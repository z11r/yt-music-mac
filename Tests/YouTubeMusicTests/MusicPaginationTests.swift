import Foundation
import XCTest
@testable import YouTubeMusic

/// Cursor selection for collection pages. The response shapes are synthetic and contain no account data.
final class MusicPaginationTests: XCTestCase {
    func testPlaylistShelfCursorWinsOverSectionCursor() throws {
        let page = try parse(playlistPage(shelf: ["contents": [song("one"), continuationItem("tracks-two")]]))
        XCTAssertEqual(page.token, "tracks-two")
        XCTAssertEqual(page.playlistItems.map(\.track.id), ["one"])
    }

    func testExhaustedPlaylistDoesNotFollowSuggestionsCursor() throws {
        let page = try parse(playlistPage(shelf: ["contents": [song("one")]]))
        XCTAssertNil(page.token)
    }

    func testExhaustedPlaylistInSectionContinuationDoesNotFollowSuggestionsCursor() throws {
        let data = json(["continuationContents": ["sectionListContinuation": [
            "contents": [["musicPlaylistShelfRenderer": ["contents": [song("two")]]]],
            "continuations": [next("suggestions")],
        ]]])
        let page = try parse(data)
        XCTAssertEqual(page.playlistItems.map(\.track.id), ["two"])
        XCTAssertNil(page.token)
    }

    func testWrappedPlaylistCursorIsFound() throws {
        let wrapped: [String: Any] = ["continuationItemRenderer": ["continuationEndpoint": ["commandExecutorCommand": ["commands": [
            ["playlistVotingRefreshPopupCommand": [String: Any]()],
            ["continuationCommand": ["token": "voted-two", "request": "CONTINUATION_REQUEST_TYPE_BROWSE"]],
        ]]]]]
        let page = try parse(playlistPage(shelf: ["contents": [song("one"), wrapped]]))
        XCTAssertEqual(page.token, "voted-two")
    }

    func testAppendedPlaylistItemsKeepTheirCursor() throws {
        let data = json(["onResponseReceivedActions": [["appendContinuationItemsAction": [
            "continuationItems": [song("two"), song("two"), continuationItem("tracks-three")],
        ]]]])
        let page = try parse(data)
        XCTAssertEqual(page.playlistItems.map(\.track.id), ["two", "two"])
        XCTAssertEqual(page.token, "tracks-three")
    }

    func testLibraryGridCursorWinsOverSectionCursor() throws {
        let data = json(["contents": ["singleColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": ["content": [
            "sectionListRenderer": [
                "contents": [["gridRenderer": ["items": [collection("VLfirst")], "continuations": [next("grid-two")]]]],
                "continuations": [next("sections-two")],
            ],
        ]]]]]]])
        let page = try parse(data, preservesOccurrences: false)
        XCTAssertEqual(page.token, "grid-two")
    }

    func testSectionCursorStillPagesShelvesWithoutTheirOwnCursor() throws {
        let data = json(["contents": ["sectionListRenderer": [
            "contents": [["musicCarouselShelfRenderer": ["contents": [collection("VLfirst")]]]],
            "continuations": [next("sections-two")],
        ]]])
        let page = try parse(data, preservesOccurrences: false)
        XCTAssertEqual(page.token, "sections-two")
    }

    func testRefreshCursorIsNotANextPage() throws {
        let refreshOnly = json(["contents": ["sectionListRenderer": ["contents": [["musicShelfRenderer": [
            "contents": [song("one")], "continuations": [["reloadContinuationData": ["continuation": "refresh"]]],
        ]]]]]])
        XCTAssertNil(try parse(refreshOnly, preservesOccurrences: false).token)

        let both = json(["contents": ["sectionListRenderer": ["contents": [["musicShelfRenderer": [
            "contents": [song("one")],
            "continuations": [["reloadContinuationData": ["continuation": "refresh"]], next("shelf-two")],
        ]]]]]])
        XCTAssertEqual(try parse(both, preservesOccurrences: false).token, "shelf-two")
    }

    func testUnreadablePlaylistCursorDoesNotLookLikeTheLastPage() throws {
        let cursors: [[String: Any]] = [
            ["continuationItemRenderer": [String: Any]()],
            continuationItem(""),
            ["continuationItemRenderer": ["continuationEndpoint": ["commandExecutorCommand": ["commands": [
                ["playlistVotingRefreshPopupCommand": [String: Any]()],
            ]]]]],
        ]
        for cursor in cursors {
            XCTAssertThrowsError(try parse(playlistPage(shelf: ["contents": [song("one"), cursor]]))) {
                XCTAssertEqual($0 as? MusicServiceError, .unsupportedResponse)
            }
        }
    }

    func testUnreadableContainerCursorDoesNotLookLikeTheLastPage() throws {
        let cursors: [Any] = [
            [["nextContinuationData": [String: Any]()]],
            [next("")],
            [["unknownContinuationData": ["continuation": "unknown"]]],
            "unexpected-shape",
        ]
        for cursor in cursors {
            let data = json(["continuationContents": ["gridContinuation": [
                "items": [collection("VLsecond")], "continuations": cursor,
            ]]])
            XCTAssertThrowsError(try parse(data, preservesOccurrences: false)) {
                XCTAssertEqual($0 as? MusicServiceError, .unsupportedResponse)
            }
        }
    }

    func testUnreadableAppendedCursorIsRejected() throws {
        let data = json(["onResponseReceivedActions": [["appendContinuationItemsAction": [
            "continuationItems": [song("two"), continuationItem("")],
        ]]]])
        XCTAssertThrowsError(try parse(data)) {
            XCTAssertEqual($0 as? MusicServiceError, .unsupportedResponse)
        }
    }

    func testCollectionCursorStillWinsOverUnreadableParentCursor() throws {
        let data = json(["contents": ["sectionListRenderer": [
            "contents": [["gridRenderer": ["items": [collection("VLfirst")], "continuations": [next("grid-two")]]]],
            "continuations": [["unknownContinuationData": [String: Any]()]],
        ]]])
        XCTAssertEqual(try parse(data, preservesOccurrences: false).token, "grid-two")
    }

    func testUnreadableSuggestionsCursorIsIgnoredAfterPlaylistEnds() throws {
        let data = json(["continuationContents": ["sectionListContinuation": [
            "contents": [["musicPlaylistShelfRenderer": ["contents": [song("two")]]]],
            "continuations": [["unknownContinuationData": [String: Any]()]],
        ]]])
        XCTAssertNil(try parse(data).token)
    }

    private func parse(_ data: Data, preservesOccurrences: Bool = true) throws -> ParsedMusicPage {
        try MusicResponseParser.parse(data, preservesOccurrences: preservesOccurrences)
    }

    /// A two-column playlist page whose section list carries a cursor for suggestions.
    private func playlistPage(shelf: [String: Any]) -> Data {
        json(["contents": ["twoColumnBrowseResultsRenderer": [
            "tabs": [["tabRenderer": ["content": ["sectionListRenderer": ["contents": [
                ["musicResponsiveHeaderRenderer": ["title": ["runs": [["text": "Playlist"]]]]],
            ]]]]]],
            "secondaryContents": ["sectionListRenderer": [
                "contents": [["musicPlaylistShelfRenderer": shelf]],
                "continuations": [next("suggestions")],
            ]],
        ]]])
    }
}

private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
private func next(_ token: String) -> [String: Any] { ["nextContinuationData": ["continuation": token]] }
private func continuationItem(_ token: String) -> [String: Any] {
    ["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": token]]]]
}
private func song(_ id: String) -> [String: Any] {
    ["musicResponsiveListItemRenderer": ["playlistItemData": ["videoId": id],
        "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Title " + id]]]]]]]]
}
private func collection(_ id: String) -> [String: Any] {
    ["musicTwoRowItemRenderer": ["title": ["runs": [["text": "Collection"]]],
        "navigationEndpoint": ["browseEndpoint": ["browseId": id,
            "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_PLAYLIST"]]]]]]
}
