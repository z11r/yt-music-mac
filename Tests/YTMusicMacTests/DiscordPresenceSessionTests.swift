import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

private func discordSong() -> Track {
    Track(id: "abcDEF12_-3", title: "Song", artist: "Artist", origin: .catalog, contentKind: .song)
}
private final class DiscordSessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    func now() -> TimeInterval { lock.withLock { value } }
}
private actor DiscordSessionSleeper {
    private var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                pending[id] = continuation; calls += 1; waiter?.resume(); waiter = nil
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func waitForSleep() async { if pending.isEmpty { await withCheckedContinuation { waiter = $0 } } }
    func wake() { let values = pending; pending = [:]; values.values.forEach { $0.resume() } }
    var pendingCount: Int { pending.count }
}
private actor DiscordSessionService: DiscordPresenceProviding {
    private var pausesNext = false
    private var paused: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var clearWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var rejects = false
    private var clearResult = DiscordPresenceClearResult.confirmed
    private(set) var attempts = 0
    private(set) var writes: [(UUID, String, PublicPlaybackMetadata)] = []
    private(set) var clears: [UUID] = []
    func pauseNext() { pausesNext = true }
    func reject() { rejects = true }
    func setClearResult(_ value: DiscordPresenceClearResult) { clearResult = value }
    func waitForPause() async { if paused == nil { await withCheckedContinuation { waiter = $0 } } }
    func release() { paused?.resume(); paused = nil }
    func publish(_ metadata: PublicPlaybackMetadata, applicationID: String, lease: DiscordPresenceLease) async throws {
        attempts += 1
        if pausesNext {
            pausesNext = false
            await withCheckedContinuation { paused = $0; waiter?.resume(); waiter = nil }
        }
        if rejects { throw DiscordPresenceError.rejected }
        try lease.sending { writes.append((lease.id, applicationID, metadata)) }
    }
    func clear(lease: DiscordPresenceLease) -> DiscordPresenceClearResult {
        lease.revoke(); clears.append(lease.id)
        let ready = clearWaiters.filter { $0.0 <= clears.count }
        clearWaiters.removeAll { $0.0 <= clears.count }; ready.forEach { $0.1.resume() }
        return clearResult
    }
    func waitForClears(_ count: Int) async { if clears.count < count { await withCheckedContinuation { clearWaiters.append((count, $0)) } } }
}
@MainActor private struct DiscordSessionFixture {
    let domain = "DiscordPresenceSessionTests-" + UUID().uuidString
    let key = String(repeating: "a", count: 64)
    let other = String(repeating: "b", count: 64)
    let namespace = "test.existing.profile"
    let applicationID = "100000000000000001"
    let credentials = MusicSessionStore()
    let service = DiscordSessionService()
    let clock = DiscordSessionClock()
    let sleeper = DiscordSessionSleeper()
    var preferences: UserDefaults { UserDefaults(suiteName: domain)! }
    func remove() { preferences.removePersistentDomain(forName: domain) }
    func model() -> DiscordPresenceSession {
        DiscordPresenceSession(preferences: preferences, profileNamespace: namespace, sessions: credentials,
            service: service, monotonic: clock.now, sleep: sleeper.sleep)
    }
    func signIn(_ account: String? = nil) async {
        await credentials.replaceSession(accountID: account ?? key, cookieHeader: "fixture=1", sapisid: "fixture")
    }
    func enable(_ model: DiscordPresenceSession) async {
        await signIn(); model.bindAccount(key)
        await model.configure(applicationID: applicationID, expectedScope: model.scope)
        await model.enable(expectedScope: model.scope)
        #expect(model.isEnabled)
    }
    func occurrence() throws -> PlaybackOccurrence {
        var queue = PlaybackQueue(); queue.replace(with: [discordSong()], startAt: 0)
        return try #require(queue.currentOccurrence)
    }
}

@MainActor @Suite("Session-opt-in Discord song presence", .serialized)
struct DiscordPresenceSessionTests {
    @Test func noConfigurationOrConsentMeansNoClientCallsOrTimers() async throws {
        let fixture = DiscordSessionFixture(); defer { fixture.remove() }
        let model = fixture.model(); await fixture.signIn(); model.bindAccount(fixture.key)
        let occurrence = try fixture.occurrence()
        model.sample(track: discordSong(), occurrence: occurrence, ended: false)
        #expect(!model.isEnabled && model.applicationID == nil && !model.isWorking)
        #expect(await fixture.service.attempts == 0)
        #expect(await fixture.sleeper.calls == 0)
        await model.configure(applicationID: fixture.applicationID, expectedScope: model.scope)
        model.sample(track: discordSong(), occurrence: occurrence, ended: false)
        #expect(await fixture.service.attempts == 0)
        await model.enable(expectedScope: model.scope)
        #expect(model.isEnabled)
        #expect(await fixture.service.attempts == 0)
        #expect(await fixture.sleeper.calls == 0)
        model.sample(track: discordSong(), occurrence: occurrence, ended: false); await model.waitForIdle()
        #expect(await fixture.service.writes.count == 1)
        await model.stop()
        #expect(await fixture.sleeper.pendingCount == 0)
    }
    @Test func verifiedUpdatesCoalesceAtFifteenSecondsAndStaleProgressClearsTheOriginalLease() async throws {
        let fixture = DiscordSessionFixture(); defer { fixture.remove() }
        let model = fixture.model(); await fixture.enable(model)
        let occurrence = try fixture.occurrence()
        for _ in 0..<100 { model.sample(track: discordSong(), occurrence: occurrence, ended: false) }
        await model.waitForIdle(); await fixture.sleeper.waitForSleep()
        #expect(await fixture.service.writes.count == 1)
        fixture.clock.advance(14); model.sample(track: discordSong(), occurrence: occurrence, ended: false)
        await model.waitForIdle()
        #expect(await fixture.service.writes.count == 1)
        fixture.clock.advance(1); model.sample(track: discordSong(), occurrence: occurrence, ended: false)
        await model.waitForIdle()
        #expect(await fixture.service.writes.count == 2)
        #expect(await fixture.sleeper.calls == 1)
        fixture.clock.advance(16); await fixture.sleeper.wake()
        await fixture.service.waitForClears(1); await model.waitForIdle()
        let ids = await fixture.service.writes.map(\.0)
        #expect(await fixture.service.clears == [ids[0]])
        #expect(model.isEnabled)
        await model.stop()
    }
    @Test func immediateRevokePreventsLateMetadataAndSettlesBeforeProfileRebind() async throws {
        let fixture = DiscordSessionFixture(); defer { fixture.remove() }
        let model = fixture.model(); await fixture.enable(model)
        await fixture.service.pauseNext()
        model.sample(track: discordSong(), occurrence: try fixture.occurrence(), ended: false)
        await fixture.service.waitForPause()
        model.quiesce()
        #expect(model.applicationID == nil && !model.isEnabled && !model.isAccountAvailable)
        let stopping = Task { await model.stop() }
        #expect(model.isWorking)
        await fixture.service.release(); await stopping.value
        #expect(await fixture.service.writes.isEmpty)
        #expect(await fixture.service.clears.count == 1)
        model.resume(confirmedAccountHash: fixture.key)
        #expect(model.applicationID == fixture.applicationID && !model.isEnabled)
        await model.stop()
    }
    @Test func changedAccountsCredentialsAndStaleConsentNeverReuseAnotherOwnersOptIn() async throws {
        for change in 0..<2 {
            let fixture = DiscordSessionFixture(); defer { fixture.remove() }
            let model = fixture.model(); await fixture.enable(model)
            if change == 0 { await fixture.signIn(fixture.other) }
            else { await fixture.credentials.replaceSession(accountID: fixture.key, cookieHeader: "fixture=2", sapisid: "fixture-new") }
            model.sample(track: discordSong(), occurrence: try fixture.occurrence(), ended: false); await model.waitForIdle()
            #expect(!model.isEnabled)
            #expect(await fixture.service.attempts == 0)
            await model.stop()
        }
        let fixture = DiscordSessionFixture(); defer { fixture.remove() }
        let model = fixture.model(); await fixture.signIn(); model.bindAccount(fixture.key)
        let scope = model.scope; model.quiesce(); model.resume(confirmedAccountHash: fixture.key)
        await model.configure(applicationID: fixture.applicationID, expectedScope: scope)
        #expect(model.applicationID == nil)
        await model.stop()
    }
    @Test func providerRejectionStopsWithoutAutomaticReconnectOrReenable() async throws {
        let fixture = DiscordSessionFixture(); defer { fixture.remove() }
        let model = fixture.model(); await fixture.enable(model); await fixture.service.reject()
        let occurrence = try fixture.occurrence()
        model.sample(track: discordSong(), occurrence: occurrence, ended: false); await model.waitForIdle()
        #expect(!model.isEnabled && model.errorMessage != nil)
        for _ in 0..<100 { model.sample(track: discordSong(), occurrence: occurrence, ended: false) }
        #expect(await fixture.service.attempts == 1)
        #expect(await fixture.service.writes.isEmpty)
        await model.stop()
    }
    @Test func unsupportedUploadsEpisodesUnknownAndLongMetadataNeverPublishAndClearOldActivity() async throws {
        let fixture = DiscordSessionFixture(); defer { fixture.remove() }
        let model = fixture.model(); await fixture.enable(model)
        let occurrence = try fixture.occurrence()
        model.sample(track: discordSong(), occurrence: occurrence, ended: false); await model.waitForIdle()
        for change in 0..<5 {
            var track = discordSong()
            switch change {
            case 0: track.origin = .upload
            case 1: track.contentKind = .podcastEpisode
            case 2: track.contentKind = nil
            case 3: track.artist = "Unknown artist"
            default: track.title = String(repeating: "曲", count: 60)
            }
            model.sample(track: track, occurrence: occurrence, ended: false)
        }
        await model.waitForIdle()
        #expect(await fixture.service.writes.count == 1)
        #expect(await fixture.service.clears.count == 1)
        await model.stop()
    }
    @Test func pauseResumeAndNaturalOccurrenceChangesUseDistinctLeasesWithoutResumingPlayback() async throws {
        let fixture = DiscordSessionFixture(); defer { fixture.remove() }
        let model = fixture.model(); await fixture.enable(model)
        let first = try fixture.occurrence()
        model.sample(track: discordSong(), occurrence: first, ended: false); await model.waitForIdle()
        model.interrupt(); await model.waitForIdle()
        model.sample(track: discordSong(), occurrence: first, ended: false); await model.waitForIdle()
        model.sample(track: discordSong(), occurrence: try fixture.occurrence(), ended: false); await model.waitForIdle()
        let ids = await fixture.service.writes.map(\.0)
        #expect(ids.count == 3 && Set(ids).count == 3)
        #expect(await fixture.service.clears == Array(ids.prefix(2)))
        await model.stop()
    }
    @Test func profileAndAccountNamespacesKeepSavedIDsPrivateAndRelaunchDoesNotShare() async throws {
        let fixture = DiscordSessionFixture(); defer { fixture.remove() }
        let model = fixture.model(); await fixture.enable(model); await model.stop()
        let reopened = fixture.model(); reopened.bindAccount(fixture.key)
        #expect(reopened.applicationID == fixture.applicationID && !reopened.isEnabled)
        reopened.quiesce(); reopened.resume(confirmedAccountHash: fixture.other)
        #expect(reopened.applicationID == nil && !reopened.isEnabled)
        let foreign = DiscordPresenceSession(preferences: fixture.preferences, profileNamespace: "another.existing.profile",
            sessions: fixture.credentials, service: fixture.service)
        foreign.bindAccount(fixture.key)
        #expect(foreign.settingsBlocked && foreign.applicationID == nil)
        await foreign.stop(); await reopened.stop()
    }
    @Test func corruptFutureAndForeignConfigurationsAreKeptUntilExplicitForget() async throws {
        let fixture = DiscordSessionFixture(); defer { fixture.remove() }
        await fixture.signIn()
        let recordName = "discordPresenceApplication.v1." + fixture.key
        for object in [Data("broken".utf8), Data("{\"version\":99}".utf8), Data(repeating: 32, count: 4_097), "wrong type"] as [Any] {
            fixture.preferences.set(object, forKey: recordName)
            let model = fixture.model(); model.bindAccount(fixture.key)
            #expect(model.settingsBlocked)
            await model.configure(applicationID: fixture.applicationID, expectedScope: model.scope)
            #expect((fixture.preferences.object(forKey: recordName) as? NSObject)?.isEqual(object) == true)
            await model.forgetConfiguration(expectedScope: model.scope)
            #expect(fixture.preferences.object(forKey: recordName) == nil && !model.settingsBlocked)
            await model.stop()
        }
        #expect(await fixture.service.attempts == 0)
    }
    @Test func clearUncertaintyIsVisibleWithoutRetainingAProviderConnection() async throws {
        let fixture = DiscordSessionFixture(); defer { fixture.remove() }
        let model = fixture.model(); await fixture.enable(model)
        model.sample(track: discordSong(), occurrence: try fixture.occurrence(), ended: false); await model.waitForIdle()
        await fixture.service.setClearResult(.unconfirmed)
        model.disable(); await model.waitForIdle()
        #expect(!model.isEnabled && model.errorMessage != nil)
        #expect(await fixture.service.clears.count == 1)
        await model.stop()
    }
    @Test func isolatedNativeSessionClearsOnPauseAndRejectsPausedCallbacksWithoutSocketOrNetworkWork() async throws {
        let preferences = SceneCheckPreferences(); defer { preferences.remove() }
        let transport = SceneCheckTransport(); let service = DiscordSessionService()
        var configuration = AppSessionConfiguration.sceneCheck(preferences: preferences.defaults, transport: transport)
        configuration.profileNamespace = "test.existing.profile"; configuration.discordPresenceClient = service
        let key = String(repeating: "a", count: 64)
        await configuration.credentials.replaceSession(accountID: key, cookieHeader: "fixture=1", sapisid: "fixture")
        let session = AppSession(configuration: configuration); let model = try #require(session.discordPresence)
        session.account.onAccountConfirmed?(key)
        await model.configure(applicationID: "100000000000000001", expectedScope: model.scope)
        await model.enable(expectedScope: model.scope)
        session.queue.replace(with: [discordSong()], startAt: 0)
        let occurrence = try #require(session.queue.currentOccurrence)
        model.sample(track: discordSong(), occurrence: occurrence, ended: false); await model.waitForIdle()
        // Valid playing state updates still break scrobble continuity conservatively, but keep public output alive.
        session.player.onListeningInterrupted?(occurrence); await model.waitForIdle()
        #expect(await service.clears.isEmpty)
        session.player.onPlaybackOutputInterrupted?(occurrence); await model.waitForIdle()
        #expect(await service.clears.count == 1)
        session.pause(); await model.waitForIdle()
        session.player.onVerifiedContentProgress?(occurrence, 1, 100, false); await model.waitForIdle()
        #expect(await service.writes.count == 1)
        #expect(await service.clears.count == 1)
        await session.signOut(); await session.shutdown()
        #expect(!model.isEnabled && model.applicationID == nil)
        #expect(await transport.attempts == 0)
    }
    @Test func nativeDiscordCopyHasMatchingLanguageKeysAndNoUntranslatedLookups() throws {
        var tables: [[String: String]] = []
        for language in ["en", "fr"] {
            let folder = try #require(AppLocalization.bundle.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: folder))
            let url = try #require(bundle.url(forResource: "DiscordPresence", withExtension: "strings"))
            tables.append(try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String]))
        }
        #expect(Set(tables[0].keys) == Set(tables[1].keys))
        #expect(tables[1]["Enable for This Session"] == "Activer pour cette session")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let expression = try NSRegularExpression(pattern: #"DiscordPresenceText\.text\("((?:[^"\\]|\\.)*)""#)
        let files = try #require(FileManager.default.enumerator(at: root.appendingPathComponent("Sources/YTMusicMac"), includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let literal = String(source[Range(match.range(at: 1), in: source)!])
                let key = try JSONDecoder().decode(String.self, from: Data("\"\(literal)\"".utf8))
                #expect(tables[0][key] != nil, "Missing Discord copy: \(key)")
            }
        }
    }
}
