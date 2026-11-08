import Foundation
import YouTubeMusic

struct CollectionLoadedSummary: Equatable {
    let playableCount: Int
    let knownSeconds: TimeInterval
    let unknownDurationCount: Int
    let isComplete: Bool

    init(page: MusicPage) {
        let tracks = CollectionPresentation.tracks(in: page)
        playableCount = tracks.count
        isComplete = page.continuation == nil && page.unavailableItemCount == 0 && !page.hasUnsupportedContent
        var sum: TimeInterval = 0, unknown = 0
        for track in tracks {
            guard let value = track.duration, value.isFinite, value > 0 else { unknown += 1; continue }
            let next = sum + value
            sum = next.isFinite ? next : .greatestFiniteMagnitude
        }
        knownSeconds = sum; unknownDurationCount = unknown
    }

    func countDescription(episodes: Bool) -> String {
        if episodes {
            return isComplete ? AppLocalization.format("%lld episodes", playableCount)
                : AppLocalization.format("%lld episodes loaded", playableCount)
        }
        return isComplete ? AppLocalization.format("%lld songs", playableCount)
            : AppLocalization.format("%lld songs loaded", playableCount)
    }

    var durationDescription: String? {
        guard playableCount > 0 else { return nil }
        if knownSeconds == 0 { return AppLocalization.text("Loaded duration unknown") }
        let time: String
        if knownSeconds > 3_599_999 { time = AppLocalization.text("more than 999 hours") }
        else if knownSeconds >= 360_000 { time = AppLocalization.format("%lld hours", Int(knownSeconds / 3_600)) }
        else { time = playbackTime(knownSeconds) }
        return unknownDurationCount == 0 ? AppLocalization.format("Loaded playable duration: %@", time)
            : AppLocalization.format("At least %@ loaded · %lld durations unknown", time, unknownDurationCount)
    }
}
