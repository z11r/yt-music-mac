import Foundation

struct AppProfile: Codable, Equatable, Identifiable, Sendable {
    static let defaultID = "default"
    let id: String
    var name: String?
    let createdAt: Date
    var isInitialized: Bool
    var isDefault: Bool { id == Self.defaultID }
    var displayName: String { name ?? AppLocalization.text("Default Profile") }
    static let original = Self(id: defaultID, name: nil, createdAt: Date(timeIntervalSinceReferenceDate: 0), isInitialized: true)

    static func additional(name: String, identifier: UUID = UUID(), now: Date = Date()) throws -> Self {
        let value = Self(id: identifier.uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: now, isInitialized: false)
        try value.validate(); return value
    }
    func validate() throws {
        guard isDefault || (Self.uuid(id) != nil && !Self.reservedWebsiteIDs.contains(id)), createdAt.timeIntervalSinceReferenceDate.isFinite else { throw AppProfileError.invalidRegistry }
        if isDefault && !isInitialized { throw AppProfileError.invalidRegistry }
        if let name {
            guard (1...100).contains(name.count), name.utf8.count <= 400,
                  name == name.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw AppProfileError.invalidName }
        } else if !isDefault { throw AppProfileError.invalidName }
    }
    static func uuid(_ value: String) -> UUID? {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value,
              uuid != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else { return nil }
        return uuid
    }
    private static let reservedWebsiteIDs: Set<String> = [
        "5d12b9c4-c139-4d87-a86a-6137bfcd1d01", "5d12b9c4-c139-4d87-a86a-6137bfcd1d02"
    ]
    private enum CodingKeys: String, CodingKey { case id, name, createdAt, isInitialized }
    init(id: String, name: String?, createdAt: Date, isInitialized: Bool) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.isInitialized = isInitialized
    }
    init(from decoder: any Decoder) throws {
        try ProfileSchema.keys(decoder, ["id", "name", "createdAt", "isInitialized"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        isInitialized = try values.decode(Bool.self, forKey: .isInitialized)
        try validate()
    }
}

struct AppProfileArchive: Codable, Equatable, Sendable {
    static let maximumProfiles = 8
    let version: Int
    var selectedID: String
    var profiles: [AppProfile]
    var deletions: [ProfileDeletionJournal]
    static let original = Self(version: 1, selectedID: AppProfile.defaultID, profiles: [.original])

    func validate() throws {
        guard [1, 2].contains(version) else { throw AppProfileError.unsupportedVersion }
        guard (1...Self.maximumProfiles).contains(profiles.count), Set(profiles.map(\.id)).count == profiles.count,
              profiles.filter(\.isDefault).count == 1, profiles.contains(where: { $0.id == selectedID && $0.isInitialized }) else { throw AppProfileError.invalidRegistry }
        guard deletions.count <= 1, version == 2 || deletions.isEmpty else { throw AppProfileError.invalidRegistry }
        for deletion in deletions {
            try deletion.validate()
            guard deletion.target.id != selectedID, profiles.contains(deletion.target) else { throw AppProfileError.invalidRegistry }
        }
        for profile in profiles { try profile.validate() }
        let names = profiles.compactMap(\.name).map { $0.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        guard Set(names).count == names.count else { throw AppProfileError.duplicateName }
    }
    private enum CodingKeys: String, CodingKey { case version, selectedID, profiles, deletions }
    init(version: Int, selectedID: String, profiles: [AppProfile], deletions: [ProfileDeletionJournal] = []) {
        self.version = version; self.selectedID = selectedID; self.profiles = profiles; self.deletions = deletions
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(selectedID, forKey: .selectedID); try c.encode(profiles, forKey: .profiles)
        if version == 2 { try c.encode(deletions, forKey: .deletions) }
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard [1, 2].contains(version) else { throw AppProfileError.unsupportedVersion }
        try ProfileSchema.keys(decoder, version == 1 ? ["version", "selectedID", "profiles"] : ["version", "selectedID", "profiles", "deletions"])
        if version == 2 {
            var pending = try values.nestedUnkeyedContainer(forKey: .deletions)
            if pending.isAtEnd { deletions = [] }
            else {
                deletions = [try pending.decode(ProfileDeletionJournal.self)]
                guard pending.isAtEnd else { throw AppProfileError.invalidRegistry }
            }
        } else { deletions = [] }
        selectedID = try values.decode(String.self, forKey: .selectedID)
        var items = try values.nestedUnkeyedContainer(forKey: .profiles)
        guard items.count.map({ $0 <= Self.maximumProfiles }) ?? true else { throw AppProfileError.capacityReached }
        var result: [AppProfile] = []
        while !items.isAtEnd {
            guard result.count < Self.maximumProfiles else { throw AppProfileError.capacityReached }
            result.append(try items.decode(AppProfile.self))
        }
        profiles = result; try validate()
    }
}

/// Values only. Resolving a context does not touch preferences, files, WebKit,
/// Keychain or native owners. The factory is the only creator of real adapters.
struct AppProfileContext: Equatable, Sendable {
    let profileID: String
    let namespace: String
    let websiteDataIdentifier: UUID
    let dataDirectory: URL
    var isDefault: Bool { profileID == AppProfile.defaultID }

    init(profile: AppProfile, appIdentifier: String, legacyDirectory: URL, legacyWebsiteDataIdentifier: UUID) throws {
        try profile.validate()
        guard legacyDirectory.isFileURL, !appIdentifier.isEmpty else { throw AppProfileError.unavailable }
        profileID = profile.id
        if profile.isDefault {
            namespace = appIdentifier
            websiteDataIdentifier = legacyWebsiteDataIdentifier
            dataDirectory = legacyDirectory
        } else {
            guard let uuid = AppProfile.uuid(profile.id), uuid != legacyWebsiteDataIdentifier else { throw AppProfileError.invalidRegistry }
            namespace = appIdentifier + ".profiles." + profile.id
            websiteDataIdentifier = uuid
            dataDirectory = legacyDirectory.appendingPathComponent("Profiles", isDirectory: true).appendingPathComponent(profile.id, isDirectory: true)
        }
    }
    var listenBrainzCredentialService: String { namespace + ".listenbrainz" }
    var lastFMCredentialService: String { namespace + ".lastfm" }
}

enum AppProfileError: Error, Equatable, LocalizedError {
    case invalidRegistry, unsupportedVersion, tooLarge, invalidName, duplicateName, capacityReached, stale, busy, unavailable, missingStore
    var errorDescription: String? {
        switch self {
        case .invalidRegistry: AppLocalization.text("The local profile registry could not be read. Its file has been kept.")
        case .unsupportedVersion: AppLocalization.text("This profile registry version is not supported. Its file has been kept.")
        case .tooLarge: AppLocalization.text("The local profile registry exceeds its storage limit.")
        case .invalidName: AppLocalization.text("Use a profile name of 1–100 characters without control characters.")
        case .duplicateName: AppLocalization.text("A local profile already uses this name.")
        case .capacityReached: AppLocalization.text("The local profile limit was reached.")
        case .stale: AppLocalization.text("The local profile registry changed. Reload profiles before continuing.")
        case .busy: AppLocalization.text("Another profile operation is in progress.")
        case .unavailable: AppLocalization.text("This local profile could not be prepared. The current profile remains paused.")
        case .missingStore: AppLocalization.text("This profile's website data store is missing. Its local records have been kept.")
        }
    }
}

enum ProfileSchema {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func keys(_ decoder: any Decoder, _ allowed: Set<String>) throws {
        let values = try decoder.container(keyedBy: Key.self)
        guard Set(values.allKeys.map(\.stringValue)).isSubset(of: allowed) else { throw AppProfileError.invalidRegistry }
    }
}
