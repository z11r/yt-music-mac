import Foundation
import MusicCore

struct QueueDisplayRow: Identifiable {
    let index: Int
    let entry: QueueEntry
    var id: UUID { entry.id }
}

struct QueueRemainingDuration: Equatable {
    let knownSeconds: TimeInterval
    let unknownCount: Int
    let songCount: Int
}

enum QueuePresentation {
    /// Filtering never changes queue order or replaces occurrence identities.
    static func rows(in entries: [QueueEntry], matching query: String) -> [QueueDisplayRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.enumerated().compactMap { index, entry in
            guard query.isEmpty || entry.track.title.localizedCaseInsensitiveContains(query) ||
                    entry.track.artist.localizedCaseInsensitiveContains(query) ||
                    entry.track.album?.localizedCaseInsensitiveContains(query) == true else { return nil }
            return QueueDisplayRow(index: index, entry: entry)
        }
    }

    /// Completed entries are excluded. An unknown duration is counted, never assumed to be zero.
    static func remaining(in queue: PlaybackQueue, position: TimeInterval,
                          confirmedCurrentDuration: TimeInterval? = nil) -> QueueRemainingDuration {
        let start = queue.currentIndex ?? 0
        let entries = queue.entries.dropFirst(start)
        let position = position.isFinite ? max(0, position) : 0
        var seconds: TimeInterval = 0
        var unknown = 0
        for (offset, entry) in entries.enumerated() {
            let confirmed = confirmedCurrentDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let duration = offset == 0 && queue.currentIndex != nil ? confirmed ?? entry.track.duration : entry.track.duration
            guard let duration, duration.isFinite, duration >= 0 else { unknown += 1; continue }
            let remaining = offset == 0 && queue.currentIndex != nil ? max(0, duration - position) : duration
            let sum = seconds + remaining
            seconds = sum.isFinite ? sum : .greatestFiniteMagnitude
        }
        return QueueRemainingDuration(knownSeconds: seconds, unknownCount: unknown, songCount: entries.count)
    }
}
