import Foundation
import MusicCore

/// Adapters must bind itemID to a validated source/reference before admission.
/// This foundation neither opens a source nor starts an engine.
struct PlaybackOutputScope: Equatable, Sendable {
    let sessionID: UUID
    let profileGeneration: UUID
    let accountGeneration: UUID
    let occurrence: PlaybackOccurrence
    let engine: PlaybackOutputEngineKind
    let itemID: UUID
    let intentRevision: UInt64
}
@MainActor protocol PlaybackOutputRetiring: AnyObject {
    var outputKind: PlaybackOutputEngineKind { get }
    /// Synchronously revoke commands/events before returning the bounded operation.
    func revokeOutput() -> PlaybackOutputRetirement
}
@MainActor final class PlaybackOutputPermit {
    let id = UUID()
    let scope: PlaybackOutputScope
    private weak var admission: PlaybackOutputAdmission?
    fileprivate let lease: UUID
    fileprivate init(scope: PlaybackOutputScope, lease: UUID, admission: PlaybackOutputAdmission) {
        self.scope = scope; self.lease = lease; self.admission = admission
    }
    var isCurrent: Bool { admission?.accepts(self) == true }
}

/// The future app owner must inject one admission gate across local profiles.
/// There is deliberately no live/global instance or token in this foundation.
@MainActor final class PlaybackOutputAdmission {
    private struct Lease {
        let id: UUID
        let owner: UUID
        let engines: [any PlaybackOutputRetiring]
        var operations: [PlaybackOutputRetirement] = []
        var active: UUID?
        var releaseWhenQuiet = false
        var proofIsValid = true
    }
    private var lease: Lease?
    fileprivate func begin(owner: UUID, engines: [any PlaybackOutputRetiring]) -> UUID? {
        if var current = lease {
            guard current.owner == owner, !current.releaseWhenQuiet else { return nil }
            current.active = nil; lease = current
            return current.id
        }
        let id = UUID(); lease = .init(id: id, owner: owner, engines: engines)
        return id
    }
    fileprivate func attach(_ operations: [PlaybackOutputRetirement], to id: UUID) -> Bool {
        guard let current = lease, current.id == id else { return false }
        let valid = operations.count == current.engines.count &&
            Set(operations.map { $0.ticket.id }).count == operations.count &&
            zip(current.engines, operations).allSatisfy { $0.outputKind == $1.ticket.engine }
        lease?.operations = operations; lease?.proofIsValid = valid
        for operation in operations {
            operation.onConfirmedQuiet { [weak self] in self?.releaseIfQuiet(id) }
        }
        return valid
    }
    fileprivate func grant(_ scope: PlaybackOutputScope, lease id: UUID) -> PlaybackOutputPermit? {
        guard let current = lease, current.id == id, !current.releaseWhenQuiet, current.proofIsValid,
              current.operations.allSatisfy(\.isConfirmedQuiet) else { return nil }
        let permit = PlaybackOutputPermit(scope: scope, lease: id, admission: self)
        lease?.active = permit.id; lease?.operations = []
        return permit
    }
    fileprivate func block(_ id: UUID) {
        guard lease?.id == id else { return }
        lease?.active = nil; lease?.releaseWhenQuiet = true; releaseIfQuiet(id)
    }
    private func releaseIfQuiet(_ id: UUID) {
        guard let current = lease, current.id == id, current.releaseWhenQuiet, current.proofIsValid,
              !current.operations.isEmpty, current.operations.allSatisfy(\.isConfirmedQuiet) else { return }
        lease = nil
    }
    fileprivate func accepts(_ permit: PlaybackOutputPermit) -> Bool {
        lease?.id == permit.lease && lease?.active == permit.id && lease?.releaseWhenQuiet == false
    }
}

enum PlaybackOutputAdmissionResult {
    case permitted(PlaybackOutputPermit)
    case blocked(PlaybackOutputProblem)
}
enum PlaybackOutputSettlement: Equatable { case quiet, blocked(PlaybackOutputProblem) }

/// Pure ownership facade foundation. Live AppSession integration is separate.
@MainActor final class PlaybackOutputCoordinator {
    private let owner = UUID()
    private let admission: PlaybackOutputAdmission
    private let engines: [any PlaybackOutputRetiring]
    private let isCurrent: (PlaybackOutputScope) -> Bool
    private var request = UUID()
    private var lease: UUID?
    private var operations: [PlaybackOutputRetirement] = []
    private var isWorking = false
    private var revoked = false
    private var retirementProofIsValid = true
    private(set) var permit: PlaybackOutputPermit?

    init(engines: [any PlaybackOutputRetiring], admission: PlaybackOutputAdmission,
         isCurrent: @escaping (PlaybackOutputScope) -> Bool) {
        self.engines = engines; self.admission = admission; self.isCurrent = isCurrent
    }
    func requestOutput(_ scope: PlaybackOutputScope) async -> PlaybackOutputAdmissionResult {
        guard !revoked, !isWorking, !Task.isCancelled, isCurrent(scope),
              (1...2).contains(engines.count), Set(engines.map(\.outputKind)).count == engines.count,
              engines.contains(where: { $0.outputKind == scope.engine }) else { return .blocked(.stale) }
        guard let lease = admission.begin(owner: owner, engines: engines) else { return .blocked(.busy) }
        self.lease = lease; permit = nil; isWorking = true
        let id = UUID(); request = id
        // Every engine revokes synchronously; only then may a retirement wait suspend.
        operations = engines.map { $0.revokeOutput() }
        retirementProofIsValid = admission.attach(operations, to: lease)
        defer { isWorking = false }
        guard retirementProofIsValid else { revoked = true; admission.block(lease); return .blocked(.unconfirmed) }
        for operation in operations {
            let receipt = await operation.settle()
            guard receipt.ticket == operation.ticket, receipt.outcome == .confirmed else {
                revoked = true; admission.block(lease)
                if case let .blocked(problem) = receipt.outcome { return .blocked(problem) }
                return .blocked(.unconfirmed)
            }
        }
        guard !revoked, request == id, !Task.isCancelled, isCurrent(scope) else {
            admission.block(lease); return .blocked(.stale)
        }
        guard let value = admission.grant(scope, lease: lease) else { return .blocked(.unconfirmed) }
        permit = value; operations = []
        return .permitted(value)
    }
    func acceptsEvent(scope: PlaybackOutputScope, permitID: UUID) -> Bool {
        guard !revoked, let permit else { return false }
        return permit.id == permitID && permit.scope == scope && permit.isCurrent && isCurrent(scope)
    }
    func quiesce() {
        revoked = true; request = UUID(); permit = nil
        guard let lease else { return }
        if operations.isEmpty && !isWorking {
            operations = engines.map { $0.revokeOutput() }
            retirementProofIsValid = admission.attach(operations, to: lease)
        }
        admission.block(lease)
        // Revoking playback intent does not cancel the stop acknowledgment.
        // Each operation still returns within its own bounded deadline.
    }
    /// A blocked receipt lets Quit finish; it is never profile/source activation authority.
    func settle() async -> PlaybackOutputSettlement {
        guard permit == nil else { return .blocked(.outputActive) }
        for operation in operations { _ = await operation.settle() }
        return retirementProofIsValid && operations.allSatisfy(\.isConfirmedQuiet) ? .quiet : .blocked(.unconfirmed)
    }
}
