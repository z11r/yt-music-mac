import Foundation
import Testing
@testable import MusicCore

private struct LocalCollectionFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCollectionTests-" + UUID().uuidString)
    let first = String(repeating: "a", count: 64)
    let second = String(repeating: "b", count: 64)
    func file(_ key: String) -> URL { directory.appendingPathComponent(key).appendingPathComponent("organization.json") }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func write(_ data: Data, key: String) throws {
        try FileManager.default.createDirectory(at: file(key).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file(key))
    }
    var playlist: LocalCollectionReference { LocalCollectionReference(serviceID: "VLPLfirst", kind: .playlist, title: "Playlist") }
    var album: LocalCollectionReference { LocalCollectionReference(serviceID: "MPREfirst", kind: .album, title: "Album") }
}

@Suite("Local collection organization")
struct LocalCollectionStoreTests {
    @Test func pinsAndFolderMembershipAreIndependentAndPersisted() async throws {
        let fixture = LocalCollectionFixture()
        defer { fixture.remove() }
        let store = LocalCollectionStore(directoryURL: fixture.directory)
        let created = try await store.createFolder(name: " Focus ", accountKey: fixture.first)
        let folder = try #require(created.folders.first)
        try await store.setPinned(true, reference: fixture.playlist, accountKey: fixture.first)
        try await store.move(fixture.playlist, to: folder.id, accountKey: fixture.first)
        let unpinned = try await store.setPinned(false, reference: fixture.playlist, accountKey: fixture.first)
        #expect(unpinned.pinned.isEmpty)
        #expect(unpinned.members(of: folder.id).map(\.reference) == [fixture.playlist])
        let loaded = try await store.load(accountKey: fixture.first)
        #expect(loaded == unpinned && loaded.folders[0].name == "Focus")
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.file(fixture.first).path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(!String(decoding: try Data(contentsOf: fixture.file(fixture.first)), as: UTF8.self).contains(fixture.first))
    }

    @Test func deletingAFolderKeepsItsPinnedCollectionsAndDropsOnlyLocalMembership() async throws {
        let fixture = LocalCollectionFixture()
        defer { fixture.remove() }
        let store = LocalCollectionStore(directoryURL: fixture.directory)
        let created = try await store.createFolder(name: "Folder", accountKey: fixture.first)
        let folder = try #require(created.folders.first)
        try await store.setPinned(true, reference: fixture.playlist, accountKey: fixture.first)
        try await store.move(fixture.playlist, to: folder.id, accountKey: fixture.first)
        try await store.move(fixture.album, to: folder.id, accountKey: fixture.first)
        let removed = try await store.removeFolder(id: folder.id, accountKey: fixture.first)
        #expect(removed.folders.isEmpty)
        #expect(removed.pinned.map(\.reference) == [fixture.playlist])
        #expect(removed.bookmarks.first?.folderID == nil && removed.bookmarks.count == 1)
    }

    @Test func equivalentPlaylistIdentifiersDoNotCreateDuplicatePins() async throws {
        let fixture = LocalCollectionFixture()
        defer { fixture.remove() }
        let store = LocalCollectionStore(directoryURL: fixture.directory)
        try await store.setPinned(true, reference: fixture.playlist, accountKey: fixture.first)
        let plain = LocalCollectionReference(serviceID: "PLfirst", kind: .playlist, title: "Updated title")
        let updated = try await store.setPinned(true, reference: plain, accountKey: fixture.first)
        #expect(updated.bookmarks.count == 1 && updated.pinned[0].reference.title == "Updated title")
        #expect(plain.id == fixture.playlist.id)
    }

    @Test func accountNamespacesStaySeparate() async throws {
        let fixture = LocalCollectionFixture()
        defer { fixture.remove() }
        let store = LocalCollectionStore(directoryURL: fixture.directory)
        let first = try await store.createFolder(name: "First account", accountKey: fixture.first)
        try await store.setPinned(true, reference: fixture.playlist, accountKey: fixture.first)
        let second = try await store.load(accountKey: fixture.second)
        #expect(second.folders.isEmpty && second.pinned.isEmpty)
        let folder = try #require(first.folders.first)
        await #expect(throws: LocalCollectionError.missingFolder) { try await store.removeFolder(id: folder.id, accountKey: fixture.second) }
        #expect(try await store.load(accountKey: fixture.first).folders == first.folders)
    }

    @Test func invalidReferencesAndCapacityFailuresPreserveThePreviousFile() async throws {
        let fixture = LocalCollectionFixture()
        defer { fixture.remove() }
        let store = LocalCollectionStore(directoryURL: fixture.directory, maximumFolders: 1, maximumBookmarks: 1)
        try await store.createFolder(name: "Only", accountKey: fixture.first)
        try await store.setPinned(true, reference: fixture.playlist, accountKey: fixture.first)
        let original = try Data(contentsOf: fixture.file(fixture.first))
        await #expect(throws: LocalCollectionError.capacityReached) { try await store.createFolder(name: "Another", accountKey: fixture.first) }
        await #expect(throws: LocalCollectionError.capacityReached) { try await store.setPinned(true, reference: fixture.album, accountKey: fixture.first) }
        let bad = LocalCollectionReference(serviceID: "file:///private", kind: .playlist, title: "Invalid")
        let roomy = LocalCollectionStore(directoryURL: fixture.directory)
        await #expect(throws: LocalCollectionError.invalidCollection) { try await roomy.setPinned(true, reference: bad, accountKey: fixture.first) }
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == original)
    }

    @Test func folderNamesAreValidatedAndRenamingRetainsIdentity() async throws {
        let fixture = LocalCollectionFixture()
        defer { fixture.remove() }
        let store = LocalCollectionStore(directoryURL: fixture.directory)
        let created = try await store.createFolder(name: "Work", accountKey: fixture.first)
        let folder = try #require(created.folders.first)
        await #expect(throws: LocalCollectionError.duplicateName) { try await store.createFolder(name: "work", accountKey: fixture.first) }
        for name in [" ", "Bad\u{0000}name", String(repeating: "x", count: 101)] {
            await #expect(throws: LocalCollectionError.invalidName) { try await store.createFolder(name: name, accountKey: fixture.first) }
        }
        let renamed = try await store.renameFolder(id: folder.id, name: "Rest", accountKey: fixture.first)
        #expect(renamed.folders[0].id == folder.id && renamed.folders[0].name == "Rest")
    }

    @Test func corruptFutureAndOversizedFilesAreRetained() async throws {
        let fixture = LocalCollectionFixture()
        defer { fixture.remove() }
        let store = LocalCollectionStore(directoryURL: fixture.directory)
        let future = try JSONEncoder().encode(LocalCollectionOrganization(version: 99))
        try fixture.write(future, key: fixture.first)
        await #expect(throws: LocalCollectionError.unsupportedVersion(99)) { try await store.load(accountKey: fixture.first) }
        await #expect(throws: LocalCollectionError.unsupportedVersion(99)) { try await store.createFolder(name: "New", accountKey: fixture.first) }
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == future)
        let corrupt = Data("{broken".utf8)
        try fixture.write(corrupt, key: fixture.first)
        await #expect(throws: LocalCollectionError.invalidArchive) { try await store.setPinned(true, reference: fixture.playlist, accountKey: fixture.first) }
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == corrupt)
        try fixture.write(Data(repeating: 32, count: 1_025), key: fixture.first)
        let bounded = LocalCollectionStore(directoryURL: fixture.directory, maximumBytes: 1_024)
        await #expect(throws: LocalCollectionError.fileTooLarge) { try await bounded.load(accountKey: fixture.first) }
    }

    @Test func orphanMembershipAndUnconfirmedAccountKeysAreRejected() async throws {
        let fixture = LocalCollectionFixture()
        defer { fixture.remove() }
        let orphan = LocalCollectionOrganization(bookmarks: [LocalCollectionBookmark(reference: fixture.album, folderID: UUID())])
        let bytes = try JSONEncoder().encode(orphan)
        try fixture.write(bytes, key: fixture.first)
        let store = LocalCollectionStore(directoryURL: fixture.directory)
        await #expect(throws: LocalCollectionError.invalidCollection) { try await store.load(accountKey: fixture.first) }
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == bytes)
        await #expect(throws: NamedQueueError.invalidAccount) { try await store.load(accountKey: "../other") }
    }

    @Test func concurrentPinsAreSerializedWithoutLosingBookmarks() async throws {
        let fixture = LocalCollectionFixture()
        defer { fixture.remove() }
        let store = LocalCollectionStore(directoryURL: fixture.directory)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let reference = LocalCollectionReference(serviceID: "PL\(index)", kind: .playlist, title: "Playlist \(index)")
                    _ = try await store.setPinned(true, reference: reference, accountKey: fixture.first)
                }
            }
            try await group.waitForAll()
        }
        #expect(try await store.load(accountKey: fixture.first).pinned.count == 12)
    }
}
