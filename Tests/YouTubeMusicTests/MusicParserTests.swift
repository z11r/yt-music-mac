// Fixtures adapted from Kaset, copyright (c) 2025 sozercan, under the MIT License.
// See THIRD_PARTY_NOTICES.md for attribution.
import Foundation
import XCTest
@testable import YouTubeMusic

final class MusicParserTests: XCTestCase {
    func testRecordedHomeResponse() throws {
        let page = try parse("home_response")
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].title, "Never Gonna Give You Up")
        XCTAssertEqual(page.items[1].title, "Test Album")
        XCTAssertFalse(page.sections[0].title.isEmpty)
    }

    func testRecordedSearchResponse() throws {
        let page = try parse("search_response")
        XCTAssertEqual(page.items.count, 4)
        XCTAssertEqual(page.items.map(\.title), ["Search Result Song 1", "Search Result Song 2", "Search Album 1", "Search Result Artist"])
    }

    func testRecordedPlaylistMetadata() throws {
        let page = try parse("playlist_detail", preservesOccurrences: true)
        XCTAssertEqual(page.title, "Test Playlist")
        XCTAssertEqual(page.items.count, 2)
        guard case let .track(track) = page.items[0] else { return XCTFail("Expected track") }
        XCTAssertEqual(track.duration, 225)
        XCTAssertEqual(track.artist, "Track Artist 1")
        XCTAssertNotNil(track.artworkURL)
    }

    func testAlbumWithoutHeaderStillLoadsTracks() throws {
        let page = try parse("album_playlist_without_header", preservesOccurrences: true)
        XCTAssertEqual(page.items.count, 3)
        XCTAssertEqual(page.items.first?.title, "Come Together (2019 Mix)")
    }

    func testDirectSearchItemsAndLaterColumns() throws {
        XCTAssertEqual(try parse("search_direct_item_section").items.map(\.title), ["Direct Song", "Direct Album"])
        XCTAssertEqual(try parse("search_later_flex_columns").items.first?.id, "album:MPREthird-column")
    }

    func testPlaylistCardsKeepBrowseIdentityInsteadOfPreviewVideo() throws {
        let page = try parse("search_playlist_watch_endpoints")
        XCTAssertEqual(page.items.map(\.id), ["playlist:RDradio-watch", "playlist:VMplaylist-action", "album:MPREcanonical-album"])
    }

    func testTopResultEndpointVariants() throws {
        let page = try parse("search_top_result_watch_endpoints")
        XCTAssertEqual(page.items.count, 3)
        XCTAssertTrue(page.items.allSatisfy { if case .track = $0 { true } else { false } })
    }

    func testSearchMenuItemsAreNeverTraversed() throws {
        let page = try parse("search_tabbed_mixed")
        XCTAssertFalse(page.items.contains { $0.title == "Must Not Parse" })
    }

    func testContinuationItemToken() throws {
        let page = try parse("search_music_shelf_continuation")
        XCTAssertEqual(page.token, "sanitized-continuation-item-token")
        XCTAssertEqual(page.items.count, 3)
    }

    func testArtistHeaderAndCarousel() throws {
        let data = Data(#"{"header":{"musicImmersiveHeaderRenderer":{"title":{"runs":[{"text":"Fixture Artist"}]}}},"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Albums"}]}}},"contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Fixture Album"}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"MPREfixture"}}}}]}}]}}}}]}}}"#.utf8)
        let page = try MusicResponseParser.parse(data, preservesOccurrences: false)
        XCTAssertEqual(page.title, "Fixture Artist")
        XCTAssertEqual(page.sections.first?.title, "Albums")
        XCTAssertEqual(page.items.first?.id, "album:MPREfixture")
    }

    func testUnavailableTrackIsNotAddedToPlayableItems() throws {
        let data = Data(#"{"contents":{"sectionListRenderer":{"contents":[{"musicShelfRenderer":{"contents":[{"musicResponsiveListItemRenderer":{"musicItemRendererDisplayPolicy":"MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT","playlistItemData":{"videoId":"unavailable"},"title":{"runs":[{"text":"Unavailable song"}]}}}]}}]}}}"#.utf8)
        let page = try MusicResponseParser.parse(data, preservesOccurrences: true)
        XCTAssertTrue(page.items.isEmpty)
    }

    func testDurationRejectsMalformedMetadata() {
        XCTAssertEqual(MusicResponseParser.parseDuration("1:02:03"), 3723)
        XCTAssertNil(MusicResponseParser.parseDuration("2026"))
        XCTAssertNil(MusicResponseParser.parseDuration("2:99"))
        XCTAssertNil(MusicResponseParser.parseDuration("-1:20"))
    }

    func testConfigurationParserHandlesEscapedValues() {
        XCTAssertEqual(YouTubeMusicClient.configurationValue("VISITOR_DATA", html: #"{"VISITOR_DATA":"fixture\u003d"}"#), "fixture=")
        XCTAssertNil(YouTubeMusicClient.configurationValue("INNERTUBE_API_KEY", html: "<html>Consent</html>"))
    }

    private func parse(_ name: String, preservesOccurrences: Bool = false) throws -> ParsedMusicPage {
        try MusicResponseParser.parse(fixtureResponse(name).data, preservesOccurrences: preservesOccurrences)
    }
}
