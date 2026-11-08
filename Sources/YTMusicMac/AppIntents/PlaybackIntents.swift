import AppIntents
import Foundation

// AudioPlaybackIntent keeps transport in the app process. Foreground actions
// retain openAppWhenRun for the macOS 14 path; supportedModes requires macOS 26.
struct ResumeMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Music"
    static let description = IntentDescription("Resume the selected song in YT Music for Mac. Sign in in the app first.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        try await MusicAutomation.shared.perform(.resume)
        return .result()
    }
}

struct PauseMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause Music"
    static let description = IntentDescription("Pause playback in YT Music for Mac.")

    @MainActor func perform() async throws -> some IntentResult {
        try await MusicAutomation.shared.perform(.pause)
        return .result()
    }
}

struct NextSongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Song"
    static let description = IntentDescription("Select the next song in the current queue.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        try await MusicAutomation.shared.perform(.next)
        return .result()
    }
}

struct PreviousSongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Song"
    static let description = IntentDescription("Restart the current song, or select the previous song near the beginning.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        try await MusicAutomation.shared.perform(.previous)
        return .result()
    }
}

struct SetMusicVolumeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Set Music Volume"
    static let description = IntentDescription("Set the app's volume from 0 to 100 percent without changing the Mac's system volume.")
    @Parameter(title: "Volume", default: 70, inclusiveRange: (0, 100)) var percent: Double
    static var parameterSummary: some ParameterSummary { Summary("Set music volume to \(\.$percent) percent") }

    @MainActor func perform() async throws -> some IntentResult {
        try await MusicAutomation.shared.perform(.volume(percent))
        return .result()
    }
}

struct PlaySongByIDIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song by Video ID"
    static let description = IntentDescription("Look up an exact YouTube video ID and play only that recording. Sign in in the app first.")
    static let openAppWhenRun = true
    @Parameter(title: "Video ID") var videoID: String
    static var parameterSummary: some ParameterSummary { Summary("Play song with video ID \(\.$videoID)") }

    @MainActor func perform() async throws -> some IntentResult {
        try await MusicAutomation.shared.perform(.playVideo(videoID))
        return .result()
    }
}
