import Foundation
import Testing
@testable import MusicCore

@Suite("Queue source identity")
struct QueueEntryOriginTests {
    @Test func legacyEntriesKeepTheirIdentityAndHaveUnknownSource() throws {
        let original = QueueEntry(track: Track(id: "same", title: "Song", artist: "Artist"))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        object.removeValue(forKey: "origin")
        let restored = try JSONDecoder().decode(QueueEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.id == original.id)
        #expect(restored.track == original.track)
        #expect(restored.origin == .unknown)
        object["origin"] = "future-source"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(QueueEntry.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func moveUndoAndPersistencePreserveSourcesAndDuplicateOccurrences() throws {
        let track = Track(id: "same", title: "Song", artist: "Artist")
        var queue = PlaybackQueue()
        queue.replace(with: [track])
        queue.append([track], origin: .radio)
        queue.append([track], origin: .autoplay)
        let original = queue.snapshot()
        queue.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(queue.entries.map(\.origin) == [.autoplay, .manual, .radio])
        queue.undo()
        #expect(queue.snapshot() == original)
        let decoded = try JSONDecoder().decode(QueueSnapshot.self, from: JSONEncoder().encode(original))
        let restored = try PlaybackQueue(snapshot: decoded)
        #expect(restored.entries == queue.entries)
        #expect(Set(restored.entries.map(\.id)).count == 3)
        #expect(restored.currentOccurrence == nil)
    }

    @Test func explicitRecommendationsKeepSeparateRecordingAndOccurrenceOriginsThroughRestoreAndUndo() throws {
        let track = Track(id: "abcDEF12_-3", title: "Song", artist: "Artist", origin: .catalog, contentKind: .song)
        var queue = PlaybackQueue(); queue.replace(with: [track, track], startAt: 1)
        let original = queue.snapshot(); let occurrence = queue.currentOccurrence
        queue.append([track], origin: .recommendation)
        #expect(queue.entries.last?.origin == .recommendation && queue.entries.last?.track.origin == .catalog)
        #expect(Array(queue.entries.prefix(2)) == original.entries && queue.currentOccurrence == occurrence)
        let decoded = try JSONDecoder().decode(QueueSnapshot.self, from: JSONEncoder().encode(queue.snapshot()))
        let restored = try PlaybackQueue(snapshot: decoded)
        #expect(restored.entries == queue.entries && restored.currentOccurrence == nil)
        #expect(Set(restored.entries.map(\.id)).count == 3)
        #expect(queue.undo() && queue.snapshot() == original && queue.currentOccurrence == occurrence)
    }
}
