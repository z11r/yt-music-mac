import Foundation
import Observation
import YouTubeMusic

@MainActor @Observable
final class MusicLinkState {
    var showsSheet = false
    var error: String?
    var isReady = false
    @ObservationIgnored var pending: URL?
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored var task: Task<Void, Never>?
}

extension AppSession {
    func receiveMusicLink(_ url: URL) {
        guard MusicLink(url: url) != nil else {
            links.error = "Open a YouTube Music song, album, artist, or playlist link."
            return
        }
        links.pending = url
        processPendingMusicLink()
    }

    func processPendingMusicLink() {
        guard links.isReady, let url = links.pending, let link = MusicLink(url: url) else { return }
        links.pending = nil
        links.task?.cancel()
        links.generation = UUID()
        let generation = links.generation
        links.error = nil
        let playbackRequest = beginScriptedPlaybackRequest()
        switch link {
        case let .track(id):
            guard account.isSignedIn else {
                links.error = "Sign in, then open the song link again."
                openAccount()
                return
            }
            links.task = Task { [weak self] in
                guard let self else { return }
                do { _ = try await self.playScriptedVideo(id, requestGeneration: playbackRequest) }
                catch is CancellationError { return }
                catch AppScriptingError.superseded { return }
                catch {
                    guard self.links.generation == generation, !Task.isCancelled else { return }
                    self.links.error = "The linked song could not be opened. Your existing queue has been kept."
                }
            }
        case let .playlist(id):
            navigate(to: .collection(MusicCollection(id: id, kind: .playlist, title: "Playlist")))
        case let .album(id):
            navigate(to: .collection(MusicCollection(id: id, kind: .album, title: "Album")))
        case let .artist(id):
            navigate(to: .collection(MusicCollection(id: id, kind: .artist, title: "Artist")))
        }
    }

    func cancelMusicLink() {
        links.task?.cancel()
        links.task = nil
        links.pending = nil
        links.generation = UUID()
    }
}
