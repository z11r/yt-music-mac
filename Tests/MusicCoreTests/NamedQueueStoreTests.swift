import Foundation
import Testing
@testable import MusicCore

private struct NamedQueueFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NamedQueueTests-" + UUID().uuidString)
    let first = String(repeating: "a", count: 64)
    let second = String(repeating: "b", count: 64)
    func file(_ account: String) -> URL { directory.appendingPathComponent(account).appendingPathComponent("queues.json") }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func write(_ data: Data, account: String) throws {
        try FileManager.default.createDirectory(at: file(account).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file(account))
    }
}

private func namedSnapshot() -> QueueSnapshot {
    var queue = PlaybackQueue()
    queue.replace(with: [Track(id: "repeat", title: "Song", artist: "Artist", duration: 100),
                         Track(id: "repeat", title: "Song", artist: "Artist", duration: 100),
                         Track(id: "next", title: "Next", artist: "Artist")], startAt: 1)
    return queue.snapshot(resumePosition: 37.5)
}

@Suite("Named local queues")
struct NamedQueueStoreTests {
    @Test func roundTripPreservesDuplicateOccurrencesAndRestoresWithoutAutoplay() async throws {
        let fixture = NamedQueueFixture()
        defer { fixture.remove() }
        let store = NamedQueueStore(directoryURL: fixture.directory)
        let snapshot = namedSnapshot()
        let saved = try await store.save(name: " Evening ", snapshot: snapshot, accountKey: fixture.first)
        #expect(saved.name == "Evening")
        let list = try await store.list(accountKey: fixture.first)
        #expect(list == [saved])
        let loaded = try await store.snapshot(id: saved.id, accountKey: fixture.first)
        #expect(loaded == snapshot)
        let restored = try PlaybackQueue(snapshot: loaded)
        #expect(restored.entries.map(\.track.id) == ["repeat", "repeat", "next"])
        #expect(restored.entries[0].id != restored.entries[1].id)
        #expect(restored.currentEntryID == snapshot.currentEntryID && restored.currentOccurrence == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.file(fixture.first).path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func accountsCannotListReadRenameOrDeleteEachOthersQueues() async throws {
        let fixture = NamedQueueFixture()
        defer { fixture.remove() }
        let store = NamedQueueStore(directoryURL: fixture.directory)
        let saved = try await store.save(name: "Personal", snapshot: namedSnapshot(), accountKey: fixture.first)
        #expect(try await store.list(accountKey: fixture.second).isEmpty)
        await #expect(throws: NamedQueueError.notFound) { try await store.snapshot(id: saved.id, accountKey: fixture.second) }
        await #expect(throws: NamedQueueError.notFound) { try await store.rename(id: saved.id, name: "Other", accountKey: fixture.second) }
        await #expect(throws: NamedQueueError.notFound) { try await store.remove(id: saved.id, accountKey: fixture.second) }
        #expect(try await store.list(accountKey: fixture.first) == [saved])
    }

    @Test func renameAndDeleteAffectOnlyTheChosenLocalSnapshot() async throws {
        let fixture = NamedQueueFixture()
        defer { fixture.remove() }
        let store = NamedQueueStore(directoryURL: fixture.directory)
        let first = try await store.save(name: "First", snapshot: namedSnapshot(), accountKey: fixture.first)
        let second = try await store.save(name: "Second", snapshot: namedSnapshot(), accountKey: fixture.first)
        try await store.rename(id: first.id, name: "Renamed", accountKey: fixture.first)
        let renamed = try #require(try await store.list(accountKey: fixture.first).first { $0.id == first.id })
        #expect(renamed.name == "Renamed" && renamed.snapshot == first.snapshot && renamed.createdAt == first.createdAt)
        try await store.remove(id: second.id, accountKey: fixture.first)
        #expect(try await store.list(accountKey: fixture.first).map(\.id) == [first.id])
    }

    @Test func invalidNamesAndPathLikeAccountKeysNeverCreateStorage() async throws {
        let fixture = NamedQueueFixture()
        defer { fixture.remove() }
        let store = NamedQueueStore(directoryURL: fixture.directory)
        for key in ["", "../account", "signed-in", String(repeating: "A", count: 64)] {
            await #expect(throws: NamedQueueError.invalidAccount) {
                try await store.save(name: "Queue", snapshot: namedSnapshot(), accountKey: key)
            }
        }
        for name in [" ", "bad\u{0000}name", String(repeating: "x", count: 101)] {
            await #expect(throws: NamedQueueError.invalidName) {
                try await store.save(name: name, snapshot: namedSnapshot(), accountKey: fixture.first)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test func aFutureArchiveIsRetainedAndCannotBeOverwritten() async throws {
        let fixture = NamedQueueFixture()
        defer { fixture.remove() }
        let data = Data("{\"version\":99,\"queues\":[]}".utf8)
        try fixture.write(data, account: fixture.first)
        let store = NamedQueueStore(directoryURL: fixture.directory)
        await #expect(throws: NamedQueueError.unsupportedVersion(99)) { try await store.list(accountKey: fixture.first) }
        await #expect(throws: NamedQueueError.unsupportedVersion(99)) {
            try await store.save(name: "New", snapshot: namedSnapshot(), accountKey: fixture.first)
        }
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == data)
    }

    @Test func malformedAndOversizedArchivesAreRetained() async throws {
        let fixture = NamedQueueFixture()
        defer { fixture.remove() }
        let corrupt = Data("{broken".utf8)
        try fixture.write(corrupt, account: fixture.first)
        let store = NamedQueueStore(directoryURL: fixture.directory)
        await #expect(throws: NamedQueueError.invalidArchive) { try await store.list(accountKey: fixture.first) }
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == corrupt)
        let large = Data(repeating: 32, count: 1_025)
        try fixture.write(large, account: fixture.first)
        let bounded = NamedQueueStore(directoryURL: fixture.directory, maximumFileSize: 1_024)
        await #expect(throws: QueuePersistenceError.fileTooLarge) { try await bounded.list(accountKey: fixture.first) }
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == large)
    }

    @Test func capacityAndInvalidSnapshotFailuresKeepThePreviousArchive() async throws {
        let fixture = NamedQueueFixture()
        defer { fixture.remove() }
        let store = NamedQueueStore(directoryURL: fixture.directory, maximumQueues: 1)
        let saved = try await store.save(name: "First", snapshot: namedSnapshot(), accountKey: fixture.first)
        let original = try Data(contentsOf: fixture.file(fixture.first))
        await #expect(throws: NamedQueueError.tooManyQueues) {
            try await store.save(name: "Second", snapshot: namedSnapshot(), accountKey: fixture.first)
        }
        let entry = saved.snapshot.entries[0]
        await #expect(throws: QueuePersistenceError.self) {
            try await store.save(name: "Invalid", snapshot: QueueSnapshot(entries: [entry, entry]), accountKey: fixture.first)
        }
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == original)
        let boundedEntries = NamedQueueStore(directoryURL: fixture.directory, maximumEntries: 2)
        await #expect(throws: NamedQueueError.tooManyEntries) {
            try await boundedEntries.save(name: "Too many", snapshot: namedSnapshot(), accountKey: fixture.second)
        }
    }

    @Test func concurrentSavesAreSerializedWithoutLosingSnapshots() async throws {
        let fixture = NamedQueueFixture()
        defer { fixture.remove() }
        let store = NamedQueueStore(directoryURL: fixture.directory)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask { _ = try await store.save(name: "Queue \(index)", snapshot: namedSnapshot(), accountKey: fixture.first) }
            }
            try await group.waitForAll()
        }
        let queues = try await store.list(accountKey: fixture.first)
        #expect(queues.count == 12 && Set(queues.map(\.id)).count == 12)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.file(fixture.first).deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(files.map(\.lastPathComponent) == ["queues.json"])
    }
}
