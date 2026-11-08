import CoreFoundation
import Foundation
import MusicCore
import Observation

struct CommandReviewEnvironment {
    let quick: QuickCommandEnvironment
    let localProfile: String
    let queueRevision: QueueRevision
    var snapshot: CommandReviewScope {
        .init(quick: quick.scope, localProfile: localProfile, occurrence: quick.occurrence,
              queueRevision: queueRevision, ready: quick.ready, signedIn: quick.signedIn)
    }
}
struct CommandReviewScope: Equatable {
    let quick: QuickCommandScope
    let localProfile: String
    let occurrence: PlaybackOccurrence?
    let queueRevision: QueueRevision
    let ready: Bool
    let signedIn: Bool
}
struct CommandReviewTicket: Equatable { let request: UUID; let inputRevision: UInt64 }
struct ReviewedCommandProposal: Equatable {
    let command: QuickCommand
    let exact: String
    let ticket: CommandReviewTicket
}

@MainActor @Observable final class CommandReviewSession {
    static let preferenceKey = "onDeviceCommandInterpretationEnabled"
    private(set) var isPresented = false
    private(set) var input = ""
    private(set) var proposal: ReviewedCommandProposal?
    private(set) var message: String?
    private(set) var isBusy = false
    private var consentRevision: UInt64 = 0
    @ObservationIgnored var environment: () -> CommandReviewEnvironment? = { nil }
    @ObservationIgnored var execute: (QuickCommand, QuickCommandEnvironment) -> Void = { _, _ in }
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let interpreter: any CommandInterpreting
    @ObservationIgnored private let gate: CommandGenerationGate
    @ObservationIgnored private var request = UUID()
    @ObservationIgnored private var inputRevision: UInt64 = 0
    @ObservationIgnored private var owner: CommandReviewScope?
    @ObservationIgnored private var oversized = false
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(preferences: UserDefaults, interpreter: any CommandInterpreting = SystemCommandInterpreter(),
         gate: CommandGenerationGate = .shared) {
        self.preferences = preferences; self.interpreter = interpreter; self.gate = gate
    }

    var enabled: Bool {
        _ = consentRevision
        guard let value = preferences.object(forKey: Self.preferenceKey) as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }

    func setEnabled(_ value: Bool, expectedGeneration: UUID) {
        guard let current = environment(), !current.quick.shuttingDown,
              current.quick.scope.accountGeneration == expectedGeneration else { return }
        invalidate()
        preferences.set(value, forKey: Self.preferenceKey)
        consentRevision &+= 1
    }

    func present() {
        guard let current = environment(), !current.quick.shuttingDown else { return }
        invalidate()
        owner = current.snapshot; isPresented = true
        if !enabled { message = ReviewedCommandIssue.disabled.message }
        else if isBusy { message = ReviewedCommandIssue.busy.message }
    }

    func edit(_ value: String) {
        guard isPresented else { return }
        revoke()
        oversized = value.utf8.count > ReviewedCommandValidator.maximumInputBytes
        input = oversized ? String(decoding: value.utf8.prefix(ReviewedCommandValidator.maximumInputBytes + 1), as: UTF8.self) : value
        inputRevision &+= 1
        message = oversized ? ReviewedCommandIssue.invalid.message : isBusy ? ReviewedCommandIssue.busy.message : nil
    }

    func interpret() {
        guard enabled else { message = ReviewedCommandIssue.disabled.message; return }
        guard !isBusy, task == nil else { message = ReviewedCommandIssue.busy.message; return }
        guard !oversized, ReviewedCommandValidator.validInput(input) else { message = ReviewedCommandIssue.invalid.message; return }
        guard isPresented, let current = environment(), !current.quick.shuttingDown, current.snapshot == owner else {
            revoke(); message = ReviewedCommandIssue.stale.message; return
        }
        revoke()
        let ticket = CommandReviewTicket(request: request, inputRevision: inputRevision)
        let scope = current.snapshot
        let text = input
        proposal = nil; message = nil; isBusy = true
        task = Task { [weak self, interpreter, gate] in
            defer { self?.isBusy = false; self?.task = nil }
            guard let self, self.accepts(ticket, scope) else { return }
            let availability = interpreter.availability()
            guard self.accepts(ticket, scope) else { return }
            guard availability == .available else { self.message = availability.message; return }
            do {
                let output = try await gate.generate(using: interpreter, input: text)
                guard self.accepts(ticket, scope) else { return }
                let validated = try ReviewedCommandValidator.validate(output, input: text)
                self.proposal = .init(command: validated.command, exact: validated.exact, ticket: ticket)
            } catch {
                guard self.accepts(ticket, scope) else { return }
                self.message = (error as? ReviewedCommandIssue)?.message ?? ReviewedCommandIssue.failed.message
            }
        }
    }

    @discardableResult func run(ticket: CommandReviewTicket) -> Result<QuickCommand, QuickCommandIssue> {
        guard let proposal, proposal.ticket == ticket, let owner, accepts(ticket, owner) else {
            revoke(); message = ReviewedCommandIssue.stale.message
            return .failure(.stale)
        }
        // The existing exact parser, current-state validator and native dispatch
        // are reused. The review ticket is consumed before any reentrant action.
        let palette = QuickCommandPalette()
        palette.environment = { [weak self] in
            guard let self, self.enabled, let current = self.environment(), current.snapshot == owner else { return nil }
            return current.quick
        }
        palette.execute = execute
        palette.present(); palette.edit(proposal.exact)
        self.proposal = nil; request = UUID()
        let result = palette.run(ticket: palette.ticket)
        if case let .failure(issue) = result { message = issue.message }
        else { invalidate() }
        return result
    }

    func invalidate() {
        revoke(); isPresented = false; input = ""; owner = nil; oversized = false; message = nil
    }
    func cancel() { revoke(); message = isBusy ? ReviewedCommandIssue.busy.message : nil }
    func waitForIdle() async { await task?.value }

    private func revoke() { request = UUID(); proposal = nil; task?.cancel() }
    private func accepts(_ ticket: CommandReviewTicket, _ scope: CommandReviewScope) -> Bool {
        guard !Task.isCancelled, enabled, isPresented,
              ticket == CommandReviewTicket(request: request, inputRevision: inputRevision) else { return false }
        guard let current = environment(), !current.quick.shuttingDown, current.snapshot == scope else {
            revoke(); message = ReviewedCommandIssue.stale.message; return false
        }
        return true
    }
}
