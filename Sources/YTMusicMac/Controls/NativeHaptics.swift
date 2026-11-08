import AppKit
import CoreFoundation
import MusicCore
import Observation

@MainActor protocol NativeHapticPerforming {
    /// Requests feedback; AppKit can suppress it. This does not report hardware success.
    func perform()
}

@MainActor struct AppKitHapticPerformer: NativeHapticPerforming {
    func perform() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

enum HapticsText {
    static func text(_ key: StaticString) -> String {
        AppLocalization.bundle.localizedString(forKey: String(describing: key), value: nil, table: "Haptics")
    }
}

struct NativeHapticOwner: Equatable {
    let instance: UUID
    let accountGeneration: UUID
    func accepts(current: Self, allowsActions: Bool, accountIsWorking: Bool) -> Bool {
        self == current && allowsActions && !accountIsWorking
    }
}
struct NativeQueueInteractionTarget {
    let owner: NativeHapticOwner
    let revision: QueueRevision
}
enum NativeQueueInteraction {
    case move(IndexSet, destination: Int), undo, shuffle, cycleRepeat
}

/// No tasks, timers, event monitors or hardware discovery. Only explicit view actions emit.
@MainActor @Observable final class NativeHaptics {
    nonisolated static let preferenceKey = "nativeHapticsEnabled"
    let instance = UUID()
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let performer: (any NativeHapticPerforming)?
    @ObservationIgnored private let monotonic: @Sendable () -> TimeInterval
    @ObservationIgnored private var lastRequest: TimeInterval?
    private var preferenceRevision: UInt64 = 0

    init(preferences: UserDefaults, performer: (any NativeHapticPerforming)?,
         monotonic: @escaping @Sendable () -> TimeInterval = PlaybackOutputTime.monotonic) {
        self.preferences = preferences; self.performer = performer; self.monotonic = monotonic
    }
    var isEnabled: Bool {
        _ = preferenceRevision
        guard let value = preferences.object(forKey: Self.preferenceKey) as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }
    fileprivate func setEnabled(_ value: Bool) {
        preferences.set(value, forKey: Self.preferenceKey)
        preferenceRevision &+= 1
    }
    fileprivate func emit() {
        guard isEnabled, let performer else { return }
        let instant = monotonic()
        guard instant.isFinite, instant >= 0 else { return }
        if let lastRequest {
            if instant < lastRequest { self.lastRequest = instant; return }
            let elapsed = instant - lastRequest
            guard elapsed.isFinite, elapsed >= 0.15 else { return }
        }
        lastRequest = instant
        performer.perform()
    }
}

extension AppSession {
    var nativeHapticOwner: NativeHapticOwner {
        .init(instance: nativeHaptics.instance, accountGeneration: accountGeneration)
    }
    var nativeQueueInteractionTarget: NativeQueueInteractionTarget {
        .init(owner: nativeHapticOwner, revision: queue.revision)
    }
    private func acceptsNativeHapticOwner(_ owner: NativeHapticOwner) -> Bool {
        owner.accepts(current: nativeHapticOwner, allowsActions: acceptsProfileActions, accountIsWorking: account.isWorking)
    }
    func setNativeHapticsEnabled(_ value: Bool, owner: NativeHapticOwner) {
        guard acceptsNativeHapticOwner(owner) else { return }
        nativeHaptics.setEnabled(value)
    }

    /// Called only by direct queue-control view actions, never shared automation dispatch.
    func performNativeQueueInteraction(_ action: NativeQueueInteraction, target: NativeQueueInteractionTarget) {
        guard acceptsNativeHapticOwner(target.owner), queue.revision == target.revision else { return }
        let before = NativeQueueFeedbackState(queue)
        switch action {
        case let .move(offsets, destination): moveQueueEntries(from: offsets, to: destination)
        case .undo: undoQueueEdit()
        case .shuffle: if !queue.isEmpty { toggleShuffle() }
        case .cycleRepeat: if !queue.isEmpty { cycleRepeat() }
        }
        guard acceptsNativeHapticOwner(target.owner), NativeQueueFeedbackState(queue) != before else { return }
        nativeHaptics.emit()
    }
}

private struct NativeQueueFeedbackState: Equatable {
    let entryIDs: [UUID]
    let selected: UUID?
    let shuffled: Bool
    let repeatMode: RepeatMode
    init(_ queue: PlaybackQueue) {
        entryIDs = queue.entries.map(\.id); selected = queue.currentEntryID
        shuffled = queue.isShuffled; repeatMode = queue.repeatMode
    }
}
