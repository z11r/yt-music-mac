import AppIntents

struct MusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumeMusicIntent(), phrases: ["Resume music in \(.applicationName)"],
                    shortTitle: "Resume Music", systemImageName: "play.fill")
        AppShortcut(intent: PauseMusicIntent(), phrases: ["Pause music in \(.applicationName)"],
                    shortTitle: "Pause Music", systemImageName: "pause.fill")
        AppShortcut(intent: NextSongIntent(), phrases: ["Next song in \(.applicationName)"],
                    shortTitle: "Next Song", systemImageName: "forward.end.fill")
        AppShortcut(intent: PreviousSongIntent(), phrases: ["Previous song in \(.applicationName)"],
                    shortTitle: "Previous Song", systemImageName: "backward.end.fill")
        AppShortcut(intent: SetMusicVolumeIntent(), phrases: ["Set music volume in \(.applicationName)"],
                    shortTitle: "Set Volume", systemImageName: "speaker.wave.2")
        AppShortcut(intent: PlaySongByIDIntent(), phrases: ["Play a song by ID in \(.applicationName)"],
                    shortTitle: "Play Song by ID", systemImageName: "music.note")
        AppShortcut(intent: OpenMusicLinkIntent(), phrases: ["Open a music link in \(.applicationName)"],
                    shortTitle: "Open Music Link", systemImageName: "link")
        AppShortcut(intent: SearchMusicIntent(), phrases: ["Search music in \(.applicationName)"],
                    shortTitle: "Search Music", systemImageName: "magnifyingglass")
    }
}

enum MusicShortcutRegistration {
    static func register() { MusicShortcuts.updateAppShortcutParameters() }
}
