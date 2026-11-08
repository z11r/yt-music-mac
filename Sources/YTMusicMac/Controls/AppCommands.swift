import AppKit
import SwiftUI

/// The Playback menu. Each item calls the same session action as the player
/// bar, the menu bar extra, the Dock menu, and Control Center.
struct PlaybackCommands: Commands {
    let session: AppSession
    let keyboardFocus: KeyboardFocusMonitor

    var body: some Commands {
        CommandMenu("Playback") {
            Button(session.player.isPlaying || session.player.isBuffering ? "Pause" : "Play") {
                keyboardFocus.run(.playPause, action: session.togglePlayback)
            }
            .keyboardShortcut(shortcut(.playPause))
            .disabled(session.currentTrack == nil)
            Button("Next Song") { keyboardFocus.run(.nextSong, action: session.next) }
                .keyboardShortcut(shortcut(.nextSong))
                .disabled(!session.queue.hasNext)
            Button("Previous Song") { keyboardFocus.run(.previousSong, action: session.previous) }
                .keyboardShortcut(shortcut(.previousSong))
                .disabled(session.currentTrack == nil)
            Divider()
            Button("Volume Up") { keyboardFocus.run(.volumeUp, action: session.increaseVolume) }
                .keyboardShortcut(shortcut(.volumeUp))
            Button("Volume Down") { keyboardFocus.run(.volumeDown, action: session.decreaseVolume) }
                .keyboardShortcut(shortcut(.volumeDown))
            Button(session.player.volume == 0 ? "Unmute" : "Mute", action: session.toggleMute)
            Divider()
            Button(session.queue.isShuffled ? "Turn Shuffle Off" : "Turn Shuffle On") { session.toggleShuffle() }
            Button("Repeat: \(session.queue.repeatMode.rawValue.capitalized)") { session.cycleRepeat() }
            Divider()
            Button("Undo Queue Edit") { session.undoQueueEdit() }.disabled(!session.queue.canUndo)
        }
    }

    /// Reading the focus here updates the menu when a text field or control
    /// gains or loses focus.
    private func shortcut(_ shortcut: PlaybackShortcut) -> KeyboardShortcut? {
        shortcut.keyboardShortcut(for: keyboardFocus.focus)
    }
}

/// Sidebar destinations reachable with Command and a number, as in Music.
enum NavigationShortcut: CaseIterable, Sendable {
    case home, explore, library, likedSongs

    var destination: MusicDestination {
        switch self {
        case .home: .home
        case .explore: .explore
        case .library: .library
        case .likedSongs: .likedSongs
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .home: "1"
        case .explore: "2"
        case .library: "3"
        case .likedSongs: "4"
        }
    }
}

struct NavigationCommands: Commands {
    let session: AppSession

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            NavigationCommandButtons(session: session)
            Divider()
        }
    }
}

private struct NavigationCommandButtons: View {
    let session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(NavigationShortcut.allCases, id: \.self) { item in
            Button(item.destination.title) {
                openWindow(id: "main")
                session.show(item.destination)
            }
            .keyboardShortcut(item.key, modifiers: .command)
            // The account sheet covers the sidebar; leave navigation to it.
            .disabled(session.showsAccount)
        }
    }
}
