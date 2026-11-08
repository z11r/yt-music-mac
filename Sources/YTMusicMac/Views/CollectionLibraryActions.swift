import SwiftUI
import YouTubeMusic

struct CollectionLibraryActions: View {
    let session: AppSession
    let page: MusicPage

    var body: some View {
        Group {
            if case let .collection(collection) = session.destination {
                if collection.kind == .album, let state = page.albumLibraryState {
                    let action = MusicLibraryEditAction.setAlbumSaved(browseID: collection.id, playlistID: state.playlistID, saved: !state.isSaved)
                    if session.canSubmitLibraryEdit(action) {
                        Button(state.isSaved ? "Remove Album from Library" : "Save Album to Library",
                               systemImage: state.isSaved ? "checkmark.circle.fill" : "plus.circle") {
                            session.submitLibraryEdit(action)
                        }
                    }
                } else if collection.kind == .artist, let state = page.artistSubscription {
                    let action = MusicLibraryEditAction.setArtistSubscribed(browseID: collection.id, channelID: state.channelID,
                                                                            subscribed: !state.isSubscribed)
                    if session.canSubmitLibraryEdit(action) {
                        Button(state.isSubscribed ? "Unfollow Artist" : "Follow Artist",
                               systemImage: state.isSubscribed ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus") {
                            session.submitLibraryEdit(action)
                        }
                    }
                }
            }
        }
        .disabled(session.isEditingLibrary)
    }
}
