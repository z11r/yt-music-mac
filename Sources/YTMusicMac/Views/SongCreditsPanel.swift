import MusicCore
import SwiftUI

struct SongCreditsAction: View {
    let track: Track
    let session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let generation = session.accountGeneration
        if track.creditsReference != nil, track.origin != .upload, track.contentKind != .podcastEpisode, track.episode == nil {
            Button("Song Credits") {
                if session.openSongCredits(track: track, expectedAccountGeneration: generation) {
                    openWindow(id: "song-credits")
                }
            }
        }
    }
}

struct SongCreditsPanel: View {
    let session: AppSession
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Song Credits").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    if let track = session.credits.track {
                        Text(track.title).font(.headline)
                        Text(track.artist).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { session.credits.clear(); dismissWindow(id: "song-credits") }
                    .keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 430, idealWidth: 560, minHeight: 360, idealHeight: 600)
        .onDisappear { session.credits.clear() }
    }

    @ViewBuilder private var content: some View {
        switch session.credits.state {
        case .idle:
            ContentUnavailableView("Choose a Song", systemImage: "info.circle",
                description: Text("Open Song Credits from a song's menu when YouTube Music offers them."))
        case .loading:
            VStack(spacing: 16) {
                ProgressView("Loading song credits…")
                Button("Cancel") { session.credits.cancel() }
            }
        case .unavailable:
            ContentUnavailableView("No Song Credits Available", systemImage: "info.circle",
                description: Text("YouTube Music did not supply credits for this recording."))
        case .failed:
            VStack(spacing: 16) {
                ContentUnavailableView("Couldn't Load Song Credits", systemImage: "wifi.exclamationmark",
                    description: Text("The request was stopped or could not finish. Try again to load this song's credits."))
                Button("Try Again") { session.credits.retry() }
            }.padding(20)
        case let .available(sections):
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(.headline).accessibilityAddTraits(.isHeader)
                            Text(section.text).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("Provided by YouTube Music").font(.caption).foregroundStyle(.secondary)
                }.textSelection(.enabled).padding(24)
            }
        }
    }
}
