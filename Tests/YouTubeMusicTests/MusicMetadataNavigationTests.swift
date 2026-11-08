import Foundation
import XCTest
@testable import YouTubeMusic

final class MusicMetadataNavigationTests: XCTestCase {
    func testTracksRetainAlbumAndAllArtistIdentities() throws {
        let page = try parse([row(metadata: [run("First", id: "UCfirst"), ["text": " & "],
                                               run("Second", id: "UCsecond"), run("Album", id: "MPREalbum")])])
        let track = try XCTUnwrap(page.items.compactMap { if case let .track(track) = $0 { track } else { nil } }.first)
        XCTAssertEqual(track.artist, "First, Second")
        XCTAssertEqual(track.artistReferences?.map(\.id), ["UCfirst", "UCsecond"])
        XCTAssertEqual(track.album, "Album")
        XCTAssertEqual(track.albumReference?.id, "MPREalbum")
        XCTAssertNil(track.isExplicit)
    }

    func testUnlinkedOrFilteredMetadataStaysDisplayTextWithoutGuessedLinks() throws {
        let page = try parse([row(metadata: [["text": "Unlinked Artist"], run("Filtered Album", id: "MPREalbum", params: "filtered")])])
        let track = try XCTUnwrap(page.items.compactMap { if case let .track(track) = $0 { track } else { nil } }.first)
        XCTAssertEqual(track.artist, "Unlinked Artist")
        XCTAssertEqual(track.album, "Filtered Album")
        XCTAssertNil(track.artistReferences)
        XCTAssertNil(track.albumReference)
        XCTAssertNil(track.isExplicit)
    }

    func testFilteredArtistDoesNotSuppressALaterCatalogIdentity() throws {
        let page = try parse([row(metadata: [run("Artist", id: "UCartist", params: "filtered"), run("Artist", id: "UCartist")])])
        guard case let .track(track) = try XCTUnwrap(page.items.first) else { return XCTFail("Expected track") }
        XCTAssertEqual(track.artistReferences?.map(\.id), ["UCartist"])
    }

    func testExplicitBadgeIsPositiveEvidenceAndOtherBadgesDoNotMeanClean() throws {
        for key in ["badges", "subtitleBadges"] {
            var explicit = row(metadata: [])
            var renderer = try XCTUnwrap(explicit["musicResponsiveListItemRenderer"] as? [String: Any])
            renderer[key] = [["musicInlineBadgeRenderer": ["icon": ["iconType": "MUSIC_EXPLICIT_BADGE"]]]]
            explicit["musicResponsiveListItemRenderer"] = renderer
            let page = try parse([explicit])
            guard case let .track(track) = try XCTUnwrap(page.items.first) else { return XCTFail("Expected track") }
            XCTAssertEqual(track.isExplicit, true)
        }
        var other = row(metadata: [])
        var renderer = try XCTUnwrap(other["musicResponsiveListItemRenderer"] as? [String: Any])
        renderer["badges"] = [["musicInlineBadgeRenderer": ["icon": ["iconType": "OTHER_BADGE"]]]]
        other["musicResponsiveListItemRenderer"] = renderer
        guard case let .track(track) = try XCTUnwrap(parse([other]).items.first) else { return XCTFail("Expected track") }
        XCTAssertNil(track.isExplicit)
    }

    func testOnlyServiceGreyOutPolicyCountsAsUnavailableAndIsNeverPlayable() throws {
        var unavailable = row(metadata: [])
        var renderer = try XCTUnwrap(unavailable["musicResponsiveListItemRenderer"] as? [String: Any])
        renderer["musicItemRendererDisplayPolicy"] = "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
        unavailable["musicResponsiveListItemRenderer"] = renderer
        let page = try parse([row(metadata: []), unavailable, unavailable])
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.playlistItems.count, 1)
        XCTAssertEqual(page.unavailableItemCount, 2)
    }

    private func parse(_ rows: [[String: Any]]) throws -> ParsedMusicPage {
        let object: [String: Any] = ["contents": ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": ["contents": rows]]]]]]
        return try MusicResponseParser.parse(JSONSerialization.data(withJSONObject: object), preservesOccurrences: true)
    }
    private func row(metadata: [[String: Any]]) -> [String: Any] {
        let columns: [[String: Any]] = [
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Song"]]]]],
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": metadata]]]
        ]
        return ["musicResponsiveListItemRenderer": ["playlistItemData": ["videoId": "song"], "flexColumns": columns]]
    }
    private func run(_ title: String, id: String, params: String? = nil) -> [String: Any] {
        var browse: [String: Any] = ["browseId": id]
        if let params { browse["params"] = params }
        return ["text": title, "navigationEndpoint": ["browseEndpoint": browse]]
    }
}
