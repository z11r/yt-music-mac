import AppKit
import MusicCore
import SwiftUI

func playbackTime(_ interval: TimeInterval) -> String {
    guard interval.isFinite, interval >= 0 else { return "0:00" }
    let seconds = Int(min(interval, 359_999))
    if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

struct PlayerBar: View {
    @Bindable var session: AppSession
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            if let message = session.player.errorMessage {
                InlineMessage(message: message, actionTitle: "Retry", action: session.retryPlayback)
            }
            HStack(spacing: 20) {
                TrackIdentityView(session: session, artworkSize: 50)
                    .frame(width: 215, alignment: .leading)
                VStack(spacing: 6) {
                    HStack(spacing: 18) {
                        ShuffleButton(session: session)
                        TransportButtons(session: session)
                        RepeatButton(session: session)
                    }
                    SeekView(session: session)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .trailing, spacing: 9) {
                    HStack(spacing: 14) {
                        Button("Open Web Player", systemImage: "play.rectangle") { session.showsWebPlayer.toggle() }
                            .accessibilityValue(session.showsWebPlayer ? "Shown" : "Hidden")
                            .disabled(session.currentTrack == nil)
                        Button("Mini-Player", systemImage: "pip") { openWindow(id: "mini-player") }
                        Button("Queue", systemImage: "list.bullet") { session.showsQueue.toggle() }
                            .foregroundStyle(session.showsQueue ? Color.accentColor : Color.secondary)
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    VolumeView(session: session).frame(width: 136)
                }
                .frame(width: 144)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
        }
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else { Rectangle().fill(.bar) }
        }
    }
}

struct TrackIdentityView: View {
    let session: AppSession
    var artworkSize: CGFloat = 48

    var body: some View {
        HStack(spacing: 11) {
            ArtworkView(url: session.currentTrack?.artworkURL, size: artworkSize)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.currentTrack?.title ?? "Choose a song")
                    .font(.headline).lineLimit(1)
                HStack(spacing: 5) {
                    if session.player.isBuffering {
                        ProgressView().controlSize(.mini).accessibilityLabel("Buffering")
                    }
                    Text(session.currentTrack?.artist ?? "Your music starts here")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .help([session.currentTrack?.title, session.currentTrack?.artist].compactMap { $0 }.joined(separator: " — "))
    }
}

struct TransportButtons: View {
    let session: AppSession
    var prominent = true

    var body: some View {
        HStack(spacing: 20) {
            Button("Previous", systemImage: "backward.end.fill", action: session.previous)
                .disabled(!session.queue.hasPrevious && session.player.clock.position <= 3)
            Button(action: session.togglePlayback) {
                Image(systemName: session.player.isPlaying || session.player.isBuffering ? "pause.fill" : "play.fill")
                    .font(.system(size: prominent ? 18 : 15, weight: .semibold))
                    .frame(width: prominent ? 34 : 26, height: prominent ? 34 : 26)
                    .background {
                        if prominent { Circle().fill(.primary.opacity(0.07)) }
                    }
            }
            .accessibilityLabel(session.player.isPlaying || session.player.isBuffering ? "Pause" : "Play")
            .accessibilityValue(session.player.isBuffering ? "Buffering" : "")
            .help(session.player.isPlaying || session.player.isBuffering ? "Pause" : "Play")
            .disabled(session.queue.isEmpty)
            Button("Next", systemImage: "forward.end.fill", action: session.next)
                .disabled(!session.queue.hasNext)
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
    }
}

struct SeekView: View {
    let session: AppSession
    @State private var isEditing = false
    @State private var proposedTime: Double = 0

    private var duration: Double { session.player.clock.duration }
    private var position: Double { isEditing ? proposedTime : session.player.clock.position }

    var body: some View {
        HStack(spacing: 8) {
            Text(playbackTime(position)).frame(minWidth: 35, alignment: .trailing)
            Slider(value: Binding(get: { min(max(0, position), max(1, duration)) },
                                  set: {
                                      proposedTime = $0
                                      if !isEditing { session.seek(to: $0) }
                                  }), in: 0...max(1, duration)) { editing in
                if editing { proposedTime = session.player.clock.position }
                isEditing = editing
                if !editing { session.seek(to: proposedTime) }
            }
            .controlSize(.small)
            .disabled(duration <= 0 || session.currentTrack == nil)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(playbackTime(position)) of \(playbackTime(duration))")
            Text(duration > 0 ? playbackTime(duration) : "—").frame(minWidth: 35, alignment: .leading)
        }
        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        .onChange(of: session.queue.currentOccurrence) { isEditing = false; proposedTime = 0 }
    }
}

struct VolumeView: View {
    let session: AppSession
    @State private var previousVolume: Double = 0.7
    var body: some View {
        HStack(spacing: 7) {
            Button(session.player.volume == 0 ? "Unmute" : "Mute",
                   systemImage: session.player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                if session.player.volume == 0 { session.setVolume(previousVolume) }
                else { previousVolume = session.player.volume; session.setVolume(0) }
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
            // Keep the setter explicit for Swift 6.2's actor-isolated callback conversion.
            Slider(value: Binding(get: { session.player.volume },
                                  set: { value in session.setVolume(value) }), in: 0...1)
                .controlSize(.small).accessibilityLabel("Volume")
                .accessibilityValue("\(Int(session.player.volume * 100)) percent")
        }
    }
}

struct ShuffleButton: View {
    let session: AppSession
    var body: some View {
        Button("Shuffle", systemImage: "shuffle", action: session.toggleShuffle)
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .foregroundStyle(session.queue.isShuffled ? Color.accentColor : Color.secondary)
            .accessibilityValue(session.queue.isShuffled ? "On" : "Off")
            .help(session.queue.isShuffled ? "Turn Shuffle Off" : "Turn Shuffle On")
            .disabled(session.queue.entries.isEmpty)
    }
}

struct RepeatButton: View {
    let session: AppSession
    var body: some View {
        Button("Repeat", systemImage: session.queue.repeatMode == .one ? "repeat.1" : "repeat",
               action: session.cycleRepeat)
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .foregroundStyle(session.queue.repeatMode == .off ? Color.secondary : Color.accentColor)
            .accessibilityValue(session.queue.repeatMode.rawValue.capitalized)
            .help("Repeat: \(session.queue.repeatMode.rawValue.capitalized)")
            .disabled(session.queue.entries.isEmpty)
    }
}

struct MiniPlayerView: View {
    @Bindable var session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                TrackIdentityView(session: session, artworkSize: 64)
                Spacer(minLength: 4)
                Button("Open Main Window", systemImage: "arrow.up.left.and.arrow.down.right") {
                    openWindow(id: "main")
                }.labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            HStack(spacing: 24) {
                ShuffleButton(session: session)
                Spacer(minLength: 0)
                TransportButtons(session: session)
                Spacer(minLength: 0)
                RepeatButton(session: session)
            }
            SeekView(session: session)
            if let message = session.player.errorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Button("Retry Playback", action: session.retryPlayback)
            }
        }
        .padding(20)
        .frame(minWidth: 350, idealWidth: 390, maxWidth: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct MenuBarPlayerView: View {
    @Bindable var session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            TrackIdentityView(session: session, artworkSize: 52)
            HStack {
                Spacer()
                TransportButtons(session: session, prominent: false)
                Spacer()
            }
            VolumeView(session: session)
            Divider()
            Button("Open YT Music for Mac", systemImage: "macwindow") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Mini-Player", systemImage: "pip") { openWindow(id: "mini-player") }
        }
        .buttonStyle(.borderless)
        .padding(16)
        .frame(width: 290)
    }
}
