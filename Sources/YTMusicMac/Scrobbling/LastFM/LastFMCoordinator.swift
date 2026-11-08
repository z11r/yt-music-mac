import Foundation
import MusicCore

struct LastFMViewState: Equatable, Sendable {
    var available = false
    var enabled = false
    var connected = false
    var configured = false
    var authorizationID: UUID?
    var authorizing = false
    var username: String?
    var ready = 0
    var uncertain = 0
    var rejected = 0
    var ignored = 0
    var retryable = 0
    var working = false
    var paused = false
    var message: String?
}

/// Owns all provider state and file writes. The YouTube session supplies only
/// its opaque confirmed profile scope, never cookies or service credentials.
actor LastFMCoordinator {
    nonisolated let gate = ScrobbleAuthorizationGate()
    private let store: LastFMStore
    private let secrets: any LastFMCredentialsStoring
    private let api: LastFMAPI
    private let wallTime: @Sendable () -> Date
    private let monotonicTime: @Sendable () -> Double
    private var profile: String?
    private var scope = UUID()
    private var document: LastFMDocument?
    private var ledger = ListeningLedger()
    private var credentials: LastFMSavedCredentials?
    private var pendingAuthorization: PendingAuthorization?
    private var authTask: Task<AuthResult, Error>?
    private var message: String?
    private var working = false
    private var workingRevision: UUID?
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var deliveries: [UUID: Task<Void, Never>] = [:]
    private var lastSavedTime = 0.0
    private var continuity: UInt64 = 0
    private var playGeneration: UInt64 = 0
    private var observer: (@Sendable (UUID, LastFMViewState) -> Void)?

    init(store: LastFMStore, secrets: any LastFMCredentialsStoring, api: LastFMAPI,
         wallTime: @escaping @Sendable () -> Date = { Date() },
         monotonicTime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store; self.secrets = secrets; self.api = api; self.wallTime = wallTime; self.monotonicTime = monotonicTime
    }

    func observe(_ observer: @escaping @Sendable (UUID, LastFMViewState) -> Void) { self.observer = observer; notify() }

    func bind(profile: String?, scope: UUID) async -> LastFMViewState {
        guard let revision = gate.currentRevision(scope: scope) else { return viewState() }
        persistIfNeeded()
        worker?.cancel(); worker = nil; workerID = nil
        self.profile = profile.flatMap { EpisodeProgressSnapshot.validAccountHash($0) ? $0 : nil }
        self.scope = scope; document = nil; credentials = nil; pendingAuthorization = nil; authTask?.cancel(); authTask = nil; ledger = .init(); message = nil; working = false; workingRevision = nil
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
            if value.configured {
                await restoreCredentials(expectedScope: scope, revision: revision)
                if gate.matches(scope: scope, revision: revision), document?.enabled == true, connected {
                    gate.activate(scope: scope, revision: revision)
                    if !value.paused { startWorker() }
                }
            }
        } catch { message = LastFMText.text("Last.fm data could not be loaded. Existing files were retained; no listens will be sent.") }
        notify(); return viewState()
    }

    private struct PendingAuthorization {
        let id: UUID
        let token: String
        let created: Date
        let appFingerprint: String
    }
    private enum AuthResult: Sendable { case token(String), session(LastFMSavedCredentials) }
    private var connected: Bool { credentials?.sessionKey != nil && credentials?.username == document?.username && document?.sessionRejected == false }

    func configure(application: LastFMAppCredentials, expectedScope: UUID, revision: UUID) async -> LastFMViewState {
        guard authorized(expectedScope, revision), let profile, document != nil, !working else { return viewState() }
        disableWork(); document!.enabled = false; document!.sessionRejected = true; ledger.suspendCurrent()
        do { try persist() } catch { message = LastFMText.text("Last.fm configuration could not be saved."); notify(); return viewState() }
        guard application.isValid else { message = LastFMText.text("Enter a 32-character app key and the registered shared secret."); notify(); return viewState() }
        working = true; workingRevision = revision; notify()
        defer { finishConfiguration(revision: revision) }
        do {
            let value = LastFMSavedCredentials(application: application)
            try await secrets.store(value, profile: profile)
            guard authorized(expectedScope, revision) else { return configurationView(revision: revision) }
            credentials = value
            document!.configured = true; document!.appFingerprint = application.fingerprint; document!.credentialRevision = value.revision; document!.sessionRejected = false
            try persist()
            message = LastFMText.text("App credentials saved in Keychain. Authorize Last.fm, then enable scrobbling separately.")
        } catch {
            guard authorized(expectedScope, revision) else { return configurationView(revision: revision) }
            credentials = nil; message = LastFMText.text("Last.fm configuration could not be saved.")
        }
        return configurationView(revision: revision)
    }

    func beginAuthorization(expectedScope: UUID, revision: UUID) async -> LastFMViewState {
        guard authorized(expectedScope, revision), document != nil, !working else { return viewState() }
        disableWork(); document!.enabled = false; document!.sessionRejected = true; ledger.suspendCurrent()
        do { try persist() } catch { message = LastFMText.text("Last.fm configuration could not be saved."); notify(); return viewState() }
        if credentials == nil { await restoreCredentials(expectedScope: expectedScope, revision: revision) }
        guard authorized(expectedScope, revision), let application = credentials?.application else { return viewState() }
        working = true; workingRevision = revision; notify()
        defer { finishConfiguration(revision: revision) }
        let api = self.api
        let job = Task<AuthResult, Error> { .token(try await api.requestToken(application: application)) }
        authTask = job; notify()
        do {
            guard case let .token(token) = try await job.value else { throw LastFMAPIError.uncertain }
            guard authorized(expectedScope, revision) else { return configurationView(revision: revision) }
            pendingAuthorization = .init(id: UUID(), token: token, created: wallTime(), appFingerprint: application.fingerprint)
            message = LastFMText.text("Open Last.fm to approve this app, then return and complete authorization.")
        } catch {
            guard authorized(expectedScope, revision) else { return configurationView(revision: revision) }
            message = LastFMText.text("Authorization could not be started. Check the registered app credentials.")
        }
        if authorized(expectedScope, revision) { authTask = nil }
        return configurationView(revision: revision)
    }

    func approvalURL(expectedScope: UUID, authorizationID: UUID) -> URL? {
        guard scope == expectedScope, gate.matches(scope: expectedScope), let pending = validAuthorization(authorizationID),
              let application = credentials?.application else { return nil }
        return LastFMAPI.approvalURL(application: application, token: pending.token)
    }

    func completeAuthorization(expectedScope: UUID, authorizationID: UUID, revision: UUID) async -> LastFMViewState {
        guard authorized(expectedScope, revision), let profile, !working,
              let pending = validAuthorization(authorizationID), let application = credentials?.application else {
            if authorized(expectedScope, revision), pendingAuthorization?.id == authorizationID { pendingAuthorization = nil; message = LastFMText.text("Authorization expired or changed. Start again."); notify() }
            return viewState()
        }
        // The token is consumed before the one explicit exchange. Unknown
        // delivery never polls or blindly replays the exchange.
        pendingAuthorization = nil
        working = true; workingRevision = revision; notify()
        defer { finishConfiguration(revision: revision) }
        let api = self.api
        let job = Task<AuthResult, Error> { .session(try await api.getSession(application: application, token: pending.token)) }
        authTask = job; notify()
        do {
            guard case let .session(value) = try await job.value else { throw LastFMAPIError.uncertain }
            guard authorized(expectedScope, revision) else { return configurationView(revision: revision) }
            guard document!.outbox.filter({ !$0.state.isFinal }).allSatisfy({ $0.username == value.username }) else {
                message = LastFMText.text("Discard pending listens before authorizing another Last.fm account."); notify(); return configurationView(revision: revision)
            }
            try await secrets.store(value, profile: profile)
            guard authorized(expectedScope, revision) else { return configurationView(revision: revision) }
            if document!.username != value.username { document!.outbox = []; ledger = .init(); document!.currentProvenance = nil }
            credentials = value; document!.credentialRevision = value.revision; document!.username = value.username; document!.enabled = false
            document!.sessionRejected = false; document!.paused = false
            try persist()
            message = LastFMText.text("Last.fm authorized. Scrobbling remains off until you enable it.")
        } catch {
            guard authorized(expectedScope, revision) else { return configurationView(revision: revision) }
            if error as? LastFMAPIError == .notAuthorized {
                pendingAuthorization = pending
                message = LastFMText.text("Last.fm approval is still required. Approve in the browser, then complete again.")
            } else { message = LastFMText.text("Authorization was not confirmed. Start again; no session exchange will be repeated automatically.") }
        }
        if authorized(expectedScope, revision) { authTask = nil }
        return configurationView(revision: revision)
    }

    func cancelAuthorization(expectedScope: UUID, revision: UUID) -> LastFMViewState {
        guard authorized(expectedScope, revision) else { return viewState() }
        disableWork(); pendingAuthorization = nil; message = LastFMText.text("Authorization cancelled locally. Scrobbling is off.")
        document?.enabled = false; persistIfNeeded(force: true); notify(); return viewState()
    }

    func setEnabled(_ enabled: Bool, expectedScope: UUID, revision: UUID) async -> LastFMViewState {
        guard authorized(expectedScope, revision), document != nil else { return viewState() }
        if enabled, credentials == nil { await restoreCredentials(expectedScope: expectedScope, revision: revision) }
        guard authorized(expectedScope, revision) else { return viewState() }
        if enabled, !connected { message = LastFMText.text("Authorize a registered Last.fm app before enabling scrobbling."); notify(); return viewState() }
        document!.enabled = enabled; ledger.suspendCurrent()
        if !enabled { disableWork() }
        do { try persist(); message = LastFMText.text(enabled ? "Last.fm applies to new song plays. Uploads and podcasts are excluded." : "Last.fm is off. Pending and uncertain listens stay local.") }
        catch { document!.enabled = false; message = LastFMText.text("The setting could not be saved. Last.fm remains off.") }
        if document!.enabled { gate.activate(scope: expectedScope, revision: revision) }
        notify(); return viewState()
    }

    func disconnect(expectedScope: UUID, revision: UUID) async -> LastFMViewState {
        guard authorized(expectedScope, revision), let profile else { return viewState() }
        disableWork(); credentials = nil
        if document != nil { document!.enabled = false; try? persist() }
        do {
            try await secrets.remove(profile: profile)
            guard authorized(expectedScope, revision) else { return viewState() }
            try store.clear(profile: profile); document = .init(profile: profile); ledger = .init()
            message = LastFMText.text("Disconnected. Local Last.fm credentials, pending listens, and receipts were removed.")
        } catch {
            guard authorized(expectedScope, revision) else { return viewState() }
            message = LastFMText.text("Last.fm is off. Credential or local-data removal was not confirmed; disconnect again.")
        }
        notify(); return viewState()
    }

    private func restoreCredentials(expectedScope: UUID, revision: UUID) async {
        guard authorized(expectedScope, revision), let profile, document?.configured == true else { return }
        do {
            let value = try await secrets.read(profile: profile)
            guard authorized(expectedScope, revision) else { return }
            guard let value, value.isValid, value.application.fingerprint == document?.appFingerprint, value.revision == document?.credentialRevision,
                  value.sessionKey == nil || value.username == document?.username else { throw LastFMAPIError.invalidCredentials }
            credentials = value
        } catch {
            if authorized(expectedScope, revision) { credentials = nil; message = LastFMText.text("Reconnect the Last.fm app credentials and session.") }
        }
    }
    private func validAuthorization(_ id: UUID) -> PendingAuthorization? {
        guard let pendingAuthorization, pendingAuthorization.id == id,
              pendingAuthorization.appFingerprint == credentials?.application.fingerprint,
              (0..<3_600).contains(wallTime().timeIntervalSince(pendingAuthorization.created)) else { return nil }
        return pendingAuthorization
    }
    private func authorized(_ scope: UUID, _ revision: UUID) -> Bool {
        self.scope == scope && gate.matches(scope: scope, revision: revision)
    }
    private func disableWork() {
        gate.disable(scope: scope); worker?.cancel(); worker = nil; workerID = nil
        authTask?.cancel(); authTask = nil; pendingAuthorization = nil; working = false; workingRevision = nil
    }

    func discardPending(expectedScope: UUID) -> LastFMViewState {
        guard scope == expectedScope, gate.matches(scope: expectedScope), document != nil, worker == nil else { return viewState() }
        document!.outbox.removeAll { !$0.state.isFinal }
        do { try persist(); message = LastFMText.text("Pending listens were discarded locally. No provider history was changed.") }
        catch { message = LastFMText.text("Local Last.fm data could not be saved.") }
        notify(); return viewState()
    }

    func begin(track: Track, occurrence: PlaybackOccurrence, intent: ListeningStartIntent, expectedScope: UUID, chosenByUser: Bool? = nil,
               continuity: UInt64 = 0, playGeneration: UInt64 = 0) {
        guard scope == expectedScope, gate.allows(scope: expectedScope), document?.enabled == true, connected else { return }
        guard playGeneration >= self.playGeneration else { return }
        self.playGeneration = playGeneration
        self.continuity = max(self.continuity, continuity)
        ledger.begin(track: track, occurrence: occurrence, intent: intent)
        if let play = ledger.state.current {
            if document!.currentProvenance?.listenID != play.id {
                document!.currentProvenance = .init(listenID: play.id, chosenByUser: chosenByUser)
            }
        } else { document!.currentProvenance = nil }
        persistIfNeeded(force: true)
    }

    func interrupt(expectedScope: UUID, continuity: UInt64 = 0, playGeneration: UInt64 = 0) {
        if scope == expectedScope, playGeneration >= self.playGeneration, continuity >= self.continuity {
            self.playGeneration = playGeneration; self.continuity = continuity; ledger.interrupt()
        }
    }

    func sample(occurrence: PlaybackOccurrence, position: Double, duration: Double, ended: Bool, expectedScope: UUID,
                continuity: UInt64 = 0, playGeneration: UInt64 = 0, observedTime: Double? = nil, observedWallTime: Date? = nil) {
        guard scope == expectedScope, gate.allows(scope: expectedScope), document?.enabled == true, connected else { return }
        guard playGeneration == self.playGeneration, continuity >= self.continuity else { return }
        if continuity > self.continuity { self.continuity = continuity; ledger.interrupt() }
        if let listen = ledger.sample(occurrence: occurrence, position: position, duration: duration,
                                      monotonicTime: observedTime ?? monotonicTime(), wallTime: observedWallTime ?? wallTime(), ended: ended) {
            guard document!.outbox.filter({ !$0.state.isFinal }).count < 100, let username = document!.username else {
                document!.paused = true; message = LastFMText.text("The local outbox is full. Resolve pending listens before collecting more."); persistIfNeeded(force: true); notify(); return
            }
            ledger.markQueued(listen)
            document!.outbox.append(.init(listen: listen, username: username, state: .ready, chosenByUser: document!.currentProvenance?.chosenByUser))
            do { try persist(); startWorker() }
            catch { document!.paused = true; message = LastFMText.text("The listen could not be saved locally; it was not submitted.") }
            notify()
        } else { persistIfNeeded(force: ended) }
    }

    func sendUnsent(expectedScope: UUID) -> LastFMViewState {
        guard scope == expectedScope, gate.allows(scope: expectedScope), document?.enabled == true, connected, !working else { return viewState() }
        document!.paused = false
        do { try persist(); startWorker() } catch { document!.paused = true; message = LastFMText.text("Local Last.fm data could not be saved.") }
        notify(); return viewState()
    }
    func retryRefused(expectedScope: UUID) -> LastFMViewState {
        guard scope == expectedScope, gate.allows(scope: expectedScope), document?.enabled == true, connected, worker == nil, !working else { return viewState() }
        for index in document!.outbox.indices where document!.outbox[index].state == .retryable || document!.outbox[index].state == .needsAuthorization {
            document!.outbox[index].state = .ready
        }
        return sendUnsent(expectedScope: expectedScope)
    }

    func stop(expectedScope: UUID) {
        guard scope == expectedScope, gate.matches(scope: expectedScope) else { return }
        gate.disable(scope: expectedScope)
        disableWork(); ledger.interrupt(); persistIfNeeded(force: true)
    }

    func viewState() -> LastFMViewState {
        LastFMViewState(available: document != nil, enabled: document?.enabled ?? false, connected: connected, configured: credentials != nil, authorizationID: pendingAuthorization?.id, authorizing: authTask != nil,
            username: document?.username, ready: document?.outbox.filter { $0.state == .ready }.count ?? 0,
            uncertain: document?.outbox.filter { $0.state == .uncertain || $0.state == .sending }.count ?? 0,
            rejected: document?.outbox.filter { $0.state == .rejected || $0.state == .needsAuthorization || $0.state == .retryable }.count ?? 0,
            ignored: document?.outbox.filter { $0.state == .ignored }.count ?? 0,
            retryable: document?.outbox.filter { $0.state == .retryable || ($0.state == .needsAuthorization && connected) }.count ?? 0, working: working || worker != nil,
            paused: document?.paused ?? false, message: message)
    }
    func waitForDeliveries() async {
        let current = Array(deliveries.values)
        for task in current { await task.value }
    }

    private func persist() throws {
        guard var document else { throw LastFMStoreError.invalidData }
        document.ledger = ledger.state
        try store.save(document)
        self.document = document; lastSavedTime = monotonicTime()
    }
    private func persistIfNeeded(force: Bool = false) {
        guard let document, document.enabled || document.username != nil || !document.outbox.isEmpty else { return }
        guard force || monotonicTime() - lastSavedTime >= 5 else { return }
        do { try persist() } catch { message = LastFMText.text("Local Last.fm data could not be saved."); notify() }
    }

    private func startWorker() {
        guard worker == nil, deliveries.count < 4, gate.allows(scope: scope), document?.enabled == true, document?.paused == false, connected, let profile else { return }
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
                  document?.enabled == true, document?.paused == false, let credentials, connected,
                  let index = document!.outbox.firstIndex(where: { $0.state == .ready && $0.username == document!.username }) else { break }
            let pending = document!.outbox[index]
            document!.outbox[index].state = .sending
            do { try persist() }
            catch { document!.outbox[index].state = .ready; document!.paused = true; message = LastFMText.text("The attempt marker could not be saved; no listen was sent."); break }
            notify()
            let gate = self.gate
            let outcome = await api.submit(pending.listen, credentials: credentials, chosenByUser: pending.chosenByUser, authorized: { gate.allows(scope: expectedScope) })
            finishDelivery(pending, outcome: outcome, profile: profile, credentialRevision: credentials.revision)
            if outcome != .confirmed && outcome != .ignored { break }
        }
        gate.remove(id: workerID)
        deliveries[workerID] = nil
        if self.workerID == workerID { worker = nil; self.workerID = nil; notify() }
    }

    private func finishDelivery(_ pending: LastFMPending, outcome: LastFMSubmissionOutcome, profile: String, credentialRevision: UUID) {
        do {
            var value: LastFMDocument
            if self.profile == profile, let current = document { value = current; value.ledger = ledger.state }
            else { value = try store.load(profile: profile) }
            guard let index = value.outbox.firstIndex(where: { $0.id == pending.id && $0.username == pending.username }) else { return }
            switch outcome {
            case .confirmed: value.outbox[index].state = .confirmed
            case .ignored: value.outbox[index].state = .ignored
            case .authenticationRejected:
                value.outbox[index].state = .needsAuthorization; value.paused = true
                if value.credentialRevision == credentialRevision { value.sessionRejected = true; value.enabled = false }
            case .rejected: value.outbox[index].state = .rejected; value.paused = true
            case .retryable: value.outbox[index].state = .retryable; value.paused = true
            case .uncertain: value.outbox[index].state = .uncertain; value.paused = true
            }
            let completed = value.outbox.filter { $0.state.isFinal }.suffix(50)
            value.outbox = value.outbox.filter { !$0.state.isFinal } + completed
            try store.save(value)
            if self.profile == profile {
                document = value
                if outcome == .authenticationRejected && value.credentialRevision == credentialRevision { gate.disable(scope: scope) }
                message = LastFMText.text(outcome == .confirmed ? "Last.fm confirmed the listen." : outcome == .ignored ? "Last.fm ignored the listen. It was not added to your history." :
                    "Submission stopped. Review refused or uncertain listens; no automatic retry was made.")
                notify()
            }
        } catch {
            if self.profile == profile { message = LastFMText.text("Delivery state could not be saved. The attempt will not be automatically repeated."); notify() }
        }
    }
    private func configurationView(revision: UUID) -> LastFMViewState {
        finishConfiguration(revision: revision); return viewState()
    }
    private func finishConfiguration(revision: UUID) {
        if workingRevision == revision { working = false; workingRevision = nil; notify() }
    }
    private func notify() { observer?(scope, viewState()) }
}
