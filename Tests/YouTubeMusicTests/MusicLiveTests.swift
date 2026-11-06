import Foundation
import XCTest
@testable import YouTubeMusic

/// Explicit opt-in probes. This client has no credential provider and can only make anonymous requests.
@MainActor
final class MusicLiveTests: XCTestCase {
    func testAnonymousExactVideoIDLookup() async throws {
        guard ProcessInfo.processInfo.environment["YTM_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set YTM_RUN_NETWORK_TESTS=1 to run anonymous service checks.")
        }
        let client = YouTubeMusicClient()
        let search = try await client.search(query: "Mozart")
        let track = try XCTUnwrap(search.tracks.first)
        let lookup = try await client.search(query: track.id)
        XCTAssertTrue(lookup.tracks.contains { $0.id == track.id }, "Exact video-ID search must return the requested song before scripting can use it.")
        let benchmarkID = "dQw4w9WgXcQ"
        let benchmark = try await client.search(query: benchmarkID)
        XCTAssertTrue(benchmark.tracks.contains { $0.id == benchmarkID }, "The public benchmark song must resolve to its exact video ID.")
    }

    func testAnonymousBrowseSurfaces() async throws {
        guard ProcessInfo.processInfo.environment["YTM_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set YTM_RUN_NETWORK_TESTS=1 to run anonymous service checks.")
        }
        let client = YouTubeMusicClient()
        let home = try await client.home()
        let explore = try await client.explore()
        let search = try await client.search(query: "Mozart")
        XCTAssertFalse(home.items.isEmpty)
        XCTAssertFalse(explore.items.isEmpty)
        XCTAssertFalse(search.items.isEmpty)
        let collections = (search.items + explore.items + home.items).compactMap { item -> MusicCollection? in
            if case let .collection(value) = item { value } else { nil }
        }
        if let album = collections.first(where: { $0.kind == .album }) {
            let page = try await client.album(id: album.id)
            XCTAssertFalse(page.tracks.isEmpty)
        } else { XCTFail("No album was available for the read-only probe") }
        if let artist = collections.first(where: { $0.kind == .artist }) {
            let page = try await client.artist(id: artist.id)
            XCTAssertFalse(page.items.isEmpty)
        } else { XCTFail("No artist was available for the read-only probe") }
        if let playlist = collections.first(where: { $0.kind == .playlist }) {
            let page = try await client.playlist(id: playlist.id)
            XCTAssertFalse(page.tracks.isEmpty)
        } else { XCTFail("No playlist was available for the read-only probe") }
    }
}
