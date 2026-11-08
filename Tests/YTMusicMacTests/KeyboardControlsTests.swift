import AppKit
import SwiftUI
import Testing
import WebKit
@testable import YTMusicMac

@MainActor
private func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                     context: nil, characters: characters, charactersIgnoringModifiers: characters,
                     isARepeat: false, keyCode: keyCode)!
}

private let rightArrow = KeyInput.character(NSRightArrowFunctionKey)
private let leftArrow = KeyInput.character(NSLeftArrowFunctionKey)
private let upArrow = KeyInput.character(NSUpArrowFunctionKey)
private let downArrow = KeyInput.character(NSDownArrowFunctionKey)

@MainActor
private func testWindow() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
struct KeyboardFocusTests {
    @Test func textInputsClaimEveryPlaybackKey() {
        let editable = NSTextView()
        let search = NSSearchField()
        let field = NSTextField(string: "")
        let web = WKWebView(frame: .zero)
        let inner = NSView()
        web.addSubview(inner)
        for responder: NSResponder in [editable, search, field] {
            #expect(KeyboardFocus(responder) == .textInput)
        }
        #expect(KeyboardFocus(web) == .webContent)
        #expect(KeyboardFocus(inner) == .webContent)
    }

    @Test func selectableTextKeepsSpaceForPlayback() {
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        let label = NSTextField(labelWithString: "Title")
        label.isSelectable = true
        #expect(KeyboardFocus(text) == .selectableText)
        #expect(KeyboardFocus(label) == .selectableText)
        #expect(KeyboardFocus(NSTextField(labelWithString: "Plain")) == .none)
    }

    @Test func focusedControlsClaimSpaceOnly() {
        #expect(KeyboardFocus(NSButton(title: "Play", target: nil, action: nil)) == .control)
        #expect(KeyboardFocus(NSPopUpButton()) == .control)
        #expect(KeyboardFocus(NSSegmentedControl()) == .control)
        #expect(KeyboardFocus(NSSlider()) == .none)
    }

    @Test func otherRespondersLeaveKeysToPlayback() {
        #expect(KeyboardFocus(nil) == .none)
        #expect(KeyboardFocus(NSView()) == .none)
        #expect(KeyboardFocus(testWindow()) == .none)
    }

    @Test func hostingViewsRespectTheirFocusedAccessibilityControl() {
        let hosting = FocusedElementView()
        for role: NSAccessibility.Role in [.button, .checkBox, .radioButton, .popUpButton, .menuButton] {
            hosting.element.setAccessibilityRole(role)
            #expect(KeyboardFocus(hosting) == .control)
        }
        hosting.element.setAccessibilityRole(.textField)
        #expect(KeyboardFocus(hosting) == .textInput)
        hosting.element.setAccessibilityRole(.group)
        #expect(KeyboardFocus(hosting) == .none)
    }

    @Test func sheetsKeepPlaybackKeysForTheirOwnControls() {
        let parent = testWindow(), sheet = testWindow()
        parent.beginSheet(sheet)
        defer { parent.endSheet(sheet) }
        #expect(KeyboardFocus(parent) == .webContent)
        #expect(KeyboardFocus(sheet) == .webContent)
        #expect(KeyboardFocus(sheet.contentView) == .webContent)
    }

    @Test func searchFieldEditorCountsAsTextInput() {
        let window = testWindow()
        let search = NSSearchField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        window.contentView?.addSubview(search)
        #expect(window.makeFirstResponder(search))
        #expect(window.firstResponder is NSText)
        #expect(KeyboardFocus(window.firstResponder) == .textInput)
    }

    @Test func monitorFollowsFirstResponderChanges() {
        let window = testWindow()
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        let button = NSButton(frame: NSRect(x: 10, y: 50, width: 80, height: 24))
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(button)
        let monitor = KeyboardFocusMonitor()
        monitor.follow(window)
        #expect(monitor.focus == .none)
        window.makeFirstResponder(field)
        #expect(monitor.focus == .textInput)
        window.makeFirstResponder(button)
        #expect(monitor.focus == .control)
        window.makeFirstResponder(nil)
        #expect(monitor.focus == .none)
        monitor.follow(nil)
        window.makeFirstResponder(field)
        #expect(monitor.focus == .none)
    }
}

@MainActor
private final class FocusedElementView: NSView {
    // AppKit's Objective-C focus getter is nonisolated; this fixture is only
    // accessed by the main-actor focus tests.
    nonisolated(unsafe) let element = NSAccessibilityElement()
    override var accessibilityFocusedUIElement: Any? { element }
}

@MainActor
struct PlaybackShortcutTests {
    @Test func shortcutsMatchMusicAndKaset() {
        let expected: [PlaybackShortcut: (KeyEquivalent, EventModifiers)] = [
            .playPause: (.space, []), .nextSong: (.rightArrow, .command), .previousSong: (.leftArrow, .command),
            .seekForward: (.rightArrow, [.command, .option]), .seekBackward: (.leftArrow, [.command, .option]),
            .volumeUp: (.upArrow, .command), .volumeDown: (.downArrow, .command),
            .shuffle: ("s", .command), .repeatMode: ("r", .command),
        ]
        for shortcut in PlaybackShortcut.allCases {
            let value = try! #require(expected[shortcut])
            #expect(shortcut.key == value.0)
            #expect(shortcut.modifiers == value.1)
        }
        #expect(NavigationShortcut.allCases.map(\.destination) == [.home, .explore, .library, .likedSongs])
        #expect(NavigationShortcut.allCases.map(\.key) == ["1", "2", "3", "4"])
    }

    @Test func shortcutsLeaveStandardAndExistingKeysAlone() {
        struct Binding: Hashable { let key: Character; let modifiers: EventModifiers.RawValue }
        let reserved: Set<Binding> = Set(["m", "w", "q", "h", ","].map { Binding(key: $0, modifiers: EventModifiers.command.rawValue) })
            .union([Binding(key: "f", modifiers: EventModifiers.command.rawValue),
                    Binding(key: "m", modifiers: EventModifiers([.command, .shift]).rawValue),
                    Binding(key: "u", modifiers: EventModifiers([.command, .shift]).rawValue)])
        let bindings = PlaybackShortcut.allCases.map { Binding(key: $0.key.character, modifiers: $0.modifiers.rawValue) }
            + NavigationShortcut.allCases.map { Binding(key: $0.key.character, modifiers: EventModifiers.command.rawValue) }
        #expect(Set(bindings).count == bindings.count)
        #expect(Set(bindings).isDisjoint(with: reserved))
    }

    @Test func menuShortcutsStepAsideForFocusedViews() {
        for shortcut in PlaybackShortcut.allCases {
            #expect(shortcut.keyboardShortcut(for: .none) == KeyboardShortcut(shortcut.key, modifiers: shortcut.modifiers))
            if shortcut != .shuffle && shortcut != .repeatMode {
                #expect(shortcut.keyboardShortcut(for: .textInput) == nil)
            }
            #expect(shortcut.keyboardShortcut(for: .webContent) == nil)
        }
        #expect(PlaybackShortcut.playPause.keyboardShortcut(for: .control) == nil)
        #expect(PlaybackShortcut.allCases.filter { !$0.isAvailable(for: .control) } == [.playPause])
        #expect(PlaybackShortcut.allCases.filter { $0.isAvailable(for: .selectableText) } == [.playPause, .shuffle, .repeatMode])
    }

    @Test func keyEventsMatchOnlyTheirExactShortcut() {
        #expect(PlaybackShortcut.playPause.matches(try! #require(KeyInput(keyEvent(" ", keyCode: 49)))))
        #expect(PlaybackShortcut.nextSong.matches(KeyInput(characters: rightArrow, modifiers: [.command, .numericPad, .function])))
        #expect(PlaybackShortcut.previousSong.matches(KeyInput(characters: leftArrow, modifiers: .command)))
        #expect(PlaybackShortcut.volumeUp.matches(KeyInput(characters: upArrow, modifiers: .command)))
        #expect(PlaybackShortcut.volumeDown.matches(KeyInput(characters: downArrow, modifiers: .command)))
        #expect(PlaybackShortcut.seekForward.matches(KeyInput(characters: rightArrow, modifiers: [.command, .option])))
        #expect(PlaybackShortcut.seekBackward.matches(KeyInput(characters: leftArrow, modifiers: [.command, .option])))
        #expect(!PlaybackShortcut.nextSong.matches(KeyInput(characters: rightArrow, modifiers: [.command, .option])))
        // Shift-Command-Right selects to the end of a line; Right alone moves the cursor.
        #expect(!PlaybackShortcut.nextSong.matches(KeyInput(characters: rightArrow, modifiers: [.command, .shift])))
        #expect(!PlaybackShortcut.nextSong.matches(KeyInput(characters: rightArrow, modifiers: [])))
        #expect(!PlaybackShortcut.playPause.matches(KeyInput(characters: " ", modifiers: .option)))
        #expect(!PlaybackShortcut.nextSong.matches(KeyInput(characters: leftArrow, modifiers: .command)))
    }

    @Test func onlyKeyDownEventsBecomeKeyInput() {
        #expect(KeyInput(nil) == nil)
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        #expect(KeyInput(click) == nil)
        #expect(KeyInput(keyEvent("a", modifiers: [.command, .capsLock]))?.modifiers == .command)
    }

    @Test func typingInTextFieldsNeverRunsPlayback() {
        let space = KeyInput(characters: " ", modifiers: [])
        let next = KeyInput(characters: rightArrow, modifiers: .command)
        #expect(ShortcutRoute.route(.playPause, input: space, focus: .textInput) == .returnKeyToFocusedView)
        #expect(ShortcutRoute.route(.nextSong, input: next, focus: .textInput) == .returnKeyToFocusedView)
        #expect(ShortcutRoute.route(.playPause, input: space, focus: .control) == .returnKeyToFocusedView)
        #expect(ShortcutRoute.route(.nextSong, input: next, focus: .control) == .perform)
        #expect(ShortcutRoute.route(.playPause, input: space, focus: .none) == .perform)
        #expect(ShortcutRoute.route(.playPause, input: space, focus: .selectableText) == .perform)
    }

    @Test func menuClicksRunWhateverHasFocus() {
        // A click, VoiceOver, or another key press that opened the menu item.
        #expect(ShortcutRoute.route(.playPause, input: nil, focus: .textInput) == .perform)
        let other = KeyInput(characters: "p", modifiers: .command)
        #expect(ShortcutRoute.route(.nextSong, input: other, focus: .textInput) == .perform)
    }

    @Test func returnedKeysEditTheFocusedText() {
        let window = testWindow()
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        window.contentView?.addSubview(text)
        window.makeFirstResponder(text)
        text.string = "ab"
        text.setSelectedRange(NSRange(location: 1, length: 0))
        text.keyDown(with: keyEvent(" ", keyCode: 49))
        #expect(text.string == "a b")
    }
}

@MainActor
struct PlaybackControlActionTests {
    @Test func seekStepsClampAndDoNotStartPlayback() async {
        let preferences = SceneCheckPreferences()
        defer { preferences.remove() }
        let transport = SceneCheckTransport()
        let session = AppSession(configuration: .sceneCheck(preferences: preferences.defaults, transport: transport))
        await session.start()
        #expect(session.advanceSceneCheck(to: 1))
        #expect(!session.canSeek)
        session.seekBy(10)
        #expect(session.player.clock.position == 0)
        session.player.clock.update(position: 95, duration: 100)
        #expect(session.canSeek)
        session.seekBy(10)
        #expect(session.player.clock.position == 100)
        session.seekBy(-10)
        #expect(session.player.clock.position == 90)
        session.seekBy(-200)
        #expect(session.player.clock.position == 0)
        session.seekBy(.nan)
        #expect(session.player.clock.position == 0)
        #expect(!session.player.isPlaying)
        #expect(await transport.attempts == 0)
    }

    @Test func volumeCommandsUseIsolatedPreferencesAndMuteRestoresVolume() async {
        let preferences = SceneCheckPreferences()
        defer { preferences.remove() }
        let transport = SceneCheckTransport()
        let session = AppSession(configuration: .sceneCheck(preferences: preferences.defaults, transport: transport))
        await session.start()
        session.setVolume(0.7)
        session.increaseVolume()
        #expect(session.player.volume == 0.8)
        session.decreaseVolume()
        #expect(session.player.volume == 0.7)
        session.toggleMute()
        #expect(session.player.volume == 0)
        session.toggleMute()
        #expect(session.player.volume == 0.7)
        #expect(preferences.defaults.double(forKey: "volume") == 0.7)
        #expect(await transport.attempts == 0)
    }
}

struct VolumeStepTests {
    @Test func stepsByTenPercentWithinBounds() {
        #expect(VolumeStep.adjusted(0.7, by: 1) == 0.8)
        #expect(VolumeStep.adjusted(0.73, by: -1) == 0.63)
        #expect(VolumeStep.adjusted(0.95, by: 1) == 1)
        #expect(VolumeStep.adjusted(1, by: 1) == 1)
        #expect(VolumeStep.adjusted(0.04, by: -1) == 0)
        #expect(VolumeStep.adjusted(0, by: 1) == 0.1)
        #expect(VolumeStep.adjusted(.nan, by: 1) == 0)
        var volume = 0.0
        for _ in 0..<7 { volume = VolumeStep.adjusted(volume, by: 1) }
        #expect(volume == 0.7)
    }
}
