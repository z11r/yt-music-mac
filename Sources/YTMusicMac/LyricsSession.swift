import Foundation
import Observation
import YouTubeMusic

/// One visible lyrics request, independent of the playback owner. Track/account
/// changes and closing the panel cancel it and fence even an uncancellable reply.
@MainActor @Observable
final class LyricsSession {
    enum State: Equatable {
        case idle, loading, unavailable
        case available(MusicLyrics)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var videoID: String?
    @ObservationIgnored private let fetch: @Sendable (String) async throws -> MusicLyrics
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(fetch: @escaping @Sendable (String) async throws -> MusicLyrics) { self.fetch = fetch }

    func load(videoID: String?) {
        clear()
        guard let videoID else { return }
        self.videoID = videoID
        state = .loading
        let request = generation
        task = Task { [weak self, fetch] in
            do {
                let lyrics = try await fetch(videoID)
                guard let self, !Task.isCancelled, self.generation == request, self.videoID == videoID else { return }
                self.state = lyrics == .unavailable ? .unavailable : .available(lyrics)
            } catch {
                guard let self, !Task.isCancelled, self.generation == request else { return }
                if error is MusicServiceError || error is MusicLyricsError {
                    self.state = .failed(error.localizedDescription)
                } else {
                    self.state = .failed(AppLocalization.text("Could not load lyrics. Try again."))
                }
            }
        }
    }

    func retry() { load(videoID: videoID) }

    func clear() {
        generation = UUID()
        task?.cancel()
        task = nil
        videoID = nil
        state = .idle
    }
}
