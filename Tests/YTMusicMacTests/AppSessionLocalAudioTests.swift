import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

@Suite("Local audio session restoration", .serialized) @MainActor
struct AppSessionLocalAudioTests {
    @Test func authBlockedStartupRestoresOnlyAWhollyLocalValidatedQueueWithoutPlaying() async throws {
        let f = try LocalSessionFixture(mixed: false)
        defer { f.remove() }
        try await f.queueStore.save(f.snapshot)
        await f.session.start()
        #expect(f.session.queue.entries.map(\.track.id) == [f.track.id])
        #expect(!f.session.hasRetainedStartupQueue && !f.session.wantsPlayback)
        #expect(f.session.queue.currentOccurrence == nil && !f.session.player.playbackIntent)
        #expect(f.session.account.loginWebView == nil && f.session.player.webView.url == nil)
        #expect(await f.library.reads == 1)
        await f.session.shutdown()
    }

    @Test func unverifiedMixedSnapshotRemainsHiddenAcrossAccountCallbacksAndIncidentalSaves() async throws {
        let f = try LocalSessionFixture(mixed: true)
        defer { f.remove() }
        try await f.queueStore.save(f.snapshot)
        await f.session.start()
        #expect(f.session.queue.isEmpty && f.session.hasRetainedStartupQueue)
        f.session.account.onAccountChanged?(true)
        f.session.account.onAccountConfirmed?(String(repeating: "b", count: 64))
        f.session.pause(); f.session.setVolume(0.2)
        #expect(f.session.queue.isEmpty && f.session.hasRetainedStartupQueue)
        #expect(f.session.reviewRetainedStartupQueue() == nil)
        let stale = AppSession.RetainedQueueReview(id: UUID(), account: UUID(), queueRevision: f.session.queue.revision)
        #expect(!f.session.openRetainedStartupQueue(stale))
        await f.session.shutdown()
        #expect(try await f.queueStore.load() == f.snapshot)
    }

    @Test func anExplicitNewLocalQueueMayReplaceARetainedMixedSnapshot() async throws {
        let f = try LocalSessionFixture(mixed: true)
        defer { f.remove() }
        try await f.queueStore.save(f.snapshot)
        await f.session.start()
        f.session.addToQueue([f.track])
        #expect(!f.session.hasRetainedStartupQueue)
        await f.session.shutdown()
        #expect(try await f.queueStore.load()?.entries.map(\.track.id) == [f.track.id])
        #expect(f.session.account.loginWebView == nil)
    }

    @Test func acceptedStartupReadDrainsWithItsProfileLeaseAndCannotPublishAfterQuiescence() async throws {
        let f = try LocalSessionFixture(mixed: false, held: true)
        defer { f.remove() }
        try await f.queueStore.save(f.snapshot)
        let starting = Task { await f.session.start() }
        await f.library.waitStarted()
        #expect(f.holds.count == 1)
        f.session.quiesceForProfileSwitch()
        var finished = false
        let settling = Task { _ = await f.session.settleForProfileSwitch(); finished = true }
        for _ in 0..<8 { await Task.yield() }
        #expect(!finished && f.holds.count == 1 && f.session.queue.isEmpty)
        await f.library.release()
        await starting.value; await settling.value
        #expect(finished && f.holds.count == 0 && f.session.queue.isEmpty)
        #expect(try await f.queueStore.load() == f.snapshot)
        await f.session.shutdown()
    }

    @Test func signOutRejectsNewActionsUntilCleanupCompletesAndThenAllowsLocalQueueUse() async throws {
        let f = try LocalSessionFixture(mixed: false, holdSignOut: true)
        defer { f.remove() }
        try await f.queueStore.save(f.snapshot)
        await f.session.start()
        let signingOut = Task { await f.session.signOut() }
        await f.signOutGate.waitStarted()
        #expect(f.session.isSigningOut && !f.session.acceptsProfileActions && f.session.queue.isEmpty)
        let volume = f.preferences.defaults.double(forKey: "volume")
        let destination = f.session.destination
        f.session.playTracks([f.track]); f.session.addToQueue([f.track]); f.session.playNext([f.track])
        f.session.setVolume(0.1); f.session.navigate(to: .explore)
        #expect(f.session.queue.isEmpty && !f.session.wantsPlayback)
        #expect(f.preferences.defaults.double(forKey: "volume") == volume && f.session.destination == destination)
        await f.signOutGate.release(); await signingOut.value
        #expect(!f.session.isSigningOut && f.session.acceptsProfileActions)
        f.session.addToQueue([f.track]); #expect(f.session.queue.entries.map(\.track.id) == [f.track.id])
        #expect(f.session.account.loginWebView == nil && f.session.player.webView.url == nil)
        await f.session.shutdown()
    }

    @Test func aQueuedPageReadyReadMustStillOwnTheExactCurrentSourceBeforeAccountIO() async throws {
        let f = try LocalSessionFixture(mixed: false)
        defer { f.remove() }
        f.session.player.onPageReady?(f.session.player.webView)
        // The callback was queued, but its output owner has since been revoked.
        f.session.player.quiesce()
        for _ in 0..<8 { await Task.yield() }
        #expect(f.accountReads == 0)
        await f.session.shutdown()
    }
}

/// Uses temporary queue metadata, fake library/profile adapters and an empty
/// nonpersistent host. Native account restoration and output are disabled.
@MainActor private final class LocalSessionFixture {
    let preferences = SceneCheckPreferences()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let holds = LocalAudioTestHolds()
    let signOutGate = LocalSessionSignOutGate()
    let library: StartupLocalLibrary
    let queueStore: QueueStore
    let snapshot: QueueSnapshot
    let track: Track
    private(set) var session: AppSession!
    var accountReads = 0
    init(mixed: Bool, held: Bool = false, holdSignOut: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profileID = UUID(), reference = LocalAudioReference(libraryID: UUID(), fileID: UUID())
        let metadata = LocalAudioMetadata(title: "Local fixture", artist: "Artist", duration: 120, byteCount: 512)
        track = try metadata.track(reference: reference)
        let io = TestLocalAudioIO()
        let record = LocalAudioLibraryRecord(reference: reference, metadata: metadata, identity: io.identity,
            bookmark: .init(mode: .ordinary, data: Data([1])))
        library = StartupLocalLibrary(.init(profileID: profileID, libraryID: reference.libraryID, records: [record]), held: held)
        queueStore = QueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        var queue = PlaybackQueue()
        var tracks = [track]
        if mixed { tracks.append(Track(id: "abcDEF12_-3", title: "Private service fixture", artist: "Artist", contentKind: .song)) }
        _ = queue.replace(with: tracks); snapshot = queue.snapshot(resumePosition: 12)
        let context = try AppProfileContext(profile: .original, appIdentifier: "fixture.audio", legacyDirectory: directory,
                                           legacyWebsiteDataIdentifier: profileID)
        let holds = holds
        let resources = LocalAudioSessionResources(context: context, store: library,
            profiles: TestLocalAudioProfiles(storageID: profileID, hold: { holds.hold() }),
            references: .init(profileStorageID: profileID), bookmarks: io,
            playback: .init(profileStorageID: profileID, prepare: { _, _, _, _ in .failure(.unsupported) },
                makeEngine: { bind, accepts in LocalAudioPlayerEngine(profileStorageID: profileID,
                    factory: { _ in fatalError("Native output must remain disabled in this fixture.") }, bindEvents: bind, acceptsEvent: accepts) }),
            reads: LocalAudioReadAdmission())
        preferences.defaults.set(true, forKey: "sessionRestoreBlocked")
        let credentials = MusicSessionStore()
        var configuration = AppSessionConfiguration(preferences: preferences.defaults, dataStore: .nonPersistent(),
            credentials: credentials, client: YouTubeMusicClient(transport: SceneCheckTransport(), sessions: credentials),
            queueStore: queueStore, queueStorageError: nil, installsSystemMedia: false, isSceneCheck: false)
        configuration.localAudioResources = resources
        let signOutGate = signOutGate
        configuration.signOutWebAccount = { _ in
            if holdSignOut { await signOutGate.wait() }
            await credentials.clear()
        }
        configuration.synchronizeAccountPage = { [weak self] _, _ in self?.accountReads += 1; return false }
        session = AppSession(configuration: configuration)
    }
    func remove() { preferences.remove(); try? FileManager.default.removeItem(at: directory) }
}
private actor StartupLocalLibrary: LocalAudioLibraryStoring {
    let document: LocalAudioLibraryDocument
    private var held: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private(set) var reads = 0
    init(_ document: LocalAudioLibraryDocument, held: Bool) { self.document = document; self.held = held }
    func load() async throws -> LocalAudioLibraryDocument? {
        reads += 1
        if held {
            await withCheckedContinuation { continuation = $0; let waiting = observers; observers = []; waiting.forEach { $0.resume() } }
        }
        return document
    }
    func save(_ document: LocalAudioLibraryDocument, replacing revision: UUID?, if permitted: @Sendable () -> Bool) async throws {
        throw LocalAudioLibraryError.invalidLibrary
    }
    func waitStarted() async { if reads == 0 { await withCheckedContinuation { observers.append($0) } } }
    func release() { held = false; let waiting = continuation; continuation = nil; waiting?.resume() }
}

private actor LocalSessionSignOutGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation = $0; let waiting = observers; observers = []; waiting.forEach { $0.resume() } }
    }
    func waitStarted() async { if continuation == nil { await withCheckedContinuation { observers.append($0) } } }
    func release() { let waiting = continuation; continuation = nil; waiting?.resume() }
}
