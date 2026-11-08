import Foundation
import MusicCore
import WebKit
import YouTubeMusic

@MainActor
struct AppSessionConfiguration {
    let preferences: UserDefaults
    let dataStore: WKWebsiteDataStore
    let credentials: MusicSessionStore
    let client: YouTubeMusicClient
    let queueStore: QueueStore?
    let queueStorageError: String?
    var installsSystemMedia: Bool
    let isSceneCheck: Bool
    var profileNamespace: String = AppIdentity.identifier
    var namedQueueStore: NamedQueueStore? = nil
    var playlistVerificationClient: YouTubeMusicClient? = nil
    var localCollectionStore: LocalCollectionStore? = nil
    var metadataCache: LibraryMetadataCache? = nil
    var storageInventory: ProtectedStorageInventory? = nil
    var spotlightIndex: (any LibrarySpotlightIndex)? = nil

    var episodeProgressStore: EpisodeProgressStore? = nil
    var localSongRuleStore: LocalSongRuleStore? = nil
    var listenBrainzCoordinator: ListenBrainzCoordinator? = nil
    var queuePlaylistJournal: QueuePlaylistJournalStore? = nil
    var lastFMCoordinator: LastFMCoordinator? = nil
    var streamingMetadataWriter: (any StreamingMetadataWriting)? = nil
    var discordPresenceClient: (any DiscordPresenceProviding)? = nil
    var commandInterpreter: (any CommandInterpreting)? = nil
    var commandGenerationGate: CommandGenerationGate? = nil
    var sponsorBlockClient: (any SponsorBlockProviding)? = nil
    var nativeHapticPerformer: (any NativeHapticPerforming)? = nil
    var nativeHapticClock: @Sendable () -> TimeInterval = PlaybackOutputTime.monotonic

    static func withoutSystemMedia(_ source: Self) -> Self {
        var result = source; result.installsSystemMedia = false; return result
    }

    static func live() -> Self {
        live(preferences: AppIdentity.preferences,
             dataStore: WKWebsiteDataStore(forIdentifier: AppIdentity.websiteDataIdentifier),
             directory: try? AppIdentity.applicationSupportDirectory(), namespace: AppIdentity.identifier)
    }

    static func live(preferences: UserDefaults, dataStore: WKWebsiteDataStore,
                     directory: URL?, namespace: String, installsSystemMedia: Bool = true) -> Self {
        let credentials = MusicSessionStore()
        let queueStore = directory.map {
            QueueStore(fileURL: $0.appendingPathComponent("queue.json"))
        }
        return Self(preferences: preferences,
                    dataStore: dataStore,
                    credentials: credentials, client: YouTubeMusicClient(sessions: credentials),
                    queueStore: queueStore,
                    queueStorageError: queueStore == nil ? AppLocalization.text("The queue cannot be saved because application storage is unavailable.") : nil,
                    installsSystemMedia: installsSystemMedia, isSceneCheck: false, profileNamespace: namespace,
                    namedQueueStore: directory.map { NamedQueueStore(directoryURL: $0.appendingPathComponent("SavedQueues", isDirectory: true)) },
                    localCollectionStore: directory.map { LocalCollectionStore(directoryURL: $0.appendingPathComponent("LocalCollections", isDirectory: true)) },
                    metadataCache: directory.map { LibraryMetadataCache(directoryURL: $0.appendingPathComponent("MetadataCache", isDirectory: true)) },
                    storageInventory: directory.map { ProtectedStorageInventory(directoryURL: $0) },
                    spotlightIndex: CoreSpotlightLibraryIndex(namespace: namespace),
                    episodeProgressStore: directory.map { EpisodeProgressStore(directory: $0.appendingPathComponent("episode-progress", isDirectory: true)) },
                    localSongRuleStore: directory.map { LocalSongRuleStore(directoryURL: $0.appendingPathComponent("LocalSongRules", isDirectory: true)) },
                    listenBrainzCoordinator: directory.map { ListenBrainzCoordinator(
                        store: ListenBrainzStore(directory: $0.appendingPathComponent("listenbrainz", isDirectory: true)),
                        tokens: KeychainListenBrainzTokens(service: namespace + ".listenbrainz"),
                        api: ListenBrainzAPI(transport: ListenBrainzHTTPTransport())) },
                    queuePlaylistJournal: directory.map { QueuePlaylistJournalStore(directoryURL: $0.appendingPathComponent("PendingQueuePlaylists", isDirectory: true)) },
                    lastFMCoordinator: directory.map { LastFMCoordinator(
                        store: LastFMStore(directory: $0.appendingPathComponent("lastfm", isDirectory: true)),
                        secrets: KeychainLastFMCredentials(service: namespace + ".lastfm"),
                        api: LastFMAPI(transport: LastFMHTTPTransport())) },
                    streamingMetadataWriter: StreamingExportFile(), discordPresenceClient: DiscordPresenceClient(),
                    sponsorBlockClient: SponsorBlockClient(), nativeHapticPerformer: AppKitHapticPerformer())
    }

    static func sceneCheck(preferences: UserDefaults, transport: SceneCheckTransport) -> Self {
        let credentials = MusicSessionStore()
        return Self(preferences: preferences, dataStore: .nonPersistent(), credentials: credentials,
                    client: YouTubeMusicClient(transport: transport, sessions: credentials),
                    queueStore: nil, queueStorageError: nil, installsSystemMedia: false, isSceneCheck: true)
    }
}
