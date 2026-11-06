import Foundation
import XCTest
@testable import YouTubeMusic

@MainActor
final class MusicLibraryEditTests: XCTestCase {
    func testUIDispatchCannotBypassTheDisabledFeature() async throws {
        let transport = EditTransport([])
        let client = await makeClient(transport)
        do {
            _ = try await client.performLibraryEdit(.setLiked(videoID: "song", liked: true))
            XCTFail("Expected disabled capability")
        } catch { XCTAssertEqual(error as? MusicLibraryEditError, .featureUnavailable) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testDispatcherRejectsOverlappingSubmissionsUntilOutcomeArrives() async throws {
        let transport = DeferredEditTransport()
        let client = await makeClient(transport)
        let first = Task { try await client.executeLibraryEdit(.setLiked(videoID: "song", liked: true)) }
        await transport.waitUntilStarted()
        do {
            _ = try await client.executeLibraryEdit(.deletePlaylist(id: "PLexample"))
            XCTFail("Expected in-flight operation guard")
        } catch { XCTAssertEqual(error as? MusicLibraryEditError, .operationInProgress) }
        await transport.finish(confirmed())
        let result = try await first.value
        XCTAssertEqual(result, .liked(videoID: "song", isLiked: true))
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testUnconfirmedOutcomeReleasesTheDispatcherWithoutRetrying() async throws {
        let transport = EditTransport([.failure(.networkConnectionLost), .response(confirmed())])
        let client = await makeClient(transport)
        do {
            _ = try await client.executeLibraryEdit(.renamePlaylist(id: "PLexample", title: "New title"))
            XCTFail("Expected uncertain result")
        } catch { XCTAssertEqual(error as? MusicLibraryEditError, .unconfirmedOutcome) }
        let countBeforeExplicitAction = await transport.requests.count
        XCTAssertEqual(countBeforeExplicitAction, 1)
        let result = try await client.executeLibraryEdit(.setLiked(videoID: "song", liked: true))
        XCTAssertEqual(result, .liked(videoID: "song", isLiked: true))
    }

    func testLikesAndUnlikesUseAuthenticatedRequests() async throws {
        let transport = EditTransport([.response(confirmed()), .response(confirmed())])
        let client = await makeClient(transport)
        let liked = try await client.setLiked(true, videoID: "song")
        let unliked = try await client.setLiked(false, videoID: "song")
        XCTAssertEqual(liked, .liked(videoID: "song", isLiked: true))
        XCTAssertEqual(unliked, .liked(videoID: "song", isLiked: false))
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/youtubei/v1/like/like", "/youtubei/v1/like/removelike"])
        XCTAssertEqual(try body(requests[0])["target"] as? [String: String], ["videoId": "song"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cookie"), "fixture=value")
        XCTAssertTrue(requests[0].value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        XCTAssertFalse(requests[0].httpShouldHandleCookies)
        XCTAssertFalse(client.supportsRemoteLibraryEdits)
    }

    func testSignedOutEditsNeverSendARequest() async {
        let transport = EditTransport([])
        let client = YouTubeMusicClient(transport: transport)
        do { _ = try await client.deletePlaylist(id: "PLexample"); XCTFail("Expected sign-in requirement") }
        catch { XCTAssertEqual(error as? MusicServiceError, .signInRequired) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCreationDefaultsToPrivateAndRequiresReturnedID() async throws {
        let transport = EditTransport([.response(response(["playlistId": "PLcreated"]))])
        let client = await makeClient(transport)
        let result = try await client.createPlaylist(title: "  A \"quoted\" title  ", description: "First\nSecond", videoIDs: ["one", "two"])
        XCTAssertEqual(result, .playlistCreated(id: "PLcreated"))
        let requests = await transport.requests
        let sent = try body(requests[0])
        XCTAssertEqual(sent["privacyStatus"] as? String, "PRIVATE")
        XCTAssertEqual(sent["title"] as? String, "A \"quoted\" title")
        XCTAssertEqual(sent["description"] as? String, "First\nSecond")
        XCTAssertEqual(sent["videoIds"] as? [String], ["one", "two"])
    }

    func testRenameAndDeleteNormalizeTheBrowsePrefix() async throws {
        let transport = EditTransport([.response(confirmed()), .response(confirmed())])
        let client = await makeClient(transport)
        let renamed = try await client.renamePlaylist(id: "VLPLexample", title: "Renamed")
        let deleted = try await client.deletePlaylist(id: "VLPLexample")
        XCTAssertEqual(renamed, .playlistRenamed(id: "PLexample", title: "Renamed"))
        XCTAssertEqual(deleted, .playlistDeleted(id: "PLexample"))
        let requests = await transport.requests
        XCTAssertEqual(try body(requests[0])["actions"] as? [[String: String]], [["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": "Renamed"]])
        XCTAssertEqual(try body(requests[1])["playlistId"] as? String, "PLexample")
    }

    func testAddedDuplicatesRetainSeparateServiceOccurrences() async throws {
        let transport = EditTransport([.response(added([("same", "first="), ("same", "second=")]))])
        let client = await makeClient(transport)
        let result = try await client.addPlaylistItems(playlistID: "PLexample", videoIDs: ["same", "same"], allowDuplicates: true)
        XCTAssertEqual(result, .itemsAdded(playlistID: "PLexample", items: [
            PlaylistItemReference(videoID: "same", setVideoID: "first="),
            PlaylistItemReference(videoID: "same", setVideoID: "second="),
        ]))
        let requests = await transport.requests
        let actions = try XCTUnwrap(body(requests[0])["actions"] as? [[String: String]])
        XCTAssertEqual(actions.map { $0["dedupeOption"] }, ["DEDUPE_OPTION_SKIP", "DEDUPE_OPTION_SKIP"])
    }

    func testRemovingADuplicateUsesTheSelectedOccurrence() async throws {
        let transport = EditTransport([.response(confirmed())])
        let client = await makeClient(transport)
        let reference = PlaylistItemReference(videoID: "same", setVideoID: "second=")
        let result = try await client.removePlaylistItems(playlistID: "PLexample", items: [reference])
        XCTAssertEqual(result, .itemsRemoved(playlistID: "PLexample", items: [reference]))
        let requests = await transport.requests
        XCTAssertEqual(try body(requests[0])["actions"] as? [[String: String]], [
            ["action": "ACTION_REMOVE_VIDEO", "removedVideoId": "same", "setVideoId": "second="],
        ])
    }

    func testMissingOrRepeatedOccurrenceIDsNeverSendARemoval() async {
        let transport = EditTransport([])
        let client = await makeClient(transport)
        let cases = [
            [PlaylistItemReference(videoID: "song", setVideoID: "")],
            [PlaylistItemReference(videoID: "one", setVideoID: "same"), PlaylistItemReference(videoID: "two", setVideoID: "same")],
        ]
        for items in cases {
            do { _ = try await client.removePlaylistItems(playlistID: "PLexample", items: items); XCTFail("Expected occurrence validation") }
            catch { XCTAssertEqual(error as? MusicLibraryEditError, .invalidPlaylistItems) }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testAddingDuplicatesRequiresExplicitOptIn() async {
        let transport = EditTransport([])
        let client = await makeClient(transport)
        do { _ = try await client.addPlaylistItems(playlistID: "PLexample", videoIDs: ["same", "same"]); XCTFail("Expected duplicate validation") }
        catch { XCTAssertEqual(error as? MusicLibraryEditError, .invalidPlaylistItems) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testPartialOrAmbiguousAddedResultsDoNotClaimSuccess() async {
        let responses = [confirmed(), added([("one", "entry")]), added([("one", "same"), ("two", "same")]), added([("wrong", "first"), ("two", "second")])]
        for response in responses {
            let client = await makeClient(EditTransport([.response(response)]))
            do { _ = try await client.addPlaylistItems(playlistID: "PLexample", videoIDs: ["one", "two"]); XCTFail("Expected unconfirmed outcome") }
            catch { XCTAssertEqual(error as? MusicLibraryEditError, .unconfirmedOutcome) }
        }
    }

    func testHTTP200ErrorsAndAccountDialogsAreNotSuccess() async {
        let cases: [(MusicHTTPResponse, MusicLibraryEditError)] = [
            (response(["error": ["code": 403]]), .serviceRejected),
            (response(["status": "STATUS_FAILED"]), .serviceRejected),
            (response(["status": "STATUS_SUCCEEDED", "alerts": [["alertRenderer": ["type": "ERROR"]]]]), .serviceRejected),
            (response(["actions": [["showEngagementPanelEndpoint": ["identifier": ["tag": "account-action"]]]]]), .interactionRequired),
        ]
        for (response, expected) in cases {
            let client = await makeClient(EditTransport([.response(response)]))
            do { _ = try await client.renamePlaylist(id: "PLexample", title: "Renamed"); XCTFail("Expected service rejection") }
            catch { XCTAssertEqual(error as? MusicLibraryEditError, expected) }
        }
    }

    func testAResponseWithoutConfirmationIsNotSuccess() async {
        for response in [response(["responseContext": [:]]), MusicHTTPResponse(data: Data(), statusCode: 204)] {
            let client = await makeClient(EditTransport([.response(response)]))
            do { _ = try await client.setLiked(true, videoID: "song"); XCTFail("Expected unconfirmed outcome") }
            catch { XCTAssertEqual(error as? MusicLibraryEditError, .unconfirmedOutcome) }
        }
    }

    func testWritesDoNotRetryAfterTimeoutServerErrorOrRateLimit() async {
        let cases: [EditTransport.Step] = [
            .failure(.timedOut), .failure(.networkConnectionLost),
            .response(MusicHTTPResponse(data: Data(), statusCode: 503)),
            .response(MusicHTTPResponse(data: Data(), statusCode: 429, headers: ["Retry-After": "0"])),
        ]
        for step in cases {
            let transport = EditTransport([step, .response(confirmed())])
            let store = await authenticatedStore()
            let initial = await store.snapshot()
            let client = YouTubeMusicClient(transport: transport, sessions: store, pause: { _ in XCTFail("A write must not retry") })
            do { _ = try await client.deletePlaylist(id: "PLexample"); XCTFail("Expected failure") }
            catch { XCTAssertTrue(error is MusicLibraryEditError || error is MusicServiceError) }
            let requests = await transport.requests
            let final = await store.snapshot()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(final.scope, initial.scope)
            XCTAssertTrue(final.isAuthenticated)
        }
    }

    func testSignOutFencesAnInFlightWriteResponse() async throws {
        let transport = DeferredEditTransport()
        let store = await authenticatedStore()
        let client = YouTubeMusicClient(transport: transport, sessions: store)
        let task = Task { try await client.deletePlaylist(id: "PLexample") }
        await transport.waitUntilStarted()
        await store.clear()
        await transport.finish(confirmed())
        do { _ = try await task.value; XCTFail("Expected account fence") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
    }

    func testSignOutDuringBootstrapPreventsTheWrite() async throws {
        let transport = DeferredEditTransport()
        let store = await authenticatedStore(configuration: nil)
        let client = YouTubeMusicClient(transport: transport, sessions: store)
        let task = Task { try await client.deletePlaylist(id: "PLexample") }
        await transport.waitUntilStarted()
        await store.clear()
        await transport.finish(MusicHTTPResponse(data: Data(#"<script>{"INNERTUBE_API_KEY":"fixture","INNERTUBE_CLIENT_VERSION":"fixture"}</script>"#.utf8), statusCode: 200))
        do { _ = try await task.value; XCTFail("Expected account fence") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    }

    func testCancellationDiscardsAnInFlightConfirmation() async {
        let transport = DeferredEditTransport()
        let client = await makeClient(transport)
        let task = Task { try await client.deletePlaylist(id: "PLexample") }
        await transport.waitUntilStarted()
        task.cancel()
        await transport.finish(confirmed())
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testInvalidPlaylistTitleCannotMakeARequest() async {
        let transport = EditTransport([])
        let client = await makeClient(transport)
        for title in [" ", "<title>", "A\u{0000}B", String(repeating: "x", count: 151)] {
            do { _ = try await client.createPlaylist(title: title); XCTFail("Expected title validation") }
            catch { XCTAssertEqual(error as? MusicLibraryEditError, .invalidTitle) }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCreationCannotSucceedWithOnlyAStatusOrAnInvalidID() async {
        for response in [confirmed(), response(["playlistId": "not an id"]), response(["playlistId": "PLexample", "status": "STATUS_FAILED"])] {
            let client = await makeClient(EditTransport([.response(response)]))
            do { _ = try await client.createPlaylist(title: "Title"); XCTFail("Expected no confirmed playlist") }
            catch { XCTAssertTrue(error is MusicLibraryEditError) }
        }
    }

    func testPlaylistRowsPreserveDuplicateOccurrencesAndMissingIdentifiers() async throws {
        let transport = EditTransport([.response(playlistRows([
            playlistRow("same", setVideoID: "first="),
            playlistRow("same", setVideoID: "second="),
            playlistRow("without-occurrence"),
        ]))])
        let page = try await makeClient(transport).playlist(id: "PLexample")
        XCTAssertEqual(page.playlistItems.map(\.track.id), ["same", "same", "without-occurrence"])
        XCTAssertEqual(page.playlistItems.map(\.setVideoID), ["first=", "second=", nil])
        XCTAssertNil(page.playlistItems[2].removalReference)
        XCTAssertEqual(page.playlistItems[1].removalReference, PlaylistItemReference(videoID: "same", setVideoID: "second="))
    }

    func testPlaylistMenuFallbackMustMatchTheRowsSong() async throws {
        func row(removalVideoID: String) -> [String: Any] {
            var row = playlistRow("song")
            var renderer = row["musicResponsiveListItemRenderer"] as! [String: Any]
            renderer["menu"] = ["menuRenderer": ["items": [["menuServiceItemRenderer": [
                "serviceEndpoint": ["playlistEditEndpoint": ["actions": [[
                    "action": "ACTION_REMOVE_VIDEO", "removedVideoId": removalVideoID, "setVideoId": "occurrence=",
                ]]]],
            ]]]]]
            row["musicResponsiveListItemRenderer"] = renderer
            return row
        }
        let transport = EditTransport([.response(playlistRows([row(removalVideoID: "song"), row(removalVideoID: "different")]))])
        let page = try await makeClient(transport).playlist(id: "PLexample")
        XCTAssertEqual(page.playlistItems.map(\.setVideoID), ["occurrence=", nil])
    }

    func testContinuationKeepsNewServiceOccurrencesOfTheSameSong() async throws {
        let first = playlistRows([playlistRow("same", setVideoID: "first=")], continuationToken: "next-page")
        let second = response(["onResponseReceivedActions": [["appendContinuationItemsAction": [
            "continuationItems": [playlistRow("same", setVideoID: "second=")],
        ]]]])
        let client = await makeClient(EditTransport([.response(first), .response(second)]))
        let firstPage = try await client.playlist(id: "PLexample")
        let continuation = try XCTUnwrap(firstPage.continuation)
        let nextPage = try await client.nextPage(continuation)
        XCTAssertEqual(firstPage.playlistItems.map(\.setVideoID), ["first="])
        XCTAssertEqual(nextPage.playlistItems.map(\.setVideoID), ["second="])
    }

    func testSearchDoesNotAttachPlaylistMembershipToGlobalTracks() async throws {
        let client = await makeClient(EditTransport([.response(playlistRows([playlistRow("song", setVideoID: "entry=")]))]))
        let page = try await client.search(query: "song")
        XCTAssertEqual(page.tracks.map(\.id), ["song"])
        XCTAssertTrue(page.playlistItems.isEmpty)
    }

    private func makeClient(_ transport: any MusicHTTPTransport) async -> YouTubeMusicClient {
        YouTubeMusicClient(transport: transport, sessions: await authenticatedStore())
    }

    private func authenticatedStore(configuration: MusicClientConfiguration? = MusicClientConfiguration(apiKey: "fixture", clientVersion: "fixture")) async -> MusicSessionStore {
        let store = MusicSessionStore()
        await store.replaceSession(accountID: "fixture-account", cookieHeader: "fixture=value", sapisid: "fixture-secret", configuration: configuration)
        return store
    }
}

private actor EditTransport: MusicHTTPTransport {
    enum Step: Sendable { case response(MusicHTTPResponse), failure(URLError.Code) }
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        switch steps.removeFirst() {
        case let .response(response): return response
        case let .failure(code): throw URLError(code)
        }
    }
}

private actor DeferredEditTransport: MusicHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var pending: CheckedContinuation<MusicHTTPResponse, any Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish(_ response: MusicHTTPResponse) { pending?.resume(returning: response); pending = nil }
}

private func body(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
}
private func response(_ object: [String: Any]) -> MusicHTTPResponse {
    MusicHTTPResponse(data: try! JSONSerialization.data(withJSONObject: object), statusCode: 200)
}
private func confirmed() -> MusicHTTPResponse { response(["status": "STATUS_SUCCEEDED"]) }
private func added(_ items: [(String, String)]) -> MusicHTTPResponse {
    response(["status": "STATUS_SUCCEEDED", "playlistEditResults": items.map {
        ["playlistEditVideoAddedResultData": ["videoId": $0.0, "setVideoId": $0.1]]
    }])
}
private func playlistRow(_ videoID: String, setVideoID: String? = nil) -> [String: Any] {
    var item = ["videoId": videoID]
    if let setVideoID { item["playlistSetVideoId"] = setVideoID }
    return ["musicResponsiveListItemRenderer": [
        "playlistItemData": item,
        "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Song"]]]]]],
    ]]
}
private func playlistRows(_ rows: [[String: Any]], continuationToken: String? = nil) -> MusicHTTPResponse {
    var shelf: [String: Any] = ["contents": rows]
    if let continuationToken { shelf["continuations"] = [["nextContinuationData": ["continuation": continuationToken]]] }
    return response(["contents": ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": shelf]]]]])
}
