import Foundation
import MusicCore
import Testing
import YouTubeMusic
import WebKit
@testable import YTMusicMac

@MainActor @Suite("Session transport and source handoff")
struct PlaybackControllerTests {
    @Test func frozenSourceSelectionUsesFreshPlaybackProofAfterOrdinaryProgress() async throws {
        let f = TransportFixture(controlledWeb: true)
        f.current = f.remoteOccurrence(); f.player.load(track: f.remoteTrack, occurrence: f.current!)
        await f.player.waitForPreparation()
        let web = try #require(f.webDrivers.first); web.acknowledge(position: 15, playing: true)
        let old = try #require(web.confirmedTimestampIdentity)
        let reference = try #require(MusicEpisodeDetailsReference(identity: .init(browseID: "MPEDfixture"), videoID: f.remoteTrack.id))
        let selected = EpisodeTimestampActionTarget(details: .init(profile: f.ownerProfile, account: f.account,
            queueRevision: PlaybackQueue().revision, entry: f.entry, occurrence: f.current, reference: reference),
            source: .init(requestID: UUID(), reference: reference, sourceIndex: 3, seconds: 30))
        web.acknowledge(position: 16, playing: true, kind: "progress")
        let latest = try #require(web.confirmedTimestampIdentity); #expect(latest != old)
        let admitted = try #require(selected.playbackTarget(isCurrent: { true }, freshProof: { f.player.timestampSeekTarget(position: 30) }))
        #expect(admitted.request.identity == latest)
        var outcome: WebTimestampSeekOutcome?
        f.player.seekTimestamp(admitted) { outcome = $0 }
        #expect(web.actions.contains(.timestamp(30)) && outcome == nil)
        web.finishTimestamp(.rejected); #expect(outcome == .rejected && f.player.isPlaying)
        var freshCalls = 0
        let refused = selected.playbackTarget(isCurrent: { false }, freshProof: { freshCalls += 1; return admitted })
        #expect(refused == nil && freshCalls == 0)
        f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
    }

    @Test func timestampRetargetPreservesPlayingAndOnlyExactNewAcknowledgmentCanConfirm() async throws {
        let f = TransportFixture(controlledWeb: true)
        f.current = f.remoteOccurrence(); f.player.load(track: f.remoteTrack, occurrence: f.current!)
        await f.player.waitForPreparation()
        let web = try #require(f.webDrivers.first); web.acknowledge(position: 15, playing: true)
        let old = try #require(web.currentOutputContext), target = try #require(f.player.timestampSeekTarget(position: 30))
        let oldPosition = f.player.clock.position
        var result: WebTimestampSeekOutcome?
        f.player.seekTimestamp(target) { result = $0 }
        #expect(web.actions.filter { $0 == .timestamp(30) }.count == 1 && web.timestampSeekIsBusy)
        #expect(f.player.errorMessage == nil && f.player.isPlaying && f.player.clock.position == oldPosition && result == nil)
        web.onOutputEvent?(.init(context: old, kind: .ended)); #expect(f.ended.isEmpty)
        #expect(f.player.timestampSeekTarget(position: 45) == nil)
        web.finishTimestamp(.confirmed(30))
        #expect(result == .confirmed(30) && !web.timestampSeekIsBusy && f.player.clock.position == oldPosition)
        f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
    }
    @Test func staleTimestampAndUnconfirmedReceiptNeverFailOrRetirePlayback() async throws {
        for change in 0..<4 {
            let f = TransportFixture(controlledWeb: true)
            f.current = f.remoteOccurrence(); f.player.load(track: f.remoteTrack, occurrence: f.current!)
            await f.player.waitForPreparation()
            let web = try #require(f.webDrivers.first); web.acknowledge(position: 15, playing: true)
            let target = try #require(f.player.timestampSeekTarget(position: 30)); var result: WebTimestampSeekOutcome?
            if change == 0 { f.player.pause() }
            if change == 1 { f.current = f.remoteOccurrence(generation: 2) }
            f.player.seekTimestamp(target) { result = $0 }
            if change < 2 {
                #expect(result == .rejected && !web.actions.contains(.timestamp(30)))
            } else {
                if change == 3 { f.player.pause() }
                web.finishTimestamp(.rejected)
                #expect(result == (change == 3 ? .unconfirmed : .rejected))
            }
            #expect(f.player.errorMessage == nil && !web.isOutputRetired && f.ended.isEmpty)
            f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
        }
    }

    @Test func playDuringAnUnacknowledgedPausedWebLoadAppliesTheLatestIntent() async throws {
        let f = TransportFixture(controlledWeb: true)
        f.current = f.remoteOccurrence()
        f.player.load(track: f.remoteTrack, occurrence: f.current!, autoplay: false)
        await f.player.waitForPreparation()
        let web = try #require(f.webDrivers.first)
        web.automaticallyAcknowledgesCommands = true
        f.player.play()
        #expect(!web.actions.contains(.play))
        web.acknowledge(playing: false)
        #expect(web.actions.filter { $0 == .play }.count == 1)
        #expect(f.player.playbackIntent && f.player.isPlaying && !f.player.isPreparing)
        f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
    }

    @Test func pauseThenPlayAndMuteDuringWebPreparationDoNotLoseTheLatestControls() async throws {
        let f = TransportFixture(controlledWeb: true)
        f.current = f.remoteOccurrence()
        f.player.load(track: f.remoteTrack, occurrence: f.current!)
        await f.player.waitForPreparation()
        let web = try #require(f.webDrivers.first)
        f.player.pause(); f.player.play(); f.player.setVolume(0)
        #expect(web.actions.contains(.volume(0)) && web.volume == 0)
        web.automaticallyAcknowledgesCommands = true
        web.acknowledge(playing: false)
        #expect(web.actions.filter { $0 == .play }.count == 1)
        #expect(f.player.playbackIntent && f.player.isPlaying && f.player.volume == 0)
        f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
    }

    @Test func webPauseRejectsEveryPrePauseProgressAndEndContextUntilTheNewCommandAcknowledges() async throws {
        let f = TransportFixture(controlledWeb: true)
        f.current = f.remoteOccurrence()
        f.player.load(track: f.remoteTrack, occurrence: f.current!)
        await f.player.waitForPreparation()
        let web = try #require(f.webDrivers.first)
        web.acknowledge(playing: true)
        let old = try #require(web.currentOutputContext)
        var progress = 0
        f.player.onVerifiedContentProgress = { _, _, _, _ in progress += 1 }
        f.player.pause()
        #expect(web.currentOutputContext == nil && web.requestedOutputContext != old)
        web.onOutputEvent?(.init(context: old, kind: .progress(position: 20, duration: 180, ended: false)))
        web.onOutputEvent?(.init(context: old, kind: .ended))
        #expect(progress == 0 && f.ended.isEmpty && !f.player.playbackIntent)
        web.acknowledge(playing: false)
        #expect(!f.player.isPlaying && !f.player.playbackIntent && f.ended.isEmpty)
        f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
    }

    @Test func webRecoveryInterruptsImmediatelyAndOnlyTheNewAcknowledgedLoadCanPublish() async throws {
        let f = TransportFixture(controlledWeb: true)
        f.current = f.remoteOccurrence()
        f.player.load(track: f.remoteTrack, occurrence: f.current!)
        await f.player.waitForPreparation()
        let web = try #require(f.webDrivers.first)
        web.acknowledge(position: 20, playing: true)
        let old = try #require(web.currentOutputContext)
        var interruptions = 0
        f.player.onPlaybackOutputInterrupted = { _ in interruptions += 1 }
        f.player.onRecoveryRequested = { _, _ in 42 }
        #expect(web.requestRecovery(position: 20))
        #expect(!f.player.isPlaying && f.player.isPreparing && interruptions == 1)
        web.onOutputEvent?(.init(context: old, kind: .ended))
        #expect(f.ended.isEmpty)
        web.acknowledge(position: 42, playing: true)
        #expect(f.player.isPlaying && !f.player.isPreparing && f.player.clock.position == 42)
        f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
    }

    @Test func canceledLocalPreparationCannotHoldWebOutputAfterTheActualEngineIsQuiet() async throws {
        let f = TransportFixture(controlledWeb: true), gate = TransportPreparationGate()
        f.prepareGate = gate
        f.current = f.occurrence(); f.player.load(track: f.track, occurrence: f.current!)
        await gate.waitStarted()
        #expect(f.engine.holds.count == 1 && f.engine.factory.drivers.isEmpty)
        f.current = f.remoteOccurrence(generation: 2)
        f.player.load(track: f.remoteTrack, occurrence: f.current!)
        await f.player.waitForPreparation()
        #expect(f.webDrivers.count == 2 && f.webDrivers[1].actions.contains(.load(f.current!, autoplay: true)))
        #expect(f.engine.holds.count == 1 && f.engine.factory.drivers.isEmpty)
        f.webDrivers[1].acknowledge(playing: true)
        #expect(f.player.isPlaying)
        gate.release()
        for _ in 0..<16 { await Task.yield() }
        #expect(f.engine.holds.count == 0 && f.player.isPlaying && f.engine.factory.drivers.isEmpty)
        f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
    }

    @Test func ordinaryLocalClockUpdatesDoNotRepublishUnchangedTransportState() async throws {
        let f = TransportFixture()
        f.current = f.occurrence(); f.player.load(track: f.track, occurrence: f.current!)
        await f.player.waitForPreparation()
        let driver = f.engine.factory.driver
        var notifications = 0
        f.player.onStateChanged = { notifications += 1 }
        for second in [10.0, 11.0, 12.0] {
            driver.frame.position = second; driver.emit(.state(driver.snapshot))
        }
        #expect(notifications == 0 && f.player.clock.elapsedSeconds == 12 && f.player.isPlaying)
        f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
    }

    @Test func volumeAndPauseDoNotDiscardAnInFlightLocalSeek() async throws {
        let f = TransportFixture()
        f.current = f.occurrence(); f.player.load(track: f.track, occurrence: f.current!)
        await f.player.waitForPreparation()
        let driver = f.engine.factory.driver; driver.autoSeek = false
        f.player.seek(to: 30)
        await driver.waitSeek()
        f.player.setVolume(0.2); f.player.pause()
        driver.frame.position = 30; driver.seekCompletion?(true)
        for _ in 0..<8 { await Task.yield() }
        #expect(f.player.clock.position == 30 && !f.player.playbackIntent && !f.player.isPlaying)
        #expect(f.player.errorMessage == nil && driver.calls.filter { $0 == "play" }.count == 1)
        f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
    }

    @Test func pauseDuringPreparationInstallsPausedAndOnlyAnExplicitPlayStartsOutput() async throws {
        let f = TransportFixture()
        let gate = TransportPreparationGate()
        f.prepareGate = gate
        let occurrence = f.occurrence()
        f.current = occurrence
        f.player.load(track: f.track, occurrence: occurrence)
        await gate.waitStarted()
        f.player.pause()
        gate.release()
        await f.player.waitForPreparation()
        #expect(!f.player.playbackIntent && !f.player.isPlaying)
        #expect(f.engine.factory.driver.current != nil)
        #expect(!f.engine.factory.driver.calls.contains("play"))
        f.player.play()
        #expect(f.engine.factory.driver.calls.filter { $0 == "play" }.count == 1)
        f.player.quiesce()
        #expect(await f.player.settleOutput() == .quiet)
    }

    @Test func supersededPreparationCannotStartOutputForTheOldOccurrence() async throws {
        let f = TransportFixture()
        let gate = TransportPreparationGate()
        f.prepareGate = gate
        let first = f.occurrence(), second = f.occurrence(generation: 2)
        f.current = first; f.player.load(track: f.track, occurrence: first)
        await gate.waitStarted()
        f.current = second; f.player.load(track: f.track, occurrence: second)
        f.prepareGate = nil; gate.release()
        await f.player.waitForPreparation()
        #expect(f.preparedScopes.last?.occurrence == second)
        #expect(f.engine.factory.driver.calls.filter { $0 == "play" }.count == 1)
        #expect(f.player.playbackIntent)
        f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
    }

    @Test func staleEndCannotAdvanceAfterTheCurrentOccurrenceChanges() async throws {
        let f = TransportFixture()
        let first = f.occurrence()
        f.current = first; f.player.load(track: f.track, occurrence: first)
        await f.player.waitForPreparation()
        let driver = f.engine.factory.driver
        let oldCallback = try #require(driver.history.last)
        let oldSnapshot = driver.snapshot
        f.current = f.occurrence(generation: 2)
        var ending = oldSnapshot; ending.position = ending.duration
        oldCallback(.ended(ending))
        #expect(f.ended.isEmpty)
        f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
    }

    @Test func canceledCrossSourceRetirementDoesNotPermanentlyPoisonLaterLocalRequests() async throws {
        let f = TransportFixture()
        f.current = f.occurrence(); f.player.load(track: f.track, occurrence: f.current!)
        await f.player.waitForPreparation()
        let driver = f.engine.factory.driver; driver.refuseQuiet = true
        let remote = Track(id: "abcDEF12_-3", title: "Service fixture", artist: "Artist", contentKind: .song)
        f.current = .init(sessionID: f.queue, entryID: f.entry, trackID: remote.id, generation: 2)
        f.player.load(track: remote, occurrence: f.current!)
        await f.engine.clock.waitForSleep()
        f.current = f.occurrence(generation: 3)
        f.player.load(track: f.track, occurrence: f.current!)
        await f.player.waitForPreparation()
        #expect(!f.player.playbackIntent && f.webInstances == 1)
        driver.refuseQuiet = false; driver.frame.control = .paused; driver.frame.rate = 0; driver.frame.muted = true
        driver.signalOutput()
        #expect(!f.player.playbackIntent)
        f.current = f.occurrence(generation: 4)
        f.player.load(track: f.track, occurrence: f.current!)
        await f.player.waitForPreparation()
        #expect(f.engine.factory.drivers.count == 2 && f.webInstances == 1)
        #expect(f.player.playbackIntent && f.engine.factory.drivers[1].calls.contains("play"))
        f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
    }

    @Test func anUnboundStartupViewMustRetireBeforeEvenAReplacementWebEngineCanActivate() async throws {
        let f = TransportFixture(); f.holdWebRetirement = true
        f.current = f.occurrence(); f.player.load(track: f.track, occurrence: f.current!)
        await f.waitWebRetirement()
        let remote = Track(id: "abcDEF12_-3", title: "Service fixture", artist: "Artist", contentKind: .song)
        f.current = .init(sessionID: f.queue, entryID: f.entry, trackID: remote.id, generation: 2)
        f.player.load(track: remote, occurrence: f.current!)
        await f.player.waitForPreparation()
        #expect(f.webInstances == 1 && f.engine.factory.drivers.isEmpty)
        #expect(!f.player.playbackIntent && f.player.errorMessage != nil)
        #expect(f.player.webView.url == nil && !f.player.webView.isLoading)
        f.webTargets[0].release()
        #expect(!f.player.playbackIntent && f.webInstances == 1)
        f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
    }

    @Test func rejectedOutputReceiptBlocksReplacementAndALateQuietProofAllowsOnlyANewRequest() async throws {
        let f = TransportFixture()
        let first = f.occurrence()
        f.current = first; f.player.load(track: f.track, occurrence: first)
        await f.player.waitForPreparation()
        let driver = f.engine.factory.driver
        driver.refuseQuiet = true
        f.player.stop()
        await f.engine.clock.waitForSleep(); await f.engine.clock.fire()
        #expect(await f.player.settleOutput() == .blocked(.unconfirmed))
        let second = f.occurrence(generation: 2)
        f.current = second; f.player.load(track: f.track, occurrence: second)
        await f.player.waitForPreparation()
        #expect(f.engine.factory.drivers.count == 1 && !f.player.playbackIntent)
        driver.refuseQuiet = false; driver.frame.control = .paused; driver.frame.rate = 0; driver.frame.muted = true
        driver.signalOutput()
        #expect(!f.player.playbackIntent)
        f.current = f.occurrence(generation: 3)
        f.player.load(track: f.track, occurrence: f.current!)
        await f.player.waitForPreparation()
        #expect(f.engine.factory.drivers.count == 2)
        #expect(f.engine.factory.drivers[1].calls.filter { $0 == "play" }.count == 1)
        f.player.quiesce(); #expect(await f.player.settleOutput() == .quiet)
    }
}

/// Empty, nonpersistent baseline web objects are never loaded. Every new media
/// retirement call is replaced by this fake; local output uses only fake drivers.
@MainActor private final class TransportFixture {
    let engine = LocalAudioEngineFixture()
    let ownerProfile = UUID(), account = UUID(), queue = UUID(), entry = UUID()
    var current: PlaybackOccurrence?
    var prepareGate: TransportPreparationGate?
    var preparedScopes: [PlaybackOutputScope] = []
    var ended: [PlaybackOccurrence] = []
    var holdWebRetirement = false
    var webInstances = 0
    var webDrivers: [ControlledWebPlaybackTransport] = []
    var webTargets: [TransportRetirementTarget] = []
    private var retirementWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var player: PlaybackController!
    var track: Track { try! LocalAudioMetadata(title: "Fixture", artist: "Artist", duration: 120, byteCount: 512).track(reference: engine.reference) }
    init(controlledWeb: Bool = false) {
        let engine = engine
        let local = LocalAudioPlaybackConfiguration(profileStorageID: engine.profileID, prepare: { [weak self] _, scope, _, resume in
            guard let self else { return .failure(.stale) }
            self.preparedScopes.append(scope)
            engine.owner.scope = scope
            do {
                let value = try await engine.prepared(scope, resume: resume)
                if let gate = self.prepareGate { await gate.wait() }
                return .success(value)
            } catch { return .failure(.sanitizing(error)) }
        }, makeEngine: { bind, accepts in
            LocalAudioPlayerEngine(profileStorageID: engine.profileID, factory: { engine.factory.make($0) },
                bindEvents: bind, acceptsEvent: accepts, sleep: { try await engine.clock.sleep() })
        })
        player = PlaybackController(dataStore: .nonPersistent(), admission: PlaybackOutputAdmission(), outputIsEnabled: true,
            local: local, webFactory: { [weak self] in
                self?.webInstances += 1
                let host = WebPlayer(dataStore: .nonPersistent(), retirementTargetFactory: { [weak self] _, id, _ in
                    let target = TransportRetirementTarget(id, held: self?.holdWebRetirement == true)
                    self?.webTargets.append(target)
                    let waiting = self?.retirementWaiters ?? []; self?.retirementWaiters = []; waiting.forEach { $0.resume() }
                    return target
                }, retirementSleep: { try await engine.clock.sleep() })
                if controlledWeb {
                    let transport = ControlledWebPlaybackTransport(instanceID: host.outputInstanceID)
                    self?.webDrivers.append(transport)
                    return WebPlaybackInstance(host: host, transport: transport)
                }
                return WebPlaybackInstance(host: host)
            })
        player.owner = { [weak self] in self.map { .init(profile: $0.ownerProfile, account: $0.account) } }
        player.acceptsOccurrence = { [weak self] in self?.current == $0 }
        player.onEnded = { [weak self] in self?.ended.append($0) }
    }
    func waitWebRetirement() async {
        if webTargets.isEmpty { await withCheckedContinuation { retirementWaiters.append($0) } }
    }
    var remoteTrack: Track { Track(id: "abcDEF12_-3", title: "Service fixture", artist: "Artist", contentKind: .song) }
    func remoteOccurrence(generation: UInt64 = 1) -> PlaybackOccurrence {
        .init(sessionID: queue, entryID: entry, trackID: remoteTrack.id, generation: generation)
    }
    func occurrence(generation: UInt64 = 1) -> PlaybackOccurrence {
        .init(sessionID: queue, entryID: entry, trackID: engine.reference.trackID, generation: generation)
    }
}
@MainActor private final class TransportRetirementTarget: PlaybackViewRetirementTarget {
    let retirementID: UUID
    private var held: Bool
    private var suspended: (() -> Void)?
    init(_ id: UUID, held: Bool = false) { retirementID = id; self.held = held }
    func suspend(_ completion: @escaping @MainActor () -> Void) { if held { suspended = completion } else { completion() } }
    func release() { held = false; let action = suspended; suspended = nil; action?() }
    func closePresentations(_ completion: @escaping @MainActor () -> Void) { completion() }
    func mediaState(_ completion: @escaping @MainActor (RetiredMediaState) -> Void) { completion(.suspended) }
}
@MainActor private final class TransportPreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation = $0; let waiting = observers; observers = []; waiting.forEach { $0.resume() } }
    }
    func waitStarted() async { if continuation == nil { await withCheckedContinuation { observers.append($0) } } }
    func release() { let waiting = continuation; continuation = nil; waiting?.resume() }
}
