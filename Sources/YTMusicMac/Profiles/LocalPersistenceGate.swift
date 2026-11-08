import Foundation

/// Checked inside a storage actor immediately before writing. Rotating the
/// token also rejects a queued save after an off → on setting change.
final class LocalPersistenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    private var revision = UUID()
    var token: UUID { lock.withLock { revision } }
    func setEnabled(_ value: Bool) { lock.withLock { enabled = value; revision = UUID() } }
    func accepts(_ token: UUID) -> Bool { lock.withLock { enabled && revision == token } }
}
