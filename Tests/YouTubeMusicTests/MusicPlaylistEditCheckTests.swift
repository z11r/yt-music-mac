import Foundation
import XCTest
@testable import YouTubeMusic

@MainActor
final class MusicPlaylistEditCheckTests: XCTestCase {
    private let videoID = "abcDEF12_-3"

    func testDisposableSequenceVerifiesOneDuplicateRemovalAndReturnsNoIdentifiers() async throws {
        let transport = PlaylistProbeTransport()
        let report = try await client(transport).checkPlaylistEdits(videoID: videoID)
        XCTAssertTrue(report.passed)
        XCTAssertFalse(report.cleanupNeeded)
        XCTAssertFalse(report.uncertainOutcome)
        XCTAssertEqual(report.steps.map(\.step), MusicPlaylistEditCheck.Step.allCases)
        XCTAssertTrue(report.steps.allSatisfy { $0.status == .confirmed })
        XCTAssertEqual(report.steps.first { $0.step == .readAdded }?.occurrenceCount, 2)
        XCTAssertEqual(report.steps.first { $0.step == .readRemoved }?.occurrenceCount, 1)
        XCTAssertEqual(report.cleanup, .deleted)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 7)
        let create = try object(requests[0])
        XCTAssertEqual(create["privacyStatus"] as? String, "PRIVATE")
        let removal = try XCTUnwrap(object(requests[4])["actions"] as? [[String: String]])
        XCTAssertEqual(removal, [["action": "ACTION_REMOVE_VIDEO", "removedVideoId": videoID, "setVideoId": "private-second="]])
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        for value in [videoID, "private-", "Playback verification", "playlistId", "Cookie", "Authorization"] {
            XCTAssertFalse(json.contains(value))
        }
    }

    func testARefusedRenameCleansOnlyTheConfirmedNewPlaylist() async throws {
        let transport = PlaylistProbeTransport(mode: .renameRejected)
        let report = try await client(transport).checkPlaylistEdits(videoID: videoID)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.status, .accessDenied)
        XCTAssertEqual(report.cleanup, .deleted)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/youtubei/v1/playlist/create", "/youtubei/v1/browse/edit_playlist", "/youtubei/v1/playlist/delete"])
        XCTAssertEqual(try object(requests[2])["playlistId"] as? String, "PLprivate-created")
    }

    func testAnUnknownCreationIsNotRetriedOrCleanedByTitle() async throws {
        let transport = PlaylistProbeTransport(mode: .creationUnconfirmed)
        let client = await client(transport)
        let scope = try await client.libraryEditScope()
        let report = try await client.checkPlaylistEdits(videoID: videoID)
        XCTAssertEqual(report.status, .unconfirmed)
        XCTAssertEqual(report.cleanup, .unavailable)
        XCTAssertTrue(report.cleanupNeeded)
        XCTAssertTrue(report.uncertainOutcome)
        let pending = await client.hasPendingPlaylistEditCleanup()
        XCTAssertTrue(pending)
        do { _ = try await client.checkPlaylistEdits(videoID: videoID); XCTFail("Expected unresolved cleanup gate") }
        catch { XCTAssertEqual(error as? MusicLibraryEditError, .verificationCleanupRequired) }
        let cleanup = try await client.retryPlaylistEditCleanup(expectedScope: scope)
        XCTAssertEqual(cleanup, .unavailable)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testAnUnconfirmedDeleteIsNeverAutomaticallyReplayed() async throws {
        let transport = PlaylistProbeTransport(mode: .deletionUnconfirmed)
        let report = try await client(transport).checkPlaylistEdits(videoID: videoID)
        XCTAssertEqual(report.status, .unconfirmed)
        XCTAssertEqual(report.cleanup, .unconfirmed)
        XCTAssertTrue(report.cleanupNeeded)
        XCTAssertTrue(report.uncertainOutcome)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/youtubei/v1/playlist/delete" }.count, 1)
    }

    func testExplicitCleanupRecoveryRechecksPermissionAndRetainsTheKnownID() async throws {
        let transport = PlaylistProbeTransport(mode: .deletionUnconfirmed)
        let client = await client(transport)
        let scope = try await client.libraryEditScope()
        let report = try await client.checkPlaylistEdits(videoID: videoID)
        XCTAssertEqual(report.cleanup, .unconfirmed)
        let retained = await client.hasPendingPlaylistEditCleanup()
        XCTAssertTrue(retained)
        let cleanup = try await client.retryPlaylistEditCleanup(expectedScope: scope)
        XCTAssertEqual(cleanup, .deleted)
        let pending = await client.hasPendingPlaylistEditCleanup()
        XCTAssertFalse(pending)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 9)
        XCTAssertEqual(requests.suffix(2).map { $0.url?.path }, ["/youtubei/v1/browse", "/youtubei/v1/playlist/delete"])
        let targets = try requests.filter { $0.url?.path == "/youtubei/v1/playlist/delete" }.map { try object($0)["playlistId"] as? String }
        XCTAssertEqual(targets, ["PLprivate-created", "PLprivate-created"])
    }

    func testExplicitCleanupRejectsAnotherScopeAndNeverUsesAChangedAccount() async throws {
        let store = await session()
        let transport = PlaylistProbeTransport(mode: .deletionUnconfirmed)
        let client = await client(transport, store: store)
        let scope = try await client.libraryEditScope()
        _ = try await client.checkPlaylistEdits(videoID: videoID)
        do { _ = try await client.retryPlaylistEditCleanup(expectedScope: UUID()); XCTFail("Expected original scope") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        await store.clear()
        let cleanup = try await client.retryPlaylistEditCleanup(expectedScope: scope)
        XCTAssertEqual(cleanup, .accountChanged)
        let pending = await client.hasPendingPlaylistEditCleanup()
        XCTAssertTrue(pending)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 7)
    }

    func testExplicitCleanupRequiresFreshDeletePermission() async throws {
        let transport = PlaylistProbeTransport(mode: .recoveryPermissionMissing)
        let client = await client(transport)
        let scope = try await client.libraryEditScope()
        _ = try await client.checkPlaylistEdits(videoID: videoID)
        let cleanup = try await client.retryPlaylistEditCleanup(expectedScope: scope)
        XCTAssertEqual(cleanup, .unconfirmed)
        let pending = await client.hasPendingPlaylistEditCleanup()
        XCTAssertTrue(pending)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 8)
        XCTAssertEqual(requests.last?.url?.path, "/youtubei/v1/browse")
        XCTAssertEqual(requests.filter { $0.url?.path == "/youtubei/v1/playlist/delete" }.count, 1)
    }

    func testReadbackMismatchStopsBeforeRemovalAndCleansThePlaylist() async throws {
        let transport = PlaylistProbeTransport(mode: .readMismatch)
        let report = try await client(transport).checkPlaylistEdits(videoID: videoID)
        XCTAssertEqual(report.status, .unexpectedResponse)
        XCTAssertEqual(report.steps.last?.step, .readAdded)
        XCTAssertEqual(report.steps.last?.occurrenceCount, 1)
        XCTAssertEqual(report.cleanup, .deleted)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 5)
    }

    func testMissingEditControlsPreventFurtherMutationsBeyondCleanup() async throws {
        let transport = PlaylistProbeTransport(mode: .permissionMissing)
        let report = try await client(transport).checkPlaylistEdits(videoID: videoID)
        XCTAssertEqual(report.status, .permissionUnavailable)
        XCTAssertEqual(report.steps.last?.step, .readAdded)
        XCTAssertEqual(report.cleanup, .deleted)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 5)
    }

    func testAccountChangePreventsCleanupFromUsingTheNewAccount() async throws {
        let store = await session()
        let transport = PlaylistProbeTransport(mode: .accountChange, store: store)
        let report = try await client(transport, store: store).checkPlaylistEdits(videoID: videoID)
        XCTAssertEqual(report.status, .accountChanged)
        XCTAssertEqual(report.cleanup, .accountChanged)
        XCTAssertTrue(report.cleanupNeeded)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains { $0.url?.path == "/youtubei/v1/playlist/delete" })
    }

    func testCallerCancellationStillRunsBoundedSameScopeCleanup() async throws {
        let transport = PlaylistProbeTransport(mode: .pauseRename)
        let client = await client(transport)
        let task = Task { try await client.checkPlaylistEdits(videoID: self.videoID) }
        await transport.waitForRename()
        task.cancel()
        let report = try await task.value
        XCTAssertEqual(report.status, .cancelled)
        XCTAssertEqual(report.cleanup, .deleted)
        XCTAssertFalse(report.cleanupNeeded)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testWorkloadDeadlineStillRunsCleanup() async throws {
        let transport = PlaylistProbeTransport(mode: .pauseRename)
        let report = try await client(transport).checkPlaylistEdits(videoID: videoID, timeout: .milliseconds(100))
        XCTAssertEqual(report.status, .timedOut)
        XCTAssertEqual(report.cleanup, .deleted)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testCleanupHasItsOwnDeadlineAndReportsAnUnconfirmedRemainingPlaylist() async throws {
        let transport = PlaylistProbeTransport(mode: .cleanupStall)
        let report = try await client(transport).checkPlaylistEdits(videoID: videoID)
        XCTAssertEqual(report.status, .accessDenied)
        XCTAssertEqual(report.cleanup, .timedOut)
        XCTAssertTrue(report.cleanupNeeded)
        XCTAssertTrue(report.uncertainOutcome)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.filter { $0.url?.path == "/youtubei/v1/playlist/delete" }.count, 1)
    }

    func testAccountChangeDuringCreationCannotClaimThereIsNothingToCleanUp() async throws {
        let store = await session()
        let transport = PlaylistProbeTransport(mode: .accountChangeDuringCreate, store: store)
        let report = try await client(transport, store: store).checkPlaylistEdits(videoID: videoID)
        XCTAssertEqual(report.status, .accountChanged)
        XCTAssertEqual(report.cleanup, .unavailable)
        XCTAssertTrue(report.cleanupNeeded)
        XCTAssertTrue(report.uncertainOutcome)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testOtherUserFacingWritesStayLockedDuringTheCheck() async throws {
        let transport = PlaylistProbeTransport(mode: .pauseRename)
        let client = await client(transport)
        let task = Task { try await client.checkPlaylistEdits(videoID: self.videoID) }
        await transport.waitForRename()
        do { _ = try await client.performLibraryEdit(.deletePlaylist(id: "PLpre-existing")); XCTFail("Expected check lock") }
        catch { XCTAssertEqual(error as? MusicLibraryEditError, .operationInProgress) }
        task.cancel()
        let report = try await task.value
        XCTAssertEqual(report.cleanup, .deleted)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testCapabilityInputAndOldScopeGuardsNeverSendRequests() async throws {
        let transport = PlaylistProbeTransport()
        let store = await session()
        let disabled = YouTubeMusicClient(transport: transport, sessions: store)
        do { _ = try await disabled.checkPlaylistEdits(videoID: videoID); XCTFail("Expected capability gate") }
        catch { XCTAssertEqual(error as? MusicLibraryEditError, .featureUnavailable) }
        let enabled = await client(transport, store: store)
        do { _ = try await enabled.checkPlaylistEdits(videoID: "short"); XCTFail("Expected exact ID validation") }
        catch { XCTAssertEqual(error as? MusicServiceError, .invalidInput) }
        do { _ = try await enabled.checkPlaylistEdits(videoID: videoID, timeout: .seconds(16)); XCTFail("Expected deadline bound") }
        catch { XCTAssertEqual(error as? MusicServiceError, .invalidInput) }
        do { _ = try await enabled.checkPlaylistEdits(videoID: videoID, expectedScope: UUID()); XCTFail("Expected account fence") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    private func client(_ transport: PlaylistProbeTransport, store: MusicSessionStore? = nil) async -> YouTubeMusicClient {
        let store = if let store { store } else { await session() }
        return YouTubeMusicClient(transport: transport, sessions: store, libraryEditCapabilities: .init(playlists: true))
    }

    private func session() async -> MusicSessionStore {
        let store = MusicSessionStore()
        await store.replaceSession(accountID: "private-account", cookieHeader: "fixture=value", sapisid: "fixture",
                                   configuration: MusicClientConfiguration(apiKey: "fixture", clientVersion: "fixture"))
        return store
    }

    private func object(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}

private actor PlaylistProbeTransport: MusicHTTPTransport {
    enum Mode: Sendable, Equatable {
        case normal, renameRejected, creationUnconfirmed, deletionUnconfirmed, readMismatch, permissionMissing
        case accountChange, pauseRename, cleanupStall, accountChangeDuringCreate
        case recoveryPermissionMissing
    }
    private let mode: Mode
    private let store: MusicSessionStore?
    private var title = "private-title"
    private var entries: [(String, String)] = []
    private var renameStarted = false
    private var deleteAttempts = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [URLRequest] = []

    init(mode: Mode = .normal, store: MusicSessionStore? = nil) { self.mode = mode; self.store = store }

    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        switch request.url?.path {
        case "/youtubei/v1/playlist/create":
            if mode == .accountChangeDuringCreate { await store?.clear() }
            return response(mode == .creationUnconfirmed ? ["responseContext": [:]] : ["playlistId": "PLprivate-created"])
        case "/youtubei/v1/playlist/delete":
            deleteAttempts += 1
            if mode == .cleanupStall { try await Task.sleep(for: .seconds(60)) }
            return response([Mode.deletionUnconfirmed, .recoveryPermissionMissing].contains(mode) && deleteAttempts == 1 ?
                ["responseContext": [:]] : ["status": "STATUS_SUCCEEDED"])
        case "/youtubei/v1/browse/edit_playlist":
            let actions = body["actions"] as? [[String: String]] ?? []
            switch actions.first?["action"] {
            case "ACTION_SET_PLAYLIST_NAME":
                renameStarted = true
                for waiter in waiters { waiter.resume() }
                waiters.removeAll()
                if mode == .pauseRename { try await Task.sleep(for: .seconds(60)) }
                if mode == .accountChange { await store?.clear() }
                if mode == .renameRejected || mode == .cleanupStall { return MusicHTTPResponse(data: Data(), statusCode: 403) }
                title = actions.first?["playlistName"] ?? title
                return response(["status": "STATUS_SUCCEEDED"])
            case "ACTION_ADD_VIDEO":
                entries = actions.enumerated().map { ($0.element["addedVideoId"] ?? "", $0.offset == 0 ? "private-first=" : "private-second=") }
                return response(["status": "STATUS_SUCCEEDED", "playlistEditResults": entries.map {
                    ["playlistEditVideoAddedResultData": ["videoId": $0.0, "setVideoId": $0.1]]
                }])
            case "ACTION_REMOVE_VIDEO":
                let removing = Set(actions.compactMap { $0["setVideoId"] })
                entries.removeAll { removing.contains($0.1) }
                return response(["status": "STATUS_SUCCEEDED"])
            default: throw URLError(.badServerResponse)
            }
        case "/youtubei/v1/browse":
            let rows = (mode == .readMismatch ? Array(entries.prefix(1)) : entries).map { videoID, occurrence in
                ["musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": videoID, "playlistSetVideoId": occurrence],
                    "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "private-song-title"]]]]]],
                ]]
            }
            let detail = ["musicDetailHeaderRenderer": ["title": ["runs": [["text": title]]]]]
            let hidePermission = mode == .permissionMissing || (mode == .recoveryPermissionMissing && deleteAttempts > 0)
            let header: [String: Any] = hidePermission ? detail : ["musicEditablePlaylistDetailHeaderRenderer": [
                "header": detail, "deletePlaylistEndpoint": ["playlistId": "PLprivate-created"],
            ]]
            return response(["header": header, "contents": ["sectionListRenderer": ["contents": [[
                "musicPlaylistShelfRenderer": ["contents": rows],
            ]]]]])
        default: throw URLError(.badServerResponse)
        }
    }

    func waitForRename() async {
        if renameStarted { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func response(_ body: [String: Any]) -> MusicHTTPResponse {
        MusicHTTPResponse(data: try! JSONSerialization.data(withJSONObject: body), statusCode: 200)
    }
}
