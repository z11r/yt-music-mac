import AppKit
import AVKit
import MusicCore
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
        for responder: NSResponder in [editable, search, field, web, inner] {
            #expect(KeyboardFocus(responder) == .textInput)
        }
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
struct PlaybackShortcutTests {
    @Test func shortcutsMatchMusicAndKaset() {
        let expected: [PlaybackShortcut: (KeyEquivalent, EventModifiers)] = [
            .playPause: (.space, []), .nextSong: (.rightArrow, .command), .previousSong: (.leftArrow, .command),
            .volumeUp: (.upArrow, .command), .volumeDown: (.downArrow, .command),
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
            #expect(shortcut.keyboardShortcut(for: .textInput) == nil)
        }
        #expect(PlaybackShortcut.playPause.keyboardShortcut(for: .control) == nil)
        #expect(PlaybackShortcut.allCases.filter { $0.isAvailable(for: .control) } == [.nextSong, .previousSong, .volumeUp, .volumeDown])
        #expect(PlaybackShortcut.allCases.filter { $0.isAvailable(for: .selectableText) } == [.playPause])
    }

    @Test func keyEventsMatchOnlyTheirExactShortcut() {
        #expect(PlaybackShortcut.playPause.matches(try! #require(KeyInput(keyEvent(" ", keyCode: 49)))))
        #expect(PlaybackShortcut.nextSong.matches(KeyInput(characters: rightArrow, modifiers: [.command, .numericPad, .function])))
        #expect(PlaybackShortcut.previousSong.matches(KeyInput(characters: leftArrow, modifiers: .command)))
        #expect(PlaybackShortcut.volumeUp.matches(KeyInput(characters: upArrow, modifiers: .command)))
        #expect(PlaybackShortcut.volumeDown.matches(KeyInput(characters: downArrow, modifiers: .command)))
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

private func track(_ id: String) -> Track {
    Track(id: id, title: "Song \(id)", artist: "Artist \(id)", album: "Album \(id)")
}

private func occurrence(_ entry: UUID, _ trackID: String = "a", generation: UInt64 = 1) -> PlaybackOccurrence {
    PlaybackOccurrence(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, entryID: entry,
                       trackID: trackID, generation: generation)
}

private func playing(_ entry: UUID, _ trackID: String = "a", generation: UInt64 = 1, confirmed: Bool = true) -> SongPlaybackState {
    SongPlaybackState(selectedEntryID: entry, occurrence: occurrence(entry, trackID, generation: generation),
                      isConfirmedPlaying: confirmed, track: track(trackID))
}

struct SongChangeTrackerTests {
    @Test func restoredSongIsNotAChange() {
        let restored = UUID()
        var tracker = SongChangeTracker()
        #expect(tracker.update(SongPlaybackState(selectedEntryID: restored, track: track("a"))) == nil)
        #expect(tracker.update(playing(restored, generation: 1)) == nil)
    }

    @Test func confirmedNewEntryIsAnnouncedOnce() {
        let first = UUID(), second = UUID()
        var tracker = SongChangeTracker()
        #expect(tracker.update(playing(first)) == first)
        #expect(tracker.update(playing(first)) == nil)
        #expect(tracker.update(playing(second, "b", confirmed: false)) == nil)
        #expect(tracker.update(playing(second, "b")) == second)
    }

    @Test func retriesSeeksAndRepeatsOfOneEntryAreNotChanges() {
        let entry = UUID()
        var tracker = SongChangeTracker()
        #expect(tracker.update(playing(entry)) == entry)
        // Buffering after a seek, then a retry or repeat-one with a new occurrence.
        #expect(tracker.update(playing(entry, confirmed: false)) == nil)
        #expect(tracker.update(playing(entry, generation: 2)) == nil)
        #expect(tracker.update(playing(entry, generation: 3)) == nil)
    }

    @Test func skippedSongsThatNeverPlayAreNotAnnounced() {
        let first = UUID(), skipped = UUID(), landed = UUID()
        var tracker = SongChangeTracker()
        _ = tracker.update(playing(first))
        #expect(tracker.update(playing(skipped, "b", confirmed: false)) == nil)
        #expect(tracker.update(playing(landed, "c")) == landed)
        // Going back to a song that was already announced before the skip.
        var back = SongChangeTracker()
        _ = back.update(playing(first))
        _ = back.update(playing(skipped, "b", confirmed: false))
        #expect(back.update(playing(first, generation: 2)) == nil)
    }

    @Test func repeatedSongInAnotherEntryIsAChange() {
        let first = UUID(), copy = UUID()
        var tracker = SongChangeTracker()
        _ = tracker.update(playing(first, "a"))
        #expect(tracker.update(playing(copy, "a")) == copy)
    }

    @Test func clearedQueueStartsOver() {
        let first = UUID(), next = UUID()
        var tracker = SongChangeTracker()
        _ = tracker.update(playing(first))
        #expect(tracker.update(SongPlaybackState()) == nil)
        #expect(tracker.settledEntryID == nil)
        #expect(tracker.update(playing(next, "b")) == next)
    }
}

@MainActor
private final class FakeNotificationCenter: SongNotificationCenter {
    var status: SongNotificationAuthorization
    var grants = true
    var requests = 0
    var posted: [SongNotificationContent] = []
    var removals = 0
    var duringAuthorization: (() -> Void)?

    init(status: SongNotificationAuthorization) { self.status = status }

    func authorization() async -> SongNotificationAuthorization {
        duringAuthorization?()
        return status
    }

    func requestAuthorization() async throws -> Bool {
        requests += 1
        status = grants ? .allowed : .denied
        return grants
    }

    func post(_ content: SongNotificationContent) async throws { posted.append(content) }
    func removeDelivered() { removals += 1 }
}

@MainActor
private final class NotifierFixture {
    let suite = "MacControlsTests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let center: FakeNotificationCenter?
    var state = SongPlaybackState()
    var isActive = false
    var notifier: SongChangeNotifier!

    init(status: SongNotificationAuthorization = .notDetermined, enabled: Bool = false, hasCenter: Bool = true) {
        preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        if enabled { preferences.set(true, forKey: SongChangeNotifier.preferenceKey) }
        center = hasCenter ? FakeNotificationCenter(status: status) : nil
        notifier = SongChangeNotifier(preferences: preferences, center: center,
                                      isAppActive: { [unowned self] in self.isActive },
                                      state: { [unowned self] in self.state })
    }

    deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }
}

@MainActor
struct SongChangeNotifierTests {
    @Test func offByDefaultAndPostsNothing() async {
        let fixture = NotifierFixture(status: .allowed)
        #expect(!fixture.notifier.isEnabled)
        fixture.state = playing(UUID())
        #expect(await fixture.notifier.evaluate() == false)
        #expect(fixture.center?.posted.isEmpty == true)
        #expect(fixture.center?.requests == 0)
    }

    @Test func turningOnAsksOnceAndStoresTheChoice() async {
        let fixture = NotifierFixture()
        await fixture.notifier.setEnabled(true)
        #expect(fixture.center?.requests == 1)
        #expect(fixture.notifier.isEnabled)
        #expect(fixture.notifier.authorization == .allowed)
        #expect(fixture.preferences.bool(forKey: SongChangeNotifier.preferenceKey))
        await fixture.notifier.setEnabled(false)
        #expect(fixture.center?.requests == 1)
        #expect(fixture.center?.removals == 1)
        #expect(!fixture.preferences.bool(forKey: SongChangeNotifier.preferenceKey))
    }

    @Test func deniedPermissionLeavesTheSettingOffWithAnExplanation() async {
        let fixture = NotifierFixture()
        fixture.center?.grants = false
        await fixture.notifier.setEnabled(true)
        #expect(!fixture.notifier.isEnabled)
        #expect(fixture.notifier.authorization == .denied)
        #expect(fixture.notifier.message == SongChangeNotifier.deniedMessage)
        #expect(!fixture.preferences.bool(forKey: SongChangeNotifier.preferenceKey))

        let alreadyDenied = NotifierFixture(status: .denied)
        await alreadyDenied.notifier.setEnabled(true)
        #expect(alreadyDenied.center?.requests == 0)
        #expect(!alreadyDenied.notifier.isEnabled)
    }

    @Test func withoutAnAppBundleTheSettingIsUnavailable() async {
        let fixture = NotifierFixture(enabled: true, hasCenter: false)
        #expect(!fixture.notifier.isAvailable)
        #expect(!fixture.notifier.isEnabled)
        await fixture.notifier.setEnabled(true)
        #expect(!fixture.notifier.isEnabled)
        #expect(fixture.notifier.message != nil)
    }

    @Test func postsConfirmedChangesOnlyWhileInTheBackground() async throws {
        let fixture = NotifierFixture(status: .allowed, enabled: true)
        let first = UUID(), second = UUID(), third = UUID()
        fixture.state = SongPlaybackState(selectedEntryID: first, track: track("a"))
        #expect(await fixture.notifier.evaluate() == false)
        fixture.state = playing(first, "a")
        #expect(await fixture.notifier.evaluate() == false)
        fixture.state = playing(second, "b", confirmed: false)
        #expect(await fixture.notifier.evaluate() == false)
        fixture.state = playing(second, "b")
        #expect(await fixture.notifier.evaluate())
        fixture.state = playing(second, "b", generation: 2)
        #expect(await fixture.notifier.evaluate() == false)
        fixture.isActive = true
        fixture.state = playing(third, "c")
        #expect(await fixture.notifier.evaluate() == false)
        let posted = try #require(fixture.center?.posted)
        #expect(posted == [SongNotificationContent(track("b"))])
        #expect(posted.first?.title == "Song b")
        #expect(posted.first?.body == "Artist b")
        #expect(posted.first?.subtitle == "Album b")
    }

    @Test func revokedPermissionStopsPostingAndExplains() async {
        let fixture = NotifierFixture(status: .denied, enabled: true)
        fixture.state = playing(UUID())
        #expect(await fixture.notifier.evaluate() == false)
        #expect(fixture.center?.posted.isEmpty == true)
        #expect(fixture.notifier.message == SongChangeNotifier.deniedMessage)
    }

    @Test func aSongReplacedWhilePermissionIsCheckedIsNotPosted() async {
        let fixture = NotifierFixture(status: .allowed, enabled: true)
        let next = UUID()
        fixture.center?.duringAuthorization = { [unowned fixture] in fixture.state = playing(next, "b", confirmed: false) }
        fixture.state = playing(UUID(), "a")
        #expect(await fixture.notifier.evaluate() == false)
        #expect(fixture.center?.posted.isEmpty == true)
    }
}

@MainActor
struct MiniPlayerAndOutputTests {
    @Test func keepOnTopSetsAFloatingWindowLevel() {
        #expect(MiniPlayerWindowLevel.level(keepsOnTop: true) == .floating)
        #expect(MiniPlayerWindowLevel.level(keepsOnTop: false) == .normal)
        let window = testWindow()
        let view = WindowLevelSetter.LevelView()
        view.level = .floating
        window.contentView?.addSubview(view)
        #expect(window.level == .floating)
        view.level = .normal
        #expect(window.level == .normal)
    }

    @Test func outputPickerHasASpokenName() {
        let picker = LabeledRoutePickerView(frame: .zero)
        #expect(picker.isAccessibilityElement())
        #expect(picker.accessibilityRole() == .button)
        #expect(picker.accessibilityLabel() == AudioOutputPicker.label)
        #expect(picker.accessibilityHelp() == AudioOutputPicker.help)
        // The inner button stays hidden from VoiceOver, so the name is not read twice.
        for case let control as NSControl in picker.subviews { #expect(!control.isAccessibilityElement()) }
    }
}
