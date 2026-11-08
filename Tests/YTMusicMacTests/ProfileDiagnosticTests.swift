import Foundation
import Testing
import YouTubeMusic
@testable import YTMusicMac

private actor ProfileDiagnosticTransport: MusicHTTPTransport {
    enum Mode { case unknownCreate, knownCreate, uncertainDelete }
    let mode: Mode
    private var holdCreate: Bool
    private var holdSecondDelete: Bool
    private var createReply: CheckedContinuation<Void, Never>?
    private var deleteReply: CheckedContinuation<Void, Never>?
    private var createWaiters: [CheckedContinuation<Void, Never>] = []
    private var deleteWaiters: [CheckedContinuation<Void, Never>] = []
    private var deletes = 0
    private(set) var requests: [URLRequest] = []

    init(mode: Mode = .knownCreate, holdCreate: Bool = false, holdSecondDelete: Bool = false) {
        self.mode = mode; self.holdCreate = holdCreate; self.holdSecondDelete = holdSecondDelete
    }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        switch request.url?.path {
        case "/youtubei/v1/playlist/create":
            let waiters = createWaiters; createWaiters = []; waiters.forEach { $0.resume() }
            if holdCreate { await withCheckedContinuation { createReply = $0 } }
            return response(mode == .unknownCreate ? ["responseContext": [:]] : ["playlistId": "PLsynthetic-diagnostic"])
        case "/youtubei/v1/browse/edit_playlist":
            // Refusing rename exercises the established original-target cleanup path.
            return MusicHTTPResponse(data: Data(), statusCode: 403)
        case "/youtubei/v1/playlist/delete":
            deletes += 1
            if deletes == 2 {
                let waiters = deleteWaiters; deleteWaiters = []; waiters.forEach { $0.resume() }
                if holdSecondDelete { await withCheckedContinuation { deleteReply = $0 } }
            }
            return response(mode == .uncertainDelete && deletes == 1 ? ["responseContext": [:]] : ["status": "STATUS_SUCCEEDED"])
        case "/youtubei/v1/browse":
            return response([
                "header": ["musicEditablePlaylistDetailHeaderRenderer": [
                    "header": ["musicDetailHeaderRenderer": ["title": ["runs": [["text": "Synthetic playlist"]]]]],
                    "deletePlaylistEndpoint": ["playlistId": "PLsynthetic-diagnostic"],
                ]],
                "contents": ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": ["contents": []]]]]],
            ])
        default: throw URLError(.unsupportedURL)
        }
    }
    func waitForCreate() async {
        if requests.contains(where: { $0.url?.path == "/youtubei/v1/playlist/create" }) { return }
        await withCheckedContinuation { createWaiters.append($0) }
    }
    func waitForSecondDelete() async {
        if deletes >= 2 { return }
        await withCheckedContinuation { deleteWaiters.append($0) }
    }
    func releaseCreate() { holdCreate = false; createReply?.resume(); createReply = nil }
    func releaseSecondDelete() { holdSecondDelete = false; deleteReply?.resume(); deleteReply = nil }
    private func response(_ object: [String: Any]) -> MusicHTTPResponse {
        MusicHTTPResponse(data: try! JSONSerialization.data(withJSONObject: object), statusCode: 200)
    }
}

private actor ProfileDiagnosticCredentials: MusicSessionProviding {
    let store: MusicSessionStore
    private var holdsFirst = true
    private var started = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(store: MusicSessionStore) { self.store = store }
    func snapshot() async -> MusicSession {
        let value = await store.snapshot()
        if holdsFirst {
            holdsFirst = false; started = true
            let waiting = waiters; waiters = []; waiting.forEach { $0.resume() }
            await withCheckedContinuation { held = $0 }
        }
        return value
    }
    func waitForSnapshot() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { held?.resume(); held = nil }
}

@MainActor private final class ProfileDiagnosticFixture {
    let preferences = SceneCheckPreferences()
    let credentials: MusicSessionStore
    let session: AppSession
    init(transport: ProfileDiagnosticTransport) async {
        var configuration = AppSessionConfiguration.sceneCheck(preferences: preferences.defaults, transport: SceneCheckTransport())
        credentials = configuration.credentials
        await credentials.replaceSession(accountID: String(repeating: "a", count: 64), cookieHeader: "fixture=1", sapisid: "fixture",
            configuration: MusicClientConfiguration(apiKey: "fixture", clientVersion: "fixture"))
        configuration.playlistVerificationClient = YouTubeMusicClient(transport: transport, sessions: credentials,
            libraryEditCapabilities: .init(playlists: true))
        session = AppSession(configuration: configuration)
    }
    init(transport: ProfileDiagnosticTransport, credentials: MusicSessionStore, scopeGate: ProfileDiagnosticCredentials) {
        var configuration = AppSessionConfiguration.sceneCheck(preferences: preferences.defaults, transport: SceneCheckTransport())
        self.credentials = credentials
        configuration.playlistVerificationClient = YouTubeMusicClient(transport: transport, sessions: scopeGate,
            libraryEditCapabilities: .init(playlists: true))
        session = AppSession(configuration: configuration)
    }
    func remove() { preferences.remove() }
}

@MainActor @Suite("Profile-scoped disposable diagnostics")
struct ProfileDiagnosticTests {
    private let videoID = "abcDEF12_-3"

    @Test func quiescedAndRolledBackOwnersRejectEarlierDiagnosticsBeforeAnyServiceRequest() async throws {
        let transport = ProfileDiagnosticTransport()
        let fixture = await ProfileDiagnosticFixture(transport: transport); defer { fixture.remove() }
        let session = fixture.session, previous = session.accountGeneration
        session.quiesceForProfileSwitch()
        for generation in [previous, session.accountGeneration] {
            await #expect(throws: AppScriptingError.superseded) {
                try await session.checkPlaylistEdits(videoID: videoID, expectedAccountGeneration: generation)
            }
            await #expect(throws: AppScriptingError.superseded) {
                try await session.retryPlaylistEditCleanup(expectedAccountGeneration: generation)
            }
            await #expect(throws: AppScriptingError.superseded) { try await session.checkLibrary(expectedAccountGeneration: generation) }
            await #expect(throws: AppScriptingError.superseded) { try await session.checkLibraryNavigation(expectedAccountGeneration: generation) }
        }
        await session.settleForProfileSwitch(); session.resumePausedProfileOwnership()
        #expect(session.acceptsProfileActions && session.accountGeneration != previous && !session.wantsPlayback)
        await #expect(throws: AppScriptingError.superseded) {
            try await session.checkPlaylistEdits(videoID: videoID, expectedAccountGeneration: previous)
        }
        await #expect(throws: AppScriptingError.superseded) {
            try await session.retryPlaylistEditCleanup(expectedAccountGeneration: previous)
        }
        #expect(await transport.requests.isEmpty)
        await session.shutdown()
    }

    @Test func profileSettlementWaitsForAdmittedCreationAndItsOriginalTargetCleanup() async throws {
        let transport = ProfileDiagnosticTransport(holdCreate: true)
        let fixture = await ProfileDiagnosticFixture(transport: transport); defer { fixture.remove() }
        let session = fixture.session, generation = session.accountGeneration
        let checking = Task { try await session.checkPlaylistEdits(videoID: videoID, expectedAccountGeneration: generation) }
        await transport.waitForCreate()
        session.quiesceForProfileSwitch()
        var started = false, settled = false
        let settling = Task { started = true; await session.settleForProfileSwitch(); settled = true }
        while !started { await Task.yield() }
        #expect(!settled)
        await transport.releaseCreate()
        let report = try await checking.value; _ = await settling.value
        #expect(settled && report.status == .accessDenied && report.cleanup == .deleted)
        #expect(!report.cleanupNeeded)
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path } == ["/youtubei/v1/playlist/create", "/youtubei/v1/browse/edit_playlist", "/youtubei/v1/playlist/delete"])
        let deletion = try #require(requests.last?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: deletion) as? [String: Any])
        #expect(object["playlistId"] as? String == "PLsynthetic-diagnostic")
        await session.shutdown()
    }

    @Test func unknownCreationKeepsItsUncertainReportAndIsNeverRetriedDuringProfileSettlement() async throws {
        let transport = ProfileDiagnosticTransport(mode: .unknownCreate, holdCreate: true)
        let fixture = await ProfileDiagnosticFixture(transport: transport); defer { fixture.remove() }
        let session = fixture.session, generation = session.accountGeneration
        let checking = Task { try await session.checkPlaylistEdits(videoID: videoID, expectedAccountGeneration: generation) }
        await transport.waitForCreate(); session.quiesceForProfileSwitch()
        let settling = Task { await session.settleForProfileSwitch() }
        await transport.releaseCreate()
        let report = try await checking.value; _ = await settling.value
        #expect(report.status == .unconfirmed && report.cleanup == .unavailable && report.cleanupNeeded && report.uncertainOutcome)
        #expect(await session.playlistVerificationClient.hasPendingPlaylistEditCleanup())
        #expect(await transport.requests.count == 1)
        await session.shutdown()
    }

    @Test func admittedExplicitRecoveryDrainsItsFreshPermissionReadAndOriginalTargetDelete() async throws {
        let transport = ProfileDiagnosticTransport(mode: .uncertainDelete, holdSecondDelete: true)
        let fixture = await ProfileDiagnosticFixture(transport: transport); defer { fixture.remove() }
        let session = fixture.session, generation = session.accountGeneration
        let report = try await session.checkPlaylistEdits(videoID: videoID, expectedAccountGeneration: generation)
        #expect(report.cleanup == .unconfirmed && report.cleanupNeeded)
        let recovery = Task { try await session.retryPlaylistEditCleanup(expectedAccountGeneration: generation) }
        await transport.waitForSecondDelete(); session.quiesceForProfileSwitch()
        var started = false, settled = false
        let settling = Task { started = true; await session.settleForProfileSwitch(); settled = true }
        while !started { await Task.yield() }
        #expect(!settled)
        await transport.releaseSecondDelete()
        #expect(try await recovery.value == .deleted); _ = await settling.value
        let cleanupPending = await session.playlistVerificationClient.hasPendingPlaylistEditCleanup()
        #expect(settled && !cleanupPending)
        let requests = await transport.requests
        #expect(requests.suffix(2).map { $0.url?.path } == ["/youtubei/v1/browse", "/youtubei/v1/playlist/delete"])
        #expect(requests.count == 5)
        await session.shutdown()
    }

    @Test func quiescingDuringCredentialSnapshotPreventsTheFirstDiagnosticWriteAndReleasesAdmission() async throws {
        let credentials = MusicSessionStore()
        await credentials.replaceSession(accountID: String(repeating: "b", count: 64), cookieHeader: "fixture=1", sapisid: "fixture",
            configuration: MusicClientConfiguration(apiKey: "fixture", clientVersion: "fixture"))
        let gate = ProfileDiagnosticCredentials(store: credentials), transport = ProfileDiagnosticTransport()
        let fixture = ProfileDiagnosticFixture(transport: transport, credentials: credentials, scopeGate: gate); defer { fixture.remove() }
        let session = fixture.session, generation = session.accountGeneration
        let checking = Task { try await session.checkPlaylistEdits(videoID: videoID, expectedAccountGeneration: generation) }
        await gate.waitForSnapshot(); session.quiesceForProfileSwitch()
        let settling = Task { await session.settleForProfileSwitch() }
        await gate.release()
        await #expect(throws: AppScriptingError.superseded) { try await checking.value }
        _ = await settling.value
        #expect(await transport.requests.isEmpty)
        await session.shutdown()
    }

    @Test func cancelledUnadmittedChecksDoNotStartServiceWorkOrBlockShutdown() async throws {
        let transport = ProfileDiagnosticTransport()
        let fixture = await ProfileDiagnosticFixture(transport: transport); defer { fixture.remove() }
        let session = fixture.session, generation = session.accountGeneration
        let checking = Task { try await session.checkPlaylistEdits(videoID: videoID, expectedAccountGeneration: generation) }
        checking.cancel()
        await #expect(throws: CancellationError.self) { try await checking.value }
        await session.shutdown()
        #expect(await transport.requests.isEmpty)
    }
}
