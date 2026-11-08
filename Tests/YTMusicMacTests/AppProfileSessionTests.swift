import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@MainActor @Suite("Profile session action fences")
struct AppProfileSessionTests {
    @Test func suspendedSceneSessionRejectsOldWindowCommandsWithoutClearingItsQueue() async throws {
        let suite = "ProfileSceneTests-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let configuration = AppSessionConfiguration.sceneCheck(preferences: preferences, transport: SceneCheckTransport())
        let session = AppSession(configuration: configuration)
        let track = Track(id: "abcDEF12_-3", title: "Opaque title", artist: "Artist")
        session.addToQueue([track]); session.setVolume(0.4)
        let before = session.queue.snapshot()
        let destination = session.destination
        session.quiesceForProfileSwitch()
        #expect(!session.acceptsProfileActions)
        session.addToQueue([track]); session.playNext([track]); session.next()
        session.toggleShuffle(); session.setVolume(0.9)
        session.navigate(to: .explore)
        #expect(session.queue.snapshot() == before)
        #expect(session.destination == destination)
        #expect(preferences.double(forKey: "volume") == 0.4)
        #expect(!session.wantsPlayback)
        await session.settleForProfileSwitch()
        session.resumePausedProfileOwnership()
        #expect(session.acceptsProfileActions && !session.wantsPlayback)
        session.addToQueue([track]); #expect(session.queue.entries.count == 2)
        await session.shutdown()
        session.addToQueue([track]); #expect(session.queue.entries.count == 2)
        #expect(session.isShuttingDown && !session.acceptsProfileActions)
    }

    @Test func persistenceSettingsUseOnlyTheInjectedProfileAndKeepLegacyDefaults() async throws {
        let suites = (0..<2).map { _ in "ProfileSceneTests-" + UUID().uuidString }
        let defaults = try suites.map { try #require(UserDefaults(suiteName: $0)) }
        defer { for (suite, preferences) in zip(suites, defaults) { preferences.removePersistentDomain(forName: suite) } }
        defaults[1].set(false, forKey: "persistsLocalQueue")
        defaults[1].set(false, forKey: "persistsEpisodeProgress")
        let sessions = defaults.map { AppSession(configuration: .sceneCheck(preferences: $0, transport: SceneCheckTransport())) }
        #expect(sessions[0].persistsLocalQueue && sessions[0].episodePlayback.persistenceEnabled)
        #expect(!sessions[1].persistsLocalQueue && !sessions[1].episodePlayback.persistenceEnabled)
        sessions[1].setPersistsLocalQueue(true); sessions[1].setPersistsEpisodeProgress(true)
        #expect(defaults[0].object(forKey: "persistsLocalQueue") == nil)
        #expect(defaults[0].object(forKey: "persistsEpisodeProgress") == nil)
        #expect(defaults[1].bool(forKey: "persistsLocalQueue"))
        #expect(defaults[1].bool(forKey: "persistsEpisodeProgress"))
        for session in sessions { await session.shutdown() }
    }
}
