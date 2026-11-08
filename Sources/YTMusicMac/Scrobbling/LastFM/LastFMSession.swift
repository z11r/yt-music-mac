import Foundation
import MusicCore
import Observation

@MainActor @Observable
final class LastFMSession {
    private(set) var state = LastFMViewState()
    private(set) var scope = UUID()
    @ObservationIgnored private let coordinator: LastFMCoordinator?
    @ObservationIgnored private var profile: String?
    @ObservationIgnored private var continuity: UInt64 = 0
    @ObservationIgnored private var playGeneration: UInt64 = 0

    init(coordinator: LastFMCoordinator?) {
        self.coordinator = coordinator
        if let coordinator {
            Task { [weak self] in
                await coordinator.observe { [weak self] scope, state in
                    Task { @MainActor in
                        guard let self, self.scope == scope else { return }
                        self.state = state
                    }
                }
            }
        }
    }

    func bindAccount(_ profile: String?, currentPlayback: (@MainActor () -> (Track, PlaybackOccurrence)?)? = nil) {
        guard self.profile != profile else { return }
        self.profile = profile; continuity = 0; playGeneration = 0
        scope = UUID(); state = .init()
        guard let coordinator else { return }
        let expected = scope
        coordinator.gate.revoke(to: expected)
        Task { [weak self] in
            let state = await coordinator.bind(profile: profile, scope: expected)
            guard let self, self.scope == expected else { return }
            self.state = state
            if state.enabled, state.connected, let (track, occurrence) = currentPlayback?() {
                self.begin(track: track, occurrence: occurrence, intent: .continuation)
            }
        }
    }

    func configure(apiKey: String, sharedSecret: String, expectedScope: UUID) async {
        guard scope == expectedScope, let coordinator,
              let revision = coordinator.gate.changeIntent(scope: expectedScope) else { return }
        let state = await coordinator.configure(application: .init(apiKey: apiKey, sharedSecret: sharedSecret), expectedScope: expectedScope, revision: revision)
        accept(state, scope: expectedScope, revision: revision)
    }
    func beginAuthorization(expectedScope: UUID) async {
        guard scope == expectedScope, let coordinator,
              let revision = coordinator.gate.changeIntent(scope: expectedScope) else { return }
        let state = await coordinator.beginAuthorization(expectedScope: expectedScope, revision: revision)
        accept(state, scope: expectedScope, revision: revision)
    }
    func approvalURL(expectedScope: UUID, authorizationID: UUID) async -> URL? {
        guard scope == expectedScope, let coordinator else { return nil }
        let value = await coordinator.approvalURL(expectedScope: expectedScope, authorizationID: authorizationID)
        guard scope == expectedScope, state.authorizationID == authorizationID else { return nil }
        return value
    }
    func completeAuthorization(expectedScope: UUID, authorizationID: UUID) async {
        guard scope == expectedScope, state.authorizationID == authorizationID, let coordinator,
              let revision = coordinator.gate.changeIntent(scope: expectedScope) else { return }
        let state = await coordinator.completeAuthorization(expectedScope: expectedScope, authorizationID: authorizationID, revision: revision)
        accept(state, scope: expectedScope, revision: revision)
    }
    func cancelAuthorization(expectedScope: UUID) async {
        guard scope == expectedScope, let coordinator,
              let revision = coordinator.gate.changeIntent(scope: expectedScope) else { return }
        let state = await coordinator.cancelAuthorization(expectedScope: expectedScope, revision: revision)
        accept(state, scope: expectedScope, revision: revision)
    }
    private func accept(_ state: LastFMViewState, scope: UUID, revision: UUID) {
        if self.scope == scope, coordinator?.gate.matches(scope: scope, revision: revision) == true { self.state = state }
    }
    func setEnabled(_ enabled: Bool, expectedScope: UUID) async {
        guard scope == expectedScope, let coordinator else { return }
        guard let revision = coordinator.gate.changeIntent(scope: expectedScope) else { return }
        let state = await coordinator.setEnabled(enabled, expectedScope: expectedScope, revision: revision)
        if scope == expectedScope, coordinator.gate.matches(scope: expectedScope, revision: revision) { self.state = state }
    }
    func disconnect(expectedScope: UUID) async {
        guard scope == expectedScope, let coordinator else { return }
        guard let revision = coordinator.gate.changeIntent(scope: expectedScope) else { return }
        let state = await coordinator.disconnect(expectedScope: expectedScope, revision: revision)
        if scope == expectedScope, coordinator.gate.matches(scope: expectedScope, revision: revision) { self.state = state }
    }
    func discardPending(expectedScope: UUID) async {
        guard scope == expectedScope, let coordinator else { return }
        let state = await coordinator.discardPending(expectedScope: expectedScope)
        if scope == expectedScope { self.state = state }
    }
    func sendUnsent(expectedScope: UUID) async {
        guard scope == expectedScope, let coordinator else { return }
        let state = await coordinator.sendUnsent(expectedScope: expectedScope)
        if scope == expectedScope { self.state = state }
    }
    func retryRefused(expectedScope: UUID) async {
        guard scope == expectedScope, let coordinator else { return }
        let state = await coordinator.retryRefused(expectedScope: expectedScope)
        if scope == expectedScope { self.state = state }
    }
    func begin(track: Track, occurrence: PlaybackOccurrence, intent: ListeningStartIntent, chosenByUser: Bool? = nil) {
        guard let coordinator, state.enabled else { return }
        let expected = scope
        continuity &+= 1
        playGeneration &+= 1
        let stamp = continuity
        let generation = playGeneration
        Task { await coordinator.begin(track: track, occurrence: occurrence, intent: intent, expectedScope: expected, chosenByUser: chosenByUser, continuity: stamp, playGeneration: generation) }
    }
    func interrupt() {
        guard let coordinator, state.enabled else { return }
        let expected = scope
        continuity &+= 1
        let stamp = continuity
        let generation = playGeneration
        Task { await coordinator.interrupt(expectedScope: expected, continuity: stamp, playGeneration: generation) }
    }
    func sample(occurrence: PlaybackOccurrence, position: Double, duration: Double, ended: Bool) {
        guard let coordinator, state.enabled else { return }
        let expected = scope
        let stamp = continuity
        let generation = playGeneration
        let time = ProcessInfo.processInfo.systemUptime
        let wallTime = Date()
        Task { await coordinator.sample(occurrence: occurrence, position: position, duration: duration, ended: ended,
                                        expectedScope: expected, continuity: stamp, playGeneration: generation, observedTime: time, observedWallTime: wallTime) }
    }
    func stop() async {
        guard let coordinator else { return }
        let expected = scope
        _ = coordinator.gate.changeIntent(scope: expected)
        await coordinator.stop(expectedScope: expected)
    }
}
