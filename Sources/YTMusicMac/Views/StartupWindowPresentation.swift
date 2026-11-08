import AppKit
import SwiftUI

struct WindowActionBridge: ViewModifier {
    let coordinator: AppLaunchCoordinator
    var statusLabel = false
    @Environment(\.openWindow) private var openWindow
    @State private var identifier = UUID()
    func body(content: Content) -> some View {
        content.onAppear {
            coordinator.registerPresenter(id: identifier, statusLabel: statusLabel) { openWindow(id: $0.rawValue) }
        }.onDisappear { coordinator.unregisterPresenter(id: identifier) }
    }
}

/// A process-owned recovery window. It contains no account or playback content.
@MainActor final class NativeStartupRecoveryPresenter: NSObject, StartupRecoveryPresenting, NSWindowDelegate {
    private var window: NSWindow?
    private var reset: (() -> Void)?
    private var cancel: (() -> Void)?
    func show(resetAndQuit: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void) {
        self.reset = resetAndQuit; self.cancel = cancel
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 210),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = StartupWindowText.text("Open YT Music for Mac")
        window.isRestorable = false; window.isReleasedWhenClosed = false; window.delegate = self
        let label = NSTextField(wrappingLabelWithString: StartupWindowText.text("The requested window could not be opened. You can use the default window setting next time and quit safely."))
        let reset = NSButton(title: StartupWindowText.text("Use Default Startup and Quit"), target: self, action: #selector(useDefaultStartupAndQuit))
        let cancel = NSButton(title: StartupWindowText.text("Cancel"), target: self, action: #selector(cancelRequest))
        let stack = NSStackView(views: [label, reset, cancel]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20)])
        }
        self.window = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func dismiss() { let old = window; window = nil; reset = nil; cancel = nil; old?.close() }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        window = nil; let callback = cancel; reset = nil; cancel = nil; callback?()
    }
    @objc private func useDefaultStartupAndQuit() { reset?() }
    @objc private func cancelRequest() { cancel?(); dismiss() }
}
