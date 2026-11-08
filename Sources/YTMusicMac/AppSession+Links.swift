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
        guard acceptsProfileActions else { return }
        guard MusicLink(url: url) != nil else {
            links.error = AppLocalization.text("Open a YouTube Music song, album, artist, or playlist link.")
            return
        }
        links.pending = url
        processPendingMusicLink()
    }

    func processPendingMusicLink() {
        guard acceptsProfileActions else { return }
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
                links.error = AppLocalization.text("Sign in, then open the song link again.")
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
                    self.links.error = AppLocalization.text("The linked song could not be opened. Your existing queue has been kept.")
                }
            }
        case let .playlist(id):
            navigate(to: .collection(MusicCollection(id: id, kind: .playlist, title: AppLocalization.text("Playlist"))))
        case let .album(id):
            navigate(to: .collection(MusicCollection(id: id, kind: .album, title: AppLocalization.text("Album"))))
        case let .artist(id):
            navigate(to: .collection(MusicCollection(id: id, kind: .artist, title: AppLocalization.text("Artist"))))
        }
    }

    func cancelMusicLink(keepingPending: Bool = false) {
        links.task?.cancel()
        links.task = nil
        if !keepingPending { links.pending = nil }
        links.generation = UUID()
    }
}
