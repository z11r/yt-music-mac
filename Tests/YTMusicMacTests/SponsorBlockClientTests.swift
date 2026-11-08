import CryptoKit
import Foundation
import Testing
@testable import YTMusicMac

private actor SponsorBlockTestHTTP: SponsorBlockTransport {
    var response: SponsorBlockResponse
    private(set) var requests: [URLRequest] = []
    private var holds = false
    private var started = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    init(_ response: SponsorBlockResponse) { self.response = response }
    func set(_ response: SponsorBlockResponse) { self.response = response }
    func hold() { holds = true; started = false }
    func send(_ request: URLRequest) async throws -> SponsorBlockResponse {
        requests.append(request); started = true
        let observers = observers; self.observers = []; observers.forEach { $0.resume() }
        if holds { await withCheckedContinuation { waiting = $0 } }
        return response
    }
    func waitForRequest() async { if !started { await withCheckedContinuation { observers.append($0) } } }
    func release() { holds = false; waiting?.resume(); waiting = nil }
}
final class SponsorBlockTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 1_000
    func now() -> TimeInterval { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant += seconds } }
}
private final class SponsorBlockFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var created = 0, released = 0
    var counts: (Int, Int) { lock.withLock { (created, released) } }
    func make() -> any SponsorBlockTransport {
        lock.withLock { created += 1 }
        return Transient(trace: self)
    }
    private func release() { lock.withLock { released += 1 } }
    private final class Transient: SponsorBlockTransport, @unchecked Sendable {
        let trace: SponsorBlockFactoryProbe
        init(trace: SponsorBlockFactoryProbe) { self.trace = trace }
        func send(_ request: URLRequest) async throws -> SponsorBlockResponse { .init(data: Data("[]".utf8), statusCode: 200) }
        deinit { trace.release() }
    }
}
func sponsorBlockPayload(_ segments: [[String: Any]], videoID: String = "abcDEF12_-3") throws -> Data {
    try JSONSerialization.data(withJSONObject: [["videoID": videoID, "segments": segments]])
}
func sponsorBlockSegment(_ changes: [String: Any] = [:]) -> [String: Any] {
    var value: [String: Any] = ["UUID": String(repeating: "a", count: 64), "category": "music_offtopic", "actionType": "skip",
        "segment": [10.0, 20.0], "videoDuration": 100, "votes": 2, "locked": false]
    value.merge(changes) { _, new in new }; return value
}

@Suite("Private bounded SponsorBlock reads")
struct SponsorBlockClientTests {
    @Test func transportFactoryStaysUnusedUntilLookupAndEachAdmittedReadReleasesItsTransport() async throws {
        let probe = SponsorBlockFactoryProbe(), clock = SponsorBlockTestClock()
        let client = SponsorBlockClient(makeTransport: probe.make, monotonic: clock.now)
        #expect(probe.counts == (0, 0))
        _ = try await client.sections(videoID: "abcDEF12_-3", duration: 100)
        #expect(probe.counts == (1, 1))
        clock.advance(30)
        _ = try await client.sections(videoID: "abcDEF12_-3", duration: 100)
        #expect(probe.counts == (2, 2))
    }
    @Test func requestUsesOnlyFourHashCharactersAndFixedReadOnlyCategoryParameters() throws {
        let request = try SponsorBlockRequest.make(videoID: "abcDEF12_-3")
        let url = try #require(request.url), parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let expected = SHA256.hash(data: Data("abcDEF12_-3".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(url.path == "/api/skipSegments/" + expected.prefix(4))
        #expect(parts.queryItems == [.init(name: "category", value: "music_offtopic"), .init(name: "actionType", value: "skip"), .init(name: "service", value: "YouTube")])
        #expect(SponsorBlockRequest.permits(request) && request.httpMethod == "GET" && request.httpBody == nil && !request.httpShouldHandleCookies)
        #expect(!url.absoluteString.contains("abcDEF12_-3") && !url.absoluteString.contains(expected))
        #expect(Set(request.allHTTPHeaderFields?.keys ?? Dictionary<String, String>().keys) == ["Accept", "User-Agent"])
        for value in ["", "short", "abcDEF12_-é", "https://example.invalid"] {
            #expect(throws: SponsorBlockError.invalidRequest) { try SponsorBlockRequest.make(videoID: value) }
        }
    }
    @Test func fixedTransportPolicyRejectsAlternateHostsPathsQueriesMethodsAndCredentialURLs() throws {
        for url in ["http://sponsor.ajay.app/api/skipSegments/abcd", "https://sponsor.ajay.app.evil.invalid/api/skipSegments/abcd",
                    "https://name:pass@sponsor.ajay.app/api/skipSegments/abcd", "https://sponsor.ajay.app/api/skipSegments/ABCDE",
                    "https://sponsor.ajay.app/api/skipSegments/abcd?category=sponsor&actionType=skip&service=YouTube",
                    "https://sponsor.ajay.app/api/skipSegments/abcd?category=music_offtopic&actionType=skip&service=YouTube&videoID=abcDEF12_-3"] {
            #expect(!SponsorBlockRequest.permits(URLRequest(url: try #require(URL(string: url)))))
        }
        var request = try SponsorBlockRequest.make(videoID: "abcDEF12_-3")
        request.httpMethod = "POST"; #expect(!SponsorBlockRequest.permits(request))
        request.httpMethod = "GET"; request.httpBody = Data([1]); #expect(!SponsorBlockRequest.permits(request))
    }
    @Test func collisionBucketsNeverReturnAnotherVideosDataAndAmbiguousTargetsFail() throws {
        let matching = try sponsorBlockPayload([sponsorBlockSegment()])
        let other = try sponsorBlockPayload([sponsorBlockSegment(["segment": [1, 9]])], videoID: "other123456")
        let objects = try #require(JSONSerialization.jsonObject(with: matching) as? [[String: Any]])
        let others = try #require(JSONSerialization.jsonObject(with: other) as? [[String: Any]])
        let result = try SponsorBlockParser.parse(JSONSerialization.data(withJSONObject: others + objects), videoID: "abcDEF12_-3", duration: 100)
        #expect(result == [.init(id: String(repeating: "a", count: 64), start: 10, end: 20)])
        #expect(try SponsorBlockParser.parse(other, videoID: "abcDEF12_-3", duration: 100).isEmpty)
        #expect(throws: SponsorBlockError.invalidResponse) {
            try SponsorBlockParser.parse(JSONSerialization.data(withJSONObject: objects + objects), videoID: "abcDEF12_-3", duration: 100)
        }
    }
    @Test func unknownDurationsKindsUntrustedVotesConflictingIDsAndUnsafeRangesAreExcluded() throws {
        for change: [String: Any] in [["videoDuration": 0], ["videoDuration": 103], ["category": "future"], ["actionType": "full"],
                                     ["votes": -1], ["segment": [-1, 20]], ["segment": [20, 10]], ["segment": [20, 100]], ["UUID": "unknown"]] {
            #expect(try SponsorBlockParser.parse(sponsorBlockPayload([sponsorBlockSegment(change)]), videoID: "abcDEF12_-3", duration: 100).isEmpty)
        }
        #expect(try SponsorBlockParser.parse(sponsorBlockPayload([sponsorBlockSegment(), sponsorBlockSegment(["segment": [30, 40]])]), videoID: "abcDEF12_-3", duration: 100).isEmpty)
        var missing = sponsorBlockSegment(); missing.removeValue(forKey: "videoDuration")
        #expect(try SponsorBlockParser.parse(sponsorBlockPayload([missing]), videoID: "abcDEF12_-3", duration: 100).isEmpty)
    }
    @Test func malformedAndOversizedStructuresAreBoundedBeforeUnboundedCollectionDecoding() throws {
        let bucket: [String: Any] = ["videoID": "abcDEF12_-3", "segments": []]
        for data in [Data(repeating: 32, count: SponsorBlockRequest.byteLimit + 1), Data("{\"future\":true}".utf8),
                     try JSONSerialization.data(withJSONObject: Array(repeating: bucket, count: 129)),
                     try sponsorBlockPayload(Array(repeating: sponsorBlockSegment(), count: 65)),
                     try sponsorBlockPayload([sponsorBlockSegment(["segment": [1, 2, 3]])])] {
            #expect(throws: SponsorBlockError.invalidResponse) { try SponsorBlockParser.parse(data, videoID: "abcDEF12_-3", duration: 100) }
        }
        #expect(throws: SponsorBlockError.invalidResponse) { try SponsorBlockParser.parse(Data("[]".utf8), videoID: "abcDEF12_-3", duration: .nan) }
    }
    @Test func lookupIsSingleFlightAndCancellationKeepsItsSlotUntilUnderlyingReadSettles() async throws {
        let clock = SponsorBlockTestClock(), transport = SponsorBlockTestHTTP(.init(data: try sponsorBlockPayload([sponsorBlockSegment()]), statusCode: 200))
        let client = SponsorBlockClient(transport: transport, monotonic: clock.now)
        await transport.hold()
        let request = Task { try await client.sections(videoID: "abcDEF12_-3", duration: 100) }
        await transport.waitForRequest(); request.cancel(); clock.advance(31)
        await #expect(throws: SponsorBlockError.busy) { try await client.sections(videoID: "abcDEF12_-3", duration: 100) }
        await transport.release()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await transport.requests.count == 1)
        #expect(try await client.sections(videoID: "abcDEF12_-3", duration: 100).count == 1)
        #expect(await transport.requests.count == 2)
    }
    @Test func negativeResultsCooldownAndProviderRetryAfterNeverAutomaticallyRetry() async throws {
        let clock = SponsorBlockTestClock(), transport = SponsorBlockTestHTTP(.init(data: Data(), statusCode: 404))
        let client = SponsorBlockClient(transport: transport, monotonic: clock.now)
        #expect(try await client.sections(videoID: "abcDEF12_-3", duration: 100).isEmpty)
        await #expect(throws: SponsorBlockError.cooldown(30)) { try await client.sections(videoID: "abcDEF12_-3", duration: 100) }
        clock.advance(30); await transport.set(.init(data: Data(), statusCode: 429, retryAfter: "120"))
        await #expect(throws: SponsorBlockError.cooldown(120)) { try await client.sections(videoID: "abcDEF12_-3", duration: 100) }
        clock.advance(119)
        await #expect(throws: SponsorBlockError.cooldown(1)) { try await client.sections(videoID: "abcDEF12_-3", duration: 100) }
        #expect(await transport.requests.count == 2)
    }
    @Test func invalidDurationAndOversizedOrFailedResponsesDoNotLeakProviderErrors() async throws {
        let transport = SponsorBlockTestHTTP(.init(data: Data("private provider error".utf8), statusCode: 503))
        let client = SponsorBlockClient(transport: transport)
        await #expect(throws: SponsorBlockError.invalidRequest) { try await client.sections(videoID: "abcDEF12_-3", duration: .nan) }
        #expect(await transport.requests.isEmpty)
        await #expect(throws: SponsorBlockError.unavailable) { try await client.sections(videoID: "abcDEF12_-3", duration: 100) }
        #expect(!SponsorBlockError.unavailable.localizedDescription.contains("private provider error"))
        let large = SponsorBlockClient(transport: SponsorBlockTestHTTP(.init(data: Data(repeating: 32, count: SponsorBlockRequest.byteLimit + 1), statusCode: 200)))
        await #expect(throws: SponsorBlockError.invalidResponse) { try await large.sections(videoID: "abcDEF12_-3", duration: 100) }
    }
}
