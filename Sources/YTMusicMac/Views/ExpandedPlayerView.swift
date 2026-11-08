import SwiftUI

/// Shares the existing playback owner and display clock with the main window.
struct ExpandedPlayerView: View {
    let session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ArtworkView(url: session.currentTrack?.artworkURL, size: 280,
                            videoID: session.currentTrack?.id)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(session.currentTrack?.title ?? "Choose a Song")
                        .font(.title.bold()).multilineTextAlignment(.center)
                        .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                    Text(session.currentTrack?.artist ?? "Open your library or search for music.")
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    if let track = session.currentTrack {
                        HStack {
                            ExplicitContentBadge(track: track)
                            TrackMetadataMenu(track: track, session: session)
                            TrackRatingMenu(session: session, track: track)
                            MusicLinkActions(track: track)
                        }
                    }
                }
                SeekView(session: session)
                HStack(spacing: 32) {
                    ShuffleButton(session: session)
                    TransportButtons(session: session)
                    RepeatButton(session: session)
                }
                HStack(spacing: 16) {
                    VolumeView(session: session)
                    AudioOutputPicker().frame(width: 24, height: 24)
                }
                CompactPlayerDestinations(session: session)
                Button("Open Main Window", systemImage: "macwindow") { openWindow(id: "main") }
                RadioStatusView(session: session)
                if let message = session.player.errorMessage {
                    InlineMessage(message: message, actionTitle: "Retry", action: session.retryPlayback)
                }
            }
            .padding(28)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 390, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct CompactPlayerDestinations: View {
    let session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 20) {
            Button("Lyrics", systemImage: "text.quote") { openWindow(id: "lyrics") }
                .disabled(session.currentTrack == nil)
            Button("Queue", systemImage: "list.bullet") { openWindow(id: "queue") }
            Button("Now Playing", systemImage: "music.note") { openWindow(id: "now-playing") }
        }
        .buttonStyle(.borderless)
    }
}
