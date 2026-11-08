import Darwin
import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

private func exportSong() -> Track {
    Track(id: "abcDEF12_-3", title: "Song", artist: "Artist", artworkURL: URL(string: "https://example.invalid/private?credential=secret"),
        origin: .catalog, contentKind: .song)
}
private final class ExportTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0
    func advance(_ value: TimeInterval) { lock.withLock { seconds += value } }
    func monotonic() -> TimeInterval { lock.withLock { seconds } }
    func date() -> Date { Date(timeIntervalSince1970: 1_800_000_000 + monotonic()) }
}
private actor ExportTestSleeper {
    private var continuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                calls += 1; continuations[id] = continuation; waiting?.resume(); waiting = nil
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { continuations.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func waitForSleep() async { if continuations.isEmpty { await withCheckedContinuation { waiting = $0 } } }
    func wake() { let pending = continuations; continuations = [:]; pending.values.forEach { $0.resume() } }
    var pendingCount: Int { continuations.count }
}

private actor ExportTestWriter: StreamingMetadataWriting {
    enum Pause: Sendable { case create, write, clear }
    private var pause: Pause?
    private var paused: CheckedContinuation<Void, Never>?
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var clearWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var latest: [UUID: StreamingExportReceipt] = [:]
    private(set) var creates = 0
    private(set) var writes: [Data] = []
    private(set) var clearCount = 0
    func pauseNext(_ value: Pause) { pause = value }
    func waitForPause() async { if paused == nil { await withCheckedContinuation { pauseWaiter = $0 } } }
    func release() { paused?.resume(); paused = nil }
    private func suspend(_ point: Pause) async {
        if pause == point {
            pause = nil
            await withCheckedContinuation { paused = $0; pauseWaiter?.resume(); pauseWaiter = nil }
        }
    }
    func create(url: URL, format: StreamingMetadataFormat, now: Date, gate: PlaybackOutputGate, revision: UInt64) async throws -> StreamingExportReceipt {
        await suspend(.create)
        let saved = try gate.configuring(through: revision) {
            creates += 1
            return StreamingExportReceipt(id: UUID(), path: url.path, format: format,
                parent: StreamingFileIdentity(stat()), file: StreamingFileIdentity(stat()), digest: String(repeating: "a", count: 64), revision: 0)
        }
        latest[saved.id] = saved; return saved
    }
    func write(_ document: StreamingMetadataDocument, receipt: StreamingExportReceipt, gate: PlaybackOutputGate,
               permit: PlaybackOutputGate.Permit) async throws -> StreamingExportReceipt {
        await suspend(.write)
        let saved = try gate.publishing(permit) {
            writes.append(try document.encoded(format: receipt.format))
            var saved = latest[receipt.id] ?? receipt; saved.revision += 1; return saved
        }
        latest[saved.id] = saved; return saved
    }
    func clear(receipt: StreamingExportReceipt, now: Date, gate: PlaybackOutputGate, through revision: UInt64) async throws -> StreamingExportReceipt {
        await suspend(.clear)
        let saved = try gate.clearing(target: receipt.id, through: revision) {
            clearCount += 1
            var saved = latest[receipt.id] ?? receipt; saved.revision += 1; return saved
        }
        latest[saved.id] = saved
        let ready = clearWaiters.filter { $0.0 <= clearCount }
        clearWaiters.removeAll { $0.0 <= clearCount }; ready.forEach { $0.1.resume() }
        return saved
    }
    func waitForClears(_ count: Int) async {
        if clearCount < count { await withCheckedContinuation { clearWaiters.append((count, $0)) } }
    }
}

@MainActor private struct ExportControllerFixture {
    let domain = "StreamingMetadataExportTests-" + UUID().uuidString
    let key = String(repeating: "a", count: 64)
    let other = String(repeating: "b", count: 64)
    let namespace = "test.existing.profile.namespace"
    let sessions = MusicSessionStore()
    let writer = ExportTestWriter()
    let clock = ExportTestClock()
    let sleeper = ExportTestSleeper()
    var preferences: UserDefaults { UserDefaults(suiteName: domain)! }
    var url: URL { FileManager.default.temporaryDirectory.appendingPathComponent(domain + ".json") }
    func remove() { preferences.removePersistentDomain(forName: domain) }
    func model() -> StreamingMetadataExport {
        StreamingMetadataExport(preferences: preferences, profileNamespace: namespace, sessions: sessions, writer: writer,
            now: clock.date, monotonic: clock.monotonic, sleep: sleeper.sleep)
    }
    func signIn(_ account: String? = nil) async {
        await sessions.replaceSession(accountID: account ?? key, cookieHeader: "fixture=1", sapisid: "fixture")
    }
    func enable(_ model: StreamingMetadataExport) async throws {
        await signIn(); model.bindAccount(key)
        await model.configure(url: url, format: .json, expectedScope: model.scope)
        #expect(model.receipt != nil && !model.isEnabled)
        await model.enable(expectedScope: model.scope)
        #expect(model.isEnabled)
    }
    func occurrence() throws -> PlaybackOccurrence {
        var queue = PlaybackQueue(); queue.replace(with: [exportSong()], startAt: 0)
        return try #require(queue.currentOccurrence)
    }
}

@MainActor @Suite("Opt-in streaming metadata export", .serialized)
struct StreamingMetadataExportTests {
    @Test func defaultOffHasNoIOOrWatchdogAndExplicitConsentExportsOnlyPublicText() async throws {
        let fixture = ExportControllerFixture(); defer { fixture.remove() }
        let model = fixture.model(); await fixture.signIn(); model.bindAccount(fixture.key)
        let occurrence = try fixture.occurrence()
        model.sample(track: exportSong(), occurrence: occurrence, ended: false)
        #expect(!model.isEnabled && !model.isWorking && model.receipt == nil)
        #expect(await fixture.writer.creates == 0)
        #expect(await fixture.writer.writes.isEmpty)
        #expect(await fixture.sleeper.calls == 0)
        try await fixture.enable(model)
        #expect(await fixture.writer.writes.isEmpty)
        model.sample(track: exportSong(), occurrence: occurrence, ended: false)
        await model.waitForIdle()
        let data = try #require(await fixture.writer.writes.first)
        let text = String(decoding: data, as: UTF8.self)
        for omitted in [exportSong().id, "private", "credential", fixture.key, "cookie", "artwork", fixture.namespace] { #expect(!text.contains(omitted)) }
        #expect(text.contains("Song") && text.contains("Artist") && text.contains("expiresAt"))
        await model.stop()
        #expect(!model.isEnabled && !model.isWorking)
        #expect(await fixture.sleeper.pendingCount == 0)
    }

    @Test func verifiedSamplesCoalesceAndOneMonotonicWatchdogClearsStaleMetadata() async throws {
        let fixture = ExportControllerFixture(); defer { fixture.remove() }
        let model = fixture.model(); try await fixture.enable(model)
        let occurrence = try fixture.occurrence()
        for _ in 0..<100 { model.sample(track: exportSong(), occurrence: occurrence, ended: false) }
        await model.waitForIdle(); await fixture.sleeper.waitForSleep()
        #expect(await fixture.writer.writes.count == 1)
        #expect(await fixture.sleeper.calls == 1)
        fixture.clock.advance(4); model.sample(track: exportSong(), occurrence: occurrence, ended: false)
        await model.waitForIdle()
        #expect(await fixture.writer.writes.count == 1)
        fixture.clock.advance(1); model.sample(track: exportSong(), occurrence: occurrence, ended: false)
        await model.waitForIdle()
        #expect(await fixture.writer.writes.count == 2)
        fixture.clock.advance(16); await fixture.sleeper.wake()
        await fixture.writer.waitForClears(2); await model.waitForIdle()
        #expect(model.isEnabled && !model.isWorking)
        #expect(await fixture.sleeper.pendingCount == 0)
        await model.stop()
    }

    @Test func synchronousInterruptRevokesALateWriteBeforeTheClearRuns() async throws {
        let fixture = ExportControllerFixture(); defer { fixture.remove() }
        let model = fixture.model(); try await fixture.enable(model)
        await fixture.writer.pauseNext(.write)
        model.sample(track: exportSong(), occurrence: try fixture.occurrence(), ended: false)
        await fixture.writer.waitForPause()
        model.interrupt()
        await fixture.writer.release(); await model.waitForIdle()
        #expect(await fixture.writer.writes.isEmpty)
        #expect(await fixture.writer.clearCount == 2)
        #expect(model.isEnabled && !model.isWorking)
        await model.stop()
    }

    @Test func accountChangesHideConfigurationAndLateWritesCannotPublishForTheNewOwner() async throws {
        let fixture = ExportControllerFixture(); defer { fixture.remove() }
        let model = fixture.model(); try await fixture.enable(model)
        let firstReceipt = try #require(model.receipt)
        await fixture.writer.pauseNext(.write)
        model.sample(track: exportSong(), occurrence: try fixture.occurrence(), ended: false)
        await fixture.writer.waitForPause()
        model.bindAccount(nil); await fixture.signIn(fixture.other); model.bindAccount(fixture.other)
        #expect(!model.isEnabled && model.receipt == nil)
        await fixture.writer.release(); await model.waitForIdle()
        #expect(await fixture.writer.writes.isEmpty)
        #expect(model.receipt == nil)
        model.bindAccount(nil); await fixture.signIn(); model.bindAccount(fixture.key)
        #expect(model.receipt?.id == firstReceipt.id && !model.isEnabled)
        let settings = StreamingExportSettings(preferences: fixture.preferences, profileNamespace: fixture.namespace)
        #expect(try settings.load(account: fixture.other) == nil)
        await model.stop()
    }

    @Test func changedCredentialScopesDisablePublishingEvenWithoutAnAccountCallback() async throws {
        let fixture = ExportControllerFixture(); defer { fixture.remove() }
        let model = fixture.model(); try await fixture.enable(model)
        await fixture.sessions.replaceSession(accountID: fixture.key, cookieHeader: "fixture=2", sapisid: "fixture-new")
        model.sample(track: exportSong(), occurrence: try fixture.occurrence(), ended: false)
        await model.waitForIdle()
        #expect(!model.isEnabled)
        #expect(await fixture.writer.writes.isEmpty)
        #expect(await fixture.writer.clearCount == 2)
        await model.stop()
    }

    @Test func staleFileChoiceCannotCreateATargetAfterAccountDetachment() async throws {
        let fixture = ExportControllerFixture(); defer { fixture.remove() }
        let model = fixture.model(); await fixture.signIn(); model.bindAccount(fixture.key)
        await fixture.writer.pauseNext(.create)
        let scope = model.scope
        let choosing = Task { await model.configure(url: fixture.url, format: .json, expectedScope: scope) }
        await fixture.writer.waitForPause(); model.bindAccount(nil)
        await fixture.writer.release(); await choosing.value
        #expect(await fixture.writer.creates == 0)
        #expect(model.receipt == nil && !model.isEnabled)
        await model.stop()
    }

    @Test func quiescingRevokesPendingConsentAndWaitsForItsOutcomeBeforeARebind() async throws {
        let fixture = ExportControllerFixture(); defer { fixture.remove() }
        let model = fixture.model(); await fixture.signIn(); model.bindAccount(fixture.key)
        await model.configure(url: fixture.url, format: .json, expectedScope: model.scope)
        let receipt = try #require(model.receipt); let scope = model.scope
        await fixture.writer.pauseNext(.clear)
        let enabling = Task { await model.enable(expectedScope: scope) }
        await fixture.writer.waitForPause()
        model.quiesce()
        #expect(!model.isEnabled && model.receipt == nil && !model.isAccountAvailable)
        let stopping = Task { await model.stop() }
        #expect(model.isWorking)
        await fixture.writer.release(); await enabling.value; await stopping.value
        #expect(!model.isEnabled && !model.isWorking)
        model.resume(confirmedAccountHash: fixture.key)
        #expect(model.receipt?.id == receipt.id && !model.isEnabled)
        #expect(await fixture.writer.writes.isEmpty)
        await model.stop()
    }

    @Test func knownUploadsEpisodesUnknownMetadataAndURLsAreExcludedAndClearPreviousText() async throws {
        let fixture = ExportControllerFixture(); defer { fixture.remove() }
        let model = fixture.model(); try await fixture.enable(model)
        let occurrence = try fixture.occurrence()
        model.sample(track: exportSong(), occurrence: occurrence, ended: false); await model.waitForIdle()
        var invalid: [Track] = []
        for index in 0..<7 {
            var song = exportSong()
            switch index {
            case 0: song.origin = .upload
            case 1: song.contentKind = .podcastEpisode
            case 2: song.contentKind = nil
            case 3: song.artist = "Unknown artist"
            case 4: song.artist = "Artiste inconnu"
            case 5: song.title = "https://private.invalid/?token=secret"
            default: song.title = "Line one\nLine two"
            }
            invalid.append(song)
        }
        for song in invalid { #expect(PublicPlaybackMetadata(track: song) == nil); model.sample(track: song, occurrence: occurrence, ended: false) }
        await model.waitForIdle()
        #expect(await fixture.writer.writes.count == 1)
        #expect(await fixture.writer.clearCount == 2)
        await model.stop()
    }

    @Test func receiptsStayPerAccountAndProfileAndRelaunchRequiresFreshConsent() async throws {
        let fixture = ExportControllerFixture(); defer { fixture.remove() }
        let model = fixture.model(); try await fixture.enable(model)
        let receipt = try #require(model.receipt); await model.stop()
        let reopened = fixture.model(); reopened.bindAccount(fixture.key)
        #expect(reopened.receipt?.id == receipt.id && !reopened.isEnabled)
        let otherProfile = StreamingMetadataExport(preferences: fixture.preferences, profileNamespace: "another.existing.profile", sessions: fixture.sessions, writer: fixture.writer)
        otherProfile.bindAccount(fixture.key)
        #expect(otherProfile.settingsBlocked && otherProfile.receipt == nil && !otherProfile.isEnabled)
        let settings = StreamingExportSettings(preferences: fixture.preferences, profileNamespace: fixture.namespace)
        #expect(try settings.load(account: fixture.key)?.id == receipt.id)
        #expect(try settings.load(account: fixture.other) == nil)
        await reopened.forgetTarget(expectedScope: reopened.scope)
        #expect(reopened.receipt == nil)
        #expect(try settings.load(account: fixture.key) == nil)
        await reopened.stop(); await otherProfile.stop()
    }

    @Test func futureCorruptAndForeignConfigurationsSurviveUntilExplicitForget() async throws {
        let fixture = ExportControllerFixture(); defer { fixture.remove() }
        let storageKey = "streamingMetadataTarget.v1." + fixture.key
        for object in [Data("{\"version\":99}".utf8), Data("corrupt".utf8), Data(repeating: 32, count: 16_385), "foreign type"] as [Any] {
            fixture.preferences.set(object, forKey: storageKey)
            let model = fixture.model(); await fixture.signIn(); model.bindAccount(fixture.key)
            #expect(model.settingsBlocked && model.receipt == nil)
            await model.configure(url: fixture.url, format: .json, expectedScope: model.scope)
            #expect((fixture.preferences.object(forKey: storageKey) as? NSObject)?.isEqual(object) == true)
            await model.forgetTarget(expectedScope: model.scope)
            #expect(fixture.preferences.object(forKey: storageKey) == nil && !model.settingsBlocked)
            await model.stop()
        }
        #expect(await fixture.writer.creates == 0)
    }

    @Test func accountAndScopeGuardsRejectStaleConsentAndInvalidConfirmedKeys() async throws {
        let fixture = ExportControllerFixture(); defer { fixture.remove() }
        let model = fixture.model(); model.bindAccount("unconfirmed")
        #expect(!model.isAccountAvailable)
        await fixture.signIn(); model.bindAccount(fixture.key)
        let oldScope = model.scope
        model.bindAccount(nil); model.bindAccount(fixture.key)
        await model.configure(url: fixture.url, format: .json, expectedScope: oldScope)
        #expect(await fixture.writer.creates == 0)
        await model.configure(url: fixture.url, format: .json, expectedScope: model.scope)
        let receipt = try #require(model.receipt)
        await model.enable(expectedScope: oldScope)
        #expect(!model.isEnabled)
        await fixture.signIn(fixture.other)
        await model.forgetTarget(expectedScope: model.scope)
        #expect(model.receipt?.id == receipt.id)
        let settings = StreamingExportSettings(preferences: fixture.preferences, profileNamespace: fixture.namespace)
        #expect(try settings.load(account: fixture.key)?.id == receipt.id)
        await model.stop()
    }

    @Test func isolatedNativeLifecycleRevokesAndClearsWithoutPlaybackOrNetworkCalls() async throws {
        let preferences = SceneCheckPreferences(); defer { preferences.remove() }
        let transport = SceneCheckTransport(); let writer = ExportTestWriter()
        var configuration = AppSessionConfiguration.sceneCheck(preferences: preferences.defaults, transport: transport)
        configuration.profileNamespace = "test.injected.existing.profile"
        configuration.streamingMetadataWriter = writer
        let key = String(repeating: "a", count: 64)
        await configuration.credentials.replaceSession(accountID: key, cookieHeader: "fixture=1", sapisid: "fixture")
        let session = AppSession(configuration: configuration)
        let model = try #require(session.streamingExport)
        session.account.onAccountConfirmed?(key)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("SceneStreamingExport-" + UUID().uuidString + ".json")
        await model.configure(url: target, format: .json, expectedScope: model.scope)
        await model.enable(expectedScope: model.scope)
        session.queue.replace(with: [exportSong()], startAt: 0)
        let occurrence = try #require(session.queue.currentOccurrence)
        model.sample(track: exportSong(), occurrence: occurrence, ended: false); await model.waitForIdle()
        session.pause(); await model.waitForIdle()
        #expect(await writer.clearCount == 2)
        session.player.onVerifiedContentProgress?(occurrence, 10, 120, false)
        await model.waitForIdle()
        #expect(await writer.writes.count == 1)
        #expect(await transport.attempts == 0)
        await session.signOut()
        #expect(model.receipt == nil && !model.isEnabled)
        await session.shutdown()
        #expect(await transport.attempts == 0)
    }

    @Test func bothExportLanguageTablesContainEveryNativeLookupWithoutChangingLocalePreferences() throws {
        var tables: [[String: String]] = []
        for language in ["en", "fr"] {
            let folder = try #require(AppLocalization.bundle.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: folder))
            let url = try #require(bundle.url(forResource: "StreamingExport", withExtension: "strings"))
            tables.append(try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String]))
        }
        #expect(Set(tables[0].keys) == Set(tables[1].keys))
        #expect(tables[1]["Enable for This Session"] == "Activer pour cette session")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let expression = try NSRegularExpression(pattern: #"StreamingExportText\.text\("((?:[^"\\]|\\.)*)""#)
        let files = try #require(FileManager.default.enumerator(at: root.appendingPathComponent("Sources/YTMusicMac"), includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let literal = String(source[Range(match.range(at: 1), in: source)!])
                let key = try JSONDecoder().decode(String.self, from: Data("\"\(literal)\"".utf8))
                #expect(tables[0][key] != nil, "Missing export copy: \(key)")
            }
        }
    }
}
