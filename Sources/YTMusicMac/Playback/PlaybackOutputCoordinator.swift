import Foundation
import MusicCore

/// The adapter binds itemID to a validated source; this grants no file access.
struct PlaybackOutputScope: Equatable, Sendable {
    let sessionID: UUID
    let profileGeneration: UUID
    let accountGeneration: UUID
    let occurrence: PlaybackOccurrence
    let engine: PlaybackOutputEngineKind
    let itemID: UUID
    let intentRevision: UInt64
    fileprivate func sharesOwner(with other: Self) -> Bool {
        sessionID == other.sessionID && profileGeneration == other.profileGeneration && accountGeneration == other.accountGeneration
    }
}
enum PlaybackOutputRetargetEffect: Equatable { case command, nextItemPreparation }
@MainActor protocol PlaybackOutputEngine: AnyObject {
    var outputInstanceID: UUID { get }
    var outputKind: PlaybackOutputEngineKind { get }
    /// Irreversible lifecycle state, never proof of physical silence.
    var isOutputRetired: Bool { get }
    /// Next-item preparation mutes/pauses owned output, retaining the instance.
    func invalidateOutputScopes(_ effect: PlaybackOutputRetargetEffect)
    func revokeOutput() -> PlaybackOutputRetirement
}
@MainActor final class PreparedPlaybackOutputPermit {
    let id = UUID()
    let scope: PlaybackOutputScope
    fileprivate let lease: UUID
    private weak var admission: PlaybackOutputAdmission?
    fileprivate init(scope: PlaybackOutputScope, lease: UUID, admission: PlaybackOutputAdmission) {
        self.scope = scope; self.lease = lease; self.admission = admission
    }
    var isCurrent: Bool { admission?.accepts(self) == true }
}
@MainActor final class PlaybackOutputPermit {
    let id = UUID()
    let scope: PlaybackOutputScope
    let engineInstanceID: UUID
    fileprivate let engineObject: ObjectIdentifier
    fileprivate let lease: UUID
    private weak var admission: PlaybackOutputAdmission?
    fileprivate init(scope: PlaybackOutputScope, engine: any PlaybackOutputEngine, lease: UUID, admission: PlaybackOutputAdmission) {
        self.scope = scope; engineInstanceID = engine.outputInstanceID; engineObject = ObjectIdentifier(engine)
        self.lease = lease; self.admission = admission
    }
    var isCurrent: Bool { admission?.accepts(self) == true }
    func authorizes(_ engine: any PlaybackOutputEngine) -> Bool { admission?.authorizes(self, engine: engine) == true }
}
/// The adapter creates this only after verifying an actual native media/load binding.
/// Callbacks capture it immutably; old callbacks are never retagged.
@MainActor final class PlaybackOutputEventBinding {
    let id = UUID()
    let permit: PlaybackOutputPermit
    let nativeMediaID: UUID
    private weak var admission: PlaybackOutputAdmission?
    fileprivate init(permit: PlaybackOutputPermit, nativeMediaID: UUID, admission: PlaybackOutputAdmission) {
        self.permit = permit; self.nativeMediaID = nativeMediaID; self.admission = admission
    }
    var isCurrent: Bool { admission?.accepts(self) == true }
}

/// Inject one gate across profiles. There is no live/global instance here.
@MainActor final class PlaybackOutputAdmission {
    @MainActor fileprivate final class Registration {
        let engine: any PlaybackOutputEngine
        let instanceID: UUID
        let kind: PlaybackOutputEngineKind
        let object: ObjectIdentifier
        var scope: PlaybackOutputScope
        var permitID: UUID?
        var eventID: UUID?
        var nativeMediaID: UUID?
        init(_ engine: any PlaybackOutputEngine, scope: PlaybackOutputScope) {
            self.engine = engine; instanceID = engine.outputInstanceID; kind = engine.outputKind
            object = ObjectIdentifier(engine); self.scope = scope
        }
        var instanceIsValid: Bool {
            engine.outputInstanceID == instanceID && engine.outputKind == kind && !engine.isOutputRetired
        }
        func revokeEvents() { permitID = nil; eventID = nil; nativeMediaID = nil }
    }
    private final class Lease {
        let id = UUID()
        let owner: UUID
        let allows: (PlaybackOutputScope) -> Bool
        var prepared: PreparedPlaybackOutputPermit?
        var registration: Registration?
        var retarget: UUID?
        var retiring = false
        var operation: PlaybackOutputRetirement?
        var proofIsValid = true
        var releaseWhenQuiet = false
        init(owner: UUID, allows: @escaping (PlaybackOutputScope) -> Bool) { self.owner = owner; self.allows = allows }
    }
    private var lease: Lease?
    fileprivate func registration(owner: UUID) -> Registration? { lease?.owner == owner ? lease?.registration : nil }
    fileprivate func isRetiring(owner: UUID) -> Bool { lease?.owner == owner && lease?.retiring == true }
    fileprivate func reserve(owner: UUID, allows: @escaping (PlaybackOutputScope) -> Bool) -> Bool {
        if let lease { return lease.owner == owner && lease.registration == nil && !lease.retiring && !lease.releaseWhenQuiet }
        lease = .init(owner: owner, allows: allows); return true
    }
    fileprivate func prepare(_ scope: PlaybackOutputScope, owner: UUID) -> PreparedPlaybackOutputPermit? {
        guard let lease, lease.owner == owner, lease.registration == nil, !lease.retiring,
              !lease.releaseWhenQuiet, lease.allows(scope), self.lease === lease else { return nil }
        let value = PreparedPlaybackOutputPermit(scope: scope, lease: lease.id, admission: self)
        lease.prepared = value; return value
    }
    fileprivate func cancel(_ prepared: PreparedPlaybackOutputPermit, owner: UUID) -> Bool {
        guard let lease, lease.owner == owner, lease.id == prepared.lease, lease.prepared?.id == prepared.id,
              lease.registration == nil, !lease.retiring else { return false }
        self.lease = nil; return true
    }
    fileprivate func bind(_ prepared: PreparedPlaybackOutputPermit, owner: UUID, engine: any PlaybackOutputEngine) -> PlaybackOutputPermit? {
        guard let lease, lease.owner == owner, accepts(prepared), engine.outputKind == prepared.scope.engine,
              !engine.isOutputRetired else { return nil }
        let registration = Registration(engine, scope: prepared.scope)
        let permit = PlaybackOutputPermit(scope: prepared.scope, engine: engine, lease: lease.id, admission: self)
        guard self.lease === lease, accepts(prepared), registration.instanceIsValid else { return nil }
        lease.prepared = nil; registration.permitID = permit.id; lease.registration = registration
        return permit
    }
    fileprivate func beginRetirement(owner: UUID, expectedPermit: UUID? = nil) -> Registration? {
        guard let lease, lease.owner == owner, !lease.retiring, let registration = lease.registration,
              expectedPermit == nil || registration.permitID == expectedPermit else { return nil }
        lease.retiring = true; lease.prepared = nil; lease.retarget = nil; registration.revokeEvents()
        return registration
    }
    fileprivate func attach(_ operation: PlaybackOutputRetirement, owner: UUID, registration: Registration) -> Bool {
        guard let lease, lease.owner == owner, lease.retiring, lease.registration === registration else { return false }
        let valid = operation.ticket.engine == registration.kind && operation.ticket.instanceID == registration.instanceID
        lease.operation = operation; lease.proofIsValid = valid
        operation.onConfirmedQuiet { [weak self] in self?.releaseIfQuiet(owner) }
        return valid
    }
    fileprivate func finishRetirement(owner: UUID, operation: PlaybackOutputRetirement) -> Bool {
        guard let lease, lease.owner == owner, lease.operation === operation, lease.proofIsValid,
              operation.isConfirmedQuiet, !lease.releaseWhenQuiet else { return false }
        lease.registration = nil; lease.operation = nil; lease.retiring = false; return true
    }
    fileprivate func release(owner: UUID) {
        guard let lease, lease.owner == owner else { return }
        lease.prepared = nil; lease.releaseWhenQuiet = true; lease.registration?.revokeEvents()
        releaseIfQuiet(owner)
    }
    private func releaseIfQuiet(_ owner: UUID) {
        guard let lease, lease.owner == owner, lease.releaseWhenQuiet else { return }
        if lease.registration == nil && !lease.retiring { self.lease = nil }
        else if lease.proofIsValid, lease.operation?.isConfirmedQuiet == true { self.lease = nil }
    }
    fileprivate func beginRetarget(_ permit: PlaybackOutputPermit, scope: PlaybackOutputScope, owner: UUID) -> (UUID, Registration)? {
        guard let lease, lease.owner == owner, !lease.retiring, lease.retarget == nil,
              let registration = lease.registration, registration.permitID == permit.id,
              registration.instanceID == permit.engineInstanceID, registration.object == permit.engineObject,
              registration.instanceIsValid, registration.scope.sharesOwner(with: scope),
              registration.kind == scope.engine, scope.intentRevision > registration.scope.intentRevision,
              lease.allows(scope), self.lease === lease else { return nil }
        let id = UUID(); lease.retarget = id; registration.revokeEvents()
        return (id, registration)
    }
    fileprivate func finishRetarget(_ id: UUID, scope: PlaybackOutputScope, owner: UUID) -> PlaybackOutputPermit? {
        guard let lease, lease.owner == owner, lease.retarget == id, !lease.retiring,
              let registration = lease.registration, registration.instanceIsValid, lease.allows(scope) else { return nil }
        let permit = PlaybackOutputPermit(scope: scope, engine: registration.engine, lease: lease.id, admission: self)
        guard lease.allows(scope), self.lease === lease, lease.retarget == id, !lease.retiring, registration.instanceIsValid else { return nil }
        registration.scope = scope; registration.permitID = permit.id; lease.retarget = nil
        return permit
    }
    fileprivate func accepts(_ prepared: PreparedPlaybackOutputPermit) -> Bool {
        guard let lease, lease.id == prepared.lease, lease.prepared?.id == prepared.id, lease.registration == nil,
              !lease.retiring, !lease.releaseWhenQuiet, lease.allows(prepared.scope) else { return false }
        return self.lease === lease && lease.prepared?.id == prepared.id && !lease.releaseWhenQuiet
    }
    fileprivate func accepts(_ permit: PlaybackOutputPermit) -> Bool {
        guard let lease, let registration = lease.registration, lease.id == permit.lease,
              registration.permitID == permit.id, registration.scope == permit.scope,
              registration.instanceID == permit.engineInstanceID, registration.object == permit.engineObject,
              !lease.retiring, lease.retarget == nil, !lease.releaseWhenQuiet,
              registration.instanceIsValid, lease.allows(permit.scope) else { return false }
        return self.lease === lease && !lease.retiring && lease.retarget == nil && !lease.releaseWhenQuiet && registration.permitID == permit.id
    }
    fileprivate func authorizes(_ permit: PlaybackOutputPermit, engine: any PlaybackOutputEngine) -> Bool {
        ObjectIdentifier(engine) == permit.engineObject && engine.outputInstanceID == permit.engineInstanceID && accepts(permit)
    }
    fileprivate func bindEvents(_ permit: PlaybackOutputPermit, engine: any PlaybackOutputEngine, nativeMediaID: UUID) -> PlaybackOutputEventBinding? {
        guard authorizes(permit, engine: engine), nativeMediaID != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)),
              let registration = lease?.registration else { return nil }
        let value = PlaybackOutputEventBinding(permit: permit, nativeMediaID: nativeMediaID, admission: self)
        registration.eventID = value.id; registration.nativeMediaID = nativeMediaID; return value
    }
    fileprivate func accepts(_ binding: PlaybackOutputEventBinding) -> Bool {
        accepts(binding.permit) && lease?.registration?.eventID == binding.id && lease?.registration?.nativeMediaID == binding.nativeMediaID
    }
    fileprivate func hasReservation(owner: UUID) -> Bool { lease?.owner == owner && lease?.prepared != nil }
}

enum PlaybackOutputPreparationResult { case prepared(PreparedPlaybackOutputPermit), blocked(PlaybackOutputProblem) }
enum PlaybackOutputAdmissionResult { case permitted(PlaybackOutputPermit), blocked(PlaybackOutputProblem) }
enum PlaybackOutputSettlement: Equatable { case quiet, blocked(PlaybackOutputProblem) }

/// Binding foundation; no live AppSession or native activation is installed here.
@MainActor final class PlaybackOutputCoordinator {
    private let owner = UUID()
    private let admission: PlaybackOutputAdmission
    private let isCurrent: (PlaybackOutputScope) -> Bool
    private var request = UUID()
    private var isWorking = false, isRevoking = false, revoked = false
    private var retirement: (operation: PlaybackOutputRetirement, valid: Bool)?
    private(set) var permit: PlaybackOutputPermit?
    init(admission: PlaybackOutputAdmission, isCurrent: @escaping (PlaybackOutputScope) -> Bool) {
        self.admission = admission; self.isCurrent = isCurrent
    }
    private func allows(_ scope: PlaybackOutputScope) -> Bool { !revoked && isCurrent(scope) }
    func prepareOutput(_ scope: PlaybackOutputScope) async -> PlaybackOutputPreparationResult {
        guard !isWorking else { return .blocked(.busy) }
        guard !revoked, !Task.isCancelled, isCurrent(scope) else { return .blocked(.stale) }
        isWorking = true; defer { isWorking = false }
        let id = UUID(); request = id
        if let current = admission.registration(owner: owner) {
            guard !admission.isRetiring(owner: owner) else { return .blocked(.busy) }
            if current.scope.sharesOwner(with: scope), current.kind == scope.engine { return .blocked(.retargetRequired) }
            permit = nil
            guard let operation = startRetirement() else { return .blocked(.unconfirmed) }
            let receipt = await operation.settle()
            guard receipt.outcome == .confirmed, retirement?.valid == true, operation.isConfirmedQuiet else {
                revoked = true; admission.release(owner: owner)
                if case let .blocked(problem) = receipt.outcome { return .blocked(problem) }
                return .blocked(.unconfirmed)
            }
            guard !Task.isCancelled, request == id, allows(scope), admission.finishRetirement(owner: owner, operation: operation) else {
                admission.release(owner: owner); return .blocked(.stale)
            }
        }
        guard admission.reserve(owner: owner, allows: { [weak self] in self?.allows($0) == true }),
              let prepared = admission.prepare(scope, owner: owner), prepared.isCurrent else { return .blocked(.busy) }
        return .prepared(prepared)
    }
    func cancelPreparedOutput(_ prepared: PreparedPlaybackOutputPermit) -> Bool { admission.cancel(prepared, owner: owner) }
    func bindOutput(_ prepared: PreparedPlaybackOutputPermit, to engine: any PlaybackOutputEngine) -> PlaybackOutputAdmissionResult {
        guard !revoked, !isWorking, !Task.isCancelled, allows(prepared.scope),
              let bound = admission.bind(prepared, owner: owner, engine: engine) else { return .blocked(.stale) }
        permit = bound; return .permitted(bound)
    }
    func retargetOutput(_ previous: PlaybackOutputPermit, to scope: PlaybackOutputScope) -> PlaybackOutputAdmissionResult {
        guard !isWorking else { return .blocked(.busy) }
        guard !revoked, !Task.isCancelled, allows(scope) else { return .blocked(.stale) }
        guard previous.scope.sharesOwner(with: scope), previous.scope.engine == scope.engine else { return .blocked(.retirementRequired) }
        guard let (id, current) = admission.beginRetarget(previous, scope: scope, owner: owner) else { return .blocked(.stale) }
        isWorking = true; permit = nil; defer { isWorking = false }
        let effect: PlaybackOutputRetargetEffect = previous.scope.itemID == scope.itemID && previous.scope.occurrence == scope.occurrence ? .command : .nextItemPreparation
        current.engine.invalidateOutputScopes(effect)
        guard !Task.isCancelled, allows(scope), let bound = admission.finishRetarget(id, scope: scope, owner: owner) else {
            _ = startRetirement(release: true); return .blocked(.stale)
        }
        permit = bound; return .permitted(bound)
    }
    /// Call only for the adapter's actual new native media/load/command binding.
    func bindMediaEvents(_ permit: PlaybackOutputPermit, engine: any PlaybackOutputEngine, nativeMediaID: UUID) -> PlaybackOutputEventBinding? {
        guard !revoked, self.permit?.id == permit.id else { return nil }
        return admission.bindEvents(permit, engine: engine, nativeMediaID: nativeMediaID)
    }
    func acceptsEvent(_ binding: PlaybackOutputEventBinding) -> Bool {
        !revoked && permit?.id == binding.permit.id && binding.isCurrent
    }
    @discardableResult func retireOutput(_ bound: PlaybackOutputPermit) -> PlaybackOutputRetirement? {
        guard admission.registration(owner: owner)?.permitID == bound.id else { return nil }
        let operation = startRetirement(expectedPermit: bound.id, release: true)
        if operation != nil { permit = nil }
        return operation
    }
    private func startRetirement(expectedPermit: UUID? = nil, release: Bool = false) -> PlaybackOutputRetirement? {
        if isRevoking { if release { admission.release(owner: owner) }; return retirement?.operation }
        guard let current = admission.beginRetirement(owner: owner, expectedPermit: expectedPermit) else { return retirement?.operation }
        isRevoking = true; defer { isRevoking = false }
        let operation = current.engine.revokeOutput()
        let valid = admission.attach(operation, owner: owner, registration: current)
        retirement = (operation, valid)
        if release { admission.release(owner: owner) }
        return operation
    }
    func quiesce() {
        revoked = true; request = UUID(); permit = nil
        _ = startRetirement(release: true)
        admission.release(owner: owner)
    }
    /// A blocked receipt lets Quit finish; it never authorizes a source/profile activation.
    func settle() async -> PlaybackOutputSettlement {
        if admission.registration(owner: owner) != nil && !admission.isRetiring(owner: owner) { return .blocked(.outputActive) }
        if admission.hasReservation(owner: owner) { return .blocked(.outputActive) }
        guard let retirement else { return .quiet }
        _ = await retirement.operation.settle()
        return retirement.valid && retirement.operation.isConfirmedQuiet ? .quiet : .blocked(.unconfirmed)
    }
}
