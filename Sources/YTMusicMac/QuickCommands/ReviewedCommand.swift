import Foundation
import MusicCore

struct CommandInterpretation: Equatable, Sendable {
    let action: String
    let argument: String
    let disposition: String

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4_096,
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys) == ["action", "argument", "disposition"],
              let action = fields["action"] as? String, let argument = fields["argument"] as? String,
              let disposition = fields["disposition"] as? String else { throw ReviewedCommandIssue.invalid }
        return .init(action: action, argument: argument, disposition: disposition)
    }
}

enum ReviewedCommandIssue: Error, Equatable {
    case invalid, ambiguous, sourceValue, busy, unavailable, failed, stale, disabled
    var message: String {
        switch self {
        case .invalid: AppLocalization.text("Use one short request within 512 UTF-8 bytes, without control characters.")
        case .ambiguous: AppLocalization.text("Only one supported action can be reviewed. Split compound requests or use an exact Quick Command.")
        case .sourceValue: AppLocalization.text("Use explicit digits for values, m:ss for positions, and double quotes around a search query. Values are never filled in for you.")
        case .busy: AppLocalization.text("The previous interpretation is still stopping. Wait for it to finish before trying again.")
        case .unavailable: AppLocalization.text("On-device interpretation is unavailable. Exact Quick Commands remain available.")
        case .failed: AppLocalization.text("The request could not be interpreted. Try one supported action or use an exact Quick Command.")
        case .stale: AppLocalization.text("The input, profile, account, startup state or recording changed. Close and reopen command review before interpreting again.")
        case .disabled: AppLocalization.text("Enable on-device command interpretation in Settings first.")
        }
    }
}

/// Model output is untrusted. Only a closed action and a source-backed argument
/// can become an existing exact command. This validator performs no dispatch.
enum ReviewedCommandValidator {
    static let maximumInputBytes = 512
    static let actions = ["play", "pause", "next", "previous", "open", "search", "volume", "seek", "timerMinutes", "timerEnd", "timerOff", "shuffleOn", "shuffleOff", "repeatOff", "repeatAll", "repeatOne"]

    static func validInput(_ input: String) -> Bool {
        !input.trimmingCharacters(in: .whitespaces).isEmpty && input.utf8.count <= maximumInputBytes &&
        !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func validate(_ output: CommandInterpretation, input: String) throws -> (command: QuickCommand, exact: String) {
        guard validInput(input), output.argument.utf8.count <= maximumInputBytes,
              !output.argument.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ReviewedCommandIssue.invalid }
        guard output.disposition == "single", actions.contains(output.action) else { throw ReviewedCommandIssue.ambiguous }
        var outside = input
        if output.action == "search" {
            let parts = input.split(separator: "\"", omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[1].isEmpty, String(parts[1]) == output.argument else { throw ReviewedCommandIssue.sourceValue }
            outside = String(parts[0]) + " " + String(parts[2])
        } else if input.contains("\"") { throw ReviewedCommandIssue.ambiguous }
        let normalized = outside.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard outside.rangeOfCharacter(from: CharacterSet(charactersIn: ";,|&/")) == nil,
              normalized.range(of: #"\b(and|then|also|after|before|et|puis|ensuite|apres|avant)\b"#, options: .regularExpression) == nil else { throw ReviewedCommandIssue.ambiguous }
        let exact: String
        switch output.action {
        case "search": exact = "search " + output.argument
        case "open":
            let argument = output.argument.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let token = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: argument) + #"(?![\p{L}\p{N}_])"#
            guard !argument.isEmpty, normalized.range(of: token, options: .regularExpression) != nil else { throw ReviewedCommandIssue.sourceValue }
            exact = "open " + output.argument
        case "volume", "seek", "timerMinutes":
            let expression = try NSRegularExpression(pattern: #"-?[0-9]+(?::[0-9]+)?(?:[.,][0-9]+)?"#)
            let matches = expression.matches(in: input, range: NSRange(input.startIndex..., in: input))
            guard matches.count == 1, let range = Range(matches[0].range, in: input), String(input[range]) == output.argument else { throw ReviewedCommandIssue.sourceValue }
            if output.action == "timerMinutes" {
                guard normalized.range(of: #"\b(min|minute|minutes|mn)\b"#, options: .regularExpression) != nil,
                      normalized.range(of: #"\b(hour|hours|heure|heures|second|seconds|seconde|secondes)\b"#, options: .regularExpression) == nil else { throw ReviewedCommandIssue.sourceValue }
                exact = "timer \(output.argument) min"
            } else { exact = output.action + " " + output.argument }
        default:
            guard output.argument.isEmpty, input.rangeOfCharacter(from: .decimalDigits) == nil else { throw ReviewedCommandIssue.sourceValue }
            let values = ["timerEnd": "timer end", "timerOff": "timer off", "shuffleOn": "shuffle on", "shuffleOff": "shuffle off",
                          "repeatOff": "repeat off", "repeatAll": "repeat all", "repeatOne": "repeat one"]
            exact = values[output.action] ?? output.action
        }
        guard case let .success(command) = QuickCommandParser.parse(exact) else { throw ReviewedCommandIssue.sourceValue }
        return (command, exact)
    }
}

enum LocalCommandAvailability: Equatable, Sendable {
    case available, requiresSystem, ineligibleDevice, notEnabled, notReady, unsupportedLanguage
    var message: String {
        switch self {
        case .available: AppLocalization.text("Ready for an explicit on-device interpretation.")
        case .requiresSystem: AppLocalization.text("On-device interpretation requires macOS 26 and an eligible Apple silicon Mac. Use exact Quick Commands here.")
        case .ineligibleDevice: AppLocalization.text("This Mac is not eligible for the on-device model. Use exact Quick Commands here.")
        case .notEnabled: AppLocalization.text("Apple Intelligence is not enabled on this Mac. Exact Quick Commands remain available.")
        case .notReady: AppLocalization.text("The on-device model is not ready. The app does not start a download; try again later or use exact Quick Commands.")
        case .unsupportedLanguage: AppLocalization.text("The on-device model does not support the current language. Use exact Quick Commands instead.")
        }
    }
}

@MainActor protocol CommandInterpreting {
    func availability() -> LocalCommandAvailability
    func interpret(_ input: String) async throws -> CommandInterpretation
}

/// One admission across local profiles. A cancelled generation retains its
/// admission until the underlying provider returns; there is no queued retry.
@MainActor final class CommandGenerationGate {
    static let shared = CommandGenerationGate()
    private(set) var isBusy = false
    func generate(using interpreter: any CommandInterpreting, input: String) async throws -> CommandInterpretation {
        guard !isBusy else { throw ReviewedCommandIssue.busy }
        try Task.checkCancellation()
        isBusy = true
        defer { isBusy = false }
        return try await interpreter.interpret(input)
    }
}
