import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

private struct SavedQueueFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SavedQueueLibraryTests-" + UUID().uuidString)
    let first = String(repeating: "a", count: 64)
    let second = String(repeating: "b", count: 64)
    func remove() { try? FileManager.default.removeItem(at: directory) }
    var snapshot: QueueSnapshot {
        var queue = PlaybackQueue()
        queue.replace(with: [Track(id: "same", title: "Song", artist: "Artist"),
                             Track(id: "same", title: "Song", artist: "Artist"),
                             Track(id: "next", title: "Next", artist: "Artist")], startAt: 1)
        return queue.snapshot(resumePosition: 37.5)
    }
}

private actor ChangingQueueSessions: MusicSessionProviding {
    let values: [MusicSession]
    private var index = 0
    init(_ values: [MusicSession]) { self.values = values }
    func snapshot() -> MusicSession {
        defer { index += 1 }
        return values[min(index, values.count - 1)]
    }
}

@MainActor @Suite("Account-specific saved queue library", .serialized)
struct NamedQueueLibraryTests {
    private func authenticated(_ store: MusicSessionStore, key: String) async {
        await store.replaceSession(accountID: key, cookieHeader: "fixture=1", sapisid: "fixture")
    }

    @Test func switchingAccountsKeepsEachNamedCollectionSeparateAndRetained() async throws {
        let fixture = SavedQueueFixture()
        defer { fixture.remove() }
        let store = NamedQueueStore(directoryURL: fixture.directory)
        let credentials = MusicSessionStore()
        await authenticated(credentials, key: fixture.first)
        let library = NamedQueueLibrary(store: store, sessions: credentials)
        #expect(await library.save(name: "First account", snapshot: fixture.snapshot))
        #expect(library.queues.count == 1)
        let firstID = try #require(library.queues.first?.id)
        library.invalidate()
        await authenticated(credentials, key: fixture.second)
        await library.refresh()
        #expect(library.queues.isEmpty)
        #expect(await library.snapshot(id: firstID) == nil)
        #expect(await library.save(name: "Second account", snapshot: fixture.snapshot))
        library.invalidate()
        await authenticated(credentials, key: fixture.first)
        await library.refresh()
        #expect(library.queues.map(\.name) == ["First account"])
        #expect(try await store.list(accountKey: fixture.second).map(\.name) == ["Second account"])
    }

    @Test func signOutHidesQueuesAndCannotReadOrWriteThePreviousAccount() async throws {
        let fixture = SavedQueueFixture()
        defer { fixture.remove() }
        let store = NamedQueueStore(directoryURL: fixture.directory)
        let credentials = MusicSessionStore()
        await authenticated(credentials, key: fixture.first)
        let library = NamedQueueLibrary(store: store, sessions: credentials)
        #expect(await library.save(name: "Kept locally", snapshot: fixture.snapshot))
        let id = try #require(library.queues.first?.id)
        await credentials.clear()
        await library.refresh()
        #expect(library.queues.isEmpty)
        #expect(await library.snapshot(id: id) == nil)
        #expect(!(await library.save(name: "Not allowed", snapshot: fixture.snapshot)))
        #expect(try await store.list(accountKey: fixture.first).count == 1)
    }

    @Test func anOldUIActionCannotSaveCapturedTracksIntoTheNewAccount() async throws {
        let fixture = SavedQueueFixture()
        defer { fixture.remove() }
        let store = NamedQueueStore(directoryURL: fixture.directory)
        let credentials = MusicSessionStore()
        await authenticated(credentials, key: fixture.first)
        let library = NamedQueueLibrary(store: store, sessions: credentials)
        let oldScope = library.scope
        library.invalidate()
        await authenticated(credentials, key: fixture.second)
        let saved = await library.save(name: "Old captured queue", snapshot: fixture.snapshot, expectedScope: oldScope)
        #expect(!saved)
        #expect(library.queues.isEmpty && library.errorMessage == nil)
        #expect(try await store.list(accountKey: fixture.first).isEmpty)
        #expect(try await store.list(accountKey: fixture.second).isEmpty)
    }

    @Test func anAccountChangeDuringAReadRejectsItsResults() async throws {
        let fixture = SavedQueueFixture()
        defer { fixture.remove() }
        let store = NamedQueueStore(directoryURL: fixture.directory)
        try await store.save(name: "Private first account", snapshot: fixture.snapshot, accountKey: fixture.first)
        let first = MusicSession(scope: UUID(), accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let second = MusicSession(scope: UUID(), accountID: fixture.second, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = NamedQueueLibrary(store: store, sessions: ChangingQueueSessions([first, second]))
        await library.refresh()
        #expect(library.queues.isEmpty)
        #expect(library.errorMessage == SavedQueueAccessError.accountChanged.localizedDescription)
        #expect(!library.isWorking)
    }

    @Test func unconfirmedIdentityNeverCreatesANewNamespace() async {
        let fixture = SavedQueueFixture()
        defer { fixture.remove() }
        let store = NamedQueueStore(directoryURL: fixture.directory)
        let credentials = MusicSessionStore()
        await authenticated(credentials, key: "a display name is not an identity")
        let library = NamedQueueLibrary(store: store, sessions: credentials)
        #expect(!(await library.save(name: "Queue", snapshot: fixture.snapshot)))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test func openingASnapshotRetainsPositionAndSelectionWithoutAutoplay() async throws {
        let preferences = SceneCheckPreferences()
        defer { preferences.remove() }
        let transport = SceneCheckTransport()
        let session = AppSession(configuration: .sceneCheck(preferences: preferences.defaults, transport: transport))
        let snapshot = SavedQueueFixture().snapshot
        try session.restoreSavedQueueSnapshot(snapshot)
        #expect(session.queue.entries == snapshot.entries)
        #expect(session.queue.currentEntryID == snapshot.currentEntryID && session.queue.currentOccurrence == nil)
        #expect(session.savedQueueSnapshot().resumePosition == 37.5)
        #expect(session.remainingQueuePosition == 37.5)
        #expect(!session.wantsPlayback && !session.player.playbackIntent)
        #expect(await transport.attempts == 0)
        await session.shutdown()
    }

    @Test func anInvalidSavedSnapshotCannotReplaceTheExistingQueue() async {
        let preferences = SceneCheckPreferences()
        defer { preferences.remove() }
        let transport = SceneCheckTransport()
        let session = AppSession(configuration: .sceneCheck(preferences: preferences.defaults, transport: transport))
        session.queue.replace(with: SceneCheckFixture.tracks, startAt: 0)
        let original = session.queue.snapshot()
        let invalid = QueueSnapshot(entries: original.entries, currentEntryID: UUID())
        #expect(throws: QueuePersistenceError.self) { try session.restoreSavedQueueSnapshot(invalid) }
        #expect(session.queue.snapshot() == original)
        #expect(await transport.attempts == 0)
        await session.shutdown()
    }
}
