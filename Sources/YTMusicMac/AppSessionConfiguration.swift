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
    let installsSystemMedia: Bool
    let isSceneCheck: Bool
    var namedQueueStore: NamedQueueStore? = nil

    static func live() -> Self {
        let credentials = MusicSessionStore()
        let directory = try? AppIdentity.applicationSupportDirectory()
        let queueStore = directory.map {
            QueueStore(fileURL: $0.appendingPathComponent("queue.json"))
        }
        return Self(preferences: AppIdentity.preferences,
                    dataStore: WKWebsiteDataStore(forIdentifier: AppIdentity.websiteDataIdentifier),
                    credentials: credentials, client: YouTubeMusicClient(sessions: credentials),
                    queueStore: queueStore,
                    queueStorageError: queueStore == nil ? "The queue cannot be saved because application storage is unavailable." : nil,
                    installsSystemMedia: true, isSceneCheck: false,
                    namedQueueStore: directory.map { NamedQueueStore(directoryURL: $0.appendingPathComponent("SavedQueues", isDirectory: true)) })
    }

    static func sceneCheck(preferences: UserDefaults, transport: SceneCheckTransport) -> Self {
        let credentials = MusicSessionStore()
        return Self(preferences: preferences, dataStore: .nonPersistent(), credentials: credentials,
                    client: YouTubeMusicClient(transport: transport, sessions: credentials),
                    queueStore: nil, queueStorageError: nil, installsSystemMedia: false, isSceneCheck: true)
    }
}
