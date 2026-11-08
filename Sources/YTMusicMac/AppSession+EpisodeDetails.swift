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
struct EpisodeTimestampActionTarget: Equatable {
    let details: EpisodeDetailsTarget
    let source: EpisodeTimestampSource
    // Source authority is immutable; playback proof is acquired only at explicit click.
    @MainActor func playbackTarget(isCurrent: () -> Bool, freshProof: () -> PlaybackTimestampSeekTarget?) -> PlaybackTimestampSeekTarget? {
        guard isCurrent(), let occurrence = details.occurrence, let value = freshProof(),
              value.request.position == TimeInterval(source.seconds), value.scope.occurrence == occurrence,
              value.request.identity.context.occurrence == occurrence, isCurrent() else { return nil }
        return value
    }
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

extension AppSession {
    func episodeTimestampTarget(sourceIndex: Int) -> EpisodeTimestampActionTarget? {
        guard let details = episodeDetailsTarget, details.occurrence != nil,
              let source = episodeDetails.timestampSource(at: sourceIndex), source.reference == details.reference else { return nil }
        return .init(details: details, source: source)
    }
    private func timestampSourceIsCurrent(_ target: EpisodeTimestampActionTarget) -> Bool {
        episodeDetailsTarget == target.details && episodeDetails.acceptsTimestamp(target.source)
            && target.source.reference == target.details.reference
    }
    func canSeekEpisodeTimestamp(_ target: EpisodeTimestampActionTarget) -> Bool {
        timestampSourceIsCurrent(target) && player.timestampSeekIsReady && TimeInterval(target.source.seconds) < player.clock.duration
    }
    // Synchronous admission and dispatch: only native proof may refresh after render.
    func seekEpisodeTimestamp(_ target: EpisodeTimestampActionTarget, completion: @escaping @MainActor (WebTimestampSeekOutcome) -> Void) {
        guard let playback = target.playbackTarget(isCurrent: { timestampSourceIsCurrent(target) }, freshProof: {
            player.timestampSeekTarget(position: TimeInterval(target.source.seconds))
        }), prepareSeek(to: playback.request.position, preservingSectionAction: false, confirmsPositionChange: false),
              timestampSourceIsCurrent(target), player.canSeekTimestamp(playback) else { completion(.rejected); return }
        player.seekTimestamp(playback) { [weak self] outcome in
            guard let self, self.timestampSourceIsCurrent(target) else { completion(.unconfirmed); return }
            if outcome.isConfirmed { self.confirmExplicitSeek(); self.saveQueue() }
            completion(outcome)
        }
    }
}
