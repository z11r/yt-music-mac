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

    @Test func tagsFiltersAndActiveSelectionStayAccountSpecific() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCollectionFilterScopeTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalCollectionStore(directoryURL: directory)
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: first, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalCollectionsLibrary(store: store, sessions: sessions)
        let oldScope = library.scope
        await library.saveTag(name: "Private tag", expectedScope: oldScope)
        let tag = try #require(library.organization.tags.first)
        await library.setTag(tag.id, present: true, collection: collection, expectedScope: oldScope)
        await library.saveFilter(name: "Tagged", criteria: LocalCollectionFilterCriteria(tagID: tag.id), expectedScope: oldScope)
        let filter = try #require(library.organization.savedFilters.first)
        #expect(library.activateFilter(id: filter.id, expectedScope: oldScope))
        library.invalidate()
        await sessions.replaceSession(accountID: second, cookieHeader: "fixture=1", sapisid: "fixture")
        await library.refresh()
        await library.saveTag(name: "Stale tag", expectedScope: oldScope)
        await library.saveFilter(name: "Stale filter", criteria: LocalCollectionFilterCriteria(), expectedScope: oldScope)
        await library.setTag(tag.id, present: true, collection: collection, expectedScope: oldScope)
        await library.removeTag(id: tag.id, expectedScope: oldScope)
        await library.removeFilter(id: filter.id, expectedScope: oldScope)
        #expect(!library.activateFilter(id: filter.id, expectedScope: oldScope))
        #expect(library.activeFilter == nil && library.organization.tags.isEmpty && library.organization.savedFilters.isEmpty)
        let secondArchive = try await store.load(accountKey: second)
        #expect(secondArchive.tags.isEmpty && secondArchive.savedFilters.isEmpty && secondArchive.bookmarks.isEmpty)
        library.invalidate()
        await sessions.replaceSession(accountID: first, cookieHeader: "fixture=1", sapisid: "fixture")
        await library.refresh()
        #expect(library.organization.tags.first == tag && library.organization.savedFilters.first == filter)
        #expect(library.bookmark(for: collection)?.tagIDs == [tag.id])
        #expect(library.activeFilter == nil)
    }

    @Test func filterPresentationUsesOnlyLoadedMetadataAndRetainsItsNavigationDetails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCollectionFilterPresentationTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: first, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalCollectionsLibrary(store: LocalCollectionStore(directoryURL: directory), sessions: sessions)
        await library.saveFilter(name: "Playlists", criteria: LocalCollectionFilterCriteria(kind: .playlist), expectedScope: library.scope)
        let filter = try #require(library.organization.savedFilters.first)
        #expect(library.activateFilter(id: filter.id, expectedScope: library.scope))
        let original = MusicCollection(id: "VLPLone", kind: .playlist, title: "Loaded", subtitle: "Details", artworkURL: URL(string: "https://example.com/art"), radioPlaylistID: "Radio")
        let equivalent = MusicCollection(id: "PLone", kind: .playlist, title: "Same loaded collection")
        let other = MusicCollection(id: "PLtwo", kind: .playlist, title: "Second")
        let album = MusicCollection(id: "MPREalbum", kind: .album, title: "Album")
        let page = MusicPage(title: "Library", sections: [MusicSection(id: "shelf", title: "More", items: [.collection(equivalent), .collection(other)])],
                             items: [.collection(original), .collection(album), .track(Track(id: "track", title: "Track", artist: "Artist"))])
        #expect(library.filteredCollections(in: page) == [original, other])
        #expect(library.filteredCollections(in: MusicPage(title: "Empty", sections: [], items: [])).isEmpty)
        #expect(library.activateFilter(id: nil, expectedScope: library.scope))
        #expect(library.activeFilter == nil)
    }

    @Test func signOutHidesSavedFiltersAndTheirActiveSelectionWithoutDeletingThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCollectionFilterSignOutTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalCollectionStore(directoryURL: directory)
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: first, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalCollectionsLibrary(store: store, sessions: sessions)
        await library.saveFilter(name: "Private", criteria: LocalCollectionFilterCriteria(), expectedScope: library.scope)
        let filter = try #require(library.organization.savedFilters.first)
        #expect(library.activateFilter(id: filter.id, expectedScope: library.scope))
        await sessions.clear()
        await library.refresh()
        #expect(library.activeFilter == nil && library.organization.savedFilters.isEmpty)
        #expect(try await store.load(accountKey: first).savedFilters == [filter])
    }

    @Test func removingAnActiveSavedFilterClearsItsPresentation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCollectionFilterDeleteTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: first, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalCollectionsLibrary(store: LocalCollectionStore(directoryURL: directory), sessions: sessions)
        await library.saveFilter(name: "All", criteria: LocalCollectionFilterCriteria(), expectedScope: library.scope)
        let filter = try #require(library.organization.savedFilters.first)
        #expect(library.activateFilter(id: filter.id, expectedScope: library.scope))
        await library.removeFilter(id: filter.id, expectedScope: library.scope)
        #expect(library.activeFilterID == nil && library.activeFilter == nil)
    }
}
