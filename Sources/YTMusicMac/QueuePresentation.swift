import Foundation
import MusicCore

struct QueueDisplayRow: Identifiable {
    let index: Int
    let entry: QueueEntry
    var id: UUID { entry.id }
}

struct QueueDisplayGroup: Identifiable {
    let id: UUID
    let origin: QueueEntryOrigin
    var rows: [QueueDisplayRow]

    var title: String {
        switch origin {
        case .unknown: "Queue"
        case .manual: "Added by You"
        case .radio: "Radio"
        case .autoplay: "Autoplay"
        }
    }
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

    /// Only adjacent occurrences are grouped. Sources never reorder playback.
    static func groups(in rows: [QueueDisplayRow]) -> [QueueDisplayGroup] {
        var groups: [QueueDisplayGroup] = []
        for row in rows {
            if groups.last?.origin == row.entry.origin {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append(QueueDisplayGroup(id: row.id, origin: row.entry.origin, rows: [row]))
            }
        }
        return groups
    }

    static func move(in group: QueueDisplayGroup, offsets: IndexSet, destination: Int,
                     isFiltering: Bool) -> (offsets: IndexSet, destination: Int)? {
        guard !isFiltering, !offsets.isEmpty, (0...group.rows.count).contains(destination),
              offsets.allSatisfy({ group.rows.indices.contains($0) }),
              let first = group.rows.first,
              group.rows.enumerated().allSatisfy({ $0.element.index == first.index + $0.offset }) else { return nil }
        return (IndexSet(offsets.map { group.rows[$0].index }), first.index + destination)
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
