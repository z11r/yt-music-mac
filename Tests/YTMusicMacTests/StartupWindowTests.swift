import Foundation
import Observation
import Testing
@testable import YTMusicMac

@Suite("Startup window ownership", .serialized) @MainActor
struct StartupWindowTests {
    @Test func restorationGatePreservesSystemAndOlderMacOSBeforeAndAfterConfiguration() {
        var unconfigured = StartupWindowRestorationGate()
        #expect(unconfigured.permitsRestoration)
        let installed = unconfigured.install(.system, supportsSelection: true)
        #expect(installed)
        #expect(unconfigured.permitsRestoration)
        for policy in StartupWindowPolicy.allCases {
            var legacy = StartupWindowRestorationGate()
            let installed = legacy.install(policy, supportsSelection: false)
            #expect(installed)
            #expect(legacy.policy == .system && legacy.permitsRestoration)
        }
    }

    @Test func explicitRestorationDecisionIsFrozenForTheWholeLaunch() {
        for policy in [StartupWindowPolicy.main, .mini, .none] {
            var gate = StartupWindowRestorationGate()
            let installed = gate.install(policy, supportsSelection: true)
            #expect(installed)
            #expect(!gate.permitsRestoration)
            let reinstalled = gate.install(.system, supportsSelection: true)
            #expect(!reinstalled)
            #expect(gate.policy == policy && !gate.permitsRestoration)
        }
        var system = StartupWindowRestorationGate()
        let installed = system.install(.system, supportsSelection: true)
        let reinstalled = system.install(.none, supportsSelection: true)
        #expect(installed && !reinstalled)
        #expect(system.permitsRestoration)
    }

    @Test func modernExplicitFunnelCompletesOnceWithoutCallingNativeRestoration() {
        for policy in [StartupWindowPolicy.main, .mini, .none] {
            var gate = StartupWindowRestorationGate()
            gate.install(policy, supportsSelection: true)
            var nativeCalls = 0, completions = 0
            let recognized = gate.resolveRestoration(native: { nativeCalls += 1; return false },
                decline: { completions += 1 })
            #expect(recognized && nativeCalls == 0 && completions == 1)
        }
    }

    @Test func nativeFunnelRetainsItsReturnValueAndCompletionForSystemLegacyAndUnknownSettings() {
        var cases = [StartupWindowRestorationGate()]
        for policy in StartupWindowPolicy.allCases {
            var gate = StartupWindowRestorationGate()
            gate.install(policy, supportsSelection: false)
            cases.append(gate)
        }
        for value in [StartupPreferenceValue.text("system"), .text("future"), .unsupported] {
            let memory = StartupPreferenceMemory(value)
            let preferences = StartupWindowPreferences(access: memory.access, supportsSelection: true)
            var gate = StartupWindowRestorationGate()
            gate.install(preferences.launchPolicy, supportsSelection: true)
            cases.append(gate)
            #expect(memory.writes.isEmpty)
        }
        for gate in cases {
            for nativeResult in [false, true] {
                var nativeCalls = 0, declines = 0
                let recognized = gate.resolveRestoration(native: { nativeCalls += 1; return nativeResult },
                    decline: { declines += 1 })
                #expect(recognized == nativeResult && nativeCalls == 1 && declines == 0)
            }
        }
    }

    @Test func nextLaunchPreferenceDoesNotRebindTheCurrentNativeRestorationGate() {
        let memory = StartupPreferenceMemory(.text("mini"))
        let preferences = StartupWindowPreferences(access: memory.access, supportsSelection: true)
        var gate = StartupWindowRestorationGate()
        gate.install(preferences.launchPolicy, supportsSelection: true)
        preferences.select(.system)
        let reinstalled = gate.install(preferences.selection, supportsSelection: true)
        #expect(!reinstalled && gate.policy == .mini && !gate.permitsRestoration)
        #expect(StartupWindowPreferences(access: memory.access, supportsSelection: true).launchPolicy == .system)
    }

    @Test func noWindowBootstrapsWithoutAnyViewAndNeverPresentsRecoveryAutomatically() async {
        let f = StartupFixture(policy: .none)
        f.coordinator.start(); f.coordinator.start()
        await f.coordinator.waitForBootstrap(); await Task.yield()
        #expect(f.starts == 1 && f.activations == [f.state.activation])
        #expect(f.windows.isEmpty && f.recovery.shows == 0 && f.urls.isEmpty && f.foreground == 0)
        await f.coordinator.shutdown()
        #expect(f.shutdowns == 1)
    }

    @Test func heldProfileRegistryNeverAdmitsTheProvisionalDefaultRuntime() async throws {
        var selected = try AppProfile.additional(name: "Selected", identifier: UUID())
        selected.isInitialized = true
        var archive = AppProfileArchive.original
        archive.profiles.append(selected); archive.selectedID = selected.id
        let gate = StartupGate(), registry = StartupProfileRegistry(archive: archive, gate: gate)
        let initial = StartupRuntime(profile: .original)
        let owner = AppProfileOwner(initial: initial, registry: registry, prepare: { profile, _ in
            PreparedAppProfile { StartupRuntime(profile: profile) }
        }, bind: { _, _ in })
        var received: [String] = [], opened = 0
        let coordinator = AppLaunchCoordinator(policy: .none, ownership: {
            .init(activation: owner.activationID, ready: owner.accepts(owner.activationID))
        }, start: { await owner.start() }, activate: { _ in }, receiveURL: { _, activation in
            guard owner.accepts(activation) else { return }; received.append(owner.current.profile.id)
        }, receiveSpotlight: { _, _ in false }, shutdown: { await owner.shutdown() }, recovery: StartupRecovery(),
        resetAndQuit: {}, validateURL: { _ in true }, recoveryDelay: {})
        coordinator.openURL(URL(string: "https://music.youtube.com/watch?v=abcDEF12_-3")!)
        coordinator.registerPresenter(id: UUID(), statusLabel: true) { _ in opened += 1 }
        coordinator.start(); await gate.waitStarted()
        #expect(initial.starts == 0 && received.isEmpty && opened == 0)
        await gate.release(); await coordinator.waitForBootstrap()
        #expect(initial.starts == 0 && owner.current.starts == 1)
        #expect(received == [selected.id] && opened == 1)
        await coordinator.shutdown()
    }

    @Test func preselectionURLWaitsForResolvedOwnerAndLabelPresenterWithoutMain() async {
        let gate = StartupGate(), f = StartupFixture(policy: .mini)
        f.startGate = gate
        let receipt = UUID()
        #expect(f.coordinator.openURL(f.url, receipt: receipt))
        f.coordinator.start(); await gate.waitStarted()
        f.state.activation = UUID()
        f.installLabel()
        #expect(f.urls.isEmpty && f.windows.isEmpty && f.activations.isEmpty)
        await gate.release(); await f.coordinator.waitForBootstrap()
        #expect(f.urls == [f.state.activation] && f.windows == [.main])
        #expect(f.coordinator.hasStatusPresenter && f.recovery.shows == 0)
        #expect(!f.coordinator.openURL(f.url, receipt: receipt))
        #expect(f.urls.count == 1)
        await f.coordinator.shutdown()
    }

    @Test func explicitDockRequestReplacesPendingMiniStartup() async {
        let f = StartupFixture(policy: .mini), delay = StartupGate()
        f.recoveryGate = delay
        f.coordinator.start(); await f.coordinator.waitForBootstrap()
        #expect(f.windows.isEmpty)
        f.coordinator.requestWindow(.main)
        f.installLabel()
        #expect(f.windows == [.main] && f.recovery.shows == 0)
        await delay.release()
        await f.coordinator.shutdown()
    }

    @Test func miniStartupCanUseTheLabelWithoutConstructingMain() async {
        let f = StartupFixture(policy: .mini)
        f.installLabel(); f.coordinator.start(); await f.coordinator.waitForBootstrap()
        #expect(f.windows == [.mini] && f.starts == 1 && f.foreground == 0)
        f.coordinator.requestWindow(.main)
        #expect(f.foreground == 1)
        await f.coordinator.shutdown()
    }

    @Test func latePresentationNeverRetargetsAcrossAtoBtoA() async {
        let f = StartupFixture()
        f.coordinator.start(); await f.coordinator.waitForBootstrap()
        let first = f.state.activation
        f.coordinator.openURL(f.url)
        f.state.activation = UUID(); f.state.ready = false; f.coordinator.ownershipChanged()
        f.state.activation = UUID(); f.state.ready = true; f.coordinator.ownershipChanged()
        f.installLabel()
        #expect(f.urls.isEmpty && f.windows.isEmpty)
        #expect(!f.coordinator.requestWindow(.main, expectedActivation: first))
        #expect(f.coordinator.requestWindow(.main, expectedActivation: f.state.activation))
        #expect(f.windows == [.main])
        await f.coordinator.shutdown()
    }

    @Test func pendingNavigationIsRevokedByAnAccountChangeWithinTheSameProfile() async {
        let f = StartupFixture()
        f.coordinator.start(); await f.coordinator.waitForBootstrap()
        let profile = f.state.activation
        f.coordinator.openURL(f.url)
        f.state.account = UUID(); f.coordinator.ownershipChanged()
        f.installLabel()
        #expect(f.state.activation == profile && f.urls.isEmpty && f.windows.isEmpty)
        f.coordinator.openURL(f.url)
        #expect(f.urls == [profile] && f.windows == [.main])
        await f.coordinator.shutdown()
    }

    @Test func observationUpdatesReadyOwnershipWithoutAnyWindowTask() async {
        let f = StartupFixture()
        f.coordinator.start(); await f.coordinator.waitForBootstrap()
        f.state.activation = UUID()
        await eventually { f.coordinator.readyActivation == f.state.activation }
        #expect(f.activations.last == f.state.activation)
        await f.coordinator.shutdown()
    }

    @Test func replacedPendingInputIsBoundedAndInvalidInputDoesNothing() async {
        let f = StartupFixture()
        f.coordinator.start(); await f.coordinator.waitForBootstrap()
        for _ in 0..<100 { f.coordinator.openURL(f.url) }
        f.coordinator.openSpotlight("fixture.index")
        #expect(!f.coordinator.openURL(URL(string: "https://example.invalid/private")!))
        #expect(!f.coordinator.openSpotlight(String(repeating: "x", count: 1_025)))
        #expect(!f.coordinator.openSpotlight("invalid\nidentifier"))
        f.installLabel()
        #expect(f.urls.isEmpty && f.spotlights == [f.state.activation] && f.windows == [.main])
        await f.coordinator.shutdown()
    }

    @Test func unrecognizedSpotlightDoesNotOpenAWindow() async {
        let f = StartupFixture(); f.acceptSpotlight = false
        f.installLabel(); f.coordinator.start(); await f.coordinator.waitForBootstrap()
        f.coordinator.openSpotlight("fixture.foreign")
        #expect(f.spotlights.count == 1 && f.windows.isEmpty)
        await f.coordinator.shutdown()
    }

    @Test func presenterReplacementUnregistersOnlyItsOwnToken() async {
        let f = StartupFixture()
        f.coordinator.start(); await f.coordinator.waitForBootstrap()
        let old = UUID(), new = UUID()
        var obsolete = 0
        f.coordinator.registerPresenter(id: old) { _ in obsolete += 1 }
        f.coordinator.registerPresenter(id: new, statusLabel: true) { f.windows.append($0) }
        f.coordinator.unregisterPresenter(id: old)
        f.coordinator.requestWindow(.main)
        #expect(obsolete == 0 && f.windows == [.main] && f.coordinator.hasStatusPresenter)
        await f.coordinator.shutdown()
    }

    @Test func changedOwnerDuringOpenCannotReceiveTheURL() async {
        let f = StartupFixture()
        f.coordinator.start(); await f.coordinator.waitForBootstrap()
        f.coordinator.registerPresenter(id: UUID()) { _ in f.state.activation = UUID() }
        f.coordinator.openURL(f.url)
        #expect(f.urls.isEmpty)
        await f.coordinator.shutdown()
    }

    @Test func recoveryRequiresCurrentRequestAndResetRequiresTheCurrentPanel() async throws {
        let f = StartupFixture()
        f.coordinator.start(); await f.coordinator.waitForBootstrap()
        f.coordinator.requestWindow(.main)
        await eventually { f.recovery.shows == 1 }
        let oldReset = try #require(f.recovery.reset)
        f.state.ready = false; f.coordinator.ownershipChanged()
        oldReset(); #expect(f.resets == 0 && f.recovery.dismissals == 1)
        f.state.ready = true; f.coordinator.ownershipChanged()
        await eventually { f.recovery.shows == 2 }
        oldReset(); #expect(f.resets == 0)
        let current = try #require(f.recovery.reset)
        current(); current(); #expect(f.resets == 1)
        await f.coordinator.shutdown()
    }

    @Test func missingPresenterRecoveryIsDismissedOnlyByFulfillmentStalenessOrCancel() async {
        let f = StartupFixture()
        f.coordinator.start(); await f.coordinator.waitForBootstrap()
        f.coordinator.requestWindow(.main)
        await eventually { f.recovery.shows == 1 }
        f.installLabel()
        #expect(f.windows == [.main] && f.recovery.dismissals == 1)
        f.coordinator.unregisterPresenter(id: f.label)
        f.coordinator.requestWindow(.main)
        await eventually { f.recovery.shows == 2 }
        f.recovery.cancel?()
        f.installLabel(); #expect(f.windows.count == 1 && f.resets == 0)
        await f.coordinator.shutdown()
    }

    @Test func quittingDuringHeldBootstrapCannotResurrectOwnershipOrPendingActions() async {
        let f = StartupFixture(), gate = StartupGate()
        f.startGate = gate
        f.coordinator.openURL(f.url); f.coordinator.start(); await gate.waitStarted()
        let stopping = Task { await f.coordinator.shutdown() }
        await eventually { f.shutdowns == 1 }
        f.installLabel()
        #expect(!f.coordinator.requestWindow(.main) && !f.coordinator.openURL(f.url))
        await gate.release(); await stopping.value
        #expect(f.coordinator.readyActivation == nil && f.activations.isEmpty && f.urls.isEmpty && f.windows.isEmpty)
    }

    @Test func repeatedShutdownWaitsForTheSameAcceptedOwnerDrain() async {
        let f = StartupFixture(), gate = StartupGate()
        f.shutdownGate = gate
        f.coordinator.start(); await f.coordinator.waitForBootstrap()
        let first = Task { await f.coordinator.shutdown() }
        await gate.waitStarted()
        var joined = false
        let second = Task { await f.coordinator.shutdown(); joined = true }
        for _ in 0..<8 { await Task.yield() }
        #expect(!joined && f.shutdowns == 1)
        await gate.release(); await first.value; await second.value
        #expect(joined && f.shutdowns == 1)
    }

    @Test func nativeWindowChoiceIsCapabilityGatedAndNextLaunchOnly() {
        let memory = StartupPreferenceMemory(.text("mini"))
        let old = StartupWindowPreferences(access: memory.access, supportsSelection: false)
        #expect(old.selection == .mini && old.launchPolicy == .system && memory.writes.isEmpty)
        old.select(.none); #expect(memory.writes.isEmpty)
        let modern = StartupWindowPreferences(access: memory.access, supportsSelection: true)
        #expect(modern.launchPolicy == .mini)
        modern.select(.none)
        #expect(modern.selection == .none && modern.launchPolicy == .mini && memory.writes == ["none"])
        #expect(StartupWindowPreferences(access: memory.access, supportsSelection: true).launchPolicy == .none)
    }

    @Test func malformedFuturePreferencesAreRetainedWithoutAutomaticWritesOrLoginCalls() {
        for value in [StartupPreferenceValue.unsupported, .text("future-value"), .text(String(repeating: "x", count: 33))] {
            let memory = StartupPreferenceMemory(value)
            let prefs = StartupWindowPreferences(access: memory.access, supportsSelection: true)
            #expect(prefs.hasUnknownValue && prefs.selection == .system && prefs.launchPolicy == .system)
            #expect(memory.writes.isEmpty)
        }
    }

    @Test func scenePolicySuppressesSecondaryAndRestoredWindowsOnlyForExplicitChoices() {
        #expect(StartupWindowPolicy.system.launch(for: .main) == .automatic)
        #expect(StartupWindowPolicy.system.launch(for: nil) == .automatic)
        #expect(StartupWindowPolicy.main.launch(for: .main) == .presented)
        #expect(StartupWindowPolicy.main.launch(for: .mini) == .suppressed)
        #expect(StartupWindowPolicy.mini.launch(for: .mini) == .presented)
        #expect(StartupWindowPolicy.mini.launch(for: nil) == .suppressed)
        #expect(StartupWindowPolicy.none.launch(for: .main) == .suppressed)
    }

    private func eventually(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(condition())
    }
}

@MainActor private final class StartupPreferenceMemory {
    var value: StartupPreferenceValue
    var writes: [String] = []
    init(_ value: StartupPreferenceValue) { self.value = value }
    var access: StartupWindowPreferenceAccess { .init(read: { self.value }, write: { self.writes.append($0); self.value = .text($0) }) }
}

@MainActor @Observable private final class StartupState {
    var activation = UUID()
    var account = UUID()
    var ready = false
}
@MainActor private final class StartupRecovery: StartupRecoveryPresenting {
    var shows = 0, dismissals = 0
    var reset: (() -> Void)?, cancel: (() -> Void)?
    func show(resetAndQuit: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void) {
        shows += 1; reset = resetAndQuit; self.cancel = cancel
    }
    func dismiss() { dismissals += 1; reset = nil; cancel = nil }
}
private actor StartupGate {
    private var began = false, released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { began = true; if !released { await withCheckedContinuation { continuation = $0 } } }
    func waitStarted() async { while !began { await Task.yield() } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor StartupProfileRegistry: AppProfileRegistry {
    let archive: AppProfileArchive
    let gate: StartupGate
    init(archive: AppProfileArchive, gate: StartupGate) { self.archive = archive; self.gate = gate }
    func load() async -> AppProfileRegistrySnapshot {
        await gate.hold(); return .init(archive: archive, revision: Data([1]))
    }
    func save(_ archive: AppProfileArchive, replacing revision: Data?) throws -> AppProfileRegistrySnapshot {
        throw AppProfileError.unavailable
    }
}
@MainActor private final class StartupRuntime: AppProfileRuntime {
    var profile: AppProfile
    var starts = 0
    init(profile: AppProfile) { self.profile = profile }
    func quiesce() {}
    func settle() async -> PlaybackOutputSettlement { .quiet }
    func resumePausedOwnership() {}
    func shutdown() async {}
    func startPaused() async { starts += 1 }
}
@MainActor private final class StartupFixture {
    let state = StartupState(), recovery = StartupRecovery(), label = UUID()
    let url = URL(string: "https://music.youtube.com/watch?v=abcDEF12_-3")!
    var startGate: StartupGate?
    var recoveryGate: StartupGate?
    var shutdownGate: StartupGate?
    var starts = 0, shutdowns = 0, resets = 0
    var activations: [UUID] = [], urls: [UUID] = [], spotlights: [UUID] = []
    var windows: [StartupWindowID] = []
    var acceptSpotlight = true
    var foreground = 0
    var coordinator: AppLaunchCoordinator!
    init(policy: StartupWindowPolicy = .system) {
        coordinator = AppLaunchCoordinator(policy: policy, ownership: { [weak self] in
            .init(activation: self?.state.activation ?? UUID(), accountEpoch: self?.state.account, ready: self?.state.ready == true)
        }, start: { [weak self] in
            guard let self else { return }; self.starts += 1
            if let gate = self.startGate { await gate.hold() }
            self.state.ready = true
        }, activate: { [weak self] in self?.activations.append($0) },
        receiveURL: { [weak self] _, owner in self?.urls.append(owner) },
        receiveSpotlight: { [weak self] _, owner in self?.spotlights.append(owner); return self?.acceptSpotlight == true },
        shutdown: { [weak self] in
            guard let self else { return }; self.shutdowns += 1
            if let gate = self.shutdownGate { await gate.hold() }
        }, recovery: recovery,
        resetAndQuit: { [weak self] in self?.resets += 1 }, validateURL: { $0.host == "music.youtube.com" },
        activateApplication: { [weak self] in self?.foreground += 1 },
        recoveryDelay: { [weak self] in if let gate = self?.recoveryGate { await gate.hold() } })
    }
    func installLabel() { coordinator.registerPresenter(id: label, statusLabel: true) { [weak self] in self?.windows.append($0) } }
}
