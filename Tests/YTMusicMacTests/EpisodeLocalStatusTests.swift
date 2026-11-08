import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@Suite("Explicit local episode status") @MainActor
struct EpisodeLocalStatusTests {
    private let account = String(repeating: "a", count: 64)
    private func track(_ number: Int = 1, duration: Double? = 100, show: String? = nil) -> Track {
        .init(id: String(format: "e%010d", number), title: "Episode", artist: "Show", duration: duration,
            contentKind: .podcastEpisode, episode: .init(identity: .init(browseID: "MPEDfixture\(number)", showBrowseID: show), serviceProgressFraction: 0.9))
    }
    private func occurrence(_ track: Track) -> PlaybackOccurrence { .init(sessionID: UUID(), entryID: UUID(), trackID: track.id, generation: 1) }
    private func model(_ ledger: ManualProgressLedger) -> EpisodePlaybackSession {
        .init(load: { await ledger.load($0) }, save: { try await ledger.save($0) },
              now: { Date(timeIntervalSince1970: 100) }, saveDelay: .seconds(60))
    }
    private func initial(position: Double = 40, updatedAt: Double = 50) -> EpisodeProgressSnapshot {
        .init(accountHash: account, records: [.init(episode: track().episode!.identity, position: position, duration: 100,
            completed: false, updatedAt: Date(timeIntervalSince1970: updatedAt))], settings: .init(skipBackward: 15, skipForward: 45))
    }

    @Test func manualCompletionRequiresKnownDurationAndDoesNotFabricateAPosition() async throws {
        let ledger = ManualProgressLedger(), session = model(ledger)
        defer { session.setPersistenceEnabled(false) }
        session.bindAccount(account); await session.waitUntilLoaded()
        let missing = try #require(session.localStatusTarget(for: track(duration: nil)))
        #expect(!missing.canMarkCompleted && !session.changeLocalStatus(.markCompleted, target: missing))
        #expect(session.localStatusTarget(for: .init(id: "song", title: "Song", artist: "Artist")) == nil)
        let target = try #require(session.localStatusTarget(for: track()))
        #expect(session.changeLocalStatus(.markCompleted, target: target))
        #expect(!session.changeLocalStatus(.markCompleted, target: target))
        let record = try #require(session.progress(for: track()))
        #expect(record.completed && record.completionSource == .manual && record.position == 0 && record.duration == 100)
        #expect(session.resumePosition(for: track()) == 0)
        #expect(await session.flush())
        #expect(await ledger.writes.last?.records == [record])
    }
    @Test func currentCompletionHoldsAcrossConfirmedSamplesButSeekAndNewPlaybackTrackNormally() async throws {
        let ledger = ManualProgressLedger(initial()), session = model(ledger)
        defer { session.setPersistenceEnabled(false) }
        session.bindAccount(account); await session.waitUntilLoaded()
        let current = occurrence(track())
        session.begin(track: track(), occurrence: current)
        session.record(occurrence: current, position: 50, duration: 100, confirmedContent: true)
        let settings = session.settings
        let target = try #require(session.localStatusTarget(for: track(show: "MPSPshow")))
        #expect(session.changeLocalStatus(.markCompleted, target: target))
        // A recovery of this same occurrence does not revoke the manual status.
        session.begin(track: track(), occurrence: current)
        session.record(occurrence: current, position: 60, duration: 100, confirmedContent: true)
        session.record(occurrence: current, position: 100, duration: 100, confirmedContent: true, ended: true)
        #expect(session.progress(for: track())?.position == 50)
        #expect(session.progress(for: track())?.completionSource == .manual && session.settings == settings)
        session.allowExplicitSeek()
        session.record(occurrence: current, position: 20, duration: 100, confirmedContent: true)
        #expect(session.progress(for: track())?.completed == false && session.progress(for: track())?.completionSource == nil)
        #expect(session.changeLocalStatus(.markCompleted, target: try #require(session.localStatusTarget(for: track()))))
        let next = occurrence(track())
        session.begin(track: track(), occurrence: next)
        session.record(occurrence: next, position: 5, duration: 100, confirmedContent: true)
        #expect(session.resumePosition(for: track()) == 5)
    }
    @Test func clearDoesNotSeekOrImmediatelyRecreateProgressFromTheCurrentOccurrence() async throws {
        let session = model(ManualProgressLedger(initial()))
        defer { session.setPersistenceEnabled(false) }
        session.bindAccount(account); await session.waitUntilLoaded()
        let current = occurrence(track())
        session.begin(track: track(), occurrence: current)
        #expect(session.changeLocalStatus(.clearProgress, target: try #require(session.localStatusTarget(for: track()))))
        session.record(occurrence: current, position: 60, duration: 100, confirmedContent: true)
        #expect(session.progress(for: track()) == nil)
        session.allowExplicitSeek()
        session.record(occurrence: current, position: 10, duration: 100, confirmedContent: true)
        #expect(session.resumePosition(for: track()) == 10)
    }
    @Test func disabledPersistenceClearCannotResurrectStoredProgressOnOptIn() async throws {
        let ledger = ManualProgressLedger(initial()), session = model(ledger)
        defer { session.setPersistenceEnabled(false) }
        session.bindAccount(account); await session.waitUntilLoaded()
        session.setPersistenceEnabled(false)
        #expect(session.changeLocalStatus(.clearProgress, target: try #require(session.localStatusTarget(for: track()))))
        let flushed = await session.flush()
        let writes = await ledger.writes
        #expect(!flushed && writes.isEmpty)
        session.setPersistenceEnabled(true); await session.waitUntilLoaded()
        #expect(session.progress(for: track()) == nil)
        #expect(await session.flush())
        #expect(await ledger.writes.last?.records.isEmpty == true)
    }
    @Test func manualStatusWinsOverOlderSavedContentEvenWhenTheWallClockMovesBackward() async throws {
        let ledger = ManualProgressLedger(initial(updatedAt: 5_000)), session = model(ledger)
        defer { session.setPersistenceEnabled(false) }
        session.bindAccount(account); await session.waitUntilLoaded()
        session.setPersistenceEnabled(false)
        #expect(session.changeLocalStatus(.markCompleted, target: try #require(session.localStatusTarget(for: track()))))
        session.setPersistenceEnabled(true); await session.waitUntilLoaded()
        #expect(session.progress(for: track())?.completionSource == .manual)
        #expect(session.progress(for: track())?.position == 40)
        #expect(session.settings == .init(skipBackward: 15, skipForward: 45))
    }
    @Test func sameAccountContinuationPreservesTheCurrentManualHoldWithoutChangingRateCapability() async throws {
        let ledger = ManualProgressLedger(initial()), session = model(ledger)
        defer { session.setPersistenceEnabled(false) }
        session.bindAccount(account); await session.waitUntilLoaded()
        let current = occurrence(track()), rates = ManualStatusRates()
        session.rateController = rates
        session.begin(track: track(), occurrence: current)
        session.record(occurrence: current, position: 50, duration: 100, confirmedContent: true)
        session.reportRates([1, 1.5], current: 1, occurrence: current)
        #expect(session.changeLocalStatus(.markCompleted, target: try #require(session.localStatusTarget(for: track()))))
        #expect(session.canControlRate && session.currentRate == 1 && rates.calls == 0)
        let continuation = try #require(session.continuationForRebind())
        let saving = session.detachAccount(); session.bindAccount(account)
        _ = await saving?.value; await session.waitUntilLoaded()
        #expect(session.restoreContinuation(continuation))
        session.record(occurrence: current, position: 60, duration: 100, confirmedContent: true)
        #expect(session.progress(for: track())?.completionSource == .manual)
        #expect(session.progress(for: track())?.position == 50)
    }
    @Test func accountOwnershipPersistenceAndOccurrenceChangesRejectRenderedTargets() async throws {
        for change in 0..<4 {
            let session = model(ManualProgressLedger(initial()))
            defer { session.setPersistenceEnabled(false) }
            session.bindAccount(account); await session.waitUntilLoaded()
            let target = try #require(session.localStatusTarget(for: track()))
            switch change {
            case 0: session.bindAccount(String(repeating: "b", count: 64)); await session.waitUntilLoaded()
            case 1: session.suspendProfileOwnership(); session.resumeProfileOwnership()
            case 2: session.setPersistenceEnabled(false)
            default: session.begin(track: track(), occurrence: occurrence(track()))
            }
            #expect(!session.changeLocalStatus(.markCompleted, target: target))
            #expect(session.progress(for: track())?.completionSource == nil)
        }
    }
    @Test func loadingBlocksManualActionsAndDoesNotInventProgressFromServicePercent() async throws {
        let loader = ManualProgressLoadGate()
        let session = EpisodePlaybackSession(load: { _ in await loader.load() }, save: { _ in }, saveDelay: .seconds(60))
        defer { session.setPersistenceEnabled(false) }
        session.bindAccount(account); await loader.waitForLoad()
        #expect(session.localStatusTarget(for: track()) == nil)
        #expect(session.progress(for: track()) == nil)
        await loader.release(); await session.waitUntilLoaded()
        #expect(session.progress(for: track()) == nil)
    }
    @Test func zeroAndUnknownDurationDoNotBorrowAnotherEpisodesDuration() async throws {
        let session = model(ManualProgressLedger(initial()))
        defer { session.setPersistenceEnabled(false) }
        session.bindAccount(account); await session.waitUntilLoaded()
        #expect(session.localStatusTarget(for: track(2, duration: nil))?.canMarkCompleted == false)
        #expect(session.localStatusTarget(for: track(2, duration: 0))?.canMarkCompleted == false)
        let withPrior = try #require(session.localStatusTarget(for: track(duration: nil)))
        #expect(withPrior.canMarkCompleted && session.changeLocalStatus(.markCompleted, target: withPrior))
        #expect(session.progress(for: track())?.duration == 100)
    }
    @Test func confirmedSeekDuringOptInWinsOverAnEarlierExplicitClear() async throws {
        let ledger = ManualProgressLedger(initial()), gate = ManualProgressLoadGate()
        let session = EpisodePlaybackSession(load: { _ in await gate.load() }, save: { try await ledger.save($0) }, saveDelay: .seconds(60))
        defer { session.setPersistenceEnabled(false) }
        session.setPersistenceEnabled(false); session.bindAccount(account)
        let current = occurrence(track())
        session.begin(track: track(), occurrence: current)
        session.record(occurrence: current, position: 45, duration: 100, confirmedContent: true)
        #expect(session.changeLocalStatus(.clearProgress, target: try #require(session.localStatusTarget(for: track()))))
        session.setPersistenceEnabled(true); await gate.waitForLoad()
        #expect(session.localStatusTarget(for: track()) == nil)
        session.allowExplicitSeek()
        session.record(occurrence: current, position: 15, duration: 100, confirmedContent: true)
        await gate.release(initial()); await session.waitUntilLoaded()
        #expect(session.resumePosition(for: track()) == 15)
        #expect(session.progress(for: track())?.completionSource == nil)
    }
    @Test func startOverReleasesTheManualHoldAndKeepsSkipSettings() async throws {
        let session = model(ManualProgressLedger(initial()))
        defer { session.setPersistenceEnabled(false) }
        session.bindAccount(account); await session.waitUntilLoaded()
        let current = occurrence(track())
        session.begin(track: track(), occurrence: current)
        #expect(session.changeLocalStatus(.markCompleted, target: try #require(session.localStatusTarget(for: track()))))
        session.startOver(track())
        #expect(session.progress(for: track()) == nil)
        session.record(occurrence: current, position: 1, duration: 100, confirmedContent: true)
        #expect(session.resumePosition(for: track()) == 1)
        #expect(session.settings == .init(skipBackward: 15, skipForward: 45))
    }
    @Test func durationCorrectionsKeepTheLatestConfirmedPositionAndDurationTogether() async throws {
        let session = model(ManualProgressLedger())
        defer { session.setPersistenceEnabled(false) }
        session.bindAccount(account); await session.waitUntilLoaded()
        let current = occurrence(track())
        session.begin(track: track(), occurrence: current)
        let rendered = try #require(session.localStatusTarget(for: track()))
        session.record(occurrence: current, position: 120, duration: 150, confirmedContent: true)
        #expect(session.changeLocalStatus(.markCompleted, target: rendered))
        #expect(session.progress(for: track())?.position == 120 && session.progress(for: track())?.duration == 150)
        #expect(await session.flush())
    }
    @Test func pendingClearIntentsAreBoundedAndStartOverDoesNotClaimARefusedClear() async throws {
        let session = model(ManualProgressLedger())
        session.setPersistenceEnabled(false); session.bindAccount(account)
        for number in 0..<2_000 {
            let episode = track(number)
            #expect(session.changeLocalStatus(.markCompleted, target: try #require(session.localStatusTarget(for: episode))))
            #expect(session.changeLocalStatus(.clearProgress, target: try #require(session.localStatusTarget(for: episode))))
        }
        let another = track(2_001)
        #expect(session.changeLocalStatus(.markCompleted, target: try #require(session.localStatusTarget(for: another))))
        #expect(!session.startOver(another))
        #expect(session.progress(for: another)?.completionSource == .manual && session.errorMessage != nil)
    }
    @Test func backwardClockSeekDuringHeldReloadCannotResurrectCapturedManualCompletion() async throws {
        let clock = ManualStatusClock(), gate = ManualProgressLoadGate(), ledger = ManualProgressLedger()
        let session = EpisodePlaybackSession(load: { _ in await gate.load() }, save: { try await ledger.save($0) }, now: { clock.read() }, saveDelay: .seconds(60))
        defer { session.setPersistenceEnabled(false) }
        session.setPersistenceEnabled(false); session.bindAccount(account)
        let current = occurrence(track())
        session.begin(track: track(), occurrence: current)
        session.record(occurrence: current, position: 40, duration: 100, confirmedContent: true)
        #expect(session.changeLocalStatus(.markCompleted, target: try #require(session.localStatusTarget(for: track()))))
        let manual = try #require(session.progress(for: track()))
        session.setPersistenceEnabled(true); await gate.waitForLoad()
        clock.set(50); session.allowExplicitSeek()
        session.record(occurrence: current, position: 15, duration: 100, confirmedContent: true)
        let earlyWrites = await ledger.writes
        #expect(session.isLoading && earlyWrites.isEmpty)
        await gate.release(.init(accountHash: account, records: [manual])); await session.waitUntilLoaded()
        #expect(session.progress(for: track())?.position == 15)
        #expect(session.progress(for: track())?.completed == false && session.progress(for: track())?.completionSource == nil)
        #expect(await session.flush())
        #expect(await ledger.writes.last?.records.first?.position == 15)
    }
    @Test func valueIdenticalConfirmedArrivalWinsCausallyOverALaterDatedStoredBookmark() async throws {
        let gate = ManualProgressLoadGate()
        let session = EpisodePlaybackSession(load: { _ in await gate.load() }, save: { _ in }, now: { Date(timeIntervalSince1970: 100) }, saveDelay: .seconds(60))
        defer { session.setPersistenceEnabled(false) }
        session.setPersistenceEnabled(false); session.bindAccount(account)
        let current = occurrence(track())
        session.begin(track: track(), occurrence: current)
        session.record(occurrence: current, position: 40, duration: 100, confirmedContent: true)
        session.setPersistenceEnabled(true); await gate.waitForLoad()
        session.allowExplicitSeek()
        session.record(occurrence: current, position: 40, duration: 100, confirmedContent: true)
        await gate.release(initial(position: 80, updatedAt: 1_000)); await session.waitUntilLoaded()
        #expect(session.resumePosition(for: track()) == 40)
    }
    @Test func startOverWithoutLoadedMemoryCannotResurrectAnOldBookmarkOnOptIn() async throws {
        let gate = ManualProgressLoadGate(), ledger = ManualProgressLedger()
        let session = EpisodePlaybackSession(load: { _ in await gate.load() }, save: { try await ledger.save($0) }, saveDelay: .seconds(60))
        defer { session.setPersistenceEnabled(false) }
        session.setPersistenceEnabled(false); session.bindAccount(account)
        #expect(session.progress(for: track()) == nil && session.startOver(track()))
        session.setPersistenceEnabled(true); await gate.waitForLoad()
        await gate.release(initial()); await session.waitUntilLoaded()
        #expect(session.progress(for: track()) == nil)
        #expect(await session.flush())
        #expect(await ledger.writes.last?.records.isEmpty == true)
    }
    @Test func boundedMergeKeepsAnOlderClockManualIntentAndWritesAValidSnapshot() async throws {
        let stored = largeSnapshot(), ledger = ManualProgressLedger(stored), session = model(ledger)
        defer { session.setPersistenceEnabled(false) }
        session.setPersistenceEnabled(false); session.bindAccount(account)
        let manual = track(5_000)
        #expect(session.changeLocalStatus(.markCompleted, target: try #require(session.localStatusTarget(for: manual))))
        session.setPersistenceEnabled(true); await session.waitUntilLoaded()
        #expect(session.progress(for: manual)?.completionSource == .manual)
        #expect(await session.flush())
        let saved = try #require(await ledger.writes.last)
        try saved.validate()
        #expect(saved.records.count == 2_000)
        #expect(!saved.records.contains { $0.episode.key == track(0).episode!.identity.key })
    }
    @Test func futureLoadFailureRetainsBoundedManualAndResetIntentUntilAValidReadSucceeds() async throws {
        let stored = largeSnapshot()
        let future = EpisodeProgressSnapshot(version: 2, accountHash: account, records: stored.records)
        let ledger = ManualProgressLedger(future), session = model(ledger)
        defer { session.setPersistenceEnabled(false) }
        session.setPersistenceEnabled(false); session.bindAccount(account)
        let first = track(5_000), second = track(5_001)
        #expect(session.startOver(track(1)))
        #expect(session.changeLocalStatus(.markCompleted, target: try #require(session.localStatusTarget(for: first))))
        session.setPersistenceEnabled(true); await session.waitUntilLoaded()
        #expect(session.errorMessage != nil && session.progress(for: first)?.completionSource == .manual)
        #expect(!(await session.flush()))
        #expect(await ledger.writes.isEmpty)
        session.setPersistenceEnabled(false)
        #expect(session.changeLocalStatus(.markCompleted, target: try #require(session.localStatusTarget(for: second))))
        await ledger.replace(stored)
        session.setPersistenceEnabled(true); await session.waitUntilLoaded()
        #expect(session.progress(for: first)?.completionSource == .manual && session.progress(for: second)?.completionSource == .manual)
        #expect(session.progress(for: track(1)) == nil)
        #expect(await session.flush())
        #expect(await ledger.writes.last?.records.count == 2_000)
    }
    @Test func anOlderHeldWriteCannotAcknowledgeNewerConfirmedResetProgress() async throws {
        let clock = ManualStatusClock(), gate = ManualProgressSaveGate(), ledger = ManualProgressLedger(initial())
        let session = EpisodePlaybackSession(load: { await ledger.load($0) }, save: { value in
            await gate.holdFirstSave(); try await ledger.save(value)
        }, now: { clock.read() }, saveDelay: .seconds(60))
        defer { session.setPersistenceEnabled(false) }
        session.bindAccount(account); await session.waitUntilLoaded()
        let current = occurrence(track())
        session.begin(track: track(), occurrence: current)
        #expect(session.changeLocalStatus(.clearProgress, target: try #require(session.localStatusTarget(for: track()))))
        session.allowExplicitSeek(); session.record(occurrence: current, position: 15, duration: 100, confirmedContent: true)
        let saving = Task { await session.flush() }
        await gate.waitForSave()
        clock.set(50); session.allowExplicitSeek()
        session.record(occurrence: current, position: 20, duration: 100, confirmedContent: true)
        await gate.release(); #expect(await saving.value)
        session.setPersistenceEnabled(false); session.setPersistenceEnabled(true); await session.waitUntilLoaded()
        #expect(session.resumePosition(for: track()) == 20)
        #expect(await session.flush())
        #expect(await ledger.writes.last?.records.first?.position == 20)
    }
    private func largeSnapshot() -> EpisodeProgressSnapshot {
        .init(accountHash: account, records: (0..<2_000).map {
            .init(episode: track($0).episode!.identity, position: 40, duration: 100, completed: false, updatedAt: Date(timeIntervalSince1970: 5_000))
        })
    }
    @Test func currentBackdatedSampleSurvivesAFullPendingMemoryWindow() async throws {
        let clock = ManualStatusClock(), ledger = ManualProgressLedger()
        let session = EpisodePlaybackSession(load: { await ledger.load($0) }, save: { try await ledger.save($0) }, now: { clock.read() }, saveDelay: .seconds(60))
        defer { session.setPersistenceEnabled(false) }
        session.setPersistenceEnabled(false); session.bindAccount(account)
        for number in 0..<2_000 {
            let episode = track(number), current = occurrence(track(number))
            session.begin(track: episode, occurrence: current)
            session.record(occurrence: current, position: 40, duration: 100, confirmedContent: true)
        }
        clock.set(50)
        let latest = track(5_000), current = occurrence(track(5_000))
        session.begin(track: latest, occurrence: current)
        session.record(occurrence: current, position: 15, duration: 100, confirmedContent: true)
        #expect(session.resumePosition(for: latest) == 15)
        session.setPersistenceEnabled(true); await session.waitUntilLoaded()
        #expect(await session.flush())
        let saved = try #require(await ledger.writes.last)
        #expect(saved.records.count == 2_000 && saved.records.contains { $0.episode.key == latest.episode!.identity.key && $0.position == 15 })
    }
}

private actor ManualProgressLedger {
    private var value: EpisodeProgressSnapshot?
    private(set) var writes: [EpisodeProgressSnapshot] = []
    init(_ value: EpisodeProgressSnapshot? = nil) { self.value = value }
    func load(_ account: String) -> EpisodeProgressSnapshot? { value?.accountHash == account ? value : nil }
    func save(_ value: EpisodeProgressSnapshot) throws { try value.validate(); self.value = value; writes.append(value) }
    func replace(_ value: EpisodeProgressSnapshot) { self.value = value }
}
private actor ManualProgressLoadGate {
    private var pending: CheckedContinuation<EpisodeProgressSnapshot?, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    func load() async -> EpisodeProgressSnapshot? {
        arrivals.forEach { $0.resume() }; arrivals.removeAll()
        return await withCheckedContinuation { pending = $0 }
    }
    func waitForLoad() async { if pending != nil { return }; await withCheckedContinuation { arrivals.append($0) } }
    func release(_ value: EpisodeProgressSnapshot? = nil) { pending?.resume(returning: value); pending = nil }
}
@MainActor private final class ManualStatusRates: EpisodeRateControlling {
    private(set) var calls = 0
    func setEpisodeRate(_ rate: Double, occurrence: PlaybackOccurrence) async -> Bool { calls += 1; return true }
}
private final class ManualStatusClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 100.0
    func read() -> Date { lock.withLock { Date(timeIntervalSince1970: seconds) } }
    func set(_ seconds: Double) { lock.withLock { self.seconds = seconds } }
}
private actor ManualProgressSaveGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var admitted = false
    func holdFirstSave() async {
        guard !admitted else { return }; admitted = true
        await withCheckedContinuation { pending = $0; arrival?.resume(); arrival = nil }
    }
    func waitForSave() async { if pending != nil { return }; await withCheckedContinuation { arrival = $0 } }
    func release() { pending?.resume(); pending = nil }
}
