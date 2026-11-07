import Foundation
import Testing
@testable import MusicCore

private func song(_ id: String) -> Track {
    Track(id: id, title: "Song \(id)", artist: "Artist", duration: 180)
}

private func playingQueue(_ ids: [String]) -> PlaybackQueue {
    var queue = PlaybackQueue()
    queue.replace(with: ids.map(song), startAt: 0)
    return queue
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        self.state = self.state &* 6364136223846793005 &+ 1442695040888963407
        return self.state
    }
}

@Suite("Playback queue")
struct PlaybackQueueTests {
    @Test func loadingAQueueDoesNotStartPlayback() {
        var queue = PlaybackQueue()
        #expect(queue.replace(with: [song("a"), song("b")]) == nil)
        #expect(queue.currentTrack?.id == "a")
        #expect(queue.currentOccurrence == nil)
        #expect(queue.beginPlayback()?.trackID == "a")
    }

    @Test func duplicateSongsHaveDistinctQueueEntries() throws {
        var queue = playingQueue(["a", "a", "b"])
        let first = try #require(queue.currentOccurrence)
        let next = queue.next()
        let second = try #require(next)
        #expect(first.trackID == second.trackID)
        #expect(first.entryID != second.entryID)
        #expect(first.generation != second.generation)
        #expect(Set(queue.entries.map(\.id)).count == 3)
    }

    @Test func oldAndDuplicateEndEventsCannotAdvanceAgain() throws {
        var queue = playingQueue(["a", "a", "b"])
        let first = try #require(queue.currentOccurrence)
        let advanced = queue.handleEnd(occurrence: first)
        let second = try #require(advanced)
        #expect(queue.handleEnd(occurrence: first) == nil)
        #expect(queue.currentOccurrence == second)
        #expect(queue.currentIndex == 1)
        let next = queue.next()
        let third = try #require(next)
        #expect(queue.handleEnd(occurrence: second) == nil)
        #expect(queue.currentOccurrence == third)
    }

    @Test func aRestoredQueueRejectsEventsFromThePreviousSession() throws {
        let previous = playingQueue(["a", "b"])
        let oldOccurrence = try #require(previous.currentOccurrence)
        var restored = try PlaybackQueue(snapshot: previous.snapshot(resumePosition: 42))
        #expect(restored.currentOccurrence == nil)
        let started = restored.beginPlayback()
        let occurrence = try #require(started)
        #expect(oldOccurrence.entryID == occurrence.entryID)
        #expect(oldOccurrence.sessionID != occurrence.sessionID)
        #expect(restored.handleEnd(occurrence: oldOccurrence) == nil)
        #expect(restored.currentOccurrence == occurrence)
    }

    @Test func repeatOneRepeatsNaturalEndButAllowsManualSkip() throws {
        var queue = playingQueue(["a", "b"])
        queue.repeatMode = .one
        let first = try #require(queue.currentOccurrence)
        let ended = queue.handleEnd(occurrence: first)
        let repeated = try #require(ended)
        #expect(first.entryID == repeated.entryID)
        #expect(first.generation != repeated.generation)
        #expect(queue.next()?.trackID == "b")
    }

    @Test func repeatAllWrapsBothDirections() throws {
        var queue = playingQueue(["a", "b"])
        queue.repeatMode = .all
        #expect(queue.previous()?.trackID == "b")
        let last = try #require(queue.currentOccurrence)
        #expect(queue.handleEnd(occurrence: last)?.trackID == "a")
        #expect(queue.next()?.trackID == "b")
        #expect(queue.next()?.trackID == "a")
    }

    @Test func finalNaturalEndStopsWithoutLosingTheSelection() throws {
        var queue = playingQueue(["a"])
        let occurrence = try #require(queue.currentOccurrence)
        #expect(queue.handleEnd(occurrence: occurrence) == nil)
        #expect(queue.currentOccurrence == nil)
        #expect(queue.currentTrack?.id == "a")
        #expect(!queue.hasNext)
        #expect(queue.beginPlayback()?.generation != occurrence.generation)
    }

    @Test func playbackFailureKeepsTheQueueAndSupportsRetry() throws {
        var queue = playingQueue(["a", "b"])
        let original = try #require(queue.currentOccurrence)
        queue.invalidatePlayback()
        #expect(queue.entries.map(\.track.id) == ["a", "b"])
        #expect(queue.currentTrack?.id == "a")
        #expect(queue.handleEnd(occurrence: original) == nil)
        let started = queue.beginPlayback()
        let retry = try #require(started)
        #expect(retry.entryID == original.entryID)
        #expect(retry.generation != original.generation)
    }

    @Test func invalidSelectionAndBoundarySkipAreNoOps() throws {
        var queue = playingQueue(["a"])
        let original = try #require(queue.currentOccurrence)
        #expect(queue.select(entryID: UUID()) == nil)
        #expect(queue.next() == nil)
        #expect(queue.previous() == nil)
        #expect(queue.currentOccurrence == original)
    }

    @Test func playNextPreservesInsertionOrderAndPlayback() throws {
        var queue = playingQueue(["a", "d"])
        let occurrence = try #require(queue.currentOccurrence)
        queue.playNext([song("b"), song("c")])
        queue.append([song("e")])
        #expect(queue.entries.map(\.track.id) == ["a", "b", "c", "d", "e"])
        #expect(queue.currentOccurrence == occurrence)
        #expect(queue.next()?.trackID == "b")
        try queue.snapshot().validate()
    }

    @Test func removingTheCurrentEntrySelectsItsSuccessor() throws {
        var queue = playingQueue(["a", "b", "c"])
        let old = try #require(queue.currentOccurrence)
        queue.remove(entryIDs: [old.entryID])
        #expect(queue.currentTrack?.id == "b")
        #expect(queue.currentOccurrence?.trackID == "b")
        #expect(queue.handleEnd(occurrence: old) == nil)
        #expect(queue.currentTrack?.id == "b")
        try queue.snapshot().validate()
    }

    @Test func removingEarlierEntriesAndTheCurrentEntryDoesNotSkipTheSuccessor() throws {
        var queue = playingQueue(["a", "b", "c", "d", "e"])
        let selectedID = queue.entries[2].id
        queue.select(entryID: selectedID)
        queue.remove(entryIDs: [queue.entries[0].id, selectedID])
        #expect(queue.entries.map(\.track.id) == ["b", "d", "e"])
        #expect(queue.currentTrack?.id == "d")
        #expect(queue.currentOccurrence?.trackID == "d")
        try queue.snapshot().validate()
    }

    @Test func editingAnInactiveSelectionDoesNotStartPlayback() throws {
        var queue = PlaybackQueue()
        queue.replace(with: [song("a"), song("b")])
        let selected = try #require(queue.currentEntryID)
        queue.remove(entryIDs: [selected])
        #expect(queue.currentTrack?.id == "b")
        #expect(queue.currentOccurrence == nil)
        queue.remove(entryIDs: Set(queue.entries.map(\.id)))
        #expect(queue.entries.isEmpty)
        #expect(queue.currentEntryID == nil)
        #expect(queue.currentOccurrence == nil)
        let didUndo = queue.undo()
        #expect(didUndo)
        #expect(queue.currentTrack?.id == "b")
        #expect(queue.currentOccurrence == nil)
    }

    @Test func removingTheLastEntryAndClearingRemainValid() throws {
        var queue = playingQueue(["a", "b"])
        let next = queue.next()
        let last = try #require(next)
        queue.remove(entryIDs: [last.entryID])
        #expect(queue.currentTrack?.id == "a")
        queue.remove(entryIDs: Set(queue.entries.map(\.id)))
        #expect(queue.currentEntryID == nil)
        #expect(queue.currentOccurrence == nil)
        try queue.snapshot().validate()
    }

    @Test func reorderingRetainsCurrentIdentity() throws {
        var queue = playingQueue(["a", "b", "c", "d", "e"])
        let next = queue.next()
        let occurrence = try #require(next)
        queue.move(fromOffsets: IndexSet([1, 3]), toOffset: 5)
        #expect(queue.entries.map(\.track.id) == ["a", "c", "e", "b", "d"])
        #expect(queue.currentOccurrence == occurrence)
        #expect(queue.currentIndex == 3)
        try queue.snapshot().validate()
    }

    @Test func outOfRangeMovesDoNotTrapOrLoseEntries() throws {
        var queue = playingQueue(["a", "b", "c"])
        queue.move(fromOffsets: IndexSet([1, 99]), toOffset: -10)
        #expect(queue.entries.map(\.track.id) == ["b", "a", "c"])
        queue.move(fromOffsets: IndexSet([0]), toOffset: 100)
        #expect(queue.entries.map(\.track.id) == ["a", "c", "b"])
        try queue.snapshot().validate()
    }

    @Test func shufflePreservesHistoryAndRestoresOriginalOrder() throws {
        var queue = playingQueue(["a", "b", "c", "d", "e", "f", "g"])
        let next = queue.next()
        let occurrence = try #require(next)
        let original = queue.entries.map(\.id)
        var random = SeededGenerator(state: 42)
        queue.setShuffle(true, using: &random)
        #expect(queue.entries.prefix(2).map(\.id) == Array(original.prefix(2)))
        #expect(Set(queue.entries.map(\.id)) == Set(original))
        #expect(queue.currentOccurrence == occurrence)
        try queue.snapshot().validate()
        queue.setShuffle(false)
        #expect(queue.entries.map(\.id) == original)
        #expect(queue.currentOccurrence == occurrence)
    }

    @Test func shuffleEditsDoNotDropAddedOrDuplicateSongs() throws {
        var queue = playingQueue(["a", "b", "c", "d"])
        var random = SeededGenerator(state: 12)
        queue.setShuffle(true, using: &random)
        queue.playNext([song("a"), song("e")])
        queue.append([song("f")])
        queue.setShuffle(false)
        #expect(queue.entries.map(\.track.id) == ["a", "a", "e", "b", "c", "d", "f"])
        #expect(Set(queue.entries.map(\.id)).count == 7)
        try queue.snapshot().validate()
    }

    @Test func undoKeepsTheCurrentlyPlayingEntryWhenPossible() throws {
        var queue = playingQueue(["a", "b", "c"])
        queue.append([song("d")])
        let next = queue.next()
        let current = try #require(next)
        let didUndo = queue.undo()
        #expect(didUndo)
        #expect(queue.entries.map(\.track.id) == ["a", "b", "c"])
        #expect(queue.currentOccurrence == current)
        #expect(queue.currentTrack?.id == "b")
    }

    @Test func undoHistoryIsBounded() {
        var queue = PlaybackQueue(undoLimit: 2)
        queue.append([song("a")])
        queue.append([song("b")])
        queue.append([song("c")])
        let firstUndo = queue.undo()
        let secondUndo = queue.undo()
        let thirdUndo = queue.undo()
        #expect(firstUndo)
        #expect(secondUndo)
        #expect(!thirdUndo)
        #expect(queue.entries.map(\.track.id) == ["a"])
    }

    @Test func metadataUpdatesPreserveOccurrenceAndEntryIDs() throws {
        var queue = playingQueue(["a", "a", "b"])
        let ids = queue.entries.map(\.id)
        let occurrence = try #require(queue.currentOccurrence)
        queue.updateTrack(Track(id: "a", title: "Updated", artist: "Artist"))
        #expect(queue.entries.prefix(2).allSatisfy { $0.track.title == "Updated" })
        #expect(queue.entries.map(\.id) == ids)
        #expect(queue.currentOccurrence == occurrence)
    }

    @Test func repeatedTransitionsDoNotAcceptEarlierEndings() throws {
        var queue = playingQueue(["a", "b", "a", "c"])
        queue.repeatMode = .all
        var seen = Set<PlaybackOccurrence>()
        for _ in 0..<200 {
            let occurrence = try #require(queue.currentOccurrence)
            #expect(seen.insert(occurrence).inserted)
            let advanced = queue.handleEnd(occurrence: occurrence)
            let next = try #require(advanced)
            #expect(queue.handleEnd(occurrence: occurrence) == nil)
            #expect(queue.currentOccurrence == next)
        }
    }
}
