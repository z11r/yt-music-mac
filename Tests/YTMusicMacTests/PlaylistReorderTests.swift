import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

struct PlaylistReorderTests {
    private let items = ["first=", "second=", "third="].map {
        MusicPlaylistItem(track: Track(id: "same-song", title: "Same song", artist: "Fixture"), setVideoID: $0)
    }

    @Test func movesOneDuplicateOccurrenceRelativeToServiceOrder() {
        #expect(PlaylistReorder.action(playlistID: "PLtest", index: 1, direction: .up, items: items, hasMore: false, isFiltered: false) ==
            .movePlaylistItem(playlistID: "PLtest", item: items[1].removalReference!, before: items[0].removalReference))
        #expect(PlaylistReorder.action(playlistID: "PLtest", index: 0, direction: .down, items: items, hasMore: false, isFiltered: false) ==
            .movePlaylistItem(playlistID: "PLtest", item: items[0].removalReference!, before: items[2].removalReference))
    }

    @Test func moveToEndRequiresTheActualCollectionEnd() {
        #expect(PlaylistReorder.action(playlistID: "PLtest", index: 1, direction: .down, items: items, hasMore: false, isFiltered: false) ==
            .movePlaylistItem(playlistID: "PLtest", item: items[1].removalReference!, before: nil))
        #expect(PlaylistReorder.action(playlistID: "PLtest", index: 1, direction: .down, items: items, hasMore: true, isFiltered: false) == nil)
        #expect(PlaylistReorder.action(playlistID: "PLtest", index: 2, direction: .down, items: items, hasMore: true, isFiltered: false) == nil)
        #expect(PlaylistReorder.action(playlistID: "PLtest", index: 0, direction: .up, items: items, hasMore: false, isFiltered: false) == nil)
    }

    @Test func filteredMissingAndInvalidOccurrencesNeverOfferAServiceMove() {
        #expect(PlaylistReorder.action(playlistID: "PLtest", index: 1, direction: .up, items: items, hasMore: false, isFiltered: true) == nil)
        #expect(PlaylistReorder.action(playlistID: "PLtest", index: -1, direction: .up, items: items, hasMore: false, isFiltered: false) == nil)
        let missing = [MusicPlaylistItem(track: items[0].track), items[1]]
        #expect(PlaylistReorder.action(playlistID: "PLtest", index: 1, direction: .up, items: missing, hasMore: false, isFiltered: false) == nil)
        #expect(PlaylistReorder.action(playlistID: "PLtest", index: 1, direction: .up, items: [items[0], items[0]], hasMore: false, isFiltered: false) == nil)
    }

    @Test func newPlaylistPermissionsDoNotBorrowRenameOrBasicEditGrants() {
        let actions: [MusicLibraryEditAction] = [.setPlaylistDescription(id: "PLtest", description: "New"),
            .setPlaylistPrivacy(id: "PLtest", privacy: .public),
            .movePlaylistItem(playlistID: "PLtest", item: items[1].removalReference!, before: items[0].removalReference)]
        let flags: [MusicPlaylistCapabilities] = [.init(canEditDescription: true), .init(canEditPrivacy: true), .init(canReorder: true)]
        for (index, action) in actions.enumerated() {
            #expect(!LibraryEditPolicy.permits(action, capabilities: .init(canRename: true, canDelete: true, canAddItems: true, canRemoveItems: true)))
            #expect(LibraryEditPolicy.playlistID(for: action) == "PLtest")
            #expect(LibraryEditPolicy.usesClientPreflight(action))
            for (flagIndex, flag) in flags.enumerated() { #expect(LibraryEditPolicy.permits(action, capabilities: flag) == (index == flagIndex)) }
        }
    }
}
