import MusicCore
import SwiftUI

struct EpisodeDetailsPanel: View {
    let session: AppSession
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(EpisodeDetailsText.text("Episode Details")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    if let track = session.episodeDetails.track {
                        Text(verbatim: track.title).font(.headline).lineLimit(3)
                        Text(verbatim: track.artist).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Button(EpisodeDetailsText.text("Close")) { session.episodeDetails.clear() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 430, idealWidth: 560, maxWidth: 760, minHeight: 360, idealHeight: 600, maxHeight: 720)
        .onChange(of: session.episodeDetailsTarget) { _, _ in session.episodeDetails.discardIfStale() }
        .onDisappear { session.episodeDetails.clear() }
    }
    @ViewBuilder private var content: some View {
        switch session.episodeDetails.state {
        case .idle: EmptyView()
        case .loading:
            VStack(spacing: 16) {
                ProgressView(EpisodeDetailsText.text("Loading episode details…"))
                Button(EpisodeDetailsText.text("Cancel")) { session.episodeDetails.cancel() }
            }
        case .unavailable:
            VStack(spacing: 16) {
                message(EpisodeDetailsText.text("YouTube Music did not provide episode details."))
                Button(EpisodeDetailsText.text("Try Again")) { session.episodeDetails.retry() }.disabled(session.episodeDetails.isBusy)
            }
        case .failed, .canceled:
            VStack(spacing: 16) {
                message(EpisodeDetailsText.text("Episode details could not be loaded."))
                if session.episodeDetails.isBusy { Text(EpisodeDetailsText.text("The previous request is still finishing.")).font(.caption) }
                Button(EpisodeDetailsText.text("Try Again")) { session.episodeDetails.retry() }.disabled(session.episodeDetails.isBusy)
            }.padding(20)
        case let .available(details):
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(verbatim: details.title).font(.headline)
                    if let show = details.show { Text(verbatim: show).foregroundStyle(.secondary) }
                    if let published = details.publishedText { Text(verbatim: published).font(.subheadline) }
                    if let duration = details.durationText { Text(verbatim: duration).font(.subheadline) }
                    Text(EpisodeDetailsText.text("Description")).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(verbatim: details.description ?? EpisodeDetailsText.text("No description was provided."))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !details.timestamps.isEmpty {
                        Divider()
                        Text(EpisodeDetailsText.text("Source Timestamp References")).font(.headline).accessibilityAddTraits(.isHeader)
                        Text(EpisodeDetailsText.text("These positions come from YouTube Music description links. They are not inferred chapters and do not seek playback."))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(details.timestamps, id: \.sourceIndex) { timestamp in
                            HStack {
                                Text(verbatim: playbackTime(Double(timestamp.seconds))).monospacedDigit()
                                if !timestamp.text.isEmpty { Text(verbatim: timestamp.text).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Text(EpisodeDetailsText.text("Provided by YouTube Music")).font(.caption).foregroundStyle(.secondary)
                }.textSelection(.enabled).padding(24)
            }
        }
    }
    private func message(_ text: String) -> some View { Text(verbatim: text).multilineTextAlignment(.center).padding(20) }
}
