import Foundation
import XCTest
@testable import YouTubeMusic

@MainActor
final class MusicClientTests: XCTestCase {
    func testSearchKeepsOrderAndRemovesRepeatedContent() async throws {
        let transport = StubTransport([.response(try fixtureResponse("search_tabbed_mixed"))])
        let client = client(transport)
        let page = try await client.search(query: " example ")
        XCTAssertFalse(page.items.isEmpty)
        XCTAssertEqual(page.items.count, Set(page.items.map(\.id)).count)
        XCTAssertEqual(page.items.first?.id, "artist:UCtop-profile")
        let requests = await transport.requests
        let body = try body(requests[0])
        XCTAssertEqual(body["query"] as? String, "example")
        XCTAssertEqual(requests[0].url?.path, "/youtubei/v1/search")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
    }

    func testPlaylistPreservesSongOccurrencesAndIgnoresSuggestedShelf() async throws {
        let data = json(["contents": ["sectionListRenderer": ["contents": [
            ["musicPlaylistShelfRenderer": ["contents": [song("one"), song("one")]]],
            ["musicShelfRenderer": ["title": text("Suggestions"), "contents": [song("wrong")]]]
        ]]]])
        let page = try await client(StubTransport([.response(response(data))])).playlist(id: "PLexample")
        XCTAssertEqual(page.tracks.map(\.id), ["one", "one"])
    }

    func testEmptyPlaylistShelfIsAuthoritative() async throws {
        let data = json(["contents": ["sectionListRenderer": ["contents": [
            ["musicPlaylistShelfRenderer": ["contents": []]],
            ["musicShelfRenderer": ["contents": [song("wrong")]]]
        ]]]])
        let page = try await client(StubTransport([.response(response(data))])).playlist(id: "PLexample")
        XCTAssertTrue(page.items.isEmpty)
    }

    func testSearchContinuationUsesSearchEndpointAndDeduplicatesAcrossPages() async throws {
        let transport = StubTransport([.response(response(shelf(["one"], token: "page-two"))),
                                       .response(response(shelf(["one", "two"], continuation: true)))])
        let client = client(transport)
        let first = try await client.search(query: "example")
        let next = try await client.nextPage(XCTUnwrap(first.continuation))
        XCTAssertEqual(next.tracks.map(\.id), ["two"])
        XCTAssertNil(next.continuation)
        let requests = await transport.requests
        XCTAssertEqual(requests[1].url?.path, "/youtubei/v1/search")
        XCTAssertEqual(try body(requests[1])["continuation"] as? String, "page-two")
    }

    func testPlaylistContinuationPreservesRepeatedTrack() async throws {
        let transport = StubTransport([.response(response(shelf(["one"], token: "next"))),
                                       .response(response(shelf(["one"], continuation: true)))])
        let client = client(transport)
        let first = try await client.playlist(id: "PLexample")
        let next = try await client.nextPage(XCTUnwrap(first.continuation))
        XCTAssertEqual(next.tracks.map(\.id), ["one"])
    }

    func testLibraryItemSectionContinuationKeepsDistinctCollectionsAndDeduplicatesRepeatedIDs() async throws {
        func collection(_ id: String) -> [String: Any] {
            ["musicTwoRowItemRenderer": ["title": text("Same title"),
                "navigationEndpoint": ["browseEndpoint": ["browseId": id,
                    "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig":
                        ["pageType": "MUSIC_PAGE_TYPE_PLAYLIST"]]]]]]
        }
        let first = json(["contents": ["sectionListRenderer": ["contents": [["gridRenderer": [
            "items": [collection("VLfirst")], "continuations": [["nextContinuationData": ["continuation": "next"]]],
        ]]]]]])
        let second = json(["continuationContents": ["itemSectionContinuation": ["contents": [
            ["gridRenderer": ["items": [collection("VLfirst"), collection("VLsecond"), collection("VLsecond")]]],
            collection("VLthird"),
        ]]]])
        let store = MusicSessionStore()
        await setFixtureSession(store)
        let transport = StubTransport([.response(response(first)), .response(response(second))])
        let client = client(transport, sessions: store)
        let initial = try await client.library()
        let next = try await client.nextPage(XCTUnwrap(initial.continuation))
        XCTAssertEqual(next.items.map(\.id), ["playlist:VLsecond", "playlist:VLthird"])
        XCTAssertNil(next.continuation)
    }

    func testItemSectionContinuationPreservesPlaylistOccurrencesAndContinuationGuard() async throws {
        let continuation = json(["continuationContents": ["itemSectionContinuation": [
            "contents": [["musicPlaylistShelfRenderer": ["contents": [song("one"), song("one")]]]],
            "continuations": [["nextContinuationData": ["continuation": "third"]]],
        ]]])
        let repeated = json(["continuationContents": ["itemSectionContinuation": [
            "contents": [song("two")], "continuations": [["nextContinuationData": ["continuation": "third"]]],
        ]]])
        let transport = StubTransport([.response(response(shelf(["one"], token: "second"))),
            .response(response(continuation)), .response(response(repeated))])
        let client = client(transport)
        let initial = try await client.playlist(id: "PLexample")
        let next = try await client.nextPage(XCTUnwrap(initial.continuation))
        XCTAssertEqual(next.tracks.map(\.id), ["one", "one"])
        XCTAssertEqual(next.playlistItems.map(\.track.id), ["one", "one"])
        do { _ = try await client.nextPage(XCTUnwrap(next.continuation)); XCTFail("Expected pagination loop") }
        catch { XCTAssertEqual(error as? MusicServiceError, .paginationLoop) }
    }

    func testRepeatedContinuationStopsWithExplicitError() async throws {
        let transport = StubTransport([.response(response(shelf(["one"], token: "next"))),
                                       .response(response(shelf(["two"], token: "next", continuation: true)))])
        let client = client(transport)
        let page = try await client.search(query: "example")
        do { _ = try await client.nextPage(XCTUnwrap(page.continuation)); XCTFail("Expected pagination error") }
        catch { XCTAssertEqual(error as? MusicServiceError, .paginationLoop) }
    }

    func testFailedContinuationCanBeRetried() async throws {
        let transport = StubTransport([.response(response(shelf(["one"], token: "next"))), .failure(.notConnectedToInternet),
                                       .response(response(shelf(["two"], continuation: true)))])
        let client = client(transport)
        let page = try await client.search(query: "example")
        let continuation = try XCTUnwrap(page.continuation)
        do { _ = try await client.nextPage(continuation); XCTFail("Expected network error") }
        catch { XCTAssertEqual(error as? MusicServiceError, .network(.notConnectedToInternet)) }
        let next = try await client.nextPage(continuation)
        XCTAssertEqual(next.tracks.map(\.id), ["two"])
    }

    func testUnreadablePlaylistContinuationCanBeRetriedWithoutLosingOccurrences() async throws {
        let malformed = json(["continuationContents": ["musicPlaylistShelfContinuation": ["contents": [
            song("two"), ["continuationItemRenderer": ["continuationEndpoint": [String: Any]()]],
        ]]]])
        let transport = StubTransport([
            .response(response(shelf(["one", "one"], token: "next"))),
            .response(response(malformed)),
            .response(response(shelf(["one", "two"], continuation: true))),
        ])
        let client = client(transport)
        let first = try await client.playlist(id: "PLexample")
        let continuation = try XCTUnwrap(first.continuation)
        do { _ = try await client.nextPage(continuation); XCTFail("Expected unreadable cursor error") }
        catch { XCTAssertEqual(error as? MusicServiceError, .unsupportedResponse) }

        let next = try await client.nextPage(continuation)
        XCTAssertEqual(first.tracks.map(\.id), ["one", "one"])
        XCTAssertEqual(next.tracks.map(\.id), ["one", "two"])
        XCTAssertNil(next.continuation)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        for request in requests.dropFirst() {
            XCTAssertEqual(try body(request)["continuation"] as? String, "next")
        }
    }

    func testSessionChangeRejectsOldContinuationBeforeNetwork() async throws {
        let store = MusicSessionStore()
        await setFixtureSession(store)
        let transport = StubTransport([.response(response(shelf(["one"], token: "next")))])
        let client = client(transport, sessions: store)
        let page = try await client.library()
        await store.clear()
        do { _ = try await client.nextPage(XCTUnwrap(page.continuation)); XCTFail("Expected session error") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testSignOutFencesResponseAlreadyInFlight() async throws {
        let store = MusicSessionStore()
        await setFixtureSession(store)
        let transport = DeferredTransport()
        let client = client(transport, sessions: store)
        let task = Task { try await client.library() }
        await transport.waitUntilStarted()
        await store.clear()
        await transport.finish(response(shelf(["private-track"])))
        do { _ = try await task.value; XCTFail("Expected stale response rejection") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
    }

    func testCancellationRejectsEvenTransportThatIgnoresCancellation() async throws {
        let transport = DeferredTransport()
        let client = client(transport)
        let task = Task { try await client.home() }
        await transport.waitUntilStarted()
        task.cancel()
        await transport.finish(response(shelf(["one"])))
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLibraryRequiresSessionWithoutMakingRequest() async throws {
        let transport = StubTransport([])
        let client = client(transport)
        do { _ = try await client.likedSongs(); XCTFail("Expected sign in requirement") }
        catch { XCTAssertEqual(error as? MusicServiceError, .signInRequired) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testNetworkAndAccessFailuresNeverEraseSession() async throws {
        let cases: [(StubTransport.Step, MusicServiceError)] = [
            (.response(MusicHTTPResponse(data: Data(), statusCode: 401)), .authenticationRejected),
            (.response(MusicHTTPResponse(data: Data(), statusCode: 403)), .accessDenied),
            (.failure(.notConnectedToInternet), .network(.notConnectedToInternet))
        ]
        for (step, expected) in cases {
            let store = MusicSessionStore()
            await setFixtureSession(store)
            let initial = await store.snapshot()
            do { _ = try await client(StubTransport([step]), sessions: store).library(); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? MusicServiceError, expected) }
            let final = await store.snapshot()
            XCTAssertTrue(final.isAuthenticated)
            XCTAssertEqual(initial.scope, final.scope)
        }
    }

    func testTransientResponsesRetryWithinBound() async throws {
        let transport = StubTransport([
            .response(MusicHTTPResponse(data: Data(), statusCode: 503)),
            .response(MusicHTTPResponse(data: Data(), statusCode: 429, headers: ["Retry-After": "0"])),
            .response(response(shelf(["one"])))
        ])
        let page = try await client(transport).home()
        XCTAssertEqual(page.tracks.map(\.id), ["one"])
        let count = await transport.requests.count
        XCTAssertEqual(count, 3)
    }

    func testLongRetryAfterDoesNotTriggerEarlyRetry() async throws {
        let transport = StubTransport([.response(MusicHTTPResponse(data: Data(), statusCode: 429, headers: ["Retry-After": "120"]))])
        do { _ = try await client(transport).home(); XCTFail("Expected rate limit") }
        catch { XCTAssertEqual(error as? MusicServiceError, .rateLimited) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testRateLimitStopsAfterThreeAttempts() async throws {
        let step = StubTransport.Step.response(MusicHTTPResponse(data: Data(), statusCode: 429))
        let transport = StubTransport([step, step, step])
        do { _ = try await client(transport).home(); XCTFail("Expected rate limit") }
        catch { XCTAssertEqual(error as? MusicServiceError, .rateLimited) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 3)
    }

    func testAnonymousBootstrapDoesNotAttachCredentials() async throws {
        let bootstrap = Data(#"<script>ytcfg.set({"INNERTUBE_API_KEY":"fixture-key","INNERTUBE_CLIENT_VERSION":"fixture-version","VISITOR_DATA":"fixture-visitor"});</script>"#.utf8)
        let transport = StubTransport([.response(response(bootstrap)), .response(response(shelf(["one"])))])
        let store = MusicSessionStore()
        await store.replaceSession(accountID: "fixture-account", cookieHeader: "example=value", sapisid: "test-a")
        let client = client(transport, sessions: store)
        _ = try await client.library()
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(requests[0].httpShouldHandleCookies)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Cookie"), "example=value")
        XCTAssertTrue(requests[1].value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        XCTAssertFalse(requests[1].httpShouldHandleCookies)
    }

    func testBootstrapMissingConfigurationIsExplicitFailure() async throws {
        let transport = StubTransport([.response(response(Data("<html>Consent needed</html>".utf8)))])
        let client = YouTubeMusicClient(transport: transport, pause: { _ in })
        do { _ = try await client.home(); XCTFail("Expected configuration failure") }
        catch { XCTAssertEqual(error as? MusicServiceError, .configurationUnavailable) }
    }

    func testUnknownResponseDoesNotLookLikeEmptyLibrary() async throws {
        let transport = StubTransport([.response(response(Data("{\"newRenderer\":{}}".utf8)))])
        do { _ = try await client(transport).home(); XCTFail("Expected unsupported response") }
        catch { XCTAssertEqual(error as? MusicServiceError, .unsupportedResponse) }
    }

    func testUnchangedSessionDoesNotInvalidatePagination() async {
        let store = MusicSessionStore()
        await setFixtureSession(store)
        let first = await store.snapshot()
        await setFixtureSession(store)
        let second = await store.snapshot()
        XCTAssertEqual(first.scope, second.scope)
    }

    func testPreferenceCookieRefreshKeepsScopeWhileAuthenticationChangeFencesIt() async throws {
        let store = MusicSessionStore()
        await setFixtureSession(store)
        let first = await store.snapshot()
        try await store.refreshCredentials(cookieHeader: "example=value; preference=new", sapisid: "test-a")
        let refreshed = await store.snapshot()
        XCTAssertEqual(first.scope, refreshed.scope)
        try await store.refreshCredentials(cookieHeader: "example=changed", sapisid: "test-b")
        let changed = await store.snapshot()
        XCTAssertNotEqual(first.scope, changed.scope)
    }

    func testLateSessionReplacementCannotRestoreSignedOutAccount() async {
        let store = MusicSessionStore()
        await setFixtureSession(store)
        let captured = await store.snapshot()
        await store.clear()
        let accepted = await store.replaceSession(accountID: "fixture-account", cookieHeader: "example=old", sapisid: "test-a",
                                                 configuration: fixtureConfiguration, expectedScope: captured.scope)
        let final = await store.snapshot()
        XCTAssertFalse(accepted)
        XCTAssertFalse(final.isAuthenticated)
    }

    func testLateCookieRefreshCannotOverwriteAnotherAccount() async throws {
        let store = MusicSessionStore()
        await setFixtureSession(store)
        let captured = await store.snapshot()
        await store.replaceSession(accountID: "other-fixture-account", cookieHeader: "example=new", sapisid: "test-c",
                                   configuration: fixtureConfiguration)
        let accepted = try await store.refreshCredentials(cookieHeader: "example=old", sapisid: "test-a",
                                                         expectedScope: captured.scope)
        let final = await store.snapshot()
        XCTAssertFalse(accepted)
        XCTAssertEqual(final.accountID, "other-fixture-account")
        XCTAssertEqual(final.cookieHeader, "example=new")
    }

    func testLateConditionalClearCannotEraseAnotherAccount() async {
        let store = MusicSessionStore()
        await setFixtureSession(store)
        let captured = await store.snapshot()
        await store.replaceSession(accountID: "other-fixture-account", cookieHeader: "example=new", sapisid: "test-c")
        let accepted = await store.clear(expectedScope: captured.scope)
        let final = await store.snapshot()
        XCTAssertFalse(accepted)
        XCTAssertEqual(final.accountID, "other-fixture-account")
    }

    func testConditionalPreferenceRefreshKeepsScope() async throws {
        let store = MusicSessionStore()
        await setFixtureSession(store)
        let captured = await store.snapshot()
        let accepted = try await store.refreshCredentials(cookieHeader: "example=value; preference=new", sapisid: "test-a",
                                                         expectedScope: captured.scope)
        let final = await store.snapshot()
        XCTAssertTrue(accepted)
        XCTAssertEqual(final.scope, captured.scope)
    }

    func testCancelledCredentialUpdateIsRejected() async {
        let store = MusicSessionStore()
        let captured = await store.snapshot()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.replaceSession(accountID: "fixture-account", cookieHeader: "example=value", sapisid: "test-a",
                                              expectedScope: captured.scope)
        }
        let accepted = await task.value
        let final = await store.snapshot()
        XCTAssertFalse(accepted)
        XCTAssertFalse(final.isAuthenticated)
    }

    func testCancelledSignOutStillClearsSession() async {
        let store = MusicSessionStore()
        await setFixtureSession(store)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.clear()
        }
        let accepted = await task.value
        let final = await store.snapshot()
        XCTAssertTrue(accepted)
        XCTAssertFalse(final.isAuthenticated)
    }

    func testAllPagesLimitIsExplicit() async throws {
        let transport = StubTransport([.response(response(shelf(["one"], token: "next")))])
        let client = client(transport)
        let first = try await client.home()
        do { _ = try await client.allPages(startingWith: first, maximumPages: 1); XCTFail("Expected limit") }
        catch { XCTAssertEqual(error as? MusicServiceError, .pageLimitReached) }
    }

    func testBrowseIdentifiersMatchRecordedRequests() async throws {
        let transport = StubTransport(Array(repeating: .response(response(shelf([]))), count: 4))
        let store = MusicSessionStore()
        await setFixtureSession(store)
        let client = client(transport, sessions: store)
        _ = try await client.likedSongs()
        _ = try await client.playlist(id: "OLAKexample")
        _ = try await client.album(id: "MPREexample")
        _ = try await client.library(category: .artists)
        let bodies = try await transport.requests.map(body)
        XCTAssertEqual(bodies.compactMap { $0["browseId"] as? String }, ["VLLM", "VLOLAKexample", "MPREexample", "FEmusic_library_corpus_artists"])
        XCTAssertEqual(bodies[3]["params"] as? String, "ggMCCAU=")
    }

    private func client(_ transport: any MusicHTTPTransport, sessions: (any MusicSessionProviding)? = nil) -> YouTubeMusicClient {
        YouTubeMusicClient(transport: transport, sessions: sessions ?? FixedSession(), pause: { _ in })
    }
    private func setFixtureSession(_ store: MusicSessionStore) async {
        await store.replaceSession(accountID: "fixture-account", cookieHeader: "example=value", sapisid: "test-a", configuration: fixtureConfiguration)
    }
}

private let fixtureConfiguration = MusicClientConfiguration(apiKey: "fixture-key", clientVersion: "fixture-version")
private struct FixedSession: MusicSessionProviding {
    let value = MusicSession(scope: UUID(), configuration: fixtureConfiguration)
    func snapshot() async -> MusicSession { value }
}
private actor StubTransport: MusicHTTPTransport {
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
private actor DeferredTransport: MusicHTTPTransport {
    private var pending: CheckedContinuation<MusicHTTPResponse, any Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            for waiter in startWaiters { waiter.resume() }
            startWaiters.removeAll()
        }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func finish(_ response: MusicHTTPResponse) { pending?.resume(returning: response); pending = nil }
}

func fixtureResponse(_ name: String) throws -> MusicHTTPResponse {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
    return response(try Data(contentsOf: url))
}
private func response(_ data: Data) -> MusicHTTPResponse { MusicHTTPResponse(data: data, statusCode: 200) }
private func body(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
}
private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
private func text(_ value: String) -> [String: Any] { ["runs": [["text": value]]] }
private func song(_ id: String) -> [String: Any] {
    ["musicResponsiveListItemRenderer": ["playlistItemData": ["videoId": id],
        "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": text("Title " + id)]]]]]
}
private func shelf(_ ids: [String], token: String? = nil, continuation: Bool = false) -> Data {
    var shelf: [String: Any] = ["contents": ids.map(song)]
    if let token { shelf["continuations"] = [["nextContinuationData": ["continuation": token]]] }
    if continuation { return json(["continuationContents": ["musicShelfContinuation": shelf]]) }
    return json(["contents": ["sectionListRenderer": ["contents": [["musicShelfRenderer": shelf]]]]])
}
