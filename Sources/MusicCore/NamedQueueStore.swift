import Foundation

public enum NamedQueueError: Error, Equatable, LocalizedError, Sendable {
    case invalidName, invalidAccount, notFound, tooManyQueues, tooManyEntries
    case unsupportedVersion(Int), invalidArchive

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Use a saved queue name of 1–100 characters without control characters."
        case .invalidAccount: "Sign in to a confirmed account to use saved queues."
        case .notFound: "This saved queue no longer exists. Refresh the list."
        case .tooManyQueues: "The saved queue limit was reached. Delete an unused saved queue first."
        case .tooManyEntries: "This queue has too many entries to save."
        case let .unsupportedVersion(version): "Saved queues version \(version) is not supported."
        case .invalidArchive: "The saved queue collection could not be read. The file has been kept."
        }
    }
}

/// A local metadata snapshot, separate from the current playback queue and service playlists.
public struct NamedQueue: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let updatedAt: Date
    public let snapshot: QueueSnapshot

    public init(id: UUID = UUID(), name: String, createdAt: Date, updatedAt: Date, snapshot: QueueSnapshot) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.snapshot = snapshot
    }
}

/// Stores metadata only, in the namespace of the app's already-confirmed account hash.
/// A missing/invalid/future file is never silently replaced by an edit.
public actor NamedQueueStore {
    public static let currentVersion = 1
    private struct Archive: Codable {
        let version: Int
        var queues: [NamedQueue]
    }

    private let directoryURL: URL
    private let maximumFileSize: Int
    private let maximumQueues: Int
    private let maximumEntries: Int
    private let now: @Sendable () -> Date

    public init(directoryURL: URL, maximumFileSize: Int = 8 * 1024 * 1024,
                maximumQueues: Int = 50, maximumEntries: Int = 10_000,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.directoryURL = directoryURL
        self.maximumFileSize = max(1, maximumFileSize)
        self.maximumQueues = max(1, maximumQueues)
        self.maximumEntries = max(1, maximumEntries)
        self.now = now
    }

    public static func acceptsAccountKey(_ accountKey: String) -> Bool {
        accountKey.utf8.count == 64 && accountKey.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    public func list(accountKey: String) throws -> [NamedQueue] {
        try read(accountKey: accountKey).queues.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
    }

    public func snapshot(id: UUID, accountKey: String) throws -> QueueSnapshot {
        guard let queue = try read(accountKey: accountKey).queues.first(where: { $0.id == id }) else {
            throw NamedQueueError.notFound
        }
        return queue.snapshot
    }

    @discardableResult public func save(name: String, snapshot: QueueSnapshot, accountKey: String) throws -> NamedQueue {
        let name = try Self.validatedName(name)
        try validate(snapshot)
        var archive = try read(accountKey: accountKey)
        guard archive.queues.count < maximumQueues else { throw NamedQueueError.tooManyQueues }
        let date = now()
        let saved = NamedQueue(name: name, createdAt: date, updatedAt: date, snapshot: snapshot)
        archive.queues.append(saved)
        try write(archive, accountKey: accountKey)
        return saved
    }

    public func rename(id: UUID, name: String, accountKey: String) throws {
        let name = try Self.validatedName(name)
        var archive = try read(accountKey: accountKey)
        guard let index = archive.queues.firstIndex(where: { $0.id == id }) else { throw NamedQueueError.notFound }
        let previous = archive.queues[index]
        archive.queues[index] = NamedQueue(id: id, name: name, createdAt: previous.createdAt,
                                         updatedAt: max(previous.createdAt, now()), snapshot: previous.snapshot)
        try write(archive, accountKey: accountKey)
    }

    public func remove(id: UUID, accountKey: String) throws {
        var archive = try read(accountKey: accountKey)
        guard archive.queues.contains(where: { $0.id == id }) else { throw NamedQueueError.notFound }
        archive.queues.removeAll { $0.id == id }
        try write(archive, accountKey: accountKey)
    }

    @discardableResult public func importQueue(from url: URL, accountKey: String) throws -> NamedQueue {
        _ = try fileURL(accountKey: accountKey)
        let imported = try NamedQueueExchange.read(from: url)
        return try save(name: imported.name, snapshot: imported.snapshot, accountKey: accountKey)
    }

    public func exportQueue(id: UUID, to url: URL, accountKey: String) throws {
        let archive = try read(accountKey: accountKey)
        guard let queue = archive.queues.first(where: { $0.id == id }) else { throw NamedQueueError.notFound }
        let root = directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        let destination = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard destination != root, !destination.hasPrefix(root + "/") else {
            throw NamedQueueExchangeError.protectedDestination
        }
        try NamedQueueExchange.write(name: queue.name, snapshot: queue.snapshot, to: url)
    }

    private static func validatedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(name.count),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw NamedQueueError.invalidName
        }
        return name
    }

    private func fileURL(accountKey: String) throws -> URL {
        guard directoryURL.isFileURL else { throw QueuePersistenceError.invalidStorageURL }
        guard Self.acceptsAccountKey(accountKey) else { throw NamedQueueError.invalidAccount }
        return directoryURL.appendingPathComponent(accountKey, isDirectory: true).appendingPathComponent("queues.json")
    }

    private func read(accountKey: String) throws -> Archive {
        let url = try fileURL(accountKey: accountKey)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber, size.intValue > maximumFileSize {
                throw QueuePersistenceError.fileTooLarge
            }
            let data = try Data(contentsOf: url)
            guard data.count <= maximumFileSize else { throw QueuePersistenceError.fileTooLarge }
            let archive: Archive
            do { archive = try JSONDecoder().decode(Archive.self, from: data) }
            catch { throw NamedQueueError.invalidArchive }
            try validate(archive)
            return archive
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                    (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return Archive(version: Self.currentVersion, queues: [])
        }
    }

    private func validate(_ snapshot: QueueSnapshot) throws {
        try snapshot.validate()
        guard snapshot.entries.count <= maximumEntries else { throw NamedQueueError.tooManyEntries }
    }

    private func validate(_ archive: Archive) throws {
        guard archive.version == Self.currentVersion else { throw NamedQueueError.unsupportedVersion(archive.version) }
        guard archive.queues.count <= maximumQueues else { throw NamedQueueError.tooManyQueues }
        guard Set(archive.queues.map(\.id)).count == archive.queues.count else { throw NamedQueueError.invalidArchive }
        for queue in archive.queues {
            guard try Self.validatedName(queue.name) == queue.name,
                  queue.createdAt.timeIntervalSince1970.isFinite, queue.updatedAt.timeIntervalSince1970.isFinite,
                  queue.updatedAt >= queue.createdAt else { throw NamedQueueError.invalidArchive }
            try validate(queue.snapshot)
        }
    }

    private func write(_ archive: Archive, accountKey: String) throws {
        try Task.checkCancellation()
        try validate(archive)
        let url = try fileURL(accountKey: accountKey)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= maximumFileSize else { throw QueuePersistenceError.fileTooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
