import Foundation
import XCTest
@testable import YouTubeMusic

final class MusicLibraryMetadataTests: XCTestCase {
    func testAnEditableCurrentHeaderPermitsEditingWithoutAssumingDeletion() throws {
        let result = try parse(header: ["musicEditablePlaylistDetailHeaderRenderer": ["header": [
            "musicDetailHeaderRenderer": ["title": ["runs": [["text": "Playlist"]]]],
        ]]], rows: [])
        XCTAssertTrue(result.playlistCapabilities.canRename)
        XCTAssertTrue(result.playlistCapabilities.canAddItems)
        XCTAssertTrue(result.playlistCapabilities.canRemoveItems)
        XCTAssertFalse(result.playlistCapabilities.canDelete)
    }

    func testExplicitNoneditableHeaderOverridesConflictingControls() throws {
        let result = try parse(header: ["musicEditablePlaylistDetailHeaderRenderer": [
            "isEditable": false, "deletePlaylistEndpoint": ["playlistId": "PLexample"],
        ]], rows: [])
        XCTAssertEqual(result.playlistCapabilities, MusicPlaylistCapabilities())
        let malformed = try parse(header: ["musicEditablePlaylistDetailHeaderRenderer": true], rows: [])
        XCTAssertEqual(malformed.playlistCapabilities, MusicPlaylistCapabilities())
    }

    func testDeletePermissionRequiresACurrentHeaderCommandNotTextOrAnotherRowsMenu() throws {
        let endpoint: [String: Any] = ["urlEndpoint": ["url": "https://music.youtube.com/playlist/delete?list=PLexample"]]
        let allowed = try parse(header: ["musicDetailHeaderRenderer": ["menu": endpoint]], rows: [])
        XCTAssertTrue(allowed.playlistCapabilities.canDelete)
        let text = try parse(header: ["musicDetailHeaderRenderer": ["title": ["runs": [["text": "playlist/delete"]]]]],
                             rows: [["musicTwoRowItemRenderer": ["menu": endpoint]]])
        XCTAssertEqual(text.playlistCapabilities, MusicPlaylistCapabilities())
        for address in ["https://music.youtube.com.evil.example/playlist/delete", "http://music.youtube.com/playlist/delete",
                        "https://music.youtube.com/playlist/delete-extra", "https://user@music.youtube.com/playlist/delete"] {
            let rejected = try parse(header: ["musicDetailHeaderRenderer": ["urlEndpoint": ["url": address]]], rows: [])
            XCTAssertFalse(rejected.playlistCapabilities.canDelete)
        }
    }

    func testLikeStatesStayAttachedToTheMatchingTrackAndUnknownRemainsAbsent() throws {
        let result = try parse(header: [:], rows: [
            row("liked", status: "LIKE"), row("unliked", status: "INDIFFERENT"),
            row("unknown", status: "NEW_STATUS"), row("wrong-target", status: "LIKE", target: "other"),
        ])
        XCTAssertEqual(result.likeStates, ["liked": true, "unliked": false])
    }

    func testConflictingLikeStatesAcrossDuplicateRowsRemainUnknown() throws {
        let result = try parse(header: [:], rows: [row("same", status: "LIKE"), row("same", status: "INDIFFERENT"),
                                                   row("same", status: "LIKE")])
        XCTAssertTrue(result.likeStates.isEmpty)
        XCTAssertEqual(result.playlistItems.count, 3)
    }

    private func parse(header: [String: Any], rows: [[String: Any]]) throws -> ParsedMusicPage {
        let data = try JSONSerialization.data(withJSONObject: ["header": header,
            "contents": ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": ["contents": rows]]]]]])
        return try MusicResponseParser.parse(data, preservesOccurrences: true)
    }

    private func row(_ id: String, status: String, target: String? = nil) -> [String: Any] {
        var like: [String: Any] = ["likeStatus": status]
        if let target { like["target"] = ["videoId": target] }
        return ["musicResponsiveListItemRenderer": ["playlistItemData": ["videoId": id],
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Song"]]]]]],
            "menu": ["menuRenderer": ["topLevelButtons": [["likeButtonRenderer": like]]]]]]
    }
}
