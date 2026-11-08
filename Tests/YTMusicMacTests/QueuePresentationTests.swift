import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@Suite("Queue presentation")
struct QueuePresentationTests {
    @Test func sourceSectionsKeepPlaybackOrderAndMapMovesToGlobalIndices() throws {
        let track = Track(id: "same", title: "Song", artist: "Artist")
        let entries = [QueueEntry(track: track), QueueEntry(track: track, origin: .radio),
                       QueueEntry(track: track, origin: .radio), QueueEntry(track: track),
                       QueueEntry(track: track, origin: .autoplay)]
        let groups = QueuePresentation.groups(in: QueuePresentation.rows(in: entries, matching: ""))
        #expect(groups.map(\.origin) == [.manual, .radio, .manual, .autoplay])
        #expect(groups.flatMap(\.rows).map(\.id) == entries.map(\.id))
        #expect(Set(groups.map(\.id)).count == groups.count)
        let move = try #require(QueuePresentation.move(in: groups[1], offsets: IndexSet(integer: 0),
            destination: 2, isFiltering: false))
        #expect(move.offsets == IndexSet(integer: 1))
        #expect(move.destination == 3)
        #expect(QueuePresentation.move(in: groups[1], offsets: [0], destination: 2, isFiltering: true) == nil)
        #expect(QueuePresentation.move(in: groups[1], offsets: [2], destination: 0, isFiltering: false) == nil)
    }

    @Test func filteringPreservesOccurrenceIdentityAndUnderlyingOrder() {
        var queue = PlaybackQueue()
        queue.replace(with: [Track(id: "a", title: "Shared", artist: "First"),
                             Track(id: "b", title: "Other", artist: "Second"),
                             Track(id: "a", title: "Shared", artist: "First")])
        let original = queue.snapshot()
        let rows = QueuePresentation.rows(in: queue.entries, matching: " shared ")
        #expect(rows.map(\.index) == [0, 2])
        #expect(rows.map(\.id) == [queue.entries[0].id, queue.entries[2].id])
        #expect(rows[0].id != rows[1].id)
        #expect(queue.snapshot() == original)
    }

    @Test func filterMatchesArtistAndAlbumAndAcceptsAnEmptyQuery() {
        let entries = [QueueEntry(track: Track(id: "a", title: "Song", artist: "Artist", album: "Record"))]
        #expect(QueuePresentation.rows(in: entries, matching: "ARTIST").count == 1)
        #expect(QueuePresentation.rows(in: entries, matching: "record").count == 1)
        #expect(QueuePresentation.rows(in: entries, matching: " \n").count == 1)
        #expect(QueuePresentation.rows(in: entries, matching: "missing").isEmpty)
    }

    @Test func remainingDurationExcludesPlayedEntriesAndKeepsUnknownsExplicit() {
        var queue = PlaybackQueue()
        queue.replace(with: [Track(id: "played", title: "Played", artist: "Artist", duration: 100),
                             Track(id: "current", title: "Current", artist: "Artist", duration: 200),
                             Track(id: "unknown", title: "Unknown", artist: "Artist"),
                             Track(id: "next", title: "Next", artist: "Artist", duration: 300)], startAt: 1)
        let remaining = QueuePresentation.remaining(in: queue, position: 50)
        #expect(remaining == QueueRemainingDuration(knownSeconds: 450, unknownCount: 1, songCount: 3))
    }

    @Test func confirmedPlaybackDurationResolvesOnlyTheCurrentUnknownSong() {
        var queue = PlaybackQueue()
        queue.replace(with: [Track(id: "current", title: "Current", artist: "Artist"),
                             Track(id: "unknown", title: "Unknown", artist: "Artist")], startAt: 0)
        let remaining = QueuePresentation.remaining(in: queue, position: 10, confirmedCurrentDuration: 90)
        #expect(remaining == QueueRemainingDuration(knownSeconds: 80, unknownCount: 1, songCount: 2))
    }

    @Test func pastTheDurationAndInvalidClockValuesNeverCreateNegativeTotals() {
        var queue = PlaybackQueue()
        queue.replace(with: [Track(id: "a", title: "Song", artist: "Artist", duration: 30)], startAt: 0)
        #expect(QueuePresentation.remaining(in: queue, position: 100).knownSeconds == 0)
        #expect(QueuePresentation.remaining(in: queue, position: .nan, confirmedCurrentDuration: .infinity).knownSeconds == 30)
        #expect(QueuePresentation.remaining(in: PlaybackQueue(), position: 0).songCount == 0)
    }
}
