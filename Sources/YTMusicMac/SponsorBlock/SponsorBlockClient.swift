import CryptoKit
import Foundation

enum SponsorBlockText {
    static func text(_ key: StaticString) -> String {
        AppLocalization.bundle.localizedString(forKey: String(describing: key), value: nil, table: "SponsorBlock")
    }
}
enum SponsorBlockError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequest, invalidResponse, unavailable, busy, cooldown(TimeInterval)
    var errorDescription: String? {
        switch self {
        case .invalidRequest: SponsorBlockText.text("Choose a confirmed catalog song before looking up sections.")
        case .invalidResponse: SponsorBlockText.text("SponsorBlock returned unsupported or inconsistent section data.")
        case .unavailable: SponsorBlockText.text("SponsorBlock could not complete this lookup. No playback action was taken.")
        case .busy, .cooldown: SponsorBlockText.text("Wait before another lookup. Canceled requests must finish and provider cooldowns still apply.")
        }
    }
}
struct SponsorBlockResponse: Sendable {
    let data: Data
    let statusCode: Int
    var retryAfter: String? = nil
}
protocol SponsorBlockTransport: Sendable {
    func send(_ request: URLRequest) async throws -> SponsorBlockResponse
}
protocol SponsorBlockProviding: Sendable {
    func sections(videoID: String, duration: TimeInterval) async throws -> [SponsorBlockSection]
}
struct SponsorBlockSection: Identifiable, Equatable, Sendable {
    let id: String
    let start: TimeInterval
    let end: TimeInterval
}

enum SponsorBlockRequest {
    static let byteLimit = 262_144
    static func acceptsVideoID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func make(videoID: String) throws -> URLRequest {
        guard acceptsVideoID(videoID) else { throw SponsorBlockError.invalidRequest }
        let prefix = SHA256.hash(data: Data(videoID.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
        var url = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/" + prefix)!
        url.queryItems = [URLQueryItem(name: "category", value: "music_offtopic"), URLQueryItem(name: "actionType", value: "skip"), URLQueryItem(name: "service", value: "YouTube")]
        var request = URLRequest(url: url.url!); request.httpMethod = "GET"
        request.httpShouldHandleCookies = false; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("YTMusicMac-Sections/1", forHTTPHeaderField: "User-Agent")
        return request
    }
    static func permits(_ request: URLRequest) -> Bool {
        guard request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "sponsor.ajay.app", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, parts.fragment == nil,
              parts.percentEncodedPath.hasPrefix("/api/skipSegments/"),
              let suffix = parts.percentEncodedPath.split(separator: "/").last,
              parts.percentEncodedPath == "/api/skipSegments/" + suffix,
              suffix.count == 4, suffix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let items = parts.queryItems, items.count == 3, Set(items.map(\.name)).count == 3 else { return false }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }) ==
            ["category": "music_offtopic", "actionType": "skip", "service": "YouTube"]
    }
}

/// Process-local rate admission contains no account, profile or song metadata.
final class SponsorBlockAdmission: @unchecked Sendable {
    static let process = SponsorBlockAdmission()
    private let lock = NSLock()
    private var permission: UUID?
    private var nextAttempt = -Double.infinity

    func begin(at instant: TimeInterval) throws -> UUID {
        try lock.withLock {
            guard instant.isFinite else { throw SponsorBlockError.invalidRequest }
            guard permission == nil else { throw SponsorBlockError.busy }
            guard instant >= nextAttempt else { throw SponsorBlockError.cooldown(nextAttempt - instant) }
            let value = UUID(); permission = value; nextAttempt = instant + 30
            return value
        }
    }
    func extend(_ value: UUID, until deadline: TimeInterval) {
        lock.withLock {
            guard permission == value, deadline.isFinite else { return }
            nextAttempt = max(nextAttempt, deadline)
        }
    }
    func finish(_ value: UUID) {
        lock.withLock { if permission == value { permission = nil } }
    }
}

/// A single explicit read; constructing the client creates no URLSession or task.
actor SponsorBlockClient: SponsorBlockProviding {
    private let transport: (any SponsorBlockTransport)?
    private let makeTransport: @Sendable () -> any SponsorBlockTransport
    private let monotonic: @Sendable () -> TimeInterval
    private let now: @Sendable () -> Date
    private let admission: SponsorBlockAdmission
    init(transport: (any SponsorBlockTransport)? = nil,
         makeTransport: @escaping @Sendable () -> any SponsorBlockTransport = { SponsorBlockHTTPTransport() },
         monotonic: @escaping @Sendable () -> TimeInterval = PlaybackOutputTime.monotonic,
         now: @escaping @Sendable () -> Date = Date.init,
         admission: SponsorBlockAdmission = .process) {
        self.transport = transport; self.makeTransport = makeTransport; self.monotonic = monotonic; self.now = now; self.admission = admission
    }
    func sections(videoID: String, duration: TimeInterval) async throws -> [SponsorBlockSection] {
        try Task.checkCancellation()
        guard duration.isFinite, duration > 0, duration <= 43_200 else { throw SponsorBlockError.invalidRequest }
        let request = try SponsorBlockRequest.make(videoID: videoID)
        let instant = monotonic()
        let permission = try admission.begin(at: instant)
        defer { admission.finish(permission) }
        let transport: any SponsorBlockTransport
        if let existing = self.transport { transport = existing }
        else { transport = makeTransport() }
        let response: SponsorBlockResponse
        do { response = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SponsorBlockError.unavailable }
        try Task.checkCancellation()
        guard response.data.count <= SponsorBlockRequest.byteLimit else { throw SponsorBlockError.invalidResponse }
        if response.statusCode == 429 {
            let delay = Self.retryDelay(response.retryAfter, now: now())
            admission.extend(permission, until: monotonic() + delay)
            throw SponsorBlockError.cooldown(delay)
        }
        if response.statusCode == 404 { return [] }
        guard response.statusCode == 200 else { throw SponsorBlockError.unavailable }
        return try SponsorBlockParser.parse(response.data, videoID: videoID, duration: duration)
    }
    private static func retryDelay(_ value: String?, now: Date) -> TimeInterval {
        guard let value, value.utf8.count <= 128 else { return 60 }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return max(30, min(seconds, 315_360_000)) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return 60 }
        return max(30, min(date.timeIntervalSince(now), 315_360_000))
    }
}

enum SponsorBlockParser {
    private struct Buckets: Decodable {
        let values: [Bucket]
        init(from decoder: any Decoder) throws {
            var input = try decoder.unkeyedContainer(); var result: [Bucket] = []
            guard input.count.map({ $0 <= 128 }) ?? true else { throw SponsorBlockError.invalidResponse }
            while !input.isAtEnd {
                guard result.count < 128 else { throw SponsorBlockError.invalidResponse }
                result.append(try input.decode(Bucket.self))
            }
            values = result
        }
    }
    private struct Bucket: Decodable {
        let videoID: String
        let segments: Segments
    }
    private struct Segments: Decodable {
        let values: [Segment]
        init(from decoder: any Decoder) throws {
            var input = try decoder.unkeyedContainer(); var result: [Segment] = []
            guard input.count.map({ $0 <= 64 }) ?? true else { throw SponsorBlockError.invalidResponse }
            while !input.isAtEnd {
                guard result.count < 64 else { throw SponsorBlockError.invalidResponse }
                result.append(try input.decode(Segment.self))
            }
            values = result
        }
    }
    private struct Segment: Decodable {
        let UUID: String?
        let category: String?
        let actionType: String?
        let segment: Times?
        let videoDuration: Double?
        let votes: Int?
    }
    private struct Times: Decodable {
        let values: [Double]
        init(from decoder: any Decoder) throws {
            var input = try decoder.unkeyedContainer()
            guard input.count.map({ $0 == 2 }) ?? true else { throw SponsorBlockError.invalidResponse }
            let start = try input.decode(Double.self), end = try input.decode(Double.self)
            guard input.isAtEnd else { throw SponsorBlockError.invalidResponse }
            values = [start, end]
        }
    }
    static func parse(_ data: Data, videoID: String, duration: Double) throws -> [SponsorBlockSection] {
        guard data.count <= SponsorBlockRequest.byteLimit, SponsorBlockRequest.acceptsVideoID(videoID),
              duration.isFinite, duration > 0, duration <= 43_200 else { throw SponsorBlockError.invalidResponse }
        do {
            let buckets = try JSONDecoder().decode(Buckets.self, from: data).values
            guard buckets.allSatisfy({ SponsorBlockRequest.acceptsVideoID($0.videoID) }) else { throw SponsorBlockError.invalidResponse }
            let matches = buckets.filter { $0.videoID == videoID }
            guard matches.count <= 1 else { throw SponsorBlockError.invalidResponse }
            let candidates = matches.first?.segments.values ?? []
            let identifiers = candidates.compactMap(\.UUID)
            let counts = Dictionary(identifiers.map { ($0, 1) }, uniquingKeysWith: +)
            return candidates.compactMap { value in
                guard value.category == "music_offtopic", value.actionType == "skip", let id = value.UUID,
                      id.utf8.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), counts[id] == 1,
                      let times = value.segment?.values, times.allSatisfy(\.isFinite),
                      times[0] >= 0, times[1] > times[0], times[1] < duration,
                      let recordedDuration = value.videoDuration, recordedDuration.isFinite, recordedDuration > 0,
                      abs(recordedDuration - duration) <= 1, let votes = value.votes, votes >= 0 else { return nil }
                return SponsorBlockSection(id: id, start: times[0], end: times[1])
            }.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        } catch { throw SponsorBlockError.invalidResponse }
    }
}
