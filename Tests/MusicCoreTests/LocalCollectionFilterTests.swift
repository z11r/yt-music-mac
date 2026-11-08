import Foundation
import Testing
@testable import MusicCore

private struct CollectionFilterFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CollectionFilterTests-" + UUID().uuidString)
    let account = String(repeating: "a", count: 64)
    var file: URL { directory.appendingPathComponent(account).appendingPathComponent("organization.json") }
    var reference: LocalCollectionReference { LocalCollectionReference(serviceID: "VLPLfocus", kind: .playlist, title: "Evening Focus") }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }
}

@Suite("Local tags and loaded collection filters")
struct LocalCollectionFilterTests {
    @Test func versionOneMigratesInMemoryAndWritesOnlyOnAnExplicitChange() async throws {
        let fixture = CollectionFilterFixture()
        defer { fixture.remove() }
        let folderID = UUID()
        let original = Data("""
        {"version":1,"folders":[{"id":"\(folderID)","name":"Old folder"}],"bookmarks":[{"reference":{"serviceID":"VLPLfocus","kind":"playlist","title":"Evening Focus"},"isPinned":true,"folderID":"\(folderID)"}]}
        """.utf8)
        try fixture.write(original)
        let store = LocalCollectionStore(directoryURL: fixture.directory)
        let loaded = try await store.load(accountKey: fixture.account)
        #expect(loaded.version == 2 && loaded.tags.isEmpty && loaded.savedFilters.isEmpty)
        #expect(loaded.pinned.first?.folderID == folderID && loaded.pinned.first?.tagIDs.isEmpty == true)
        #expect(try Data(contentsOf: fixture.file) == original)
        let changed = try await store.saveTag(name: "Focus", accountKey: fixture.account)
        #expect(changed.pinned.count == 1 && changed.folders.first?.id == folderID)
        #expect(try JSONDecoder().decode(LocalCollectionOrganization.self, from: Data(contentsOf: fixture.file)) == changed)
    }

    @Test func tagsAreIndependentOfPinsAndFoldersAndRenameKeepsMembership() async throws {
        let fixture = CollectionFilterFixture()
        defer { fixture.remove() }
        let store = LocalCollectionStore(directoryURL: fixture.directory)
        let tag = try #require(try await store.saveTag(name: "Calm", accountKey: fixture.account).tags.first)
        try await store.setTag(tag.id, present: true, reference: fixture.reference, accountKey: fixture.account)
        try await store.setPinned(true, reference: fixture.reference, accountKey: fixture.account)
        try await store.setPinned(false, reference: fixture.reference, accountKey: fixture.account)
        let folder = try #require(try await store.createFolder(name: "Temporary", accountKey: fixture.account).folders.first)
        try await store.move(fixture.reference, to: folder.id, accountKey: fixture.account)
        try await store.removeFolder(id: folder.id, accountKey: fixture.account)
        let renamed = try await store.saveTag(id: tag.id, name: "Quiet", accountKey: fixture.account)
        #expect(renamed.tags[0].id == tag.id && renamed.tags[0].name == "Quiet")
        #expect(renamed.bookmarks[0].tagIDs == [tag.id] && renamed.bookmarks[0].folderID == nil)
        let removed = try await store.removeTag(id: tag.id, accountKey: fixture.account)
        #expect(removed.bookmarks.isEmpty && removed.tags.isEmpty)
    }

    @Test func combinedCriteriaMatchOnlyLoadedCollectionsAndPreserveTheirOrder() {
        let fixture = CollectionFilterFixture()
        let tag = LocalCollectionTag(name: "Focus")
        let folder = LocalCollectionFolder(name: "Work")
        let first = fixture.reference
        let second = LocalCollectionReference(serviceID: "PLother", kind: .playlist, title: "Morning FOCUS")
        let unloaded = LocalCollectionReference(serviceID: "PLunloaded", kind: .playlist, title: "Unloaded Focus")
        let album = LocalCollectionReference(serviceID: "MPREalbum", kind: .album, title: "Focus")
        let organization = LocalCollectionOrganization(folders: [folder], bookmarks: [first, second, unloaded, album].map {
            LocalCollectionBookmark(reference: $0, isPinned: true, folderID: folder.id, tagIDs: [tag.id])
        }, tags: [tag])
        let criteria = LocalCollectionFilterCriteria(titleContains: "focus", kind: .playlist, pinnedOnly: true, folderID: folder.id, tagID: tag.id)
        let duplicate = LocalCollectionReference(serviceID: "PLfocus", kind: .playlist, title: "Duplicate Focus")
        #expect(criteria.apply(to: [second, first, album, duplicate], in: organization) == [second, first])
        #expect(criteria.apply(to: [], in: organization).isEmpty)
        #expect(!LocalCollectionFilterCriteria(tagID: UUID()).matches(first, in: organization))
    }

    @Test func savedCriteriaRoundTripAndUpdateWithoutStoringResultCollections() async throws {
        let fixture = CollectionFilterFixture()
        defer { fixture.remove() }
        let store = LocalCollectionStore(directoryURL: fixture.directory)
        let created = try await store.saveFilter(name: "Focus playlists", criteria: LocalCollectionFilterCriteria(titleContains: "focus", kind: .playlist), accountKey: fixture.account)
        let filter = try #require(created.savedFilters.first)
        let updated = try await store.saveFilter(id: filter.id, name: "Pinned focus", criteria: LocalCollectionFilterCriteria(titleContains: "focus", pinnedOnly: true), accountKey: fixture.account)
        #expect(updated.savedFilters[0].id == filter.id && updated.savedFilters[0].criteria.pinnedOnly)
        #expect(try await store.load(accountKey: fixture.account) == updated)
        let data = try Data(contentsOf: fixture.file)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let filters = try #require(json["savedFilters"] as? [[String: Any]])
        #expect(Set(filters[0].keys) == ["id", "name", "criteria"])
        #expect(String(decoding: data, as: UTF8.self).contains("loadedLibraryCollections"))
        #expect(!String(decoding: data, as: UTF8.self).contains(fixture.account))
        #expect(updated.bookmarks.isEmpty)
        #expect(try await store.removeFilter(id: filter.id, accountKey: fixture.account).savedFilters.isEmpty)
    }

    @Test func deletingReferencedTagsOrFoldersCannotSilentlyBroadenAFilter() async throws {
        let fixture = CollectionFilterFixture()
        defer { fixture.remove() }
        let store = LocalCollectionStore(directoryURL: fixture.directory)
        let tag = try #require(try await store.saveTag(name: "Focus", accountKey: fixture.account).tags.first)
        let folder = try #require(try await store.createFolder(name: "Work", accountKey: fixture.account).folders.first)
        let filter = try #require(try await store.saveFilter(name: "Both", criteria: LocalCollectionFilterCriteria(folderID: folder.id, tagID: tag.id), accountKey: fixture.account).savedFilters.first)
        let original = try Data(contentsOf: fixture.file)
        await #expect(throws: LocalCollectionError.referencedByFilter) { try await store.removeTag(id: tag.id, accountKey: fixture.account) }
        await #expect(throws: LocalCollectionError.referencedByFilter) { try await store.removeFolder(id: folder.id, accountKey: fixture.account) }
        #expect(try Data(contentsOf: fixture.file) == original)
        try await store.saveFilter(id: filter.id, name: "Title only", criteria: LocalCollectionFilterCriteria(titleContains: "Focus"), accountKey: fixture.account)
        try await store.removeTag(id: tag.id, accountKey: fixture.account)
        #expect(try await store.removeFolder(id: folder.id, accountKey: fixture.account).folders.isEmpty)
    }

    @Test func futureVersionsAndUnsupportedCriteriaKeepTheirOriginalFiles() async throws {
        let fixture = CollectionFilterFixture()
        defer { fixture.remove() }
        let store = LocalCollectionStore(directoryURL: fixture.directory)
        let documents = [
            "{\"version\":99}",
            "{\"version\":2,\"folders\":[],\"bookmarks\":[],\"tags\":[],\"savedFilters\":[],\"futureOrganization\":true}",
            "{\"version\":2,\"folders\":[],\"bookmarks\":[],\"tags\":[],\"savedFilters\":[{\"id\":\"\(UUID())\",\"name\":\"Future\",\"criteria\":{\"scope\":\"allServiceMusic\",\"titleContains\":\"\",\"pinnedOnly\":false}}]}",
            "{\"version\":2,\"folders\":[],\"bookmarks\":[],\"tags\":[],\"savedFilters\":[{\"id\":\"\(UUID())\",\"name\":\"Future\",\"criteria\":{\"scope\":\"loadedLibraryCollections\",\"titleContains\":\"\",\"pinnedOnly\":false,\"downloadsOnly\":true}}]}",
            "{\"version\":2,\"folders\":[],\"bookmarks\":[],\"tags\":[],\"savedFilters\":[{\"id\":\"\(UUID())\",\"name\":\"Future\",\"criteria\":{\"scope\":\"loadedLibraryCollections\",\"titleContains\":\"\",\"pinnedOnly\":false,\"kind\":\"futureUnsupportedKind\"}}]}"
        ]
        for document in documents {
            let bytes = Data(document.utf8)
            try fixture.write(bytes)
            await #expect(throws: (any Error).self) { try await store.saveTag(name: "New", accountKey: fixture.account) }
            #expect(try Data(contentsOf: fixture.file) == bytes)
        }
    }

    @Test func invalidCriteriaDuplicateNamesAndCapacityKeepThePreviousArchive() async throws {
        let fixture = CollectionFilterFixture()
        defer { fixture.remove() }
        let store = LocalCollectionStore(directoryURL: fixture.directory, maximumTags: 1, maximumFilters: 1)
        try await store.saveTag(name: "Focus", accountKey: fixture.account)
        let filter = try #require(try await store.saveFilter(name: "All", criteria: LocalCollectionFilterCriteria(), accountKey: fixture.account).savedFilters.first)
        let original = try Data(contentsOf: fixture.file)
        await #expect(throws: LocalCollectionError.duplicateName) { try await store.saveTag(name: "focus", accountKey: fixture.account) }
        await #expect(throws: LocalCollectionError.capacityReached) { try await store.saveTag(name: "Another", accountKey: fixture.account) }
        await #expect(throws: LocalCollectionError.capacityReached) { try await store.saveFilter(name: "Another", criteria: LocalCollectionFilterCriteria(), accountKey: fixture.account) }
        for criteria in [LocalCollectionFilterCriteria(titleContains: String(repeating: "x", count: 201)), LocalCollectionFilterCriteria(folderID: UUID()), LocalCollectionFilterCriteria(tagID: UUID())] {
            await #expect(throws: LocalCollectionError.invalidFilter) { try await store.saveFilter(id: filter.id, name: "All", criteria: criteria, accountKey: fixture.account) }
        }
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test func concurrentTagAssignmentsRetainEveryMembership() async throws {
        let fixture = CollectionFilterFixture()
        defer { fixture.remove() }
        let store = LocalCollectionStore(directoryURL: fixture.directory)
        for index in 0..<12 { try await store.saveTag(name: "Tag \(index)", accountKey: fixture.account) }
        let organization = try await store.load(accountKey: fixture.account)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for tag in organization.tags {
                group.addTask { _ = try await store.setTag(tag.id, present: true, reference: fixture.reference, accountKey: fixture.account) }
            }
            try await group.waitForAll()
        }
        #expect(try await store.load(accountKey: fixture.account).bookmarks[0].tagIDs.count == 12)
    }
}
