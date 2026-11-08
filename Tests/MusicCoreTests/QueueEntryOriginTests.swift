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
}
