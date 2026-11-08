import SwiftUI

struct RecordingCounterpartPanel: View {
    let session: RecordingCounterpartSession
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(RecordingCounterpartText.text("Other Recording")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(RecordingCounterpartText.text("Close")) { session.clear() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
        }
        .frame(minWidth: 420, idealWidth: 520, maxWidth: 700, minHeight: 340, idealHeight: 420, maxHeight: 600)
        .onDisappear { session.clear() }
    }
    @ViewBuilder private var content: some View {
        switch session.state {
        case .idle: EmptyView()
        case .loading:
            VStack(spacing: 16) {
                ProgressView(RecordingCounterpartText.text("Loading the paired recording…"))
                Button(RecordingCounterpartText.text("Cancel")) { session.cancel() }
            }
        case .unavailable:
            retryMessage(RecordingCounterpartText.text("YouTube Music did not provide a verified paired recording."))
        case .failed, .canceled:
            retryMessage(RecordingCounterpartText.text("The paired recording could not be loaded."))
        case .expired:
            retryMessage(RecordingCounterpartText.text("This review has expired. Load the paired recording again."))
        case let .available(review), let .confirming(review):
            VStack(spacing: 18) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(RecordingCounterpartText.text(review.pair.kind == .song ? "Song" : "Video")).font(.subheadline).foregroundStyle(.secondary)
                        Text(verbatim: review.pair.track.title).font(.headline).lineLimit(4)
                        Text(verbatim: review.pair.track.artist).foregroundStyle(.secondary).lineLimit(3)
                        if let duration = review.pair.track.duration { Text(verbatim: playbackTime(duration)).monospacedDigit() }
                        Text(RecordingCounterpartText.text("This adds the paired recording next in your queue and starts it at the beginning. Your original entry and remaining queue are kept."))
                        Text(RecordingCounterpartText.text("YouTube Music controls playback availability. This does not change audio-only settings or preserve playback position."))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(RecordingCounterpartText.text("Provided by YouTube Music")).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                Button(RecordingCounterpartText.text("Add and Play from Start")) { _ = session.confirm(review.id) }
                    .buttonStyle(.borderedProminent).disabled(session.isBusy)
                if case .confirming = session.state { ProgressView(RecordingCounterpartText.text("Checking this request…")) }
            }
        }
    }
    private func retryMessage(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text(verbatim: message).multilineTextAlignment(.center)
            if session.isBusy { Text(RecordingCounterpartText.text("The previous request is still finishing.")).font(.caption).foregroundStyle(.secondary) }
            Button(RecordingCounterpartText.text("Try Again")) { session.retry() }.disabled(session.isBusy)
        }
    }
}
