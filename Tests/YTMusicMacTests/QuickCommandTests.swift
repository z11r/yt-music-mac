import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

struct QuickCommandParserTests {
    @Test func exactEnglishAndFrenchCommandsHaveTypedMeaning() {
        let commands: [(String, QuickCommand)] = [("PLAY", .play), ("lire", .play), ("pause", .pause),
            ("next", .next), ("suivant", .next), ("PRÉCÉDENT", .previous),
            ("open artists", .open(.artists)), ("ouvrir artistes suivis", .open(.followedArtists)),
            ("open songs", .open(.songs)), ("ouvrir bibliothèque", .open(.library)),
            ("open saved episodes", .open(.savedEpisodes)), ("ouvrir vos balados", .open(.yourPodcasts)),
            ("open queue", .open(.queue)), ("timer 1440 min", .timerMinutes(1_440)),
            ("minuterie fin", .timerEnd), ("minuterie arrêt", .timerOff), ("volume 100", .volume(100)),
            ("position 3:09", .seek(189)), ("seek 0:00", .seek(0)), ("aléatoire oui", .shuffle(true)),
            ("shuffle off", .shuffle(false)), ("répétition toutes", .repeatMode(.all)),
            ("repeat one", .repeatMode(.one)), ("répétition non", .repeatMode(.off))]
        for (input, expected) in commands { #expect(QuickCommandParser.parse(input) == .success(expected)) }
    }
    @Test func searchRemainderIsOpaqueIncludingSpacesQuotesCaseAndCommandWords() {
        for query in ["  Björk AND 'next'  ", "play jazz; pause", "東京 🎵 + live -remix", "https://example.invalid/?q=next&timer=off", "I Want It All"] {
            #expect(QuickCommandParser.parse("search " + query) == .success(.search(query)))
            #expect(QuickCommandParser.parse("RECHERCHER " + query) == .success(.search(query)))
        }
    }
    @Test func ambiguousNaturalLanguageChainingAndUnsupportedActionsNeverFallBackToPlayback() {
        for text in ["play jazz", "play next", "next previous", "play; pause", "pause && next", "generate a playlist", "like", "queue jazz", "play something relaxing", "open artists followed"] {
            guard case .failure = QuickCommandParser.parse(text) else { Issue.record("Unexpected command: \(text)"); continue }
        }
    }
    @Test func numericGrammarAndSingleLineBoundsRejectNonFiniteAndOverflowInput() {
        let rejected = ["timer 0 min", "timer 1441 min", "timer 1.5 min", "timer 20", "timer -1 min", "volume 101", "volume -0", "volume 0.1", "volume 50%", "volume NaN", "volume １２", "seek 1:1", "seek 1:60", "seek -1:00", "seek 1441:00", "seek 1:02:03", "seek inf", "seek 999999999999999999:00", "search \nnext", "pause\t", "search hello\u{0}world"]
        for input in rejected { guard case .failure = QuickCommandParser.parse(input) else { Issue.record("Accepted invalid input"); continue } }
        #expect(QuickCommandParser.parse("search " + String(repeating: "a", count: 501)) == .failure(.tooLong))
        #expect(QuickCommandParser.parse(String(repeating: " ", count: 1_025)) == .failure(.tooLong))
        #expect(QuickCommandParser.parse("search " + String(repeating: "界", count: 500)) == .failure(.tooLong))
        #expect(QuickCommandParser.parse("search ") == .failure(.searchUsage))
    }
}

@MainActor private final class QuickCommandHarness {
    let palette = QuickCommandPalette()
    var environment = QuickCommandEnvironment(scope: .init(accountGeneration: UUID(), profile: nil, startupIntent: UUID()), ready: true)
    var commands: [QuickCommand] = []
    init() {
        palette.environment = { [weak self] in self?.environment }
        palette.execute = { [weak self] command, _ in self?.commands.append(command) }
    }
    @discardableResult func run(_ text: String) -> Result<QuickCommand, QuickCommandIssue> {
        palette.present(); palette.edit(text); return palette.run(ticket: palette.ticket)
    }
}

@MainActor struct QuickCommandDispatchTests {
    @Test func duplicatePresentationAndInputTicketsCannotExecuteTwice() {
        let h = QuickCommandHarness()
        h.palette.present(); h.palette.edit("volume 20")
        let first = h.palette.ticket
        h.palette.edit("volume 30")
        #expect(h.palette.run(ticket: first) == .failure(.stale))
        let current = h.palette.ticket
        #expect(h.palette.run(ticket: current) == .success(.volume(30)))
        #expect(h.palette.run(ticket: current) == .failure(.stale))
        #expect(h.commands == [.volume(30)] && !h.palette.isPresented && h.palette.input.isEmpty)
        h.palette.present(); h.palette.edit("volume 40")
        #expect(h.palette.run(ticket: current) == .failure(.stale))
        #expect(h.commands.count == 1)
    }
    @Test func accountProfileAndStartupIntentChangesRefuseTheOldOwner() {
        for change in 0..<3 {
            let h = QuickCommandHarness()
            h.palette.present(); h.palette.edit("volume 50")
            let ticket = h.palette.ticket, old = h.environment.scope
            h.environment = .init(scope: .init(accountGeneration: change == 0 ? UUID() : old.accountGeneration,
                profile: change == 1 ? "fixture-profile" : old.profile, startupIntent: change == 2 ? UUID() : old.startupIntent), ready: true)
            #expect(h.palette.run(ticket: ticket) == .failure(.stale))
            #expect(h.commands.isEmpty)
        }
    }
    @Test func scopeIsReadAgainImmediatelyBeforeDispatch() {
        let h = QuickCommandHarness(); var calls = 0
        h.palette.present(); h.palette.edit("volume 50")
        h.palette.environment = {
            calls += 1
            if calls == 2 { return .init(scope: .init(accountGeneration: UUID(), profile: nil, startupIntent: UUID()), ready: true) }
            return h.environment
        }
        #expect(h.palette.run(ticket: h.palette.ticket) == .failure(.stale))
        #expect(h.commands.isEmpty)
    }
    @Test func publicSearchAndNavigationAndLocalControlsDoNotRequireSignIn() {
        let h = QuickCommandHarness()
        #expect(!h.environment.signedIn)
        for (text, expected): (String, QuickCommand) in [("search All the Way", .search("All the Way")), ("open home", .open(.home)), ("volume 50", .volume(50)), ("timer 15 min", .timerMinutes(15)), ("timer off", .timerOff), ("open queue", .open(.queue))] {
            #expect(h.run(text) == .success(expected))
        }
        #expect(h.commands.count == 6)
    }
    @Test func localControlsRemainAvailableDuringStartupButQueueActionsWait() {
        let h = QuickCommandHarness(); h.environment.ready = false
        for text in ["open home", "search music", "next", "shuffle on", "repeat all"] { #expect(h.run(text) == .failure(.notReady)) }
        #expect(h.run("volume 25") == .success(.volume(25)))
        #expect(h.run("timer off") == .success(.timerOff))
        #expect(h.commands == [.volume(25), .timerOff])
    }
    @Test func missingQueueOccurrenceAndDurationHaveActionableFeedback() {
        let h = QuickCommandHarness()
        #expect(h.run("play") == .failure(.noQueue))
        #expect(h.run("pause") == .failure(.noCurrentOccurrence))
        #expect(h.run("next") == .failure(.noCurrentOccurrence))
        #expect(h.run("previous") == .failure(.noCurrentOccurrence))
        #expect(h.run("timer end") == .failure(.noCurrentOccurrence))
        h.environment.hasQueue = true
        #expect(h.run("play") == .failure(.signIn))
        h.environment.occurrence = .init(sessionID: UUID(), entryID: UUID(), trackID: "fixture", generation: 1)
        #expect(h.run("next") == .failure(.noNext))
        #expect(h.run("seek 1:00") == .failure(.cannotSeek))
        h.environment.duration = 30
        #expect(h.run("seek 1:00") == .failure(.seekOutOfRange))
        #expect(h.commands.isEmpty && h.palette.message != nil)
    }
    @Test func failedParsingAndOversizedPreviewsNeverDispatchAFragment() {
        let h = QuickCommandHarness()
        #expect(h.run("play jazz") == .failure(.playbackUsage))
        h.palette.present(); h.palette.edit("search " + String(repeating: "界", count: 2_000))
        #expect(h.palette.input.utf8.count <= 1_027)
        #expect(h.palette.run(ticket: h.palette.ticket) == .failure(.tooLong))
        #expect(h.commands.isEmpty)
        h.palette.edit("volume 10")
        #expect(h.palette.run(ticket: h.palette.ticket) == .success(.volume(10)))
    }
    @Test func invalidationClearsSensitiveInputAndShutdownRejectsNewWork() {
        let h = QuickCommandHarness()
        h.palette.present(); h.palette.edit("search fixture private query")
        let ticket = h.palette.ticket; h.palette.invalidate()
        #expect(h.palette.input.isEmpty && !h.palette.isPresented)
        #expect(h.palette.run(ticket: ticket) == .failure(.stale))
        h.environment.shuttingDown = true; h.palette.present()
        #expect(!h.palette.isPresented && h.commands.isEmpty)
    }
}

@MainActor struct QuickCommandNativeTests {
    @Test func anonymousVolumeQueueAndTimerActionsUseDisposablePreferencesWithoutPlayback() async {
        let preferences = SceneCheckPreferences(); defer { preferences.remove() }
        let transport = SceneCheckTransport()
        let session = AppSession(configuration: .sceneCheck(preferences: preferences.defaults, transport: transport))
        #expect(run("volume 25", session) == .success(.volume(25)))
        #expect(preferences.defaults.double(forKey: "volume") == 0.25 && session.player.volume == 0.25)
        #expect(run("open queue", session) == .success(.open(.queue)) && session.showsQueue)
        #expect(run("timer 1 min", session) == .success(.timerMinutes(1)) && session.sleepTimer.isArmed)
        #expect(run("timer off", session) == .success(.timerOff) && !session.sleepTimer.isArmed)
        #expect(await transport.attempts == 0)
        #expect(session.sceneCheckIsIsolated)
        session.quickCommands.present(); session.quickCommands.edit("search fixture query")
        session.openAccount()
        #expect(!session.quickCommands.isPresented && session.quickCommands.input.isEmpty && session.account.loginWebView == nil)
    }
    @Test func artistDestinationsAreDistinctAndSearchDoesNotChoosePlayback() async {
        let preferences = SceneCheckPreferences(); defer { preferences.remove() }
        let transport = SceneCheckTransport()
        let session = AppSession(configuration: .sceneCheck(preferences: preferences.defaults, transport: transport))
        _ = run("open artists", session)
        #expect(session.destination == .libraryCategory(.songArtists))
        _ = run("open followed artists", session)
        #expect(session.destination == .libraryCategory(.artists))
        let query = "  Björk AND 'next'; volume 100  "
        _ = run("search " + query, session)
        #expect(session.searchText == query && session.destination == .search(query))
        await session.pageTask?.value
        #expect(session.queue.isEmpty && !session.player.playbackIntent && session.player.webView.url == nil)
        #expect(session.searchHistory.queries.isEmpty)
    }
    @Test func accountAndLinkIntentFencesApplyToNativeDispatchToo() {
        let preferences = SceneCheckPreferences(); defer { preferences.remove() }
        let session = AppSession(configuration: .sceneCheck(preferences: preferences.defaults, transport: SceneCheckTransport()))
        session.quickCommands.present(); session.quickCommands.edit("volume 30")
        let ticket = session.quickCommands.ticket
        session.accountGeneration = UUID()
        #expect(session.quickCommands.run(ticket: ticket) == .failure(.stale))
        session.quickCommands.present(); session.quickCommands.edit("volume 40")
        let linkTicket = session.quickCommands.ticket
        session.links.generation = UUID()
        #expect(session.quickCommands.run(ticket: linkTicket) == .failure(.stale))
        #expect(preferences.defaults.object(forKey: "volume") == nil)
    }
    @Test func existingOccurrenceActionsAreBoundedAndIdempotent() async throws {
        let preferences = SceneCheckPreferences(); defer { preferences.remove() }
        let session = AppSession(configuration: .sceneCheck(preferences: preferences.defaults, transport: SceneCheckTransport()))
        #expect(session.advanceSceneCheck(to: 1))
        let begun = session.queue.beginPlayback()
        let occurrence = try #require(begun)
        _ = run("timer end", session)
        #expect(session.sleepTimer.state.schedule == SleepTimerState.Schedule.endOfTrack(occurrence))
        _ = run("timer off", session)
        _ = run("shuffle on", session); _ = run("shuffle on", session)
        #expect(session.queue.isShuffled)
        _ = run("shuffle off", session); _ = run("repeat one", session)
        #expect(!session.queue.isShuffled && session.queue.repeatMode == .one)
        _ = run("pause", session)
        #expect(session.sceneCheckIsIsolated)
    }
    private func run(_ text: String, _ session: AppSession) -> Result<QuickCommand, QuickCommandIssue> {
        session.quickCommands.present(); session.quickCommands.edit(text)
        return session.quickCommands.run(ticket: session.quickCommands.ticket)
    }
}
