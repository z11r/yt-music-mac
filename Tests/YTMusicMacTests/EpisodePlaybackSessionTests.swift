import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@MainActor struct EpisodePlaybackSessionTests {
    private let firstHash = String(repeating: "a", count: 64)
    private let secondHash = String(repeating: "b", count: 64)
    private var track: Track {
        Track(id: "abcDEF12_-3", title: "Episode", artist: "Show", duration: 3_600, contentKind: .podcastEpisode,
              episode: .init(identity: .init(browseID: "MPEDcanonical"), serviceProgressFraction: 0.9))
    }

    @Test func disabledPersistenceKeepsUsefulSessionProgressWithoutLoadingOrSaving() async {
        let ledger = ProgressLedger()
        let session = model(ledger)
        session.setPersistenceEnabled(false)
        session.bindAccount(firstHash); await session.waitUntilLoaded()
        let occurrence = occurrence()
        session.begin(track: track, occurrence: occurrence)
        session.record(occurrence: occurrence, position: 70, duration: 3_600, confirmedContent: true)
        #expect(session.resumePosition(for: track) == 70)
        #expect(!(await session.flush()))
        #expect(await ledger.loads == 0)
        #expect(await ledger.writes.isEmpty)
        _ = session.detachAccount()
        #expect(await ledger.writes.isEmpty)
    }

    @Test func optingInMergesNewMemoryProgressWithRetainedStoredProgress() async {
        let ledger = ProgressLedger(initial: [firstHash: snapshot(firstHash, position: 30)])
        let session = model(ledger)
        session.setPersistenceEnabled(false)
        session.bindAccount(firstHash)
        let occurrence = occurrence()
        session.begin(track: track, occurrence: occurrence)
        session.record(occurrence: occurrence, position: 80, duration: 3_600, confirmedContent: true)
        session.setPersistenceEnabled(true)
        await session.waitUntilLoaded()
        #expect(session.resumePosition(for: track) == 80)
        #expect(await session.flush())
        #expect(await ledger.writes.last?.records.first?.position == 80)
        session.setPersistenceEnabled(false)
        session.record(occurrence: occurrence, position: 90, duration: 3_600, confirmedContent: true)
        #expect(session.resumePosition(for: track) == 90)
        let count = await ledger.writes.count
        #expect(!(await session.flush()))
        #expect(await ledger.writes.count == count)
    }

    @Test func sameAccountRebindWaitsForFinalSaveAndContinuesWithoutABookmarkSeek() async throws {
        let store = RebindProgressLedger(snapshot(firstHash, position: 120))
        let session = EpisodePlaybackSession(load: { await store.load($0) }, save: { await store.save($0) }, saveDelay: .seconds(60))
        session.bindAccount(firstHash); await session.waitUntilLoaded()
        let current = occurrence()
        session.begin(track: track, occurrence: current)
        session.record(occurrence: current, position: 130, duration: 3_600, confirmedContent: true)
        let continuation = try #require(session.continuationForRebind())
        let saving = session.detachAccount()
        await store.waitForSave()
        session.bindAccount(firstHash)
        for _ in 0..<5 { await Task.yield() }
        #expect(await store.loads == 1)
        #expect(session.isLoading)
        await store.finishSave()
        #expect(await saving?.value == true)
        await session.waitUntilLoaded()
        #expect(session.resumePosition(for: track) == 130)
        #expect(session.restoreContinuation(continuation))
        session.record(occurrence: current, position: 30, duration: 3_600, confirmedContent: true)
        #expect(session.resumePosition(for: track) == 30)
        #expect(!session.bindAccount(firstHash))
        session.record(occurrence: current, position: 31, duration: 3_600, confirmedContent: true)
        #expect(session.resumePosition(for: track) == 31)
        let finalSave = session.detachAccount()
        await store.waitForSave()
        await store.finishSave()
        #expect(await finalSave?.value == true)
    }

    @Test func continuationCannotReplaceANewerRequestOrAnotherAccount() async throws {
        let session = model(ProgressLedger(initial: [firstHash: snapshot(firstHash, position: 120)]))
        session.bindAccount(firstHash); await session.waitUntilLoaded()
        let original = occurrence()
        session.begin(track: track, occurrence: original)
        session.record(occurrence: original, position: 125, duration: 3_600, confirmedContent: true)
        let continuation = try #require(session.continuationForRebind())
        _ = session.detachAccount()
        session.bindAccount(firstHash); await session.waitUntilLoaded()
        let replacement = occurrence()
        session.begin(track: track, occurrence: replacement)
        #expect(!session.restoreContinuation(continuation))
        session.record(occurrence: original, position: 200, duration: 3_600, confirmedContent: true)
        session.record(occurrence: replacement, position: 1, duration: 3_600, confirmedContent: true)
        #expect(session.resumePosition(for: track) == 120)
        session.bindAccount(secondHash); await session.waitUntilLoaded()
        #expect(!session.restoreContinuation(continuation))
    }

    @Test func confirmedLocalProgressRejectsPlaceholdersAndStaleOccurrences() async throws {
        let ledger = ProgressLedger(initial: [firstHash: snapshot(firstHash, position: 120)])
        let session = model(ledger)
        session.bindAccount(firstHash); await session.waitUntilLoaded()
        let occurrence = occurrence()
        session.begin(track: track, occurrence: occurrence)
        session.record(occurrence: occurrence, position: 200, duration: 3_600, confirmedContent: false)
        session.record(occurrence: occurrence, position: 0, duration: 3_600, confirmedContent: true)
        session.record(occurrence: occurrence, position: 1, duration: 3_600, confirmedContent: true)
        session.record(occurrence: self.occurrence(), position: 300, duration: 3_600, confirmedContent: true)
        #expect(session.resumePosition(for: track) == 120)
        session.record(occurrence: occurrence, position: 125, duration: 3_600, confirmedContent: true)
        #expect(session.resumePosition(for: track) == 125)
        session.allowExplicitSeek()
        session.record(occurrence: occurrence, position: 25, duration: 3_600, confirmedContent: true)
        #expect(session.resumePosition(for: track) == 25)
        #expect(await session.flush())
        #expect(await ledger.writes.last?.records.first?.position == 25)
    }

    @Test func servicePercentAndSongPlaybackNeverCreateLocalEpisodeHistory() async {
        let ledger = ProgressLedger()
        let session = model(ledger)
        session.bindAccount(firstHash); await session.waitUntilLoaded()
        let occurrence = occurrence()
        session.begin(track: track, occurrence: occurrence)
        #expect(session.progress(for: track) == nil)
        #expect(session.resumePosition(for: track) == 0)
        session.begin(track: Track(id: track.id, title: "Song", artist: "Artist"), occurrence: occurrence)
        session.record(occurrence: occurrence, position: 50, duration: 3_600, confirmedContent: true)
        #expect(session.progress(for: track) == nil)
    }

    @Test func completionRequiresAConfirmedEndAndStartOverIsExplicit() async {
        let ledger = ProgressLedger()
        let session = model(ledger)
        session.bindAccount(firstHash); await session.waitUntilLoaded()
        let occurrence = occurrence()
        session.begin(track: track, occurrence: occurrence)
        session.record(occurrence: occurrence, position: 3_599, duration: 3_600, confirmedContent: true)
        #expect(session.progress(for: track)?.completed == false)
        session.record(occurrence: occurrence, position: 3_600, duration: 3_600, confirmedContent: true, ended: true)
        #expect(session.progress(for: track)?.completed == true)
        #expect(session.resumePosition(for: track) == 0)
        session.startOver(track)
        #expect(session.progress(for: track) == nil)
        #expect(await session.flush())
        #expect(await ledger.writes.last?.records.isEmpty == true)
    }

    @Test func accountChangesFenceLoadsSamplesAndCapturedFinalSaves() async throws {
        let loader = DeferredProgressLoader()
        let ledger = ProgressLedger()
        let session = EpisodePlaybackSession(load: { await loader.load($0) }, save: { await ledger.save($0) })
        session.bindAccount(firstHash)
        await loader.waitForRequest(firstHash)
        session.bindAccount(secondHash)
        await loader.waitForRequest(secondHash)
        await loader.finish(secondHash, value: snapshot(secondHash, position: 200))
        await session.waitUntilLoaded()
        await loader.finish(firstHash, value: snapshot(firstHash, position: 100))
        #expect(session.resumePosition(for: track) == 200)
        let occurrence = occurrence()
        session.begin(track: track, occurrence: occurrence)
        session.record(occurrence: occurrence, position: 210, duration: 3_600, confirmedContent: true)
        let finalSave = session.detachAccount()
        #expect(session.progress(for: track) == nil)
        session.record(occurrence: occurrence, position: 220, duration: 3_600, confirmedContent: true)
        #expect(await finalSave?.value == true)
        #expect(await ledger.writes.last?.accountHash == secondHash)
        #expect(await ledger.writes.last?.records.first?.position == 210)
    }

    @Test func failedLoadsDoNotEraseOrOverwriteExistingStorage() async {
        let ledger = ProgressLedger()
        let session = EpisodePlaybackSession(load: { _ in throw EpisodeProgressError.unsupportedVersion }, save: { await ledger.save($0) })
        session.bindAccount(firstHash); await session.waitUntilLoaded()
        let occurrence = occurrence()
        session.begin(track: track, occurrence: occurrence)
        session.record(occurrence: occurrence, position: 50, duration: 3_600, confirmedContent: true)
        #expect(session.errorMessage != nil)
        #expect(!(await session.flush()))
        #expect(await ledger.writes.isEmpty)
    }

    @Test func skipSettingsPersistAndSeekTargetsRemainEpisodeOnlyAndBounded() async {
        let ledger = ProgressLedger()
        let session = model(ledger)
        session.bindAccount(firstHash); await session.waitUntilLoaded()
        session.setSkipIntervals(backward: 15, forward: 45)
        session.setSkipIntervals(backward: -5, forward: 500)
        #expect(session.settings == EpisodePlaybackSettings(skipBackward: 15, skipForward: 45))
        #expect(await session.flush())
        #expect(await ledger.writes.last?.settings == session.settings)
        #expect(EpisodeSkip.target(track: track, position: 5, duration: 100, offset: -15, positionConfirmed: true) == 0)
        #expect(EpisodeSkip.target(track: track, position: 95, duration: 100, offset: 45, positionConfirmed: true) == 100)
        #expect(EpisodeSkip.target(track: track, position: 10, duration: 100, offset: 15, positionConfirmed: false) == nil)
        #expect(EpisodeSkip.target(track: track, position: 10, duration: 0, offset: 15, positionConfirmed: true) == nil)
        #expect(EpisodeSkip.target(track: Track(id: track.id, title: "Song", artist: "Artist"), position: 10, duration: 100, offset: 15, positionConfirmed: true) == nil)
    }

    @Test func ratesRequireAReportedCapabilityVerifiedEpisodeAndConfirmedCommand() async {
        let session = model(ProgressLedger())
        session.bindAccount(firstHash); await session.waitUntilLoaded()
        let occurrence = occurrence()
        session.begin(track: track, occurrence: occurrence)
        session.reportRates([1, 1.5, 2], current: 1, occurrence: occurrence)
        #expect(!session.canControlRate)
        let rates = TestEpisodeRates()
        session.rateController = rates
        session.record(occurrence: occurrence, position: 10, duration: 3_600, confirmedContent: true)
        session.reportRates([1, 1.5, 2], current: 1, occurrence: occurrence)
        #expect(session.canControlRate)
        #expect(!(await session.setRate(3)))
        #expect(!(await session.setRate(1.5, expectedOccurrence: self.occurrence())))
        #expect(rates.calls.isEmpty)
        rates.result = false
        #expect(!(await session.setRate(1.5)))
        #expect(session.currentRate == 1)
        rates.result = true
        #expect(await session.setRate(1.5))
        #expect(session.currentRate == 1.5)
        session.reportRates([], current: 1.5, occurrence: occurrence)
        #expect(!session.canControlRate)
    }

    @Test func aLateRateResultCannotChangeASupersedingEpisodeOrSong() async {
        let session = model(ProgressLedger())
        session.bindAccount(firstHash); await session.waitUntilLoaded()
        let occurrence = occurrence()
        session.begin(track: track, occurrence: occurrence)
        session.record(occurrence: occurrence, position: 10, duration: 3_600, confirmedContent: true)
        session.reportRates([1, 2], current: 1, occurrence: occurrence)
        let rates = TestEpisodeRates(); rates.suspends = true
        session.rateController = rates
        let task = Task { await session.setRate(2) }
        while rates.pending == nil { await Task.yield() }
        session.begin(track: Track(id: "song", title: "Song", artist: "Artist"), occurrence: self.occurrence())
        rates.finish(true)
        #expect(!(await task.value))
        #expect(session.currentRate == nil)
        #expect(!session.canControlRate)
    }

    @Test func profileSuspensionRevokesPendingRateAndRequiresFreshContentBeforeRollbackControls() async {
        let session = model(ProgressLedger())
        session.bindAccount(firstHash); await session.waitUntilLoaded()
        let occurrence = occurrence()
        session.begin(track: track, occurrence: occurrence)
        session.record(occurrence: occurrence, position: 10, duration: 3_600, confirmedContent: true)
        session.reportRates([1, 2], current: 1, occurrence: occurrence)
        let rates = TestEpisodeRates(); rates.suspends = true
        session.rateController = rates
        let task = Task { await session.setRate(2) }
        while rates.pending == nil { await Task.yield() }
        session.suspendProfileOwnership()
        #expect(!session.isRatePending && !session.canControlRate && !session.canRefreshRate)
        session.reportRates([1, 2], current: 2, occurrence: occurrence)
        session.refreshRates()
        session.resumeProfileOwnership()
        rates.finish(true)
        #expect(!(await task.value))
        #expect(session.currentRate == nil && !session.canControlRate && !session.canRefreshRate)
        session.reportRates([1, 2], current: 2, occurrence: occurrence)
        #expect(session.currentRate == nil)
        session.record(occurrence: occurrence, position: 11, duration: 3_600, confirmedContent: true)
        session.reportRates([1, 2], current: 1, occurrence: occurrence)
        #expect(session.canControlRate && session.currentRate == 1)
    }

    @Test func bridgeSamplesExcludeAdsLoadingZerosAndUnconfirmedPausedStates() throws {
        let occurrence = occurrence()
        var payload: [String: Any] = [
            "kind": "progress", "loadID": UUID().uuidString,
            "identity": ["sessionID": occurrence.sessionID.uuidString, "entryID": occurrence.entryID.uuidString,
                         "trackID": occurrence.trackID, "generation": String(occurrence.generation)],
            "documentID": UUID().uuidString, "mediaGeneration": 1, "sequence": 1,
            "commandRevision": 0, "playbackIntent": true, "intentSource": "native", "videoID": occurrence.trackID,
            "position": 10, "duration": 100, "volume": 1, "isPlaying": true, "isBuffering": false, "isAd": false, "mediaReady": true,
        ]
        #expect(try #require(PlaybackBridgeMessage.decode(payload)).confirmsEpisodeProgress)
        let changes: [[String: Any]] = [["isAd": true], ["mediaReady": false], ["isBuffering": true], ["position": 0], ["duration": 0], ["isPlaying": false], ["kind": "error"]]
        for change in changes {
            let message = try #require(PlaybackBridgeMessage.decode(payload.merging(change) { _, new in new }))
            #expect(!message.confirmsEpisodeProgress)
        }
        payload["kind"] = "ended"; payload["isPlaying"] = false
        #expect(try #require(PlaybackBridgeMessage.decode(payload)).confirmsEpisodeProgress)
    }

    private func model(_ ledger: ProgressLedger) -> EpisodePlaybackSession {
        EpisodePlaybackSession(load: { await ledger.load($0) }, save: { await ledger.save($0) }, now: { Date(timeIntervalSince1970: 1_000) })
    }
    private func occurrence() -> PlaybackOccurrence { .init(sessionID: UUID(), entryID: UUID(), trackID: track.id, generation: 1) }
    private func snapshot(_ hash: String, position: Double) -> EpisodeProgressSnapshot {
        .init(accountHash: hash, records: [.init(episode: track.episode!.identity, position: position, duration: 3_600, completed: false, updatedAt: Date(timeIntervalSince1970: 1_000))])
    }
}

private actor ProgressLedger {
    let initial: [String: EpisodeProgressSnapshot]
    private(set) var writes: [EpisodeProgressSnapshot] = []
    private(set) var loads = 0
    init(initial: [String: EpisodeProgressSnapshot] = [:]) { self.initial = initial }
    func load(_ hash: String) -> EpisodeProgressSnapshot? { loads += 1; return initial[hash] }
    func save(_ snapshot: EpisodeProgressSnapshot) { writes.append(snapshot) }
}
private actor DeferredProgressLoader {
    private var requests: [String: CheckedContinuation<EpisodeProgressSnapshot?, Never>] = [:]
    func load(_ hash: String) async -> EpisodeProgressSnapshot? { await withCheckedContinuation { requests[hash] = $0 } }
    func waitForRequest(_ hash: String) async { while requests[hash] == nil { await Task.yield() } }
    func finish(_ hash: String, value: EpisodeProgressSnapshot?) { requests.removeValue(forKey: hash)?.resume(returning: value) }
}
@MainActor private final class TestEpisodeRates: EpisodeRateControlling {
    var result = true
    var suspends = false
    var calls: [Double] = []
    var pending: CheckedContinuation<Bool, Never>?
    func setEpisodeRate(_ rate: Double, occurrence: PlaybackOccurrence) async -> Bool {
        calls.append(rate)
        if suspends { return await withCheckedContinuation { pending = $0 } }
        return result
    }
    func finish(_ value: Bool) { pending?.resume(returning: value); pending = nil }
}

private actor RebindProgressLedger {
    private var snapshot: EpisodeProgressSnapshot
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var loads = 0
    init(_ snapshot: EpisodeProgressSnapshot) { self.snapshot = snapshot }
    func load(_ hash: String) -> EpisodeProgressSnapshot? {
        loads += 1
        return snapshot.accountHash == hash ? snapshot : nil
    }
    func save(_ value: EpisodeProgressSnapshot) async {
        await withCheckedContinuation { pending = $0 }
        snapshot = value
    }
    func waitForSave() async { while pending == nil { await Task.yield() } }
    func finishSave() { pending?.resume(); pending = nil }
}
