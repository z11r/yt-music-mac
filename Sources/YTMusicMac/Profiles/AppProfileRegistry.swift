import Darwin
import Foundation

struct AppProfileRegistrySnapshot: Equatable, Sendable {
    let archive: AppProfileArchive
    let revision: Data?
}

protocol AppProfileRegistry: Sendable {
    func load() async throws -> AppProfileRegistrySnapshot
    func save(_ archive: AppProfileArchive, replacing revision: Data?) async throws -> AppProfileRegistrySnapshot
}

protocol AppProfileRegistryIO: Sendable {
    func read() throws -> Data?
    func replace(_ data: Data, expected: Data?) throws
    func replaceDurably(_ data: Data, expected: Data?) throws
}

extension AppProfileRegistryIO {
    func replaceDurably(_ data: Data, expected: Data?) throws { try replace(data, expected: expected) }
}

actor AppProfileRegistryStore: AppProfileRegistry {
    static let byteLimit = 65_536
    private let io: any AppProfileRegistryIO
    init(io: any AppProfileRegistryIO) { self.io = io }
    func load() throws -> AppProfileRegistrySnapshot {
        let data = try io.read()
        return .init(archive: try decode(data), revision: data)
    }
    func save(_ archive: AppProfileArchive, replacing revision: Data?) throws -> AppProfileRegistrySnapshot {
        try archive.validate()
        let current = try io.read()
        _ = try decode(current) // Never replace malformed or future data.
        guard current == revision else { throw AppProfileError.stale }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= Self.byteLimit else { throw AppProfileError.tooLarge }
        if archive.version == 2 { try io.replaceDurably(data, expected: current) }
        else { try io.replace(data, expected: current) }
        return .init(archive: archive, revision: data)
    }
    private func decode(_ data: Data?) throws -> AppProfileArchive {
        guard let data else { return .original }
        guard data.count <= Self.byteLimit else { throw AppProfileError.tooLarge }
        do {
            try ProfileMetadataJSON.check(data)
            let archive = try JSONDecoder().decode(AppProfileArchive.self, from: data)
            try archive.validate(); return archive
        } catch let error as AppProfileError { throw error }
        catch { throw AppProfileError.invalidRegistry }
    }
}

/// Production adapter. Initialization is inert; tests use memory IO instead.
struct FileAppProfileRegistryIO: AppProfileRegistryIO {
    let file: URL
    func read() throws -> Data? {
        guard file.isFileURL else { throw AppProfileError.unavailable }
        do {
            let values = try FileManager.default.attributesOfItem(atPath: file.path)
            guard values[.type] as? FileAttributeType == .typeRegular else { throw AppProfileError.invalidRegistry }
            guard let size = values[.size] as? NSNumber, size.intValue <= AppProfileRegistryStore.byteLimit else { throw AppProfileError.tooLarge }
            guard let stream = InputStream(url: file) else { throw AppProfileError.unavailable }
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: min(buffer.count, AppProfileRegistryStore.byteLimit + 1 - data.count))
                guard count >= 0 else { throw AppProfileError.unavailable }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= AppProfileRegistryStore.byteLimit else { throw AppProfileError.tooLarge }
            }
            return data
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
    }
    func replace(_ data: Data, expected: Data?) throws { try replace(data, expected: expected, directorySync: false) }
    func replaceDurably(_ data: Data, expected: Data?) throws { try replace(data, expected: expected, directorySync: true) }
    private func replace(_ data: Data, expected: Data?, directorySync: Bool) throws {
        guard file.isFileURL, data.count <= AppProfileRegistryStore.byteLimit else { throw AppProfileError.unavailable }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let lock = file.appendingPathExtension("lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AppProfileError.unavailable }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AppProfileError.busy }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard try read() == expected else { throw AppProfileError.stale }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".app-profiles-" + UUID().uuidString + ".tmp")
        let output = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard output >= 0 else { throw AppProfileError.unavailable }
        defer { Darwin.close(output); _ = Darwin.unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw AppProfileError.unavailable }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(output, base.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw AppProfileError.unavailable }
                offset += written
            }
        }
        guard Darwin.fsync(output) == 0, Darwin.rename(temporary.path, file.path) == 0 else { throw AppProfileError.unavailable }
        if directorySync {
            let parent = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard parent >= 0 else { throw AppProfileError.unavailable }
            defer { Darwin.close(parent) }
            guard Darwin.fsync(parent) == 0 else { throw AppProfileError.unavailable }
        }
    }
}
