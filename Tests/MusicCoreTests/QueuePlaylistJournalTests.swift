import Foundation
import Testing
@testable import MusicCore

private struct QueueJournalFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QueuePlaylistJournalTests-" + UUID().uuidString)
    let key = String(repeating: "a", count: 64)
    let other = String(repeating: "b", count: 64)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    var snapshot: QueueSnapshot {
        let song = Track(id: "abcDEF12_-3", title: "Song", artist: "Artist", artworkURL: URL(string: "https://example.com/private?token=secret"))
        var queue = PlaybackQueue(); queue.append([song, song]); return queue.snapshot()
    }
    func plan() throws -> QueuePlaylistPlan { try QueuePlaylistPlan(title: "Reviewed queue", createdAt: date, songs: QueuePlaylistPlan.reviewedSongs(snapshot)) }
    var file: URL { directory.appendingPathComponent(key).appendingPathComponent("pending.json") }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Suite("Durable queue-to-playlist journal")
struct QueuePlaylistJournalTests {
    @Test func reviewPreservesQueueOrderAndOccurrencesWithoutCredentialsOrPlaybackState() throws {
        let fixture = QueueJournalFixture()
        let snapshot = fixture.snapshot
        let songs = try QueuePlaylistPlan.reviewedSongs(snapshot)
        #expect(songs.map(\.id) == snapshot.entries.map(\.id))
        #expect(songs.map(\.videoID) == ["abcDEF12_-3", "abcDEF12_-3"])
        let plan = try QueuePlaylistPlan(title: " Private queue ", createdAt: fixture.date, songs: songs)
        let text = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        for omitted in ["artwork", "https", "token", "resumePosition", "cookie", fixture.key] { #expect(!text.contains(omitted)) }
        #expect(plan.title == "Private queue")
        let uploaded = QueueSnapshot(entries: [QueueEntry(track: Track(id: "abcDEF12_-3", title: "Upload", artist: "Artist", origin: .upload))])
        #expect(throws: QueuePlaylistJournalError.uploadedMusicUnsupported) { try QueuePlaylistPlan.reviewedSongs(uploaded) }
        for track in [Track(id: "abcDEF12_-3", title: "Episode", artist: "Show", contentKind: .podcastEpisode),
                      Track(id: "abcDEF12_-3", title: "Episode", artist: "Show", episode: .init(identity: .init(browseID: "MPEDfixture")))] {
            let episode = QueueSnapshot(entries: [QueueEntry(track: track)])
            #expect(throws: QueuePlaylistJournalError.podcastUnsupported) { try QueuePlaylistPlan.reviewedSongs(episode) }
        }
        let unsafe = QueueSnapshot(entries: [QueueEntry(track: Track(id: "file:///private", title: "Bad", artist: "Artist"))])
        #expect(throws: QueuePlaylistJournalError.invalidQueue) { try QueuePlaylistPlan.reviewedSongs(unsafe) }
    }

    @Test func exclusiveLeaseDurabilityAndCASProtectOnePendingOperationAcrossStoreInstances() async throws {
        let fixture = QueueJournalFixture()
        defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory, now: { fixture.date })
        let another = QueuePlaylistJournalStore(directoryURL: fixture.directory)
        let lease = try await store.acquire(accountKey: fixture.key)
        let initial = try await store.begin(fixture.plan(), lease: lease)
        #expect(try await another.load(accountKey: fixture.key) == initial)
        await #expect(throws: QueuePlaylistJournalError.busy) { try await another.acquire(accountKey: fixture.key) }
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        var creating = initial; creating.phase = .creating
        let saved = try await store.update(creating, expectedRevision: initial.revision, lease: lease)
        #expect(saved.revision != initial.revision)
        await #expect(throws: QueuePlaylistJournalError.stale) { try await store.update(creating, expectedRevision: initial.revision, lease: lease) }
        await store.release(lease)
        let recovered = try await another.acquire(accountKey: fixture.key)
        await #expect(throws: QueuePlaylistJournalError.pendingExists) { try await another.begin(fixture.plan(), lease: recovered) }
        #expect(try await another.load(accountKey: fixture.key)?.phase == .creating)
        await another.release(recovered)
    }

    @Test func knownTargetAndConfirmedPrefixCannotBeReplacedOrRewound() async throws {
        let fixture = QueueJournalFixture()
        defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory)
        let lease = try await store.acquire(accountKey: fixture.key)
        var record = try await store.begin(fixture.plan(), lease: lease)
        var next = record; next.phase = .creating
        record = try await store.update(next, expectedRevision: record.revision, lease: lease)
        next = record; next.phase = .targetKnown; next.targetID = "PLcreated"
        record = try await store.update(next, expectedRevision: record.revision, lease: lease)
        next = record; next.phase = .batchPending; next.attemptedEnd = 1
        record = try await store.update(next, expectedRevision: record.revision, lease: lease)
        next = record; next.phase = .targetKnown; next.attemptedEnd = nil
        next.confirmed = [QueuePlaylistOccurrence(videoID: "abcDEF12_-3", setVideoID: "first=")]
        record = try await store.update(next, expectedRevision: record.revision, lease: lease)
        let original = try Data(contentsOf: fixture.file)
        var wrongTarget = record; wrongTarget.targetID = "PLdifferent"; wrongTarget.phase = .batchPending; wrongTarget.attemptedEnd = 2
        await #expect(throws: QueuePlaylistJournalError.invalidJournal) { try await store.update(wrongTarget, expectedRevision: record.revision, lease: lease) }
        var wrongPrefix = wrongTarget; wrongPrefix.targetID = record.targetID
        wrongPrefix.confirmed = [QueuePlaylistOccurrence(videoID: "abcDEF12_-3", setVideoID: "replaced=")]
        await #expect(throws: QueuePlaylistJournalError.invalidJournal) { try await store.update(wrongPrefix, expectedRevision: record.revision, lease: lease) }
        #expect(try Data(contentsOf: fixture.file) == original)
        await store.release(lease)
    }

    @Test func futureCorruptOversizedAndNonRegularRecordsAreKept() async throws {
        let fixture = QueueJournalFixture()
        defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory, maximumBytes: 1_024)
        try FileManager.default.createDirectory(at: fixture.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for bytes in [Data("broken".utf8), Data("{\"version\":99}".utf8), Data(repeating: 32, count: 1_025)] {
            try bytes.write(to: fixture.file)
            let lease = try await store.acquire(accountKey: fixture.key)
            await #expect(throws: (any Error).self) { try await store.begin(fixture.plan(), lease: lease) }
            #expect(try Data(contentsOf: fixture.file) == bytes)
            await store.release(lease)
        }
        try FileManager.default.removeItem(at: fixture.file)
        try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: true)
        await #expect(throws: QueuePlaylistJournalError.invalidJournal) { try await store.load(accountKey: fixture.key) }
    }

    @Test func accountNamespacesAndExplicitForgetOnlyAddressTheOwnedJournalFile() async throws {
        let fixture = QueueJournalFixture()
        defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory)
        let lease = try await store.acquire(accountKey: fixture.key)
        let record = try await store.begin(fixture.plan(), lease: lease)
        #expect(try await store.load(accountKey: fixture.other) == nil)
        let sentinel = fixture.directory.appendingPathComponent("queue-sentinel.json")
        let original = Data("protected queue".utf8); try original.write(to: sentinel)
        try await store.forget(id: record.plan.id, revision: record.revision, lease: lease)
        #expect(try await store.load(accountKey: fixture.key) == nil)
        #expect(try Data(contentsOf: sentinel) == original)
        await store.release(lease)
        await #expect(throws: NamedQueueError.invalidAccount) { try await store.acquire(accountKey: "../private") }
    }

    @Test func maximumQueueAndJournalBoundsAreEnforcedBeforeAnyRecordIsReplaced() async throws {
        let fixture = QueueJournalFixture()
        defer { fixture.remove() }
        let song = QueuePlaylistPlan.Song(id: UUID(), videoID: "abcDEF12_-3", title: "Song", artist: "Artist")
        let songs = (0..<10_000).map { _ in QueuePlaylistPlan.Song(id: UUID(), videoID: song.videoID, title: song.title, artist: song.artist) }
        #expect(try QueuePlaylistPlan(title: "Maximum", createdAt: fixture.date, songs: songs).songs.count == 10_000)
        #expect(throws: QueuePlaylistJournalError.invalidQueue) { try QueuePlaylistPlan(title: "Too large", createdAt: fixture.date, songs: songs + [song]) }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory, maximumBytes: 100)
        let lease = try await store.acquire(accountKey: fixture.key)
        await #expect(throws: QueuePlaylistJournalError.tooLarge) { try await store.begin(fixture.plan(), lease: lease) }
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        await store.release(lease)
    }
}
