import Testing
import YouTubeMusic
@testable import YTMusicMac

struct LibraryEditPolicyTests {
    @Test func missingOrUnrelatedCapabilityDoesNotEnableAnEdit() {
        let actions: [MusicLibraryEditAction] = [.renamePlaylist(id: "PLtest", title: "Name"),
            .deletePlaylist(id: "PLtest"), .addItems(playlistID: "PLtest", videoIDs: ["abcDEF12_-3"], allowDuplicates: false),
            .removeItems(playlistID: "PLtest", items: [PlaylistItemReference(videoID: "abcDEF12_-3", setVideoID: "occurrence")])]
        let capabilities: [MusicPlaylistCapabilities] = [
            .init(canRename: true), .init(canDelete: true), .init(canAddItems: true), .init(canRemoveItems: true),
        ]
        for (index, action) in actions.enumerated() {
            #expect(!LibraryEditPolicy.permits(action, capabilities: .init()))
            #expect(LibraryEditPolicy.playlistID(for: action) == "PLtest")
            for (capabilityIndex, capability) in capabilities.enumerated() {
                #expect(LibraryEditPolicy.permits(action, capabilities: capability) == (index == capabilityIndex))
            }
        }
    }

    @Test func creationAndLikesDoNotUseAnotherPlaylistsPermission() {
        #expect(LibraryEditPolicy.playlistID(for: .setLiked(videoID: "abcDEF12_-3", liked: true)) == nil)
        #expect(LibraryEditPolicy.playlistID(for: .createPlaylist(title: "New", description: nil,
            privacy: .private, videoIDs: [])) == nil)
        #expect(LibraryEditPolicy.normalizedID("VLPLtest") == "PLtest")
        #expect(LibraryEditPolicy.normalizedID("PLtest") == "PLtest")
    }
}
