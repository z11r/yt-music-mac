import Foundation
import Testing
@testable import MusicCore

@Suite("Song credits references and queue compatibility")
struct SongCreditsReferenceTests {
    @Test func validatesPrefixASCIIAndLengthWithoutGuessing() throws {
        for value in ["", "MPTC", "mptCabc", "abcDEF12_-3", "MPTCé", "MPTCa b", "MPTCa\n", "MPTC/a", "MPTCa=", "MPTC" + String(repeating: "x", count: 253)] {
            #expect(SongCreditsReference(browseID: value) == nil)
        }
        let reference = try #require(SongCreditsReference(browseID: "MPTCopaque_12-3"))
        #expect(try JSONDecoder().decode(SongCreditsReference.self, from: JSONEncoder().encode(reference)) == reference)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SongCreditsReference.self, from: Data(#"{"browseID":"wrong"}"#.utf8))
        }
    }

    @Test func oldTracksDecodeAndNewQueueOccurrencesKeepTheirReference() throws {
        let old = try JSONDecoder().decode(Track.self, from: Data(#"{"id":"abcDEF12_-3","title":"Song","artist":"Artist"}"#.utf8))
        #expect(old.creditsReference == nil)
        var track = old
        track.creditsReference = SongCreditsReference(browseID: "MPTCopaque")
        var queue = PlaybackQueue()
        queue.replace(with: [track, track])
        let ids = queue.entries.map(\.id)
        queue.updateTrack(Track(id: old.id, title: "Refreshed", artist: old.artist))
        #expect(queue.entries.allSatisfy { $0.track.creditsReference == track.creditsReference })
        let restored = try PlaybackQueue(snapshot: JSONDecoder().decode(QueueSnapshot.self, from: JSONEncoder().encode(queue.snapshot())))
        #expect(restored.entries.map(\.id) == ids)
        #expect(restored.entries.map(\.track.creditsReference) == [track.creditsReference, track.creditsReference])
    }
}
