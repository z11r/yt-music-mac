import Foundation

/// Synchronous account/opt-out fence shared with the UI. Revocation cancels an
/// already registered request task without waiting for the coordinator actor.
final class ScrobbleAuthorizationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var scope = UUID()
    private var enabled = false
    private var revision = UUID()
    private var cancellation: (id: UUID, action: @Sendable () -> Void)?
    func revoke(to scope: UUID) {
        lock.lock()
        self.scope = scope; revision = UUID(); enabled = false
        let cancellation = self.cancellation; self.cancellation = nil
        lock.unlock()
        cancellation?.action()
    }
    /// Starts a UI configuration action. Older asynchronous actions cannot
    /// re-enable sending after a later opt-out, disconnect, or token change.
    func changeIntent(scope: UUID) -> UUID? {
        lock.lock()
        guard self.scope == scope else { lock.unlock(); return nil }
        revision = UUID(); enabled = false
        let value = revision
        let cancellation = self.cancellation; self.cancellation = nil
        lock.unlock()
        cancellation?.action()
        return value
    }
    func currentRevision(scope: UUID) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return self.scope == scope ? revision : nil
    }
    func matches(scope: UUID, revision: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.scope == scope && self.revision == revision
    }
    func activate(scope: UUID, revision: UUID) {
        lock.lock(); defer { lock.unlock() }
        if self.scope == scope && self.revision == revision { enabled = true }
    }
    func matches(scope: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.scope == scope
    }
    func disable(scope: UUID) {
        lock.lock()
        let accepted = self.scope == scope
        let cancellation = accepted ? self.cancellation : nil
        if accepted { enabled = false; self.cancellation = nil }
        lock.unlock()
        cancellation?.action()
    }
    func allows(scope: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.scope == scope && enabled
    }
    func install(scope: UUID, id: UUID, cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        let accepted = self.scope == scope && enabled
        if accepted { cancellation = (id, cancel) }
        lock.unlock()
        if !accepted { cancel() }
    }
    func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if cancellation?.id == id { cancellation = nil }
    }
}
