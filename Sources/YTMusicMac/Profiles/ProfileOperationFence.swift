import Foundation

/// Revokes new native work synchronously, then waits for already accepted
/// operations to finish their own account-scoped outcome and journal handling.
@MainActor
final class ProfileOperationFence {
    private var accepting = true
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func begin() -> Bool { guard accepting else { return false }; count += 1; return true }
    func end() {
        precondition(count > 0)
        count -= 1
        if count == 0 { let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
    }
    func quiesce() { accepting = false }
    func resume() { accepting = true }
    func waitForIdle() async {
        guard count > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
