import Foundation
import XCTest
@testable import YouTubeMusic

/// Explicit opt-in probes of the public search service. The client has no credentials.
@MainActor
final class MusicSearchLiveTests: XCTestCase {
    func testAnonymousFiltersReturnTheirKindOfResult() async throws {
        guard ProcessInfo.processInfo.environment["YTM_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set YTM_RUN_NETWORK_TESTS=1 to run anonymous service checks.")
        }
        let client = YouTubeMusicClient()
        let expectations: [(MusicSearchFilter, (MusicItem) -> Bool)] = [
            (.songs, { if case .track = $0 { true } else { false } }),
            (.videos, { if case .track = $0 { true } else { false } }),
            (.albums, { kind($0) == .album }),
            (.artists, { kind($0) == .artist }),
            (.communityPlaylists, { kind($0) == .playlist }),
            (.featuredPlaylists, { kind($0) == .playlist }),
        ]
        var songIDs = Set<String>()
        for (filter, matches) in expectations {
            let page = try await client.search(query: "Mozart", filter: filter)
            XCTAssertFalse(page.items.isEmpty, "\(filter) returned nothing")
            XCTAssertTrue(page.items.allSatisfy(matches), "\(filter) returned another kind of item")
            if filter == .songs {
                songIDs = Set(page.tracks.map(\.id))
                let next = try await client.nextPage(XCTUnwrap(page.continuation, "Songs should continue"))
                XCTAssertFalse(next.tracks.isEmpty)
                XCTAssertTrue(next.items.allSatisfy(matches))
            }
            if filter == .videos {
                XCTAssertTrue(songIDs.isDisjoint(with: page.tracks.map(\.id)), "Videos repeated the song results")
            }
        }
    }

    func testAnonymousSuggestions() async throws {
        guard ProcessInfo.processInfo.environment["YTM_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set YTM_RUN_NETWORK_TESTS=1 to run anonymous service checks.")
        }
        let suggestions = try await YouTubeMusicClient().searchSuggestions(for: "moza")
        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertTrue(suggestions.allSatisfy { $0.query.lowercased().contains("moza") })
    }
}

private func kind(_ item: MusicItem) -> MusicCollection.Kind? {
    if case let .collection(value) = item { value.kind } else { nil }
}
