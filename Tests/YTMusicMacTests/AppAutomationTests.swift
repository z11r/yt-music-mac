import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

@MainActor @Suite("Shortcut dispatch")
struct AppAutomationTests {
    @Test func listingAndConstructingActionsNeverResolvesASession() {
        let dispatcher = MusicAutomation { Issue.record("No invocation should resolve a session"); return nil }
        _ = dispatcher
        _ = ResumeMusicIntent()
        _ = PauseMusicIntent()
        _ = SetMusicVolumeIntent()
        _ = PlaySongByIDIntent()
        _ = OpenMusicLinkIntent()
        _ = SearchMusicIntent()
        #expect(MusicShortcuts.appShortcuts.count == 8)
    }

    @Test func missingSessionFailsWithoutConstructingAPlayer() async {
        let dispatcher = MusicAutomation { nil }
        await #expect(throws: MusicAutomationError.unavailable) { try await dispatcher.perform(.pause) }
    }

    @Test func signedOutPlaybackNeverOpensAnAccountOrStartsALookup() async {
        let session = AutomationFixture()
        session.automationState.isSignedIn = false
        let dispatcher = MusicAutomation { session }
        for action in [MusicAutomationAction.resume, .next, .previous, .playVideo("abcDEF12_-3"),
                       .openLink(URL(string: "https://music.youtube.com/watch?v=abcDEF12_-3")!)] {
            await #expect(throws: MusicAutomationError.signInRequired) { try await dispatcher.perform(action) }
        }
        #expect(session.actions.isEmpty)
        #expect(session.lookups.isEmpty)
        #expect(session.destinations.isEmpty)
    }

    @Test func pauseAndVolumeWorkWithoutAnAccountAndVolumeIsAppScoped() async throws {
        let session = AutomationFixture()
        session.automationState.isSignedIn = false
        let dispatcher = MusicAutomation { session }
        try await dispatcher.perform(.pause)
        try await dispatcher.perform(.volume(35))
        #expect(session.actions == [.pause])
        #expect(session.volumes == [0.35])
        #expect(session.lookups.isEmpty)
    }

    @Test func explicitNavigationRequestsMainButTransportDoesNotPresentAWindow() async throws {
        let session = AutomationFixture(), dispatcher = MusicAutomation { session }
        try await dispatcher.perform(.pause)
        try await dispatcher.perform(.volume(35))
        #expect(session.presentations == 0)
        try await dispatcher.perform(.search("fixture"))
        try await dispatcher.perform(.openLink(URL(string: "https://music.youtube.com/playlist?list=PLfixture")!))
        #expect(session.presentations == 2 && session.searches == ["fixture"] && session.destinations.count == 1)
    }

    @Test func invalidParametersNeverPrepareOrMutateTheSession() async {
        let session = AutomationFixture()
        let dispatcher = MusicAutomation { session }
        let invalid: [MusicAutomationAction] = [.volume(-1), .volume(101), .volume(.nan), .volume(.infinity),
            .playVideo("short"), .playVideo(" abcDEF12_-3"),
            .openLink(URL(string: "https://example.invalid/watch?v=abcDEF12_-3")!),
            .search(" "), .search("one\ntwo"), .search(String(repeating: "a", count: 501))]
        for action in invalid { await #expect(throws: MusicAutomationError.self) { try await dispatcher.perform(action) } }
        #expect(session.preparations == 0)
        #expect(session.actions.isEmpty)
        #expect(session.lookups.isEmpty)
        #expect(session.volumes.isEmpty)
    }

    @Test func readyAndSelectionChecksPreventSilentNoOps() async {
        let session = AutomationFixture()
        let dispatcher = MusicAutomation { session }
        session.automationState.isReady = false
        await #expect(throws: MusicAutomationError.notReady) { try await dispatcher.perform(.resume) }
        session.automationState.isReady = true
        session.automationState.hasSelection = false
        await #expect(throws: MusicAutomationError.noSelection) { try await dispatcher.perform(.resume) }
        session.automationState.hasSelection = true
        session.automationState.hasNextSong = false
        await #expect(throws: MusicAutomationError.noNextSong) { try await dispatcher.perform(.next) }
        #expect(session.actions.isEmpty)
    }

    @Test func transportUsesTheExistingQueueOwner() async throws {
        let session = AutomationFixture()
        let dispatcher = MusicAutomation { session }
        for action in [MusicAutomationAction.resume, .next, .previous] { try await dispatcher.perform(action) }
        #expect(session.actions == [.resume, .next, .previous])
        #expect(session.destinations.isEmpty)
    }

    @Test func exactSongLinksAndIDsUseTheExactRecordingResolver() async throws {
        let session = AutomationFixture()
        let dispatcher = MusicAutomation { session }
        try await dispatcher.perform(.playVideo("abcDEF12_-3"))
        try await dispatcher.perform(.openLink(URL(string: "https://youtu.be/abcDEF12_-3?si=tracking")!))
        #expect(session.lookups == ["abcDEF12_-3", "abcDEF12_-3"])
        #expect(session.played == ["abcDEF12_-3", "abcDEF12_-3"])
    }

    @Test func collectionLinksNavigateWithoutPlaybackAndStripTracking() async throws {
        let session = AutomationFixture()
        session.automationState.isSignedIn = false
        let dispatcher = MusicAutomation { session }
        try await dispatcher.perform(.openLink(URL(string: "https://music.youtube.com/browse/MPREalbum?si=tracking")!))
        try await dispatcher.perform(.openLink(URL(string: "https://music.youtube.com/channel/UCartist")!))
        try await dispatcher.perform(.openLink(URL(string: "https://music.youtube.com/playlist?list=VLPLlist")!))
        #expect(session.destinations == [
            .collection(MusicCollection(id: "MPREalbum", kind: .album, title: "Album")),
            .collection(MusicCollection(id: "UCartist", kind: .artist, title: "Artist")),
            .collection(MusicCollection(id: "PLlist", kind: .playlist, title: "Playlist"))])
        #expect(session.lookups.isEmpty)
        #expect(session.actions.isEmpty)
    }

    @Test func searchPreservesTheTypedQueryWithoutChoosingAResult() async throws {
        let session = AutomationFixture()
        let dispatcher = MusicAutomation { session }
        try await dispatcher.perform(.search("  exact artist & album  "))
        #expect(session.searches == ["exact artist & album"])
        #expect(session.played.isEmpty)
    }

    @Test func newerPauseFencesAPlaybackLookupAlreadyInFlight() async throws {
        let gate = AutomationGate()
        let session = AutomationFixture()
        session.lookup = { id in
            await gate.suspend()
            return page(id)
        }
        let dispatcher = MusicAutomation { session }
        let older = Task { try await dispatcher.perform(.playVideo("abcDEF12_-3")) }
        await gate.waitForArrival()
        try await dispatcher.perform(.pause)
        await gate.release()
        await #expect(throws: MusicAutomationError.superseded) { try await older.value }
        #expect(session.played.isEmpty)
        #expect(session.actions == [.pause])
    }

    @Test func aMissingExactRecordingKeepsTheExistingQueue() async {
        let session = AutomationFixture()
        session.lookup = { _ in page("differentID") }
        let dispatcher = MusicAutomation { session }
        await #expect(throws: MusicAutomationError.lookupFailed) {
            try await dispatcher.perform(.playVideo("abcDEF12_-3"))
        }
        #expect(session.played.isEmpty)
        #expect(session.actions.isEmpty)
    }

    @Test func volumeAdjustmentDoesNotCancelAnExplicitSongLookup() async throws {
        let gate = AutomationGate()
        let session = AutomationFixture()
        session.lookup = { id in await gate.suspend(); return page(id) }
        let dispatcher = MusicAutomation { session }
        let playback = Task { try await dispatcher.perform(.playVideo("abcDEF12_-3")) }
        await gate.waitForArrival()
        try await dispatcher.perform(.volume(20))
        await gate.release()
        try await playback.value
        #expect(session.played == ["abcDEF12_-3"])
        #expect(session.volumes == [0.2])
    }

    @Test func nativeActionDuringPreparationAlsoFencesTheShortcut() async {
        let gate = AutomationGate()
        let session = AutomationFixture()
        session.prepare = { await gate.suspend() }
        let dispatcher = MusicAutomation { session }
        let older = Task { try await dispatcher.perform(.resume) }
        await gate.waitForArrival()
        _ = session.beginScriptedPlaybackRequest() // Same fence used by native actions.
        await gate.release()
        await #expect(throws: MusicAutomationError.superseded) { try await older.value }
        #expect(session.actions.isEmpty)
    }

    @Test func sessionReplacementDuringPreparationCannotTargetTheNewSession() async {
        let gate = AutomationGate()
        let first = AutomationFixture()
        let second = AutomationFixture()
        first.prepare = { await gate.suspend() }
        var current: AutomationFixture? = first
        let dispatcher = MusicAutomation { current }
        let older = Task { try await dispatcher.perform(.resume) }
        await gate.waitForArrival()
        current = second
        await gate.release()
        await #expect(throws: MusicAutomationError.superseded) { try await older.value }
        #expect(first.actions.isEmpty)
        #expect(second.actions.isEmpty)
    }

    @Test func cancelledActionCannotDispatchAfterPreparation() async {
        let gate = AutomationGate()
        let session = AutomationFixture()
        session.prepare = { await gate.suspend() }
        let dispatcher = MusicAutomation { session }
        let operation = Task { try await dispatcher.perform(.next) }
        await gate.waitForArrival()
        operation.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(session.actions.isEmpty)
    }
}

@MainActor
private final class AutomationFixture: MusicAutomationSession {
    var automationState = MusicAutomationState(isReady: true, isSignedIn: true, hasSelection: true, hasNextSong: true)
    var prepare: () async -> Void = {}
    var lookup: @Sendable (String) async throws -> MusicPage = { page($0) }
    private var request = UUID()
    private(set) var preparations = 0
    private(set) var actions: [MusicAutomationAction] = []
    private(set) var volumes: [Double] = []
    private(set) var lookups: [String] = []
    private(set) var played: [String] = []
    private(set) var destinations: [MusicDestination] = []
    private(set) var searches: [String] = []
    private(set) var presentations = 0

    func prepareForAutomation() async { preparations += 1; await prepare() }
    func beginScriptedPlaybackRequest() -> UUID { request = UUID(); return request }
    func acceptsScriptedPlaybackRequest(_ value: UUID) -> Bool { request == value }
    func playScriptedVideo(_ id: String, requestGeneration: UUID) async throws -> String {
        lookups.append(id)
        let track = try await ScriptedTrackResolver.resolve(videoID: id, search: lookup)
        guard request == requestGeneration, automationState.isSignedIn else { throw AppScriptingError.superseded }
        played.append(track.id)
        return track.id
    }
    func performAutomationTransport(_ action: MusicAutomationAction) { actions.append(action); _ = beginScriptedPlaybackRequest() }
    func setVolume(_ value: Double) { volumes.append(value) }
    func navigate(to target: MusicDestination, recordHistory: Bool) { destinations.append(target) }
    func searchForAutomation(_ query: String) { searches.append(query) }
    func presentAutomationNavigation() { presentations += 1 }
}

private actor AutomationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var arrived = false
    func suspend() async {
        arrived = true
        arrival?.resume(); arrival = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForArrival() async {
        if arrived { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private func page(_ id: String) -> MusicPage {
    MusicPage(title: "Fixture", sections: [], items: [.track(Track(id: id, title: "Song", artist: "Artist"))])
}
