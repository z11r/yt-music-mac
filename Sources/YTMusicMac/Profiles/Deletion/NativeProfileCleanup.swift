import AppKit
import CoreSpotlight
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import WebKit

@MainActor struct NativeProfileCleanup: ProfileCleanupPreparing {
    let root: URL
    let onlyInstance: @MainActor () -> Bool
    init(root: URL, onlyInstance: @escaping @MainActor () -> Bool = NativeProfileCleanup.isOnlyInstance) { self.root = root; self.onlyInstance = onlyInstance }
    static func isOnlyInstance() -> Bool {
        guard Bundle.main.bundleIdentifier == AppIdentity.identifier else { return false }
        guard let executable = Bundle.main.executableURL?.lastPathComponent else { return false }
        let inventory = NSWorkspace.shared.runningApplications.map {
            ProfileProcessEntry(pid: $0.processIdentifier, bundle: $0.bundleIdentifier, executable: $0.executableURL?.lastPathComponent)
        }
        return ProfileProcessAdmission.allows(inventory, ownPID: ProcessInfo.processInfo.processIdentifier,
            bundle: AppIdentity.identifier, executable: executable)
    }
    func prepare(_ target: AppProfile) async throws -> any ProfileCleanupSession {
        guard !target.isDefault, onlyInstance() else { throw ProfileCleanupProblem.otherInstance }
        let context = try AppProfileContext(profile: target, appIdentifier: AppIdentity.identifier,
            legacyDirectory: root, legacyWebsiteDataIdentifier: AppIdentity.websiteDataIdentifier)
        let lease = try ProfileLifecycleLease(root: root, profileID: target.id, exclusive: true)
        return NativeProfileCleanupSession(root: root, context: context, lease: lease, onlyInstance: onlyInstance)
    }
}
@MainActor private final class NativeProfileCleanupSession: ProfileMetadataCleaning {
    let root: URL
    let context: AppProfileContext
    var lease: ProfileLifecycleLease?
    let onlyInstance: @MainActor () -> Bool
    var removedPreferences = false
    var originalPreferences: [String: Any]?
    private var metadata: ProfileMetadataManifest?
    private var reviewedMetadata = false
    private let directory: ProfileMetadataDirectory
    private var credentialSnapshot: Set<ProfileCredentialCleanup.Item>?
    init(root: URL, context: AppProfileContext, lease: ProfileLifecycleLease, onlyInstance: @escaping @MainActor () -> Bool) {
        self.root = root; self.context = context; self.lease = lease; self.onlyInstance = onlyInstance
        directory = ProfileMetadataDirectory(root: root, profileID: context.profileID)
    }
    func close() { lease = nil }
    func reviewMetadata(recovering: ProfileMetadataManifest?) async throws -> ProfileMetadataManifest? {
        guard lease != nil, onlyInstance() else { throw ProfileCleanupProblem.otherInstance }
        metadata = try await directory.review(recovering: recovering)
        reviewedMetadata = true
        return metadata
    }
    func validateMetadata(_ manifest: ProfileMetadataManifest) async throws {
        guard lease != nil, onlyInstance() else { throw ProfileCleanupProblem.otherInstance }
        try await directory.validate(manifest)
        guard lease != nil, onlyInstance() else { throw ProfileCleanupProblem.otherInstance }
        metadata = manifest
    }
    private func preflight() async throws {
        guard lease != nil, onlyInstance() else { throw ProfileCleanupProblem.otherInstance }
        if let metadata { try await validateMetadata(metadata) }
        else if reviewedMetadata, try await directory.exists() { throw ProfileCleanupProblem.savedData }
    }
    func metadataFileIsPresent(_ file: ProfileMetadataFile, manifest: ProfileMetadataManifest) async throws -> Bool {
        try await validateMetadata(manifest)
        return try await directory.isPresent(file, manifest: manifest)
    }
    func removeMetadataFile(_ file: ProfileMetadataFile, manifest: ProfileMetadataManifest) async throws {
        try await validateMetadata(manifest)
        try await directory.remove(file, manifest: manifest)
    }
    func finishMetadata(_ manifest: ProfileMetadataManifest) async throws {
        try await validateMetadata(manifest)
        try await directory.finish(manifest)
    }
    func probe(_ step: ProfileCleanupStep, state: ProfileCleanupState) async -> ProfileCleanupProbe {
        guard lease != nil, onlyInstance() else { return .blocked(.otherInstance) }
        do {
            switch step {
            case .website:
                return await WKWebsiteDataStore.allDataStoreIdentifiers.contains(context.websiteDataIdentifier) ? .ready : .absent
            case .spotlight:
                if state == .complete { return .confirmed }
                guard CSSearchableIndex.isIndexingAvailable() else { return .blocked(.unavailable) }
                return state == .pending ? .ready : .blocked(.uncertainIndex)
            case .credentials:
                let context = context
                let items = try await Task.detached { try ProfileCredentialCleanup.items(context: context) }.value
                if items.isEmpty { return .absent }
                let current = Set(items)
                if let credentialSnapshot, credentialSnapshot != current { return .blocked(.credentialsUnavailable) }
                credentialSnapshot = current
                return .ready
            case .preferences:
                guard let preferences = UserDefaults(suiteName: context.namespace) else { return .blocked(.unknownPreferences) }
                guard let domain = preferences.persistentDomain(forName: context.namespace), !domain.isEmpty else {
                    return removedPreferences || state == .complete ? .confirmed : .blocked(.unknownPreferences)
                }
                guard ProfilePreferenceCleanup.accepts(domain) else { return .blocked(.unknownPreferences) }
                if let originalPreferences, !NSDictionary(dictionary: originalPreferences).isEqual(to: domain) { return .blocked(.unknownPreferences) }
                originalPreferences = domain
                return .ready
            case .directory:
                if reviewedMetadata, metadata == nil {
                    return try await directory.exists() ? .blocked(.savedData) : .absent
                }
                let current = try await directory.review(recovering: metadata)
                if !reviewedMetadata { metadata = current; reviewedMetadata = true }
                return try await directory.exists() ? .ready : .absent
            }
        } catch { return .blocked((error as? ProfileCleanupProblem) ?? .unavailable) }
    }
    func remove(_ step: ProfileCleanupStep) async throws {
        guard lease != nil, onlyInstance() else { throw ProfileCleanupProblem.otherInstance }
        try await preflight()
        switch step {
        case .website:
            guard await WKWebsiteDataStore.allDataStoreIdentifiers.contains(context.websiteDataIdentifier), onlyInstance() else { throw ProfileCleanupProblem.unavailable }
            try await preflight()
            try await WKWebsiteDataStore.remove(forIdentifier: context.websiteDataIdentifier)
            guard !(await WKWebsiteDataStore.allDataStoreIdentifiers.contains(context.websiteDataIdentifier)) else { throw ProfileCleanupProblem.unavailable }
        case .spotlight:
            guard CSSearchableIndex.isIndexingAvailable() else { throw ProfileCleanupProblem.unavailable }
            let index = CSSearchableIndex(name: context.namespace + ".catalog")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                index.deleteAllSearchableItems { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        case .credentials:
            let context = context, expected = credentialSnapshot ?? []
            try await Task.detached { [self] in
                try await ProfileCredentialCleanup.remove(context: context, expected: expected) { try await self.preflight() }
            }.value
            credentialSnapshot = []
        case .preferences:
            guard case .ready = await probe(.preferences, state: .pending), let prefs = UserDefaults(suiteName: context.namespace) else { throw ProfileCleanupProblem.unknownPreferences }
            try await preflight()
            guard let domain = prefs.persistentDomain(forName: context.namespace), ProfilePreferenceCleanup.accepts(domain),
                  let originalPreferences, NSDictionary(dictionary: originalPreferences).isEqual(to: domain) else { throw ProfileCleanupProblem.unknownPreferences }
            prefs.removePersistentDomain(forName: context.namespace)
            guard prefs.synchronize(), prefs.persistentDomain(forName: context.namespace).map(\.isEmpty) ?? true else { throw ProfileCleanupProblem.unavailable }
            removedPreferences = true
        case .directory:
            guard let metadata, metadata.files.isEmpty else { throw ProfileCleanupProblem.savedData }
            try await finishMetadata(metadata)
        }
    }
}
enum ProfilePreferenceCleanup {
    static let booleans: Set<String> = ["autoplay", "cacheLibraryMetadata", "persistsLocalQueue", "persistsEpisodeProgress", "keepsMiniPlayerOnTop", "showsSongChangeNotifications", "sessionRestoreBlocked", "spotlightLibraryEnabled", "onDeviceCommandInterpretationEnabled", NativeHaptics.preferenceKey]
    static func accepts(_ values: [String: Any]) -> Bool {
        guard values.count <= 32 else { return false }
        for (key, value) in values {
            if booleans.contains(key) { guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }; continue }
            switch key {
            case "volume": guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else { return false }
            case "appearance": guard let value = value as? String, ["system", "light", "dark"].contains(value) else { return false }
            case NativeControlAccent.preferenceKey: guard let value = value as? String, NativeControlAccent(rawValue: value) != nil else { return false }
            case "lastAccount": guard let value = value as? String, EpisodeProgressAccountKey.accepts(value) else { return false }
            default: return false
            }
        }
        return true
    }
}
private enum ProfileCredentialCleanup {
    struct Item: Hashable, Sendable { let service: String; let account: String; let reference: Data; let digest: Data }
    static func items(context: AppProfileContext) throws -> [Item] {
        var items: [Item] = []
        for service in [context.listenBrainzCredentialService, context.lastFMCredentialService] {
            let auth = LAContext(); auth.interactionNotAllowed = true
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                kSecAttrSynchronizable: kSecAttrSynchronizableAny, kSecUseAuthenticationContext: auth,
                kSecMatchLimit: 33, kSecReturnAttributes: true, kSecReturnData: true, kSecReturnPersistentRef: true]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let rows = result as? [[CFString: Any]], rows.count <= 32 else { throw ProfileCleanupProblem.credentialsUnavailable }
            for row in rows {
                guard row[kSecAttrService] as? String == service, let account = row[kSecAttrAccount] as? String,
                      EpisodeProgressAccountKey.accepts(account), (row[kSecAttrSynchronizable] as? Bool ?? false) == false,
                      let data = row[kSecValueData] as? Data, let ref = row[kSecValuePersistentRef] as? Data, ref.count <= 1_024 else { throw ProfileCleanupProblem.credentialsUnavailable }
                if service == context.listenBrainzCredentialService {
                    guard data.count <= 256, let token = String(data: data, encoding: .utf8), ListenBrainzAPI.validToken(token) else { throw ProfileCleanupProblem.credentialsUnavailable }
                } else {
                    guard data.count <= 4_096, let saved = try? JSONDecoder().decode(LastFMSavedCredentials.self, from: data), saved.isValid,
                          let original = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
                          let encoded = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? NSDictionary,
                          original == encoded else { throw ProfileCleanupProblem.credentialsUnavailable }
                }
                items.append(.init(service: service, account: account, reference: ref, digest: Data(SHA256.hash(data: data))))
            }
        }
        return items
    }
    static func remove(context: AppProfileContext, expected: Set<Item>, preflight: @Sendable () async throws -> Void) async throws {
        guard Set(try items(context: context)) == expected else { throw ProfileCleanupProblem.credentialsUnavailable }
        for item in expected {
            let current = try items(context: context)
            guard current.contains(where: { $0.service == item.service && $0.account == item.account && $0.reference == item.reference && $0.digest == item.digest }) else { throw ProfileCleanupProblem.credentialsUnavailable }
            let auth = LAContext(); auth.interactionNotAllowed = true
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: item.service,
                kSecAttrAccount: item.account, kSecAttrSynchronizable: false, kSecMatchItemList: [item.reference], kSecUseAuthenticationContext: auth]
            try await preflight()
            guard try items(context: context).contains(item) else { throw ProfileCleanupProblem.credentialsUnavailable }
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ProfileCleanupProblem.credentialsUnavailable }
        }
        guard try items(context: context).isEmpty else { throw ProfileCleanupProblem.credentialsUnavailable }
    }
}

struct ProfileProcessEntry: Sendable {
    let pid: Int32
    let bundle: String?
    let executable: String?
}
enum ProfileProcessAdmission {
    static func allows(_ entries: [ProfileProcessEntry], ownPID: Int32, bundle: String, executable: String) -> Bool {
        !entries.contains {
            $0.pid != ownPID && ($0.bundle == bundle || ($0.bundle == nil && $0.executable == executable))
        }
    }
}
