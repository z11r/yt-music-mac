import Foundation
import WebKit

@MainActor protocol LoginMediaSuspensionTarget: AnyObject {
    var suspensionID: UUID { get }
    func suspendMedia(_ completion: @escaping @MainActor () -> Void)
}

enum LoginMediaSuspensionResult: Equatable { case waiting, ready, blocked }

/// Only one native suspension can remain unresolved. No API releases suspension.
@MainActor final class LoginMediaSuspensionGate {
    @MainActor private final class Entry {
        let target: any LoginMediaSuspensionTarget
        let identity: UUID
        let object: ObjectIdentifier
        var acknowledged = false, failed = false, revoked = false
        var ready: (() -> Void)?
        var blocked: (() -> Void)?
        var deadline: Task<Void, Never>?
        init(_ target: any LoginMediaSuspensionTarget, ready: @escaping () -> Void, blocked: @escaping () -> Void) {
            self.target = target; identity = target.suspensionID; object = ObjectIdentifier(target)
            self.ready = ready; self.blocked = blocked
        }
        func matches(_ target: any LoginMediaSuspensionTarget) -> Bool {
            identity == target.suspensionID && object == ObjectIdentifier(target)
        }
    }
    private let sleep: @Sendable () async throws -> Void
    private var current: Entry?
    private var pending: Entry?
    var canCreateView: Bool { current == nil && pending == nil }
    var hasPendingSuspension: Bool { pending != nil }
    init(sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }) { self.sleep = sleep }

    @discardableResult
    func begin(_ target: any LoginMediaSuspensionTarget, onReady: @escaping () -> Void,
               onBlocked: @escaping () -> Void) -> LoginMediaSuspensionResult {
        guard canCreateView else { return .blocked }
        let entry = Entry(target, ready: onReady, blocked: onBlocked)
        current = entry; pending = entry
        entry.deadline = Task { [weak self, weak entry, sleep] in
            do { try Task.checkCancellation(); try await sleep() } catch { return }
            guard let self, let entry else { return }
            self.expire(entry)
        }
        // Install both identities before a synchronously completing adapter.
        target.suspendMedia { [weak self, entry] in self?.completed(entry) }
        return isReady(target) ? .ready : (entry.failed || entry.revoked ? .blocked : .waiting)
    }
    func isReady(_ target: any LoginMediaSuspensionTarget) -> Bool {
        guard let current else { return false }
        return current.matches(target) && current.acknowledged && !current.failed && !current.revoked && pending == nil
    }
    func revoke() {
        guard let entry = current else { return }
        current = nil; entry.revoked = true
        entry.ready = nil; entry.blocked = nil
        entry.deadline?.cancel(); entry.deadline = nil
        // A pending native callback retains its exact unloaded view until it settles.
    }
    private func expire(_ entry: Entry) {
        guard current === entry, pending === entry, !entry.failed, !entry.revoked else { return }
        entry.failed = true; entry.ready = nil
        let callback = entry.blocked; entry.blocked = nil; entry.deadline = nil
        callback?()
    }
    private func completed(_ entry: Entry) {
        guard pending === entry else { return }
        pending = nil; entry.deadline?.cancel(); entry.deadline = nil
        guard current === entry, !entry.failed, !entry.revoked,
              entry.target.suspensionID == entry.identity else { return }
        entry.acknowledged = true
        let callback = entry.ready; entry.ready = nil; entry.blocked = nil
        callback?()
    }
}

/// Created for an empty account view. Its first load waits for this exact callback.
@MainActor final class WKLoginMediaSuspensionTarget: LoginMediaSuspensionTarget {
    let suspensionID = UUID()
    private let view: WKWebView
    init(_ view: WKWebView) { self.view = view }
    func suspendMedia(_ completion: @escaping @MainActor () -> Void) {
        view.setAllMediaPlaybackSuspended(true, completionHandler: completion)
    }
}

enum LoginMediaText {
    static func text(_ key: StaticString) -> String {
        AppLocalization.bundle.localizedString(forKey: String(describing: key), value: nil, table: "LoginMedia")
    }
}
