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
    func prepare(_ profile: AppProfile, allowCreation: Bool) async throws -> PreparedAppProfile<NativeAppProfileRuntime> {
        let context = try AppProfileContext(profile: profile, appIdentifier: AppIdentity.identifier,
            legacyDirectory: legacyDirectory, legacyWebsiteDataIdentifier: AppIdentity.websiteDataIdentifier)
        // WebKit's initializer creates a missing store. Existing profiles must
        // prove their store is still present before calling it.
        if !context.isDefault && !allowCreation {
            let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
            guard identifiers.contains(context.websiteDataIdentifier) else { throw AppProfileError.missingStore }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: context.dataDirectory.path, isDirectory: &directory), directory.boolValue else {
                throw AppProfileError.missingStore
            }
        }
        let preferences: UserDefaults
        if context.isDefault { preferences = AppIdentity.preferences }
        else {
            guard let scoped = UserDefaults(suiteName: context.namespace) else { throw AppProfileError.unavailable }
            preferences = scoped
            // Registration is process-local; absent options stay off without
            // copying the default profile's preferences into a new namespace.
            preferences.register(defaults: ["cacheLibraryMetadata": false, "persistsLocalQueue": false, "autoplay": false, "persistsEpisodeProgress": false])
        }
        if allowCreation {
            try FileManager.default.createDirectory(at: context.dataDirectory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let configuration = AppSessionConfiguration.live(preferences: preferences,
            dataStore: WKWebsiteDataStore(forIdentifier: context.websiteDataIdentifier),
            directory: context.dataDirectory, namespace: context.namespace, installsSystemMedia: false)
        return PreparedAppProfile { NativeAppProfileRuntime(profile: profile, configuration: configuration) }
    }
}
