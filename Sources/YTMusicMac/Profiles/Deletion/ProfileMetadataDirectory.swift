import CryptoKit
import Darwin
import Foundation

/// Used only under the cleanup session's retained exclusive profile lease.
/// All operations are relative to verified descriptors, never bookmark targets.
actor ProfileMetadataDirectory {
    let root: URL
    let profileID: String
    private var locks: [String: Int32] = [:]
    init(root: URL, profileID: String) { self.root = root; self.profileID = profileID }
    deinit { for fd in locks.values { _ = flock(fd, LOCK_UN); Darwin.close(fd) } }

    func exists() throws -> Bool {
        guard let handles = try openTarget() else { return false }
        handles.close(); return true
    }
    func review(recovering: ProfileMetadataManifest?) throws -> ProfileMetadataManifest? {
        let current = try inventory()
        if let recovering {
            try recovering.validate()
            guard current.map(recovering.accepts) ?? true else { throw ProfileCleanupProblem.savedData }
            return recovering
        }
        return current
    }
    func validate(_ manifest: ProfileMetadataManifest) throws {
        try manifest.validate()
        guard try inventory().map(manifest.accepts) ?? true else { throw ProfileCleanupProblem.savedData }
    }
    func isPresent(_ file: ProfileMetadataFile, manifest: ProfileMetadataManifest) throws -> Bool {
        try validate(manifest)
        return try inventory()?.files.contains(where: { $0.path == file.path }) == true
    }
    func remove(_ file: ProfileMetadataFile, manifest: ProfileMetadataManifest) throws {
        try validate(manifest)
        guard manifest.files.contains(file), file.state == .running else { throw ProfileCleanupProblem.stale }
        guard let handles = try openTarget() else { return }
        defer { handles.close() }
        let parent = try openParent(file.path, target: handles.target, manifest: manifest)
        defer { Darwin.close(parent) }
        let name = String(file.path.split(separator: "/").last!)
        guard let current = try inspectFile(parent, name: name, path: file.path, device: handles.info.st_dev) else { return }
        guard current.identity == file.identity, current.digest == file.digest, current.schema == file.schema else { throw ProfileCleanupProblem.savedData }
        if ProfileMetadataFormat.identify(file.path) == .storeLock {
            let prefix = String(file.path.prefix(file.path.count - name.count))
            guard !manifest.files.contains(where: { $0.path.hasPrefix(prefix) && $0.path != file.path && $0.state != .complete }) else { throw ProfileCleanupProblem.savedData }
            guard let locked = locks[file.path] else { throw ProfileCleanupProblem.releaseRequired }
            var actual = stat()
            guard fstat(locked, &actual) == 0, identity(actual) == file.identity else { throw ProfileCleanupProblem.unsafePath }
        }
        try handles.validateNamed()
        try verifyParent(parent, path: file.path, target: handles.target, manifest: manifest)
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, identity(named) == file.identity,
              unlinkat(parent, name, 0) == 0 else { throw ProfileCleanupProblem.unsafePath }
        guard fsync(parent) == 0 else { throw ProfileCleanupProblem.unavailable }
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw ProfileCleanupProblem.unavailable }
    }
    func finish(_ manifest: ProfileMetadataManifest) throws {
        try validate(manifest)
        guard manifest.files.allSatisfy({ $0.state == .complete }) else { throw ProfileCleanupProblem.savedData }
        guard let handles = try openTarget() else { return }
        defer { handles.close() }
        guard let current = try inventory(), current.files.isEmpty else { throw ProfileCleanupProblem.savedData }
        for folder in current.folders.filter({ !$0.path.isEmpty }).sorted(by: { $0.path.count > $1.path.count }) {
            try validate(manifest)
            let parent = try openParent(folder.path, target: handles.target, manifest: manifest)
            defer { Darwin.close(parent) }
            let name = String(folder.path.split(separator: "/").last!)
            var named = stat()
            guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  identity(named).sameDirectory(as: folder.identity) else { throw ProfileCleanupProblem.unsafePath }
            try handles.validateNamed()
            try verifyParent(parent, path: folder.path, target: handles.target, manifest: manifest)
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0, fsync(parent) == 0 else { throw ProfileCleanupProblem.unsafePath }
        }
        try validate(manifest); try handles.validateNamed()
        guard unlinkat(handles.profiles, profileID, AT_REMOVEDIR) == 0, fsync(handles.profiles) == 0 else { throw ProfileCleanupProblem.unsafePath }
        var named = stat()
        guard fstatat(handles.profiles, profileID, &named, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw ProfileCleanupProblem.unavailable }
    }
    private func inventory() throws -> ProfileMetadataManifest? {
        guard let profileUUID = AppProfile.uuid(profileID), let handles = try openTarget() else { return nil }
        defer { handles.close() }
        var result = ProfileMetadataManifest(files: [], folders: [.init(path: "", identity: identity(handles.info))])
        var bytes: Int64 = 0, entries = 0
        try walk(handles.target, path: "", device: handles.info.st_dev, profileUUID: profileUUID, result: &result, bytes: &bytes, entries: &entries)
        try handles.validateNamed()
        try result.validate()
        result.files.sort {
            let a = ProfileMetadataFormat.identify($0.path) == .storeLock, b = ProfileMetadataFormat.identify($1.path) == .storeLock
            return a == b ? $0.path < $1.path : !a
        }
        result = .init(files: result.files, folders: result.folders.sorted { $0.path < $1.path })
        return result
    }
    private func walk(_ fd: Int32, path: String, device: dev_t, profileUUID: UUID, result: inout ProfileMetadataManifest,
                      bytes: inout Int64, entries: inout Int) throws {
        let copy = dup(fd)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { Darwin.close(copy) }; throw ProfileCleanupProblem.unsafePath }
        defer { closedir(stream) }; rewinddir(stream)
        while true {
            errno = 0
            guard let row = readdir(stream) else { guard errno == 0 else { throw ProfileCleanupProblem.unsafePath }; break }
            let name = withUnsafePointer(to: &row.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(row.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            entries += 1
            guard entries <= ProfileMetadataManifest.maximumFiles + ProfileMetadataManifest.maximumFolders,
                  !name.contains("/"), !name.contains("\0") else { throw ProfileCleanupProblem.savedData }
            let relative = path.isEmpty ? name : path + "/" + name
            var named = stat()
            guard fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0, named.st_dev == device else { throw ProfileCleanupProblem.unsafePath }
            if named.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                guard ProfileMetadataPaths.isFolder(relative), ProfileFilesystemAdmission.allows(named, kind: .directory),
                      result.folders.count < ProfileMetadataManifest.maximumFolders else { throw ProfileCleanupProblem.savedData }
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw ProfileCleanupProblem.unsafePath }
                defer { Darwin.close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, ProfileFilesystemAdmission.matches(named, opened) else { throw ProfileCleanupProblem.unsafePath }
                result.folders.append(.init(path: relative, identity: identity(opened)))
                try walk(child, path: relative, device: device, profileUUID: profileUUID, result: &result, bytes: &bytes, entries: &entries)
            } else {
                guard result.files.count < ProfileMetadataManifest.maximumFiles,
                      let file = try inspectFile(fd, name: name, path: relative, device: device) else { throw ProfileCleanupProblem.savedData }
                bytes += file.identity.size
                guard bytes <= ProfileMetadataManifest.maximumBytes else { throw ProfileCleanupProblem.savedData }
                result.files.append(file)
            }
        }
    }
    private func inspectFile(_ parent: Int32, name: String, path: String, device: dev_t) throws -> ProfileMetadataFile? {
        guard let format = ProfileMetadataFormat.identify(path), let profileUUID = AppProfile.uuid(profileID) else { throw ProfileCleanupProblem.savedData }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw ProfileCleanupProblem.unsafePath }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_dev == device, before.st_uid == geteuid(), before.st_mode == 0o100600,
              before.st_nlink == 1, before.st_size >= 0, before.st_size <= format.byteLimit,
              before.st_flags & UInt32(SF_DATALESS) == 0 else { throw ProfileCleanupProblem.savedData }
        if format == .storeLock {
            if let held = locks[path] {
                var info = stat()
                guard fstat(held, &info) == 0, ProfileFilesystemAdmission.matches(info, before) else { throw ProfileCleanupProblem.unsafePath }
            } else {
                let held = openat(parent, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard held >= 0 else { throw ProfileCleanupProblem.unsafePath }
                var info = stat()
                guard fstat(held, &info) == 0, ProfileFilesystemAdmission.matches(info, before), flock(held, LOCK_EX | LOCK_NB) == 0 else {
                    Darwin.close(held); throw ProfileCleanupProblem.releaseRequired
                }
                locks[path] = held
            }
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = Darwin.read(fd, &buffer, min(buffer.count, format.byteLimit + 1 - data.count))
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw ProfileCleanupProblem.unavailable }
            if n == 0 { break }
            data.append(contentsOf: buffer.prefix(n))
            guard data.count <= format.byteLimit else { throw ProfileCleanupProblem.savedData }
        }
        let schema: ProfileMetadataSchemaProof
        do { schema = try ProfileMetadataSchema.validate(data, path: path, profileID: profileUUID) }
        catch { throw ProfileCleanupProblem.savedData }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, identity(before) == identity(after),
              fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, identity(before) == identity(named) else { throw ProfileCleanupProblem.savedData }
        return .init(path: path, identity: identity(before), digest: Data(SHA256.hash(data: data)), schema: schema)
    }
    private struct Handles {
        let base: Int32, profiles: Int32, target: Int32
        let info: stat, profilesInfo: stat
        let name: String
        func close() { Darwin.close(target); Darwin.close(profiles); Darwin.close(base) }
        func validateNamed() throws {
            var named = stat(), parent = stat()
            guard fstatat(base, "Profiles", &parent, AT_SYMLINK_NOFOLLOW) == 0,
                  ProfileFilesystemAdmission.matches(parent, profilesInfo),
                  fstatat(profiles, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  ProfileFilesystemAdmission.matches(named, info) else { throw ProfileCleanupProblem.unsafePath }
        }
    }
    private func openTarget() throws -> Handles? {
        guard AppProfile.uuid(profileID) != nil else { throw ProfileCleanupProblem.protectedProfile }
        let base = try ProfileSafeDirectories.open(root)
        let profiles = openat(base, "Profiles", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if profiles < 0, errno == ENOENT { Darwin.close(base); return nil }
        guard profiles >= 0 else { Darwin.close(base); throw ProfileCleanupProblem.unsafePath }
        let target = openat(profiles, profileID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if target < 0, errno == ENOENT { Darwin.close(profiles); Darwin.close(base); return nil }
        guard target >= 0 else { Darwin.close(profiles); Darwin.close(base); throw ProfileCleanupProblem.unsafePath }
        var baseInfo = stat(), parentInfo = stat(), info = stat(), volume = statfs()
        guard fstat(base, &baseInfo) == 0, fstat(profiles, &parentInfo) == 0, fstat(target, &info) == 0,
              fstatfs(target, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0,
              [baseInfo, parentInfo, info].allSatisfy({ ProfileFilesystemAdmission.allows($0, kind: .directory) && $0.st_dev == baseInfo.st_dev }) else {
            Darwin.close(target); Darwin.close(profiles); Darwin.close(base); throw ProfileCleanupProblem.unsafePath
        }
        let handles = Handles(base: base, profiles: profiles, target: target, info: info, profilesInfo: parentInfo, name: profileID)
        do { try handles.validateNamed(); return handles } catch { handles.close(); throw error }
    }
    private func openParent(_ path: String, target: Int32, manifest: ProfileMetadataManifest) throws -> Int32 {
        var current = dup(target)
        guard current >= 0 else { throw ProfileCleanupProblem.unsafePath }
        do {
            var relative = ""
            for part in path.split(separator: "/").dropLast() {
                relative = relative.isEmpty ? String(part) : relative + "/" + part
                guard let expected = manifest.folders.first(where: { $0.path == relative }) else { throw ProfileCleanupProblem.unsafePath }
                let next = openat(current, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ProfileCleanupProblem.unsafePath }
                var opened = stat(), named = stat()
                guard fstat(next, &opened) == 0, ProfileFilesystemAdmission.allows(opened, kind: .directory),
                      identity(opened).sameDirectory(as: expected.identity),
                      fstatat(current, String(part), &named, AT_SYMLINK_NOFOLLOW) == 0,
                      ProfileFilesystemAdmission.matches(opened, named) else { Darwin.close(next); throw ProfileCleanupProblem.unsafePath }
                Darwin.close(current); current = next
            }
            return current
        } catch { Darwin.close(current); throw error }
    }
    private func verifyParent(_ parent: Int32, path: String, target: Int32, manifest: ProfileMetadataManifest) throws {
        let fresh = try openParent(path, target: target, manifest: manifest)
        defer { Darwin.close(fresh) }
        var captured = stat(), named = stat()
        guard fstat(parent, &captured) == 0, fstat(fresh, &named) == 0,
              ProfileFilesystemAdmission.matches(captured, named) else { throw ProfileCleanupProblem.unsafePath }
    }
    private func identity(_ info: stat) -> ProfileMetadataIdentity {
        .init(device: info.st_dev, inode: info.st_ino, generation: info.st_gen, owner: info.st_uid, mode: info.st_mode,
              links: UInt64(info.st_nlink), size: info.st_size, modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
              changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
}
