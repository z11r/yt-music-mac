import Foundation
import Testing
@testable import MusicCore

struct QueueStressTests {
    @Test func mixedQueueOperationsPreserveIdentityAndRestorableState() throws {
        for seed in [UInt64(7), 41, 203, 991] {
            var random = QueueRandom(seed: seed)
            var queue = PlaybackQueue()
            var retired: [PlaybackOccurrence] = []
            for step in 0..<2500 {
                let before = queue.currentOccurrence
                let operation = random.nextInt(13)
                switch operation {
                case 0:
                    let tracks = random.tracks(count: random.nextInt(20))
                    queue.replace(with: tracks, startAt: tracks.isEmpty ? nil : random.nextInt(tracks.count))
                case 1: queue.append(random.tracks(count: random.nextInt(5)))
                case 2: queue.playNext(random.tracks(count: random.nextInt(5)))
                case 3:
                    let removal = Set(queue.entries.enumerated().compactMap { index, entry in
                        index % 3 == step % 3 ? entry.id : nil
                    })
                    queue.remove(entryIDs: removal)
                case 4:
                    if !queue.entries.isEmpty {
                        let index = random.nextInt(queue.entries.count)
                        queue.move(fromOffsets: IndexSet(integer: index), toOffset: random.nextInt(queue.entries.count + 1))
                    }
                case 5: queue.setShuffle(!queue.isShuffled, using: &random)
                case 6: queue.repeatMode = RepeatMode.allCases[random.nextInt(RepeatMode.allCases.count)]
                case 7: queue.next()
                case 8: queue.previous()
                case 9: queue.undo()
                case 10:
                    if let current = queue.currentOccurrence { queue.handleEnd(occurrence: current) }
                case 11: queue.beginPlayback()
                default: queue.invalidatePlayback()
                }
                if let before, before != queue.currentOccurrence { retired.append(before) }
                if retired.count > 50 { retired.removeFirst() }
                if let old = retired.first, old != queue.currentOccurrence {
                    let unchanged = queue.snapshot()
                    let rejected = queue.handleEnd(occurrence: old)
                    #expect(rejected == nil)
                    #expect(queue.snapshot() == unchanged)
                }
                #expect(Set(queue.entries.map(\.id)).count == queue.entries.count)
                if let current = queue.currentOccurrence {
                    #expect(current.entryID == queue.currentEntryID)
                    #expect(current.trackID == queue.currentTrack?.id)
                }
                let snapshot = queue.snapshot(resumePosition: Double(step))
                try snapshot.validate()
                if step % 50 == 0 {
                    let decoded = try JSONDecoder().decode(QueueSnapshot.self, from: JSONEncoder().encode(snapshot))
                    let restored = try PlaybackQueue(snapshot: decoded)
                    #expect(restored.entries == queue.entries)
                    #expect(restored.currentEntryID == queue.currentEntryID)
                    #expect(restored.currentOccurrence == nil)
                }
            }
        }
    }
}

private struct QueueRandom: RandomNumberGenerator {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed
    }
    mutating func nextInt(_ upperBound: Int) -> Int { Int(next() % UInt64(upperBound)) }
    mutating func tracks(count: Int) -> [Track] {
        (0..<count).map { _ in
            let id = nextInt(8)
            return Track(id: "song-\(id)", title: "Song \(id)", artist: "Test Artist")
        }
    }
}
