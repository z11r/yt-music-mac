import AppKit
import Observation
import SwiftUI
import WebKit

/// Playback commands bound to keys that text editing and focused controls also use.
enum PlaybackShortcut: CaseIterable, Sendable {
    case playPause, nextSong, previousSong, volumeUp, volumeDown

    var key: KeyEquivalent {
        switch self {
        case .playPause: .space
        case .nextSong: .rightArrow
        case .previousSong: .leftArrow
        case .volumeUp: .upArrow
        case .volumeDown: .downArrow
        }
    }

    var modifiers: EventModifiers { self == .playPause ? [] : .command }

    /// The shortcut a menu item shows and responds to, or nil while the
    /// focused view needs the key for itself.
    func keyboardShortcut(for focus: KeyboardFocus) -> KeyboardShortcut? {
        isAvailable(for: focus) ? KeyboardShortcut(key, modifiers: modifiers) : nil
    }

    func isAvailable(for focus: KeyboardFocus) -> Bool {
        self == .playPause ? !focus.usesSpace : !focus.usesCommandArrows
    }

    /// Whether a key press is this shortcut. A menu click or an accessibility
    /// action has no matching key press.
    func matches(_ input: KeyInput) -> Bool {
        let expected: (String, NSEvent.ModifierFlags) = switch self {
        case .playPause: (" ", [])
        case .nextSong: (KeyInput.character(NSRightArrowFunctionKey), .command)
        case .previousSong: (KeyInput.character(NSLeftArrowFunctionKey), .command)
        case .volumeUp: (KeyInput.character(NSUpArrowFunctionKey), .command)
        case .volumeDown: (KeyInput.character(NSDownArrowFunctionKey), .command)
        }
        return input.characters == expected.0 && input.modifiers == expected.1
    }
}

/// The parts of a key-down event that identify a shortcut.
struct KeyInput: Equatable, Sendable {
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    let characters: String
    let modifiers: NSEvent.ModifierFlags

    init(characters: String, modifiers: NSEvent.ModifierFlags) {
        self.characters = characters
        self.modifiers = modifiers.intersection(Self.relevantModifiers)
    }

    init?(_ event: NSEvent?) {
        guard let event, event.type == .keyDown, let characters = event.charactersIgnoringModifiers else { return nil }
        self.init(characters: characters, modifiers: event.modifierFlags)
    }

    static func character(_ value: Int) -> String {
        UnicodeScalar(value).map { String(Character($0)) } ?? ""
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.characters == rhs.characters && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }
}

/// Which playback keys the focused view uses itself.
struct KeyboardFocus: Equatable, Sendable {
    /// Typing a space, or activating a focused button or segmented control.
    var usesSpace = false
    /// Moving the insertion point or selection with Command and an arrow key.
    var usesCommandArrows = false

    static let none = KeyboardFocus()
    static let textInput = KeyboardFocus(usesSpace: true, usesCommandArrows: true)
    static let control = KeyboardFocus(usesSpace: true, usesCommandArrows: false)
    static let selectableText = KeyboardFocus(usesSpace: false, usesCommandArrows: true)

    @MainActor
    init(_ responder: NSResponder?) {
        self = Self.classify(responder)
    }

    init(usesSpace: Bool = false, usesCommandArrows: Bool = false) {
        self.usesSpace = usesSpace
        self.usesCommandArrows = usesCommandArrows
    }

    @MainActor
    private static func classify(_ responder: NSResponder?) -> KeyboardFocus {
        guard let responder else { return .none }
        // Field editors and text views, including the search field's editor.
        if let text = responder as? NSText { return text.isEditable ? .textInput : .selectableText }
        if let field = responder as? NSTextField {
            if field.isEditable { return .textInput }
            return field.isSelectable ? .selectableText : .none
        }
        if let view = responder as? NSView {
            // Web content may have its own text fields, such as the sign-in page.
            if view is WKWebView || view.enclosingWebView != nil { return .textInput }
            // Keyboard navigation activates these controls with Space.
            if view is NSButton || view is NSSegmentedControl { return .control }
        }
        if responder is NSTextInputClient { return .textInput }
        return .none
    }
}

private extension NSView {
    var enclosingWebView: WKWebView? {
        var view = superview
        while let current = view {
            if let web = current as? WKWebView { return web }
            view = current.superview
        }
        return nil
    }
}

/// What a playback menu command does when it runs.
enum ShortcutRoute: Equatable, Sendable {
    /// Run the playback action.
    case perform
    /// The key belongs to the focused view; hand it back and skip playback.
    case returnKeyToFocusedView

    /// A menu click always runs the action. A key press runs it only when the
    /// focused view does not use that key. The menu normally drops the shortcut
    /// before this happens; this catches a focus change it has not shown yet.
    static func route(_ shortcut: PlaybackShortcut, input: KeyInput?, focus: KeyboardFocus) -> Self {
        guard let input, shortcut.matches(input) else { return .perform }
        return shortcut.isAvailable(for: focus) ? .perform : .returnKeyToFocusedView
    }
}

/// Follows the key window's first responder so playback shortcuts step aside
/// for text fields and focused controls.
@MainActor @Observable
final class KeyboardFocusMonitor {
    private(set) var focus = KeyboardFocus.none

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var responderObservation: NSKeyValueObservation?
    @ObservationIgnored private weak var observedWindow: NSWindow?

    func start() {
        guard observers.isEmpty else { return }
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.followKeyWindow() }
            })
        }
        followKeyWindow()
    }

    /// The focus at this moment, read directly from the key window.
    var currentFocus: KeyboardFocus { KeyboardFocus(NSApplication.shared.keyWindow?.firstResponder) }

    /// Runs a playback command from the menu, unless its key press belongs to
    /// the focused view.
    func run(_ shortcut: PlaybackShortcut, action: () -> Void) {
        let event = NSApplication.shared.currentEvent
        switch ShortcutRoute.route(shortcut, input: KeyInput(event), focus: currentFocus) {
        case .perform:
            action()
        case .returnKeyToFocusedView:
            // Text views take the key directly: Space types and Command-arrow
            // moves the insertion point. Other views keep their focus untouched.
            if let event, let text = NSApplication.shared.keyWindow?.firstResponder as? NSText {
                text.keyDown(with: event)
            }
            followKeyWindow()
        }
    }

    private func followKeyWindow() { follow(NSApplication.shared.keyWindow) }

    /// Tracks the first responder of `window`, the key window in the app.
    func follow(_ window: NSWindow?) {
        if window !== observedWindow {
            responderObservation?.invalidate()
            // `firstResponder` is KVO compliant (NSWindow.h).
            responderObservation = window?.observe(\.firstResponder) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.update() }
            }
            observedWindow = window
        }
        update()
    }

    private func update() {
        let value = KeyboardFocus(observedWindow?.firstResponder)
        if value != focus { focus = value }
    }
}
