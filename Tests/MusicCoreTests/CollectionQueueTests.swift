import Foundation
import Testing
@testable import MusicCore

@Suite("Whole collection queue")
struct CollectionQueueTests {
    private let tracks = ["a", "a", "b", "c", "d", "e"].map {
        Track(id: $0, title: "Song", artist: "Artist")
    }

    @Test func orderedCollectionPlaybackResetsShuffleAndPreservesDuplicateOccurrences() throws {
        var queue = PlaybackQueue()
        queue.replace(with: [tracks[2], tracks[0]], startAt: 0)
        queue.setShuffle(true)
        let old = try #require(queue.currentOccurrence)
        let request = queue.replaceForPlayback(with: tracks, shuffled: false)
        let current = try #require(request)
        #expect(!queue.isShuffled)
        #expect(queue.entries.map(\.track.id) == tracks.map(\.id))
        #expect(Set(queue.entries.map(\.id)).count == tracks.count)
        #expect(current.entryID == queue.entries.first?.id)
        #expect(!queue.accepts(old))
        try queue.snapshot().validate()
    }

    @Test func shuffleIncludesTheStartingEntryAndCanRestoreServiceOrder() throws {
        var firstTracks = Set<String>()
        for seed in 1...24 {
            var queue = PlaybackQueue()
            var generator = CollectionGenerator(state: UInt64(seed))
            let request = queue.replaceForPlayback(with: tracks, shuffled: true, using: &generator)
            let current = try #require(request)
            firstTracks.insert(current.trackID)
            #expect(queue.currentIndex == 0)
            #expect(queue.isShuffled)
            #expect(queue.entries.map(\.track.id).sorted() == tracks.map(\.id).sorted())
            queue.setShuffle(false)
            #expect(queue.entries.map(\.track.id) == tracks.map(\.id))
            #expect(queue.currentOccurrence == current)
            try queue.snapshot().validate()
        }
        #expect(firstTracks.count > 1)
    }

    @Test func oneUndoRestoresThePreviousQueueAfterShuffledReplacement() throws {
        var queue = PlaybackQueue()
        queue.replace(with: Array(tracks.prefix(2)), startAt: 1)
        let oldEntries = queue.entries
        let oldSelection = queue.currentEntryID
        let request = queue.replaceForPlayback(with: tracks, shuffled: true)
        let replacement = try #require(request)
        let restored = queue.undo()
        #expect(restored)
        #expect(queue.entries == oldEntries)
        #expect(queue.currentEntryID == oldSelection)
        #expect(!queue.isShuffled)
        #expect(!queue.accepts(replacement))
    }
}

private struct CollectionGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
