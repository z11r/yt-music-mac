import Foundation
import MusicCore
import Observation

/// Optional evidence; malformed clock data never invalidates ordinary playback.
struct WebTimestampSeekClock: Decodable, Equatable, Sendable {
    let monotonic: Double?
    let wall: Double?
    var isValid: Bool { [monotonic, wall].allSatisfy { $0.map { $0.isFinite && $0 >= 0 } == true } }
    init(monotonic: Double, wall: Double) { self.monotonic = monotonic; self.wall = wall }
    init(from decoder: any Decoder) throws {
        let c = try? decoder.container(keyedBy: Keys.self)
        monotonic = try? c?.decode(Double.self, forKey: .monotonic)
        wall = try? c?.decode(Double.self, forKey: .wall)
    }
    private enum Keys: CodingKey { case monotonic, wall }
}

struct WebTimestampSeekIdentity: Equatable, Sendable {
    let context: WebPlaybackOutputContext
    let documentID: UUID
    let mediaGeneration: Int
    let commandRevision: Int
    let duration: TimeInterval
    let clock: WebTimestampSeekClock

    static func verified(_ message: PlaybackBridgeMessage, context: WebPlaybackOutputContext, revision: Int) -> Self? {
        guard message.kind == .state || message.kind == .progress,
              message.confirmsEpisodeProgress, message.playbackIntent, message.mediaGeneration > 0,
              message.commandRevision == revision, revision < 9_007_199_254_740_989,
              message.loadID == context.loadID, message.identity == PlaybackBridgeIdentity(context.occurrence),
              message.videoID == context.occurrence.trackID, message.position < message.duration,
              let clock = message.timestampSeekClock, clock.isValid else { return nil }
        return .init(context: context, documentID: message.documentID, mediaGeneration: message.mediaGeneration,
                     commandRevision: revision, duration: message.duration, clock: clock)
    }
}

struct WebTimestampSeekRequest: Equatable, Sendable {
    let id: UUID
    let identity: WebTimestampSeekIdentity
    let position: TimeInterval
    init(id: UUID = UUID(), identity: WebTimestampSeekIdentity, position: TimeInterval) {
        self.id = id; self.identity = identity; self.position = position
    }
    var isValid: Bool {
        position.isFinite && position >= 0 && identity.duration.isFinite && position < identity.duration &&
        identity.clock.isValid && identity.commandRevision >= 0 && identity.commandRevision < 9_007_199_254_740_989
    }
    func payload(revision: Int) -> [String: Any] {
        let occurrence = identity.context.occurrence
        return ["requestID": id.uuidString.lowercased(), "loadID": identity.context.loadID.uuidString,
                "documentID": identity.documentID.uuidString.lowercased(), "mediaGeneration": identity.mediaGeneration,
                "expectedRevision": identity.commandRevision, "revision": revision,
                "duration": identity.duration, "position": position,
                "sourceClock": ["monotonic": identity.clock.monotonic!, "wall": identity.clock.wall!],
                "identity": ["sessionID": occurrence.sessionID.uuidString.lowercased(), "entryID": occurrence.entryID.uuidString.lowercased(),
                             "trackID": occurrence.trackID, "generation": String(occurrence.generation)]]
    }
}

struct PlaybackTimestampSeekTarget: Equatable, Sendable {
    let scope: PlaybackOutputScope
    let bindingID: UUID
    let request: WebTimestampSeekRequest
}

enum WebTimestampSeekOutcome: Equatable, Sendable {
    case confirmed(TimeInterval), rejected, unconfirmed, cancelled
    var isConfirmed: Bool { if case .confirmed = self { true } else { false } }
    static func receipt(_ body: Any, request: WebTimestampSeekRequest, revision: Int) -> Self {
        guard let value = body as? [String: Any], value["requestID"] as? String == request.id.uuidString.lowercased(),
              let number = value["revision"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number == NSNumber(value: revision),
              let status = value["status"] as? String else { return .unconfirmed }
        if status == "rejected" { return .rejected }
        guard status == "confirmed", let position = value["position"] as? NSNumber,
              CFGetTypeID(position) != CFBooleanGetTypeID(), position.doubleValue.isFinite,
              position.doubleValue >= 0, position.doubleValue < request.identity.duration,
              abs(position.doubleValue - request.position) <= 0.25 else { return .unconfirmed }
        return .confirmed(position.doubleValue)
    }
}

@MainActor @Observable final class WebTimestampSeekAdmission {
    static let shared = WebTimestampSeekAdmission()
    private(set) var ticket: UUID?
    func reserve(_ id: UUID) -> Bool { guard ticket == nil else { return false }; ticket = id; return true }
    func release(_ id: UUID) { if ticket == id { ticket = nil } }
}

/// The same synchronous admission is used by WebPlayer and injected tests.
/// Cancellation/timeout of a UI waiter cannot free this native call's slot.
@MainActor final class WebTimestampSeekTransaction {
    private(set) var inFlight: UUID?
    private var worker: UUID?
    private let admission: WebTimestampSeekAdmission
    var isBusy: Bool { admission.ticket != nil }
    init(admission: WebTimestampSeekAdmission? = nil) { self.admission = admission ?? .shared }
    func perform(_ request: WebTimestampSeekRequest, current: () -> WebTimestampSeekIdentity?,
                 retarget: () -> WebPlaybackOutputContext?,
                 dispatch: (WebTimestampSeekRequest, WebPlaybackOutputContext, @escaping @MainActor (WebTimestampSeekOutcome) -> Void) -> Void,
                 completion: @escaping @MainActor (WebTimestampSeekOutcome) -> Void) {
        let ticket = UUID()
        guard !Task.isCancelled, inFlight == nil, request.isValid, current() == request.identity, admission.reserve(ticket) else { completion(.rejected); return }
        inFlight = request.id; worker = ticket
        guard let next = retarget(), next.engineInstanceID == request.identity.context.engineInstanceID,
              next.loadID == request.identity.context.loadID, next.occurrence == request.identity.context.occurrence,
              next.commandEpoch != request.identity.context.commandEpoch,
              next.minimumCommandRevision == request.identity.commandRevision + 1 else {
            inFlight = nil; worker = nil; admission.release(ticket); completion(.rejected); return
        }
        dispatch(request, next) { [self] outcome in
            guard worker == ticket, inFlight == request.id else { return }
            inFlight = nil; worker = nil; admission.release(ticket); completion(outcome)
        }
    }
}

/// A bounded UI receipt, independent of the retained native operation above.
@MainActor final class WebTimestampSeekReply {
    private var result: WebTimestampSeekOutcome?
    private var waiter: CheckedContinuation<WebTimestampSeekOutcome, Never>?
    private var timer: Task<Void, Never>?
    func wait(sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
              start: (@escaping @MainActor (WebTimestampSeekOutcome) -> Void) -> Void) async -> WebTimestampSeekOutcome {
        if let result { return result }
        guard waiter == nil else { return .unconfirmed }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            timer = Task { [weak self] in do { try await sleep() } catch { return }; self?.finish(.unconfirmed) }
            start { [weak self] in self?.finish($0) }
        }
    }
    func finish(_ value: WebTimestampSeekOutcome) {
        guard result == nil else { return }
        result = value; timer?.cancel(); timer = nil
        waiter?.resume(returning: value); waiter = nil
    }
}
