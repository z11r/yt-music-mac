import Foundation
import MusicCore
import Testing
import WebKit
import YouTubeMusic
@testable import YTMusicMac

private actor RecordingSpotlightIndex: LibrarySpotlightIndex {
    private var entries: [String: SpotlightCatalogRecord] = [:]
    private var batches: [[SpotlightCatalogRecord]] = []
    private var deletions: [String] = []
    private var pausesNextWrite = false
    private var paused: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var failsDeletion = false
    private var failsIndexing = false
    enum Failure: Error { case injected }
    func pauseNextWrite() { pausesNextWrite = true }
    func index(_ records: [SpotlightCatalogRecord]) async throws {
        batches.append(records)
        if pausesNextWrite {
            pausesNextWrite = false
            await withCheckedContinuation {
                paused = $0
                observer?.resume()
                observer = nil
            }
        }
        for record in records { entries[record.identifier] = record }
        if failsIndexing { throw Failure.injected }
    }
    func delete(domain: String) throws {
        deletions.append(domain)
        if failsDeletion { throw Failure.injected }
        entries = entries.filter { $0.value.domain != domain && !$0.value.domain.hasPrefix(domain + ".") }
    }
    func waitForPausedWrite() async {
        if paused != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func releaseWrite() { paused?.resume(); paused = nil }
    func setDeletionFailure(_ value: Bool) { failsDeletion = value }
    func setIndexFailure(_ value: Bool) { failsIndexing = value }
    func records() -> [SpotlightCatalogRecord] { entries.values.sorted { $0.identifier < $1.identifier } }
    func writtenBatches() -> [[SpotlightCatalogRecord]] { batches }
    func deletedDomains() -> [String] { deletions }
}

private struct SpotlightFixture {
    let suite = "SpotlightTests-" + UUID().uuidString
    let first = String(repeating: "a", count: 64)
    let second = String(repeating: "b", count: 64)
    var preferences: UserDefaults { UserDefaults(suiteName: suite)! }
    func remove() { preferences.removePersistentDomain(forName: suite) }
    func page(_ suffix: String = "one", count: Int = 1) -> MusicPage {
        MusicPage(title: "Library", sections: [], items: (0..<count).map {
            .collection(MusicCollection(id: "VLPL\(suffix)\($0)", kind: .playlist, title: "Playlist \(suffix) \($0)",
                subtitle: "Private detail", artworkURL: URL(string: "https://example.com/private?token=secret"), radioPlaylistID: "OpaqueRadio"))
        })
    }
    @MainActor func controller(_ index: RecordingSpotlightIndex, sessions: any MusicSessionProviding) -> SpotlightLibraryController {
        SpotlightLibraryController(index: index, sessions: sessions, preferences: preferences, namespace: "test.music.app")
    }
}

@MainActor @Suite("Optional scoped Spotlight library indexing", .serialized)
struct SpotlightLibraryTests {
    @Test func freshDefaultOffNeverTouchesTheInjectedIndexOrCreatesAReceipt() async throws {
        let fixture = SpotlightFixture()
        defer { fixture.remove() }
        let index = RecordingSpotlightIndex()
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let controller = fixture.controller(index, sessions: sessions)
        controller.start()
        let source = try #require(await controller.beginSource())
        await controller.capture(fixture.page(), source: source)
        await controller.waitForIdle()
        #expect(!controller.isEnabled && !controller.isWorking && !controller.hasIndexedMetadata)
        #expect(await index.writtenBatches().isEmpty)
        #expect(await index.deletedDomains().isEmpty)
        #expect(fixture.preferences.data(forKey: "spotlightLibraryReceipt") == nil)
    }

    @Test func indexingIsBoundedBatchedAndStoresOnlyCatalogNamesAndIdentity() async throws {
        let fixture = SpotlightFixture()
        defer { fixture.remove() }
        let index = RecordingSpotlightIndex()
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let controller = fixture.controller(index, sessions: sessions)
        controller.setEnabled(true)
        let source = try #require(await controller.beginSource())
        await controller.capture(fixture.page(count: 600), source: source)
        await controller.waitForIdle()
        let records = await index.records()
        let batches = await index.writtenBatches()
        #expect(records.count == 500 && batches.count == 5 && batches.allSatisfy { $0.count <= 100 })
        #expect(Set(records.map(\.domain)) == [controller.policy.domain(accountKey: fixture.first)!])
        #expect(records.allSatisfy { $0.reference.serviceID.hasPrefix("PL") && !$0.identifier.contains("token") })
        #expect(controller.lastSubmittedCount == 500 && !controller.isWorking)
        let receipt = try #require(fixture.preferences.data(forKey: "spotlightLibraryReceipt"))
        #expect(receipt.count < 1_024 && !String(decoding: receipt, as: UTF8.self).contains("Playlist"))
        let restored = fixture.controller(index, sessions: sessions)
        restored.start()
        restored.accountChanged(isSignedIn: true)
        await restored.waitForIdle()
        #expect(restored.isEnabled && restored.lastSubmittedCount == 500)
        #expect(await index.deletedDomains().isEmpty)
    }

    @Test func disableWaitsForALateWriteThenRemovesOnlyThisAppsDomain() async throws {
        let fixture = SpotlightFixture()
        defer { fixture.remove() }
        let index = RecordingSpotlightIndex()
        await index.pauseNextWrite()
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let controller = fixture.controller(index, sessions: sessions)
        controller.setEnabled(true)
        let source = try #require(await controller.beginSource())
        await controller.capture(fixture.page(), source: source)
        await index.waitForPausedWrite()
        controller.setEnabled(false)
        #expect(!controller.isEnabled && controller.isRemovalPending)
        await index.releaseWrite()
        await controller.waitForIdle()
        #expect(await index.records().isEmpty)
        #expect(await index.deletedDomains() == [controller.policy.rootDomain])
        #expect(!controller.hasIndexedMetadata && fixture.preferences.data(forKey: "spotlightLibraryReceipt") == nil)
    }

    @Test func pendingReplacementsCoalesceWhileTheSingleWriterWaits() async throws {
        let fixture = SpotlightFixture()
        defer { fixture.remove() }
        let index = RecordingSpotlightIndex()
        await index.pauseNextWrite()
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let controller = fixture.controller(index, sessions: sessions)
        controller.setEnabled(true)
        let source = try #require(await controller.beginSource())
        await controller.capture(fixture.page("initial"), source: source)
        await index.waitForPausedWrite()
        for value in 0..<20 { await controller.capture(fixture.page("replacement\(value)"), source: source) }
        await index.releaseWrite()
        await controller.waitForIdle()
        #expect(await index.writtenBatches().count == 2)
        #expect(await index.records().map(\.reference.serviceID) == ["PLreplacement190"])
    }

    @Test func accountChangesCannotMixDomainsEvenWhenTheOldWriteFinishesLate() async throws {
        let fixture = SpotlightFixture()
        defer { fixture.remove() }
        let index = RecordingSpotlightIndex()
        await index.pauseNextWrite()
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let controller = fixture.controller(index, sessions: sessions)
        controller.setEnabled(true)
        let oldSource = try #require(await controller.beginSource())
        await controller.capture(fixture.page("old"), source: oldSource)
        await index.waitForPausedWrite()
        await sessions.replaceSession(accountID: fixture.second, cookieHeader: "fixture=1", sapisid: "fixture")
        controller.accountChanged(isSignedIn: true)
        await controller.capture(fixture.page("stale"), source: oldSource)
        let newSource = try #require(await controller.beginSource())
        await controller.capture(fixture.page("new"), source: newSource)
        await index.releaseWrite()
        await controller.waitForIdle()
        #expect(await index.records().map(\.reference.serviceID) == ["PLnew0"])
        #expect(await index.records().allSatisfy { $0.domain == controller.policy.domain(accountKey: fixture.second) })
    }

    @Test func signOutInvalidatesSourcesAndRemovesLateWrites() async throws {
        let fixture = SpotlightFixture()
        defer { fixture.remove() }
        let index = RecordingSpotlightIndex()
        await index.pauseNextWrite()
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let controller = fixture.controller(index, sessions: sessions)
        controller.setEnabled(true)
        let source = try #require(await controller.beginSource())
        await controller.capture(fixture.page(), source: source)
        await index.waitForPausedWrite()
        controller.accountChanged(isSignedIn: false)
        await sessions.clear()
        await controller.capture(fixture.page("stale"), source: source)
        await index.releaseWrite()
        await controller.waitForIdle()
        #expect(await index.records().isEmpty)
        #expect(await index.writtenBatches().count == 1)
        #expect(await controller.beginSource() == nil)
        #expect(!controller.hasIndexedMetadata && controller.lastSubmittedCount == 0)
    }

    @Test func failedRemovalIsRetainedAndRetriedAfterRelaunchWithoutReindexing() async throws {
        let fixture = SpotlightFixture()
        defer { fixture.remove() }
        let index = RecordingSpotlightIndex()
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let controller = fixture.controller(index, sessions: sessions)
        controller.setEnabled(true)
        let source = try #require(await controller.beginSource())
        await controller.capture(fixture.page(), source: source)
        await controller.waitForIdle()
        await index.setDeletionFailure(true)
        controller.setEnabled(false)
        await controller.waitForIdle()
        #expect(controller.isRemovalPending && controller.errorMessage != nil && !controller.isEnabled)
        #expect(await index.records().count == 1)
        await index.setDeletionFailure(false)
        let restored = fixture.controller(index, sessions: sessions)
        restored.start()
        await restored.waitForIdle()
        #expect(await index.records().isEmpty)
        #expect(await index.writtenBatches().count == 1)
        #expect(!restored.hasIndexedMetadata && restored.errorMessage == nil)
    }

    @Test func partialIndexFailureCannotClaimSuccessAndExplicitRemovalRecoversIt() async throws {
        let fixture = SpotlightFixture()
        defer { fixture.remove() }
        let index = RecordingSpotlightIndex()
        await index.setIndexFailure(true)
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let controller = fixture.controller(index, sessions: sessions)
        controller.setEnabled(true)
        let source = try #require(await controller.beginSource())
        await controller.capture(fixture.page(), source: source)
        await controller.waitForIdle()
        #expect(controller.isRemovalPending && controller.lastSubmittedCount == 0 && controller.errorMessage != nil)
        let identifier = try #require(await index.records().first?.identifier)
        #expect(await controller.resolve(identifier) == nil)
        controller.removeIndexedMetadata()
        await controller.waitForIdle()
        #expect(await index.records().isEmpty)
        #expect(controller.errorMessage == nil)
    }

    @Test func unsupportedCleanupReceiptsArePreservedUntilExplicitScopedRemoval() async throws {
        let fixture = SpotlightFixture()
        defer { fixture.remove() }
        let future = Data("{\"version\":99}".utf8)
        fixture.preferences.set(future, forKey: "spotlightLibraryReceipt")
        let index = RecordingSpotlightIndex()
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let controller = fixture.controller(index, sessions: sessions)
        controller.start()
        controller.setEnabled(true)
        let source = try #require(await controller.beginSource())
        await controller.capture(fixture.page(), source: source)
        await controller.waitForIdle()
        #expect(fixture.preferences.data(forKey: "spotlightLibraryReceipt") == future)
        #expect(await index.writtenBatches().isEmpty)
        #expect(await index.deletedDomains().isEmpty)
        controller.removeIndexedMetadata()
        await controller.waitForIdle()
        #expect(await index.deletedDomains() == [controller.policy.rootDomain])
        #expect(fixture.preferences.data(forKey: "spotlightLibraryReceipt") == nil)
    }

    @Test func resultResolutionRequiresTheCurrentConfirmedAccountAndOptIn() async throws {
        let fixture = SpotlightFixture()
        defer { fixture.remove() }
        let index = RecordingSpotlightIndex()
        let sessions = MusicSessionStore()
        let controller = fixture.controller(index, sessions: sessions)
        let identifier = try #require(controller.policy.records(from: [LocalCollectionReference(serviceID: "PLone", kind: .playlist, title: "Title")], accountKey: fixture.first, now: Date()).first?.identifier)
        #expect(await controller.resolve(identifier) == nil)
        controller.setEnabled(true)
        #expect(await controller.resolve(identifier) == nil)
        await sessions.replaceSession(accountID: fixture.second, cookieHeader: "fixture=1", sapisid: "fixture")
        #expect(await controller.resolve(identifier) == nil)
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        #expect(await controller.resolve(identifier)?.serviceID == "PLone")
        #expect(await controller.resolve(identifier + "?play=1") == nil)
    }

    @Test func nativeResultRoutingKeepsQueueAndPlaybackIntactAndNeverPromptsForAnAccount() async throws {
        let fixture = SpotlightFixture()
        defer { fixture.remove() }
        let index = RecordingSpotlightIndex()
        let sessions = MusicSessionStore()
        let transport = SceneCheckTransport()
        let configuration = AppSessionConfiguration(preferences: fixture.preferences, dataStore: .nonPersistent(), credentials: sessions,
            client: YouTubeMusicClient(transport: transport, sessions: sessions), queueStore: nil, queueStorageError: nil,
            installsSystemMedia: false, isSceneCheck: false, spotlightIndex: index)
        let session = AppSession(configuration: configuration)
        session.setSpotlightEnabled(true)
        let policy = SpotlightCatalogPolicy(namespace: AppIdentity.identifier)
        let identifier = try #require(policy.records(from: [LocalCollectionReference(serviceID: "PLone", kind: .playlist, title: "Title")], accountKey: fixture.first, now: Date()).first?.identifier)
        #expect(!(await session.openSpotlightResult(identifier)))
        #expect(session.destination == .home && !session.showsAccount && !session.player.playbackIntent)
        #expect(await transport.attempts == 0)
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        session.queue.replace(with: [Track(id: "abcDEF12_-3", title: "Queued", artist: "Artist")])
        let queue = session.queue.snapshot()
        #expect(await session.openSpotlightResult(identifier))
        #expect(session.destination == .collection(MusicCollection(id: "PLone", kind: .playlist, title: "Playlist")))
        #expect(session.queue.snapshot() == queue && !session.player.playbackIntent && !session.showsAccount)
        #expect(session.account.loginWebView == nil && session.player.webView.url == nil)
        session.setSpotlightEnabled(false)
        await session.shutdown()
    }
}
