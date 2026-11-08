import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

private actor ChangingCollectionSessions: MusicSessionProviding {
    let first: MusicSession
    let second: MusicSession
    private var read = false
    init(first: MusicSession, second: MusicSession) { self.first = first; self.second = second }
    func snapshot() -> MusicSession {
        defer { read = true }
        return read ? second : first
    }
}

@MainActor @Suite("Account-specific local collection library", .serialized)
struct LocalCollectionsLibraryTests {
    private let first = String(repeating: "a", count: 64)
    private let second = String(repeating: "b", count: 64)
    private let collection = MusicCollection(id: "VLPLlocal", kind: .playlist, title: "Local reference")

    @Test func pinsAndFoldersAreHiddenAcrossAccountsAndRetainedForTheOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCollectionLibraryTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalCollectionStore(directoryURL: directory)
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: first, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalCollectionsLibrary(store: store, sessions: sessions)
        let oldScope = library.scope
        await library.createFolder(name: "First account", expectedScope: oldScope)
        await library.setPinned(true, collection: collection, expectedScope: oldScope)
        #expect(library.organization.pinned.count == 1 && library.organization.folders.count == 1)
        library.invalidate()
        await sessions.replaceSession(accountID: second, cookieHeader: "fixture=1", sapisid: "fixture")
        await library.refresh()
        #expect(library.organization.pinned.isEmpty && library.organization.folders.isEmpty)
        await library.setPinned(true, collection: collection, expectedScope: oldScope)
        await library.createFolder(name: "Stale", expectedScope: oldScope)
        #expect(try await store.load(accountKey: second).bookmarks.isEmpty)
        #expect(try await store.load(accountKey: second).folders.isEmpty)
        library.invalidate()
        await sessions.replaceSession(accountID: first, cookieHeader: "fixture=1", sapisid: "fixture")
        await library.refresh()
        #expect(library.organization.pinned.count == 1 && library.organization.folders.first?.name == "First account")
    }

    @Test func signOutClearsVisibleOrganizationAndCannotWriteMoreBookmarks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCollectionSignOutTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalCollectionStore(directoryURL: directory)
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: first, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalCollectionsLibrary(store: store, sessions: sessions)
        await library.setPinned(true, collection: collection, expectedScope: library.scope)
        await sessions.clear()
        await library.refresh()
        #expect(library.organization.pinned.isEmpty)
        await library.createFolder(name: "Not allowed", expectedScope: library.scope)
        #expect(library.organization.folders.isEmpty)
        #expect(try await store.load(accountKey: first).pinned.count == 1)
    }

    @Test func anAccountChangeDuringLoadRejectsThePrivateResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCollectionFenceTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalCollectionStore(directoryURL: directory)
        try await store.setPinned(true, reference: collection.localReference, accountKey: first)
        let a = MusicSession(scope: UUID(), accountID: first, cookieHeader: "fixture=1", sapisid: "fixture")
        let b = MusicSession(scope: UUID(), accountID: second, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalCollectionsLibrary(store: store, sessions: ChangingCollectionSessions(first: a, second: b))
        await library.refresh()
        #expect(library.organization.bookmarks.isEmpty && library.errorMessage != nil && !library.isWorking)
    }

    @Test func localReferencesRoundTripOnlyNavigationMetadata() {
        for kind in [MusicCollection.Kind.playlist, .album, .artist] {
            let original = MusicCollection(id: "ServiceID", kind: kind, title: "Title", subtitle: "Details",
                                           artworkURL: URL(string: "https://example.com/art"), radioPlaylistID: "RadioID")
            let restored = original.localReference.collection
            #expect(restored.id == original.id && restored.kind == kind && restored.title == original.title)
            #expect(restored.subtitle == nil && restored.artworkURL == nil && restored.radioPlaylistID == nil)
        }
    }
}
