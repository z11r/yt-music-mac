import Foundation
import WebKit

/// Only genuinely unresolved legacy pause/close calls retain a view here.
/// Overflow makes later output handoff fail closed; it does not invent a receipt.
@MainActor final class RetiringPlaybackViews {
    struct Snapshot { let id: UUID; let resource: AnyObject }
    private struct Entry { let resource: AnyObject; var paused = false; var closed = false }
    private var entries: [UUID: Entry] = [:]
    private let limit: Int
    private(set) var historyIsComplete = true
    var snapshots: [Snapshot] { entries.map { .init(id: $0.key, resource: $0.value.resource) } }
    init(limit: Int = 7) { self.limit = min(7, max(1, limit)) }
    @discardableResult func remember(_ resource: AnyObject, id: UUID) -> Bool {
        guard historyIsComplete, entries[id] == nil, entries.count < limit else {
            historyIsComplete = false; return false
        }
        entries[id] = .init(resource: resource); return true
    }
    func paused(_ id: UUID) { entries[id]?.paused = true; removeIfSettled(id) }
    func closed(_ id: UUID) { entries[id]?.closed = true; removeIfSettled(id) }
    func confirmedQuiet(_ ids: [UUID]) { for id in ids { entries[id] = nil } }
    private func removeIfSettled(_ id: UUID) {
        if entries[id]?.paused == true, entries[id]?.closed == true { entries[id] = nil }
    }
}

/// Irreversible for one WebPlayer instance. A future facade creates a fresh web
/// engine under a new permit; authentication can never release this hold.
@MainActor final class WebPlaybackOutputHold {
    private(set) var isHeld = false
    private let ledger: PlaybackViewRetirementLedger
    var operation: PlaybackOutputRetirement? { ledger.operation }
    init(instanceID: UUID = UUID(), sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }) {
        ledger = PlaybackViewRetirementLedger(instanceID: instanceID, sleep: sleep)
    }
    func revoke(historyIsComplete: Bool, willRevoke: () -> Void,
                targets: () -> [any PlaybackViewRetirementTarget]) -> PlaybackOutputRetirement {
        if isHeld { return ledger.reserve() }
        isHeld = true
        _ = ledger.reserve()
        willRevoke()
        return ledger.begin(targets(), historyIsComplete: historyIsComplete)
    }
}

typealias WebPlaybackRetirementTargetFactory = @MainActor (WKWebView, UUID, @escaping @MainActor () -> Void) -> any PlaybackViewRetirementTarget

/// This adapter is inert until the future facade explicitly revokes output.
@MainActor final class WebPlayerOutputAdapter: PlaybackOutputEngine {
    let outputKind = PlaybackOutputEngineKind.web
    private let player: WebPlayer
    var outputInstanceID: UUID { player.outputInstanceID }
    var isOutputRetired: Bool { player.isOutputOwnershipHeld }
    init(player: WebPlayer) { self.player = player }
    func invalidateOutputScopes(_ effect: PlaybackOutputRetargetEffect) { player.invalidateOutputScopesForRetarget(effect) }
    func revokeOutput() -> PlaybackOutputRetirement { player.revokeOutputForHandoff() }
}

@MainActor final class WKPlaybackRetirementTarget: PlaybackViewRetirementTarget {
    let retirementID: UUID
    private let view: WKWebView
    private let didClose: () -> Void
    init(view: WKWebView, id: UUID, didClose: @escaping () -> Void) {
        self.view = view; retirementID = id; self.didClose = didClose
    }
    func suspend(_ completion: @escaping @MainActor () -> Void) {
        view.setAllMediaPlaybackSuspended(true, completionHandler: completion)
    }
    func closePresentations(_ completion: @escaping @MainActor () -> Void) {
        view.closeAllMediaPresentations { [view, didClose] in
            if let before = view.previousKeyView, before.nextKeyView === view {
                let after = view.nextKeyView
                before.nextKeyView = after.map { $0.isDescendant(of: view) } ?? true ? nil : after
            }
            view.nextKeyView = nil; view.removeFromSuperview()
            didClose(); completion()
        }
    }
    func mediaState(_ completion: @escaping @MainActor (RetiredMediaState) -> Void) {
        view.requestMediaPlaybackState { state in
            switch state {
            case .none: completion(.none)
            case .suspended: completion(.suspended)
            case .paused: completion(.paused)
            case .playing: completion(.playing)
            @unknown default: completion(.unknown)
            }
        }
    }
}
