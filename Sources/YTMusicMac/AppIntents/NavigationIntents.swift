import AppIntents
import Foundation

struct OpenMusicLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Music Link"
    static let description = IntentDescription("Open a YouTube Music album, artist, or playlist, or play an exact song link. Song playback requires sign-in in the app.")
    static let openAppWhenRun = true
    @Parameter(title: "Music Link") var link: URL
    static var parameterSummary: some ParameterSummary { Summary("Open music link \(\.$link)") }

    @MainActor func perform() async throws -> some IntentResult {
        try await MusicAutomation.shared.perform(.openLink(link))
        return .result()
    }
}

struct SearchMusicIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Music"
    static let description = IntentDescription("Show catalog results for a search without automatically playing a result.")
    static let openAppWhenRun = true
    @Parameter(title: "Search") var query: String
    static var parameterSummary: some ParameterSummary { Summary("Search music for \(\.$query)") }

    @MainActor func perform() async throws -> some IntentResult {
        try await MusicAutomation.shared.perform(.search(query))
        return .result()
    }
}
