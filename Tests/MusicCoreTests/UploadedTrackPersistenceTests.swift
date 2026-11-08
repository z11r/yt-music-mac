import Foundation
import Testing
@testable import MusicCore

struct UploadedTrackPersistenceTests {
    @Test func oldTrackSnapshotsDecodeWithUnknownOrigin() throws {
        let old = Data(#"{"id":"abcDEF12_-3","title":"Song","artist":"Artist"}"#.utf8)
        let track = try JSONDecoder().decode(Track.self, from: old)
        #expect(track.id == "abcDEF12_-3")
        #expect(track.origin == nil)
    }

    @Test func uploadedTracksKeepTheirOriginAndOccurrenceIdentityOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UploadedTrackPersistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        var queue = PlaybackQueue()
        let track = Track(id: "abcDEF12_-3", title: "Uploaded song", artist: "Fixture", origin: .upload)
        queue.replace(with: [track, track])
        let expected = queue.entries.map(\.id)
        try await store.save(queue.snapshot())
        let saved = try #require(await store.load())
        let restored = try PlaybackQueue(snapshot: saved)
        #expect(restored.entries.map(\.id) == expected)
        #expect(Set(expected).count == 2)
        #expect(restored.entries.allSatisfy { $0.track.origin == .upload && $0.track.id == track.id })
        #expect(restored.currentOccurrence == nil)
    }

    @Test func metadataRefreshWithoutOriginPreservesKnownUploadProvenance() {
        var queue = PlaybackQueue()
        queue.replace(with: [Track(id: "abcDEF12_-3", title: "Upload", artist: "Fixture", origin: .upload)])
        queue.updateTrack(Track(id: "abcDEF12_-3", title: "Updated title", artist: "Fixture"))
        #expect(queue.currentTrack?.title == "Updated title")
        #expect(queue.currentTrack?.origin == .upload)
    }
}
