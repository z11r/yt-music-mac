import Foundation

public enum QueuePersistenceError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case invalidQueue(String)
    case fileTooLarge
    case invalidStorageURL

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version): CoreLocalization.format("Saved queue version %lld is not supported.", version)
        case let .invalidQueue(reason): CoreLocalization.format("The saved queue is invalid: %@.", Self.localizedReason(reason))
        case .fileTooLarge: CoreLocalization.text("The saved queue exceeds the storage limit.")
        case .invalidStorageURL: CoreLocalization.text("The queue store requires a local file URL.")
        }
    }

    private static func localizedReason(_ reason: String) -> String {
        switch reason {
        case "duplicate entry identifiers": CoreLocalization.text("duplicate entry identifiers")
        case "missing track identifier": CoreLocalization.text("missing track identifier")
        case "selection is missing from the queue": CoreLocalization.text("selection is missing from the queue")
        case "shuffle order does not match the queue": CoreLocalization.text("shuffle order does not match the queue")
        case "unshuffled entries are out of order": CoreLocalization.text("unshuffled entries are out of order")
        case "invalid playback position": CoreLocalization.text("invalid playback position")
        case "invalid track duration": CoreLocalization.text("invalid track duration")
        default: reason
        }
    }
}

public struct QueueSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let entries: [QueueEntry]
    public let currentEntryID: UUID?
    public let repeatMode: RepeatMode
    public let isShuffled: Bool
    public let unshuffledOrder: [UUID]
    public let resumePosition: TimeInterval

    public init(
        version: Int = QueueSnapshot.currentVersion,
        entries: [QueueEntry],
        currentEntryID: UUID? = nil,
        repeatMode: RepeatMode = .off,
        isShuffled: Bool = false,
        unshuffledOrder: [UUID]? = nil,
        resumePosition: TimeInterval = 0
    ) {
        self.version = version
        self.entries = entries
        self.currentEntryID = currentEntryID
        self.repeatMode = repeatMode
        self.isShuffled = isShuffled
        self.unshuffledOrder = unshuffledOrder ?? entries.map(\.id)
        self.resumePosition = resumePosition
    }

    public func validate() throws {
        guard self.version == Self.currentVersion else {
            throw QueuePersistenceError.unsupportedVersion(self.version)
        }
        let ids = Set(self.entries.map(\.id))
        guard ids.count == self.entries.count else {
            throw QueuePersistenceError.invalidQueue("duplicate entry identifiers")
        }
        guard self.entries.allSatisfy({ !$0.track.id.isEmpty }) else {
            throw QueuePersistenceError.invalidQueue("missing track identifier")
        }
        if let currentEntryID, !ids.contains(currentEntryID) {
            throw QueuePersistenceError.invalidQueue("selection is missing from the queue")
        }
        guard Set(self.unshuffledOrder) == ids, self.unshuffledOrder.count == ids.count else {
            throw QueuePersistenceError.invalidQueue("shuffle order does not match the queue")
        }
        if !self.isShuffled, self.unshuffledOrder != self.entries.map(\.id) {
            throw QueuePersistenceError.invalidQueue("unshuffled entries are out of order")
        }
        guard self.resumePosition.isFinite, self.resumePosition >= 0 else {
            throw QueuePersistenceError.invalidQueue("invalid playback position")
        }
        guard self.entries.allSatisfy({ entry in
            entry.track.duration.map { $0.isFinite && $0 >= 0 } ?? true
        }) else {
            throw QueuePersistenceError.invalidQueue("invalid track duration")
        }
    }
}

public actor QueueStore {
    private let fileURL: URL
    private let maximumFileSize: Int

    public init(fileURL: URL, maximumFileSize: Int = 4 * 1024 * 1024) {
        self.fileURL = fileURL
        self.maximumFileSize = max(1, maximumFileSize)
    }

    public func load() throws -> QueueSnapshot? {
        try self.checkURL()
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: self.fileURL.path)
            if let size = attributes[.size] as? NSNumber, size.intValue > self.maximumFileSize {
                throw QueuePersistenceError.fileTooLarge
            }
            let data = try Data(contentsOf: self.fileURL)
            guard data.count <= self.maximumFileSize else { throw QueuePersistenceError.fileTooLarge }
            let snapshot = try JSONDecoder().decode(QueueSnapshot.self, from: data)
            try snapshot.validate()
            return snapshot
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return nil
        }
    }

    public func save(_ snapshot: QueueSnapshot) throws {
        try self.checkURL()
        try snapshot.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= self.maximumFileSize else { throw QueuePersistenceError.fileTooLarge }
        try FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: self.fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.fileURL.path)
    }

    public func clear() throws {
        try self.checkURL()
        do {
            try FileManager.default.removeItem(at: self.fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return
        }
    }

    private func checkURL() throws {
        guard self.fileURL.isFileURL else { throw QueuePersistenceError.invalidStorageURL }
    }
}
