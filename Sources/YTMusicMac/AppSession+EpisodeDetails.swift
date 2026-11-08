import Foundation
import MusicCore
import YouTubeMusic

struct EpisodeDetailsTarget: Equatable {
    let profile: UUID
    let account: UUID
    let queueRevision: QueueRevision
    let entry: UUID
    let occurrence: PlaybackOccurrence?
    let reference: MusicEpisodeDetailsReference
}
extension AppSession {
    var episodeDetailsTarget: EpisodeDetailsTarget? {
        guard acceptsProfileActions, account.isSignedIn, !account.isWorking,
              let track = currentTrack, let entry = queue.currentEntryID,
              let reference = EpisodeDetailsSession.reference(for: track) else { return nil }
        return .init(profile: playbackProfileGeneration, account: accountGeneration, queueRevision: queue.revision,
            entry: entry, occurrence: queue.currentOccurrence, reference: reference)
    }
    @discardableResult func openEpisodeDetails(_ target: EpisodeDetailsTarget) -> Bool {
        guard episodeDetailsTarget == target, let track = currentTrack else { return false }
        return episodeDetails.open(track: track) { [weak self] in self?.episodeDetailsTarget == target }
    }
}
