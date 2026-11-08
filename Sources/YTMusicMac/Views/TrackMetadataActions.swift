import MusicCore
import SwiftUI
import YouTubeMusic

/// Only identities established by the service offer navigation. Display strings
/// alone never become guessed artist or album destinations.
struct TrackMetadataActions: View {
    let track: Track
    let session: AppSession

    var body: some View {
        if let album = track.albumReference {
            Button("Go to Album: \(album.title)") {
                session.navigate(to: .collection(MusicCollection(id: album.id, kind: .album, title: album.title)))
            }
        }
        ForEach(track.artistReferences ?? []) { artist in
            Button("Go to Artist: \(artist.title)") {
                session.navigate(to: .collection(MusicCollection(id: artist.id, kind: .artist, title: artist.title)))
            }
        }
    }
}

struct TrackMetadataMenu: View {
    let track: Track
    let session: AppSession

    var body: some View {
        if track.albumReference != nil || !(track.artistReferences ?? []).isEmpty {
            Menu {
                TrackMetadataActions(track: track, session: session)
            } label: {
                Label("Album and Artists", systemImage: "info.circle")
            }
            .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
            .help("Open album or artist")
        }
    }
}

struct ExplicitContentBadge: View {
    let track: Track

    var body: some View {
        if track.isExplicit == true {
            Text("E").font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 3).padding(.vertical, 1)
                .foregroundStyle(.secondary).background(.quaternary, in: RoundedRectangle(cornerRadius: 2))
                .accessibilityLabel("Explicit content").help("Explicit content")
        }
    }
}

struct UnavailableMusicNotice: View {
    let page: MusicPage

    var body: some View {
        if page.unavailableItemCount > 0 {
            Text("\(page.unavailableItemCount) unavailable items excluded from the loaded pages")
                .font(.caption).foregroundStyle(.secondary)
        }
        if page.hasUnsupportedContent {
            Text("Some content on these loaded pages uses a format this version cannot read.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
