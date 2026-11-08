import Foundation
import MusicCore

/// Stable for one acknowledged load/intent, not for each progress or volume update.
struct WebPlaybackOutputContext: Equatable, Sendable {
    let engineInstanceID: UUID
    let loadID: UUID
    let occurrence: PlaybackOccurrence
    let commandEpoch: UUID
    let minimumCommandRevision: Int
}
struct WebPlaybackOutputEvent: Sendable {
    enum Kind: Sendable {
        case state
        case progress(position: TimeInterval, duration: TimeInterval, ended: Bool)
        case ended
        case failure(message: String, reason: PlaybackFailureReason)
        case rates(EpisodeRateSnapshot?)
        case listeningInterrupted
        case outputInterrupted
    }
    let context: WebPlaybackOutputContext
    let kind: Kind
}

/// Pure acknowledgment state. Callbacks retain receipts, never read a newer identity.
struct WebPlaybackOutputObservation {
    struct Receipt: Equatable {
        let context: WebPlaybackOutputContext
        let needsBinding: Bool
        let acknowledgedCommandRevision: Int
    }
    private var latestIssuedCommandRevision = 0
    private(set) var requested: WebPlaybackOutputContext?
    private(set) var current: WebPlaybackOutputContext?
    mutating func prepare(_ context: WebPlaybackOutputContext) {
        requested = context.minimumCommandRevision >= 0 ? context : nil
        current = nil; latestIssuedCommandRevision = 0
    }
    mutating func commandIssued(_ revision: Int) {
        guard requested != nil, revision >= 0 else { return }
        latestIssuedCommandRevision = max(latestIssuedCommandRevision, revision)
    }
    mutating func revoke() { requested = nil; current = nil }
    mutating func accept(_ message: PlaybackBridgeMessage, gate: inout PlaybackEventGate) -> Receipt? {
        guard let requested, requested.loadID == message.loadID,
              PlaybackBridgeIdentity(requested.occurrence) == message.identity,
              message.commandRevision >= requested.minimumCommandRevision,
              message.commandRevision <= latestIssuedCommandRevision,
              gate.accept(message) else { return nil }
        let needsBinding = current != requested
        current = requested
        return .init(context: requested, needsBinding: needsBinding, acknowledgedCommandRevision: message.commandRevision)
    }
    func accepts(_ context: WebPlaybackOutputContext) -> Bool { current == context && requested == context }
    func matchesRequest(_ context: WebPlaybackOutputContext) -> Bool { requested == context }
}
