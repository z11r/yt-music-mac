import Foundation
import MusicCore
import XCTest
@testable import YouTubeMusic

@MainActor final class MusicLibrarySearchTests: XCTestCase {
    func testEveryOfferedCategoryHasExactLibraryParamsAndStructuralResults() async throws {
        let transport = LibrarySearchHTTP(try MusicLibrarySearchFilter.allCases.map { try libraryFixture($0) })
        let store = await libraryCredentials(), client = YouTubeMusicClient(transport: transport, sessions: store)
        let scope = await store.snapshot().scope
        var pages: [MusicPage] = []
        for filter in MusicLibrarySearchFilter.allCases { pages.append(try await client.searchLibrary(query: "  Björk 中文  ", filter: filter, expectedScope: scope)) }
        let requests = await transport.requests
        XCTAssertEqual(try requests.map { try requestBody($0)["params"] as? String }, [
            "EgWKAQIIAWoKEAUQCRADEAoYBA%3D%3D", "EgWKAQIQAWoKEAUQCRADEAoYBA%3D%3D",
            "EgWKAQIYAWoKEAUQCRADEAoYBA%3D%3D", "EgWKAQIgAWoKEAUQCRADEAoYBA%3D%3D",
            "EgWKAQIoAWoKEAUQCRADEAoYBA%3D%3D", "EgWKAQJQAWoKEAUQCRADEAoYBA%3D%3D", "EgWKAQJIAWoKEAUQCRADEAoYBA%3D%3D"])
        XCTAssertTrue(try requests.allSatisfy { try requestBody($0)["query"] as? String == "Björk 中文" })
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/youtubei/v1/search" && $0.httpMethod == "POST" })
        XCTAssertEqual(pages[0].tracks.first?.contentKind, .song)
        XCTAssertEqual(pages[1].tracks.first?.contentKind, .song)
        for (index, kind) in [(2, MusicCollection.Kind.album), (3, .artist), (4, .playlist), (5, .podcast)] {
            guard case let .collection(value) = pages[index].items.first else { return XCTFail("Expected structural collection") }
            XCTAssertEqual(value.kind, kind)
        }
        XCTAssertEqual(pages[6].tracks.first?.contentKind, .podcastEpisode)
        XCTAssertNil(pages[0].tracks.first?.origin, "A library filter does not establish catalog provenance")
    }

    func testAnonymousStaleInvalidAndCanceledReadsNeverBootstrapOrSendHTTP() async throws {
        let transport = LibrarySearchHTTP([]), empty = MusicSessionStore()
        let client = YouTubeMusicClient(transport: transport, sessions: empty)
        let scope = await empty.snapshot().scope
        await expect(.signInRequired) { try await client.searchLibrary(query: "private", filter: .songs, expectedScope: scope) }
        let store = await libraryCredentials(), signed = YouTubeMusicClient(transport: transport, sessions: store)
        await expect(.sessionChanged) { try await signed.searchLibrary(query: "private", filter: .songs, expectedScope: UUID()) }
        let current = await store.snapshot().scope
        for text in ["", "\n ", "a\tb", "a\0b", String(repeating: "x", count: 501)] {
            await expect(.invalidInput) { try await signed.searchLibrary(query: text, filter: .songs, expectedScope: current) }
        }
        let canceled = Task { try await signed.searchLibrary(query: "private", filter: .songs, expectedScope: current) }
        canceled.cancel()
        do { _ = try await canceled.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let attempts = await transport.requests
        XCTAssertTrue(attempts.isEmpty)
    }

    func testAmbiguousTabsUploadsAndWrongContinuationContainersAreRejected() async throws {
        let row = libraryRow(.songs)
        let content: [String: Any] = ["sectionListRenderer": ["contents": [["musicShelfRenderer": ["contents": [row]]]]]]
        let tab: [String: Any] = ["tabRenderer": ["content": content]]
        let multi: [String: Any] = ["contents": ["tabbedSearchResultsRenderer": ["tabs": [tab, tab, tab]]]]
        let uploaded: [String: Any] = ["musicTwoRowItemRenderer": ["title": ["runs": [["text": "Privé"]]],
            "navigationEndpoint": ["browseEndpoint": ["browseId": "FEmusic_library_privately_owned_release_detailABC"]]]]
        var privateRow = libraryRow(.songs)
        var renderer = privateRow["musicResponsiveListItemRenderer"] as! [String: Any]
        renderer["menu"] = ["musicDeletePrivatelyOwnedEntityCommand": ["entityId": "private-fixture"]]
        privateRow["musicResponsiveListItemRenderer"] = renderer
        for object in [multi, libraryShelf([uploaded]), libraryShelf([privateRow]), ["contents": ["twoColumnBrowseResultsRenderer": [:]]]] {
            let transport = LibrarySearchHTTP([try libraryResponse(object)]), store = await libraryCredentials()
            let client = YouTubeMusicClient(transport: transport, sessions: store)
            await expect(.unsupportedResponse) { try await client.searchLibrary(query: "x", filter: .albums, expectedScope: await store.snapshot().scope) }
        }
        XCTAssertThrowsError(try MusicLibrarySearchAdapter.prepare(libraryResponse(["continuationContents": ["musicPlaylistShelfContinuation": ["contents": []]]]).data, continuation: true))
        XCTAssertThrowsError(try MusicLibrarySearchAdapter.prepare(Data("unrecognized private response".utf8), continuation: false)) { error in
            XCTAssertEqual(error as? MusicServiceError, .invalidResponse)
        }
    }

    func testCredentialRevocationBeforeConfigurationBootstrapSendsNothing() async throws {
        let transport = LibrarySearchHTTP([])
        let original = MusicSession(scope: UUID(), accountID: String(repeating: "a", count: 64), cookieHeader: "fixture=1", sapisid: "fixture")
        let sessions = LibraryChangingSession(original)
        let client = YouTubeMusicClient(transport: transport, sessions: sessions)
        await expect(.sessionChanged) { try await client.searchLibrary(query: "private", filter: .songs, expectedScope: original.scope) }
        let attempts = await transport.requests
        XCTAssertTrue(attempts.isEmpty)
    }

    func testContinuationRetainsQueryParamsAuthScopeAndExplicitRetryIdentity() async throws {
        let first = try libraryResponse(libraryShelf([libraryRow(.songs)], token: "opaque-next"))
        let later = try libraryResponse(["continuationContents": ["musicShelfContinuation": ["contents": [libraryRow(.songs), libraryRow(.songs, id: "xyzABC98_-7")]]]])
        let transport = LibrarySearchHTTP([first, .init(data: Data(), statusCode: 403), later]), store = await libraryCredentials()
        let client = YouTubeMusicClient(transport: transport, sessions: store)
        let page = try await client.searchLibrary(query: "école", filter: .songs, expectedScope: await store.snapshot().scope)
        let token = try XCTUnwrap(page.continuation)
        await expect(.accessDenied) { try await client.nextPage(token) }
        let next = try await client.nextPage(token)
        XCTAssertEqual(next.tracks.map(\.id), ["xyzABC98_-7"])
        let requests = await transport.requests
        XCTAssertEqual(requests[1].httpBody, requests[2].httpBody)
        XCTAssertEqual(try requestBody(requests[1])["query"] as? String, "école")
        XCTAssertEqual(try requestBody(requests[1])["params"] as? String, MusicLibrarySearchFilter.songs.params)
        XCTAssertNil(try requestBody(requests[1])["continuation"])
        let query = URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.filter { ["ctoken", "continuation"].contains($0.name) }.map(\.value), ["opaque-next", "opaque-next"])
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Cookie"), "fixture=1")
        await store.clear()
        await expect(.sessionChanged) { try await client.nextPage(token) }
        let finalRequests = await transport.requests
        XCTAssertEqual(finalRequests.count, 3)
    }

    func testLoopsAndExcessiveRowsNeverReturnAnUnboundedPage() async throws {
        let response = try libraryResponse(libraryShelf([libraryRow(.songs)], token: "same"))
        let second = try libraryResponse(["continuationContents": ["musicShelfContinuation": ["contents": [], "continuations": [["nextContinuationData": ["continuation": "same"]]]]]])
        let transport = LibrarySearchHTTP([response, second]), store = await libraryCredentials()
        let client = YouTubeMusicClient(transport: transport, sessions: store)
        let page = try await client.searchLibrary(query: "x", filter: .songs, expectedScope: await store.snapshot().scope)
        await expect(.paginationLoop) { try await client.nextPage(try XCTUnwrap(page.continuation)) }
        let oversized = try libraryResponse(libraryShelf(Array(repeating: libraryRow(.songs), count: 1_001)))
        XCTAssertThrowsError(try MusicLibrarySearchAdapter.prepare(oversized.data, continuation: false))
    }

    func testFilterAndTranslatedShelfLabelsNeverFabricateMusicKind() async throws {
        let object = libraryShelf([["musicResponsiveListItemRenderer": ["playlistItemData": ["videoId": "abcDEF12_-3"],
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "未知の録音"]]]]]]]]])
        let transport = LibrarySearchHTTP([try libraryResponse(object)]), store = await libraryCredentials()
        let page = try await YouTubeMusicClient(transport: transport, sessions: store).searchLibrary(query: "x", filter: .songs, expectedScope: await store.snapshot().scope)
        XCTAssertNil(page.tracks.first?.contentKind); XCTAssertNil(page.tracks.first?.origin)
    }
    private func expect(_ error: MusicServiceError, operation: () async throws -> MusicPage) async {
        do { _ = try await operation(); XCTFail("Expected \(error)") } catch let actual { XCTAssertEqual(actual as? MusicServiceError, error) }
    }
}

private actor LibrarySearchHTTP: MusicHTTPTransport {
    private var replies: [MusicHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [MusicHTTPResponse]) { self.replies = replies }
    func send(_ request: URLRequest) throws -> MusicHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        return replies.removeFirst()
    }
}
private actor LibraryChangingSession: MusicSessionProviding {
    let original: MusicSession
    private var calls = 0
    init(_ original: MusicSession) { self.original = original }
    func snapshot() -> MusicSession {
        calls += 1
        return calls == 1 ? original : MusicSession(scope: UUID())
    }
}
private func libraryCredentials() async -> MusicSessionStore {
    let store = MusicSessionStore()
    await store.replaceSession(accountID: String(repeating: "a", count: 64), cookieHeader: "fixture=1", sapisid: "fixture",
        configuration: .init(apiKey: "fixture", clientVersion: "fixture"))
    return store
}
private func requestBody(_ request: URLRequest) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]) }
private func libraryResponse(_ object: [String: Any]) throws -> MusicHTTPResponse { .init(data: try JSONSerialization.data(withJSONObject: object), statusCode: 200) }
private func libraryShelf(_ rows: [[String: Any]], token: String? = nil) -> [String: Any] {
    var shelf: [String: Any] = ["title": ["runs": [["text": "Résultats 私のライブラリ"]]], "contents": rows]
    if let token { shelf["continuations"] = [["nextContinuationData": ["continuation": token]]] }
    return ["contents": ["sectionListRenderer": ["contents": [["musicShelfRenderer": shelf]]]]]
}
private func libraryFixture(_ filter: MusicLibrarySearchFilter) throws -> MusicHTTPResponse {
    let content = libraryShelf([libraryRow(filter)])
    return try libraryResponse(["contents": ["tabbedSearchResultsRenderer": ["tabs": [["tabRenderer": ["selected": true, "content": content["contents"]!]]]]]])
}
private func libraryRow(_ filter: MusicLibrarySearchFilter, id: String = "abcDEF12_-3") -> [String: Any] {
    let collectionID: String?
    switch filter {
    case .albums: collectionID = "MPREfixture"
    case .artists: collectionID = "UCfixture"
    case .playlists: collectionID = "VLPLfixture"
    case .podcasts: collectionID = "MPSPPLfixture"
    default: collectionID = nil
    }
    if let collectionID {
        return ["musicTwoRowItemRenderer": ["title": ["runs": [["text": "Titre opaque"]]], "navigationEndpoint": ["browseEndpoint": ["browseId": collectionID]]]]
    }
    let type = filter == .episodes ? "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" : filter == .videos ? "MUSIC_VIDEO_TYPE_OMV" : "MUSIC_VIDEO_TYPE_ATV"
    return ["musicResponsiveListItemRenderer": ["playlistItemData": ["videoId": id],
        "onTap": ["watchEndpoint": ["videoId": id, "watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": type]]]],
        "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Titre opaque"]]]]]]]]
}
