import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

private actor SponsorBlockTestService: SponsorBlockProviding {
    private(set) var calls = 0
    private(set) var requested: [(String, TimeInterval)] = []
    var sections = [SponsorBlockSection(id: String(repeating: "a", count: 64), start: 10, end: 20)]
    private var hold = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func holdNext() { hold = true }
    func sections(videoID: String, duration: TimeInterval) async throws -> [SponsorBlockSection] {
        calls += 1; requested.append((videoID, duration))
        let waiting = waiters; waiters = []; waiting.forEach { $0.resume() }
        if hold { await withCheckedContinuation { held = $0 } }
        return sections
    }
    func waitForCall() async { if calls == 0 { await withCheckedContinuation { waiters.append($0) } } }
    func release() { hold = false; held?.resume(); held = nil }
}

private actor SponsorBlockSnapshotGate: MusicSessionProviding {
    let store: MusicSessionStore
    private var hold = false
    private var started = false
    private var held: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    init(store: MusicSessionStore) { self.store = store }
    func holdNext() { hold = true; started = false }
    func snapshot() async -> MusicSession {
        let value = await store.snapshot()
        if hold {
            hold = false; started = true
            let waiting = observers; observers = []; waiting.forEach { $0.resume() }
            await withCheckedContinuation { held = $0 }
        }
        return value
    }
    func waitForSnapshot() async { if !started { await withCheckedContinuation { observers.append($0) } } }
    func release() { held?.resume(); held = nil }
}

private func sponsorBlockSong() -> Track {
    Track(id: "abcDEF12_-3", title: "Song", artist: "Artist", origin: .catalog, contentKind: .song)
}
private func sponsorBlockIdentity() -> SponsorBlockPlaybackIdentity {
    var queue = PlaybackQueue(); queue.replace(with: [sponsorBlockSong()], startAt: 0)
    return .init(occurrence: queue.currentOccurrence!, loadID: UUID(), documentID: UUID(), mediaGeneration: 1, commandRevision: 2, duration: 100)
}
@MainActor private final class SponsorBlockFixture {
    let sessions = MusicSessionStore()
    let service = SponsorBlockTestService()
    let clock = SponsorBlockTestClock()
    let account = String(repeating: "a", count: 64)
    var context: SponsorBlockContext? = .init(accountGeneration: UUID(), playback: sponsorBlockIdentity())
    var position: TimeInterval = 15
    var seeks: [TimeInterval] = []
    var sessionProvider: (any MusicSessionProviding)?
    lazy var model: SponsorBlockSession = {
        let model = SponsorBlockSession(sessions: sessionProvider ?? sessions, profileNamespace: "test.existing.profile", service: service, monotonic: clock.now)
        model.currentContext = { [weak self] in self?.context }
        model.currentPosition = { [weak self] in self?.position ?? .nan }
        model.performSeek = { [weak self] context, section in
            guard let self, self.context == context else { return false }
            self.seeks.append(section.end); return true
        }
        return model
    }()
    func enable() async {
        await sessions.replaceSession(accountID: account, cookieHeader: "fixture=1", sapisid: "fixture")
        model.bindAccount(account); await model.enable(expectedScope: model.scope)
    }
    func lookup() async { model.lookup(); await model.waitForIdle() }
}

@MainActor @Suite("Session-opt-in non-music section previews")
struct SponsorBlockSessionTests {
    @Test func onlyCurrentCommandConfirmedContentCanProduceANativeSegmentIdentity() throws {
        let occurrence = sponsorBlockIdentity().occurrence
        let body: [String: Any] = [
            "kind": "progress", "loadID": UUID().uuidString, "documentID": UUID().uuidString,
            "identity": ["sessionID": occurrence.sessionID.uuidString, "entryID": occurrence.entryID.uuidString,
                         "trackID": occurrence.trackID, "generation": String(occurrence.generation)],
            "mediaGeneration": 1, "sequence": 1, "commandRevision": 3, "playbackIntent": true, "intentSource": "native",
            "videoID": occurrence.trackID, "position": 15, "duration": 100, "volume": 0.5,
            "isPlaying": true, "isBuffering": false, "isAd": false, "mediaReady": true,
        ]
        let accepted = try #require(PlaybackBridgeMessage.decode(body))
        #expect(SponsorBlockPlaybackIdentity.verified(accepted, occurrence: occurrence, commandRevision: 3) != nil)
        #expect(SponsorBlockPlaybackIdentity.verified(accepted, occurrence: occurrence, commandRevision: 4) == nil)
        for (key, value): (String, Any) in [("kind", "ready"), ("kind", "ended"), ("kind", "error"), ("isAd", true),
                                          ("mediaReady", false), ("isBuffering", true), ("isPlaying", false),
                                          ("playbackIntent", false), ("mediaGeneration", 0), ("position", 0),
                                          ("duration", 0), ("videoID", "other123456")] {
            var invalid = body; invalid[key] = value
            let message = try #require(PlaybackBridgeMessage.decode(invalid))
            #expect(SponsorBlockPlaybackIdentity.verified(message, occurrence: occurrence, commandRevision: 3) == nil)
        }
    }
    @Test func explicitSongMetadataIsRequiredWithoutRetaggingLegacyOriginOrInferringFromAnID() {
        let identity = sponsorBlockIdentity(), generation = UUID()
        var song = sponsorBlockSong()
        #expect(SponsorBlockContext.make(track: song, playback: identity, accountGeneration: generation) != nil)
        song.origin = nil
        #expect(SponsorBlockContext.make(track: song, playback: identity, accountGeneration: generation) != nil)
        for modification in 0..<6 {
            var invalid = song
            switch modification {
            case 0: invalid.origin = .upload
            case 1: invalid.contentKind = nil
            case 2: invalid.contentKind = .podcastEpisode
            case 3: invalid.title = invalid.id
            case 4: invalid.artist = "Unknown artist"
            default: invalid.title = String(repeating: "x", count: 513)
            }
            #expect(SponsorBlockContext.make(track: invalid, playback: identity, accountGeneration: generation) == nil)
        }
        let mismatched = Track(id: "other123456", title: "Other", artist: "Artist", contentKind: .song)
        #expect(SponsorBlockContext.make(track: mismatched, playback: identity, accountGeneration: generation) == nil)
    }
    @Test func offAndConsentAlonePerformNoLookupAndProgressNeverStartsOne() async {
        let fixture = SponsorBlockFixture(), model = fixture.model
        model.lookup()
        #expect(!model.isEnabled && !model.isWorking && model.preview == nil)
        await fixture.enable()
        #expect(model.isEnabled && !model.isWorking)
        for _ in 0..<100 { model.playbackChanged() }
        #expect(await fixture.service.calls == 0)
        await model.stop()
    }
    @Test func explicitPreviewHasImmutableTimingAndOnlyAnExplicitCurrentSectionSkipSeeksOnce() async throws {
        let fixture = SponsorBlockFixture(), model = fixture.model; await fixture.enable(); await fixture.lookup()
        let preview = try #require(model.preview), section = try #require(preview.sections.first)
        #expect(fixture.seeks.isEmpty && model.canSkip(section, previewID: preview.id))
        #expect(await model.skip(section, previewID: preview.id))
        #expect(fixture.seeks == [20] && model.preview == nil)
        #expect(!(await model.skip(section, previewID: preview.id)))
        #expect(fixture.seeks.count == 1)
        await model.stop()
    }
    @Test func unconfirmedOptionalSeekReportsOnlyItsOwnFailureAndNeverRetries() async throws {
        let fixture = SponsorBlockFixture(), model = fixture.model; await fixture.enable(); await fixture.lookup()
        let preview = try #require(model.preview), section = try #require(preview.sections.first)
        var attempts = 0
        model.performSeek = { _, _ in attempts += 1; return false }
        #expect(!(await model.skip(section, previewID: preview.id)))
        #expect(model.isEnabled && model.preview == nil && model.errorMessage != nil && fixture.seeks.isEmpty && attempts == 1)
        #expect(!(await model.skip(section, previewID: preview.id)))
        #expect(attempts == 1)
        await model.stop()
    }
    @Test func optionalSeekReplyHasOneBoundedOutcomeAndLateRepliesCannotRestartIt() async {
        let reply = SponsorBlockSeekReply()
        var starts = 0
        let result = await reply.wait(sleep: { }) { _ in starts += 1 }
        #expect(!result && starts == 1)
        reply.finish(true)
        let repeated = await reply.wait { _ in Issue.record("A completed seek reply must not dispatch again") }
        #expect(!repeated)
        let canceled = SponsorBlockSeekReply()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await canceled.wait { _ in Issue.record("Canceled optional seeks must never dispatch") }
        }
        #expect(!(await task.value))
    }
    @Test func everyAccountPlaybackIdentityDurationAndIntentChangeRejectsAnOldSkip() async throws {
        for change in 0..<8 {
            let fixture = SponsorBlockFixture(), model = fixture.model; await fixture.enable(); await fixture.lookup()
            let preview = try #require(model.preview), section = try #require(preview.sections.first)
            let old = preview.context.playback
            if change == 7 { fixture.context = nil }
            else {
                let identity = SponsorBlockPlaybackIdentity(
                    occurrence: change == 0 ? sponsorBlockIdentity().occurrence : old.occurrence,
                    loadID: change == 1 ? UUID() : old.loadID, documentID: change == 2 ? UUID() : old.documentID,
                    mediaGeneration: change == 3 ? old.mediaGeneration + 1 : old.mediaGeneration,
                    commandRevision: change == 4 ? old.commandRevision + 1 : old.commandRevision,
                    duration: change == 5 ? 101 : old.duration)
                fixture.context = .init(accountGeneration: change == 6 ? UUID() : preview.context.accountGeneration, playback: identity)
            }
            #expect(!(await model.skip(section, previewID: preview.id)))
            model.playbackChanged(); #expect(model.preview == nil && fixture.seeks.isEmpty)
            await model.stop()
        }
    }
    @Test func manualSkipRejectsExpiredPreviewAndPositionsOutsideTheSection() async throws {
        let fixture = SponsorBlockFixture(), model = fixture.model; await fixture.enable(); await fixture.lookup()
        let preview = try #require(model.preview), section = try #require(preview.sections.first)
        for position in [9.9, 20, 80, Double.nan] {
            fixture.position = position
            #expect(!(await model.skip(section, previewID: preview.id)))
        }
        fixture.position = 15; fixture.clock.advance(300)
        #expect(!(await model.skip(section, previewID: preview.id)))
        model.playbackChanged(); #expect(model.preview == nil)
        #expect(fixture.seeks.isEmpty)
        await model.stop()
    }
    @Test func cancelAndDisableKeepTheUnderlyingSlotUntilSettlementAndDiscardLateResults() async {
        let fixture = SponsorBlockFixture(), model = fixture.model; await fixture.enable(); await fixture.service.holdNext()
        model.lookup(); await fixture.service.waitForCall()
        model.interrupt(); fixture.clock.advance(31)
        for _ in 0..<100 { model.lookup() }
        #expect(model.isWorking && model.preview == nil)
        #expect(await fixture.service.calls == 1)
        model.quiesce()
        var started = false, stopped = false
        let stopping = Task { started = true; await model.stop(); stopped = true }
        while !started { await Task.yield() }
        #expect(!stopped && !model.isEnabled && !model.isAccountAvailable)
        await fixture.service.release(); await stopping.value
        #expect(stopped && !model.isWorking && model.preview == nil && fixture.seeks.isEmpty)
        model.bindAccount(fixture.account)
        #expect(!model.isEnabled)
    }
    @Test func changingRecordingDuringReadDiscardsItsResultsWithoutFetchingTheReplacement() async {
        let fixture = SponsorBlockFixture(), model = fixture.model; await fixture.enable(); await fixture.service.holdNext()
        model.lookup(); await fixture.service.waitForCall()
        fixture.context = .init(accountGeneration: UUID(), playback: sponsorBlockIdentity()); model.playbackChanged()
        await fixture.service.release(); await model.waitForIdle()
        #expect(model.preview == nil && fixture.seeks.isEmpty)
        #expect(await fixture.service.calls == 1)
        await model.stop()
    }
    @Test func changedCredentialsAndNewAccountCannotReuseConsentOrSeekAnOldPreview() async throws {
        let fixture = SponsorBlockFixture(), model = fixture.model; await fixture.enable(); await fixture.lookup()
        let preview = try #require(model.preview), section = try #require(preview.sections.first)
        await fixture.sessions.replaceSession(accountID: fixture.account, cookieHeader: "fixture=2", sapisid: "fixture-new")
        #expect(!(await model.skip(section, previewID: preview.id)))
        #expect(!model.isEnabled && model.preview == nil && fixture.seeks.isEmpty)
        model.bindAccount(String(repeating: "b", count: 64))
        #expect(!model.isEnabled && model.preview == nil)
        await model.stop()
    }
    @Test func relaunchAndAnotherProfileStartOffAndAnOldConsentTicketCannotEnableAfterQuiesce() async {
        let fixture = SponsorBlockFixture(), model = fixture.model; await fixture.enable()
        let ticket = model.scope; model.quiesce(); model.bindAccount(fixture.account)
        await model.enable(expectedScope: ticket)
        #expect(!model.isEnabled)
        let another = SponsorBlockSession(sessions: fixture.sessions, profileNamespace: "another.existing.profile", service: fixture.service)
        another.bindAccount(fixture.account); #expect(!another.isEnabled && another.preview == nil)
        #expect(await fixture.service.calls == 0)
        await model.stop(); await another.stop()
    }
    @Test func scopeChangesDuringConsentOrManualSkipAreRecheckedAfterSuspension() async throws {
        let fixture = SponsorBlockFixture(), gate = SponsorBlockSnapshotGate(store: fixture.sessions)
        fixture.sessionProvider = gate
        await fixture.sessions.replaceSession(accountID: fixture.account, cookieHeader: "fixture=1", sapisid: "fixture")
        let model = fixture.model; model.bindAccount(fixture.account)
        await gate.holdNext()
        let ticket = model.scope
        let enabling = Task { await model.enable(expectedScope: ticket) }
        await gate.waitForSnapshot(); model.quiesce()
        await gate.release(); await enabling.value
        #expect(!model.isEnabled)
        model.bindAccount(fixture.account); await model.enable(expectedScope: model.scope)
        await fixture.lookup()
        let preview = try #require(model.preview), section = try #require(preview.sections.first)
        await gate.holdNext()
        let skipping = Task { await model.skip(section, previewID: preview.id) }
        await gate.waitForSnapshot(); fixture.context = nil
        await gate.release()
        #expect(!(await skipping.value) && fixture.seeks.isEmpty)
        await model.stop()
    }
    @Test func nativeProfileHooksAndDedicatedOutputInterruptionsClearWithoutProviderOrPlaybackCalls() async throws {
        let preferences = SceneCheckPreferences(); defer { preferences.remove() }
        let transport = SceneCheckTransport(), service = SponsorBlockTestService()
        var configuration = AppSessionConfiguration.sceneCheck(preferences: preferences.defaults, transport: transport)
        configuration.profileNamespace = "test.existing.profile"; configuration.sponsorBlockClient = service
        let account = String(repeating: "a", count: 64)
        await configuration.credentials.replaceSession(accountID: account, cookieHeader: "fixture=1", sapisid: "fixture")
        let session = AppSession(configuration: configuration), model = try #require(session.sponsorBlock)
        session.account.onAccountConfirmed?(account); await model.enable(expectedScope: model.scope)
        session.queue.replace(with: [sponsorBlockSong()], startAt: 0)
        let occurrence = try #require(session.queue.currentOccurrence)
        let identity = SponsorBlockPlaybackIdentity(occurrence: occurrence, loadID: UUID(), documentID: UUID(), mediaGeneration: 1, commandRevision: 1, duration: 100)
        let context = SponsorBlockContext(accountGeneration: session.accountGeneration, playback: identity)
        model.currentContext = { context }; model.currentPosition = { 15 }
        model.lookup(); await model.waitForIdle(); #expect(model.preview != nil)
        session.player.onListeningInterrupted?(occurrence); #expect(model.preview != nil)
        session.player.onPlaybackOutputInterrupted?(occurrence); #expect(model.preview == nil)
        session.quiesceForProfileSwitch(); await session.settleForProfileSwitch()
        #expect(!model.isEnabled && !model.isAccountAvailable)
        session.resumePausedProfileOwnership(); #expect(!model.isEnabled && !session.wantsPlayback)
        await session.shutdown()
        #expect(await service.calls == 1)
        #expect(await transport.attempts == 0)
    }
    @Test func nativeLanguageTablesContainAllStaticCopyAndMatchWithoutRealPreferences() throws {
        var values: [[String: String]] = []
        for language in ["en", "fr"] {
            let folder = try #require(AppLocalization.bundle.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: folder)), url = try #require(bundle.url(forResource: "SponsorBlock", withExtension: "strings"))
            values.append(try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String]))
        }
        #expect(Set(values[0].keys) == Set(values[1].keys) && values[0].count == 28)
        #expect(values[1].values.allSatisfy { !$0.isEmpty })
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources/YTMusicMac/SponsorBlock", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let expression = try NSRegularExpression(pattern: #"SponsorBlockText\.text\("([^"]+)"\)"#)
        var lookups = Set<String>()
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                if let range = Range(match.range(at: 1), in: source) { lookups.insert(String(source[range])) }
            }
        }
        #expect(lookups == Set(values[0].keys))
    }
}
