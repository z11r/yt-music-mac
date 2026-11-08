import Foundation

/// Portable within one local profile, without a filename, URL, bookmark, or service identifier.
public struct LocalAudioReference: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public let libraryID: UUID
    public let fileID: UUID
    public var trackID: String { "local:" + fileID.uuidString.lowercased() }
    public static func isReservedTrackID(_ value: String) -> Bool { String(value.prefix(6)).lowercased() == "local:" }

    public init(libraryID: UUID, fileID: UUID) {
        self.libraryID = libraryID
        self.fileID = fileID
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case version, libraryID, fileID }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.container(keyedBy: LocalAudioCodingKey.self)
        guard Set(raw.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw LocalAudioLibraryError.invalidReference
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw LocalAudioLibraryError.unsupportedReferenceVersion(version) }
        func identifier(_ key: CodingKeys) throws -> UUID {
            let text = try values.decode(String.self, forKey: key)
            guard text.utf8.count == 36, text.unicodeScalars.allSatisfy(\.isASCII),
                  let id = UUID(uuidString: text), id.uuidString.lowercased() == text.lowercased() else {
                throw LocalAudioLibraryError.invalidReference
            }
            return id
        }
        libraryID = try identifier(.libraryID)
        fileID = try identifier(.fileID)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentVersion, forKey: .version)
        try values.encode(libraryID, forKey: .libraryID)
        try values.encode(fileID, forKey: .fileID)
    }
}

public extension Track {
    /// The reserved namespace also fences damaged or older round-tripped local metadata.
    var hasLocalAudioSource: Bool {
        origin == .localFile || localAudioReference != nil || LocalAudioReference.isReservedTrackID(id)
    }
    /// Includes catalog, uploaded music and service podcast episodes, but never local files.
    var isServiceTrack: Bool { !hasLocalAudioSource }
    var isCatalogTrack: Bool { isServiceTrack && origin != .upload }
    /// Older service responses can omit kind and origin. They remain eligible for existing actions.
    var isCatalogSong: Bool { isCatalogTrack && contentKind != .podcastEpisode && episode == nil }
    var isExplicitCatalogSong: Bool { isCatalogSong && contentKind == .song }
    var remoteArtworkURL: URL? { isServiceTrack ? artworkURL : nil }
    var remoteArtworkVideoID: String? { isServiceTrack ? id : nil }

    func validateLocalAudioSource() throws {
        guard hasLocalAudioSource else { return }
        guard origin == .localFile, let reference = localAudioReference, id == reference.trackID,
              artworkURL == nil, albumReference == nil, (artistReferences ?? []).isEmpty,
              creditsReference == nil, episode == nil, contentKind != .podcastEpisode else {
            throw LocalAudioLibraryError.invalidReference
        }
    }
}

struct LocalAudioCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
