import MusicCore
import SwiftUI

struct EpisodeDetailsPanel: View {
    let session: AppSession
    @State private var pendingTimestamp: UUID?
    @State private var timestampReply: WebTimestampSeekReply?
    @State private var timestampFeedback: (EpisodeTimestampSource, String)?
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
                Button(EpisodeDetailsText.text("Close")) { cancelTimestampReceipt(); session.episodeDetails.clear() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 430, idealWidth: 560, maxWidth: 760, minHeight: 360, idealHeight: 600, maxHeight: 720)
        .onChange(of: session.episodeDetailsTarget) { _, _ in cancelTimestampReceipt(); session.episodeDetails.discardIfStale() }
        .onDisappear { cancelTimestampReceipt(); session.episodeDetails.clear() }
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
                        Text(EpisodeDetailsText.text("These positions come from YouTube Music description links. They are not inferred chapters."))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(EpisodeDetailsText.text("Go to a reference while this episode is playing and its current content is confirmed. Ads, loading and paused playback are unavailable."))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(details.timestamps, id: \.sourceIndex) { timestamp in
                            let target = session.episodeTimestampTarget(sourceIndex: timestamp.sourceIndex)
                            EpisodeTimestampReferenceRow(session: session, target: target,
                                time: EpisodeDetailsTimestampFormatter.text(timestamp.seconds) ?? "—", label: timestamp.text,
                                isPending: pendingTimestamp != nil, seek: seek)
                        }
                    }
                    if let (source, feedback) = timestampFeedback, session.episodeDetails.acceptsTimestamp(source) {
                        Text(verbatim: feedback).font(.caption).accessibilityAddTraits(.updatesFrequently)
                    }
                    Text(EpisodeDetailsText.text("Provided by YouTube Music")).font(.caption).foregroundStyle(.secondary)
                }.textSelection(.enabled).padding(24)
            }
        }
    }
    private func seek(_ target: EpisodeTimestampActionTarget) {
        guard pendingTimestamp == nil else { return }
        let id = UUID(), reply = WebTimestampSeekReply()
        pendingTimestamp = id; timestampReply = reply; timestampFeedback = nil
        // Dispatch now, before starting the asynchronous receipt waiter.
        session.seekEpisodeTimestamp(target) { reply.finish($0) }
        Task { @MainActor in
            let result = await reply.wait(start: { _ in })
            guard pendingTimestamp == id else { return }
            pendingTimestamp = nil; timestampReply = nil
            guard session.episodeDetails.acceptsTimestamp(target.source) else { return }
            let text: String
            switch result {
            case .confirmed: text = EpisodeDetailsText.text("Reference position confirmed.")
            case .rejected: text = EpisodeDetailsText.text("This reference is unavailable for the current playback state.")
            case .unconfirmed, .cancelled: text = EpisodeDetailsText.text("The position change could not be confirmed. Check playback before trying again.")
            }
            timestampFeedback = (target.source, text)
        }
    }
    private func cancelTimestampReceipt() {
        pendingTimestamp = nil; timestampFeedback = nil
        timestampReply?.finish(.cancelled); timestampReply = nil
    }
    private func message(_ text: String) -> some View { Text(verbatim: text).multilineTextAlignment(.center).padding(20) }
}

/// Readiness changes affect this small row; progress-clock proofs are never read during rendering.
private struct EpisodeTimestampReferenceRow: View {
    let session: AppSession
    let target: EpisodeTimestampActionTarget?
    let time: String
    let label: String
    let isPending: Bool
    let seek: (EpisodeTimestampActionTarget) -> Void
    var body: some View {
        HStack {
            Text(verbatim: time).monospacedDigit()
            if !label.isEmpty { Text(verbatim: label).foregroundStyle(.secondary) }
            Spacer()
            Button(EpisodeDetailsText.text("Go to Reference")) { if let target { seek(target) } }
                .disabled(isPending || target.map { !session.canSeekEpisodeTimestamp($0) } != false)
                .accessibilityLabel(EpisodeDetailsText.text("Go to Reference") + " " + time)
        }
    }
}
