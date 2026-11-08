import AppKit
import Foundation
import Observation
import SwiftUI

struct PlaybackBindingModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8
    static let command = Self(rawValue: 1)
    static let option = Self(rawValue: 2)
    static let control = Self(rawValue: 4)
    static let shift = Self(rawValue: 8)
    static let all: Self = [.command, .option, .control, .shift]

    var eventModifiers: EventModifiers {
        var value: EventModifiers = []
        if contains(.command) { value.insert(.command) }
        if contains(.option) { value.insert(.option) }
        if contains(.control) { value.insert(.control) }
        if contains(.shift) { value.insert(.shift) }
        return value
    }

    var appKitModifiers: NSEvent.ModifierFlags {
        var value: NSEvent.ModifierFlags = []
        if contains(.command) { value.insert(.command) }
        if contains(.option) { value.insert(.option) }
        if contains(.control) { value.insert(.control) }
        if contains(.shift) { value.insert(.shift) }
        return value
    }
}

/// Logical keys, matching native menu equivalents rather than physical key codes.
struct PlaybackKeyBinding: Codable, Hashable, Sendable {
    let key: String
    let modifiers: PlaybackBindingModifiers
    static let letterKeys = Array("abcdefghijklmnopqrstuvwxyz0123456789").map(String.init)
    static let specialKeys = ["space", "left", "right", "up", "down"]
    static let supportedKeys = letterKeys + specialKeys

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "space": .space
        case "left": .leftArrow
        case "right": .rightArrow
        case "up": .upArrow
        case "down": .downArrow
        default: KeyEquivalent(key.first ?? " ")
        }
    }

    var keyTitle: String {
        switch key {
        case "space": "Space"
        case "left": "Left Arrow"
        case "right": "Right Arrow"
        case "up": "Up Arrow"
        case "down": "Down Arrow"
        default: key.uppercased()
        }
    }

    var displayText: String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "⌃" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }
        let glyph: String = switch key {
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        default: keyTitle
        }
        return prefix + glyph
    }

    var accessibilityText: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Command") }
        return (parts + [keyTitle]).joined(separator: ", ")
    }

    var isArrow: Bool { ["left", "right", "up", "down"].contains(key) }

    func isAvailable(for focus: KeyboardFocus) -> Bool {
        // Editable text, web pages, and sheets keep all playback bindings.
        if focus.usesSpace && focus.usesCommandArrows && focus.usesCommandLetters { return false }
        if key == "space" { return !focus.usesSpace }
        if isArrow { return !focus.usesCommandArrows }
        return !focus.usesCommandLetters
    }

    func keyboardShortcut(for focus: KeyboardFocus) -> KeyboardShortcut? {
        isAvailable(for: focus) ? KeyboardShortcut(keyEquivalent, modifiers: modifiers.eventModifiers) : nil
    }

    func matches(_ input: KeyInput) -> Bool {
        input.characters.lowercased() == String(keyEquivalent.character).lowercased() && input.modifiers == modifiers.appKitModifiers
    }
}

extension PlaybackShortcut {
    var title: String {
        switch self {
        case .playPause: "Play/Pause"
        case .nextSong: "Next Song"
        case .previousSong: "Previous Song"
        case .seekForward: "Skip Forward 10 Seconds"
        case .seekBackward: "Skip Backward 10 Seconds"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .shuffle: "Shuffle"
        case .repeatMode: "Repeat"
        }
    }

    var defaultBinding: PlaybackKeyBinding {
        switch self {
        case .playPause: PlaybackKeyBinding(key: "space", modifiers: [])
        case .nextSong: PlaybackKeyBinding(key: "right", modifiers: .command)
        case .previousSong: PlaybackKeyBinding(key: "left", modifiers: .command)
        case .seekForward: PlaybackKeyBinding(key: "right", modifiers: [.command, .option])
        case .seekBackward: PlaybackKeyBinding(key: "left", modifiers: [.command, .option])
        case .volumeUp: PlaybackKeyBinding(key: "up", modifiers: .command)
        case .volumeDown: PlaybackKeyBinding(key: "down", modifiers: .command)
        case .shuffle: PlaybackKeyBinding(key: "s", modifiers: .command)
        case .repeatMode: PlaybackKeyBinding(key: "r", modifiers: .command)
        }
    }
}

enum PlaybackBindingError: Error, Equatable, LocalizedError {
    case unsupportedKey, modifierRequired, reserved, conflict(PlaybackShortcut)

    var errorDescription: String? {
        switch self {
        case .unsupportedKey: "Choose a letter, number, arrow key, or Space."
        case .modifierRequired: "Custom shortcuts need Command or Control. Space remains available for Play/Pause."
        case .reserved: "This combination is reserved for a standard Mac or app command. Choose another shortcut."
        case let .conflict(action): "This shortcut is already assigned to \(action.title). Change or disable that binding first."
        }
    }
}

enum PlaybackBindingRules {
    static func validate(_ binding: PlaybackKeyBinding, for action: PlaybackShortcut) throws {
        guard PlaybackKeyBinding.supportedKeys.contains(binding.key),
              binding.modifiers.subtracting(.all).isEmpty else { throw PlaybackBindingError.unsupportedKey }
        // Retain the app's established defaults, including Command-S/Command-R.
        if binding == action.defaultBinding { return }
        guard binding.modifiers.contains(.command) || binding.modifiers.contains(.control) else {
            throw PlaybackBindingError.modifierRequired
        }
        let flags = binding.modifiers
        if binding.key == "space" || (binding.isArrow && flags.contains(.control)) ||
            flags.isSuperset(of: [.control, .option]) { throw PlaybackBindingError.reserved }
        if flags == .command, PlaybackKeyBinding.letterKeys.contains(binding.key) { throw PlaybackBindingError.reserved }
        if flags == .control || flags == [.control, .shift] { throw PlaybackBindingError.reserved }
        if flags == [.command, .shift], ["a", "c", "g", "h", "m", "n", "o", "p", "q", "s", "t", "u", "v", "w", "z"].contains(binding.key) {
            throw PlaybackBindingError.reserved
        }
        if flags == [.command, .option], ["f", "h", "m", "q", "w"].contains(binding.key) { throw PlaybackBindingError.reserved }
        if flags == [.command, .option, .shift], ["m", "q", "v", "w"].contains(binding.key) { throw PlaybackBindingError.reserved }
        if flags == [.command, .control], ["d", "f", "q", "s"].contains(binding.key) { throw PlaybackBindingError.reserved }
        if flags == [.command, .control, .shift], binding.key == "q" { throw PlaybackBindingError.reserved }
    }
}

/// Local preferences only. An invalid or newer saved envelope is retained until
/// the user explicitly saves or resets; it never changes account preferences.
@MainActor @Observable
final class PlaybackShortcutBindings {
    static let preferenceKey = "playbackShortcutBindings.v1"
    private enum Setting: Codable, Equatable { case disabled, custom(PlaybackKeyBinding) }
    private struct Saved: Codable { let version: Int; let overrides: [String: Setting] }
    @ObservationIgnored private let preferences: UserDefaults
    private var overrides: [PlaybackShortcut: Setting] = [:]
    private(set) var loadMessage: String?

    init(preferences: UserDefaults) {
        self.preferences = preferences
        guard let data = preferences.data(forKey: Self.preferenceKey) else { return }
        do {
            guard data.count <= 32_768 else { throw PlaybackBindingError.unsupportedKey }
            let saved = try JSONDecoder().decode(Saved.self, from: data)
            guard saved.version == 1 else { throw PlaybackBindingError.unsupportedKey }
            var decoded: [PlaybackShortcut: Setting] = [:]
            for (name, setting) in saved.overrides {
                guard let action = PlaybackShortcut(rawValue: name) else { throw PlaybackBindingError.unsupportedKey }
                decoded[action] = setting
            }
            try validate(decoded)
            overrides = decoded
        } catch {
            loadMessage = "Saved shortcuts could not be read. Defaults are active. Reset or save new bindings to replace them."
        }
    }

    func binding(for action: PlaybackShortcut) -> PlaybackKeyBinding? {
        binding(for: action, overrides: overrides)
    }

    func isDefault(_ action: PlaybackShortcut) -> Bool { overrides[action] == nil }

    func assign(_ binding: PlaybackKeyBinding?, to action: PlaybackShortcut) throws {
        var updated = overrides
        if binding == action.defaultBinding { updated.removeValue(forKey: action) }
        else { updated[action] = binding.map(Setting.custom) ?? .disabled }
        try save(updated, changed: action)
    }

    func reset(_ action: PlaybackShortcut) throws {
        var updated = overrides
        updated.removeValue(forKey: action)
        try save(updated, changed: action)
    }

    func resetAll() {
        preferences.removeObject(forKey: Self.preferenceKey)
        overrides = [:]
        loadMessage = nil
    }

    private func save(_ updated: [PlaybackShortcut: Setting], changed action: PlaybackShortcut) throws {
        if let candidate = binding(for: action, overrides: updated) {
            try PlaybackBindingRules.validate(candidate, for: action)
            for other in PlaybackShortcut.allCases where other != action {
                if candidate == binding(for: other, overrides: updated) { throw PlaybackBindingError.conflict(other) }
            }
        }
        try validate(updated)
        let saved = Saved(version: 1, overrides: Dictionary(uniqueKeysWithValues: updated.map { ($0.key.rawValue, $0.value) }))
        let data = try JSONEncoder().encode(saved)
        preferences.set(data, forKey: Self.preferenceKey)
        overrides = updated
        loadMessage = nil
    }

    private func validate(_ values: [PlaybackShortcut: Setting]) throws {
        var owners: [PlaybackKeyBinding: PlaybackShortcut] = [:]
        for action in PlaybackShortcut.allCases {
            guard let binding = binding(for: action, overrides: values) else { continue }
            try PlaybackBindingRules.validate(binding, for: action)
            if let other = owners[binding] { throw PlaybackBindingError.conflict(other) }
            owners[binding] = action
        }
    }

    private func binding(for action: PlaybackShortcut, overrides: [PlaybackShortcut: Setting]) -> PlaybackKeyBinding? {
        switch overrides[action] {
        case .disabled: nil
        case let .custom(binding): binding
        case nil: action.defaultBinding
        }
    }
}
