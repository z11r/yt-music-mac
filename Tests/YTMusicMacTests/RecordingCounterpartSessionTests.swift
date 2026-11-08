import Foundation
import MusicCore
import Testing
@testable import YouTubeMusic
@testable import YTMusicMac

@MainActor @Suite("Explicit recording counterpart review")
struct RecordingCounterpartSessionTests {
    @Test func constructionIneligibleAndRevokedQueuedActionsDoNoWork() async {
        let fixture = CounterpartFixture(), target = CounterpartFixture.target()
        #expect(fixture.session.state == .idle)
        var invalid = target.track; invalid.contentKind = nil
        let bad = RecordingCounterpartTarget(profile: target.profile, account: target.account, queueRevision: target.queueRevision,
            entry: target.entry, occurrence: target.occurrence, track: invalid)
        #expect(!fixture.open(bad))
        #expect(fixture.open(target))
        fixture.current = nil
        await fixture.session.waitForIdle()
        #expect(await fixture.gate!.snapshots == 0)
        #expect(await fixture.gate!.readCount == 0)
        #expect(fixture.session.state == .idle && fixture.actions.isEmpty)
    }

    @Test func explicitReadDoesNotPlayAndConfirmationUsesTheSameScopeOnce() async throws {
        let f = CounterpartFixture(), target = CounterpartFixture.target()
        #expect(f.open(target)); await f.gate!.waitForRead()
        await f.gate!.reply(.available(counterpartPair())); await f.session.waitForIdle()
        guard case let .available(review) = f.session.state else { Issue.record("Expected review"); return }
        #expect(f.actions.isEmpty && review.owner.target == target)
        #expect(f.session.confirm(review.id)); #expect(!f.session.confirm(review.id))
        await f.session.waitForIdle()
        #expect(f.actions.count == 1 && f.actions[0].0 == review.owner && f.actions[0].1 == counterpartPair().track)
        #expect(f.session.state == .idle && !f.session.isPresented && !f.session.confirm(review.id))
        #expect(await f.gate!.snapshots == 3)
    }

    @Test func canceledReadRetainsItsSingleCrossProfileSlotUntilActualSettlement() async {
        let admission = RecordingCounterpartReadAdmission()
        let old = CounterpartFixture(admission: admission), new = CounterpartFixture(admission: admission)
        let target = CounterpartFixture.target()
        #expect(old.open(target)); await old.gate!.waitForRead()
        old.session.cancel()
        #expect(old.session.isBusy && !new.open(target))
        old.session.retry(); #expect(await old.gate!.readCount == 1)
        await old.gate!.reply(.available(counterpartPair())); await old.session.waitForIdle()
        #expect(old.session.state == .canceled && old.actions.isEmpty && !new.session.isBusy)
        #expect(new.open(target)); await new.gate!.waitForRead()
        await new.gate!.reply(.unavailable); await new.session.waitForIdle()
        #expect(new.session.state == .unavailable && new.actions.isEmpty)
    }

    @Test func profileOperationDrainWaitsForAHeldCanceledReadAndRejectsNewWork() async {
        let operations = ProfileOperationFence(), f = CounterpartFixture(operations: operations)
        #expect(f.open(CounterpartFixture.target())); await f.gate!.waitForRead()
        operations.quiesce(); f.session.clear()
        var settled = false
        let drain = Task { await operations.waitForIdle(); settled = true }
        await Task.yield(); #expect(!settled && f.session.isBusy)
        await f.gate!.reply(.available(counterpartPair())); await f.session.waitForIdle(); await drain.value
        #expect(settled && f.actions.isEmpty)
        #expect(f.open(CounterpartFixture.target()))
        await f.session.waitForIdle()
        #expect(await f.gate!.readCount == 1)
    }

    @Test func everyFrozenNativeTargetFieldRevokesAReadAndItsVisibleReview() async {
        for field in 0..<7 {
            let f = CounterpartFixture(), target = CounterpartFixture.target()
            #expect(f.open(target)); await f.gate!.waitForRead()
            f.current = changedCounterpartTarget(target, field: field)
            #expect(!f.session.isPresented && f.session.state == .idle)
            await f.gate!.reply(.available(counterpartPair())); await f.session.waitForIdle()
            #expect(f.actions.isEmpty && f.session.state == .idle)
        }
    }

    @Test func closeOrStaleOwnerDuringEachCredentialAwaitPreventsReadOrPlay() async {
        for held in 1...3 {
            let f = CounterpartFixture(heldSnapshot: held), target = CounterpartFixture.target()
            #expect(f.open(target))
            if held > 1 {
                await f.gate!.waitForRead(); await f.gate!.reply(.available(counterpartPair()))
                if held == 3 {
                    await f.session.waitForIdle()
                    guard case let .available(review) = f.session.state else { Issue.record("Expected review"); continue }
                    #expect(f.session.confirm(review.id))
                }
            }
            await f.gate!.waitForSnapshot(held)
            f.session.clear()
            #expect(f.session.state == .idle && !f.session.isPresented)
            await f.gate!.releaseSnapshot(); await f.session.waitForIdle()
            #expect(f.actions.isEmpty)
            #expect(await f.gate!.readCount == (held == 1 ? 0 : 1))
        }
    }

    @Test func actualCredentialRotationRejectsTheResponseAndAnAlreadyPreparedConfirmation() async {
        for beforeConfirmation in [false, true] {
            let f = CounterpartFixture(), target = CounterpartFixture.target()
            #expect(f.open(target)); await f.gate!.waitForRead()
            if !beforeConfirmation { await f.gate!.rotateScope() }
            await f.gate!.reply(.available(counterpartPair())); await f.session.waitForIdle()
            if beforeConfirmation {
                guard case let .available(review) = f.session.state else { Issue.record("Expected review"); continue }
                await f.gate!.rotateScope(); #expect(f.session.confirm(review.id)); await f.session.waitForIdle()
            }
            #expect(f.actions.isEmpty && f.session.state == .idle)
        }
    }

    @Test func staleAvailableReviewAndExpiredReviewCannotPlay() async {
        for stale in [true, false] {
            let f = CounterpartFixture(), target = CounterpartFixture.target()
            #expect(f.open(target)); await f.gate!.waitForRead()
            await f.gate!.reply(.available(counterpartPair())); await f.session.waitForIdle()
            guard case let .available(review) = f.session.state else { Issue.record("Expected review"); continue }
            if stale { f.current = changedCounterpartTarget(target, field: 0) }
            else { f.date = f.date.addingTimeInterval(301) }
            #expect(!f.session.confirm(review.id) && f.actions.isEmpty)
            #expect(f.session.state == (stale ? .idle : .expired))
        }
    }

    @Test func failedReadsKeepErrorsOpaqueAndRetryRequiresAnExplicitAction() async {
        let f = CounterpartFixture(), target = CounterpartFixture.target()
        #expect(f.open(target)); await f.gate!.waitForRead()
        await f.gate!.fail(); await f.session.waitForIdle()
        #expect(f.session.state == .failed && f.actions.isEmpty)
        #expect(await f.gate!.readCount == 1)
        f.session.retry(); await f.gate!.waitForRead(2)
        await f.gate!.reply(.unavailable); await f.session.waitForIdle()
        #expect(f.session.state == .unavailable && f.actions.isEmpty)
    }

    @Test func insertionPreservesOriginalEntriesShuffleRepeatAndSelectsOnlyTheReturnedNewUUID() throws {
        var queue = PlaybackQueue()
        let original = [counterpartSourceTrack(), Track(id: "nextOne12_3", title: "Next", artist: "Artist", contentKind: .song),
                        Track(id: "nextTwo12_3", title: "Last", artist: "Artist", contentKind: .song)]
        queue.replace(with: original, startAt: 0); queue.setShuffle(true); queue.repeatMode = .all
        let before = queue.entries, target = CounterpartFixture.target(queue: queue)
        let inserted = try #require(RecordingCounterpartQueueAction.insert(counterpartPair().track, into: &queue, for: target))
        #expect(queue.entries.filter { $0.id != inserted } == before)
        #expect(queue.entries[try #require(queue.currentIndex) + 1].id == inserted)
        #expect(queue.currentOccurrence == target.occurrence && queue.repeatMode == .all && queue.isShuffled)
        let selection = queue.select(entryID: inserted)
        let occurrence = try #require(selection)
        #expect(occurrence.entryID == inserted && occurrence.trackID == counterpartPair().track.id && occurrence != target.occurrence)
        #expect(queue.snapshot().resumePosition == 0)
        queue.setShuffle(false)
        #expect(queue.entries.filter { $0.id != inserted }.map(\.track) == original)
        #expect(!RecordingCounterpartTarget(profile: target.profile, account: target.account, queueRevision: target.queueRevision,
            entry: UUID(), occurrence: target.occurrence, track: target.track).isValid)
    }

    @Test func staleQueueRevisionEntryOrOccurrenceAndForeignSourcesCannotMutateTheQueue() {
        let original = CounterpartFixture.queue(), target = CounterpartFixture.target(queue: original)
        for field in 2..<7 {
            var queue = original
            #expect(RecordingCounterpartQueueAction.insert(counterpartPair().track, into: &queue, for: changedCounterpartTarget(target, field: field)) == nil)
            #expect(queue.entries == original.entries && queue.currentOccurrence == original.currentOccurrence)
        }
        for kind in [MusicContentKind.song, .podcastEpisode] {
            var queue = original, track = counterpartPair().track; track.origin = .upload; track.contentKind = kind
            #expect(RecordingCounterpartQueueAction.insert(track, into: &queue, for: target) == nil && queue.entries == original.entries)
        }
    }

    @Test func counterpartCopyHasMatchingEnglishAndFrenchTablesWithoutFormattingSourceMetadata() throws {
        var keys: [Set<String>] = []
        for language in ["en", "fr"] {
            let languageURL = try #require(AppLocalization.bundle.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: languageURL)), url = try #require(bundle.url(forResource: "RecordingCounterpart", withExtension: "strings"))
            let values = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            #expect(values.count == 18 && values.values.allSatisfy { !$0.isEmpty })
            #expect(values["Add and Play from Start"] != nil && values["Song"] != nil && values["Video"] != nil)
            keys.append(Set(values.keys))
        }
        #expect(keys[0] == keys[1])
    }
}

@MainActor private final class CounterpartFixture {
    var current: RecordingCounterpartTarget?
    var actions: [(RecordingCounterpartOwner, Track)] = []
    var date = Date(timeIntervalSince1970: 1_000)
    let gate: CounterpartGate?
    var session: RecordingCounterpartSession!
    init(admission: RecordingCounterpartReadAdmission? = nil, operations: ProfileOperationFence? = nil, heldSnapshot: Int? = nil) {
        let gate = CounterpartGate(heldSnapshot: heldSnapshot); self.gate = gate
        session = RecordingCounterpartSession(operations: operations ?? .init(), admission: admission ?? .init(),
            snapshot: { await gate.snapshot() }, fetch: { try await gate.fetch($0, scope: $1) }, now: { [weak self] in self?.date ?? .distantPast })
    }
    func open(_ target: RecordingCounterpartTarget) -> Bool {
        current = target
        return session.open(target, isCurrent: { [weak self] in self?.current == $0 },
            accept: { [weak self] owner, track in
                guard let self, self.current == owner.target else { return false }
                self.actions.append((owner, track)); return true
            })
    }
    static func queue() -> PlaybackQueue { var queue = PlaybackQueue(); queue.replace(with: [counterpartSourceTrack()], startAt: 0); return queue }
    static func target(queue: PlaybackQueue = CounterpartFixture.queue()) -> RecordingCounterpartTarget {
        .init(profile: UUID(), account: UUID(), queueRevision: queue.revision, entry: queue.currentEntryID!, occurrence: queue.currentOccurrence!, track: queue.currentTrack!)
    }
}
private func counterpartSourceTrack() -> Track { .init(id: "abcDEF12_-3", title: "Source", artist: "Artist", contentKind: .song) }
private func counterpartPair() -> MusicRecordingCounterpart {
    .init(primaryVideoID: "abcDEF12_-3", primaryKind: .song, kind: .video,
        track: .init(id: "xyzABC98_-7", title: "Other version", artist: "Artist", duration: 250, origin: .catalog, contentKind: .song))
}
private func changedCounterpartTarget(_ value: RecordingCounterpartTarget, field: Int) -> RecordingCounterpartTarget {
    var track = value.track
    if field == 6 { track.title += " changed" }
    return .init(profile: field == 0 ? UUID() : value.profile, account: field == 1 ? UUID() : value.account,
        queueRevision: field == 2 ? PlaybackQueue().revision : value.queueRevision, entry: field == 3 ? UUID() : value.entry,
        occurrence: field == 4 ? .init(sessionID: UUID(), entryID: value.entry, trackID: value.track.id, generation: 1) :
            field == 5 ? .init(sessionID: value.occurrence.sessionID, entryID: value.entry, trackID: value.track.id, generation: value.occurrence.generation + 1) : value.occurrence,
        track: track)
}
private actor CounterpartGate {
    private var scope = UUID()
    let heldSnapshot: Int?
    private(set) var snapshots = 0
    private(set) var readCount = 0
    private var pending: CheckedContinuation<MusicRecordingCounterpartResult, any Error>?
    private var snapshotHold: CheckedContinuation<Void, Never>?
    private var readObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var snapshotObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    init(heldSnapshot: Int?) { self.heldSnapshot = heldSnapshot }
    func snapshot() async -> MusicSession {
        snapshots += 1
        if snapshots == heldSnapshot {
            await withCheckedContinuation { snapshotHold = $0; let ready = snapshotObservers; snapshotObservers = []; ready.forEach { $0.1.resume() } }
        }
        return .init(scope: scope, accountID: "fixture", cookieHeader: "fixture=value", sapisid: "fixture")
    }
    func fetch(_ videoID: String, scope: UUID) async throws -> MusicRecordingCounterpartResult {
        readCount += 1
        return try await withCheckedThrowingContinuation { pending = $0; let ready = readObservers.filter { $0.0 <= readCount }; readObservers.removeAll { $0.0 <= readCount }; ready.forEach { $0.1.resume() } }
    }
    func waitForRead(_ count: Int = 1) async { if readCount < count { await withCheckedContinuation { readObservers.append((count, $0)) } } }
    func waitForSnapshot(_ count: Int) async { if snapshots < count || snapshotHold == nil { await withCheckedContinuation { snapshotObservers.append((count, $0)) } } }
    func releaseSnapshot() { let held = snapshotHold; snapshotHold = nil; held?.resume() }
    func rotateScope() { scope = UUID() }
    func reply(_ value: MusicRecordingCounterpartResult) { let result = pending; pending = nil; result?.resume(returning: value) }
    func fail() { struct PrivateFailure: Error {}; let result = pending; pending = nil; result?.resume(throwing: PrivateFailure()) }
}
