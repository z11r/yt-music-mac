import AppKit
import AVKit
import MusicCore
import SwiftUI
import Testing
import WebKit
@testable import YTMusicMac

@MainActor
private func testWindow() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
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

    @Test func stoppingDuringAuthorizationFencesPostingAndDoesNotAlterTheSavedChoice() async {
        let fixture = NotifierFixture(status: .allowed, enabled: true)
        fixture.center?.duringAuthorization = { [unowned fixture] in fixture.notifier.stop() }
        fixture.state = playing(UUID(), "a")
        #expect(!(await fixture.notifier.evaluate()))
        await fixture.notifier.waitForIdle()
        #expect(fixture.center?.posted.isEmpty == true)
        #expect(fixture.preferences.bool(forKey: SongChangeNotifier.preferenceKey))
        fixture.center?.duringAuthorization = nil
        fixture.notifier.start()
        fixture.state = playing(UUID(), "b")
        #expect(await fixture.notifier.evaluate())
        fixture.notifier.stop()
    }

    @Test func stoppingBeforePermissionDecisionCannotPromptForAnOldOwner() async {
        let fixture = NotifierFixture()
        fixture.center?.duringAuthorization = { [unowned fixture] in fixture.notifier.stop() }
        await fixture.notifier.setEnabled(true)
        #expect(fixture.center?.requests == 0)
        #expect(!fixture.preferences.bool(forKey: SongChangeNotifier.preferenceKey))
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
