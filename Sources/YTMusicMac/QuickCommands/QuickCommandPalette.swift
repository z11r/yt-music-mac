import Foundation
import MusicCore
import Observation

struct QuickCommandScope: Equatable {
    let accountGeneration: UUID
    let profile: String?
    let startupIntent: UUID
}
struct QuickCommandEnvironment {
    let scope: QuickCommandScope
    var ready = false
    var shuttingDown = false
    var signedIn = false
    var hasQueue = false
    var canPause = false
    var hasNext = false
    var occurrence: PlaybackOccurrence?
    var duration: Double = 0
}
struct QuickCommandTicket: Equatable {
    let presentation: UUID
    let inputRevision: UInt64
}

/// Synchronous, local parsing and dispatch. No command history, storage, tasks,
/// suggestions, timers, model inference, or service calls are owned here.
@MainActor @Observable final class QuickCommandPalette {
    private(set) var isPresented = false
    private(set) var input = ""
    private(set) var message: String?
    @ObservationIgnored var environment: () -> QuickCommandEnvironment? = { nil }
    @ObservationIgnored var execute: (QuickCommand, QuickCommandEnvironment) -> Void = { _, _ in }
    @ObservationIgnored private var scope: QuickCommandScope?
    @ObservationIgnored private var presentation = UUID()
    private(set) var inputRevision: UInt64 = 0
    @ObservationIgnored private var oversized = false
    var ticket: QuickCommandTicket { .init(presentation: presentation, inputRevision: inputRevision) }

    func present() {
        guard let environment = environment(), !environment.shuttingDown else { return }
        invalidate()
        scope = environment.scope; isPresented = true
    }
    func edit(_ value: String) {
        guard isPresented else { return }
        oversized = value.utf8.count > 1_024
        input = oversized ? String(decoding: value.utf8.prefix(1_025), as: UTF8.self) : value
        inputRevision &+= 1; message = oversized ? QuickCommandIssue.tooLong.message : nil
    }
    func invalidate() {
        presentation = UUID(); scope = nil; isPresented = false; input = ""; inputRevision = 0; oversized = false; message = nil
    }
    @discardableResult func run(ticket: QuickCommandTicket) -> Result<QuickCommand, QuickCommandIssue> {
        guard isPresented, self.ticket == ticket, let current = environment(), !current.shuttingDown, current.scope == scope else { return refuse(.stale) }
        if oversized { return refuse(.tooLong) }
        let command: QuickCommand
        switch QuickCommandParser.parse(input) {
        case let .failure(issue): return refuse(issue)
        case let .success(value): command = value
        }
        // Re-read immediately before dispatch; an injected or future asynchronous
        // owner must not turn a parsed request into another profile's action.
        guard let fresh = environment(), !fresh.shuttingDown, fresh.scope == current.scope,
              self.ticket == ticket, isPresented else { return refuse(.stale) }
        if let issue = Self.unavailable(command, in: fresh) { return refuse(issue) }
        invalidate() // Consume the UI request before calling a potentially reentrant action.
        execute(command, fresh)
        return .success(command)
    }
    private func refuse(_ issue: QuickCommandIssue) -> Result<QuickCommand, QuickCommandIssue> {
        if isPresented { message = issue.message }
        return .failure(issue)
    }
    static func unavailable(_ command: QuickCommand, in environment: QuickCommandEnvironment) -> QuickCommandIssue? {
        if command.needsStartup, !environment.ready { return .notReady }
        switch command {
        case .play:
            if !environment.hasQueue { return .noQueue }
            return environment.signedIn ? nil : .signIn
        case .pause: return environment.canPause ? nil : .noCurrentOccurrence
        case .next:
            if environment.occurrence == nil { return .noCurrentOccurrence }
            return environment.hasNext ? nil : .noNext
        case .previous, .timerEnd: return environment.occurrence == nil ? .noCurrentOccurrence : nil
        case let .seek(seconds):
            guard environment.occurrence != nil else { return .noCurrentOccurrence }
            guard environment.duration.isFinite, environment.duration > 0 else { return .cannotSeek }
            return Double(seconds) <= environment.duration ? nil : .seekOutOfRange
        default: return nil
        }
    }
}
