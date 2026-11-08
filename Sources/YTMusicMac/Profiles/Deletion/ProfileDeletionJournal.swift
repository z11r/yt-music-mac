import Foundation

enum ProfileCleanupStep: String, Codable, CaseIterable, Sendable {
    case website, spotlight, credentials, preferences, directory
    var index: Int { Self.allCases.firstIndex(of: self)! }
    var title: String {
        switch self {
        case .website: AppLocalization.text("Website Sign-In and Data")
        case .spotlight: AppLocalization.text("Profile's Named Spotlight Index")
        case .credentials: AppLocalization.text("Last.fm and ListenBrainz Credentials")
        case .preferences: AppLocalization.text("Profile Settings")
        case .directory: AppLocalization.text("Profile Data Folder")
        }
    }
}
enum ProfileCleanupState: String, Codable, Sendable { case pending, running, complete, uncertain }
enum ProfileCleanupProblem: String, Error, Codable, Sendable {
    case protectedProfile, stale, busy, otherInstance, releaseRequired, savedData, unknownPreferences, credentialsUnavailable, unsafePath, uncertainIndex, unavailable
    var message: String {
        switch self {
        case .protectedProfile: AppLocalization.text("The default, current and saved-selected profiles cannot be deleted.")
        case .stale: AppLocalization.text("The profile or account changed. Review deletion again.")
        case .busy: AppLocalization.text("Finish the pending profile operation first.")
        case .otherInstance: AppLocalization.text("Close other copies of this app before reviewing cleanup.")
        case .releaseRequired: AppLocalization.text("This profile's website store may still be retained. Relaunch the app before reviewing cleanup.")
        case .savedData: AppLocalization.text("Unrecognized, changed, or unresolved saved data is retained. Review the supported formats before trying cleanup again.")
        case .unknownPreferences: AppLocalization.text("Unrecognized or versioned settings are retained pending supported cleanup.")
        case .credentialsUnavailable: AppLocalization.text("Provider credentials could not be safely inspected without interaction. They have been retained.")
        case .unsafePath: AppLocalization.text("The profile folder or lock path is not a verified directory. Nothing outside the profile will be removed.")
        case .uncertainIndex: AppLocalization.text("The prior Spotlight cleanup result cannot be verified. Deletion remains pending.")
        case .unavailable: AppLocalization.text("Cleanup was not confirmed. Review the pending deletion before continuing.")
        }
    }
}
struct ProfileDeletionJournal: Codable, Equatable, Identifiable, Sendable {
    let version: Int
    let id: UUID
    let target: AppProfile
    let createdAt: Date
    var states: [ProfileCleanupState]
    var problem: ProfileCleanupProblem?
    var metadata: ProfileMetadataManifest?
    init(target: AppProfile, id: UUID = UUID(), now: Date = Date()) {
        version = 1; metadata = nil; self.id = id; self.target = target; createdAt = now
        states = Array(repeating: .pending, count: ProfileCleanupStep.allCases.count)
    }
    func validate() throws {
        try target.validate()
        guard [1, 2].contains(version), (version == 2) == (metadata != nil), !target.isDefault, states.count == ProfileCleanupStep.allCases.count,
              id != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)), createdAt.timeIntervalSinceReferenceDate.isFinite else { throw AppProfileError.invalidRegistry }
        try metadata?.validate()
    }
    private enum CodingKeys: String, CodingKey { case version, id, target, createdAt, states, problem, metadata }
    func withMetadata(_ value: ProfileMetadataManifest) -> Self {
        Self(version: 2, id: id, target: target, createdAt: createdAt, states: states, problem: problem, metadata: value)
    }
    private init(version: Int, id: UUID, target: AppProfile, createdAt: Date, states: [ProfileCleanupState], problem: ProfileCleanupProblem?, metadata: ProfileMetadataManifest?) {
        self.version = version; self.id = id; self.target = target; self.createdAt = createdAt
        self.states = states; self.problem = problem; self.metadata = metadata
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard [1, 2].contains(version) else { throw AppProfileError.invalidRegistry }
        try ProfileSchema.keys(decoder, Set(["version", "id", "target", "createdAt", "states", "problem"] + (version == 2 ? ["metadata"] : [])))
        id = try c.decode(UUID.self, forKey: .id)
        target = try c.decode(AppProfile.self, forKey: .target); createdAt = try c.decode(Date.self, forKey: .createdAt)
        var items = try c.nestedUnkeyedContainer(forKey: .states); var result: [ProfileCleanupState] = []
        while !items.isAtEnd {
            guard result.count < ProfileCleanupStep.allCases.count else { throw AppProfileError.invalidRegistry }
            result.append(try items.decode(ProfileCleanupState.self))
        }
        states = result; problem = try c.decodeIfPresent(ProfileCleanupProblem.self, forKey: .problem)
        metadata = try c.decodeIfPresent(ProfileMetadataManifest.self, forKey: .metadata)
        try validate()
    }
}
enum ProfileCleanupProbe: Equatable, Sendable {
    case absent, ready, confirmed, blocked(ProfileCleanupProblem)
    var problem: ProfileCleanupProblem? { if case let .blocked(value) = self { value } else { nil } }
}
@MainActor protocol ProfileCleanupSession: AnyObject {
    func probe(_ step: ProfileCleanupStep, state: ProfileCleanupState) async -> ProfileCleanupProbe
    func remove(_ step: ProfileCleanupStep) async throws
    func close()
}
@MainActor protocol ProfileCleanupPreparing {
    func prepare(_ target: AppProfile) async throws -> any ProfileCleanupSession
}
struct ProfileDeletionReview: Identifiable {
    let id = UUID()
    let snapshot: AppProfileRegistrySnapshot
    let target: AppProfile
    let probes: [ProfileCleanupProbe]
    var metadata: ProfileMetadataManifest? = nil
    var problem: ProfileCleanupProblem? { probes.compactMap(\.problem).first }
}
