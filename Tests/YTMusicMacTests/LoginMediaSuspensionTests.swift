import Foundation
import Testing
@testable import YTMusicMac

@MainActor @Suite("Login views wait for exact sticky suspension")
struct LoginMediaSuspensionTests {
    @Test func anIdleGateDoesNoWorkAndNeverAuthorizesAnUnregisteredView() {
        let clock = LoginSuspensionClock(), gate = LoginMediaSuspensionGate(sleep: clock.sleep)
        let view = LoginSuspensionView()
        #expect(gate.canCreateView && !gate.hasPendingSuspension && !gate.isReady(view))
        #expect(clock.calls == 0 && view.calls == 0)
    }
    @Test func noLoadOrNavigationAuthorityExistsBeforeActualAcknowledgment() {
        let clock = LoginSuspensionClock(), gate = LoginMediaSuspensionGate(sleep: clock.sleep)
        let view = LoginSuspensionView(); var loads = 0
        #expect(gate.begin(view, onReady: { loads += 1 }, onBlocked: { Issue.record("Unexpected block") }) == .waiting)
        #expect(view.calls == 1 && loads == 0 && !gate.isReady(view) && !gate.canCreateView)
        view.finish()
        #expect(loads == 1 && gate.isReady(view) && !gate.hasPendingSuspension)
        gate.revoke()
    }
    @Test func synchronousAcknowledgmentSeesRegisteredExactIdentity() {
        let gate = LoginMediaSuspensionGate(sleep: LoginSuspensionClock().sleep), view = LoginSuspensionView()
        view.synchronous = true; var ready = false
        #expect(gate.begin(view, onReady: { ready = gate.isReady(view) }, onBlocked: {}) == .ready)
        #expect(ready && gate.isReady(view))
        gate.revoke()
    }
    @Test func closeRevokesLoadAndReplacementWaitsForTheOldNativeCallToActuallySettle() {
        let gate = LoginMediaSuspensionGate(sleep: LoginSuspensionClock().sleep)
        let old = LoginSuspensionView(), replacement = LoginSuspensionView(); var loads = 0
        gate.begin(old, onReady: { loads += 1 }, onBlocked: {})
        gate.revoke()
        #expect(!gate.isReady(old) && !gate.canCreateView && gate.hasPendingSuspension)
        #expect(gate.begin(replacement, onReady: { loads += 1 }, onBlocked: {}) == .blocked)
        #expect(replacement.calls == 0)
        old.finish()
        #expect(loads == 0 && gate.canCreateView)
        gate.begin(replacement, onReady: { loads += 1 }, onBlocked: {})
        #expect(loads == 0 && !gate.isReady(replacement))
        replacement.finish(); #expect(loads == 1 && gate.isReady(replacement))
        gate.revoke()
    }
    @Test func deadlineFailsClosedAndLateAcknowledgmentCannotLoadOrAutomaticallyRetry() async {
        let clock = LoginSuspensionClock(), gate = LoginMediaSuspensionGate(sleep: clock.sleep)
        let view = LoginSuspensionView(); var loads = 0, blocks = 0
        gate.begin(view, onReady: { loads += 1 }, onBlocked: { blocks += 1 })
        clock.fire(); await yieldUntil { blocks == 1 }
        #expect(blocks == 1 && loads == 0 && !gate.isReady(view) && gate.hasPendingSuspension)
        view.finish()
        #expect(!gate.hasPendingSuspension && !gate.isReady(view) && !gate.canCreateView && loads == 0)
        let next = LoginSuspensionView()
        #expect(gate.begin(next, onReady: { loads += 1 }, onBlocked: {}) == .blocked)
        #expect(next.calls == 0)
        gate.revoke()
        #expect(gate.canCreateView)
    }
    @Test func duplicateOldCallbacksCannotAuthorizeAReplacementOrRunLoadTwice() {
        let gate = LoginMediaSuspensionGate(sleep: LoginSuspensionClock().sleep), old = LoginSuspensionView()
        var loads = 0
        gate.begin(old, onReady: { loads += 1 }, onBlocked: {})
        let oldReply = old.reply
        old.finish(); oldReply?()
        #expect(loads == 1)
        gate.revoke()
        let next = LoginSuspensionView()
        gate.begin(next, onReady: { loads += 1 }, onBlocked: {})
        oldReply?()
        #expect(!gate.isReady(next) && gate.hasPendingSuspension && loads == 1)
        next.finish(); #expect(gate.isReady(next) && loads == 2)
        gate.revoke()
    }
    @Test func aDifferentObjectCannotReuseAnAcknowledgedIdentifier() {
        let gate = LoginMediaSuspensionGate(sleep: LoginSuspensionClock().sleep), view = LoginSuspensionView()
        gate.begin(view, onReady: {}, onBlocked: {}); view.finish()
        let impostor = LoginSuspensionView(id: view.suspensionID)
        #expect(gate.isReady(view) && !gate.isReady(impostor))
        gate.revoke()
        #expect(!gate.isReady(view) && !gate.isReady(impostor))
    }
    @Test func repeatedOpenDoesNotLaunchAdditionalSuspensionsOrReplacePendingCallbacks() {
        let gate = LoginMediaSuspensionGate(sleep: LoginSuspensionClock().sleep), view = LoginSuspensionView()
        var first = 0, second = 0
        gate.begin(view, onReady: { first += 1 }, onBlocked: {})
        for _ in 0..<30 {
            #expect(gate.begin(view, onReady: { second += 1 }, onBlocked: {}) == .blocked)
        }
        #expect(view.calls == 1)
        view.finish()
        #expect(first == 1 && second == 0)
        gate.revoke()
    }
    @Test func reentrantReadyCloseCannotLeaveAuthorizationOrReleaseANewerView() {
        let gate = LoginMediaSuspensionGate(sleep: LoginSuspensionClock().sleep), view = LoginSuspensionView()
        let next = LoginSuspensionView()
        gate.begin(view, onReady: {
            #expect(gate.isReady(view))
            gate.revoke()
            gate.begin(next, onReady: {}, onBlocked: {})
        }, onBlocked: {})
        view.finish()
        #expect(!gate.isReady(view) && !gate.isReady(next) && next.calls == 1)
        next.finish(); #expect(gate.isReady(next))
        gate.revoke()
    }
    @Test func reentrantDeadlineCloseCannotStartAnotherUnresolvedNativeCall() async {
        let clock = LoginSuspensionClock(), gate = LoginMediaSuspensionGate(sleep: clock.sleep)
        let view = LoginSuspensionView(), next = LoginSuspensionView(); var blocked = false
        gate.begin(view, onReady: { Issue.record("Late load") }, onBlocked: {
            blocked = true; gate.revoke()
            #expect(gate.begin(next, onReady: {}, onBlocked: {}) == .blocked)
        })
        clock.fire(); await yieldUntil { blocked }
        #expect(next.calls == 0 && gate.hasPendingSuspension)
        view.finish(); #expect(gate.canCreateView)
    }
    @Test func pendingExactResourceSurvivesCloseUntilNativeSettlement() {
        let gate = LoginMediaSuspensionGate(sleep: LoginSuspensionClock().sleep)
        var view: LoginSuspensionView? = LoginSuspensionView()
        weak var resource = view
        defer { resource = nil }
        gate.begin(view!, onReady: { Issue.record("Revoked load") }, onBlocked: {})
        gate.revoke(); view = nil
        #expect(resource != nil && !gate.canCreateView)
        resource?.finish()
        #expect(resource == nil && gate.canCreateView)
    }
    @Test func closeCancelsTheResponseDeadlineWithoutGrantingOutput() async {
        let clock = LoginSuspensionClock(), gate = LoginMediaSuspensionGate(sleep: clock.sleep), view = LoginSuspensionView()
        var blocks = 0, loads = 0
        gate.begin(view, onReady: { loads += 1 }, onBlocked: { blocks += 1 })
        gate.revoke(); clock.fire()
        for _ in 0..<20 { await Task.yield() }
        #expect(blocks == 0 && loads == 0 && gate.hasPendingSuspension && !gate.isReady(view))
        view.finish(); #expect(gate.canCreateView)
    }
    @Test func safetyFailureCopyHasEnglishAndFrenchResources() throws {
        let key = "Could not prepare the account page safely. Close Account and try again."
        for language in ["en", "fr"] {
            let path = try #require(AppLocalization.bundle.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            let value = bundle.localizedString(forKey: key, value: "missing", table: "LoginMedia")
            #expect(value != "missing" && !value.isEmpty)
            if language == "fr" { #expect(value != key) }
        }
    }
}

@MainActor private final class LoginSuspensionView: LoginMediaSuspensionTarget {
    let suspensionID: UUID
    var calls = 0, synchronous = false
    var reply: (() -> Void)?
    init(id: UUID = UUID()) { suspensionID = id }
    func suspendMedia(_ completion: @escaping @MainActor () -> Void) {
        calls += 1; reply = completion
        if synchronous { finish() }
    }
    func finish() { let callback = reply; reply = nil; callback?() }
}
private final class LoginSuspensionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var waiter: CheckedContinuation<Void, any Error>?
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func sleep() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let ready = lock.withLock { () -> Result<Void, any Error>? in
                    count += 1
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
@MainActor private func yieldUntil(_ condition: () -> Bool) async {
    for _ in 0..<1_000 { if condition() { return }; await Task.yield() }
    Issue.record("Synthetic suspension deadline did not complete")
}
