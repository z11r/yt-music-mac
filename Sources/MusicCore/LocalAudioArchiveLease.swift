import Darwin
import Foundation

enum LocalAudioArchiveLockPolicy {
    static func allows(owner: UInt32, mode: UInt16, links: UInt64, size: Int64, expectedOwner: UInt32) -> Bool {
        owner == expectedOwner && mode & 0o177777 == 0o100600 && links == 1 && size == 0
    }
    static func allowsDirectory(owner: UInt32, mode: UInt16, expectedOwner: UInt32) -> Bool {
        owner == expectedOwner && mode & 0o177777 == 0o040700
    }
}

/// A stable empty lock inode coordinates cooperating app processes. Never unlink it on release.
/// All archive admission and replacement uses the captured private directory descriptor.
final class LocalAudioArchiveLease {
    private let directory: Int32
    private let descriptor: Int32
    private let lockName: String
    private let archiveName: String
    private let lockIdentity: stat

    init(fileURL: URL) throws {
        let folder = fileURL.deletingLastPathComponent()
        let name = fileURL.lastPathComponent
        let lock = name + ".lock"
        guard !name.isEmpty, name != ".", name != "..", lock.utf8.count <= 255 else {
            throw LocalAudioLibraryError.invalidStorageURL
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw LocalAudioLibraryError.invalidLibrary }
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0,
              LocalAudioArchiveLockPolicy.allowsDirectory(owner: parentInfo.st_uid, mode: parentInfo.st_mode, expectedOwner: geteuid()) else {
            Darwin.close(parent); throw LocalAudioLibraryError.invalidLibrary
        }
        let fd = openat(parent, lock, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { Darwin.close(parent); throw LocalAudioLibraryError.invalidLibrary }
        var info = stat()
        guard fstat(fd, &info) == 0,
              LocalAudioArchiveLockPolicy.allows(owner: info.st_uid, mode: info.st_mode, links: UInt64(info.st_nlink),
                                               size: info.st_size, expectedOwner: geteuid()) else {
            Darwin.close(fd); Darwin.close(parent); throw LocalAudioLibraryError.invalidLibrary
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd); Darwin.close(parent)
            throw code == EWOULDBLOCK || code == EAGAIN ? LocalAudioLibraryError.busy : .invalidLibrary
        }
        do { try Self.validate(directory: parent, descriptor: fd, name: lock, identity: info) }
        catch { _ = flock(fd, LOCK_UN); Darwin.close(fd); Darwin.close(parent); throw error }
        directory = parent; descriptor = fd; lockIdentity = info; archiveName = name; lockName = lock
    }

    func openArchive() throws -> Int32? {
        try validate()
        let fd = openat(directory, archiveName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw LocalAudioLibraryError.invalidLibrary }
        return fd
    }

    func createStaging() throws -> (name: String, descriptor: Int32) {
        let name = ".local-audio-" + UUID().uuidString + ".tmp"
        let fd = openat(directory, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalAudioLibraryError.invalidLibrary }
        return (name, fd)
    }

    func discardStaging(_ name: String) { _ = unlinkat(directory, name, 0) }

    func commit(_ name: String) throws {
        try validate()
        guard renameat(directory, name, directory, archiveName) == 0 else { throw LocalAudioLibraryError.invalidLibrary }
        guard fsync(directory) == 0 else { throw LocalAudioLibraryError.invalidLibrary }
    }

    private func validate() throws {
        try Self.validate(directory: directory, descriptor: descriptor, name: lockName, identity: lockIdentity)
    }

    private static func validate(directory: Int32, descriptor: Int32, name: String, identity: stat) throws {
        var info = stat(), named = stat(), folder = stat()
        guard fstat(directory, &folder) == 0,
              LocalAudioArchiveLockPolicy.allowsDirectory(owner: folder.st_uid, mode: folder.st_mode, expectedOwner: geteuid()),
              fstat(descriptor, &info) == 0,
              LocalAudioArchiveLockPolicy.allows(owner: info.st_uid, mode: info.st_mode, links: UInt64(info.st_nlink),
                                               size: info.st_size, expectedOwner: geteuid()),
              fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_dev == identity.st_dev, info.st_ino == identity.st_ino, info.st_gen == identity.st_gen,
              named.st_dev == info.st_dev, named.st_ino == info.st_ino, named.st_gen == info.st_gen else {
            throw LocalAudioLibraryError.invalidLibrary
        }
    }

    deinit { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor); Darwin.close(directory) }
}
