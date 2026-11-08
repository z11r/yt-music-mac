import Darwin
import Foundation
import Testing
@testable import MusicCore

@Suite("Local audio archive operating system lock")
struct LocalAudioArchiveLockTests {
    @Test func independentlyHeldOSLockRefusesBeforeReadingOrReplacingArchive() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAudioLockTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.json")
        let profile = UUID()
        let original = LocalAudioLibraryDocument(profileID: profile, libraryID: UUID())
        let store = LocalAudioLibraryStore(fileURL: file, profileID: profile)
        try await store.save(original, replacing: nil)
        let lock = file.appendingPathExtension("lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o600)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        let replacement = LocalAudioLibraryDocument(profileID: profile, libraryID: original.libraryID)
        let before = try Data(contentsOf: file)
        await #expect(throws: LocalAudioLibraryError.busy) { try await store.save(replacement, replacing: original.revision) }
        #expect(try Data(contentsOf: file) == before)
        let future = Data(#"{"version":999}"#.utf8)
        try future.write(to: file)
        // Even a future version is not read until the independently held writer releases its lock.
        await #expect(throws: LocalAudioLibraryError.busy) { try await store.save(replacement, replacing: original.revision) }
        #expect(try Data(contentsOf: file) == future)
    }

    @Test func stablePrivateLockInodeSurvivesCommitsAndFutureBytesRemainAfterUnlock() async throws {
        let fixture = ArchiveLockFixture(); defer { fixture.remove() }
        let original = LocalAudioLibraryDocument(profileID: fixture.profile, libraryID: UUID())
        let store = fixture.store()
        try await store.save(original, replacing: nil)
        var first = stat(); #expect(lstat(fixture.lock.path, &first) == 0)
        let next = LocalAudioLibraryDocument(profileID: fixture.profile, libraryID: original.libraryID)
        try await store.save(next, replacing: original.revision)
        var second = stat(); #expect(lstat(fixture.lock.path, &second) == 0)
        #expect(first.st_ino == second.st_ino && first.st_dev == second.st_dev)
        #expect(second.st_mode & 0o777 == 0o600 && second.st_nlink == 1 && second.st_size == 0)
        let future = Data(#"{"version":999}"#.utf8)
        try future.write(to: fixture.file)
        await #expect(throws: LocalAudioLibraryError.unsupportedVersion(999)) {
            try await store.save(original, replacing: next.revision)
        }
        #expect(try Data(contentsOf: fixture.file) == future)
        var retained = stat(); #expect(lstat(fixture.lock.path, &retained) == 0)
        #expect(retained.st_ino == first.st_ino)
    }

    @Test func symlinkHardlinkAndPublicOrNonemptyLockFilesCannotAdmitAWrite() async throws {
        let fixture = ArchiveLockFixture(); defer { fixture.remove() }
        let original = LocalAudioLibraryDocument(profileID: fixture.profile, libraryID: UUID())
        let store = fixture.store()
        try await store.save(original, replacing: nil)
        let replacement = LocalAudioLibraryDocument(profileID: fixture.profile, libraryID: original.libraryID)
        let before = try Data(contentsOf: fixture.file)
        let sentinel = fixture.folder.appendingPathComponent("sentinel")
        let sentinelData = Data("retained fixture".utf8); try sentinelData.write(to: sentinel)
        try FileManager.default.removeItem(at: fixture.lock)
        try FileManager.default.createSymbolicLink(at: fixture.lock, withDestinationURL: sentinel)
        await #expect(throws: LocalAudioLibraryError.invalidLibrary) { try await store.save(replacement, replacing: original.revision) }
        #expect(try Data(contentsOf: sentinel) == sentinelData)
        try FileManager.default.removeItem(at: fixture.lock)
        #expect(FileManager.default.createFile(atPath: fixture.lock.path, contents: Data(), attributes: [.posixPermissions: 0o600]))
        let alias = fixture.folder.appendingPathComponent("linked-lock")
        try FileManager.default.linkItem(at: fixture.lock, to: alias)
        await #expect(throws: LocalAudioLibraryError.invalidLibrary) { try await store.save(replacement, replacing: original.revision) }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.lock.path)
        await #expect(throws: LocalAudioLibraryError.invalidLibrary) { try await store.save(replacement, replacing: original.revision) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.lock.path)
        try Data([1]).write(to: fixture.lock)
        await #expect(throws: LocalAudioLibraryError.invalidLibrary) { try await store.save(replacement, replacing: original.revision) }
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    @Test func ownershipAndPrivateModeAdmissionArePureAndFailClosed() {
        #expect(LocalAudioArchiveLockPolicy.allows(owner: 501, mode: 0o100600, links: 1, size: 0, expectedOwner: 501))
        #expect(!LocalAudioArchiveLockPolicy.allows(owner: 502, mode: 0o100600, links: 1, size: 0, expectedOwner: 501))
        #expect(!LocalAudioArchiveLockPolicy.allows(owner: 501, mode: 0o100644, links: 1, size: 0, expectedOwner: 501))
        #expect(!LocalAudioArchiveLockPolicy.allows(owner: 501, mode: 0o120600, links: 1, size: 0, expectedOwner: 501))
        #expect(!LocalAudioArchiveLockPolicy.allows(owner: 501, mode: 0o100600, links: 2, size: 0, expectedOwner: 501))
        #expect(!LocalAudioArchiveLockPolicy.allows(owner: 501, mode: 0o100600, links: 1, size: 1, expectedOwner: 501))
        #expect(LocalAudioArchiveLockPolicy.allowsDirectory(owner: 501, mode: 0o040700, expectedOwner: 501))
        #expect(!LocalAudioArchiveLockPolicy.allowsDirectory(owner: 501, mode: 0o040755, expectedOwner: 501))
    }

    @Test func replacingLockInodeDuringAnAdmittedWritePreservesPreviousArchive() async throws {
        let fixture = ArchiveLockFixture(); defer { fixture.remove() }
        let original = LocalAudioLibraryDocument(profileID: fixture.profile, libraryID: UUID())
        let store = fixture.store()
        try await store.save(original, replacing: nil)
        let before = try Data(contentsOf: fixture.file)
        let replacement = LocalAudioLibraryDocument(profileID: fixture.profile, libraryID: original.libraryID)
        let probe = LockReplacementProbe(url: fixture.lock)
        await #expect(throws: LocalAudioLibraryError.invalidLibrary) {
            try await store.save(replacement, replacing: original.revision, if: { probe.permits() })
        }
        #expect(try Data(contentsOf: fixture.file) == before)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path)
        #expect(!names.contains(where: { $0.hasPrefix(".local-audio-") }))
    }
}

private struct ArchiveLockFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAudioArchiveTests-" + UUID().uuidString)
    let profile = UUID()
    var file: URL { folder.appendingPathComponent("library.json") }
    var lock: URL { file.appendingPathExtension("lock") }
    func store() -> LocalAudioLibraryStore { LocalAudioLibraryStore(fileURL: file, profileID: profile) }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}

private final class LockReplacementProbe: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var calls = 0
    init(url: URL) { self.url = url }
    func permits() -> Bool {
        lock.withLock {
            calls += 1
            if calls == 2 {
                do { try FileManager.default.removeItem(at: url) }
                catch { Issue.record("The fixture must replace its own lock inode") }
                #expect(FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]))
            }
            return true
        }
    }
}
