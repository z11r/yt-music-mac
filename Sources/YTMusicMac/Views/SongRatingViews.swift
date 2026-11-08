import MusicCore
import SwiftUI
import YouTubeMusic

struct TrackRatingActions: View {
    let session: AppSession
    let track: Track

    var body: some View {
        let current = session.rating(for: track)
        let scope = session.libraryEditingScope
        if track.isCatalogSong && session.canEditRating(.liked) {
            ratingButton(current == .liked ? AppLocalization.text("Remove Like") : AppLocalization.text("Like"),
                         symbol: current == .liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                         target: current == .liked ? .neutral : .liked, scope: scope)
        }
        if track.isCatalogSong && session.canEditRating(.disliked) {
            ratingButton(current == .disliked ? AppLocalization.text("Remove Dislike") : AppLocalization.text("Dislike"),
                         symbol: current == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                         target: current == .disliked ? .neutral : .disliked, scope: scope)
        }
    }

    private func ratingButton(_ title: String, symbol: String, target: MusicRating, scope: UUID) -> some View {
        Button(title, systemImage: symbol) {
            Task {
                guard track.isCatalogSong, session.libraryEditingScope == scope else { return }
                _ = await session.performLibraryEdit(.setRating(videoID: track.id, rating: target))
            }
        }
        .disabled(session.isEditingLibrary)
        .accessibilityLabel("\(title) \(track.title)")
    }
}

struct TrackRatingMenu: View {
    let session: AppSession
    let track: Track

    var body: some View {
        if track.isCatalogSong && session.hasRatingControls {
            let rating = session.rating(for: track)
            Menu { TrackRatingActions(session: session, track: track) } label: {
                Label("Song Rating", systemImage: symbol(rating))
            }
            .menuStyle(.borderlessButton).labelStyle(.iconOnly).fixedSize()
            .foregroundStyle(rating == .liked || rating == .disliked ? Color.accentColor : Color.secondary)
            .accessibilityLabel("Rating for \(track.title)")
            .accessibilityValue(description(rating))
            .help(description(rating))
            .disabled(session.isEditingLibrary)
        }
    }

    private func symbol(_ rating: MusicRating?) -> String {
        switch rating {
        case .liked: "hand.thumbsup.fill"
        case .disliked: "hand.thumbsdown.fill"
        case .neutral: "hand.thumbsup"
        case nil: "questionmark.circle"
        }
    }

    private func description(_ rating: MusicRating?) -> String {
        switch rating {
        case .liked: AppLocalization.text("Liked")
        case .disliked: AppLocalization.text("Disliked")
        case .neutral: AppLocalization.text("No rating")
        case nil: AppLocalization.text("Rating unknown")
        }
    }
}
