import Foundation
import Observation

struct AppLaunchOwnership: Equatable, Sendable {
    let activation: UUID
    let accountEpoch: UUID?
    let ready: Bool
    init(activation: UUID, accountEpoch: UUID? = nil, ready: Bool) {
        self.activation = activation; self.accountEpoch = accountEpoch; self.ready = ready
    }
    var identity: AppLaunchIdentity { .init(activation: activation, accountEpoch: accountEpoch) }
}
struct AppLaunchIdentity: Equatable, Sendable { let activation: UUID; let accountEpoch: UUID? }

@MainActor protocol StartupRecoveryPresenting: AnyObject {
    func show(resetAndQuit: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void)
    func dismiss()
}

/// Owns bootstrap and explicit presentation independently of any window or popover.
@MainActor @Observable final class AppLaunchCoordinator {
    private enum Payload { case window(StartupWindowID), url(URL), spotlight(String) }
    private enum Binding { case launch(UUID), activation(AppLaunchIdentity) }
    private struct Request { let id: UUID; var binding: Binding; let payload: Payload; let automatic: Bool }
    private struct Presenter { let id: UUID; let statusLabel: Bool; let open: (StartupWindowID) -> Void }
    private(set) var readyActivation: UUID?
    private(set) var isStopping = false
    private(set) var hasStatusPresenter = false
    @ObservationIgnored private let launchID = UUID()
    @ObservationIgnored private let ownership: () -> AppLaunchOwnership
    @ObservationIgnored private let startOwner: () async -> Void
    @ObservationIgnored private let activate: (UUID) -> Void
    @ObservationIgnored private let receiveURL: (URL, UUID) -> Void
    @ObservationIgnored private let receiveSpotlight: (String, UUID) -> Bool
    @ObservationIgnored private let shutdownOwner: () async -> Void
    @ObservationIgnored private let resetAndQuit: () -> Void
    @ObservationIgnored private let validateURL: (URL) -> Bool
    @ObservationIgnored private let activateApplication: () -> Void
    @ObservationIgnored private let recovery: any StartupRecoveryPresenting
    @ObservationIgnored private let recoveryDelay: () async throws -> Void
    @ObservationIgnored private let initialPolicy: StartupWindowPolicy
    @ObservationIgnored private var bootstrap: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var presenters: [Presenter] = []
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var recoveredRequest: UUID?
    @ObservationIgnored private var recoveryPresentation: UUID?
    @ObservationIgnored private var activated: UUID?
    @ObservationIgnored private var receipts: [UUID] = []
    @ObservationIgnored private var began = false
    @ObservationIgnored private var observationID = UUID()
    @ObservationIgnored private var recoveryID: UUID?
    @ObservationIgnored private var finishedShutdown = false
    @ObservationIgnored private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    init(policy: StartupWindowPolicy, ownership: @escaping () -> AppLaunchOwnership,
         start: @escaping () async -> Void, activate: @escaping (UUID) -> Void,
         receiveURL: @escaping (URL, UUID) -> Void, receiveSpotlight: @escaping (String, UUID) -> Bool,
         shutdown: @escaping () async -> Void, recovery: any StartupRecoveryPresenting,
         resetAndQuit: @escaping () -> Void, validateURL: @escaping (URL) -> Bool,
         activateApplication: @escaping () -> Void = {},
         recoveryDelay: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(400)) }) {
        initialPolicy = policy; self.ownership = ownership; startOwner = start; self.activate = activate
        self.receiveURL = receiveURL; self.receiveSpotlight = receiveSpotlight; shutdownOwner = shutdown
        self.recovery = recovery; self.resetAndQuit = resetAndQuit; self.validateURL = validateURL
        self.recoveryDelay = recoveryDelay
        self.activateApplication = activateApplication
    }

    func start() {
        guard !began, !isStopping else { return }
        began = true
        if pending == nil, initialPolicy == .mini {
            pending = .init(id: UUID(), binding: .launch(launchID), payload: .window(.mini), automatic: true)
        }
        observe()
        bootstrap = Task { [weak self] in
            guard let self, !self.isStopping else { return }
            await self.startOwner()
            guard !Task.isCancelled, !self.isStopping else { return }
            self.observe()
        }
    }
    func waitForBootstrap() async { await bootstrap?.value }

    func ownershipChanged() { if began, !isStopping { observe() } }

    @discardableResult func requestWindow(_ window: StartupWindowID, expectedActivation: UUID? = nil, receipt: UUID = UUID()) -> Bool {
        enqueue(.window(window), expected: expectedActivation, receipt: receipt)
    }
    @discardableResult func openURL(_ url: URL, receipt: UUID = UUID()) -> Bool {
        guard url.absoluteString.utf8.count <= 8_192, validateURL(url) else { return false }
        return enqueue(.url(url), expected: nil, receipt: receipt)
    }
    @discardableResult func openSpotlight(_ identifier: String, receipt: UUID = UUID()) -> Bool {
        guard !identifier.isEmpty, identifier.utf8.count <= 1_024,
              !identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        return enqueue(.spotlight(identifier), expected: nil, receipt: receipt)
    }

    func registerPresenter(id: UUID, statusLabel: Bool = false, open: @escaping (StartupWindowID) -> Void) {
        guard !isStopping else { return }
        presenters.removeAll { $0.id == id }
        guard presenters.count < 16 else { return }
        presenters.append(.init(id: id, statusLabel: statusLabel, open: open))
        hasStatusPresenter = presenters.contains(where: \.statusLabel)
        refresh()
    }
    func unregisterPresenter(id: UUID) {
        presenters.removeAll { $0.id == id }; hasStatusPresenter = presenters.contains(where: \.statusLabel)
        refresh()
    }
    func cancelPresentation() { pending = nil; dismissRecovery() }

    func shutdown() async {
        if isStopping {
            if !finishedShutdown { await withCheckedContinuation { shutdownWaiters.append($0) } }
            return
        }
        isStopping = true; readyActivation = nil; pending = nil; receipts = []
        bootstrap?.cancel(); presenters = []; hasStatusPresenter = false; dismissRecovery()
        await shutdownOwner()
        await bootstrap?.value
        finishedShutdown = true
        let waiting = shutdownWaiters; shutdownWaiters = []; waiting.forEach { $0.resume() }
    }

    private func enqueue(_ payload: Payload, expected: UUID?, receipt: UUID) -> Bool {
        guard !isStopping, !receipts.contains(receipt) else { return false }
        let state = ownership()
        if let expected, expected != state.activation || !state.ready { return false }
        receipts.append(receipt); if receipts.count > 32 { receipts.removeFirst(receipts.count - 32) }
        let binding: Binding = activated == nil && expected == nil ? .launch(launchID) : .activation(state.identity)
        dismissRecovery()
        pending = .init(id: receipt, binding: binding, payload: payload, automatic: false)
        refresh(); return true
    }

    private func observe() {
        let token = UUID(); observationID = token
        _ = withObservationTracking { ownership() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationID == token else { return }
                self.ownershipChanged()
            }
        }
        refresh()
    }
    private func refresh() {
        guard began, !isStopping else { return }
        let state = ownership()
        if let pending, case let .activation(id) = pending.binding, id != state.identity { self.pending = nil; dismissRecovery() }
        guard state.ready else { readyActivation = nil; dismissRecovery(); return }
        readyActivation = state.activation
        if var request = pending, case let .launch(id) = request.binding {
            guard id == launchID else { pending = nil; dismissRecovery(); return }
            request.binding = .activation(state.identity); pending = request
        }
        if activated != state.activation {
            activated = state.activation; activate(state.activation)
        }
        guard ownership() == state, let request = pending else { return }
        guard case let .activation(id) = request.binding, id == state.identity else { return }
        guard let presenter = presenters.last else { scheduleRecovery(request); return }
        pending = nil; dismissRecovery()
        guard ownership() == state, !isStopping else { return }
        switch request.payload {
        case let .window(window):
            presenter.open(window)
            if !request.automatic, ownership() == state, !isStopping { activateApplication() }
        case let .url(url):
            presenter.open(.main)
            guard ownership() == state, !isStopping else { return }
            activateApplication()
            guard ownership() == state, !isStopping else { return }
            receiveURL(url, state.activation)
        case let .spotlight(identifier):
            if receiveSpotlight(identifier, state.activation), ownership() == state, !isStopping {
                presenter.open(.main)
                if ownership() == state, !isStopping { activateApplication() }
            }
        }
    }

    private func scheduleRecovery(_ request: Request) {
        guard recoveryTask == nil, recoveredRequest != request.id else { return }
        let token = UUID(); recoveryID = token
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.recoveryID == token { self.recoveryTask = nil; self.recoveryID = nil } }
            do { try Task.checkCancellation(); try await self.recoveryDelay(); try Task.checkCancellation() } catch { return }
            guard self.isCurrent(request.id), self.presenters.isEmpty else { return }
            self.recoveredRequest = request.id
            let presentation = UUID(); self.recoveryPresentation = presentation
            self.recovery.show(resetAndQuit: { [weak self] in
                guard let self, self.recoveryPresentation == presentation, self.isCurrent(request.id) else { return }
                self.pending = nil; self.dismissRecovery()
                self.resetAndQuit()
            }, cancel: { [weak self] in
                guard let self, self.recoveryPresentation == presentation, self.pending?.id == request.id else { return }
                self.cancelPresentation()
            })
        }
    }
    private func isCurrent(_ receipt: UUID) -> Bool {
        guard !isStopping, let pending, pending.id == receipt,
              case let .activation(id) = pending.binding else { return false }
        let state = ownership(); return state.ready && state.identity == id
    }
    private func dismissRecovery() {
        recoveryTask?.cancel(); recoveryTask = nil; recoveryID = nil
        if recoveredRequest != nil { recoveredRequest = nil; recoveryPresentation = nil; recovery.dismiss() }
    }
}
