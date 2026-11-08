import Darwin
import Foundation
import ObjectiveC
import WebKit

/// Locks are retained as coordination metadata, never unlinked while another
/// process might still hold the old inode. They contain no profile data.
final class ProfileLifecycleLease: @unchecked Sendable {
    private let descriptor: Int32
    init(root: URL, profileID: String, exclusive: Bool) throws {
        guard AppProfile.uuid(profileID) != nil else { throw ProfileCleanupProblem.protectedProfile }
        let parent = try ProfileSafeDirectories.open(root)
        defer { Darwin.close(parent) }
        if mkdirat(parent, "ProfileLocks", 0o700) != 0 && errno != EEXIST { throw ProfileCleanupProblem.unsafePath }
        let folder = openat(parent, "ProfileLocks", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard folder >= 0 else { throw ProfileCleanupProblem.unsafePath }
        defer { Darwin.close(folder) }
        var folderInfo = stat()
        guard fstat(folder, &folderInfo) == 0, ProfileFilesystemAdmission.allows(folderInfo, kind: .privateDirectory) else { throw ProfileCleanupProblem.unsafePath }
        let fd = openat(folder, profileID + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ProfileCleanupProblem.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, ProfileFilesystemAdmission.allows(info, kind: .lockFile) else {
            Darwin.close(fd); throw ProfileCleanupProblem.unsafePath
        }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            Darwin.close(fd); throw ProfileCleanupProblem.releaseRequired
        }
        descriptor = fd
    }
    deinit { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
@MainActor enum ProfileStoreLeaseRetention {
    private static var key: UInt8 = 0
    static func attach(_ lease: ProfileLifecycleLease, to store: WKWebsiteDataStore) {
        objc_setAssociatedObject(store, &key, lease, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    static func attachView(_ view: WKWebView, from store: WKWebsiteDataStore) {
        if let lease = objc_getAssociatedObject(store, &key) as? ProfileLifecycleLease {
            objc_setAssociatedObject(view, &key, lease, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
enum ProfileSafeDirectories {
    static func isSafeRoot(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "") && url.user == nil && url.password == nil &&
        url.port == nil && url.query == nil && url.fragment == nil && url.absoluteString.utf8.count <= 8_192 &&
        !url.absoluteString.lowercased().contains("%00") && !url.path.contains("\0")
    }
    static func open(_ url: URL) throws -> Int32 {
        guard isSafeRoot(url) else { throw ProfileCleanupProblem.unsafePath }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard current >= 0 else { throw ProfileCleanupProblem.unsafePath }
        do {
            for component in url.pathComponents.dropFirst() {
                guard !component.isEmpty, component != ".", component != ".." else { throw ProfileCleanupProblem.unsafePath }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw ProfileCleanupProblem.unsafePath }
                Darwin.close(current); current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, ProfileFilesystemAdmission.allows(info, kind: .directory) else { throw ProfileCleanupProblem.unsafePath }
            return current
        } catch { Darwin.close(current); throw error }
    }
    static let folders: Set<String> = ["SavedQueues", "LocalCollections", "MetadataCache", "episode-progress", "LocalSongRules", "listenbrainz", "lastfm", "PendingQueuePlaylists"]
    /// Admission for activation checks only directory ownership and path scope;
    /// existing files remain opaque and are never inspected or removed here.
    static func admitProfile(root: URL, id: String, creating: Bool) throws {
        guard AppProfile.uuid(id) != nil else { throw ProfileCleanupProblem.protectedProfile }
        let base = try open(root); defer { Darwin.close(base) }
        func child(_ parent: Int32, _ name: String) throws -> Int32 {
            if creating, mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw ProfileCleanupProblem.unsafePath }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if fd < 0, errno == ENOENT { throw AppProfileError.missingStore }
            guard fd >= 0 else { throw ProfileCleanupProblem.unsafePath }
            return fd
        }
        let profiles = try child(base, "Profiles"); defer { Darwin.close(profiles) }
        let target = try child(profiles, id); defer { Darwin.close(target) }
        var baseInfo = stat(), profilesInfo = stat(), targetInfo = stat()
        guard fstat(base, &baseInfo) == 0, fstat(profiles, &profilesInfo) == 0, fstat(target, &targetInfo) == 0,
              ProfileFilesystemAdmission.allows(profilesInfo, kind: .directory),
              ProfileFilesystemAdmission.allows(targetInfo, kind: .directory),
              baseInfo.st_dev == profilesInfo.st_dev, baseInfo.st_dev == targetInfo.st_dev else { throw ProfileCleanupProblem.unsafePath }
        var namedProfiles = stat(), namedTarget = stat()
        guard fstatat(base, "Profiles", &namedProfiles, AT_SYMLINK_NOFOLLOW) == 0,
              fstatat(profiles, id, &namedTarget, AT_SYMLINK_NOFOLLOW) == 0,
              ProfileFilesystemAdmission.matches(namedProfiles, profilesInfo), ProfileFilesystemAdmission.matches(namedTarget, targetInfo) else { throw ProfileCleanupProblem.unsafePath }
    }
    static func emptyProfile(root: URL, id: String, removing: Bool) throws -> Bool {
        guard AppProfile.uuid(id) != nil else { throw ProfileCleanupProblem.protectedProfile }
        let base = try open(root); defer { Darwin.close(base) }
        let profiles = openat(base, "Profiles", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if profiles < 0 && errno == ENOENT { return true }
        guard profiles >= 0 else { throw ProfileCleanupProblem.unsafePath }
        defer { Darwin.close(profiles) }
        let target = openat(profiles, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if target < 0 && errno == ENOENT { return true }
        guard target >= 0 else { throw ProfileCleanupProblem.unsafePath }
        defer { Darwin.close(target) }
        var identity = stat(); guard fstat(target, &identity) == 0, ProfileFilesystemAdmission.allows(identity, kind: .directory) else { throw ProfileCleanupProblem.unsafePath }
        var parentIdentity = stat(), baseIdentity = stat()
        guard fstat(profiles, &parentIdentity) == 0, fstat(base, &baseIdentity) == 0,
              ProfileFilesystemAdmission.allows(parentIdentity, kind: .directory),
              ProfileFilesystemAdmission.allows(baseIdentity, kind: .directory),
              identity.st_dev == parentIdentity.st_dev, identity.st_dev == baseIdentity.st_dev else { throw ProfileCleanupProblem.unsafePath }
        var count = 0
        try walk(target, depth: 0, device: identity.st_dev, removing: false, count: &count)
        if removing {
            count = 0; try walk(target, depth: 0, device: identity.st_dev, removing: true, count: &count)
            var named = stat()
            guard fstatat(profiles, id, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  ProfileFilesystemAdmission.matches(named, identity), ProfileFilesystemAdmission.allows(named, kind: .directory),
                  unlinkat(profiles, id, AT_REMOVEDIR) == 0 else { throw ProfileCleanupProblem.unsafePath }
            return true
        }
        return false
    }
    private static func walk(_ fd: Int32, depth: Int, device: dev_t, removing: Bool, count: inout Int) throws {
        guard depth <= 2 else { throw ProfileCleanupProblem.savedData }
        let copy = dup(fd)
        guard copy >= 0, let entries = fdopendir(copy) else { if copy >= 0 { Darwin.close(copy) }; throw ProfileCleanupProblem.unsafePath }
        defer { closedir(entries) }
        // dup shares the directory offset; rewind before each bounded pass.
        rewinddir(entries)
        while true {
            errno = 0
            guard let entry = readdir(entries) else {
                guard errno == 0 else { throw ProfileCleanupProblem.unsafePath }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= 128, !name.contains("/"), !name.contains("\0") else { throw ProfileCleanupProblem.savedData }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ProfileCleanupProblem.unsafePath }
            guard info.st_dev == device, ProfileFilesystemAdmission.allows(info, kind: .directory) else { throw ProfileCleanupProblem.unsafePath }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  depth == 0 ? folders.contains(name) : depth == 1 && EpisodeProgressAccountKey.accepts(name) else { throw ProfileCleanupProblem.savedData }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard child >= 0 else { throw ProfileCleanupProblem.unsafePath }
            do {
                var opened = stat()
                guard fstat(child, &opened) == 0, ProfileFilesystemAdmission.matches(opened, info),
                      ProfileFilesystemAdmission.allows(opened, kind: .directory) else { throw ProfileCleanupProblem.unsafePath }
                try walk(child, depth: depth + 1, device: device, removing: removing, count: &count)
                if removing {
                    var named = stat()
                    guard fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                          ProfileFilesystemAdmission.matches(named, opened), ProfileFilesystemAdmission.allows(named, kind: .directory),
                          unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw ProfileCleanupProblem.unsafePath }
                }
            } catch { Darwin.close(child); throw error }
            Darwin.close(child)
        }
    }
}
enum EpisodeProgressAccountKey {
    static func accepts(_ key: String) -> Bool { key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

enum ProfileFilesystemAdmission {
    enum Kind { case directory, privateDirectory, lockFile }
    static func allows(owner: UInt32, mode: UInt16, expectedOwner: UInt32, kind: Kind, links: UInt64 = 1, size: Int64 = 0) -> Bool {
        guard owner == expectedOwner, mode & 0o7000 == 0 else { return false }
        switch kind {
        case .directory: return mode & 0o170000 == 0o040000 && mode & 0o700 == 0o700 && mode & 0o022 == 0
        case .privateDirectory: return mode & 0o170000 == 0o040000 && mode & 0o777 == 0o700
        case .lockFile: return mode & 0o170000 == 0o100000 && mode & 0o777 == 0o600 && links == 1 && size == 0
        }
    }
    static func allows(_ info: stat, kind: Kind) -> Bool {
        allows(owner: info.st_uid, mode: info.st_mode, expectedOwner: geteuid(), kind: kind, links: UInt64(info.st_nlink), size: info.st_size)
    }
    static func sameIdentity(device: Int32, inode: UInt64, generation: UInt32, expectedDevice: Int32, expectedInode: UInt64, expectedGeneration: UInt32) -> Bool {
        device == expectedDevice && inode == expectedInode && generation == expectedGeneration
    }
    static func matches(_ first: stat, _ second: stat) -> Bool {
        sameIdentity(device: first.st_dev, inode: first.st_ino, generation: first.st_gen,
                     expectedDevice: second.st_dev, expectedInode: second.st_ino, expectedGeneration: second.st_gen)
    }
}
