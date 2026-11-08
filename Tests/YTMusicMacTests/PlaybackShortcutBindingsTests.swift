import AppKit
import SwiftUI
import Testing
@testable import YTMusicMac

@MainActor @Suite("Configurable playback shortcuts")
struct PlaybackShortcutBindingsTests {
    @Test func customBindingsAndDisabledActionsSurviveAnIsolatedRelaunch() throws {
        let fixture = BindingPreferences()
        defer { fixture.remove() }
        let first = PlaybackShortcutBindings(preferences: fixture.defaults)
        let custom = PlaybackKeyBinding(key: "k", modifiers: [.command, .option])
        try first.assign(custom, to: .playPause)
        try first.assign(nil, to: .shuffle)
        let restored = PlaybackShortcutBindings(preferences: fixture.defaults)
        #expect(restored.binding(for: .playPause) == custom)
        #expect(restored.binding(for: .shuffle) == nil)
        #expect(restored.binding(for: .seekForward) == PlaybackShortcut.seekForward.defaultBinding)
        #expect(restored.loadMessage == nil)
    }

    @Test func duplicateDefaultBindingReportsItsOwnerWithoutSaving() throws {
        let fixture = BindingPreferences()
        defer { fixture.remove() }
        let settings = PlaybackShortcutBindings(preferences: fixture.defaults)
        let custom = PlaybackKeyBinding(key: "k", modifiers: [.command, .option])
        try settings.assign(custom, to: .playPause)
        let previous = fixture.defaults.data(forKey: PlaybackShortcutBindings.preferenceKey)
        #expect(throws: PlaybackBindingError.conflict(.nextSong)) {
            try settings.assign(PlaybackShortcut.nextSong.defaultBinding, to: .playPause)
        }
        #expect(settings.binding(for: .playPause) == custom)
        #expect(fixture.defaults.data(forKey: PlaybackShortcutBindings.preferenceKey) == previous)
    }

    @Test func disablingAConflictingActionAllowsReassignmentAndResetRemainsAtomic() throws {
        let fixture = BindingPreferences()
        defer { fixture.remove() }
        let settings = PlaybackShortcutBindings(preferences: fixture.defaults)
        try settings.assign(nil, to: .nextSong)
        try settings.assign(PlaybackShortcut.nextSong.defaultBinding, to: .playPause)
        let previous = fixture.defaults.data(forKey: PlaybackShortcutBindings.preferenceKey)
        #expect(throws: PlaybackBindingError.conflict(.playPause)) { try settings.reset(.nextSong) }
        #expect(settings.binding(for: .nextSong) == nil)
        #expect(fixture.defaults.data(forKey: PlaybackShortcutBindings.preferenceKey) == previous)
        settings.resetAll()
        #expect(settings.binding(for: .playPause) == PlaybackShortcut.playPause.defaultBinding)
        #expect(settings.binding(for: .nextSong) == PlaybackShortcut.nextSong.defaultBinding)
    }

    @Test func resetDoesNotTouchOtherPreferencesOrAnotherStore() throws {
        let first = BindingPreferences(), second = BindingPreferences()
        defer { first.remove(); second.remove() }
        first.defaults.set("kept", forKey: "unrelated")
        let bindings = PlaybackShortcutBindings(preferences: first.defaults)
        let independent = PlaybackShortcutBindings(preferences: second.defaults)
        try bindings.assign(PlaybackKeyBinding(key: "k", modifiers: [.command, .option]), to: .playPause)
        try bindings.assign(nil, to: .repeatMode)
        try bindings.reset(.repeatMode)
        #expect(bindings.isDefault(.repeatMode))
        #expect(!bindings.isDefault(.playPause))
        #expect(independent.isDefault(.playPause))
        bindings.resetAll()
        #expect(first.defaults.data(forKey: PlaybackShortcutBindings.preferenceKey) == nil)
        #expect(first.defaults.string(forKey: "unrelated") == "kept")
        #expect(second.defaults.data(forKey: PlaybackShortcutBindings.preferenceKey) == nil)
    }

    @Test func malformedAndFuturePreferencesUseDefaultsWithoutDestroyingSavedData() {
        let fixture = BindingPreferences()
        defer { fixture.remove() }
        let samples = [Data("not-json".utf8), Data(#"{"version":99,"overrides":{}}"#.utf8), Data(repeating: 0, count: 32_769)]
        for data in samples {
            fixture.defaults.set(data, forKey: PlaybackShortcutBindings.preferenceKey)
            let bindings = PlaybackShortcutBindings(preferences: fixture.defaults)
            #expect(bindings.loadMessage != nil)
            #expect(bindings.binding(for: .nextSong) == PlaybackShortcut.nextSong.defaultBinding)
            #expect(fixture.defaults.data(forKey: PlaybackShortcutBindings.preferenceKey) == data)
        }
    }

    @Test func unsupportedSavedActionsAreRetainedUntilExplicitReset() {
        let fixture = BindingPreferences()
        defer { fixture.remove() }
        let data = Data(#"{"version":1,"overrides":{"futureAction":{"disabled":{}}}}"#.utf8)
        fixture.defaults.set(data, forKey: PlaybackShortcutBindings.preferenceKey)
        let bindings = PlaybackShortcutBindings(preferences: fixture.defaults)
        #expect(bindings.loadMessage != nil)
        #expect(fixture.defaults.data(forKey: PlaybackShortcutBindings.preferenceKey) == data)
        bindings.resetAll()
        #expect(bindings.loadMessage == nil)
        #expect(fixture.defaults.data(forKey: PlaybackShortcutBindings.preferenceKey) == nil)
    }

    @Test func conflictingSavedOverridesNeverBecomeActive() throws {
        let fixture = BindingPreferences()
        defer { fixture.remove() }
        let settings = PlaybackShortcutBindings(preferences: fixture.defaults)
        try settings.assign(PlaybackKeyBinding(key: "k", modifiers: [.command, .option]), to: .playPause)
        let saved = try #require(fixture.defaults.data(forKey: PlaybackShortcutBindings.preferenceKey))
        var object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        var overrides = try #require(object["overrides"] as? [String: Any])
        overrides["nextSong"] = overrides["playPause"]
        object["overrides"] = overrides
        let conflicting = try JSONSerialization.data(withJSONObject: object)
        fixture.defaults.set(conflicting, forKey: PlaybackShortcutBindings.preferenceKey)
        let restored = PlaybackShortcutBindings(preferences: fixture.defaults)
        #expect(restored.loadMessage != nil)
        #expect(restored.binding(for: .playPause) == PlaybackShortcut.playPause.defaultBinding)
        #expect(fixture.defaults.data(forKey: PlaybackShortcutBindings.preferenceKey) == conflicting)
    }

    @Test func standardTextWindowNavigationAndAccessibilityKeysStayReserved() {
        let commandKeys = ["a", "c", "v", "x", "z", "f", "o", "q", "w", "m", "h", "0", "1", "4", "9"]
        for key in commandKeys {
            #expect(throws: PlaybackBindingError.reserved) {
                try PlaybackBindingRules.validate(PlaybackKeyBinding(key: key, modifiers: .command), for: .playPause)
            }
        }
        let reserved = [
            PlaybackKeyBinding(key: "m", modifiers: [.command, .shift]),
            PlaybackKeyBinding(key: "u", modifiers: [.command, .shift]),
            PlaybackKeyBinding(key: "z", modifiers: [.command, .shift]),
            PlaybackKeyBinding(key: "f", modifiers: [.command, .control]),
            PlaybackKeyBinding(key: "s", modifiers: [.command, .control]),
            PlaybackKeyBinding(key: "space", modifiers: .command),
            PlaybackKeyBinding(key: "space", modifiers: .control),
            PlaybackKeyBinding(key: "left", modifiers: .control),
            PlaybackKeyBinding(key: "k", modifiers: [.control, .option]),
            PlaybackKeyBinding(key: "a", modifiers: .control)
        ]
        for binding in reserved {
            #expect(throws: PlaybackBindingError.reserved) { try PlaybackBindingRules.validate(binding, for: .playPause) }
        }
    }

    @Test func unmodifiedTypingAndUnsupportedKeysCannotBecomeCustomBindings() {
        for binding in [PlaybackKeyBinding(key: "a", modifiers: []), PlaybackKeyBinding(key: "left", modifiers: .option)] {
            #expect(throws: PlaybackBindingError.modifierRequired) { try PlaybackBindingRules.validate(binding, for: .nextSong) }
        }
        for binding in [PlaybackKeyBinding(key: "escape", modifiers: .command),
                        PlaybackKeyBinding(key: "é", modifiers: .command),
                        PlaybackKeyBinding(key: "k", modifiers: PlaybackBindingModifiers(rawValue: 128))] {
            #expect(throws: PlaybackBindingError.unsupportedKey) { try PlaybackBindingRules.validate(binding, for: .playPause) }
        }
    }

    @Test func everyPlaybackBindingStepsAsideForTypingSearchWebContentAndSheets() {
        let custom = PlaybackKeyBinding(key: "k", modifiers: [.command, .option])
        for binding in PlaybackShortcut.allCases.map(\.defaultBinding) + [custom] {
            for focus in [KeyboardFocus.textInput, .webContent] {
                let input = KeyInput(characters: String(binding.keyEquivalent.character), modifiers: binding.modifiers.appKitModifiers)
                #expect(binding.keyboardShortcut(for: focus) == nil)
                #expect(ShortcutRoute.route(binding: binding, input: input, focus: focus) == .returnKeyToFocusedView)
            }
        }
    }

    @Test func customRoutingUsesTheAssignedCombinationAndPreservesMenuClicks() {
        let binding = PlaybackKeyBinding(key: "j", modifiers: [.command, .shift])
        let input = KeyInput(characters: "J", modifiers: [.command, .shift, .capsLock])
        #expect(binding.matches(input))
        #expect(!binding.matches(KeyInput(characters: "j", modifiers: .command)))
        #expect(!binding.matches(KeyInput(characters: " ", modifiers: [])))
        #expect(ShortcutRoute.route(binding: binding, input: input, focus: .none) == .perform)
        #expect(ShortcutRoute.route(binding: binding, input: input, focus: .textInput) == .returnKeyToFocusedView)
        #expect(ShortcutRoute.route(binding: binding, input: nil, focus: .textInput) == .perform)
        #expect(ShortcutRoute.route(binding: nil, input: nil, focus: .webContent) == .perform)
        #expect(PlaybackShortcut.playPause.defaultBinding.keyboardShortcut(for: .control) == nil)
        #expect(PlaybackShortcut.nextSong.defaultBinding.keyboardShortcut(for: .selectableText) == nil)
    }

    @Test func selectingTheDefaultClearsOnlyThatOverride() throws {
        let fixture = BindingPreferences()
        defer { fixture.remove() }
        let bindings = PlaybackShortcutBindings(preferences: fixture.defaults)
        try bindings.assign(PlaybackKeyBinding(key: "k", modifiers: [.command, .option]), to: .playPause)
        try bindings.assign(nil, to: .shuffle)
        try bindings.assign(PlaybackShortcut.playPause.defaultBinding, to: .playPause)
        #expect(bindings.isDefault(.playPause))
        #expect(bindings.binding(for: .shuffle) == nil)
    }

    @Test func sheetProtectionUsesTheWindowEvenForAResponderWithoutAView() {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        sheet.isReleasedWhenClosed = false
        let responder = ShortcutProxyResponder()
        parent.beginSheet(sheet)
        defer { parent.endSheet(sheet) }
        #expect(sheet.makeFirstResponder(responder))
        let monitor = KeyboardFocusMonitor()
        monitor.follow(sheet)
        #expect(monitor.focus == .webContent)
        for action in PlaybackShortcut.allCases { #expect(action.defaultBinding.keyboardShortcut(for: monitor.focus) == nil) }
    }
}

@MainActor
private final class ShortcutProxyResponder: NSResponder {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private struct BindingPreferences {
    let name: String
    let defaults: UserDefaults
    init() {
        name = "io.github.z11r.ytmusicmac.tests.bindings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
    }
    func remove() { defaults.removePersistentDomain(forName: name) }
}
