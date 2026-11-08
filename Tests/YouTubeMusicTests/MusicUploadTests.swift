import Foundation
import MusicCore
import XCTest
@testable import YouTubeMusic

@MainActor
final class MusicUploadTests: XCTestCase {
    private let videoID = "abcDEF12_-3"
    private let albumID = "FEmusic_library_privately_owned_release_detailb_po_fixture"
    private let artistID = "FEmusic_library_privately_owned_artist_detaila_po_fixture"

    func testUploadCategoriesUseAuthenticatedReadOnlyRoutes() async throws {
        let transport = UploadTransport(Array(repeating: shelf([]), count: 3))
        let client = await client(transport)
        for category in MusicUploadCategory.allCases { _ = try await client.uploads(category: category) }
        let requests = await transport.requests
        XCTAssertEqual(try requests.map { try body($0)["browseId"] as? String }, [
            "FEmusic_library_privately_owned_tracks", "FEmusic_library_privately_owned_releases", "FEmusic_library_privately_owned_artists",
        ])
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/youtubei/v1/browse" && $0.value(forHTTPHeaderField: "Cookie") == "fixture=value" })
    }

    func testAnonymousUploadsAndInvalidPrivateCollectionIDsNeverSendRequests() async throws {
        let transport = UploadTransport([])
        let client = YouTubeMusicClient(transport: transport)
        for operation in 0...3 {
            do {
                switch operation {
                case 0: _ = try await client.uploads()
                case 1: _ = try await client.searchUploads(query: "Fixture")
                case 2: _ = try await client.uploadedAlbum(id: albumID)
                default: _ = try await client.uploadedArtist(id: artistID)
                }
                XCTFail("Expected signed-in account")
            } catch { XCTAssertEqual(error as? MusicServiceError, .signInRequired) }
        }
        do { _ = try await client.uploadedAlbum(id: "MPREcatalog"); XCTFail("Expected upload-only browse ID") }
        catch { XCTAssertEqual(error as? MusicServiceError, .invalidInput) }
        do { _ = try await client.uploadedArtist(id: "UCcatalog"); XCTFail("Expected upload-only browse ID") }
        catch { XCTAssertEqual(error as? MusicServiceError, .invalidInput) }
        do { _ = try await client.album(id: artistID); XCTFail("Expected matching private collection kind") }
        catch { XCTAssertEqual(error as? MusicServiceError, .invalidInput) }
        do { _ = try await client.artist(id: albumID); XCTFail("Expected matching private collection kind") }
        catch { XCTAssertEqual(error as? MusicServiceError, .invalidInput) }
        do { _ = try await client.playlist(id: albumID); XCTFail("Expected private album route") }
        catch { XCTAssertEqual(error as? MusicServiceError, .invalidInput) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testUploadQueueTargetIsPlaybackIdentityAndEntityNeverEntersTrack() async throws {
        let transport = UploadTransport([shelf([uploadRow(videoID, title: "Uploaded song")])])
        let page = try await client(transport).uploads()
        XCTAssertEqual(page.tracks.map(\.id), [videoID])
        XCTAssertEqual(page.tracks.first?.origin, .upload)
        XCTAssertEqual(page.playlistItems.first?.track.origin, .upload)
        let encoded = String(decoding: try JSONEncoder().encode(page.tracks), as: UTF8.self)
        XCTAssertFalse(encoded.contains("t_po_private_entity"))
        XCTAssertFalse(encoded.contains("entityId"))
        var queue = PlaybackQueue()
        queue.replace(with: page.tracks + page.tracks)
        XCTAssertEqual(queue.entries.map(\.track.id), [videoID, videoID])
        XCTAssertEqual(Set(queue.entries.map(\.id)).count, 2)
    }

    func testUploadSearchSelectsOnlyTheUploadsTabAndUsesPinnedScope() async throws {
        let response = object(["contents": ["tabbedSearchResultsRenderer": ["tabs": [
            tab([uploadRow("CATALOG1234", title: "Catalog")]), tab([uploadRow("LIBRARY1234", title: "Library")]),
            tab([uploadRow(videoID, title: "Upload match"), card(albumID, title: "Upload album"), card(artistID, title: "Upload artist")]),
        ]]]])
        let transport = UploadTransport([response])
        let page = try await client(transport).searchUploads(query: "  Fixture  ")
        XCTAssertEqual(page.tracks.map(\.title), ["Upload match"])
        XCTAssertTrue(page.tracks.allSatisfy { $0.origin == .upload })
        let collections = page.items.compactMap { if case let .collection(value) = $0 { value } else { nil } }
        XCTAssertEqual(collections.map(\.kind), [.album, .artist])
        XCTAssertTrue(collections.allSatisfy(\.isUploaded))
        let requests = await transport.requests
        XCTAssertEqual(try body(requests[0])["query"] as? String, "Fixture")
        XCTAssertEqual(try body(requests[0])["params"] as? String, "agIYAw%3D%3D")
        XCTAssertEqual(requests[0].url?.path, "/youtubei/v1/search")
    }

    func testMissingUploadsTabNeverFallsBackToCatalogResults() async throws {
        let transport = UploadTransport([object(["contents": ["tabbedSearchResultsRenderer": ["tabs": [tab([uploadRow(videoID)])]]]])])
        do { _ = try await client(transport).searchUploads(query: "Fixture"); XCTFail("Expected unsupported scope layout") }
        catch { XCTAssertEqual(error as? MusicServiceError, .unsupportedResponse) }
    }

    func testUploadSearchCanUseItsTitleWatchEndpointWithoutAnEntityIdentifier() async throws {
        let row: [String: Any] = ["musicResponsiveListItemRenderer": ["flexColumns": [
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Uploaded search result",
                "navigationEndpoint": ["watchEndpoint": ["videoId": videoID]],
            ]]]]],
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Uploaded artist",
                "navigationEndpoint": ["browseEndpoint": ["browseId": artistID]],
            ]]]]],
        ]]]
        let transport = UploadTransport([shelf([row])])
        let result = try await client(transport).searchUploads(query: "Fixture")
        XCTAssertEqual(result.tracks.first?.id, videoID)
        XCTAssertEqual(result.tracks.first?.artist, "Uploaded artist")
        XCTAssertEqual(result.tracks.first?.origin, .upload)
    }

    func testUploadContinuationsKeepAuthenticationOriginAndRepeatedOccurrences() async throws {
        let transport = UploadTransport([shelf([uploadRow(videoID)], token: "private-next"), next([uploadRow(videoID), uploadRow("xyzABC98_-7")])])
        let client = await client(transport)
        let first = try await client.uploads()
        let second = try await client.nextPage(XCTUnwrap(first.continuation))
        XCTAssertEqual(second.tracks.map(\.id), [videoID, "xyzABC98_-7"])
        XCTAssertTrue(second.tracks.allSatisfy { $0.origin == .upload })
        XCTAssertTrue(second.playlistItems.allSatisfy { $0.track.origin == .upload })
        let requests = await transport.requests
        XCTAssertEqual(try body(requests[1])["continuation"] as? String, "private-next")
        XCTAssertNotNil(requests[1].value(forHTTPHeaderField: "Authorization"))
    }

    func testUploadContinuationCannotCrossAnAccountBoundary() async throws {
        let store = await session()
        let transport = UploadTransport([shelf([uploadRow(videoID)], token: "private-next")])
        let client = await client(transport, store: store)
        let first = try await client.uploads()
        await store.clear()
        do { _ = try await client.nextPage(XCTUnwrap(first.continuation)); XCTFail("Expected account fence") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testAccountChangeRejectsAnUploadResponseAlreadyInFlight() async throws {
        let store = await session()
        let transport = UploadTransport([shelf([uploadRow(videoID)])], clearStore: store)
        do { _ = try await client(transport, store: store).uploads(); XCTFail("Expected stale account response") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testPrivateAlbumAndArtistNavigationRemainAuthenticatedAndKeepOrigin() async throws {
        let transport = UploadTransport([shelf([uploadRow(videoID)]), shelf([uploadRow(videoID)])])
        let client = await client(transport)
        let album = try await client.album(id: albumID)
        let artist = try await client.artist(id: artistID)
        XCTAssertEqual(album.tracks.first?.origin, .upload)
        XCTAssertEqual(artist.tracks.first?.origin, .upload)
        let requests = await transport.requests
        XCTAssertEqual(try requests.map { try body($0)["browseId"] as? String }, [albumID, artistID])
    }

    func testEntityOnlyInvalidAndConflictingPlaybackTargetsAreRejected() async throws {
        var conflict = uploadRow(videoID)
        var renderer = try XCTUnwrap(conflict["musicResponsiveListItemRenderer"] as? [String: Any])
        renderer["playlistItemData"] = ["videoId": "xyzABC98_-7"]
        conflict["musicResponsiveListItemRenderer"] = renderer
        for row in [uploadRow("t_po_private_entity"), uploadRow(nil), conflict] {
            let transport = UploadTransport([shelf([row])])
            do { _ = try await client(transport).uploads(); XCTFail("Expected valid unambiguous playback ID") }
            catch { XCTAssertEqual(error as? MusicServiceError, .unsupportedResponse) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testCatalogResultsNeverUseUploadMenuIdentityOrMarkOrigin() async throws {
        let catalog: [String: Any] = ["musicTwoRowItemRenderer": [
            "title": ["runs": [["text": "Catalog fixture"]]],
            "navigationEndpoint": ["watchEndpoint": ["videoId": "otherID12_3"]],
        ]]
        let transport = UploadTransport([shelf([uploadRow(videoID)]), shelf([uploadRow(videoID), catalog])])
        let client = await client(transport)
        do { _ = try await client.search(query: "Fixture"); XCTFail("Expected unsupported-only content") }
        catch { XCTAssertEqual(error as? MusicServiceError, .unsupportedResponse) }
        let page = try await client.search(query: "Fixture")
        XCTAssertEqual(page.tracks.map(\.id), ["otherID12_3"])
        XCTAssertTrue(page.tracks.allSatisfy { $0.origin != .upload })
        let requests = await transport.requests
        XCTAssertTrue(try requests.allSatisfy { try body($0)["params"] == nil })
    }

    func testUploadShuffleControlIsNotACollectionOrPlaybackTrack() async throws {
        let shuffle: [String: Any] = ["musicResponsiveListItemRenderer": [
            "navigationEndpoint": ["watchPlaylistEndpoint": ["playlistId": "MLPRprivate-shuffle"]],
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Shuffle all"]]]]]],
        ]]
        let transport = UploadTransport([shelf([shuffle, uploadRow(videoID)])])
        let page = try await client(transport).uploads()
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.tracks.first?.id, videoID)
    }

    private func client(_ transport: UploadTransport, store: MusicSessionStore? = nil) async -> YouTubeMusicClient {
        let store = if let store { store } else { await session() }
        return YouTubeMusicClient(transport: transport, sessions: store)
    }
    private func session() async -> MusicSessionStore {
        let store = MusicSessionStore()
        await store.replaceSession(accountID: "fixture", cookieHeader: "fixture=value", sapisid: "fixture",
            configuration: MusicClientConfiguration(apiKey: "fixture", clientVersion: "fixture"))
        return store
    }
}

private actor UploadTransport: MusicHTTPTransport {
    private var responses: [MusicHTTPResponse]
    private let clearStore: MusicSessionStore?
    private(set) var requests: [URLRequest] = []
    init(_ responses: [MusicHTTPResponse], clearStore: MusicSessionStore? = nil) { self.responses = responses; self.clearStore = clearStore }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        if let clearStore { await clearStore.clear() }
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}
private func body(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
}
private func object(_ value: [String: Any]) -> MusicHTTPResponse { .init(data: try! JSONSerialization.data(withJSONObject: value), statusCode: 200) }
private func shelf(_ rows: [[String: Any]], token: String? = nil) -> MusicHTTPResponse {
    var shelf: [String: Any] = ["contents": rows]
    if let token { shelf["continuations"] = [["nextContinuationData": ["continuation": token]]] }
    return object(["contents": ["sectionListRenderer": ["contents": [["musicShelfRenderer": shelf]]]]])
}
private func next(_ rows: [[String: Any]]) -> MusicHTTPResponse {
    object(["continuationContents": ["musicShelfContinuation": ["contents": rows]]])
}
private func tab(_ rows: [[String: Any]]) -> [String: Any] {
    ["tabRenderer": ["content": ["sectionListRenderer": ["contents": [["musicShelfRenderer": ["contents": rows]]]]]]]
}
private func card(_ id: String, title: String) -> [String: Any] {
    ["musicResponsiveListItemRenderer": ["navigationEndpoint": ["browseEndpoint": ["browseId": id]],
        "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": title]]]]]]]]
}
private func uploadRow(_ videoID: String?, title: String = "Uploaded fixture") -> [String: Any] {
    var menu: [[String: Any]] = []
    if let videoID { menu.append(["menuServiceItemRenderer": ["serviceEndpoint": ["queueAddEndpoint": ["queueTarget": ["videoId": videoID]]]]]) }
    menu.append(["menuNavigationItemRenderer": ["navigationEndpoint": ["confirmDialogEndpoint": ["content": [
        "confirmDialogRenderer": ["confirmButton": ["buttonRenderer": ["command": [
            "musicDeletePrivatelyOwnedEntityCommand": ["entityId": "t_po_private_entity"],
        ]]]],
    ]]]]])
    return ["musicResponsiveListItemRenderer": [
        "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": title]]]]],
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Uploaded artist"]]]]]],
        "menu": ["menuRenderer": ["items": menu]],
    ]]
}
