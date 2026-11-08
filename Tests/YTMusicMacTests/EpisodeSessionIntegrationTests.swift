import Foundation
import MusicCore
import Testing
import WebKit
import YouTubeMusic
@testable import YTMusicMac

@MainActor struct EpisodeSessionIntegrationTests {
    @Test func waitingForEpisodeStorageKeepsTheExplicitResumePointWithoutLoadingMedia() async throws {
        let suite = "EpisodeSessionTests-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let sessions = MusicSessionStore()
        let transport = SceneCheckTransport()
        let configuration = AppSessionConfiguration(preferences: preferences, dataStore: .nonPersistent(),
            credentials: sessions, client: YouTubeMusicClient(transport: transport, sessions: sessions),
            queueStore: nil, queueStorageError: nil, installsSystemMedia: false, isSceneCheck: false)
        let session = AppSession(configuration: configuration)
        session.episodePlayback.bindAccount(String(repeating: "a", count: 64))
        let track = Track(id: "abcDEF12_-3", title: "Episode", artist: "Show", duration: 600,
            contentKind: .podcastEpisode, episode: .init(identity: .init(browseID: "MPEDfixture")))
        let selected = session.queue.replace(with: [track], startAt: 0)
        let occurrence = try #require(selected)
        session.wantsPlayback = true
        session.request(occurrence, resumingAt: 42)
        #expect(session.savedQueueSnapshot().resumePosition == 42)
        #expect(session.player.webView.url == nil)
        session.pause()
        await session.episodePlayback.waitUntilLoaded()
        await Task.yield()
        #expect(session.savedQueueSnapshot().resumePosition == 42)
        #expect(!session.wantsPlayback)
        #expect(session.player.webView.url == nil)
        await session.shutdown()
    }
}
