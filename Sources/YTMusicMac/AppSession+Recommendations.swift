import Foundation
import MusicCore

extension AppSession {
    var canPreviewRecommendations: Bool {
        acceptsProfileActions && account.isSignedIn && !isSceneCheck && !isShuttingDown && !collectionPlayback.isLoading &&
            !collectionPlayback.canRetry && !radio.isStartingCollectionRadio &&
            queue.entries.count < QueueRecommendations.queueLimit && queue.currentTrack.map(QueueRecommendations.supports) == true
    }

    func previewQueueRecommendations() {
        guard canPreviewRecommendations, let seed = queue.currentTrack else { return }
        let context = recommendationContext
        recommendations.start(seed: seed, queue: queue, context: context,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return self.canPreviewRecommendations && self.recommendationContext == context
            }, append: { [weak self] tracks in
                guard let self, self.canPreviewRecommendations, self.recommendationContext == context else { return }
                self.queue.append(tracks, origin: .recommendation)
                self.saveQueue()
            })
    }
}
