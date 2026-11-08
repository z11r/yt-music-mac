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

@MainActor @Suite("Source-neutral output admission foundation")
struct PlaybackOutputCoordinatorTests {
    @Test func constructionIsInertAndOutputIsGrantedOnlyAfterEveryEngineReceipt() async throws {
        let f = OutputCoordinatorFixture()
        #expect(f.web.calls == 0 && f.local.calls == 0 && f.coordinator.permit == nil)
        let request = Task { await f.coordinator.requestOutput(f.scope.current) }
        await f.waitForRevocation()
        #expect(f.web.revoked && f.local.revoked && f.coordinator.permit == nil)
        f.web.confirm(); #expect(f.coordinator.permit == nil)
        f.local.confirm()
        guard case let .permitted(permit) = await request.value else { Issue.record("Expected confirmed admission"); return }
        #expect(permit.isCurrent && f.coordinator.acceptsEvent(scope: f.scope.current, permitID: permit.id))
        #expect(!f.coordinator.acceptsEvent(scope: f.scope.current, permitID: UUID()))
        await f.close()
    }
    @Test func everyOwnerOccurrenceItemEngineAndIntentChangeDuringRetirementRejectsActivation() async {
        for field in 0..<8 {
            let f = OutputCoordinatorFixture(), expected = f.scope.current
            let request = Task { await f.coordinator.requestOutput(expected) }
            await f.waitForRevocation()
            f.scope.current = outputScope(changing: field, from: expected)
            f.web.confirm(); f.local.confirm()
            guard case .blocked = await request.value else { Issue.record("Stale scope was admitted"); continue }
            #expect(f.coordinator.permit == nil)
        }
    }
    @Test func uncertainOldOwnerBlocksAnotherProfileButQuitSettlementReturnsWithoutTheMissingCallback() async {
        let admission = PlaybackOutputAdmission(), first = OutputCoordinatorFixture(admission: admission)
        let request = Task { await first.coordinator.requestOutput(first.scope.current) }
        await first.waitForRevocation()
        first.web.timeout(); first.local.confirm()
        guard case .blocked(.timedOut) = await request.value else { Issue.record("Expected deadline"); return }
        #expect(await first.coordinator.settle() == .blocked(.unconfirmed))
        let next = OutputCoordinatorFixture(admission: admission)
        guard case .blocked(.busy) = await next.coordinator.requestOutput(next.scope.current) else { Issue.record("Uncertain owner released output"); return }
        #expect(next.web.calls == 0 && next.local.calls == 0)
        first.web.confirm()
        #expect(first.coordinator.permit == nil)
        let fresh = Task { await next.coordinator.requestOutput(next.scope.current) }
        await next.waitForRevocation(); next.web.confirm(); next.local.confirm()
        guard case .permitted = await fresh.value else { Issue.record("Fresh explicit admission failed"); return }
        await next.close()
    }
    @Test func mismatchedEngineReceiptsCannotReleaseUnknownOutputAuthority() async {
        let admission = PlaybackOutputAdmission(), f = OutputCoordinatorFixture(admission: admission)
        f.web.returnedKind = .local
        guard case .blocked(.unconfirmed) = await f.coordinator.requestOutput(f.scope.current) else {
            Issue.record("Wrong engine receipt admitted output"); return
        }
        f.web.confirm(); f.local.confirm()
        #expect(await f.coordinator.settle() == .blocked(.unconfirmed))
        let replacement = OutputCoordinatorFixture(admission: admission)
        guard case .blocked(.busy) = await replacement.coordinator.requestOutput(replacement.scope.current) else {
            Issue.record("Mismatched proof released output authority"); return
        }
        #expect(replacement.web.calls == 0 && replacement.local.calls == 0)
    }
    @Test func cancellationAndQuiesceCannotReviveAnOldIntentOrCreateMoreRetirements() async {
        let f = OutputCoordinatorFixture()
        let request = Task { await f.coordinator.requestOutput(f.scope.current) }
        await f.waitForRevocation(); request.cancel()
        guard case .blocked = await request.value else { Issue.record("Canceled request was admitted"); return }
        f.coordinator.quiesce(); f.local.timeout()
        #expect(await f.coordinator.settle() == .blocked(.unconfirmed))
        let counts = (f.web.calls, f.local.calls)
        guard case .blocked = await f.coordinator.requestOutput(f.scope.current) else { Issue.record("Revoked coordinator admitted output"); return }
        #expect(counts == (f.web.calls, f.local.calls))
        f.web.confirm(); f.local.confirm()
        #expect(f.coordinator.permit == nil)
        #expect(await f.coordinator.settle() == .quiet)
    }
    @Test func synchronousEngineCallbacksCannotReenterAndDuplicateRetirementDuringRevocation() async {
        let f = OutputCoordinatorFixture()
        f.web.onRevoke = { [weak coordinator = f.coordinator] in coordinator?.quiesce() }
        let request = Task { await f.coordinator.requestOutput(f.scope.current) }
        await f.waitForRevocation()
        #expect(f.web.calls == 1 && f.local.calls == 1)
        f.web.confirm(); f.local.confirm()
        guard case .blocked = await request.value else { Issue.record("Reentrant revoked request was activated"); return }
        #expect(f.coordinator.permit == nil && f.web.calls == 1 && f.local.calls == 1)
        #expect(await f.coordinator.settle() == .quiet)
    }
    @Test func quiesceReturnsABlockedReceiptAtDeadlineEvenWhenAnActiveEngineNeverAcknowledges() async {
        let admission = PlaybackOutputAdmission(), f = OutputCoordinatorFixture(admission: admission)
        let request = Task { await f.coordinator.requestOutput(f.scope.current) }
        await f.waitForRevocation(); f.web.confirm(); f.local.confirm()
        guard case let .permitted(permit) = await request.value else { Issue.record("Expected initial permit"); return }
        f.coordinator.quiesce()
        #expect(!permit.isCurrent)
        f.web.timeout(); f.local.confirm()
        #expect(await f.coordinator.settle() == .blocked(.unconfirmed))
        let replacement = OutputCoordinatorFixture(admission: admission)
        guard case .blocked(.busy) = await replacement.coordinator.requestOutput(replacement.scope.current) else {
            Issue.record("Missing retirement acknowledgment released output"); return
        }
        #expect(replacement.web.calls == 0)
        f.web.confirm()
        #expect(f.coordinator.permit == nil)
    }
    @Test func activePermitIsRevokedSynchronouslyBeforeShutdownWaitAndLateEventsStayRejected() async {
        let f = OutputCoordinatorFixture()
        let request = Task { await f.coordinator.requestOutput(f.scope.current) }
        await f.waitForRevocation(); f.web.confirm(); f.local.confirm()
        guard case let .permitted(permit) = await request.value else { Issue.record("Expected permit"); return }
        f.coordinator.quiesce()
        #expect(!permit.isCurrent && f.coordinator.permit == nil)
        #expect(!f.coordinator.acceptsEvent(scope: permit.scope, permitID: permit.id))
        #expect(f.web.calls == 2 && f.local.calls == 2)
        var settled = false
        let waiting = Task { let result = await f.coordinator.settle(); settled = true; return result }
        for _ in 0..<20 { await Task.yield() }
        #expect(!settled)
        f.web.confirm(); f.local.confirm()
        #expect(await waiting.value == .quiet)
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
@MainActor private final class RetirementTestEngine: PlaybackOutputRetiring {
    let outputKind: PlaybackOutputEngineKind
    var calls = 0, revoked = false
    var operation: PlaybackOutputRetirement?
    private var deadline: RetirementTestDeadline?
    var returnedKind: PlaybackOutputEngineKind?
    var onRevoke: (() -> Void)?
    init(_ kind: PlaybackOutputEngineKind) { outputKind = kind }
    func revokeOutput() -> PlaybackOutputRetirement {
        calls += 1; revoked = true; onRevoke?()
        let clock = RetirementTestDeadline(); deadline = clock
        let value = PlaybackOutputRetirement(engine: returnedKind ?? outputKind, retaining: RetirementTestResource(), sleep: clock.sleep)
        operation = value; return value
    }
    func confirm() { if let operation { operation.confirmQuiet(ticket: operation.ticket) } }
    func timeout() { deadline?.fire() }
}
@MainActor private final class OutputScopeBox { var current: PlaybackOutputScope; init(_ scope: PlaybackOutputScope) { current = scope } }
@MainActor private final class OutputCoordinatorFixture {
    let web = RetirementTestEngine(.web), local = RetirementTestEngine(.local)
    let scope: OutputScopeBox
    let coordinator: PlaybackOutputCoordinator
    init(admission: PlaybackOutputAdmission? = nil) {
        let value = outputScope(); scope = OutputScopeBox(value)
        let scope = scope
        coordinator = PlaybackOutputCoordinator(engines: [web, local], admission: admission ?? PlaybackOutputAdmission(), isCurrent: { scope.current == $0 })
    }
    func waitForRevocation() async {
        for _ in 0..<1_000 { if web.calls > 0 && local.calls > 0 { return }; await Task.yield() }
        Issue.record("Synthetic retirement did not start")
    }
    func close() async { coordinator.quiesce(); web.confirm(); local.confirm(); _ = await coordinator.settle() }
}
private func outputScope(changing field: Int? = nil, from old: PlaybackOutputScope? = nil) -> PlaybackOutputScope {
    let initial = old ?? .init(sessionID: UUID(), profileGeneration: UUID(), accountGeneration: UUID(),
        occurrence: .init(sessionID: UUID(), entryID: UUID(), trackID: "abcDEF12_-3", generation: 1),
        engine: .local, itemID: UUID(), intentRevision: 1)
    return .init(sessionID: field == 0 ? UUID() : initial.sessionID,
        profileGeneration: field == 1 ? UUID() : initial.profileGeneration,
        accountGeneration: field == 2 ? UUID() : initial.accountGeneration,
        occurrence: field == 3 ? .init(sessionID: initial.occurrence.sessionID, entryID: UUID(), trackID: initial.occurrence.trackID, generation: 1) :
            field == 4 ? .init(sessionID: initial.occurrence.sessionID, entryID: initial.occurrence.entryID, trackID: initial.occurrence.trackID, generation: 2) : initial.occurrence,
        engine: field == 5 ? .web : initial.engine, itemID: field == 6 ? UUID() : initial.itemID,
        intentRevision: field == 7 ? initial.intentRevision + 1 : initial.intentRevision)
}
