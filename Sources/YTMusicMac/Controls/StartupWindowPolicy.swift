import Foundation
import Observation
import SwiftUI

enum StartupWindowText {
    static func text(_ key: String) -> String {
        AppIdentity.resourceBundle.localizedString(forKey: key, value: key, table: "StartupWindow")
    }
}

enum StartupWindowPolicy: String, CaseIterable, Hashable, Sendable {
    case system, main, mini, none
    var title: String {
        switch self {
        case .system: StartupWindowText.text("Use macOS Window Settings")
        case .main: StartupWindowText.text("Main Window")
        case .mini: StartupWindowText.text("Mini Player")
        case .none: StartupWindowText.text("No Startup Window")
        }
    }
    func effective(supportsSelection: Bool) -> Self { supportsSelection ? self : .system }
    func launch(for window: StartupWindowID?) -> StartupSceneLaunch {
        switch self {
        case .system: .automatic
        case .main: window == .main ? .presented : .suppressed
        case .mini: window == .mini ? .presented : .suppressed
        case .none: .suppressed
        }
    }
}

enum StartupWindowID: String, Sendable { case main, mini = "mini-player" }
enum StartupSceneLaunch: Equatable, Sendable { case automatic, presented, suppressed }
enum StartupPreferenceValue { case absent, text(String), unsupported }

@MainActor struct StartupWindowPreferenceAccess {
    let read: () -> StartupPreferenceValue
    let write: (String) -> Void
    static func defaults(_ preferences: UserDefaults) -> Self {
        .init(read: {
            guard let value = preferences.object(forKey: StartupWindowPreferences.key) else { return .absent }
            guard let string = value as? String else { return .unsupported }
            return .text(string)
        }, write: { preferences.set($0, forKey: StartupWindowPreferences.key) })
    }
}

/// Process-wide window settings; changes affect the next launch, not this run's windows.
@MainActor @Observable final class StartupWindowPreferences {
    static let key = "startupWindowPolicy"
    let supportsSelection: Bool
    let launchPolicy: StartupWindowPolicy
    private(set) var selection: StartupWindowPolicy
    private(set) var hasUnknownValue: Bool
    @ObservationIgnored private let access: StartupWindowPreferenceAccess

    init(access: StartupWindowPreferenceAccess, supportsSelection: Bool, launchOverride: StartupWindowPolicy? = nil) {
        self.access = access; self.supportsSelection = supportsSelection
        let value = access.read()
        let stored: StartupWindowPolicy?
        switch value {
        case .absent: stored = .system
        case let .text(raw): stored = raw.utf8.count <= 32 ? StartupWindowPolicy(rawValue: raw) : nil
        case .unsupported: stored = nil
        }
        selection = stored ?? .system; hasUnknownValue = stored == nil
        launchPolicy = (launchOverride ?? stored ?? .system).effective(supportsSelection: supportsSelection)
    }

    func select(_ value: StartupWindowPolicy) {
        guard value == .system || supportsSelection else { return }
        access.write(value.rawValue); selection = value; hasUnknownValue = false
    }
}

extension Scene {
    func startupWindowPolicy(_ policy: StartupWindowPolicy, window: StartupWindowID? = nil) -> some Scene {
        if #available(macOS 15, *) {
            let launch: SceneLaunchBehavior = switch policy.launch(for: window) {
                case .automatic: .automatic
                case .presented: .presented
                case .suppressed: .suppressed
            }
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(
                self.defaultLaunchBehavior(launch).restorationBehavior(policy == .system ? .automatic : .disabled)))
        } else {
            // SceneBuilder has no if/else support. Its public availability
            // builders provide one return type without newer APIs on macOS 14.
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(self))
        }
    }
}
