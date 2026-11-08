import Foundation

enum PlaybackOutputEngineKind: String, Hashable, Sendable { case web, local }
enum PlaybackOutputProblem: Equatable, Sendable {
    case busy, stale, cancelled, timedOut, unconfirmed, unknownTargets, capacity, outputActive, retargetRequired, retirementRequired
}
struct PlaybackRetirementTicket: Equatable, Sendable {
    let id: UUID
    let engine: PlaybackOutputEngineKind
    let instanceID: UUID
    init(engine: PlaybackOutputEngineKind, instanceID: UUID) { id = UUID(); self.engine = engine; self.instanceID = instanceID }
}
struct PlaybackRetirementReceipt: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case confirmed, blocked(PlaybackOutputProblem) }
    let ticket: PlaybackRetirementTicket
    let outcome: Outcome
}

/// A bounded answer is separate from actual native settlement. An uncertain
/// answer never discards the retained target or proves that its output stopped.
@MainActor final class PlaybackOutputRetirement {
    let ticket: PlaybackRetirementTicket
    private(set) var isConfirmedQuiet = false
    private(set) var receipt: PlaybackRetirementReceipt?
    private var quietObservers: [() -> Void] = []
    func onConfirmedQuiet(_ callback: @escaping () -> Void) {
        if isConfirmedQuiet { callback(); return }
        guard quietObservers.count < 4 else { return }
        quietObservers.append(callback)
    }
    private var retained: AnyObject?
    private var deadline: Task<Void, Never>?
    private var waiters: [CheckedContinuation<PlaybackRetirementReceipt, Never>] = []

    init(engine: PlaybackOutputEngineKind, instanceID: UUID, retaining target: AnyObject? = nil,
         sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }) {
        ticket = .init(engine: engine, instanceID: instanceID); retained = target
        deadline = Task { [weak self] in
            do { try Task.checkCancellation(); try await sleep() } catch { return }
            self?.block(.timedOut)
        }
    }
    func confirmQuiet(ticket: PlaybackRetirementTicket) {
        guard ticket == self.ticket, !isConfirmedQuiet else { return }
        isConfirmedQuiet = true; retained = nil
        publish(.confirmed)
        let callbacks = quietObservers; quietObservers = []; callbacks.forEach { $0() }
    }
    func block(_ problem: PlaybackOutputProblem) { publish(.blocked(problem)) }
    private func publish(_ outcome: PlaybackRetirementReceipt.Outcome) {
        guard receipt == nil else { return }
        let value = PlaybackRetirementReceipt(ticket: ticket, outcome: outcome)
        receipt = value; deadline?.cancel(); deadline = nil
        let waiting = waiters; waiters = []
        waiting.forEach { $0.resume(returning: value) }
    }
    func settle() async -> PlaybackRetirementReceipt {
        await withTaskCancellationHandler {
            if Task.isCancelled { block(.cancelled) }
            if let receipt { return receipt }
            guard waiters.count < 4 else { return .init(ticket: ticket, outcome: .blocked(.busy)) }
            return await withCheckedContinuation { waiters.append($0) }
        } onCancel: { Task { @MainActor in self.block(.cancelled) } }
    }
}

enum RetiredMediaState: Sendable { case none, suspended, paused, playing, unknown }
@MainActor protocol PlaybackViewRetirementTarget: AnyObject {
    var retirementID: UUID { get }
    func suspend(_ completion: @escaping @MainActor () -> Void)
    func closePresentations(_ completion: @escaping @MainActor () -> Void)
    func mediaState(_ completion: @escaping @MainActor (RetiredMediaState) -> Void)
}

/// One sealed set of exact views. Deadline/cancellation never admits more views.
@MainActor final class PlaybackViewRetirementLedger {
    private final class Entry {
        var target: (any PlaybackViewRetirementTarget)?
        var suspended = false, closed = false, requestedState = false, receivedState = false, quiet = false
        init(_ target: any PlaybackViewRetirementTarget) { self.target = target }
    }
    private let instanceID: UUID
    private let maximumTargets: Int
    private let sleep: @Sendable () async throws -> Void
    private var entries: [UUID: Entry] = [:]
    private var historyIsComplete = true
    private var hasBegun = false
    private(set) var operation: PlaybackOutputRetirement?
    var retainedTargetCount: Int { entries.values.filter { $0.target != nil }.count }

    init(instanceID: UUID = UUID(), maximumTargets: Int = 8,
         sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }) {
        self.instanceID = instanceID
        self.maximumTargets = min(8, max(1, maximumTargets)); self.sleep = sleep
    }
    func reserve() -> PlaybackOutputRetirement {
        if let operation { return operation }
        let value = PlaybackOutputRetirement(engine: .web, instanceID: instanceID, retaining: self, sleep: sleep)
        operation = value; return value
    }
    func begin(_ targets: [any PlaybackViewRetirementTarget], historyIsComplete: Bool = true) -> PlaybackOutputRetirement {
        let operation = reserve()
        guard !hasBegun else { return operation }
        hasBegun = true
        self.historyIsComplete = historyIsComplete
        if !historyIsComplete { operation.block(.unknownTargets) }
        guard targets.count <= maximumTargets, Set(targets.map(\.retirementID)).count == targets.count else {
            operation.block(.capacity); return operation
        }
        entries = Dictionary(uniqueKeysWithValues: targets.map { ($0.retirementID, Entry($0)) })
        if entries.isEmpty {
            if historyIsComplete { operation.confirmQuiet(ticket: operation.ticket) }
            return operation
        }
        // Register every exact resource before a synchronously completing native call.
        for (id, entry) in entries {
            guard let target = entry.target else { continue }
            target.suspend { self.suspended(id) }
            target.closePresentations { self.closed(id) }
        }
        return operation
    }
    private func suspended(_ id: UUID) {
        guard let entry = entries[id], !entry.suspended else { return }
        entry.suspended = true; inspect(id, entry)
    }
    private func closed(_ id: UUID) {
        guard let entry = entries[id], !entry.closed else { return }
        entry.closed = true; inspect(id, entry)
    }
    private func inspect(_ id: UUID, _ entry: Entry) {
        guard entry.suspended, entry.closed, !entry.requestedState, let target = entry.target else { return }
        entry.requestedState = true
        target.mediaState { state in
            guard let current = self.entries[id], current === entry, !entry.receivedState else { return }
            entry.receivedState = true
            switch state {
            case .none, .suspended: entry.quiet = true; entry.target = nil
            case .paused, .playing, .unknown: self.operation?.block(.unconfirmed); return
            }
            if self.historyIsComplete, self.entries.values.allSatisfy(\.quiet), let operation = self.operation {
                operation.confirmQuiet(ticket: operation.ticket)
            }
        }
    }
}
