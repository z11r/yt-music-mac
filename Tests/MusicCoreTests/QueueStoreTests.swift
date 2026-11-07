import Foundation
import Testing
@testable import MusicCore

private struct StoreFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("YTMusicCoreTests-" + UUID().uuidString, isDirectory: true)

    var fileURL: URL { self.directory.appendingPathComponent("queue.json") }

    func remove() {
        try? FileManager.default.removeItem(at: self.directory)
    }
}

private func sampleQueue() -> PlaybackQueue {
    var queue = PlaybackQueue()
    queue.replace(with: [
        Track(id: "a", title: "First", artist: "Artist", duration: 120),
        Track(id: "a", title: "First", artist: "Artist", duration: 120),
        Track(id: "b", title: "Second", artist: "Artist", duration: 240),
    ], startAt: 1)
    return queue
}

@Suite("Saved queue")
struct QueueStoreTests {
    @Test func saveLoadAndRestoreDoNotAutoplay() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let store = QueueStore(fileURL: fixture.fileURL)
        let queue = sampleQueue()
        let snapshot = queue.snapshot(resumePosition: 37.5)
        try await store.save(snapshot)
        let loaded = try #require(try await store.load())
        #expect(loaded == snapshot)
        #expect(loaded.resumePosition == 37.5)
        let restored = try PlaybackQueue(snapshot: loaded)
        #expect(restored.currentEntryID == queue.currentEntryID)
        #expect(restored.currentOccurrence == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func missingFileIsAnEmptyRestore() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let store = QueueStore(fileURL: fixture.fileURL)
        #expect(try await store.load() == nil)
        try await store.clear()
    }

    @Test func repeatedSavesReplaceThePreviousSnapshot() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let store = QueueStore(fileURL: fixture.fileURL)
        var queue = sampleQueue()
        try await store.save(queue.snapshot())
        queue.append([Track(id: "c", title: "Third", artist: "Artist")])
        queue.next()
        let latest = queue.snapshot(resumePosition: 9)
        try await store.save(latest)
        #expect(try await store.load() == latest)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
        #expect(files.map(\.lastPathComponent) == ["queue.json"])
    }

    @Test func malformedJSONIsReportedAndRetained() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let original = Data("{\"version\":".utf8)
        try original.write(to: fixture.fileURL)
        let store = QueueStore(fileURL: fixture.fileURL)
        await #expect(throws: DecodingError.self) { try await store.load() }
        #expect(try Data(contentsOf: fixture.fileURL) == original)
    }

    @Test func newerVersionsAreNotSilentlyOverwritten() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let snapshot = QueueSnapshot(version: 99, entries: [])
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let original = try JSONEncoder().encode(snapshot)
        try original.write(to: fixture.fileURL)
        let store = QueueStore(fileURL: fixture.fileURL)
        await #expect(throws: QueuePersistenceError.unsupportedVersion(99)) { try await store.load() }
        #expect(try Data(contentsOf: fixture.fileURL) == original)
    }

    @Test func invalidSaveDoesNotDamageThePreviousQueue() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let store = QueueStore(fileURL: fixture.fileURL)
        let original = sampleQueue().snapshot()
        try await store.save(original)
        let invalid = QueueSnapshot(entries: original.entries, currentEntryID: UUID())
        await #expect(throws: QueuePersistenceError.self) { try await store.save(invalid) }
        #expect(try await store.load() == original)
    }

    @Test func duplicateEntryIdentifiersAreRejected() {
        let entry = QueueEntry(track: Track(id: "a", title: "Song", artist: "Artist"))
        let invalid = QueueSnapshot(entries: [entry, entry])
        #expect(throws: QueuePersistenceError.self) { try PlaybackQueue(snapshot: invalid) }
    }

    @Test func mismatchedShuffleOrderAndInvalidPositionsAreRejected() {
        let entry = QueueEntry(track: Track(id: "a", title: "Song", artist: "Artist"))
        #expect(throws: QueuePersistenceError.self) {
            try QueueSnapshot(entries: [entry], isShuffled: true, unshuffledOrder: [UUID()]).validate()
        }
        #expect(throws: QueuePersistenceError.self) {
            try QueueSnapshot(entries: [entry], resumePosition: -.infinity).validate()
        }
    }

    @Test func oversizedDataIsRejectedBeforeDecoding() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data(repeating: 32, count: 1025).write(to: fixture.fileURL)
        let store = QueueStore(fileURL: fixture.fileURL, maximumFileSize: 1024)
        await #expect(throws: QueuePersistenceError.fileTooLarge) { try await store.load() }
    }

    @Test func separateStoresDoNotShareOrClearEachOthersState() async throws {
        let first = StoreFixture()
        let second = StoreFixture()
        defer { first.remove(); second.remove() }
        let firstStore = QueueStore(fileURL: first.fileURL)
        let secondStore = QueueStore(fileURL: second.fileURL)
        let snapshot = sampleQueue().snapshot()
        try await firstStore.save(snapshot)
        #expect(try await secondStore.load() == nil)
        try await secondStore.clear()
        #expect(try await firstStore.load() == snapshot)
        try await firstStore.clear()
        #expect(try await firstStore.load() == nil)
    }
}
