import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

private struct StorageFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StorageControllerTests-" + UUID().uuidString)
    let suite = "StoragePreferences-" + UUID().uuidString
    let first = String(repeating: "a", count: 64)
    let second = String(repeating: "b", count: 64)
    var preferences: UserDefaults { UserDefaults(suiteName: suite)! }
    var cache: LibraryMetadataCache { LibraryMetadataCache(directoryURL: directory.appendingPathComponent("MetadataCache")) }
    func file(_ key: String) -> URL { directory.appendingPathComponent("MetadataCache").appendingPathComponent(key).appendingPathComponent("library.json") }
    var page: MusicPage {
        MusicPage(title: "Private library title", sections: [], items: [
            .collection(MusicCollection(id: "VLPLone", kind: .playlist, title: "Collection", subtitle: "Not cached",
                artworkURL: URL(string: "https://example.com/auth?token=private"), radioPlaylistID: "OpaqueRadio")),
            .track(Track(id: "abcDEF12_-3", title: "Track", artist: "Artist"))])
    }
    func remove() {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor ChangingStorageSessions: MusicSessionProviding {
    let first: MusicSession
    let second: MusicSession
    private var read = false
    init(first: MusicSession, second: MusicSession) { self.first = first; self.second = second }
    func snapshot() -> MusicSession { defer { read = true }; return read ? second : first }
}

private actor SuspendedStorageSessions: MusicSessionProviding {
    let session: MusicSession
    private var count = 0
    private var blocked: CheckedContinuation<MusicSession, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    init(session: MusicSession) { self.session = session }
    func snapshot() async -> MusicSession {
        count += 1
        if count == 3 {
            return await withCheckedContinuation {
                blocked = $0
                waiter?.resume()
                waiter = nil
            }
        }
        return session
    }
    func waitForBlockedRead() async {
        if blocked != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { blocked?.resume(returning: session); blocked = nil }
}

@MainActor @Suite("Scoped storage controls and metadata capture", .serialized)
struct StorageControllerTests {
    @Test func captureCachesOnlyNavigationMetadataAndRefreshReportsActualBytes() async throws {
        let fixture = StorageFixture()
        defer { fixture.remove() }
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let storage = StorageController(cache: fixture.cache, inventory: ProtectedStorageInventory(directoryURL: fixture.directory), sessions: sessions, preferences: fixture.preferences)
        let context = try #require(await storage.beginCapture())
        await storage.capture(fixture.page, context: context)
        #expect(storage.snapshot?.collections.count == 1)
        let data = try Data(contentsOf: fixture.file(fixture.first))
        let text = String(decoding: data, as: UTF8.self)
        for excluded in ["token", "OpaqueRadio", "Not cached", "Track", "cookieHeader", fixture.first] { #expect(!text.contains(excluded)) }
        await storage.refresh(expectedScope: storage.scope)
        #expect(storage.metadataBytes == data.count && storage.protectedUsage?.currentQueueBytes == 0 && !storage.isWorking)
    }

    @Test func aPageCapturedForAnOldAccountCannotBeWrittenForTheNewAccount() async throws {
        let fixture = StorageFixture()
        defer { fixture.remove() }
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let storage = StorageController(cache: fixture.cache, inventory: nil, sessions: sessions, preferences: fixture.preferences)
        let context = try #require(await storage.beginCapture())
        await sessions.replaceSession(accountID: fixture.second, cookieHeader: "fixture=1", sapisid: "fixture")
        await storage.capture(fixture.page, context: context)
        #expect(storage.snapshot == nil && storage.metadataBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(fixture.first).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.file(fixture.second).path))
    }

    @Test func clearInvalidatesRequestsAlreadyInFlightAndLaterCapturesCanRefillTheCache() async throws {
        let fixture = StorageFixture()
        defer { fixture.remove() }
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let storage = StorageController(cache: fixture.cache, inventory: nil, sessions: sessions, preferences: fixture.preferences)
        let first = try #require(await storage.beginCapture())
        await storage.capture(fixture.page, context: first)
        let pending = try #require(await storage.beginCapture())
        await storage.clearMetadata(expectedScope: storage.scope)
        await storage.capture(fixture.page, context: pending)
        #expect(storage.snapshot == nil && storage.metadataBytes == 0 && storage.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(fixture.first).path))
        let later = try #require(await storage.beginCapture())
        await storage.capture(fixture.page, context: later)
        #expect(storage.snapshot != nil && storage.metadataBytes > 0)
    }

    @Test func anOlderPageCannotReplaceANewerLoadedLibrarySnapshot() async throws {
        let fixture = StorageFixture()
        defer { fixture.remove() }
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let storage = StorageController(cache: fixture.cache, inventory: nil, sessions: sessions, preferences: fixture.preferences)
        let older = try #require(await storage.beginCapture())
        let newer = try #require(await storage.beginCapture())
        let page = MusicPage(title: "Newer", sections: [], items: [.collection(MusicCollection(id: "MPREtwo", kind: .album, title: "Newer"))])
        await storage.capture(page, context: newer)
        await storage.capture(fixture.page, context: older)
        #expect(storage.snapshot?.collections.first?.title == "Newer")
    }

    @Test func anAlreadyWrittenSnapshotCannotReappearAfterClearWhileItsAccountCheckWasPending() async throws {
        let fixture = StorageFixture()
        defer { fixture.remove() }
        let session = MusicSession(scope: UUID(), accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let sessions = SuspendedStorageSessions(session: session)
        let storage = StorageController(cache: fixture.cache, inventory: nil, sessions: sessions, preferences: fixture.preferences)
        let context = try #require(await storage.beginCapture())
        let pending = Task { await storage.capture(fixture.page, context: context) }
        await sessions.waitForBlockedRead()
        await storage.clearMetadata(expectedScope: storage.scope)
        await sessions.release()
        await pending.value
        #expect(storage.snapshot == nil && storage.metadataBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(fixture.first).path))
    }

    @Test func staleUIActionsAndSignOutCannotExposeOrClearAnotherAccountsCache() async throws {
        let fixture = StorageFixture()
        defer { fixture.remove() }
        let sessions = MusicSessionStore()
        let cache = fixture.cache
        let reference = LocalCollectionReference(serviceID: "PLone", kind: .playlist, title: "Retained")
        try await cache.save(collections: [reference], accountKey: fixture.first)
        try await cache.save(collections: [reference], accountKey: fixture.second)
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let storage = StorageController(cache: cache, inventory: nil, sessions: sessions, preferences: fixture.preferences)
        let oldScope = storage.scope
        await storage.refresh(expectedScope: oldScope)
        #expect(storage.snapshot != nil)
        storage.invalidate()
        await sessions.replaceSession(accountID: fixture.second, cookieHeader: "fixture=1", sapisid: "fixture")
        await storage.clearMetadata(expectedScope: oldScope)
        await storage.refresh(expectedScope: oldScope)
        #expect(storage.snapshot == nil && storage.protectedUsage == nil && storage.metadataBytes == 0)
        #expect(try await cache.load(accountKey: fixture.second) != nil)
        await storage.refresh(expectedScope: storage.scope)
        #expect(storage.snapshot != nil)
        await sessions.clear()
        await storage.refresh(expectedScope: storage.scope)
        #expect(storage.snapshot == nil && storage.metadataBytes == 0 && storage.protectedUsage == nil)
        #expect(await storage.beginCapture() == nil)
        #expect(try await cache.load(accountKey: fixture.first) != nil)
    }

    @Test func disablingNewSnapshotsUsesIsolatedPreferencesAndRetainsExplicitlyReadableMetadata() async throws {
        let fixture = StorageFixture()
        defer { fixture.remove() }
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let cache = fixture.cache
        let storage = StorageController(cache: cache, inventory: nil, sessions: sessions, preferences: fixture.preferences)
        let context = try #require(await storage.beginCapture())
        await storage.capture(fixture.page, context: context)
        storage.setMetadataEnabled(false)
        #expect(await storage.beginCapture() == nil)
        let restored = StorageController(cache: cache, inventory: nil, sessions: sessions, preferences: fixture.preferences)
        #expect(!restored.metadataEnabled)
        await restored.refresh(expectedScope: restored.scope)
        #expect(restored.snapshot != nil)
        restored.setMetadataEnabled(true)
        #expect(await restored.beginCapture() != nil)
    }

    @Test func anAccountChangeWhileReadingRejectsItsPrivateMetadata() async throws {
        let fixture = StorageFixture()
        defer { fixture.remove() }
        let cache = fixture.cache
        try await cache.save(collections: [LocalCollectionReference(serviceID: "PLone", kind: .playlist, title: "Private")], accountKey: fixture.first)
        let first = MusicSession(scope: UUID(), accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let second = MusicSession(scope: UUID(), accountID: fixture.second, cookieHeader: "fixture=1", sapisid: "fixture")
        let storage = StorageController(cache: cache, inventory: nil, sessions: ChangingStorageSessions(first: first, second: second), preferences: fixture.preferences)
        await storage.refresh(expectedScope: storage.scope)
        #expect(storage.snapshot == nil && storage.metadataBytes == 0 && storage.errorMessage != nil)
    }

    @Test func unconfirmedIdentitiesCannotCreateMetadataStorage() async {
        let fixture = StorageFixture()
        defer { fixture.remove() }
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: "display-name", cookieHeader: "fixture=1", sapisid: "fixture")
        let storage = StorageController(cache: fixture.cache, inventory: nil, sessions: sessions, preferences: fixture.preferences)
        #expect(await storage.beginCapture() == nil)
        await storage.refresh(expectedScope: storage.scope)
        #expect(storage.snapshot == nil && storage.errorMessage != nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }
}
