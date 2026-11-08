import Foundation

public enum ProtectedStorageInventoryError: Error, LocalizedError, Sendable {
    case unsupportedFile
    public var errorDescription: String? { CoreLocalization.text("A saved-data path is not a regular file. Its contents have been kept.") }
}

public struct ProtectedStorageUsage: Equatable, Sendable {
    public let localAudioBytes: Int
    public let currentQueueBytes: Int
    public let namedQueueBytes: Int
    public let organizationBytes: Int
    public let songRuleBytes: Int
    public let episodeProgressBytes: Int
    public let listenBrainzBytes: Int
    public let lastFMBytes: Int
    public let pendingPlaylistBytes: Int
}

/// Measures fixed metadata files only. It has no deletion operation or access to session storage.
public actor ProtectedStorageInventory {
    private let directoryURL: URL
    public init(directoryURL: URL) { self.directoryURL = directoryURL }
    public func measure(accountKey: String) throws -> ProtectedStorageUsage {
        guard directoryURL.isFileURL else { throw QueuePersistenceError.invalidStorageURL }
        guard NamedQueueStore.acceptsAccountKey(accountKey) else { throw NamedQueueError.invalidAccount }
        return try ProtectedStorageUsage(localAudioBytes: size(["LocalAudio", "library.json"]),
            currentQueueBytes: size(["queue.json"]),
            namedQueueBytes: size(["SavedQueues", accountKey, "queues.json"]),
            organizationBytes: size(["LocalCollections", accountKey, "organization.json"]),
            songRuleBytes: size(["LocalSongRules", accountKey, "song-rules.json"]),
            episodeProgressBytes: size(["episode-progress", accountKey + ".json"]),
            listenBrainzBytes: size(["listenbrainz", accountKey + ".json"]),
            lastFMBytes: size(["lastfm", accountKey + ".json"]),
            pendingPlaylistBytes: size(["PendingQueuePlaylists", accountKey, "pending.json"]))
    }
    private func size(_ components: [String]) throws -> Int {
        let url = components.reduce(directoryURL) { $0.appendingPathComponent($1) }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ProtectedStorageInventoryError.unsupportedFile }
            return max(0, (attributes[.size] as? NSNumber)?.intValue ?? 0)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return 0 }
    }
}
