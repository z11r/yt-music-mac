import SwiftUI
import MusicCore

struct EpisodeControlsView: View {
    let session: AppSession
    var body: some View {
        if let track = session.currentTrack, track.contentKind == .podcastEpisode, track.episode != nil {
            HStack(spacing: 12) {
                Button("Back \(Int(session.episodePlayback.settings.skipBackward)) seconds", systemImage: "gobackward") { session.skipEpisode(forward: false) }
                    .disabled(!canSkip)
                Button("Forward \(Int(session.episodePlayback.settings.skipForward)) seconds", systemImage: "goforward") { session.skipEpisode(forward: true) }
                    .disabled(!canSkip)
                if !session.player.isPlaying, session.episodePlayback.resumePosition(for: track) > 0 {
                    Button("Resume at \(playbackTime(session.episodePlayback.resumePosition(for: track)))", action: session.resumeEpisode)
                }
                Menu("Episode Options") {
                    Button("Start Episode Over", action: session.startEpisodeOver)
                        .disabled(session.episodePlayback.isLoading)
                    Menu("Skip Backward") {
                        ForEach([5, 10, 15, 30], id: \.self) { seconds in
                            Button("\(seconds) seconds") { session.episodePlayback.setSkipIntervals(backward: Double(seconds), forward: session.episodePlayback.settings.skipForward) }
                        }
                    }
                    .disabled(session.episodePlayback.isLoading || session.episodePlayback.errorMessage != nil)
                    Menu("Skip Forward") {
                        ForEach([15, 30, 45, 60], id: \.self) { seconds in
                            Button("\(seconds) seconds") { session.episodePlayback.setSkipIntervals(backward: session.episodePlayback.settings.skipBackward, forward: Double(seconds)) }
                        }
                    }
                    .disabled(session.episodePlayback.isLoading || session.episodePlayback.errorMessage != nil)
                    if session.episodePlayback.canControlRate {
                        Menu("Playback Speed (\(session.episodePlayback.currentRate?.formatted() ?? "—")×)") {
                            ForEach(session.episodePlayback.availableRates, id: \.self) { rate in
                                let occurrence = session.queue.currentOccurrence
                                Button("\(rate.formatted())×") { Task {
                                    guard let occurrence else { return }
                                    await session.episodePlayback.setRate(rate, expectedOccurrence: occurrence)
                                } }
                            }
                        }
                    }
                }
                if session.episodePlayback.isLoading { ProgressView().controlSize(.mini).accessibilityLabel("Loading local episode progress") }
                if let error = session.episodePlayback.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            .font(.caption).padding(.horizontal, 20).padding(.bottom, 8)
            .disabled(!session.account.isSignedIn)
        }
    }
    private var canSkip: Bool {
        session.player.hasConfirmedPosition && !session.player.isBuffering && session.player.clock.duration > 0 && session.player.errorMessage == nil
    }
}
