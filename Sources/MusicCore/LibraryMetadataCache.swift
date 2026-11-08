import Foundation

public struct LibraryMetadataSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let capturedAt: Date
    public let collections: [LocalCollectionReference]
    public let isTruncated: Bool

    public init(capturedAt: Date, collections: [LocalCollectionReference], isTruncated: Bool = false) {
        version = Self.currentVersion
        self.capturedAt = capturedAt
        self.collections = collections
        self.isTruncated = isTruncated
    }
}

public enum LibraryMetadataCacheError: Error, Equatable, LocalizedError, Sendable {
    case invalidArchive, fileTooLarge, invalidMetadata, superseded, unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidArchive: CoreLocalization.text("The library metadata cache could not be read. Its file has been kept.")
        case .fileTooLarge: CoreLocalization.text("The library metadata cache exceeds its storage limit.")
        case .invalidMetadata: CoreLocalization.text("This library metadata could not be cached. The previous snapshot has been kept.")
        case .superseded: CoreLocalization.text("A newer library snapshot or cache-clear request replaced this operation.")
        case let .unsupportedVersion(value): CoreLocalization.format("Library metadata cache version %lld is not supported. Its file has been kept.", value)
        }
    }
}

public struct LibraryMetadataWriteToken: Sendable {
    fileprivate let generation: UUID
    fileprivate let sequence: UInt64
    fileprivate let accountKey: String
}

/// Account-specific, read-only library collection metadata. Contains no URLs, service parameters or audio.
public actor LibraryMetadataCache {
    public static let byteLimit = 2 * 1024 * 1024
    public static let collectionLimit = 2_000
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    private let directoryURL: URL
    private let maximumBytes: Int
    private let maximumCollections: Int
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date
    private var generation = UUID()
    private var sequence: UInt64 = 0
    private var lastWritten: UInt64 = 0

    public init(directoryURL: URL, maximumBytes: Int = byteLimit, maximumCollections: Int = collectionLimit,
                lifetime: TimeInterval = LibraryMetadataCache.lifetime,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.directoryURL = directoryURL
        self.maximumBytes = min(Self.byteLimit, max(1, maximumBytes))
        self.maximumCollections = min(Self.collectionLimit, max(1, maximumCollections))
        self.lifetime = lifetime.isFinite ? min(Self.lifetime, max(0, lifetime)) : Self.lifetime
        self.now = now
    }

    public func load(accountKey: String) throws -> LibraryMetadataSnapshot? {
        guard let snapshot = try read(accountKey: accountKey) else { return nil }
        let age = now().timeIntervalSince(snapshot.capturedAt)
        // An implausible future date must not be presented as a current offline snapshot.
        guard age.isFinite, age >= -300 else { throw LibraryMetadataCacheError.invalidArchive }
        return age < lifetime ? snapshot : nil
    }

    public func beginWrite(accountKey: String) throws -> LibraryMetadataWriteToken {
        _ = try fileURL(accountKey)
        sequence &+= 1
        return LibraryMetadataWriteToken(generation: generation, sequence: sequence, accountKey: accountKey)
    }

    @discardableResult public func save(collections: [LocalCollectionReference], accountKey: String,
                                       token: LibraryMetadataWriteToken? = nil) throws -> LibraryMetadataSnapshot {
        let token = try token ?? beginWrite(accountKey: accountKey)
        guard token.generation == generation, token.accountKey == accountKey, token.sequence > lastWritten else { throw LibraryMetadataCacheError.superseded }
        // Validate an existing file before replacing it, including expired files.
        _ = try read(accountKey: accountKey)
        var seen = Set<String>()
        var limited: [LocalCollectionReference] = []
        var truncated = false
        for collection in collections where seen.insert(collection.id).inserted {
            if limited.count == maximumCollections { truncated = true; break }
            limited.append(collection)
        }
        let snapshot = LibraryMetadataSnapshot(capturedAt: now(), collections: limited, isTruncated: truncated)
        try validate(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumBytes else { throw LibraryMetadataCacheError.fileTooLarge }
        let url = try fileURL(accountKey)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lastWritten = token.sequence
        return snapshot
    }

    public func storedBytes(accountKey: String) throws -> Int {
        let url = try fileURL(accountKey)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else { throw LibraryMetadataCacheError.invalidArchive }
            return max(0, size.intValue)
        } catch let error as NSError where Self.isMissing(error) { return 0 }
    }

    /// Explicit clearing only addresses this cache file in the confirmed account namespace.
    public func clear(accountKey: String) throws {
        let url = try fileURL(accountKey)
        generation = UUID()
        lastWritten = 0
        try Task.checkCancellation()
        do { try FileManager.default.removeItem(at: url) }
        catch let error as NSError where Self.isMissing(error) { }
    }

    private func read(accountKey: String) throws -> LibraryMetadataSnapshot? {
        let url = try fileURL(accountKey)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LibraryMetadataCacheError.invalidArchive }
            if let size = attributes[.size] as? NSNumber, size.intValue > maximumBytes { throw LibraryMetadataCacheError.fileTooLarge }
            guard let stream = InputStream(url: url) else { throw LibraryMetadataCacheError.invalidArchive }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                try Task.checkCancellation()
                let count = stream.read(&buffer, maxLength: min(buffer.count, maximumBytes + 1 - data.count))
                guard count >= 0 else { throw LibraryMetadataCacheError.invalidArchive }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= maximumBytes else { throw LibraryMetadataCacheError.fileTooLarge }
            }
            let archive: Archive
            do { archive = try JSONDecoder().decode(Archive.self, from: data) }
            catch let error as LibraryMetadataCacheError { throw error }
            catch { throw LibraryMetadataCacheError.invalidArchive }
            try validate(archive.snapshot)
            guard archive.snapshot.collections.count <= maximumCollections else { throw LibraryMetadataCacheError.invalidArchive }
            return archive.snapshot
        } catch let error as NSError where Self.isMissing(error) { return nil }
    }

    private struct Archive: Decodable {
        let snapshot: LibraryMetadataSnapshot
        private enum CodingKeys: String, CodingKey, CaseIterable { case version, capturedAt, collections, isTruncated }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let version = try values.decode(Int.self, forKey: .version)
            guard version == LibraryMetadataSnapshot.currentVersion else { throw LibraryMetadataCacheError.unsupportedVersion(version) }
            let raw = try decoder.container(keyedBy: LocalCollectionArchiveKey.self)
            guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else { throw LibraryMetadataCacheError.invalidArchive }
            var valuesArray = try values.nestedUnkeyedContainer(forKey: .collections)
            guard valuesArray.count.map({ $0 <= LibraryMetadataCache.collectionLimit }) ?? true else { throw LibraryMetadataCacheError.invalidArchive }
            var collections: [LocalCollectionReference] = []
            while !valuesArray.isAtEnd {
                guard collections.count < LibraryMetadataCache.collectionLimit else { throw LibraryMetadataCacheError.invalidArchive }
                collections.append(try valuesArray.decode(LocalCollectionReference.self))
            }
            snapshot = LibraryMetadataSnapshot(capturedAt: try values.decode(Date.self, forKey: .capturedAt),
                                               collections: collections, isTruncated: try values.decode(Bool.self, forKey: .isTruncated))
        }
    }

    private func validate(_ snapshot: LibraryMetadataSnapshot) throws {
        guard snapshot.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              Set(snapshot.collections.map(\.id)).count == snapshot.collections.count else { throw LibraryMetadataCacheError.invalidMetadata }
        for value in snapshot.collections {
            guard !value.serviceID.isEmpty, value.serviceID.utf8.count <= 256,
                  value.serviceID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
                  !value.title.isEmpty, value.title.utf8.count <= 4_096,
                  !value.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw LibraryMetadataCacheError.invalidMetadata }
        }
    }

    private func fileURL(_ key: String) throws -> URL {
        guard directoryURL.isFileURL else { throw QueuePersistenceError.invalidStorageURL }
        guard NamedQueueStore.acceptsAccountKey(key) else { throw NamedQueueError.invalidAccount }
        return directoryURL.appendingPathComponent(key).appendingPathComponent("library.json")
    }
    private static func isMissing(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
    }
}
