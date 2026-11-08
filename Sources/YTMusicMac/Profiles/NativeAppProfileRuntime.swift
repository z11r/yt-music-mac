import Foundation
import WebKit

/// Constructed only by explicit app startup/profile selection. Tests exercise the
/// generic owner with fake runtimes and never instantiate this factory.
@MainActor
final class NativeAppProfileRuntime: AppProfileRuntime {
    var profile: AppProfile
    let session: AppSession
    let preferences: UserDefaults
    let bindings: PlaybackShortcutBindings
    let notifications: SongChangeNotifier
    private let usesNativeOwners: Bool

    init(profile: AppProfile, configuration: AppSessionConfiguration) {
        self.profile = profile
        preferences = configuration.preferences
        usesNativeOwners = !configuration.isSceneCheck
        session = AppSession(configuration: configuration)
        bindings = PlaybackShortcutBindings(preferences: configuration.preferences)
        notifications = SongChangeNotifier(session: session, preferences: configuration.preferences)
    }
    func quiesce() { notifications.stop(); session.quiesceForProfileSwitch() }
    func settle() async { await notifications.waitForIdle(); await session.settleForProfileSwitch(); await ArtworkCache.shared.clearForProfileSwitch() }
    func resumePausedOwnership() { session.resumePausedProfileOwnership() }
    func shutdown() async { notifications.stop(); await session.shutdown() }
    func startPaused() async {
        if usesNativeOwners { session.installSystemMediaOwnership(); notifications.start() }
        await session.start()
    }
}

@MainActor
struct NativeAppProfileFactory {
    let legacyDirectory: URL
    let registry: any AppProfileRegistry
    func prepare(_ profile: AppProfile, allowCreation: Bool) async throws -> PreparedAppProfile<NativeAppProfileRuntime> {
        let lease = try profile.isDefault ? nil : ProfileLifecycleLease(root: legacyDirectory, profileID: profile.id, exclusive: false)
        let latest = try await registry.load()
        guard latest.archive.profiles.contains(profile), !latest.archive.deletions.contains(where: { $0.target.id == profile.id }) else { throw AppProfileError.stale }
        let context = try AppProfileContext(profile: profile, appIdentifier: AppIdentity.identifier,
            legacyDirectory: legacyDirectory, legacyWebsiteDataIdentifier: AppIdentity.websiteDataIdentifier)
        // WebKit's initializer creates a missing store. Existing profiles must
        // prove their store is still present before calling it.
        if !context.isDefault && !allowCreation {
            let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
            guard identifiers.contains(context.websiteDataIdentifier) else { throw AppProfileError.missingStore }
        }
        let confirmed = try await registry.load()
        guard confirmed.archive.profiles.contains(profile), !confirmed.archive.deletions.contains(where: { $0.target.id == profile.id }) else { throw AppProfileError.stale }
        if !context.isDefault { try ProfileSafeDirectories.admitProfile(root: legacyDirectory, id: profile.id, creating: allowCreation) }
        let preferences: UserDefaults
        if context.isDefault { preferences = AppIdentity.preferences }
        else {
            guard let scoped = UserDefaults(suiteName: context.namespace) else { throw AppProfileError.unavailable }
            preferences = scoped
            // Registration is process-local; absent options stay off without
            // copying the default profile's preferences into a new namespace.
            preferences.register(defaults: ["cacheLibraryMetadata": false, "persistsLocalQueue": false, "autoplay": false, "persistsEpisodeProgress": false])
        }
        if allowCreation && context.isDefault {
            try FileManager.default.createDirectory(at: context.dataDirectory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let store = WKWebsiteDataStore(forIdentifier: context.websiteDataIdentifier)
        if let lease { ProfileStoreLeaseRetention.attach(lease, to: store) }
        let configuration = AppSessionConfiguration.live(preferences: preferences,
            dataStore: store,
            directory: context.dataDirectory, namespace: context.namespace, installsSystemMedia: false)
        return PreparedAppProfile { NativeAppProfileRuntime(profile: profile, configuration: configuration) }
    }
}
