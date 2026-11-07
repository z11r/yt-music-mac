import Foundation
import Testing
import YouTubeMusic
@testable import YTMusicMac

@Suite("Isolated scene checks")
struct SceneCheckTests {
    @Test func revisionsRequireAnAttachedViewAndCannotBeBatchedOrDuplicated() {
        var progress = SceneCheckProgress()
        #expect(progress.requestNext() == 1)
        #expect(progress.requestNext() == nil)
        let unattached = progress.acknowledge(1, attached: false)
        let outOfOrder = progress.acknowledge(2, attached: true)
        let first = progress.acknowledge(1, attached: true)
        let duplicate = progress.acknowledge(1, attached: true)
        #expect(!unattached)
        #expect(!outOfOrder)
        #expect(first)
        #expect(!duplicate)
        #expect(!progress.isComplete)
        for revision in 2...SceneCheckProgress.target {
            #expect(progress.requestNext() == revision)
            let acknowledged = progress.acknowledge(revision, attached: true)
            #expect(acknowledged)
        }
        #expect(progress.isComplete)
        #expect(progress.requestNext() == nil)
    }

    @Test func networkTransportRejectsRequestsWithoutOpeningASession() async {
        let transport = SceneCheckTransport()
        do {
            _ = try await transport.send(URLRequest(url: URL(string: "https://example.invalid/")!))
            Issue.record("The scene check must reject every network request.")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        } catch { Issue.record("Unexpected error type.") }
        #expect(await transport.attempts == 1)
    }

    @Test @MainActor func syntheticSessionDoesNotRestoreBrowseOrRegisterPlayback() async {
        let preferences = SceneCheckPreferences()
        defer { preferences.remove() }
        let transport = SceneCheckTransport()
        let session = AppSession(configuration: .sceneCheck(preferences: preferences.defaults, transport: transport))
        await session.start()
        #expect(session.sceneCheckIsIsolated)
        #expect(session.page?.title == "Home")
        #expect(await transport.attempts == 0)
        #expect(session.advanceSceneCheck(to: 1))
        #expect(!session.advanceSceneCheck(to: 1))
        for revision in 2...SceneCheckProgress.target { #expect(session.advanceSceneCheck(to: revision)) }
        #expect(!session.advanceSceneCheck(to: SceneCheckProgress.target + 1))
        session.next()
        session.openAccount()
        #expect(session.sceneCheckIsIsolated)
        #expect(!session.showsAccount)
        #expect(session.queue.entries.count == 3)
        #expect(session.queue.entries.map(\.track.id).filter { $0 == "scene-track-a" }.count == 2)
        #expect(await transport.attempts == 0)
        #expect(await session.account.credentials.snapshot().isAuthenticated == false)
    }

    @Test func preferencesUseSeparateDisposableDomains() {
        let first = SceneCheckPreferences()
        let second = SceneCheckPreferences()
        defer { first.remove(); second.remove() }
        #expect(first.domain != second.domain)
        #expect(first.domain.hasPrefix("io.github.z11r.ytmusicmac.scenecheck."))
        first.defaults.set("dark", forKey: "appearance")
        #expect(second.defaults.string(forKey: "appearance") == "system")
        first.remove()
        #expect(first.defaults.persistentDomain(forName: first.domain)?.isEmpty != false)
        #expect(second.defaults.string(forKey: "appearance") == "system")
    }
}
