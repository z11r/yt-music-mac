import Foundation
import Testing
@testable import MusicCore

private final class MetadataTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func advance(_ interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}

private struct MetadataCacheFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryMetadataTests-" + UUID().uuidString)
    let first = String(repeating: "a", count: 64)
    let second = String(repeating: "b", count: 64)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    var collections: [LocalCollectionReference] {
        [LocalCollectionReference(serviceID: "VLPLone", kind: .playlist, title: "Playlist"),
         LocalCollectionReference(serviceID: "MPREalbum", kind: .album, title: "Album")]
    }
    func file(_ account: String) -> URL { directory.appendingPathComponent(account).appendingPathComponent("library.json") }
    func write(_ data: Data, account: String) throws {
        try FileManager.default.createDirectory(at: file(account).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file(account))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Suite("Account-specific read-only library metadata cache")
struct LibraryMetadataCacheTests {
    @Test func snapshotRoundTripsOnlyDatedCollectionMetadataAndHasPrivatePermissions() async throws {
        let fixture = MetadataCacheFixture()
        defer { fixture.remove() }
        let store = LibraryMetadataCache(directoryURL: fixture.directory, now: { fixture.date })
        let saved = try await store.save(collections: fixture.collections, accountKey: fixture.first)
        #expect(saved.capturedAt == fixture.date && !saved.isTruncated)
        #expect(try await store.load(accountKey: fixture.first) == saved)
        let bytes = try Data(contentsOf: fixture.file(fixture.first))
        #expect(try await store.storedBytes(accountKey: fixture.first) == bytes.count)
        let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(json.keys) == ["version", "capturedAt", "collections", "isTruncated"])
        let records = try #require(json["collections"] as? [[String: Any]])
        #expect(records.allSatisfy { Set($0.keys) == ["serviceID", "kind", "title"] })
        #expect(!String(decoding: bytes, as: UTF8.self).contains(fixture.first))
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file(fixture.first).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func expiryRejectsOldSnapshotsWithoutDeletingTheirFilesAndRefreshCanReplaceThem() async throws {
        let fixture = MetadataCacheFixture()
        defer { fixture.remove() }
        let clock = MetadataTestClock(fixture.date)
        let store = LibraryMetadataCache(directoryURL: fixture.directory, lifetime: 60, now: clock.now)
        try await store.save(collections: fixture.collections, accountKey: fixture.first)
        let original = try Data(contentsOf: fixture.file(fixture.first))
        clock.advance(60)
        #expect(try await store.load(accountKey: fixture.first) == nil)
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == original)
        let updated = try await store.save(collections: [fixture.collections[0]], accountKey: fixture.first)
        #expect(updated.capturedAt == clock.now() && updated.collections.count == 1)
        #expect(try await store.load(accountKey: fixture.first) == updated)
    }

    @Test func accountIsolationClearAndStaleWriteFencesPreserveTheOtherAccount() async throws {
        let fixture = MetadataCacheFixture()
        defer { fixture.remove() }
        let store = LibraryMetadataCache(directoryURL: fixture.directory, now: { fixture.date })
        try await store.save(collections: fixture.collections, accountKey: fixture.first)
        #expect(try await store.load(accountKey: fixture.second) == nil)
        try await store.save(collections: [fixture.collections[1]], accountKey: fixture.second)
        let oldToken = try await store.beginWrite(accountKey: fixture.first)
        try await store.clear(accountKey: fixture.first)
        await #expect(throws: LibraryMetadataCacheError.superseded) {
            try await store.save(collections: fixture.collections, accountKey: fixture.first, token: oldToken)
        }
        #expect(try await store.storedBytes(accountKey: fixture.first) == 0)
        #expect(try await store.load(accountKey: fixture.second)?.collections == [fixture.collections[1]])
        await #expect(throws: NamedQueueError.invalidAccount) { try await store.clear(accountKey: "../other") }
    }

    @Test func aLateOlderPageCannotOverwriteANewerSnapshot() async throws {
        let fixture = MetadataCacheFixture()
        defer { fixture.remove() }
        let store = LibraryMetadataCache(directoryURL: fixture.directory, now: { fixture.date })
        let older = try await store.beginWrite(accountKey: fixture.first)
        let newer = try await store.beginWrite(accountKey: fixture.first)
        try await store.save(collections: fixture.collections, accountKey: fixture.first, token: newer)
        await #expect(throws: LibraryMetadataCacheError.superseded) {
            try await store.save(collections: [fixture.collections[0]], accountKey: fixture.first, token: older)
        }
        #expect(try await store.load(accountKey: fixture.first)?.collections == fixture.collections)
        await #expect(throws: LibraryMetadataCacheError.superseded) {
            try await store.save(collections: [], accountKey: fixture.second, token: newer)
        }
    }

    @Test func snapshotsBoundCollectionCountsDeduplicateAndRetainLoadedOrder() async throws {
        let fixture = MetadataCacheFixture()
        defer { fixture.remove() }
        let store = LibraryMetadataCache(directoryURL: fixture.directory, maximumCollections: 1, now: { fixture.date })
        let duplicate = LocalCollectionReference(serviceID: "PLone", kind: .playlist, title: "Equivalent")
        let saved = try await store.save(collections: [fixture.collections[0], duplicate, fixture.collections[1]], accountKey: fixture.first)
        #expect(saved.collections == [fixture.collections[0]] && saved.isTruncated)
        #expect(try await store.load(accountKey: fixture.first) == saved)
    }

    @Test func malformedFutureOversizedAndInvalidMetadataNeverOverwriteTheOriginalFile() async throws {
        let fixture = MetadataCacheFixture()
        defer { fixture.remove() }
        let store = LibraryMetadataCache(directoryURL: fixture.directory, maximumBytes: 1_024, now: { fixture.date })
        let records = [Data("broken".utf8), Data("{\"version\":99}".utf8), Data(repeating: 32, count: 1_025),
                       Data("{\"version\":1,\"capturedAt\":0,\"collections\":[],\"isTruncated\":false,\"futureField\":true}".utf8)]
        for record in records {
            try fixture.write(record, account: fixture.first)
            await #expect(throws: (any Error).self) { try await store.save(collections: fixture.collections, accountKey: fixture.first) }
            #expect(try Data(contentsOf: fixture.file(fixture.first)) == record)
        }
        try FileManager.default.removeItem(at: fixture.file(fixture.first))
        try await store.save(collections: fixture.collections, accountKey: fixture.first)
        let original = try Data(contentsOf: fixture.file(fixture.first))
        for reference in [LocalCollectionReference(serviceID: "https://example.com", kind: .playlist, title: "URL"),
                          LocalCollectionReference(serviceID: "PLvalid", kind: .playlist, title: "Bad\u{0000}title")] {
            await #expect(throws: LibraryMetadataCacheError.invalidMetadata) { try await store.save(collections: [reference], accountKey: fixture.first) }
            #expect(try Data(contentsOf: fixture.file(fixture.first)) == original)
        }
        let tiny = LibraryMetadataCache(directoryURL: fixture.directory, maximumBytes: 10, now: { fixture.date })
        await #expect(throws: LibraryMetadataCacheError.fileTooLarge) { try await tiny.load(accountKey: fixture.first) }
    }

    @Test func nonRegularFilesAndImplausibleFutureDatesAreNotReadAsOfflineSnapshots() async throws {
        let fixture = MetadataCacheFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.file(fixture.first), withIntermediateDirectories: true)
        let store = LibraryMetadataCache(directoryURL: fixture.directory, now: { fixture.date })
        await #expect(throws: LibraryMetadataCacheError.invalidArchive) { try await store.load(accountKey: fixture.first) }
        try FileManager.default.removeItem(at: fixture.file(fixture.first))
        let future = LibraryMetadataSnapshot(capturedAt: fixture.date.addingTimeInterval(301), collections: fixture.collections)
        let original = try JSONEncoder().encode(future)
        try fixture.write(original, account: fixture.first)
        await #expect(throws: LibraryMetadataCacheError.invalidArchive) { try await store.load(accountKey: fixture.first) }
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == original)
    }

    @Test func clearingMetadataPreservesProtectedDataAndMeasuresOnlyTheChosenAccount() async throws {
        let fixture = MetadataCacheFixture()
        defer { fixture.remove() }
        let protected: [(String, Int)] = [("LocalAudio/library.json", 101), ("queue.json", 21), ("SavedQueues/\(fixture.first)/queues.json", 33),
            ("LocalCollections/\(fixture.first)/organization.json", 45),
            ("LocalSongRules/\(fixture.first)/song-rules.json", 51), ("episode-progress/\(fixture.first).json", 61),
            ("listenbrainz/\(fixture.first).json", 71), ("lastfm/\(fixture.first).json", 81),
            ("PendingQueuePlaylists/\(fixture.first)/pending.json", 91), ("credentials-sentinel", 17), ("WebKit/session-sentinel", 27),
            ("SavedQueues/\(fixture.second)/queues.json", 99)]
        for (path, size) in protected {
            let url = fixture.directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: size).write(to: url)
        }
        let cache = LibraryMetadataCache(directoryURL: fixture.directory.appendingPathComponent("MetadataCache"), now: { fixture.date })
        try await cache.save(collections: fixture.collections, accountKey: fixture.first)
        let inventory = ProtectedStorageInventory(directoryURL: fixture.directory)
        let before = try await inventory.measure(accountKey: fixture.first)
        #expect(before.localAudioBytes == 101)
        #expect(before.currentQueueBytes == 21 && before.namedQueueBytes == 33 && before.organizationBytes == 45)
        #expect(before.songRuleBytes == 51 && before.episodeProgressBytes == 61)
        #expect(before.listenBrainzBytes == 71 && before.lastFMBytes == 81 && before.pendingPlaylistBytes == 91)
        try await cache.clear(accountKey: fixture.first)
        #expect(try await inventory.measure(accountKey: fixture.first) == before)
        #expect(try await inventory.measure(accountKey: fixture.second).namedQueueBytes == 99)
        for (path, size) in protected { #expect(try Data(contentsOf: fixture.directory.appendingPathComponent(path)).count == size) }
    }
}
