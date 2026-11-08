import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@Suite("Reviewed command validation")
struct ReviewedCommandValidatorTests {
    @Test func supportedSourceArgumentsBecomeOnlyExistingExactCommands() throws {
        let rows: [(String, String, String, QuickCommand)] = [
            ("Please pause playback", "pause", "", .pause),
            ("Could you resume the queue", "play", "", .play),
            ("Skip to next", "next", "", .next), ("Go to previous", "previous", "", .previous),
            ("Open my albums", "open", "albums", .open(.albums)),
            ("Ouvrir les artistes suivis", "open", "artistes suivis", .open(.followedArtists)),
            ("Set volume to 50 percent", "volume", "50", .volume(50)),
            ("Go to position 1:30 please", "seek", "1:30", .seek(90)),
            ("Stop in 15 minutes", "timerMinutes", "15", .timerMinutes(15)),
            ("Stop at the end", "timerEnd", "", .timerEnd), ("Turn the timer off", "timerOff", "", .timerOff),
            ("Turn shuffle on", "shuffleOn", "", .shuffle(true)), ("Turn shuffle off", "shuffleOff", "", .shuffle(false)),
            ("Turn repeat off", "repeatOff", "", .repeatMode(.off)), ("Repeat all", "repeatAll", "", .repeatMode(.all)),
            ("Repeat one", "repeatOne", "", .repeatMode(.one)),
        ]
        for (input, action, argument, expected) in rows {
            let result = try ReviewedCommandValidator.validate(.init(action: action, argument: argument, disposition: "single"), input: input)
            #expect(result.command == expected)
            #expect(QuickCommandParser.parse(result.exact) == .success(expected))
        }
    }
    @Test func searchPreservesTheExactQuotedQueryWithoutTreatingItsWordsAsActions() throws {
        let query = "  Björk AND 'next'; volume 100  "
        let result = try ReviewedCommandValidator.validate(.init(action: "search", argument: query, disposition: "single"), input: "Please find \"\(query)\"")
        #expect(result.command == .search(query))
        for argument in ["Björk", query + " invented"] {
            #expect(throws: ReviewedCommandIssue.sourceValue) {
                try ReviewedCommandValidator.validate(.init(action: "search", argument: argument, disposition: "single"), input: "Please find \"\(query)\"")
            }
        }
    }
    @Test func missingInventedConvertedAndOutOfRangeValuesAreRejected() {
        let rows = [("Make it louder", "volume", "50"), ("Volume fifty", "volume", "50"),
                    ("Volume 50", "volume", "60"), ("Volume 101", "volume", "101"),
                    ("Volume -1", "volume", "1"), ("Volume 0.5", "volume", "50"),
                    ("Seek 1:30", "seek", "90"), ("Seek 1:99", "seek", "1:99"),
                    ("Seek 1441:00", "seek", "1441:00"), ("Timer 2 hours", "timerMinutes", "120"),
                    ("Timer 15 seconds", "timerMinutes", "15"), ("Timer 15", "timerMinutes", "15"),
                    ("Timer 0 minutes", "timerMinutes", "0"), ("Volume 50 or 60", "volume", "50"),
                    ("Open disliked", "open", "liked"), ("Open something", "open", "uploads")]
        for (input, action, argument) in rows {
            #expect(throws: (any Error).self) { try ReviewedCommandValidator.validate(.init(action: action, argument: argument, disposition: "single"), input: input) }
        }
    }
    @Test func unsupportedCompoundAndOversizedOutputCannotBecomeAnAction() {
        for disposition in ["ambiguous", "multiple", "unsupported", "SINGLE"] {
            #expect(throws: ReviewedCommandIssue.ambiguous) { try ReviewedCommandValidator.validate(.init(action: "pause", argument: "", disposition: disposition), input: "Please pause") }
        }
        for input in ["Pause and next", "Pause; next", "Pause, next", "Pause puis suivant", "Pause before next", "Pause & next"] {
            #expect(throws: ReviewedCommandIssue.ambiguous) { try ReviewedCommandValidator.validate(.init(action: "pause", argument: "", disposition: "single"), input: input) }
        }
        for action in ["playVideoID", "delete", "playlist", "pause;next", "unsupported"] {
            #expect(throws: ReviewedCommandIssue.ambiguous) { try ReviewedCommandValidator.validate(.init(action: action, argument: "", disposition: "single"), input: "Please pause") }
        }
        #expect(!ReviewedCommandValidator.validInput(String(repeating: "a", count: 513)))
        #expect(!ReviewedCommandValidator.validInput("pause\nnext"))
        #expect(!ReviewedCommandValidator.validInput(" "))
    }
    @Test func rawSchemaRejectsAdditionalFieldsArraysWrongTypesAndOversizedData() throws {
        let valid = Data(#"{"action":"pause","argument":"","disposition":"single"}"#.utf8)
        #expect(try CommandInterpretation.decode(valid) == .init(action: "pause", argument: "", disposition: "single"))
        for raw in [#"{"action":"pause","argument":"","disposition":"single","videoID":"invented"}"#,
                    #"[{"action":"pause"},{"action":"next"}]"#, #"{"action":"volume","argument":50,"disposition":"single"}"#, "broken", "{}"] {
            #expect(throws: ReviewedCommandIssue.invalid) { try CommandInterpretation.decode(Data(raw.utf8)) }
        }
        #expect(throws: ReviewedCommandIssue.invalid) { try CommandInterpretation.decode(Data(repeating: 32, count: 4_097)) }
    }
}

@Suite("Explicit on-device command review") @MainActor
struct CommandReviewSessionTests {
    @Test func defaultOffAndUnavailableCasesNeverGenerate() async throws {
        let h = try ReviewHarness(); defer { h.remove() }
        h.review.present(); h.review.edit("Please pause"); h.review.interpret()
        #expect(!h.review.enabled && h.provider.availabilityReads == 0 && h.provider.inputs.isEmpty)
        h.enable()
        for status in [LocalCommandAvailability.requiresSystem, .ineligibleDevice, .notEnabled, .notReady, .unsupportedLanguage] {
            h.provider.status = status
            h.review.present(); h.review.edit("Please pause"); h.review.interpret()
            await h.review.waitForIdle()
            #expect(h.review.message == status.message && h.provider.inputs.isEmpty)
        }
        h.defaults.set("true", forKey: CommandReviewSession.preferenceKey)
        #expect(!h.review.enabled)
        h.defaults.set(1, forKey: CommandReviewSession.preferenceKey)
        #expect(!h.review.enabled)
    }
    @Test func interpretationNeverDispatchesAndExplicitRunConsumesTheTicketOnce() async throws {
        let h = try ReviewHarness(); defer { h.remove() }
        h.enable(); await h.propose("Set volume to 50", action: "volume", argument: "50")
        let proposal = try #require(h.review.proposal)
        #expect(h.commands.isEmpty && proposal.exact == "volume 50")
        #expect(h.review.run(ticket: proposal.ticket) == .success(.volume(50)))
        #expect(h.review.run(ticket: proposal.ticket) == .failure(.stale))
        #expect(h.commands == [.volume(50)])
    }
    @Test func editsAndReopenRevokeSynchronouslyButCannotAccumulateUncancelledGenerations() async throws {
        let gate = CommandGenerationGate()
        let h = try ReviewHarness(gate: gate); defer { h.remove() }
        h.enable(); h.review.present(); h.review.edit("Please pause"); h.review.interpret()
        await h.provider.waitForInput()
        let pending = h.review.task
        h.review.edit("Please next")
        #expect(h.review.proposal == nil && h.review.isBusy && gate.isBusy)
        h.review.invalidate(); h.review.present(); h.review.edit("Please next"); h.review.interpret()
        #expect(h.provider.inputs == ["Please pause"])
        h.provider.respond(.init(action: "pause", argument: "", disposition: "single"))
        await pending?.value
        #expect(!h.review.isBusy && !gate.isBusy && h.review.proposal == nil && h.commands.isEmpty)
    }
    @Test func globalAdmissionProtectsIndependentProfileControllers() async throws {
        let gate = CommandGenerationGate()
        let first = try ReviewHarness(gate: gate), second = try ReviewHarness(gate: gate)
        defer { first.remove(); second.remove() }
        first.enable(); first.review.present(); first.review.edit("Please pause"); first.review.interpret()
        await first.provider.waitForInput()
        second.enable(); second.review.present(); second.review.edit("Please next"); second.review.interpret()
        await second.review.waitForIdle()
        #expect(second.provider.inputs.isEmpty && second.review.proposal == nil)
        #expect(second.review.message == ReviewedCommandIssue.busy.message)
        first.review.invalidate()
        first.provider.respond(.init(action: "pause", argument: "", disposition: "single"))
        await first.review.waitForIdle()
        #expect(!gate.isBusy)
    }
    @Test func disableWhileRunningDropsEvenAnUncancellableReplyAndLeavesOtherProfilesOff() async throws {
        let h = try ReviewHarness(), other = try ReviewHarness()
        defer { h.remove(); other.remove() }
        h.enable(); h.review.present(); h.review.edit("Please pause"); h.review.interpret()
        await h.provider.waitForInput()
        h.review.setEnabled(false, expectedGeneration: h.quick.scope.accountGeneration)
        #expect(h.review.proposal == nil && !h.review.isPresented && !h.review.enabled && !other.review.enabled)
        h.provider.respond(.init(action: "pause", argument: "", disposition: "single"))
        await h.review.waitForIdle()
        #expect(h.review.proposal == nil && h.commands.isEmpty)
        h.review.setEnabled(true, expectedGeneration: UUID())
        #expect(!h.review.enabled)
    }
    @Test func everyCapturedStateBoundaryRejectsAStaleProposalBeforeRun() async throws {
        for change in 0..<7 {
            let h = try ReviewHarness(); defer { h.remove() }
            h.enable(); await h.propose("Set volume to 50", action: "volume", argument: "50")
            let ticket = try #require(h.review.proposal?.ticket)
            switch change {
            case 0: h.quick = ReviewHarness.quick()
            case 1: h.profile = "different-local-profile"
            case 2: h.quick.ready = false
            case 3: h.quick.occurrence = .init(sessionID: UUID(), entryID: UUID(), trackID: "fixture", generation: 1)
            case 4: h.quick.shuttingDown = true
            case 5: h.queue.append([.init(id: "fixture", title: "Fixture", artist: "Fixture")])
            default:
                let old = h.quick
                h.quick = .init(scope: .init(accountGeneration: old.scope.accountGeneration, profile: old.scope.profile, startupIntent: UUID()),
                               ready: old.ready, signedIn: old.signedIn, hasQueue: old.hasQueue)
            }
            #expect(h.review.run(ticket: ticket) == .failure(.stale))
            #expect(h.commands.isEmpty && h.review.proposal == nil)
        }
    }
    @Test func freshExistingCommandValidationAndReentrantConsumptionRemainEffective() async throws {
        let h = try ReviewHarness(); defer { h.remove() }
        h.enable(); await h.propose("Please next", action: "next", argument: "")
        let noOccurrence = try #require(h.review.proposal?.ticket)
        #expect(h.review.run(ticket: noOccurrence) == .failure(.noCurrentOccurrence))
        await h.propose("Set volume to 50", action: "volume", argument: "50")
        let ticket = try #require(h.review.proposal?.ticket)
        h.review.execute = { command, _ in
            h.commands.append(command)
            #expect(h.review.run(ticket: ticket) == .failure(.stale))
        }
        #expect(h.review.run(ticket: ticket) == .success(.volume(50)))
        #expect(h.commands == [.volume(50)])
    }
    @Test func arbitraryProviderErrorsAreFixedCopyAndNeverBlindlyRetried() async throws {
        struct PrivateFailure: Error {}
        let h = try ReviewHarness(); defer { h.remove() }
        h.enable(); h.review.present(); h.review.edit("Please pause"); h.review.interpret()
        await h.provider.waitForInput()
        h.provider.fail(PrivateFailure())
        await h.review.waitForIdle()
        #expect(h.review.message == ReviewedCommandIssue.failed.message)
        #expect(h.provider.inputs.count == 1 && h.commands.isEmpty)
    }
    @Test func oversizedOrControlCharacterInputNeverReachesTheProviderAndCannotRunAPrefix() throws {
        let h = try ReviewHarness(); defer { h.remove() }
        h.enable(); h.review.present()
        for input in ["Please pause\nthen next", "Set volume to 50" + String(repeating: " ", count: 1_000)] {
            h.review.edit(input); h.review.interpret()
            #expect(h.review.task == nil && h.review.proposal == nil)
            #expect(h.review.message == ReviewedCommandIssue.invalid.message)
        }
        #expect(h.provider.inputs.isEmpty && h.provider.availabilityReads == 0 && h.commands.isEmpty)
    }
    @Test func extraReviewScopeIsReadAgainInsideTheExistingDispatcher() async throws {
        let h = try ReviewHarness(); defer { h.remove() }
        h.enable(); await h.propose("Set volume to 50", action: "volume", argument: "50")
        let ticket = try #require(h.review.proposal?.ticket)
        var reads = 0
        h.review.environment = {
            reads += 1
            if reads == 3 { h.profile = "changed-during-dispatch" }
            return .init(quick: h.quick, localProfile: h.profile, queueRevision: h.queue.revision)
        }
        #expect(h.review.run(ticket: ticket) == .failure(.stale))
        #expect(h.commands.isEmpty)
    }
    @Test func changedStartupIntentAndAccountDuringGenerationCannotPublishOrRun() async throws {
        let h = try ReviewHarness(); defer { h.remove() }
        h.enable(); h.review.present(); h.review.edit("Please pause"); h.review.interpret()
        await h.provider.waitForInput()
        h.quick = ReviewHarness.quick()
        h.provider.respond(.init(action: "pause", argument: "", disposition: "single"))
        await h.review.waitForIdle()
        #expect(h.review.proposal == nil && h.commands.isEmpty)
    }
    @Test func nativeAccountGenerationAndProfileQuiesceClearInputBeforeWaitingForTheProvider() async throws {
        let preferences = SceneCheckPreferences(); defer { preferences.remove() }
        let provider = ReviewProvider()
        var configuration = AppSessionConfiguration.sceneCheck(preferences: preferences.defaults, transport: SceneCheckTransport())
        configuration.commandInterpreter = provider; configuration.commandGenerationGate = CommandGenerationGate()
        let session = AppSession(configuration: configuration)
        session.commandReview.setEnabled(true, expectedGeneration: session.accountGeneration)
        session.commandReview.present(); session.commandReview.edit("Please pause"); session.commandReview.interpret()
        await provider.waitForInput()
        session.accountGeneration = UUID()
        #expect(!session.commandReview.isPresented && session.commandReview.input.isEmpty && session.commandReview.proposal == nil)
        provider.respond(.init(action: "pause", argument: "", disposition: "single"))
        await session.commandReview.waitForIdle()
        session.commandReview.present(); session.commandReview.edit("Please next")
        session.quiesceForProfileSwitch()
        #expect(!session.commandReview.isPresented && session.commandReview.input.isEmpty)
        #expect(!session.acceptsProfileActions && provider.inputs.count == 1)
        await session.shutdown()
    }
}

@MainActor private final class ReviewProvider: CommandInterpreting {
    var status: LocalCommandAvailability = .available
    private(set) var availabilityReads = 0
    private(set) var inputs: [String] = []
    private var reply: CheckedContinuation<CommandInterpretation, any Error>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    func availability() -> LocalCommandAvailability { availabilityReads += 1; return status }
    func interpret(_ input: String) async throws -> CommandInterpretation {
        inputs.append(input)
        arrivals.forEach { $0.resume() }; arrivals.removeAll()
        return try await withCheckedThrowingContinuation { reply = $0 }
    }
    func waitForInput() async {
        if reply != nil { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func respond(_ output: CommandInterpretation) { let pending = reply; reply = nil; pending?.resume(returning: output) }
    func fail(_ error: any Error) { let pending = reply; reply = nil; pending?.resume(throwing: error) }
}

@MainActor private final class ReviewHarness {
    let domain = "CommandReviewTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let provider = ReviewProvider()
    let review: CommandReviewSession
    var quick = ReviewHarness.quick()
    var profile = "fixture-local-profile"
    var queue = PlaybackQueue()
    var commands: [QuickCommand] = []
    init(gate: CommandGenerationGate = CommandGenerationGate()) throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        review = CommandReviewSession(preferences: defaults, interpreter: provider, gate: gate)
        review.environment = { [weak self] in
            guard let self else { return nil }
            return .init(quick: self.quick, localProfile: self.profile, queueRevision: self.queue.revision)
        }
        review.execute = { [weak self] command, _ in self?.commands.append(command) }
    }
    static func quick() -> QuickCommandEnvironment {
        .init(scope: .init(accountGeneration: UUID(), profile: "fixture-account", startupIntent: UUID()), ready: true, signedIn: true, hasQueue: true)
    }
    func enable() { review.setEnabled(true, expectedGeneration: quick.scope.accountGeneration) }
    func propose(_ input: String, action: String, argument: String) async {
        review.present(); review.edit(input); review.interpret()
        await provider.waitForInput()
        provider.respond(.init(action: action, argument: argument, disposition: "single"))
        await review.waitForIdle()
    }
    func remove() { defaults.removePersistentDomain(forName: domain) }
}
