import Foundation
import Testing
@testable import MusicCore

@Suite("Track metadata persistence")
struct TrackMetadataTests {
    @Test func oldVersionOneQueueDecodesWithoutNewFields() throws {
        let id = "11111111-1111-1111-1111-111111111111"
        let json = """
        {"version":1,"entries":[{"id":"\(id)","track":{"id":"song","title":"Song","artist":"Artist"}}],
        "currentEntryID":"\(id)","repeatMode":"off","isShuffled":false,"unshuffledOrder":["\(id)"],"resumePosition":0}
        """
        let snapshot = try JSONDecoder().decode(QueueSnapshot.self, from: Data(json.utf8))
        try snapshot.validate()
        let track = try #require(snapshot.entries.first?.track)
        #expect(track.albumReference == nil)
        #expect(track.artistReferences == nil)
        #expect(track.isExplicit == nil)
        #expect(try PlaybackQueue(snapshot: snapshot).currentTrack?.id == "song")
    }

    @Test func catalogMetadataRoundTripsWithoutChangingQueueOccurrenceIdentity() throws {
        let track = Track(id: "song", title: "Song", artist: "First, Second", album: "Album",
            albumReference: TrackMetadataReference(id: "album", title: "Album"),
            artistReferences: [TrackMetadataReference(id: "first", title: "First"), TrackMetadataReference(id: "second", title: "Second")],
            isExplicit: true)
        var queue = PlaybackQueue()
        queue.replace(with: [track, track])
        let original = queue.snapshot()
        let restored = try JSONDecoder().decode(QueueSnapshot.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(Set(restored.entries.map(\.id)).count == 2)
        #expect(restored.entries.first?.track.albumReference?.id == "album")
    }
}
