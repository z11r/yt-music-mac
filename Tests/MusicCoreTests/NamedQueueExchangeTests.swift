import Foundation
import Testing
@testable import MusicCore

private let exchangeID = "abcDEF12_-3"
private let nextExchangeID = "xyz12345_-6"

private func exchangeSnapshot() -> QueueSnapshot {
    var queue = PlaybackQueue()
    queue.replace(with: [
        Track(id: exchangeID, title: "First", artist: "Artist", album: "Album",
              artworkURL: URL(string: "https://private:secret@example.com/art?token=private"), duration: 120),
        Track(id: exchangeID, title: "First", artist: "Artist", duration: 120),
        Track(id: nextExchangeID, title: "Next", artist: "Other"),
    ], startAt: 1)
    return queue.snapshot(resumePosition: 37)
}

private func exchangeSong(_ changes: [String: Any] = [:]) -> [String: Any] {
    ["videoID": exchangeID, "title": "Song", "artist": "Artist",
     "link": "https://music.youtube.com/watch?v=" + exchangeID].merging(changes) { $1 }
}

private func exchangeData(songs: [[String: Any]], version: Int = 1) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["version": version, "name": "Imported", "songs": songs])
}

@Suite("Named queue metadata exchange")
struct NamedQueueExchangeTests {
    @Test func roundTripKeepsSongOrderAndCreatesFreshDuplicateOccurrences() throws {
        let original = exchangeSnapshot()
        let data = try NamedQueueExchange.encode(name: "Evening", snapshot: original)
        let imported = try NamedQueueExchange.decode(data)
        #expect(imported.name == "Evening")
        #expect(imported.snapshot.entries.map(\.track.id) == [exchangeID, exchangeID, nextExchangeID])
        #expect(Set(imported.snapshot.entries.map(\.id)).count == 3)
        #expect(Set(imported.snapshot.entries.map(\.id)).isDisjoint(with: original.entries.map(\.id)))
        #expect(imported.snapshot.resumePosition == 0)
        let restored = try PlaybackQueue(snapshot: imported.snapshot)
        #expect(restored.currentOccurrence == nil)
        #expect(imported.snapshot.entries.allSatisfy { $0.track.artworkURL == nil })
    }

    @Test func exportContainsOnlyTheDocumentAndSongMetadataFields() throws {
        let snapshot = exchangeSnapshot()
        let data = try NamedQueueExchange.encode(name: "Queue", snapshot: snapshot)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(root.keys) == ["version", "name", "songs"])
        let songs = try #require(root["songs"] as? [[String: Any]])
        #expect(Set(songs[0].keys) == ["videoID", "title", "artist", "album", "duration", "link"])
        let text = String(decoding: data, as: UTF8.self)
        for privateValue in ["private", "secret", "artworkURL", "resumePosition", "accountID", "scope", snapshot.entries[0].id.uuidString] {
            #expect(!text.contains(privateValue))
        }
    }

    @Test func invalidAndArbitrarySourceLinksAreRejected() throws {
        let links = [
            "file:///tmp/song.mp3", "data:audio/mpeg;base64,AAA", "javascript:alert(1)",
            "https://music.youtube.com.evil.example/watch?v=" + exchangeID,
            "http://music.youtube.com/watch?v=" + exchangeID,
            "https://user:password@music.youtube.com/watch?v=" + exchangeID,
            "https://music.youtube.com/watch?v=" + nextExchangeID,
            "https://music.youtube.com/watch?v=" + exchangeID + "&token=private",
            "https://music.youtube.com/watch?v=" + exchangeID + "#private",
        ]
        for link in links {
            let data = try exchangeData(songs: [exchangeSong(["link": link])])
            #expect(throws: NamedQueueExchangeError.invalidLink) { try NamedQueueExchange.decode(data) }
        }
    }

    @Test func songIdentifiersTextAndDurationsAreValidatedBeforeBuildingEntries() throws {
        let invalid: [[String: Any]] = [
            ["videoID": "short"], ["videoID": "abcDEF12/--"], ["videoID": "abcDEF12_-é"],
            ["title": ""], ["title": "bad\u{0000}title"], ["artist": String(repeating: "x", count: 4_097)],
            ["duration": -1], ["duration": 604_801],
        ]
        for values in invalid {
            let data = try exchangeData(songs: [exchangeSong(values)])
            #expect(throws: NamedQueueExchangeError.invalidSong) { try NamedQueueExchange.decode(data) }
        }
    }

    @Test func aFutureVersionIsRejectedBeforeItsSongShapeIsDecoded() throws {
        let data = Data("{\"version\":99,\"name\":\"Future\",\"songs\":\"unknown format\"}".utf8)
        #expect(throws: NamedQueueExchangeError.unsupportedVersion(99)) { try NamedQueueExchange.decode(data) }
    }

    @Test func theSongCountIsBoundedDuringDecoding() throws {
        let data = try exchangeData(songs: Array(repeating: exchangeSong(), count: NamedQueueExchange.maximumSongs + 1))
        #expect(throws: NamedQueueExchangeError.tooManySongs) { try NamedQueueExchange.decode(data) }
    }

    @Test func importRejectsOversizedAndNonRegularFilesBeforeReading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QueueExchangeTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let large = directory.appendingPathComponent("large.json")
        try Data(repeating: 32, count: NamedQueueExchange.maximumBytes + 1).write(to: large)
        #expect(throws: QueuePersistenceError.fileTooLarge) { try NamedQueueExchange.read(from: large) }
        #expect(throws: NamedQueueExchangeError.invalidDocument) { try NamedQueueExchange.read(from: directory) }
        #expect(throws: QueuePersistenceError.invalidStorageURL) {
            try NamedQueueExchange.read(from: URL(string: "https://example.com/queue.json")!)
        }
    }

    @Test func corruptAndFutureImportsPreserveTheOriginalStoreAndInputFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QueueExchangeStoreTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("saved")
        let key = String(repeating: "a", count: 64)
        let store = NamedQueueStore(directoryURL: root)
        try await store.save(name: "Original", snapshot: exchangeSnapshot(), accountKey: key)
        let archive = root.appendingPathComponent(key).appendingPathComponent("queues.json")
        let original = try Data(contentsOf: archive)
        let input = directory.appendingPathComponent("input.json")
        for bytes in [Data("{broken".utf8), try exchangeData(songs: [], version: 99)] {
            try bytes.write(to: input)
            await #expect(throws: NamedQueueExchangeError.self) { try await store.importQueue(from: input, accountKey: key) }
            #expect(try Data(contentsOf: archive) == original)
            #expect(try Data(contentsOf: input) == bytes)
        }
    }

    @Test func exportCannotOverwriteInternalArchivesAndImportedFilesNeverAutoplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QueueExchangeRoundTripTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("saved")
        let key = String(repeating: "a", count: 64)
        let store = NamedQueueStore(directoryURL: root)
        let saved = try await store.save(name: "Original", snapshot: exchangeSnapshot(), accountKey: key)
        let archive = root.appendingPathComponent(key).appendingPathComponent("queues.json")
        let original = try Data(contentsOf: archive)
        await #expect(throws: NamedQueueExchangeError.protectedDestination) {
            try await store.exportQueue(id: saved.id, to: archive, accountKey: key)
        }
        #expect(try Data(contentsOf: archive) == original)
        let exported = directory.appendingPathComponent("portable.json")
        try await store.exportQueue(id: saved.id, to: exported, accountKey: key)
        #expect(!String(decoding: try Data(contentsOf: exported), as: UTF8.self).contains(key))
        let imported = try await store.importQueue(from: exported, accountKey: key)
        #expect(imported.id != saved.id)
        #expect(imported.snapshot.entries.map(\.track.id) == saved.snapshot.entries.map(\.track.id))
        #expect(try PlaybackQueue(snapshot: imported.snapshot).currentOccurrence == nil)
    }
}
