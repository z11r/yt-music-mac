import AppKit
import SwiftUI

enum MiniPlayerWindowLevel {
    static let preferenceKey = "keepsMiniPlayerOnTop"

    static func level(keepsOnTop: Bool) -> NSWindow.Level { keepsOnTop ? .floating : .normal }
}

/// Sets the level of the window that hosts it. SwiftUI's `windowLevel` scene
/// modifier needs macOS 15, so the macOS 14 path sets the level in AppKit.
struct WindowLevelSetter: NSViewRepresentable {
    let level: NSWindow.Level

    func makeNSView(context: Context) -> LevelView { LevelView() }

    func updateNSView(_ view: LevelView, context: Context) { view.level = level }

    final class LevelView: NSView {
        var level: NSWindow.Level = .normal {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window, window.level != level else { return }
            window.level = level
        }
    }
}

/// Settings and menu control for the mini-player's window level.
struct KeepMiniPlayerOnTopToggle: View {
    @AppStorage(MiniPlayerWindowLevel.preferenceKey)
    private var keepsOnTop = false

    init(preferences: UserDefaults = AppIdentity.preferences) {
        _keepsOnTop = AppStorage(wrappedValue: false, MiniPlayerWindowLevel.preferenceKey, store: preferences)
    }

    var body: some View {
        Toggle("Keep Mini Player on Top", isOn: $keepsOnTop)
    }
}
