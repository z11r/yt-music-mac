import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@MainActor @Suite("Explicit native queue haptics")
struct NativeHapticsTests {
    @Test func missingOrUnsupportedPreferencesStayOffWithoutRewritingThem() async {
        let f = HapticsFixture(); defer { f.preferences.remove() }
        #expect(!f.session.nativeHaptics.isEnabled)
        #expect(f.preferences.defaults.object(forKey: NativeHaptics.preferenceKey) == nil)
        for value: Any in ["true", 1, Data([1]), ["version": 2]] {
            f.preferences.defaults.set(value, forKey: NativeHaptics.preferenceKey)
            #expect(!f.session.nativeHaptics.isEnabled)
            f.act(.cycleRepeat)
            #expect(f.performer.requests == 0 && f.clock.reads == 0)
            #expect(f.preferences.defaults.object(forKey: NativeHaptics.preferenceKey) != nil)
        }
        #expect(await f.transport.attempts == 0)
    }
    @Test func offDoesNotChangeTheExistingActionAndAnAbsentPerformerNeedsNoFallback() {
        let f = HapticsFixture(); defer { f.preferences.remove() }
        let original = f.session.queue.entries.map(\.id)
        f.act(.move([0], destination: 3))
        #expect(f.session.queue.entries.map(\.id) == [original[1], original[2], original[0]])
        #expect(f.performer.requests == 0 && f.clock.reads == 0)
        let silent = HapticsFixture(installsFakePerformer: false); defer { silent.preferences.remove() }
        silent.enable(); silent.act(.cycleRepeat)
        #expect(silent.session.queue.repeatMode == .all && silent.performer.requests == 0 && silent.clock.reads == 0)
    }
    @Test func oneSuccessfulMovePreservesDuplicateOccurrencesAndSelection() async {
        let f = HapticsFixture(); defer { f.preferences.remove() }
        f.enable()
        let occurrence = f.session.queue.beginPlayback(), original = f.session.queue.entries
        f.act(.move([0], destination: 3))
        #expect(f.session.queue.entries.map(\.id) == [original[1].id, original[2].id, original[0].id])
        #expect(f.session.queue.entries.map(\.track.id) == ["duplicate", "third", "duplicate"])
        #expect(f.session.queue.currentOccurrence == occurrence && f.session.queue.currentEntryID == original[0].id)
        #expect(f.performer.requests == 1 && f.clock.reads == 1)
        #expect(await f.transport.attempts == 0)
    }
    @Test func undoShuffleAndRepeatEmitOnceForEachActualDirectChange() {
        let f = HapticsFixture(); defer { f.preferences.remove() }
        f.enable()
        let original = f.session.queue.entries.map(\.id)
        f.act(.move([0], destination: 3)); f.clock.set(2)
        f.act(.undo)
        #expect(f.session.queue.entries.map(\.id) == original)
        f.clock.set(3); f.act(.shuffle)
        #expect(f.session.queue.isShuffled)
        f.clock.set(4); f.act(.cycleRepeat)
        #expect(f.session.queue.repeatMode == .all && f.performer.requests == 4)
    }
    @Test func noOpMovesAndUndoDoNotEmitOrConsumeTheBurstWindow() {
        let f = HapticsFixture(); defer { f.preferences.remove() }
        f.enable()
        f.act(.move([], destination: 0)); f.act(.move([0], destination: 1))
        #expect(f.performer.requests == 0 && f.clock.reads == 0)
        f.session.queue = PlaybackQueue()
        f.act(.undo); f.act(.shuffle); f.act(.cycleRepeat)
        #expect(f.performer.requests == 0 && f.clock.reads == 0)
        #expect(f.session.queue.isEmpty && !f.session.queue.isShuffled && f.session.queue.repeatMode == .off)
    }
    @Test func ordinaryMutatorsAndExistingAutomationDispatchStaySilentWhileEnabled() async {
        let f = HapticsFixture(); defer { f.preferences.remove() }
        f.enable()
        f.session.toggleShuffle(); f.session.cycleRepeat()
        f.session.moveQueueEntries(from: [0], to: 3); f.session.undoQueueEdit()
        let environment = f.session.quickCommandEnvironment
        f.session.executeQuickCommand(.shuffle(false), environment: environment)
        #expect(!f.session.queue.isShuffled && f.session.queue.repeatMode == .all)
        f.session.quickCommands.present(); f.session.quickCommands.edit("repeat one")
        #expect(f.session.quickCommands.run(ticket: f.session.quickCommands.ticket) == .success(.repeatMode(.one)))
        #expect(f.session.queue.repeatMode == .one && f.performer.requests == 0 && f.clock.reads == 0)
        #expect(await f.transport.attempts == 0)
    }
    @Test func renderedAccountAndQueueTargetsCannotAffectReplacementState() {
        let f = HapticsFixture(); defer { f.preferences.remove() }
        f.enable()
        let oldAccount = f.session.nativeQueueInteractionTarget
        f.session.accountGeneration = UUID()
        f.session.performNativeQueueInteraction(.cycleRepeat, target: oldAccount)
        #expect(f.session.queue.repeatMode == .off && f.performer.requests == 0)
        let oldQueue = f.session.nativeQueueInteractionTarget
        f.session.queue.append([Track(id: "new", title: "New", artist: "Artist")])
        let order = f.session.queue.entries.map(\.id)
        f.session.performNativeQueueInteraction(.move([0], destination: 3), target: oldQueue)
        #expect(f.session.queue.entries.map(\.id) == order && f.performer.requests == 0)
        f.session.setNativeHapticsEnabled(false, owner: oldAccount.owner)
        #expect(f.session.nativeHaptics.isEnabled)
    }
    @Test func profileQuiesceAndShutdownRevokeFeedbackBeforeAnyLateViewAction() async {
        let f = HapticsFixture(); defer { f.preferences.remove() }
        f.enable()
        let target = f.session.nativeQueueInteractionTarget
        f.session.quiesceForProfileSwitch()
        f.session.performNativeQueueInteraction(.cycleRepeat, target: target)
        f.session.setNativeHapticsEnabled(false, owner: target.owner)
        #expect(f.session.queue.repeatMode == .off && f.session.nativeHaptics.isEnabled && f.performer.requests == 0)
        await f.session.settleForProfileSwitch()
        f.session.resumePausedProfileOwnership()
        f.session.performNativeQueueInteraction(.cycleRepeat, target: target)
        #expect(f.performer.requests == 0 && f.session.queue.repeatMode == .off)
        let fresh = f.session.nativeQueueInteractionTarget
        await f.session.shutdown()
        f.session.performNativeQueueInteraction(.cycleRepeat, target: fresh)
        #expect(f.performer.requests == 0 && f.session.queue.repeatMode == .off)
    }
    @Test func accountWorkingAndRevokedOwnershipRefuseARenderedAdmission() {
        let current = NativeHapticOwner(instance: UUID(), accountGeneration: UUID())
        #expect(!current.accepts(current: current, allowsActions: true, accountIsWorking: true))
        #expect(!current.accepts(current: current, allowsActions: false, accountIsWorking: false))
        #expect(current.accepts(current: current, allowsActions: true, accountIsWorking: false))
    }
    @Test func burstSuppressionHandlesBackwardAndInvalidClocksWithoutSchedulingAnything() {
        let f = HapticsFixture(); defer { f.preferences.remove() }
        f.enable(); f.clock.set(10); f.act(.cycleRepeat)
        f.clock.set(10.1); f.act(.cycleRepeat)
        #expect(f.performer.requests == 1)
        f.clock.set(10.3); f.act(.cycleRepeat)
        f.clock.set(5); f.act(.cycleRepeat)
        f.clock.set(5.1); f.act(.cycleRepeat)
        #expect(f.performer.requests == 2)
        f.clock.set(5.3); f.act(.cycleRepeat)
        for value in [Double.nan, .infinity, -.infinity, -1] { f.clock.set(value); f.act(.cycleRepeat) }
        #expect(f.performer.requests == 3)
        f.clock.set(6); f.act(.cycleRepeat)
        #expect(f.performer.requests == 4)
    }
    @Test func disablingSuppressesAnAlreadyRenderedActionWithoutSuppressingItsLocalChange() {
        let f = HapticsFixture(); defer { f.preferences.remove() }
        f.enable()
        let rendered = f.session.nativeQueueInteractionTarget
        f.session.setNativeHapticsEnabled(false, owner: rendered.owner)
        f.session.performNativeQueueInteraction(.cycleRepeat, target: rendered)
        #expect(f.session.queue.repeatMode == .all && f.performer.requests == 0 && f.clock.reads == 0)
    }
    @Test func preferencesAndOwnerTokensStayWithinTheInjectedLocalProfile() {
        let first = HapticsFixture(), second = HapticsFixture()
        defer { first.preferences.remove(); second.preferences.remove() }
        first.enable()
        #expect(!second.session.nativeHaptics.isEnabled)
        second.session.accountGeneration = first.session.accountGeneration
        second.enable()
        second.session.performNativeQueueInteraction(.cycleRepeat, target: first.session.nativeQueueInteractionTarget)
        #expect(second.session.queue.repeatMode == .off && second.performer.requests == 0)
        first.act(.cycleRepeat); second.act(.cycleRepeat)
        #expect(first.performer.requests == 1 && second.performer.requests == 1)
    }
    @Test func nativeCopyHasMatchingEnglishFrenchKeysAndDeletionRecognizesOnlyABoolean() throws {
        for locale in ["en", "fr"] {
            let directory = try #require(Bundle.module.url(forResource: locale, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: directory))
            let url = try #require(bundle.url(forResource: "Haptics", withExtension: "strings"))
            let values = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            #expect(values.count == 3 && values.values.allSatisfy { !$0.isEmpty })
            #expect(values["Haptic Feedback"] != nil && values["Use Haptics for Direct Queue Controls"] != nil)
            #expect(values.keys.contains { $0.hasPrefix("Off by default for each local profile.") })
        }
        #expect(ProfilePreferenceCleanup.accepts([NativeHaptics.preferenceKey: true]))
        #expect(!ProfilePreferenceCleanup.accepts([NativeHaptics.preferenceKey: 1]))
        #expect(!ProfilePreferenceCleanup.accepts([NativeHaptics.preferenceKey: "true"]))
    }
}

@MainActor private final class HapticsFixture {
    let preferences = SceneCheckPreferences()
    let performer = FakeHapticPerformer()
    let clock = HapticTestClock()
    let transport = SceneCheckTransport()
    let session: AppSession
    init(installsFakePerformer: Bool = true) {
        var configuration = AppSessionConfiguration.sceneCheck(preferences: preferences.defaults, transport: transport)
        configuration.nativeHapticPerformer = installsFakePerformer ? performer : nil
        configuration.nativeHapticClock = clock.read
        session = AppSession(configuration: configuration)
        session.queue.replace(with: [Track(id: "duplicate", title: "First", artist: "Artist"),
            Track(id: "duplicate", title: "Second occurrence", artist: "Artist"), Track(id: "third", title: "Third", artist: "Artist")])
    }
    func enable() { session.setNativeHapticsEnabled(true, owner: session.nativeHapticOwner) }
    func act(_ action: NativeQueueInteraction) {
        session.performNativeQueueInteraction(action, target: session.nativeQueueInteractionTarget)
    }
}
@MainActor private final class FakeHapticPerformer: NativeHapticPerforming {
    private(set) var requests = 0
    func perform() { requests += 1 }
}
private final class HapticTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 1
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func set(_ value: TimeInterval) { lock.withLock { instant = value } }
    func read() -> TimeInterval { lock.withLock { count += 1; return instant } }
}
