import Foundation

public enum EpisodeCompletionSource: String, Codable, Equatable, Sendable { case manual }

public struct EpisodeProgressRecord: Codable, Equatable, Sendable {
    public let episode: EpisodeIdentity
    public let position: TimeInterval
    public let duration: TimeInterval
    public let completed: Bool
    public let updatedAt: Date
    /// A manual completion is a local status choice, not measured listening.
    public let completionSource: EpisodeCompletionSource?
    public init(episode: EpisodeIdentity, position: TimeInterval, duration: TimeInterval, completed: Bool, updatedAt: Date,
                completionSource: EpisodeCompletionSource? = nil) {
        self.episode = episode; self.position = position; self.duration = duration; self.completed = completed; self.updatedAt = updatedAt
        self.completionSource = completionSource
    }
}

public struct EpisodePlaybackSettings: Codable, Equatable, Sendable {
    public var skipBackward: TimeInterval
    public var skipForward: TimeInterval
    public init(skipBackward: TimeInterval = 10, skipForward: TimeInterval = 30) {
        self.skipBackward = skipBackward; self.skipForward = skipForward
    }
}

public struct EpisodeProgressSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let accountHash: String
    public let records: [EpisodeProgressRecord]
    public let settings: EpisodePlaybackSettings
    public init(version: Int = 1, accountHash: String, records: [EpisodeProgressRecord], settings: EpisodePlaybackSettings = .init()) {
        self.version = version; self.accountHash = accountHash; self.records = records; self.settings = settings
    }

    public func validate() throws {
        guard version == 1 else { throw EpisodeProgressError.unsupportedVersion }
        guard Self.validAccountHash(accountHash), records.count <= 2_000,
              Set(records.map { $0.episode.key }).count == records.count,
              [settings.skipBackward, settings.skipForward].allSatisfy({ $0.isFinite && (5...120).contains($0) }),
              records.allSatisfy({ record in
                Self.validEpisode(record.episode) && record.position.isFinite &&
                (record.position > 0 || record.position == 0 && record.completed && record.completionSource == .manual) &&
                (record.completionSource != .manual || record.completed) &&
                record.duration.isFinite && record.duration > 0 && record.position <= record.duration + 2 &&
                record.updatedAt.timeIntervalSince1970.isFinite
              }) else { throw EpisodeProgressError.invalidSnapshot }
    }

    public static func validAccountHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func validEpisode(_ value: EpisodeIdentity) -> Bool {
        func valid(_ id: String) -> Bool { id.utf8.count <= 256 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } }
        return value.browseID.hasPrefix("MPED") && value.browseID.count > 4 && valid(value.browseID) &&
            (value.showBrowseID.map { $0.hasPrefix("MPSP") && $0.count > 4 && valid($0) } ?? true)
    }
}

public enum EpisodeProgressError: Error, Equatable, Sendable {
    case invalidStorageURL, fileTooLarge, unsupportedVersion, invalidSnapshot
}

/// Local listening bookmarks only. No service history or progress is written.
public actor EpisodeProgressStore {
    private let directory: URL
    private let maximumFileSize: Int
    public init(directory: URL, maximumFileSize: Int = 1_048_576) {
        self.directory = directory; self.maximumFileSize = min(1_048_576, max(1, maximumFileSize))
    }

    public func load(accountHash: String) throws -> EpisodeProgressSnapshot? {
        let url = try fileURL(accountHash)
        do {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard (size?.intValue ?? maximumFileSize + 1) <= maximumFileSize else { throw EpisodeProgressError.fileTooLarge }
            let data = try Data(contentsOf: url)
            guard data.count <= maximumFileSize else { throw EpisodeProgressError.fileTooLarge }
            let snapshot = try JSONDecoder().decode(EpisodeProgressSnapshot.self, from: data)
            try snapshot.validate()
            guard snapshot.accountHash == accountHash else { throw EpisodeProgressError.invalidSnapshot }
            return snapshot
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
    }

    public func save(_ snapshot: EpisodeProgressSnapshot, if permitted: @Sendable () -> Bool = { true }) throws {
        guard permitted() else { throw CancellationError() }
        let url = try fileURL(snapshot.accountHash)
        try snapshot.validate()
        if let current = try load(accountHash: snapshot.accountHash), current.version != 1 { throw EpisodeProgressError.unsupportedVersion }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumFileSize else { throw EpisodeProgressError.fileTooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard permitted() else { throw CancellationError() }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear(accountHash: String) throws {
        let url = try fileURL(accountHash)
        do { try FileManager.default.removeItem(at: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { }
    }

    private func fileURL(_ accountHash: String) throws -> URL {
        guard directory.isFileURL else { throw EpisodeProgressError.invalidStorageURL }
        guard EpisodeProgressSnapshot.validAccountHash(accountHash) else { throw EpisodeProgressError.invalidSnapshot }
        return directory.appendingPathComponent(accountHash + ".json")
    }
}
