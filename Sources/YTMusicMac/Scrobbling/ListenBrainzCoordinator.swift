import Foundation
import MusicCore

struct ListenBrainzViewState: Equatable, Sendable {
    var available = false
    var enabled = false
    var connected = false
    var username: String?
    var ready = 0
    var uncertain = 0
    var rejected = 0
    var working = false
    var paused = false
    var message: String?
}

/// Owns all provider state and file writes. The YouTube session supplies only
/// its opaque confirmed profile scope, never cookies or service credentials.
actor ListenBrainzCoordinator {
    nonisolated let gate = ScrobbleAuthorizationGate()
    private let store: ListenBrainzStore
    private let tokens: any ScrobbleTokenStoring
    private let api: ListenBrainzAPI
    private let wallTime: @Sendable () -> Date
    private let monotonicTime: @Sendable () -> Double
    private var profile: String?
    private var scope = UUID()
    private var document: ListenBrainzDocument?
    private var ledger = ListeningLedger()
    private var token: String?
    private var message: String?
    private var working = false
    private var workingRevision: UUID?
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var deliveries: [UUID: Task<Void, Never>] = [:]
    private var lastSavedTime = 0.0
    private var continuity: UInt64 = 0
    private var playGeneration: UInt64 = 0
    private var observer: (@Sendable (UUID, ListenBrainzViewState) -> Void)?

    init(store: ListenBrainzStore, tokens: any ScrobbleTokenStoring, api: ListenBrainzAPI,
         wallTime: @escaping @Sendable () -> Date = { Date() },
         monotonicTime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store; self.tokens = tokens; self.api = api; self.wallTime = wallTime; self.monotonicTime = monotonicTime
    }

    func observe(_ observer: @escaping @Sendable (UUID, ListenBrainzViewState) -> Void) { self.observer = observer; notify() }

    func bind(profile: String?, scope: UUID) async -> ListenBrainzViewState {
        guard let revision = gate.currentRevision(scope: scope) else { return viewState() }
        persistIfNeeded()
        worker?.cancel(); worker = nil; workerID = nil
        self.profile = profile.flatMap { EpisodeProgressSnapshot.validAccountHash($0) ? $0 : nil }
        self.scope = scope; document = nil; token = nil; ledger = .init(); message = nil; working = false; workingRevision = nil
        continuity = 0
        playGeneration = 0
        guard let profile = self.profile else { notify(); return viewState() }
        do {
            var value = try store.load(profile: profile)
            let interrupted = value.outbox.contains { $0.state == .sending }
            if interrupted {
                for index in value.outbox.indices where value.outbox[index].state == .sending { value.outbox[index].state = .uncertain }
                value.paused = true
                try store.save(value)
            }
            document = value; ledger = ListeningLedger(state: value.ledger)
            if value.enabled { await checkConnection(expectedScope: scope, resumeSending: !value.paused, revision: revision) }
        } catch { message = "ListenBrainz data could not be loaded. Existing files were retained; no listens will be sent." }
        notify(); return viewState()
    }

    func connect(token supplied: String, expectedScope: UUID, revision requestedRevision: UUID? = nil) async -> ListenBrainzViewState {
        guard let revision = requestedRevision ?? gate.currentRevision(scope: expectedScope),
              scope == expectedScope, gate.matches(scope: expectedScope, revision: revision), let profile, document != nil, !working else { return viewState() }
        gate.disable(scope: expectedScope); worker?.cancel(); worker = nil; workerID = nil
        document!.enabled = false
        do { try persist() } catch { message = "Scrobbling could not be safely configured."; notify(); return viewState() }
        working = true; workingRevision = revision; message = nil; notify()
        defer { finishConfiguration(revision: revision) }
        do {
            let username = try await api.validateToken(supplied)
            guard scope == expectedScope, gate.matches(scope: expectedScope, revision: revision) else { return viewState() }
            guard document!.outbox.filter({ $0.state != .confirmed }).allSatisfy({ $0.username == username }) else {
                working = false; message = "Discard pending listens and disconnect before choosing another ListenBrainz account."; notify(); return viewState()
            }
            try await tokens.store(supplied, profile: profile)
            guard scope == expectedScope, gate.matches(scope: expectedScope, revision: revision) else { return viewState() }
            if document!.username != username {
                document!.outbox = []; ledger = .init()
            }
            document!.username = username; document!.enabled = false; document!.paused = false
            token = supplied
            try persist()
            message = "Token verified and stored. Enable scrobbling to send songs started after opting in."
        } catch {
            guard scope == expectedScope, gate.matches(scope: expectedScope, revision: revision) else { return viewState() }
            token = nil; message = "The ListenBrainz connection was not established. Check the token and local credential storage."
        }
        working = false; notify(); return viewState()
    }

    func setEnabled(_ enabled: Bool, expectedScope: UUID, revision requestedRevision: UUID? = nil) async -> ListenBrainzViewState {
        guard let revision = requestedRevision ?? gate.currentRevision(scope: expectedScope),
              scope == expectedScope, gate.matches(scope: expectedScope, revision: revision), document != nil else { return viewState() }
        if enabled, token == nil { await checkConnection(expectedScope: expectedScope, resumeSending: false, revision: revision) }
        guard scope == expectedScope, gate.matches(scope: expectedScope, revision: revision) else { return viewState() }
        if enabled, token == nil { return viewState() }
        document!.enabled = enabled
        ledger.suspendCurrent()
        if !enabled { gate.disable(scope: expectedScope); worker?.cancel(); worker = nil; workerID = nil; working = false; workingRevision = nil }
        do { try persist(); message = enabled ? "Scrobbling applies to new song plays. Uploads and podcasts are excluded." : "Scrobbling is off. Pending and uncertain listens stay local." }
        catch { document!.enabled = false; message = "The setting could not be saved. Scrobbling remains off." }
        if document!.enabled { gate.activate(scope: expectedScope, revision: revision) }
        notify(); return viewState()
    }

    func checkConnection(expectedScope: UUID, resumeSending: Bool = false, revision requestedRevision: UUID? = nil) async {
        guard let revision = requestedRevision ?? gate.currentRevision(scope: expectedScope),
              scope == expectedScope, gate.matches(scope: expectedScope, revision: revision), let profile, document != nil, !working else { return }
        working = true; workingRevision = revision; notify()
        defer { finishConfiguration(revision: revision) }
        do {
            guard let saved = try await tokens.read(profile: profile) else { throw ListenBrainzAPIError.invalidToken }
            guard scope == expectedScope, gate.matches(scope: expectedScope, revision: revision) else { return }
            let username = try await api.validateToken(saved)
            guard scope == expectedScope, gate.matches(scope: expectedScope, revision: revision) else { return }
            guard username == document!.username else { throw ListenBrainzAPIError.invalidToken }
            token = saved
            if document!.enabled { gate.activate(scope: expectedScope, revision: revision) }
            if resumeSending { document!.paused = false; try persist() }
            message = "ListenBrainz connection verified."
        } catch {
            guard scope == expectedScope, gate.matches(scope: expectedScope, revision: revision) else { return }
            token = nil; message = "Reconnect ListenBrainz before sending listens."
        }
        working = false; notify()
        if resumeSending { startWorker() }
    }

    func disconnect(expectedScope: UUID, revision requestedRevision: UUID? = nil) async -> ListenBrainzViewState {
        guard let revision = requestedRevision ?? gate.currentRevision(scope: expectedScope),
              scope == expectedScope, gate.matches(scope: expectedScope, revision: revision), let profile else { return viewState() }
        gate.disable(scope: expectedScope)
        worker?.cancel(); worker = nil; workerID = nil; token = nil; working = false; workingRevision = nil
        if document != nil { document!.enabled = false; try? persist() }
        do {
            try await tokens.remove(profile: profile)
            guard scope == expectedScope, gate.matches(scope: expectedScope, revision: revision) else { return viewState() }
            try store.clear(profile: profile)
            document = .init(profile: profile); ledger = .init()
            message = "Disconnected. Local ListenBrainz settings, pending listens, and receipts were removed."
        } catch {
            guard scope == expectedScope, gate.matches(scope: expectedScope, revision: revision) else { return viewState() }
            message = "Reporting is off. Credential or local-data removal was not confirmed; try disconnecting again."
        }
        notify(); return viewState()
    }

    func discardPending(expectedScope: UUID) -> ListenBrainzViewState {
        guard scope == expectedScope, gate.matches(scope: expectedScope), document != nil, worker == nil else { return viewState() }
        document!.outbox.removeAll { $0.state != .confirmed }
        do { try persist(); message = "Pending listens were discarded locally. No provider history was changed." }
        catch { message = "Local ListenBrainz data could not be saved." }
        notify(); return viewState()
    }

    func begin(track: Track, occurrence: PlaybackOccurrence, intent: ListeningStartIntent, expectedScope: UUID,
               continuity: UInt64 = 0, playGeneration: UInt64 = 0) {
        guard scope == expectedScope, gate.allows(scope: expectedScope), document?.enabled == true, token != nil else { return }
        guard playGeneration >= self.playGeneration else { return }
        self.playGeneration = playGeneration
        self.continuity = max(self.continuity, continuity)
        ledger.begin(track: track, occurrence: occurrence, intent: intent)
        persistIfNeeded(force: true)
    }

    func interrupt(expectedScope: UUID, continuity: UInt64 = 0, playGeneration: UInt64 = 0) {
        if scope == expectedScope, playGeneration >= self.playGeneration, continuity >= self.continuity {
            self.playGeneration = playGeneration; self.continuity = continuity; ledger.interrupt()
        }
    }

    func sample(occurrence: PlaybackOccurrence, position: Double, duration: Double, ended: Bool, expectedScope: UUID,
                continuity: UInt64 = 0, playGeneration: UInt64 = 0, observedTime: Double? = nil, observedWallTime: Date? = nil) {
        guard scope == expectedScope, gate.allows(scope: expectedScope), document?.enabled == true, token != nil else { return }
        guard playGeneration == self.playGeneration, continuity >= self.continuity else { return }
        if continuity > self.continuity { self.continuity = continuity; ledger.interrupt() }
        if let listen = ledger.sample(occurrence: occurrence, position: position, duration: duration,
                                      monotonicTime: observedTime ?? monotonicTime(), wallTime: observedWallTime ?? wallTime(), ended: ended) {
            guard document!.outbox.filter({ $0.state != .confirmed }).count < 100, let username = document!.username else {
                document!.paused = true; message = "The local outbox is full. Resolve pending listens before collecting more."; persistIfNeeded(force: true); notify(); return
            }
            ledger.markQueued(listen)
            document!.outbox.append(.init(listen: listen, username: username, state: .ready))
            do { try persist(); startWorker() }
            catch { document!.paused = true; message = "The listen could not be saved locally; it was not submitted." }
            notify()
        } else { persistIfNeeded(force: ended) }
    }

    func sendUnsent(expectedScope: UUID) async -> ListenBrainzViewState {
        guard scope == expectedScope, document?.enabled == true else { return viewState() }
        await checkConnection(expectedScope: expectedScope, resumeSending: true)
        return viewState()
    }

    func stop(expectedScope: UUID) {
        guard scope == expectedScope, gate.matches(scope: expectedScope) else { return }
        gate.disable(scope: expectedScope)
        worker?.cancel(); worker = nil; workerID = nil; ledger.interrupt(); persistIfNeeded(force: true)
    }

    func viewState() -> ListenBrainzViewState {
        ListenBrainzViewState(available: document != nil, enabled: document?.enabled ?? false, connected: token != nil,
            username: document?.username, ready: document?.outbox.filter { $0.state == .ready }.count ?? 0,
            uncertain: document?.outbox.filter { $0.state == .uncertain || $0.state == .sending }.count ?? 0,
            rejected: document?.outbox.filter { $0.state == .rejected }.count ?? 0, working: working || worker != nil,
            paused: document?.paused ?? false, message: message)
    }
    func waitForDeliveries() async {
        let current = Array(deliveries.values)
        for task in current { await task.value }
    }

    private func persist() throws {
        guard var document else { throw ListenBrainzStoreError.invalidData }
        document.ledger = ledger.state
        try store.save(document)
        self.document = document; lastSavedTime = monotonicTime()
    }
    private func persistIfNeeded(force: Bool = false) {
        guard let document, document.enabled || document.username != nil || !document.outbox.isEmpty else { return }
        guard force || monotonicTime() - lastSavedTime >= 5 else { return }
        do { try persist() } catch { message = "Local ListenBrainz data could not be saved."; notify() }
    }

    private func startWorker() {
        guard worker == nil, deliveries.count < 4, gate.allows(scope: scope), document?.enabled == true, document?.paused == false, token != nil, let profile else { return }
        let id = UUID(); workerID = id
        let expected = scope
        worker = Task { await self.deliver(profile: profile, expectedScope: expected, workerID: id) }
        let worker = self.worker!
        deliveries[id] = worker
        gate.install(scope: expected, id: id) { worker.cancel() }
        notify()
    }

    private func deliver(profile: String, expectedScope: UUID, workerID: UUID) async {
        // At most five new attempts per run. Attempted listens never re-enter ready.
        for _ in 0..<5 {
            guard !Task.isCancelled, gate.allows(scope: expectedScope), scope == expectedScope, self.profile == profile,
                  document?.enabled == true, document?.paused == false, let token,
                  let index = document!.outbox.firstIndex(where: { $0.state == .ready && $0.username == document!.username }) else { break }
            let pending = document!.outbox[index]
            document!.outbox[index].state = .sending
            do { try persist() }
            catch { document!.outbox[index].state = .ready; document!.paused = true; message = "The attempt marker could not be saved; no listen was sent."; break }
            notify()
            let gate = self.gate
            let outcome = await api.submit(pending.listen, token: token, authorized: { gate.allows(scope: expectedScope) })
            finishDelivery(pending, outcome: outcome, profile: profile)
            if outcome != .confirmed { break }
        }
        gate.remove(id: workerID)
        deliveries[workerID] = nil
        if self.workerID == workerID { worker = nil; self.workerID = nil; notify() }
    }

    private func finishDelivery(_ pending: ListenBrainzPending, outcome: ListenBrainzSubmissionOutcome, profile: String) {
        do {
            var value: ListenBrainzDocument
            if self.profile == profile, let current = document { value = current; value.ledger = ledger.state }
            else { value = try store.load(profile: profile) }
            guard let index = value.outbox.firstIndex(where: { $0.id == pending.id && $0.username == pending.username }) else { return }
            switch outcome {
            case .confirmed: value.outbox[index].state = .confirmed
            case .rejected, .authenticationRejected: value.outbox[index].state = .rejected; value.paused = true
            case .uncertain: value.outbox[index].state = .uncertain; value.paused = true
            }
            let confirmed = value.outbox.filter { $0.state == .confirmed }.suffix(50)
            value.outbox = value.outbox.filter { $0.state != .confirmed } + confirmed
            try store.save(value)
            if self.profile == profile {
                document = value
                if outcome == .authenticationRejected { token = nil }
                message = outcome == .confirmed ? "ListenBrainz confirmed the listen." :
                    "Submission stopped. Uncertain or rejected listens are kept locally and are never retried automatically."
                notify()
            }
        } catch {
            if self.profile == profile { message = "Delivery state could not be saved. The attempt will not be automatically repeated."; notify() }
        }
    }
    private func finishConfiguration(revision: UUID) {
        if workingRevision == revision { working = false; workingRevision = nil; notify() }
    }
    private func notify() { observer?(scope, viewState()) }
}
