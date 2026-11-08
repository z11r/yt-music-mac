import Foundation

public enum LocalAudioLibraryError: Error, Equatable, Sendable {
    case invalidReference, invalidLibrary, wrongProfile, wrongLibrary, missingFile, staleRevision
    case invalidMetadata, invalidBookmark, capacityReached, fileTooLarge, invalidStorageURL
    case unsupportedVersion(Int), unsupportedReferenceVersion(Int)
}

public enum LocalAudioBookmarkMode: String, Codable, Sendable {
    /// The current unsandboxed build: bookmark tracking never substitutes for actual file permission.
    case ordinary
    /// Only for an explicitly entitled sandboxed build; failure never falls back to ordinary access.
    case securityScopedReadOnly
}

public struct LocalAudioBookmark: Codable, Equatable, Sendable {
    public static let maximumBytes = 64 * 1024
    public let mode: LocalAudioBookmarkMode
    public let data: Data
    public init(mode: LocalAudioBookmarkMode, data: Data) { self.mode = mode; self.data = data }
    public func validate() throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw LocalAudioLibraryError.invalidBookmark }
    }
}

/// Stable volume and file identity, independent of the bookmark's current location.
public struct LocalAudioFileIdentity: Codable, Equatable, Sendable {
    public let volumeID: String
    public let fileID: UInt64
    public init(volumeID: String, fileID: UInt64) { self.volumeID = volumeID; self.fileID = fileID }
    public func validate() throws {
        guard !volumeID.isEmpty, volumeID.utf8.count <= 128, fileID > 0,
              !volumeID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LocalAudioLibraryError.invalidMetadata
        }
    }
}

public struct LocalAudioMetadata: Codable, Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String?
    public let duration: TimeInterval
    public let byteCount: Int64
    public init(title: String, artist: String, album: String? = nil, duration: TimeInterval, byteCount: Int64) {
        self.title = title; self.artist = artist; self.album = album; self.duration = duration; self.byteCount = byteCount
    }
    public func validate() throws {
        func text(_ value: String, empty: Bool) -> Bool {
            (empty || !value.isEmpty) && value.utf8.count <= 1_024 &&
                !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        guard text(title, empty: false), text(artist, empty: true), album.map({ text($0, empty: true) }) ?? true,
              duration.isFinite, (0.001...604_800).contains(duration), byteCount > 0 else {
            throw LocalAudioLibraryError.invalidMetadata
        }
    }
    public func track(reference: LocalAudioReference) throws -> Track {
        try validate()
        return Track(id: reference.trackID, title: title, artist: artist, album: album, duration: duration,
                     origin: .localFile, contentKind: .song, localAudioReference: reference)
    }
}

public struct LocalAudioLibraryRecord: Codable, Equatable, Identifiable, Sendable {
    public let reference: LocalAudioReference
    public let metadata: LocalAudioMetadata
    public let identity: LocalAudioFileIdentity
    public let bookmark: LocalAudioBookmark
    public var id: UUID { reference.fileID }
    public init(reference: LocalAudioReference, metadata: LocalAudioMetadata,
                identity: LocalAudioFileIdentity, bookmark: LocalAudioBookmark) {
        self.reference = reference; self.metadata = metadata; self.identity = identity; self.bookmark = bookmark
    }
    public func validate() throws {
        try metadata.validate(); try identity.validate(); try bookmark.validate()
    }
}

/// One profile's private file grants. This archive is never a queue exchange or drag payload.
public struct LocalAudioLibraryDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumRecords = 2_000
    public let version: Int
    public let profileID: UUID
    public let libraryID: UUID
    public let revision: UUID
    public let records: [LocalAudioLibraryRecord]
    public init(version: Int = currentVersion, profileID: UUID, libraryID: UUID, revision: UUID = UUID(),
                records: [LocalAudioLibraryRecord] = []) {
        self.version = version; self.profileID = profileID; self.libraryID = libraryID
        self.revision = revision; self.records = records
    }
    public func validate() throws {
        guard version == Self.currentVersion else { throw LocalAudioLibraryError.unsupportedVersion(version) }
        guard records.count <= Self.maximumRecords else { throw LocalAudioLibraryError.capacityReached }
        guard Set(records.map(\.id)).count == records.count else { throw LocalAudioLibraryError.invalidLibrary }
        for record in records {
            guard record.reference.libraryID == libraryID else { throw LocalAudioLibraryError.wrongLibrary }
            try record.validate()
        }
    }
    public func record(for reference: LocalAudioReference) throws -> LocalAudioLibraryRecord {
        guard reference.libraryID == libraryID else { throw LocalAudioLibraryError.wrongLibrary }
        guard let record = records.first(where: { $0.reference == reference }) else { throw LocalAudioLibraryError.missingFile }
        return record
    }

    private enum CodingKeys: String, CodingKey { case version, profileID, libraryID, revision, records }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw LocalAudioLibraryError.unsupportedVersion(version) }
        profileID = try values.decode(UUID.self, forKey: .profileID)
        libraryID = try values.decode(UUID.self, forKey: .libraryID)
        revision = try values.decode(UUID.self, forKey: .revision)
        var source = try values.nestedUnkeyedContainer(forKey: .records)
        guard source.count.map({ $0 <= Self.maximumRecords }) ?? true else { throw LocalAudioLibraryError.capacityReached }
        var parsed: [LocalAudioLibraryRecord] = []
        while !source.isAtEnd {
            guard parsed.count < Self.maximumRecords else { throw LocalAudioLibraryError.capacityReached }
            parsed.append(try source.decode(LocalAudioLibraryRecord.self))
        }
        records = parsed
        try validate()
    }
}
