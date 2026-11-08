import Foundation
import MusicCore
import Testing
import WebKit
@testable import YTMusicMac

@MainActor @Suite("Bounded exact-view output retirement")
struct PlaybackOutputRetirementTests {
    @Test func everyKnownOldViewAndTheCurrentViewMustConfirmSuspensionCloseAndState() async {
        let clock = RetirementTestDeadline(), ledger = PlaybackViewRetirementLedger(sleep: clock.sleep)
        let old = RetirementTestView(), current = RetirementTestView()
        let operation = ledger.begin([old, current])
        #expect(old.suspensions == 1 && current.suspensions == 1 && old.closes == 1 && current.closes == 1)
        old.finishSuspend(); old.finishClose(); old.finishState(.suspended)
        #expect(!operation.isConfirmedQuiet && ledger.retainedTargetCount == 1)
        current.finishSuspend(); #expect(current.stateRequests == 0)
        current.finishClose(); #expect(current.stateRequests == 1)
        current.finishState(.none)
        #expect(await operation.settle() == .init(ticket: operation.ticket, outcome: .confirmed))
        #expect(ledger.retainedTargetCount == 0 && operation.isConfirmedQuiet)
    }
    @Test func pausedPlayingAndUnknownAreNotProofAndDuplicateRepliesCannotUpgradeThem() async {
        for state in [RetiredMediaState.paused, .playing, .unknown] {
            let clock = RetirementTestDeadline(), ledger = PlaybackViewRetirementLedger(sleep: clock.sleep)
            let view = RetirementTestView(), operation = ledger.begin([view])
            view.finishSuspend(); view.finishClose()
            let reply = view.stateReply
            reply?(state); reply?(.suspended)
            #expect(await operation.settle() == .init(ticket: operation.ticket, outcome: .blocked(.unconfirmed)))
            #expect(!operation.isConfirmedQuiet && ledger.retainedTargetCount == 1)
        }
    }
    @Test func deadlineReturnsBlockedWithoutDiscardingResourcesOrAdmittingAnotherRetirement() async {
        let clock = RetirementTestDeadline(), ledger = PlaybackViewRetirementLedger(sleep: clock.sleep)
        var view: RetirementTestView? = RetirementTestView()
        weak var retained = view
        defer { retained = nil }
        let operation = ledger.begin([view!])
        view = nil; clock.fire()
        #expect(await operation.settle() == .init(ticket: operation.ticket, outcome: .blocked(.timedOut)))
        #expect(retained != nil && ledger.retainedTargetCount == 1)
        let replacement = RetirementTestView()
        #expect(ledger.begin([replacement]) === operation)
        #expect(replacement.suspensions == 0 && replacement.closes == 0)
        retained?.finishSuspend(); retained?.finishClose(); retained?.finishState(.suspended)
        #expect(operation.isConfirmedQuiet && retained == nil && ledger.retainedTargetCount == 0)
        #expect(await operation.settle() == .init(ticket: operation.ticket, outcome: .blocked(.timedOut)))
    }
    @Test func cancellationHasABoundedReceiptAndRetainsAdmittedTargetsUntilActualConfirmation() async {
        let clock = RetirementTestDeadline(), ledger = PlaybackViewRetirementLedger(sleep: clock.sleep)
        let view = RetirementTestView(), operation = ledger.begin([view])
        let waiting = Task { await operation.settle() }
        waiting.cancel()
        #expect(await waiting.value == .init(ticket: operation.ticket, outcome: .blocked(.cancelled)))
        #expect(ledger.retainedTargetCount == 1 && !operation.isConfirmedQuiet)
        view.finishSuspend(); view.finishClose(); view.finishState(.suspended)
        #expect(operation.isConfirmedQuiet)
        #expect(await operation.settle() == .init(ticket: operation.ticket, outcome: .blocked(.cancelled)))
    }
    @Test func overflowAndUnknownHistoryNeverCertifySilenceOrLaunchAnUnboundedSet() async {
        let clock = RetirementTestDeadline(), ledger = PlaybackViewRetirementLedger(maximumTargets: 1, sleep: clock.sleep)
        let first = RetirementTestView(), second = RetirementTestView()
        let refused = ledger.begin([first, second])
        #expect(await refused.settle() == .init(ticket: refused.ticket, outcome: .blocked(.capacity)))
        #expect(first.suspensions == 0 && second.suspensions == 0)
        let unknown = PlaybackViewRetirementLedger(sleep: RetirementTestDeadline().sleep)
        let known = RetirementTestView(), uncertain = unknown.begin([known], historyIsComplete: false)
        known.finishSuspend(); known.finishClose(); known.finishState(.none)
        #expect(await uncertain.settle() == .init(ticket: uncertain.ticket, outcome: .blocked(.unknownTargets)))
        #expect(!uncertain.isConfirmedQuiet)
    }
    @Test func knownViewInventoryRetainsOnlyUnresolvedResourcesAndOverflowStaysBlocked() {
        let inventory = RetiringPlaybackViews(limit: 1), firstID = UUID()
        var first: RetirementTestResource? = RetirementTestResource()
        weak var weakFirst = first
        defer { weakFirst = nil }
        #expect(inventory.remember(first!, id: firstID))
        first = nil
        inventory.closed(firstID)
        #expect(weakFirst != nil && inventory.snapshots.count == 1)
        #expect(!inventory.remember(RetirementTestResource(), id: UUID()))
        inventory.paused(firstID)
        #expect(weakFirst == nil && inventory.snapshots.isEmpty && !inventory.historyIsComplete)
    }
    @Test func ownershipHoldPrecedesAllCallbacksAndCannotBeClearedByRepeatedRequests() async {
        let hold = WebPlaybackOutputHold(sleep: RetirementTestDeadline().sleep), view = RetirementTestView()
        var revoked = false
        var nested: PlaybackOutputRetirement?
        view.onSuspend = { #expect(hold.isHeld && revoked) }
        let operation = hold.revoke(historyIsComplete: true, willRevoke: {
            revoked = true
            nested = hold.revoke(historyIsComplete: true, willRevoke: { Issue.record("Reentrant revocation") }, targets: { [] })
        }, targets: { [view] })
        #expect(nested === operation)
        let other = RetirementTestView()
        let repeated = hold.revoke(historyIsComplete: true, willRevoke: { Issue.record("Revoked twice") }, targets: { [other] })
        #expect(repeated === operation && other.suspensions == 0 && hold.isHeld)
        view.finishSuspend(); view.finishClose(); view.finishState(.suspended)
        #expect(await operation.settle() == .init(ticket: operation.ticket, outcome: .confirmed))
        #expect(hold.isHeld)
    }
    @Test func retiredWebPlayerCannotLoadPlaySeekRestoreReplaceOrIssueASecondNativeRetirement() async {
        let factory = RetirementTestFactory()
        let player = WebPlayer(dataStore: .nonPersistent(), retirementTargetFactory: { view, id, closed in factory.make(view, id: id, didClose: closed) },
                               retirementSleep: RetirementTestDeadline().sleep)
        let exactView = player.webView, generation = player.webViewGeneration
        let operation = player.revokeOutputForHandoff()
        #expect(factory.targets.count == 1 && player.isOutputOwnershipHeld && operation.receipt == nil)
        #expect(operation.ticket.instanceID == player.outputInstanceID)
        let track = Track(id: "abcDEF12_-3", title: "Synthetic", artist: "Artist", contentKind: .song)
        let occurrence = PlaybackOccurrence(sessionID: UUID(), entryID: UUID(), trackID: track.id, generation: 1)
        player.load(track: track, occurrence: occurrence); player.play(); player.seek(to: 10); player.retry(); player.stop()
        var synchronized = false
        #expect(!player.restoreSessionPage { _ in synchronized = true; return true })
        #expect(!synchronized && player.webView === exactView && player.webViewGeneration == generation)
        #expect(player.webView.url == nil && !player.playbackIntent && factory.targets.count == 1)
        #expect(player.revokeOutputForHandoff() === operation && factory.targets.count == 1)
        let target = factory.targets[0]
        target.finishSuspend(); target.finishClose(); target.finishState(.none)
        #expect(await operation.settle() == .init(ticket: operation.ticket, outcome: .confirmed))
        player.load(track: track, occurrence: occurrence); player.play()
        #expect(player.isOutputOwnershipHeld && player.webView === exactView && player.webView.url == nil)
    }
}

@MainActor @Suite("Exact engine binding and same-instance retarget")
struct PlaybackOutputCoordinatorTests {
    @Test func preparationIsInertAndOnlyTheExactBoundInstanceReceivesAuthority() async throws {
        let f = OutputCoordinatorFixture(), web = RetirementTestEngine(.web)
        let prepared = try await f.prepare()
        #expect(prepared.isCurrent && web.calls == 0 && f.coordinator.permit == nil)
        #expect(await f.coordinator.settle() == .blocked(.outputActive))
        let wrongKind = RetirementTestEngine(.local)
        guard case .blocked = f.coordinator.bindOutput(prepared, to: wrongKind) else { Issue.record("Wrong kind accepted"); return }
        let permit = try f.bind(prepared, to: web)
        let impostor = RetirementTestEngine(.web, id: web.outputInstanceID)
        #expect(permit.isCurrent && permit.authorizes(web) && !permit.authorizes(impostor))
        #expect(f.coordinator.bindMediaEvents(permit, engine: impostor, nativeMediaID: UUID()) == nil)
        #expect(f.coordinator.bindMediaEvents(permit, engine: web, nativeMediaID: .init(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))) == nil)
        let event = try #require(f.coordinator.bindMediaEvents(permit, engine: web, nativeMediaID: UUID()))
        #expect(f.coordinator.acceptsEvent(event))
        let foreign = OutputCoordinatorFixture()
        #expect(foreign.coordinator.bindMediaEvents(permit, engine: web, nativeMediaID: UUID()) == nil)
        #expect(!foreign.coordinator.acceptsEvent(event))
        guard case .blocked = f.coordinator.bindOutput(prepared, to: web) else { Issue.record("Consumed reservation rebound"); return }
        #expect(!f.coordinator.cancelPreparedOutput(prepared))
        await f.close(web)
    }
    @Test func freshEngineAfterRetirementIsRegisteredAndQuiesceRetiresThatExactInstance() async throws {
        let f = OutputCoordinatorFixture(), old = RetirementTestEngine(.local)
        f.scope.current = outputScope(engine: .local, from: f.scope.current)
        let first = try f.bind(await f.prepare(), to: old)
        let oldEvent = try #require(f.coordinator.bindMediaEvents(first, engine: old, nativeMediaID: UUID()))
        f.scope.current = outputScope(engine: .web, from: f.scope.current)
        let waiting = Task { await f.coordinator.prepareOutput(f.scope.current) }
        await old.waitForRevocation()
        #expect(!first.isCurrent && !oldEvent.isCurrent)
        old.confirm()
        let prepared = try preparedValue(await waiting.value)
        let fresh = RetirementTestEngine(.web)
        let permit = try f.bind(prepared, to: fresh)
        #expect(permit.authorizes(fresh) && !permit.authorizes(old) && fresh.calls == 0)
        f.coordinator.quiesce()
        #expect(fresh.calls == 1 && old.calls == 1 && !permit.isCurrent)
        fresh.confirm(); #expect(await f.coordinator.settle() == .quiet)
    }
    @Test func sameWebNextItemAndPauseSeekCommandsRetainOneInstanceAndRejectOldCallbacks() async throws {
        let f = OutputCoordinatorFixture(), engine = RetirementTestEngine(.web)
        var permit = try f.bind(await f.prepare(), to: engine)
        var event = try #require(f.coordinator.bindMediaEvents(permit, engine: engine, nativeMediaID: UUID()))
        for index in 0..<3 {
            let old = permit, oldEvent = event
            f.scope.current = outputScope(nextItem: index == 0, from: f.scope.current)
            permit = try boundValue(f.coordinator.retargetOutput(old, to: f.scope.current))
            #expect(!old.isCurrent && !oldEvent.isCurrent && !f.coordinator.acceptsEvent(oldEvent))
            #expect(permit.authorizes(engine) && engine.calls == 0)
            // Nothing relabels the old callback with this new permit.
            #expect(!event.isCurrent)
            event = try #require(f.coordinator.bindMediaEvents(permit, engine: engine, nativeMediaID: UUID()))
            #expect(f.coordinator.acceptsEvent(event))
        }
        #expect(engine.effects == [.nextItemPreparation, .command, .command])
        #expect(engine.pauses == 1 && engine.mutes == 1)
        await f.close(engine)
    }
    @Test func sameOwnerPrepareRequiresRetargetWithoutRetiringOrReplacingTheEngine() async throws {
        let f = OutputCoordinatorFixture(), engine = RetirementTestEngine(.web)
        let permit = try f.bind(await f.prepare(), to: engine)
        f.scope.current = outputScope(nextItem: true, from: f.scope.current)
        guard case .blocked(.retargetRequired) = await f.coordinator.prepareOutput(f.scope.current) else { Issue.record("Expected retarget requirement"); return }
        #expect(engine.calls == 0)
        let rebound = try boundValue(f.coordinator.retargetOutput(permit, to: f.scope.current))
        #expect(rebound.authorizes(engine))
        await f.close(engine)
    }
    @Test func everyOwnerOccurrenceItemEngineAndIntentChangeDuringRetirementRejectsPreparation() async throws {
        for field in 0..<8 {
            let f = OutputCoordinatorFixture(), engine = RetirementTestEngine(.web)
            _ = try f.bind(await f.prepare(), to: engine)
            let target = outputScope(engine: .local, from: f.scope.current)
            f.scope.current = target
            let waiting = Task { await f.coordinator.prepareOutput(target) }
            await engine.waitForRevocation()
            f.scope.current = outputScope(changing: field, from: target)
            engine.confirm()
            guard case .blocked = await waiting.value else { Issue.record("Stale scope prepared"); continue }
            #expect(f.coordinator.permit == nil && engine.calls == 1)
        }
    }
    @Test func supersededPreparedPermitCannotBindOrDropTheNewReservation() async throws {
        let admission = PlaybackOutputAdmission(), f = OutputCoordinatorFixture(admission: admission)
        let old = try await f.prepare()
        f.scope.current = outputScope(from: f.scope.current)
        let latest = try await f.prepare(), engine = RetirementTestEngine(.web)
        #expect(!old.isCurrent && latest.isCurrent)
        #expect(!f.coordinator.cancelPreparedOutput(old))
        guard case .blocked = f.coordinator.bindOutput(old, to: engine) else { Issue.record("Superseded reservation bound"); return }
        #expect(f.coordinator.cancelPreparedOutput(latest) && !latest.isCurrent)
        let other = OutputCoordinatorFixture(admission: admission), next = try await other.prepare()
        #expect(next.isCurrent && engine.calls == 0)
        #expect(other.coordinator.cancelPreparedOutput(next))
    }
    @Test func canceledPreparationAfterActualQuietReleasesAdmissionWithoutActivatingAnEngine() async throws {
        let admission = PlaybackOutputAdmission(), f = OutputCoordinatorFixture(admission: admission)
        let engine = RetirementTestEngine(.web)
        _ = try f.bind(await f.prepare(), to: engine)
        f.scope.current = outputScope(engine: .local, from: f.scope.current)
        let waiting = Task { await f.coordinator.prepareOutput(f.scope.current) }
        await engine.waitForRevocation(); engine.confirm()
        let prepared = try preparedValue(await waiting.value)
        // A separately retained asset/read job is not output authority.
        let retainedRead = RetirementTestResource()
        #expect(f.coordinator.cancelPreparedOutput(prepared))
        let other = OutputCoordinatorFixture(admission: admission), next = try await other.prepare()
        #expect(next.isCurrent && engine.calls == 1)
        withExtendedLifetime(retainedRead) { #expect(other.coordinator.cancelPreparedOutput(next)) }
    }
    @Test func changedScopeCannotBindAPreparedReservationAndStaleDropStillReleasesIt() async throws {
        for field in 0..<8 {
            let admission = PlaybackOutputAdmission(), f = OutputCoordinatorFixture(admission: admission)
            let prepared = try await f.prepare(), engine = RetirementTestEngine(.web)
            f.scope.current = outputScope(changing: field, from: f.scope.current)
            #expect(!prepared.isCurrent)
            guard case .blocked = f.coordinator.bindOutput(prepared, to: engine) else { Issue.record("Stale preparation bound"); continue }
            #expect(engine.calls == 0 && f.coordinator.cancelPreparedOutput(prepared))
            let other = OutputCoordinatorFixture(admission: admission), next = try await other.prepare()
            #expect(other.coordinator.cancelPreparedOutput(next))
        }
    }
    @Test func nonincreasingIntentCannotRebindCommandsOrMediaEvents() async throws {
        let f = OutputCoordinatorFixture(), engine = RetirementTestEngine(.web)
        let old = try f.bind(await f.prepare(), to: engine)
        let event = try #require(f.coordinator.bindMediaEvents(old, engine: engine, nativeMediaID: UUID()))
        guard case .blocked(.stale) = f.coordinator.retargetOutput(old, to: old.scope) else { Issue.record("Nonincreasing intent rebound"); return }
        #expect(old.isCurrent && event.isCurrent && engine.effects.isEmpty)
        await f.close(engine)
    }
    @Test func staleAssetFailureCannotRetireTheNewerBoundIntent() async throws {
        let f = OutputCoordinatorFixture(), engine = RetirementTestEngine(.web)
        let old = try f.bind(await f.prepare(), to: engine)
        f.scope.current = outputScope(nextItem: true, from: f.scope.current)
        let current = try boundValue(f.coordinator.retargetOutput(old, to: f.scope.current))
        #expect(f.coordinator.retireOutput(old) == nil && engine.calls == 0 && current.isCurrent)
        let retirement = try #require(f.coordinator.retireOutput(current))
        #expect(engine.calls == 1 && !current.isCurrent && engine.pauses == 1)
        engine.confirm(); #expect((await retirement.settle()).outcome == .confirmed)
        #expect(await f.coordinator.settle() == .quiet)
    }
    @Test func crossSessionProfileAccountAndSourceCannotReuseTheBoundEngine() async throws {
        for field in [0, 1, 2, 5] {
            let f = OutputCoordinatorFixture(), engine = RetirementTestEngine(.web)
            let old = try f.bind(await f.prepare(), to: engine)
            f.scope.current = outputScope(changing: field, from: f.scope.current)
            guard case .blocked(.retirementRequired) = f.coordinator.retargetOutput(old, to: f.scope.current) else { Issue.record("Cross-owner reuse accepted"); return }
            #expect(engine.effects.isEmpty && engine.calls == 0)
            let waiting = Task { await f.coordinator.prepareOutput(f.scope.current) }
            await engine.waitForRevocation(); engine.confirm()
            let prepared = try preparedValue(await waiting.value)
            #expect(f.coordinator.cancelPreparedOutput(prepared))
        }
    }
    @Test func timeoutBlocksAnotherProfileAndQuitReturnsWithoutTheMissingCallback() async throws {
        let admission = PlaybackOutputAdmission(), f = OutputCoordinatorFixture(admission: admission)
        let engine = RetirementTestEngine(.web), permit = try f.bind(await f.prepare(), to: engine)
        f.coordinator.quiesce(); engine.timeout()
        #expect(!permit.isCurrent)
        #expect(await f.coordinator.settle() == .blocked(.unconfirmed))
        let other = OutputCoordinatorFixture(admission: admission)
        guard case .blocked(.busy) = await other.coordinator.prepareOutput(other.scope.current) else { Issue.record("Uncertain retirement released admission"); return }
        engine.confirm()
        #expect(await f.coordinator.settle() == .quiet && f.coordinator.permit == nil)
        let prepared = try await other.prepare()
        #expect(other.coordinator.cancelPreparedOutput(prepared))
    }
    @Test func cancellationOfSourceChangeCannotAdmitAnotherEngineBeforeActualSettlement() async throws {
        let admission = PlaybackOutputAdmission(), f = OutputCoordinatorFixture(admission: admission)
        let engine = RetirementTestEngine(.web)
        _ = try f.bind(await f.prepare(), to: engine)
        f.scope.current = outputScope(engine: .local, from: f.scope.current)
        let waiting = Task { await f.coordinator.prepareOutput(f.scope.current) }
        await engine.waitForRevocation(); waiting.cancel()
        guard case .blocked(.cancelled) = await waiting.value else { Issue.record("Expected bounded cancellation"); return }
        let other = OutputCoordinatorFixture(admission: admission)
        guard case .blocked(.busy) = await other.coordinator.prepareOutput(other.scope.current) else { Issue.record("Canceled native output released early"); return }
        engine.confirm()
        #expect(f.coordinator.permit == nil)
        let prepared = try await other.prepare()
        #expect(other.coordinator.cancelPreparedOutput(prepared))
    }
    @Test func wrongInstanceOrKindRetirementProofCannotReleaseOutput() async throws {
        for wrongInstance in [true, false] {
            let admission = PlaybackOutputAdmission(), f = OutputCoordinatorFixture(admission: admission)
            let engine = RetirementTestEngine(.web)
            engine.returnedInstance = wrongInstance ? UUID() : nil
            engine.returnedKind = wrongInstance ? nil : .local
            _ = try f.bind(await f.prepare(), to: engine)
            f.coordinator.quiesce(); engine.confirm()
            #expect(await f.coordinator.settle() == .blocked(.unconfirmed))
            let other = OutputCoordinatorFixture(admission: admission)
            guard case .blocked(.busy) = await other.coordinator.prepareOutput(other.scope.current) else { Issue.record("Mismatched identity released gate"); return }
        }
    }
    @Test func reentrantRetargetQuiesceRevokesImmediatelyAndRetiresOnlyTheRegisteredEngine() async throws {
        let f = OutputCoordinatorFixture(), engine = RetirementTestEngine(.web)
        let old = try f.bind(await f.prepare(), to: engine)
        let event = try #require(f.coordinator.bindMediaEvents(old, engine: engine, nativeMediaID: UUID()))
        engine.onInvalidate = { [weak coordinator = f.coordinator] in
            #expect(!old.isCurrent && !event.isCurrent)
            coordinator?.quiesce()
        }
        f.scope.current = outputScope(nextItem: true, from: f.scope.current)
        guard case .blocked = f.coordinator.retargetOutput(old, to: f.scope.current) else { Issue.record("Reentrant revoked scope rebound"); return }
        #expect(engine.calls == 1 && f.coordinator.permit == nil)
        engine.confirm(); #expect(await f.coordinator.settle() == .quiet)
    }
    @Test func reentrantRevocationDoesNotRetireTwiceOrReleaseBeforeTheExactReceipt() async throws {
        let f = OutputCoordinatorFixture(), engine = RetirementTestEngine(.web)
        let permit = try f.bind(await f.prepare(), to: engine)
        engine.onRevoke = { [weak coordinator = f.coordinator] in coordinator?.quiesce() }
        f.coordinator.quiesce()
        #expect(engine.calls == 1 && !permit.isCurrent)
        engine.confirm(); #expect(await f.coordinator.settle() == .quiet)
    }
    @Test func retiredAndUnregisteredEnginesCannotObtainOutputOrEventAuthority() async throws {
        let f = OutputCoordinatorFixture(), engine = RetirementTestEngine(.web)
        let prepared = try await f.prepare()
        _ = engine.revokeOutput(); engine.confirm()
        guard case .blocked = f.coordinator.bindOutput(prepared, to: engine) else { Issue.record("Retired instance rebound"); return }
        let live = RetirementTestEngine(.web), permit = try f.bind(prepared, to: live)
        #expect(!permit.authorizes(engine))
        #expect(f.coordinator.bindMediaEvents(permit, engine: engine, nativeMediaID: UUID()) == nil)
        await f.close(live)
    }
}

private final class RetirementTestDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var waiter: CheckedContinuation<Void, any Error>?
    func sleep() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let ready = lock.withLock { () -> Result<Void, any Error>? in
                    if let result { return result }; waiter = continuation; return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
    func fire() { finish(.success(())) }
    private func finish(_ value: Result<Void, any Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard result == nil else { return nil }
            result = value; defer { waiter = nil }; return waiter
        }
        pending?.resume(with: value)
    }
}
@MainActor private final class RetirementTestView: PlaybackViewRetirementTarget {
    let retirementID: UUID
    var suspensions = 0, closes = 0, stateRequests = 0
    var onSuspend: (() -> Void)?
    var suspendReply: (() -> Void)?, closeReply: (() -> Void)?, stateReply: ((RetiredMediaState) -> Void)?
    init(id: UUID = UUID()) { retirementID = id }
    func suspend(_ completion: @escaping @MainActor () -> Void) { suspensions += 1; suspendReply = completion; onSuspend?() }
    func closePresentations(_ completion: @escaping @MainActor () -> Void) { closes += 1; closeReply = completion }
    func mediaState(_ completion: @escaping @MainActor (RetiredMediaState) -> Void) { stateRequests += 1; stateReply = completion }
    func finishSuspend() { let reply = suspendReply; suspendReply = nil; reply?() }
    func finishClose() { let reply = closeReply; closeReply = nil; reply?() }
    func finishState(_ state: RetiredMediaState) { let reply = stateReply; stateReply = nil; reply?(state) }
}
private final class RetirementTestResource {}
@MainActor private final class RetirementTestFactory {
    var targets: [RetirementTestView] = []
    func make(_ view: WKWebView, id: UUID, didClose: @escaping @MainActor () -> Void) -> any PlaybackViewRetirementTarget {
        let fake = RetirementTestView(id: id); targets.append(fake); return fake
    }
}
@MainActor private final class RetirementTestEngine: PlaybackOutputEngine {
    let outputInstanceID: UUID
    let outputKind: PlaybackOutputEngineKind
    var calls = 0, pauses = 0, mutes = 0
    var effects: [PlaybackOutputRetargetEffect] = []
    private(set) var isOutputRetired = false
    var operation: PlaybackOutputRetirement?
    private var deadline: RetirementTestDeadline?
    var returnedKind: PlaybackOutputEngineKind?, returnedInstance: UUID?
    var onRevoke: (() -> Void)?, onInvalidate: (() -> Void)?
    init(_ kind: PlaybackOutputEngineKind, id: UUID = UUID()) { outputKind = kind; outputInstanceID = id }
    func invalidateOutputScopes(_ effect: PlaybackOutputRetargetEffect) {
        effects.append(effect)
        if effect == .nextItemPreparation { pauses += 1; mutes += 1 }
        onInvalidate?()
    }
    func revokeOutput() -> PlaybackOutputRetirement {
        if let operation { return operation }
        calls += 1; isOutputRetired = true; onRevoke?()
        let clock = RetirementTestDeadline(); deadline = clock
        let value = PlaybackOutputRetirement(engine: returnedKind ?? outputKind, instanceID: returnedInstance ?? outputInstanceID,
            retaining: RetirementTestResource(), sleep: clock.sleep)
        operation = value; return value
    }
    func confirm() { if let operation { operation.confirmQuiet(ticket: operation.ticket) } }
    func timeout() { deadline?.fire() }
    func waitForRevocation() async {
        for _ in 0..<1_000 { if calls > 0 { return }; await Task.yield() }
        Issue.record("Synthetic retirement did not start")
    }
}
@MainActor private final class OutputScopeBox { var current: PlaybackOutputScope; init(_ scope: PlaybackOutputScope) { current = scope } }
@MainActor private final class OutputCoordinatorFixture {
    let scope: OutputScopeBox
    let coordinator: PlaybackOutputCoordinator
    init(admission: PlaybackOutputAdmission? = nil) {
        scope = OutputScopeBox(outputScope())
        let scope = scope
        coordinator = PlaybackOutputCoordinator(admission: admission ?? PlaybackOutputAdmission(), isCurrent: { scope.current == $0 })
    }
    func prepare() async throws -> PreparedPlaybackOutputPermit { try preparedValue(await coordinator.prepareOutput(scope.current)) }
    func bind(_ prepared: PreparedPlaybackOutputPermit, to engine: RetirementTestEngine) throws -> PlaybackOutputPermit {
        try boundValue(coordinator.bindOutput(prepared, to: engine))
    }
    func close(_ engine: RetirementTestEngine) async { coordinator.quiesce(); engine.confirm(); _ = await coordinator.settle() }
}
private enum OutputFixtureError: Error { case blocked }
@MainActor private func preparedValue(_ result: PlaybackOutputPreparationResult) throws -> PreparedPlaybackOutputPermit {
    guard case let .prepared(value) = result else { Issue.record("Expected preparation"); throw OutputFixtureError.blocked }
    return value
}
@MainActor private func boundValue(_ result: PlaybackOutputAdmissionResult) throws -> PlaybackOutputPermit {
    guard case let .permitted(value) = result else { Issue.record("Expected exact engine binding"); throw OutputFixtureError.blocked }
    return value
}
private func outputScope(changing field: Int? = nil, engine: PlaybackOutputEngineKind? = nil, nextItem: Bool = false,
                         from old: PlaybackOutputScope? = nil) -> PlaybackOutputScope {
    let initial = old ?? .init(sessionID: UUID(), profileGeneration: UUID(), accountGeneration: UUID(),
        occurrence: .init(sessionID: UUID(), entryID: UUID(), trackID: "abcDEF12_-3", generation: 1),
        engine: .web, itemID: UUID(), intentRevision: 1)
    return .init(sessionID: field == 0 ? UUID() : initial.sessionID,
        profileGeneration: field == 1 ? UUID() : initial.profileGeneration,
        accountGeneration: field == 2 ? UUID() : initial.accountGeneration,
        occurrence: field == 3 || nextItem ? .init(sessionID: initial.occurrence.sessionID, entryID: UUID(), trackID: initial.occurrence.trackID, generation: 1) :
            field == 4 ? .init(sessionID: initial.occurrence.sessionID, entryID: initial.occurrence.entryID, trackID: initial.occurrence.trackID, generation: 2) : initial.occurrence,
        engine: engine ?? (field == 5 ? (initial.engine == .web ? .local : .web) : initial.engine),
        itemID: field == 6 || nextItem ? UUID() : initial.itemID,
        intentRevision: (old != nil && field == nil) || field == 7 ? initial.intentRevision + 1 : initial.intentRevision)
}
