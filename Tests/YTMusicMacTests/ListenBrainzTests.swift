import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@MainActor struct ListenBrainzTests {
    private let profile = String(repeating: "a", count: 64)
    private let otherProfile = String(repeating: "b", count: 64)
    private let fakeToken = "fixture-token-never-real"
    private let song = Track(id: "abcDEF12_-3", title: "Fixture Song", artist: "Fixture Artist", album: "Fixture Album", contentKind: .song)

    @Test func defaultOffDoesNotAccessCredentialsOrMakeRequests() async throws {
        let fixture = fixture([])
        defer { fixture.remove() }
        let state = await bind(fixture)
        #expect(!state.enabled && !state.connected)
        let occurrence = occurrence()
        await fixture.coordinator.begin(track: song, occurrence: occurrence, intent: .newListen, expectedScope: fixture.scope)
        await feed(fixture, occurrence: occurrence)
        #expect(await fixture.tokens.readCount == 0)
        #expect(await fixture.transport.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test func verificationDoesNotOptInAndConfirmedPostsContainOnlyDisclosedMetadata() async throws {
        let fixture = fixture([.response(valid()), .response(accepted())])
        defer { fixture.remove() }
        _ = await bind(fixture)
        let connected = await fixture.coordinator.connect(token: fakeToken, expectedScope: fixture.scope)
        #expect(connected.connected && !connected.enabled)
        #expect(await fixture.tokens.values[profile] == fakeToken)
        _ = await fixture.coordinator.setEnabled(true, expectedScope: fixture.scope)
        let occurrence = occurrence()
        await fixture.coordinator.begin(track: song, occurrence: occurrence, intent: .newListen, expectedScope: fixture.scope)
        await feed(fixture, occurrence: occurrence)
        await fixture.coordinator.waitForDeliveries()
        let requests = await fixture.transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "GET" && requests[0].url?.query == nil)
        #expect(requests[1].url?.absoluteString == "https://api.listenbrainz.org/1/submit-listens")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Token " + fakeToken)
        let body = try #require(requests[1].httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["listen_type"] as? String == "import")
        let payload = try #require(object["payload"] as? [[String: Any]])
        let metadata = try #require(payload.first?["track_metadata"] as? [String: Any])
        #expect(metadata["artist_name"] as? String == song.artist)
        #expect(metadata["track_name"] as? String == song.title)
        #expect(metadata["release_name"] as? String == song.album)
        let encoded = String(decoding: body, as: UTF8.self)
        for excluded in [song.id, profile, "Cookie", "Authorization", "artwork", "episode", "entityId"] { #expect(!encoded.contains(excluded)) }
        let stored = try fixture.store.load(profile: profile)
        #expect(stored.outbox.first?.state == .confirmed)
        let file = fixture.directory.appendingPathComponent(profile + ".json")
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains(fakeToken))
    }

    @Test func uncertainPostsSurviveRestartWithoutAutomaticReplay() async throws {
        let fixture = fixture([.response(valid()), .response(.init(data: Data("{}".utf8), statusCode: 200)), .response(valid()), .response(valid())])
        defer { fixture.remove() }
        await enable(fixture)
        let occurrence = occurrence()
        await fixture.coordinator.begin(track: song, occurrence: occurrence, intent: .newListen, expectedScope: fixture.scope)
        await feed(fixture, occurrence: occurrence)
        await fixture.coordinator.waitForDeliveries()
        #expect(try fixture.store.load(profile: profile).outbox.first?.state == .uncertain)
        _ = await fixture.coordinator.sendUnsent(expectedScope: fixture.scope)
        await fixture.coordinator.waitForDeliveries()
        let restarted = fixture.restarted()
        _ = await bind(restarted)
        await restarted.coordinator.waitForDeliveries()
        let requests = await fixture.transport.requests
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(await restarted.coordinator.viewState().uncertain == 1)
    }

    @Test func aCrashedAttemptIsHeldBeforeAnyNetworkSend() async throws {
        let fixture = fixture([.response(valid())])
        defer { fixture.remove() }
        var document = ListenBrainzDocument(profile: profile)
        document.enabled = true; document.username = "fixture-user"
        document.outbox = [.init(listen: earned(), username: "fixture-user", state: .sending)]
        try fixture.store.save(document)
        await fixture.tokens.store(fakeToken, profile: profile)
        let state = await bind(fixture)
        #expect(state.uncertain == 1 && state.paused)
        #expect(try fixture.store.load(profile: profile).outbox.first?.state == .uncertain)
        #expect(await fixture.transport.requests.filter { $0.httpMethod == "POST" }.isEmpty)
    }

    @Test func lateResponsesCannotUpdateAnotherProfile() async throws {
        let fixture = fixture([.response(valid()), .hold])
        defer { fixture.remove() }
        await enable(fixture)
        let occurrence = occurrence()
        await fixture.coordinator.begin(track: song, occurrence: occurrence, intent: .newListen, expectedScope: fixture.scope)
        await feed(fixture, occurrence: occurrence)
        await fixture.transport.waitForHold()
        #expect(try fixture.store.load(profile: profile).outbox.first?.state == .sending)
        let nextScope = UUID()
        fixture.coordinator.gate.revoke(to: nextScope)
        let next = await fixture.coordinator.bind(profile: otherProfile, scope: nextScope)
        #expect(!next.enabled && next.ready == 0)
        await fixture.transport.finish(accepted())
        await fixture.coordinator.waitForDeliveries()
        #expect(try fixture.store.load(profile: otherProfile).outbox.isEmpty)
        #expect(try fixture.store.load(profile: profile).outbox.first?.state == .confirmed)
        #expect(await fixture.coordinator.viewState().username == nil)
        #expect(await fixture.transport.requests.count == 2)
    }

    @Test func optingOutWhileValidationIsInFlightDefeatsTheOlderOptIn() async throws {
        let fixture = fixture([.hold])
        defer { fixture.remove() }
        var document = ListenBrainzDocument(profile: profile)
        document.username = "fixture-user"
        try fixture.store.save(document)
        await fixture.tokens.store(fakeToken, profile: profile)
        _ = await bind(fixture)
        let enabling = Task { await fixture.coordinator.setEnabled(true, expectedScope: fixture.scope) }
        await fixture.transport.waitForHold()
        let revision = try #require(fixture.coordinator.gate.changeIntent(scope: fixture.scope))
        _ = await fixture.coordinator.setEnabled(false, expectedScope: fixture.scope, revision: revision)
        await fixture.transport.finish(valid())
        _ = await enabling.value
        let state = await fixture.coordinator.viewState()
        #expect(!state.enabled && !state.working)
        #expect(!fixture.coordinator.gate.allows(scope: fixture.scope))
        #expect(try !fixture.store.load(profile: profile).enabled)
        #expect(await fixture.transport.requests.count == 1)
    }

    @Test func optOutAndReenableCannotCollectThePriorPartialPlay() async throws {
        let fixture = fixture([.response(valid()), .response(accepted())])
        defer { fixture.remove() }
        await enable(fixture)
        let occurrence = occurrence()
        await fixture.coordinator.begin(track: song, occurrence: occurrence, intent: .newListen, expectedScope: fixture.scope)
        for time in 1...40 {
            await fixture.coordinator.sample(occurrence: occurrence, position: Double(time), duration: 120, ended: false,
                                            expectedScope: fixture.scope, observedTime: Double(time))
        }
        _ = await fixture.coordinator.setEnabled(false, expectedScope: fixture.scope)
        _ = await fixture.coordinator.setEnabled(true, expectedScope: fixture.scope)
        for time in 41...120 {
            await fixture.coordinator.sample(occurrence: occurrence, position: Double(time), duration: 120, ended: false,
                                            expectedScope: fixture.scope, observedTime: Double(time))
        }
        #expect(await fixture.transport.requests.count == 1)
        await fixture.coordinator.begin(track: song, occurrence: occurrence, intent: .newListen, expectedScope: fixture.scope)
        await feed(fixture, occurrence: occurrence)
        await fixture.coordinator.waitForDeliveries()
        #expect(await fixture.transport.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func aLateAcknowledgmentCannotRecreateExplicitlyDeletedLocalData() async throws {
        let fixture = fixture([.response(valid()), .hold])
        defer { fixture.remove() }
        await enable(fixture)
        let occurrence = occurrence()
        await fixture.coordinator.begin(track: song, occurrence: occurrence, intent: .newListen, expectedScope: fixture.scope)
        await feed(fixture, occurrence: occurrence)
        await fixture.transport.waitForHold()
        _ = await fixture.coordinator.disconnect(expectedScope: fixture.scope)
        await fixture.transport.finish(accepted())
        await fixture.coordinator.waitForDeliveries()
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(profile + ".json").path))
        #expect(await fixture.coordinator.viewState().username == nil)
        #expect(await fixture.tokens.values[profile] == nil)
    }

    @Test func stalePlayAndContinuitySamplesCannotBridgeASeekOrReplacedSelection() async throws {
        let fixture = fixture([.response(valid())])
        defer { fixture.remove() }
        await enable(fixture)
        let occurrence = occurrence()
        await fixture.coordinator.begin(track: song, occurrence: occurrence, intent: .newListen, expectedScope: fixture.scope,
                                        continuity: 1, playGeneration: 1)
        for time in 1...40 {
            await fixture.coordinator.sample(occurrence: occurrence, position: Double(time), duration: 120, ended: false,
                                            expectedScope: fixture.scope, continuity: 1, playGeneration: 1, observedTime: Double(time))
        }
        await fixture.coordinator.interrupt(expectedScope: fixture.scope, continuity: 2, playGeneration: 1)
        // The queued pre-seek callbacks arrive after the interruption.
        for time in 41...100 {
            await fixture.coordinator.sample(occurrence: occurrence, position: Double(time), duration: 120, ended: false,
                                            expectedScope: fixture.scope, continuity: 1, playGeneration: 1, observedTime: Double(time))
        }
        let next = PlaybackOccurrence(sessionID: occurrence.sessionID, entryID: UUID(), trackID: song.id, generation: 2)
        await fixture.coordinator.begin(track: song, occurrence: next, intent: .newListen, expectedScope: fixture.scope,
                                        continuity: 3, playGeneration: 2)
        for time in 41...100 {
            await fixture.coordinator.sample(occurrence: occurrence, position: Double(time), duration: 120, ended: false,
                                            expectedScope: fixture.scope, continuity: 1, playGeneration: 1, observedTime: Double(time))
        }
        #expect(await fixture.transport.requests.count == 1)
        #expect(try fixture.store.load(profile: profile).ledger.current?.heardSeconds == 0)
    }

    @Test func staleOptInCannotReopenARevokedProfile() async {
        let fixture = fixture([])
        defer { fixture.remove() }
        let next = UUID()
        fixture.coordinator.gate.revoke(to: next)
        _ = await fixture.coordinator.bind(profile: profile, scope: fixture.scope)
        _ = await fixture.coordinator.connect(token: fakeToken, expectedScope: fixture.scope)
        _ = await fixture.coordinator.setEnabled(true, expectedScope: fixture.scope)
        fixture.coordinator.gate.activate(scope: fixture.scope, revision: UUID())
        #expect(!fixture.coordinator.gate.allows(scope: fixture.scope))
        #expect(await fixture.transport.requests.isEmpty)
        #expect(await fixture.tokens.readCount == 0)
    }

    @Test func rejectedAndUncertainOutcomesNeverClaimSuccessOrRetry() async {
        for response in [ScrobbleHTTPResponse(data: Data(), statusCode: 400), .init(data: Data(), statusCode: 401),
                         .init(data: Data(), statusCode: 429), .init(data: Data(), statusCode: 500), .init(data: Data("{}".utf8), statusCode: 200)] {
            let transport = FakeListenBrainzTransport([.response(response)])
            let result = await ListenBrainzAPI(transport: transport).submit(earned(), token: fakeToken)
            #expect(result != .confirmed)
            #expect(await transport.requests.count == 1)
        }
        let transport = FakeListenBrainzTransport([.failure])
        #expect(await ListenBrainzAPI(transport: transport).submit(earned(), token: fakeToken) == .uncertain)
        #expect(await transport.requests.count == 1)
    }

    @Test func tokenValidationIsStrictAndNeverUsesAQueryString() async {
        for object: [String: Any] in [["valid": false], ["valid": 1, "user_name": "fixture-user"], ["valid": true]] {
            let transport = FakeListenBrainzTransport([.response(.init(data: try! JSONSerialization.data(withJSONObject: object), statusCode: 200))])
            await #expect(throws: (any Error).self) { _ = try await ListenBrainzAPI(transport: transport).validateToken(fakeToken) }
            #expect(await transport.requests.first?.url?.query == nil)
        }
        let transport = FakeListenBrainzTransport([])
        await #expect(throws: ListenBrainzAPIError.self) { _ = try await ListenBrainzAPI(transport: transport).validateToken("token\nheader") }
        #expect(await transport.requests.isEmpty)
    }

    @Test func localFilesAreBoundedAtomicAndRetainMalformedOrNewerData() throws {
        let fixture = fixture([])
        defer { fixture.remove() }
        var document = ListenBrainzDocument(profile: profile)
        document.username = "fixture-user"
        document.outbox = (0..<101).map { _ in .init(listen: earned(), username: "fixture-user", state: .ready) }
        #expect(throws: ListenBrainzStoreError.self) { try fixture.store.save(document) }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let file = fixture.directory.appendingPathComponent(profile + ".json")
        let malformed = Data("{malformed".utf8)
        try malformed.write(to: file)
        #expect(throws: (any Error).self) { try fixture.store.save(.init(profile: profile)) }
        #expect(try Data(contentsOf: file) == malformed)
        document = .init(profile: profile); document.version = 2
        let newer = try JSONEncoder().encode(document)
        try newer.write(to: file)
        #expect(throws: ListenBrainzStoreError.unsupportedVersion) { _ = try fixture.store.load(profile: profile) }
        #expect(throws: (any Error).self) { try fixture.store.save(.init(profile: profile)) }
        #expect(try Data(contentsOf: file) == newer)
    }

    @Test func backlogSendsAreBoundedAndOnlyUnattemptedListensAreSelected() async throws {
        let fixture = fixture([.response(valid()), .response(valid())] + Array(repeating: .response(accepted()), count: 5))
        defer { fixture.remove() }
        var document = ListenBrainzDocument(profile: profile)
        document.enabled = true; document.paused = true; document.username = "fixture-user"
        document.outbox = (0..<100).map { _ in .init(listen: earned(), username: "fixture-user", state: .ready) }
        try fixture.store.save(document)
        await fixture.tokens.store(fakeToken, profile: profile)
        _ = await bind(fixture)
        _ = await fixture.coordinator.sendUnsent(expectedScope: fixture.scope)
        await fixture.coordinator.waitForDeliveries()
        #expect(await fixture.transport.requests.filter { $0.httpMethod == "POST" }.count == 5)
        #expect(await fixture.coordinator.viewState().ready == 95)
    }

    @Test func disconnectStopsCaptureDeletesOnlyItsCredentialAndRemovesLocalData() async throws {
        let fixture = fixture([.response(valid())])
        defer { fixture.remove() }
        await enable(fixture)
        await fixture.tokens.store("another-profile-token", profile: otherProfile)
        let disconnected = await fixture.coordinator.disconnect(expectedScope: fixture.scope)
        #expect(!disconnected.enabled && !disconnected.connected)
        #expect(await fixture.tokens.values[profile] == nil)
        #expect(await fixture.tokens.values[otherProfile] == "another-profile-token")
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(profile + ".json").path))
    }

    @Test func providerAccountCannotChangeWhilePendingListensTargetAnotherUser() async throws {
        let fixture = fixture([.response(valid(name: "new-user"))])
        defer { fixture.remove() }
        var document = ListenBrainzDocument(profile: profile)
        document.username = "old-user"
        document.outbox = [.init(listen: earned(), username: "old-user", state: .uncertain)]
        try fixture.store.save(document)
        _ = await bind(fixture)
        let result = await fixture.coordinator.connect(token: fakeToken, expectedScope: fixture.scope)
        #expect(!result.enabled && !result.connected)
        #expect(result.username == "old-user")
        #expect(await fixture.tokens.values.isEmpty)
    }

    private func occurrence() -> PlaybackOccurrence { .init(sessionID: UUID(), entryID: UUID(), trackID: song.id, generation: 1) }
    private func earned() -> EarnedListen {
        .init(entryID: UUID(), metadata: ListenMetadata(track: song)!, listenedAt: 1_700_000_000, duration: 120)
    }
    private func bind(_ fixture: ListenBrainzFixture) async -> ListenBrainzViewState {
        fixture.coordinator.gate.revoke(to: fixture.scope)
        return await fixture.coordinator.bind(profile: profile, scope: fixture.scope)
    }
    private func enable(_ fixture: ListenBrainzFixture) async {
        _ = await bind(fixture)
        _ = await fixture.coordinator.connect(token: fakeToken, expectedScope: fixture.scope)
        _ = await fixture.coordinator.setEnabled(true, expectedScope: fixture.scope)
    }
    private func feed(_ fixture: ListenBrainzFixture, occurrence: PlaybackOccurrence) async {
        for time in 1...61 {
            fixture.clock.set(Double(time))
            await fixture.coordinator.sample(occurrence: occurrence, position: Double(time), duration: 120, ended: false,
                                              expectedScope: fixture.scope, observedTime: Double(time))
        }
    }
    private func fixture(_ steps: [FakeListenBrainzTransport.Step]) -> ListenBrainzFixture {
        ListenBrainzFixture(steps: steps)
    }
}

private struct ListenBrainzFixture {
    let directory: URL
    let store: ListenBrainzStore
    let tokens: FakeScrobbleTokens
    let transport: FakeListenBrainzTransport
    let clock: ScrobbleTestClock
    let coordinator: ListenBrainzCoordinator
    let scope: UUID
    init(steps: [FakeListenBrainzTransport.Step]) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ListenBrainzTests-\(UUID().uuidString)", isDirectory: true)
        store = ListenBrainzStore(directory: directory)
        tokens = FakeScrobbleTokens(); transport = FakeListenBrainzTransport(steps); clock = ScrobbleTestClock(); scope = UUID()
        coordinator = ListenBrainzCoordinator(store: store, tokens: tokens, api: .init(transport: transport),
            wallTime: { [clock] in Date(timeIntervalSince1970: 1_700_000_000 + clock.read()) }, monotonicTime: { [clock] in clock.read() })
    }
    private init(directory: URL, store: ListenBrainzStore, tokens: FakeScrobbleTokens, transport: FakeListenBrainzTransport, clock: ScrobbleTestClock) {
        self.directory = directory; self.store = store; self.tokens = tokens; self.transport = transport; self.clock = clock; scope = UUID()
        coordinator = ListenBrainzCoordinator(store: store, tokens: tokens, api: .init(transport: transport),
            wallTime: { [clock] in Date(timeIntervalSince1970: 1_700_000_000 + clock.read()) }, monotonicTime: { [clock] in clock.read() })
    }
    func restarted() -> Self { .init(directory: directory, store: store, tokens: tokens, transport: transport, clock: clock) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
private actor FakeScrobbleTokens: ScrobbleTokenStoring {
    private(set) var values: [String: String] = [:]
    private(set) var readCount = 0
    func read(profile: String) -> String? { readCount += 1; return values[profile] }
    func store(_ token: String, profile: String) { values[profile] = token }
    func remove(profile: String) { values[profile] = nil }
}
private actor FakeListenBrainzTransport: ScrobbleHTTPTransport {
    enum Step: Sendable { case response(ScrobbleHTTPResponse), failure, hold }
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    private var held: CheckedContinuation<ScrobbleHTTPResponse, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) async throws -> ScrobbleHTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        switch steps.removeFirst() {
        case let .response(value): return value
        case .failure: throw URLError(.networkConnectionLost)
        case .hold:
            return await withCheckedContinuation {
                held = $0
                for waiter in waiters { waiter.resume() }; waiters = []
            }
        }
    }
    func waitForHold() async { if held == nil { await withCheckedContinuation { waiters.append($0) } } }
    func finish(_ response: ScrobbleHTTPResponse) { held?.resume(returning: response); held = nil }
}
private final class ScrobbleTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 0.0
    func set(_ time: Double) { lock.withLock { self.time = time } }
    func read() -> Double { lock.withLock { time } }
}
private func valid(name: String = "fixture-user") -> ScrobbleHTTPResponse {
    .init(data: try! JSONSerialization.data(withJSONObject: ["valid": true, "user_name": name]), statusCode: 200)
}
private func accepted() -> ScrobbleHTTPResponse { .init(data: Data(#"{"status":"ok"}"#.utf8), statusCode: 200) }
