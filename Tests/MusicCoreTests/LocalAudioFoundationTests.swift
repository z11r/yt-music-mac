import Foundation
import Testing
@testable import MusicCore

@Suite("Local audio source and queue migration")
struct LocalAudioFoundationTests {
    @Test func restoredListeningMetadataCannotResubmitAReservedLocalIdentifier() throws {
        let raw = Data(#"{"trackID":"LOCAL:orphan","title":"Private","artist":"Artist"}"#.utf8)
        let metadata = try JSONDecoder().decode(ListenMetadata.self, from: raw)
        #expect(!metadata.isValid)
        var state = ListeningLedgerState()
        state.receipts = [.init(entryID: UUID(), trackID: "local:orphan", listenID: UUID())]
        #expect(!state.validate())
    }

    @Test func referenceContainsOnlyVersionAndUUIDsAndRejectsFutureOrUnscopedFields() throws {
        let reference = LocalAudioReference(libraryID: UUID(), fileID: UUID())
        let data = try JSONEncoder().encode(reference)
        #expect(try JSONDecoder().decode(LocalAudioReference.self, from: data) == reference)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "libraryID", "fileID"])
        for change in ["future", "identifier", "path"] {
            var invalid = object
            switch change {
            case "future": invalid["version"] = 2
            case "identifier": invalid["fileID"] = "file:///private/example.mp3"
            default: invalid["path"] = "/private/example.mp3"
            }
            let encoded = try JSONSerialization.data(withJSONObject: invalid)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(LocalAudioReference.self, from: encoded) }
        }
    }

    @Test func legacyTrackAndVersionOneQueueMigrateWithoutChangingOccurrenceOrderOrMetadata() throws {
        let legacy = Data(#"{"id":"scene-fixture","title":"Fixture","artist":"Artist"}"#.utf8)
        let oldTrack = try JSONDecoder().decode(Track.self, from: legacy)
        #expect(oldTrack.isCatalogSong && oldTrack.isServiceTrack)
        #expect(oldTrack.localAudioReference == nil)
        let first = QueueEntry(track: oldTrack, origin: .manual)
        let second = QueueEntry(track: oldTrack, origin: .radio)
        let original = QueueSnapshot(entries: [second, first], currentEntryID: first.id, repeatMode: .all,
            isShuffled: true, unshuffledOrder: [first.id, second.id], resumePosition: 42.5)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["version"] = 1
        let restored = try JSONDecoder().decode(QueueSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored == original)
        #expect(restored.version == 2)
        #expect(try PlaybackQueue(snapshot: restored).currentOccurrence == nil)
    }

    @Test func v2LocalQueuePreservesDuplicatesAndRequiresSameProfileLibraryForBlockedAuthRestore() throws {
        let library = localDocument()
        let record = try #require(library.records.first)
        let track = try record.metadata.track(reference: record.reference)
        let entries = [QueueEntry(track: track), QueueEntry(track: track)]
        let queue = QueueSnapshot(entries: entries, currentEntryID: entries[1].id, resumePosition: 9)
        let restored = try JSONDecoder().decode(QueueSnapshot.self, from: JSONEncoder().encode(queue))
        #expect(restored == queue)
        #expect(entries[0].id != entries[1].id)
        #expect(try restored.isWhollyLocal(in: library, expectedProfileID: library.profileID))
        #expect(throws: LocalAudioLibraryError.wrongProfile) {
            try restored.isWhollyLocal(in: library, expectedProfileID: UUID())
        }
        let foreign = localDocument()
        #expect(throws: LocalAudioLibraryError.wrongLibrary) {
            try restored.isWhollyLocal(in: foreign, expectedProfileID: foreign.profileID)
        }
        let mixed = QueueSnapshot(entries: entries + [QueueEntry(track: Track(id: "legacy", title: "Song", artist: "Artist"))])
        #expect(try !mixed.isWhollyLocal(in: library, expectedProfileID: library.profileID))
        #expect(mixed.entries.count == 3)
        var legacy = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as? [String: Any])
        legacy["version"] = 1
        #expect(throws: LocalAudioLibraryError.invalidReference) {
            try JSONDecoder().decode(QueueSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        }
    }

    @Test func eitherLocalMarkerExcludesServicesEvenWhenTheVideoIDLooksValid() throws {
        let reference = LocalAudioReference(libraryID: UUID(), fileID: UUID())
        var originOnly = Track(id: "abcdefghijk", title: "Song", artist: "Artist", origin: .localFile, contentKind: .song)
        var referenceOnly = Track(id: "abcdefghijk", title: "Song", artist: "Artist", contentKind: .song,
                                  localAudioReference: reference)
        originOnly.artworkURL = URL(string: "https://example.test/private-art")
        referenceOnly.artworkURL = originOnly.artworkURL
        let unscoped = Track(id: "LoCaL:" + reference.fileID.uuidString, title: "Song", artist: "Artist", contentKind: .song)
        for track in [originOnly, referenceOnly, unscoped] {
            #expect(track.hasLocalAudioSource)
            #expect(!track.isServiceTrack && !track.isCatalogSong && !track.isExplicitCatalogSong)
            #expect(track.remoteArtworkURL == nil && track.remoteArtworkVideoID == nil)
            #expect(ListenMetadata(track: track) == nil)
            #expect(throws: LocalAudioLibraryError.invalidReference) { try track.validateLocalAudioSource() }
            #expect(throws: LocalAudioLibraryError.invalidReference) {
                try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track))
            }
        }
        let legacy = Track(id: "abcdefghijk", title: "Song", artist: "Artist", contentKind: .song)
        #expect(legacy.isExplicitCatalogSong && ListenMetadata(track: legacy) != nil)
    }

    @Test func localSourcesNeverBecomePortableLinksServicePlaylistPlansOrServiceEnrichment() throws {
        let library = localDocument()
        let record = try #require(library.records.first)
        let track = try record.metadata.track(reference: record.reference)
        var queue = PlaybackQueue(); queue.replace(with: [track, track])
        #expect(throws: NamedQueueExchangeError.localAudioUnsupported) {
            try NamedQueueExchange.encode(name: "Local", snapshot: queue.snapshot())
        }
        #expect(throws: QueuePlaylistJournalError.localAudioUnsupported) { try QueuePlaylistPlan.reviewedSongs(queue.snapshot()) }
        queue.updateTrack(Track(id: track.id, title: "Remote replacement", artist: "Artist"))
        #expect(queue.entries.allSatisfy { $0.track == track })
        let data = try JSONEncoder().encode(queue.snapshot())
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("bookmark") && !text.contains("file:") && !text.contains("volumeID"))
    }

    @Test func malformedAndFutureQueuesAreRetainedEvenWhenAutomaticSaveIsAttempted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAudioQueueTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for original in [Data("{".utf8), Data(#"{"version":999}"#.utf8)] {
            let file = directory.appendingPathComponent("queue.json")
            try original.write(to: file)
            let store = QueueStore(fileURL: file)
            await #expect(throws: (any Error).self) { try await store.load() }
            await #expect(throws: (any Error).self) { try await store.save(QueueSnapshot(entries: [])) }
            #expect(try Data(contentsOf: file) == original)
            try await store.clear()
        }
    }
}

@Suite("Bounded profile local audio library")
struct LocalAudioLibraryStoreTests {
    @Test func separateStoreActorsCannotBothCommitAgainstTheSameRevision() async throws {
        let fixture = LocalAudioStoreFixture(); defer { fixture.remove() }
        let original = localDocument()
        let first = LocalAudioLibraryStore(fileURL: fixture.file, profileID: original.profileID)
        let second = LocalAudioLibraryStore(fileURL: fixture.file, profileID: original.profileID)
        try await first.save(original, replacing: nil)
        let left = LocalAudioLibraryDocument(profileID: original.profileID, libraryID: original.libraryID)
        let right = LocalAudioLibraryDocument(profileID: original.profileID, libraryID: original.libraryID)
        async let a: Bool = commit(first, document: left, revision: original.revision)
        async let b: Bool = commit(second, document: right, revision: original.revision)
        let outcomes = await [a, b]
        #expect(outcomes.filter { $0 }.count == 1)
        let latest = try #require(try await first.load())
        #expect([left.revision, right.revision].contains(latest.revision))
    }

    @Test func privateAtomicRoundTripCompareAndReplaceAndSeparateProfiles() async throws {
        let fixture = LocalAudioStoreFixture(); defer { fixture.remove() }
        let original = localDocument()
        let store = LocalAudioLibraryStore(fileURL: fixture.file, profileID: original.profileID)
        #expect(try await store.load() == nil)
        try await store.save(original, replacing: nil)
        #expect(try await store.load() == original)
        let updated = LocalAudioLibraryDocument(profileID: original.profileID, libraryID: original.libraryID, records: original.records)
        try await store.save(updated, replacing: original.revision)
        await #expect(throws: LocalAudioLibraryError.staleRevision) { try await store.save(original, replacing: original.revision) }
        #expect(try await store.load() == updated)
        let other = LocalAudioLibraryStore(fileURL: fixture.file, profileID: UUID())
        await #expect(throws: LocalAudioLibraryError.wrongProfile) { try await other.load() }
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let children = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
        #expect(Set(children.map(\.lastPathComponent)) == ["library.json", "library.json.lock"])
    }

    @Test func revokedWriteAndBadArchiveNeverReplaceExistingBytes() async throws {
        let fixture = LocalAudioStoreFixture(); defer { fixture.remove() }
        let document = localDocument()
        let store = LocalAudioLibraryStore(fileURL: fixture.file, profileID: document.profileID)
        try await store.save(document, replacing: nil)
        let bytes = try Data(contentsOf: fixture.file)
        let replacement = LocalAudioLibraryDocument(profileID: document.profileID, libraryID: document.libraryID)
        await #expect(throws: CancellationError.self) { try await store.save(replacement, replacing: document.revision, if: { false }) }
        #expect(try Data(contentsOf: fixture.file) == bytes)
        for invalid in [Data("{".utf8), Data(#"{"version":999}"#.utf8)] {
            try invalid.write(to: fixture.file)
            await #expect(throws: (any Error).self) { try await store.load() }
            await #expect(throws: (any Error).self) { try await store.save(replacement, replacing: nil) }
            #expect(try Data(contentsOf: fixture.file) == invalid)
        }
    }

    @Test func boundsRejectOversizedBookmarksRecordsMetadataAndArchives() async throws {
        let document = localDocument()
        let record = try #require(document.records.first)
        #expect(throws: LocalAudioLibraryError.invalidBookmark) {
            try LocalAudioBookmark(mode: .ordinary, data: Data(repeating: 1, count: LocalAudioBookmark.maximumBytes + 1)).validate()
        }
        #expect(throws: LocalAudioLibraryError.invalidMetadata) {
            try LocalAudioMetadata(title: "Song", artist: "Artist", duration: .infinity, byteCount: 10).validate()
        }
        #expect(throws: LocalAudioLibraryError.capacityReached) {
            try LocalAudioLibraryDocument(profileID: document.profileID, libraryID: document.libraryID,
                records: Array(repeating: record, count: 2_001)).validate()
        }
        let fixture = LocalAudioStoreFixture(); defer { fixture.remove() }
        let small = LocalAudioLibraryStore(fileURL: fixture.file, profileID: document.profileID, maximumBytes: 32)
        await #expect(throws: LocalAudioLibraryError.fileTooLarge) { try await small.save(document, replacing: nil) }
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test func libraryRejectsForeignReferencesAndDuplicateIDsWithoutChangingStoredData() async throws {
        let fixture = LocalAudioStoreFixture(); defer { fixture.remove() }
        let document = localDocument()
        let record = try #require(document.records.first)
        let store = LocalAudioLibraryStore(fileURL: fixture.file, profileID: document.profileID)
        try await store.save(document, replacing: nil)
        let bytes = try Data(contentsOf: fixture.file)
        let duplicate = LocalAudioLibraryDocument(profileID: document.profileID, libraryID: document.libraryID, records: [record, record])
        await #expect(throws: LocalAudioLibraryError.invalidLibrary) { try await store.save(duplicate, replacing: document.revision) }
        let foreign = LocalAudioLibraryDocument(profileID: document.profileID, libraryID: UUID(), records: [record])
        await #expect(throws: LocalAudioLibraryError.wrongLibrary) { try await store.save(foreign, replacing: document.revision) }
        #expect(try Data(contentsOf: fixture.file) == bytes)
    }
}

private func commit(_ store: LocalAudioLibraryStore, document: LocalAudioLibraryDocument, revision: UUID) async -> Bool {
    do { try await store.save(document, replacing: revision); return true }
    catch { return false }
}

private struct LocalAudioStoreFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAudioLibraryTests-" + UUID().uuidString)
    var file: URL { directory.appendingPathComponent("library.json") }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func localDocument() -> LocalAudioLibraryDocument {
    let reference = LocalAudioReference(libraryID: UUID(), fileID: UUID())
    let record = LocalAudioLibraryRecord(reference: reference,
        metadata: LocalAudioMetadata(title: "Local fixture", artist: "Artist", duration: 120, byteCount: 1_024),
        identity: LocalAudioFileIdentity(volumeID: "fixture-volume", fileID: 42),
        bookmark: LocalAudioBookmark(mode: .ordinary, data: Data([1, 2, 3])))
    return LocalAudioLibraryDocument(profileID: UUID(), libraryID: reference.libraryID, records: [record])
}
