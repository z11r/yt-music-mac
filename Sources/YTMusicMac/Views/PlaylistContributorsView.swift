import SwiftUI
import YouTubeMusic

/// An explicit presentation keeps its original admission identity across view refreshes.
struct PlaylistContributorsPresentation: Identifiable {
    let id = UUID()
    let profile: UUID
    let account: UUID
    let destination: MusicDestination
    let collaboration: MusicPlaylistCollaboration

    @MainActor func isCurrent(in session: AppSession) -> Bool {
        session.acceptsProfileActions && session.account.isSignedIn && !session.account.isWorking &&
        session.accountGeneration == account && session.playbackProfileGeneration == profile &&
        session.destination == destination && session.page?.collectionHeader?.collaboration == collaboration
    }

    func removeIfCurrent(from current: inout Self?) {
        if current?.id == id { current = nil }
    }
}

/// One private, bounded image cache for the currently presented attribution.
/// No person metadata enters the shared artwork cache or a persistent store.
struct PlaylistContributorsView: View {
    let collaboration: MusicPlaylistCollaboration
    let isCurrent: @MainActor @Sendable () -> Bool
    @State private var cache = ArtworkCache(memory: BoundedMemoryCache(
        byteLimit: 1_024 * 1_024, countLimit: 8, observesMemoryPressure: false))

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playlist Contributors").font(.headline)
            if isCurrent(), !collaboration.avatarURLs.isEmpty {
                HStack(spacing: 8) {
                    ForEach(collaboration.avatarURLs, id: \.self) { url in
                        ContributorPortrait(url: url, cache: cache, isCurrent: isCurrent)
                    }
                }
            }
            ScrollView {
                if isCurrent() {
                    Text(verbatim: collaboration.label).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Open this playlist again to view its contributors.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16).frame(width: 360, height: 180)
        .onDisappear { let cache = cache; Task { await cache.clear() } }
    }
}

private struct ContributorPortrait: View {
    let url: URL
    let cache: ArtworkCache
    let isCurrent: @MainActor @Sendable () -> Bool
    @State private var loaded: DecodedArtwork?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.allowsProfileArtworkLoading) private var allowsLoading

    private struct Request: Equatable {
        let artwork: ArtworkRequest
        let allowed: Bool
    }
    var body: some View {
        let artwork = ArtworkRequest(url: url, videoID: nil,
            pixels: min(128, max(64, Int((32 * displayScale).rounded(.up)))))
        let allowed = allowsLoading && isCurrent()
        let image = allowed ? loaded ?? cache.memory.value(for: artwork.cacheKey) : nil
        ZStack {
            Circle().fill(.quaternary)
            if let image {
                Image(decorative: image.image, scale: displayScale).resizable().scaledToFill()
            } else { Image(systemName: "person.crop.circle").foregroundStyle(.secondary) }
        }
        .frame(width: 32, height: 32).clipShape(Circle()).accessibilityHidden(true)
        .task(id: Request(artwork: artwork, allowed: allowed)) {
            guard allowed, isCurrent(), !Task.isCancelled else { return }
            let image = await cache.image(for: artwork, admission: ArtworkLoadAdmission(isCurrent: isCurrent))
            guard !Task.isCancelled, isCurrent() else { return }
            loaded = image
        }
    }
}
