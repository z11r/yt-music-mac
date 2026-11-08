import Foundation
import MusicCore

extension AppSession {
    func episodeStatusTarget(for track: Track) -> EpisodePlaybackSession.LocalStatusTarget? {
        guard acceptsProfileActions, account.isSignedIn, !account.isWorking else { return nil }
        return episodePlayback.localStatusTarget(for: track)
    }

    @discardableResult
    func changeEpisodeLocalStatus(_ action: EpisodePlaybackSession.LocalStatusAction, track: Track,
                                  target: EpisodePlaybackSession.LocalStatusTarget, expectedAccountGeneration: UUID) -> Bool {
        guard acceptsProfileActions, account.isSignedIn, !account.isWorking, accountGeneration == expectedAccountGeneration,
              track.contentKind == .podcastEpisode, track.origin != .upload, track.episode?.identity == target.episode else { return false }
        return episodePlayback.changeLocalStatus(action, target: target)
    }
}
