import Foundation
import XCTest
@testable import YouTubeMusic

/// The radio fixtures are trimmed from anonymous `next` responses recorded on 2026-11-07.
@MainActor
final class MusicRadioTests: XCTestCase {
    func testSongRadioRequestsTheSongsRadioAndMarksTheSeed() async throws {
        let transport = RadioTransport([try fixtureResponse("radio_song_first_page")])
        let page = try await client(transport).radio(videoID: "dQw4w9WgXcQ")

        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.path, "/youtubei/v1/next")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
        let body = try body(requests[0])
        XCTAssertEqual(body["videoId"] as? String, "dQw4w9WgXcQ")
        XCTAssertEqual(body["playlistId"] as? String, "RDAMVMdQw4w9WgXcQ")
        XCTAssertEqual(body["enablePersistentPlaylistPanel"] as? Bool, true)
        XCTAssertEqual(body["isAudioOnly"] as? Bool, true)

        XCTAssertEqual(page.title, "Never Gonna Give You Up Mix")
        XCTAssertEqual(page.playlistID, "RDAMVMdQw4w9WgXcQ")
        XCTAssertEqual(page.tracks.map(\.id), ["dQw4w9WgXcQ", "yPYZpwSpKmA", "djV11Xbc914", "XEjLoHdbVeE"])
        XCTAssertEqual(page.selectedTrackID, "dQw4w9WgXcQ")
        XCTAssertEqual(page.tracks(excluding: "dQw4w9WgXcQ").map(\.id), ["yPYZpwSpKmA", "djV11Xbc914", "XEjLoHdbVeE"])
        let seed = page.tracks[0]
        XCTAssertEqual(seed.title, "Never Gonna Give You Up")
        // Video bylines list views and likes after the artist; only the artist is kept.
        XCTAssertEqual(seed.artist, "Rick Astley")
        XCTAssertNil(seed.album)
        XCTAssertEqual(seed.duration, 214)
        XCTAssertEqual(seed.artworkURL?.host, "i.ytimg.com")
        XCTAssertNotNil(page.continuation)
    }

    func testRadioContentKindRequiresAnExplicitServiceType() throws {
        func typed(_ id: String, _ type: String) -> [String: Any] {
            panelItem(id, extra: ["navigationEndpoint": ["watchEndpoint": ["videoId": id,
                "watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": type]]]]])
        }
        let parsed = try MusicRadioParser.parse(json(firstPage([
            typed("abcDEF12_-3", "MUSIC_VIDEO_TYPE_ATV"),
            typed("xyzABC34_-5", "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"),
            typed("qrsABC34_-5", "MUSIC_VIDEO_TYPE_UGC"),
        ], token: nil)))
        XCTAssertEqual(parsed.tracks.map(\.contentKind), [.song, .podcastEpisode, nil])
        XCTAssertEqual(parsed.tracks[1].episode?.identity.browseID, "MPEDxyzABC34_-5")
    }

    func testContinuationLoadsTheNextPageWithItsToken() async throws {
        let transport = RadioTransport([try fixtureResponse("radio_song_first_page"), try fixtureResponse("radio_continuation")])
        let client = client(transport)
        let first = try await client.radio(videoID: "dQw4w9WgXcQ")
        let next = try await client.nextRadioPage(XCTUnwrap(first.continuation))

        let requests = await transport.requests
        XCTAssertEqual(requests[1].url?.path, "/youtubei/v1/next")
        let body = try body(requests[1])
        XCTAssertEqual(body["continuation"] as? String, try fixtureToken("radio_song_first_page"))
        XCTAssertNil(body["videoId"])
        XCTAssertEqual(next.tracks.map(\.id), ["JYIaWeVL1JM", "x34icYC8zA0", "2ssCL292DQA"])
        XCTAssertEqual(next.tracks[0].artist, "Snap!")
        XCTAssertNil(next.selectedTrackID)
        XCTAssertEqual(next.playlistID, "RDAMVMdQw4w9WgXcQ")
        XCTAssertNotNil(next.continuation)
    }

    func testCollectionMixHasNoSeedSongAndReadsAlbums() async throws {
        let transport = RadioTransport([try fixtureResponse("radio_album_mix")])
        let page = try await client(transport).radio(playlistID: "RDAMPLOLAK5uy_kKzgbumGI8XJFtMr9MZyCAq-oW7G1GOuY")
        let body = try await body(transport.requests[0])
        XCTAssertNil(body["videoId"])
        XCTAssertEqual(body["playlistId"] as? String, "RDAMPLOLAK5uy_kKzgbumGI8XJFtMr9MZyCAq-oW7G1GOuY")
        XCTAssertEqual(page.tracks.map(\.id), ["0XEnBSWZYNs", "Tc8FyMkYXaQ", "BWcB8YYDDYM"])
        XCTAssertEqual(page.tracks.map(\.album), ["50", "I Got a Name", "The Best of Me"])
        XCTAssertEqual(page.tracks.map(\.artist), ["Rick Astley", "Jim Croce", "Rick Astley"])
        XCTAssertEqual(page.tracks[1].duration, 155)
        XCTAssertEqual(page.selectedTrackID, "0XEnBSWZYNs")
        XCTAssertEqual(page.title, "The Best of Me Mix")
    }

    func testAQueueWithoutAPanelMeansNoRadio() async throws {
        let page = try await client(RadioTransport([try fixtureResponse("radio_unavailable")])).radio(playlistID: "RDAMVMunavailable")
        XCTAssertTrue(page.tracks.isEmpty)
        XCTAssertNil(page.continuation)
        XCTAssertNil(page.selectedTrackID)
    }

    func testAResponseWithoutAQueueIsUnsupported() {
        XCTAssertThrowsError(try MusicRadioParser.parse(json(["contents": ["sectionListRenderer": ["contents": []]]]))) {
            XCTAssertEqual($0 as? MusicServiceError, .unsupportedResponse)
        }
        XCTAssertThrowsError(try MusicRadioParser.parse(json(["error": ["status": "UNAUTHENTICATED"]]))) {
            XCTAssertEqual($0 as? MusicServiceError, .authenticationRejected)
        }
    }

    func testDuplicatesAndItemsWithMissingFields() throws {
        let items: [[String: Any]] = [
            panelItem("seed", selected: true),
            panelItem("one"),
            panelItem("one", title: "Repeated"),
            ["playlistPanelVideoRenderer": ["title": text("No identifier")]],
            ["playlistPanelVideoRenderer": ["videoId": "untitled"]],
            panelItem("bad id!"),
            panelItem("blocked", extra: ["unplayableText": text("Unavailable")]),
            ["playlistPanelVideoWrapperRenderer": ["primaryRenderer": panelItem("wrapped")]],
            ["playlistPanelVideoRenderer": ["videoId": "bare", "title": text("Bare")]],
            ["playlistPanelVideoRenderer": ["videoId": "short", "title": text("Short"), "shortBylineText": text("Short Artist")]],
            ["playlistPanelVideoRenderer": ["title": text("Endpoint only"),
                                            "navigationEndpoint": ["watchEndpoint": ["videoId": "endpoint"]]]],
            ["automixPreviewVideoRenderer": ["content": [:]]],
        ]
        let parsed = try MusicRadioParser.parse(json(firstPage(items, token: "next-page")))
        XCTAssertEqual(parsed.tracks.map(\.id), ["seed", "one", "wrapped", "bare", "short", "endpoint"])
        XCTAssertEqual(parsed.tracks[1].title, "Title one", "The first occurrence of a repeated song is kept.")
        XCTAssertEqual(parsed.selectedTrackID, "seed")
        XCTAssertEqual(parsed.token, "next-page")
        let bare = parsed.tracks[3]
        XCTAssertEqual(bare.artist, "Unknown artist")
        XCTAssertNil(bare.duration)
        XCTAssertNil(bare.artworkURL)
        XCTAssertEqual(parsed.tracks[4].artist, "Short Artist")
        XCTAssertEqual(parsed.tracks[0].artist, "Artist A, Artist B & Artist C")
    }

    func testLaterPagesDropSongsFromEarlierPagesAndTheSeed() async throws {
        let transport = RadioTransport([
            response(firstPage([panelItem("seed", selected: true), panelItem("one")], token: "page-two")),
            response(continuationPage([panelItem("seed"), panelItem("one"), panelItem("two")], token: "page-three")),
        ])
        let client = client(transport)
        let first = try await client.radio(videoID: "seed")
        let next = try await client.nextRadioPage(XCTUnwrap(first.continuation))
        XCTAssertEqual(next.tracks.map(\.id), ["two"])
    }

    func testARepeatedTokenStopsInsteadOfLooping() async throws {
        let transport = RadioTransport([
            response(firstPage([panelItem("seed", selected: true)], token: "same")),
            response(continuationPage([panelItem("one")], token: "same")),
        ])
        let client = client(transport)
        let first = try await client.radio(videoID: "seed")
        do {
            _ = try await client.nextRadioPage(XCTUnwrap(first.continuation))
            XCTFail("Expected a pagination loop error")
        } catch { XCTAssertEqual(error as? MusicServiceError, .paginationLoop) }
    }

    func testAContinuationFromAnotherSessionIsRejected() async throws {
        let store = MusicSessionStore()
        let transport = RadioTransport([response(firstPage([panelItem("seed", selected: true)], token: "next"))])
        let client = YouTubeMusicClient(transport: transport, sessions: store, pause: { _ in })
        await store.replaceSession(accountID: "fixture-account", cookieHeader: "example=value", sapisid: "test-a",
                                   configuration: radioConfiguration)
        let first = try await client.radio(videoID: "seed")
        await store.clear()
        do {
            _ = try await client.nextRadioPage(XCTUnwrap(first.continuation))
            XCTFail("Expected a session change")
        } catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testInvalidIdentifiersAreRejectedBeforeAnyRequest() async throws {
        let transport = RadioTransport([])
        let client = client(transport)
        let calls: [() async throws -> MusicRadioPage] = [
            { try await client.radio(videoID: "bad id") }, { try await client.radio(playlistID: "RD/../x") },
            { try await client.radio(videoID: "ok", playlistID: "") },
        ]
        for call in calls {
            do { _ = try await call(); XCTFail("Expected invalid input") }
            catch { XCTAssertEqual(error as? MusicServiceError, .invalidInput) }
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testCollectionsKeepTheMixTheirMenuOffers() throws {
        let page = try MusicResponseParser.parse(Data(contentsOf: XCTUnwrap(
            Bundle.module.url(forResource: "search_collection_mix_menus", withExtension: "json"))), preservesOccurrences: false)
        let collections = page.items.compactMap { item -> MusicCollection? in
            if case let .collection(value) = item { value } else { nil }
        }
        XCTAssertEqual(collections.map(\.kind), [.album, .artist])
        // The shuffle command plays the collection itself; only the mix command is a radio.
        XCTAssertEqual(collections.map(\.radioPlaylistID), ["RDAMPLOLAK5uy_kKzgbumGI8XJFtMr9MZyCAq-oW7G1GOuY",
                                                            "RDEMbiOp71btqIEmNAEnJUXG_g"])
        let row: [String: Any] = ["musicResponsiveListItemRenderer": [
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": text("Show")]]],
            "navigationEndpoint": ["browseEndpoint": ["browseId": "VLPLshow"]],
            "menu": ["menuRenderer": ["items": [["menuNavigationItemRenderer": [
                "icon": ["iconType": "MUSIC_SHUFFLE"],
                "navigationEndpoint": ["watchPlaylistEndpoint": ["playlistId": "PLshow"]],
            ]]]]],
        ]]
        let withoutMix = try MusicResponseParser.parse(json(["contents": ["sectionListRenderer": ["contents": [
            ["musicShelfRenderer": ["contents": [row]]],
        ]]]]), preservesOccurrences: false)
        guard case let .collection(playlist) = try XCTUnwrap(withoutMix.items.first) else { return XCTFail("Expected a playlist") }
        XCTAssertNil(playlist.radioPlaylistID)
    }

    private func client(_ transport: RadioTransport) -> YouTubeMusicClient {
        YouTubeMusicClient(transport: transport, sessions: RadioFixedSession(), pause: { _ in })
    }

    private func fixtureToken(_ name: String) throws -> String {
        let data = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json")))
        let path: [Any] = ["contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer",
                           "watchNextTabbedResultsRenderer", "tabs", 0, "tabRenderer", "content", "musicQueueRenderer",
                           "content", "playlistPanelRenderer", "continuations", 0, "nextRadioContinuationData", "continuation"]
        let value = path.reduce(try JSONSerialization.jsonObject(with: data) as Any?) { node, key in
            if let key = key as? String { return (node as? [String: Any])?[key] }
            guard let index = key as? Int, let array = node as? [Any], array.indices.contains(index) else { return nil }
            return array[index]
        }
        return try XCTUnwrap(value as? String)
    }
}

private let radioConfiguration = MusicClientConfiguration(apiKey: "fixture-key", clientVersion: "fixture-version")
private struct RadioFixedSession: MusicSessionProviding {
    let value = MusicSession(scope: UUID(), configuration: radioConfiguration)
    func snapshot() async -> MusicSession { value }
}
private actor RadioTransport: MusicHTTPTransport {
    private var responses: [MusicHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [MusicHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}

private func response(_ object: [String: Any]) -> MusicHTTPResponse { MusicHTTPResponse(data: json(object), statusCode: 200) }
private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
private func text(_ value: String) -> [String: Any] { ["runs": [["text": value]]] }
private func body(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
}
private func panelItem(_ id: String, title: String? = nil, selected: Bool = false, extra: [String: Any] = [:]) -> [String: Any] {
    let artist: [String: Any] = ["browseEndpoint": ["browseId": "UCartist",
        "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_ARTIST"]]]]
    var renderer: [String: Any] = [
        "videoId": id, "title": text(title ?? "Title " + id), "selected": selected,
        "longBylineText": ["runs": [["text": "Artist A", "navigationEndpoint": artist], ["text": ", "],
                                    ["text": "Artist B", "navigationEndpoint": artist], ["text": " & "],
                                    ["text": "Artist C"], ["text": " • "], ["text": "1M views"]]],
        "lengthText": text("3:00"),
        "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/\(id)/default.jpg", "width": 120, "height": 90]]],
    ]
    renderer.merge(extra) { $1 }
    return ["playlistPanelVideoRenderer": renderer]
}
private func firstPage(_ items: [[String: Any]], token: String?) -> [String: Any] {
    var panel: [String: Any] = ["playlistId": "RDAMVMseed", "contents": items]
    if let token { panel["continuations"] = [["nextRadioContinuationData": ["continuation": token]]] }
    return ["contents": ["singleColumnMusicWatchNextResultsRenderer": ["tabbedRenderer": ["watchNextTabbedResultsRenderer": [
        "tabs": [["tabRenderer": ["content": ["musicQueueRenderer": ["content": ["playlistPanelRenderer": panel]]]]]]]]]]]
}
private func continuationPage(_ items: [[String: Any]], token: String?) -> [String: Any] {
    var panel: [String: Any] = ["contents": items]
    if let token { panel["continuations"] = [["nextRadioContinuationData": ["continuation": token]]] }
    return ["continuationContents": ["playlistPanelContinuation": panel]]
}
