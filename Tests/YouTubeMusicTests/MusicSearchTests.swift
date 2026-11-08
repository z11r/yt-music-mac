import Foundation
import XCTest
@testable import YouTubeMusic

/// Fixtures are trimmed anonymous responses with synthetic names, identifiers and tokens.
@MainActor
final class MusicSearchTests: XCTestCase {
    func testScopedSearchRejectsOldOwnerBeforeAnyRequest() async throws {
        let transport = RecordingTransport([])
        let client = client(transport)
        do {
            _ = try await client.search(query: "private phrase", filter: .songs, expectedScope: UUID())
            XCTFail("Expected stale scope rejection")
        } catch let error as MusicServiceError { XCTAssertEqual(error, .sessionChanged) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testEachFilterSendsItsParamsAndTheUnfilteredSearchSendsNone() async throws {
        let transport = RecordingTransport(Array(repeating: try fixtureResponse("search_filter_songs"),
                                                 count: MusicSearchFilter.allCases.count))
        let client = client(transport)
        for filter in MusicSearchFilter.allCases { _ = try await client.search(query: " example ", filter: filter) }
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, Array(repeating: "/youtubei/v1/search", count: requests.count))
        let bodies = try requests.map(body)
        XCTAssertEqual(bodies.map { $0["query"] as? String }, Array(repeating: "example", count: bodies.count))
        XCTAssertEqual(bodies.map { $0["params"] as? String }, [
            nil,
            "EgWKAQIIAWoMEA4QChADEAQQCRAF",
            "EgWKAQIQAWoMEA4QChADEAQQCRAF",
            "EgWKAQIYAWoMEA4QChADEAQQCRAF",
            "EgWKAQIgAWoMEA4QChADEAQQCRAF",
            "EgeKAQQoAEABagwQDhAKEAMQBBAJEAU=",
            "EgeKAQQoADgBagwQDhAKEAMQBBAJEAU=",
        ])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    }

    func testSongsFilterReturnsSongsWithMetadataAndAContinuation() async throws {
        let page = try await search("search_filter_songs", filter: .songs)
        XCTAssertEqual(page.items.map(\.id), ["track:fxVideo0001", "track:fxVideo0004"])
        let first = try XCTUnwrap(page.tracks.first)
        XCTAssertEqual(first.title, "Song Title 1")
        XCTAssertEqual(first.artist, "Artist 3")
        XCTAssertEqual(first.album, "Album 4")
        XCTAssertEqual(first.duration, 430)
        XCTAssertEqual(page.sections.map(\.title), ["Songs"])
        XCTAssertNotNil(page.continuation)
    }

    func testVideosFilterReturnsPlayableVideos() async throws {
        let page = try await search("search_filter_videos", filter: .videos)
        XCTAssertEqual(page.tracks.map(\.id), ["fxVideo0010", "fxVideo0011"])
        XCTAssertEqual(page.tracks.map(\.title), ["Video Title 14", "Video Title 15"])
        XCTAssertEqual(page.tracks.map(\.artist), ["Artist 3", "Artist 3"], "View counts are not artists.")
        XCTAssertEqual(page.tracks.map(\.duration), [343, 241])
        XCTAssertEqual(page.items.count, page.tracks.count)
        XCTAssertNotNil(page.continuation)
    }

    func testAlbumsFilterReturnsAlbumsRatherThanTheirArtistsOrPlayButtons() async throws {
        let page = try await search("search_filter_albums", filter: .albums)
        XCTAssertEqual(collections(page).map(\.kind), [.album, .album])
        XCTAssertEqual(collections(page).map(\.id), ["MPREb_fixture13", "MPREb_fixture15"])
        XCTAssertEqual(collections(page).map(\.title), ["Album Title 16", "Album Title 17"])
        XCTAssertNotNil(page.continuation)
    }

    func testArtistsFilterReturnsArtists() async throws {
        let page = try await search("search_filter_artists", filter: .artists)
        XCTAssertEqual(collections(page).map(\.kind), [.artist, .artist])
        XCTAssertEqual(collections(page).map(\.id), ["UCfixture02", "UCfixture16"])
        XCTAssertEqual(collections(page).map(\.title), ["Artist 3", "Artist Name 18"])
        XCTAssertNil(page.continuation, "The probe returned a single artists page.")
    }

    func testCommunityPlaylistsFilterReturnsPlaylists() async throws {
        let page = try await search("search_filter_community_playlists", filter: .communityPlaylists)
        XCTAssertEqual(collections(page).map(\.kind), [.playlist, .playlist])
        XCTAssertEqual(collections(page).map(\.id), ["VLPLfixture19", "VLPLfixture22"])
        XCTAssertEqual(collections(page).map(\.title), ["Community Playlist 19", "Community Playlist 20"])
        XCTAssertNotNil(page.continuation)
    }

    func testFeaturedPlaylistsFilterReturnsPlaylists() async throws {
        let page = try await search("search_filter_featured_playlists", filter: .featuredPlaylists)
        XCTAssertEqual(collections(page).map(\.kind), [.playlist, .playlist])
        XCTAssertEqual(collections(page).map(\.id), ["VLRDCLfixture24", "VLRDCLfixture26"])
        XCTAssertEqual(collections(page).map(\.title), ["Featured Playlist 23", "Featured Playlist 24"])
        XCTAssertNil(page.continuation)
    }

    func testFilteredResultsContinueThroughTheSearchEndpointWithOnlyTheToken() async throws {
        let transport = RecordingTransport([try fixtureResponse("search_filter_songs"),
                                            try fixtureResponse("search_filter_songs_continuation")])
        let client = client(transport)
        let first = try await client.search(query: "example", filter: .songs)
        let next = try await client.nextPage(XCTUnwrap(first.continuation))
        XCTAssertEqual(next.tracks.map(\.id), ["fxVideo0006", "fxVideo0007"])
        XCTAssertEqual(next.tracks.map(\.title), ["Next Song Title 8", "Next Song Title 9"])
        XCTAssertNotNil(next.continuation)
        let requests = await transport.requests
        XCTAssertEqual(requests[1].url?.path, "/youtubei/v1/search")
        let continuationBody = try body(requests[1])
        XCTAssertEqual(continuationBody["continuation"] as? String, "fixture-songs-page-2")
        XCTAssertNil(continuationBody["query"])
        XCTAssertNil(continuationBody["params"])
    }

    func testSuggestionsUseTheSuggestionEndpointWithTheTextAsTyped() async throws {
        let transport = RecordingTransport([try fixtureResponse("search_suggestions")])
        let suggestions = try await client(transport).searchSuggestions(for: "exam ")
        XCTAssertEqual(suggestions.map(\.query), ["example", "example song", "example artist live"])
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.url?.path, "/youtubei/v1/music/get_search_suggestions")
        XCTAssertEqual(try body(XCTUnwrap(requests.first))["input"] as? String, "exam ")
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Cookie"))
    }

    func testSuggestionsRejectEmptyOrMultilineTextWithoutARequest() async throws {
        let transport = RecordingTransport([])
        let client = client(transport)
        for input in ["", "   ", "first\nsecond", String(repeating: "a", count: 501)] {
            do {
                _ = try await client.searchSuggestions(for: input)
                XCTFail("Expected invalid input for \(input.debugDescription)")
            } catch let error as MusicServiceError { XCTAssertEqual(error, .invalidInput) }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSuggestionParserReadsHistoryAndFallbackTextAndDropsRepeats() throws {
        let data = json(["contents": [
            ["searchSuggestionsSectionRenderer": ["contents": [
                ["historySuggestionRenderer": ["suggestion": ["runs": [["text": "recent", "bold": true], ["text": " search"]]],
                                               "navigationEndpoint": ["searchEndpoint": ["query": "recent search"]]]],
                ["searchSuggestionRenderer": ["suggestion": ["runs": [["text": "rec"], ["text": "ent search"]]]]],
                ["searchSuggestionRenderer": ["suggestion": ["runs": [["text": "Recent Search"]]]]],
                ["searchSuggestionRenderer": ["suggestion": ["runs": [["text": "rec"], ["text": "ord"]]]]],
                ["searchSuggestionRenderer": ["suggestion": ["runs": [["text": "  "]]]]],
                ["musicResponsiveListItemRenderer": ["flexColumns": []]],
            ]]],
        ]])
        XCTAssertEqual(try MusicSearchSuggestionParser.parse(data).map(\.query), ["recent search", "record"])
    }

    func testSuggestionParserTreatsAMissingListAsNoSuggestionsAndAnErrorAsAFailure() throws {
        XCTAssertEqual(try MusicSearchSuggestionParser.parse(json(["responseContext": [:]])), [])
        XCTAssertThrowsError(try MusicSearchSuggestionParser.parse(json(["error": ["status": "PERMISSION_DENIED"]]))) {
            XCTAssertEqual($0 as? MusicServiceError, .accessDenied)
        }
        XCTAssertThrowsError(try MusicSearchSuggestionParser.parse(Data("not json".utf8))) {
            XCTAssertEqual($0 as? MusicServiceError, .invalidResponse)
        }
    }

    private func search(_ fixture: String, filter: MusicSearchFilter) async throws -> MusicPage {
        try await client(RecordingTransport([try fixtureResponse(fixture)])).search(query: "example", filter: filter)
    }

    private func collections(_ page: MusicPage) -> [MusicCollection] {
        page.items.compactMap { if case let .collection(value) = $0 { value } else { nil } }
    }

    private func client(_ transport: RecordingTransport) -> YouTubeMusicClient {
        YouTubeMusicClient(transport: transport, sessions: AnonymousFixtureSession(), pause: { _ in })
    }
}

private struct AnonymousFixtureSession: MusicSessionProviding {
    let value = MusicSession(scope: UUID(), configuration: MusicClientConfiguration(apiKey: "fixture-key",
                                                                                     clientVersion: "fixture-version"))
    func snapshot() async -> MusicSession { value }
}

private actor RecordingTransport: MusicHTTPTransport {
    private var responses: [MusicHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [MusicHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}

private func body(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
}
private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
