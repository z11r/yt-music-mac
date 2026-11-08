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
            RadioStatusView(session: session)
            if let message = session.player.videoPresentation.message {
                InlineMessage(message: message, actionTitle: "Dismiss", action: session.player.videoPresentation.clearMessage)
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
                        Button("Lyrics", systemImage: "text.quote") { openWindow(id: "lyrics") }
                            .help("Show lyrics").disabled(session.currentTrack == nil)
                        VideoPresentationMenu(session: session)
                        Button("Now Playing", systemImage: "arrow.up.left.and.arrow.down.right") { openWindow(id: "now-playing") }
                            .help("Open Now Playing")
                        Button("Mini-Player", systemImage: "pip") { openWindow(id: "mini-player") }
                            .help("Open Mini-Player")
                        AudioOutputPicker().frame(width: 20, height: 20)
                        Button(session.showsQueue ? "Hide Queue" : "Show Queue", systemImage: "list.bullet") { session.showsQueue.toggle() }
                            .foregroundStyle(session.showsQueue ? Color.accentColor : Color.secondary)
                            .accessibilityValue(session.showsQueue ? "Shown" : "Hidden")
                            .help(session.showsQueue ? "Hide Queue" : "Show Queue")
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    VolumeView(session: session).frame(width: 136)
                }
                .frame(width: 192)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            EpisodeControlsView(session: session)
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
            ArtworkView(url: session.currentTrack?.artworkURL, size: artworkSize, videoID: session.currentTrack?.id)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(session.currentTrack?.title ?? AppLocalization.text("Choose a song"))
                        .font(.headline).lineLimit(1)
                    if let track = session.currentTrack { ExplicitContentBadge(track: track) }
                }
                HStack(spacing: 5) {
                    if session.player.isBuffering {
                        ProgressView().controlSize(.mini).accessibilityLabel("Buffering")
                    }
                    Text(session.currentTrack?.artist ?? AppLocalization.text("Your music starts here"))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            if let track = session.currentTrack {
                TrackMetadataMenu(track: track, session: session)
                TrackRatingMenu(session: session, track: track)
            }
        }
        .accessibilityElement(children: .contain)
        .help([session.currentTrack?.title, session.currentTrack?.artist].compactMap { $0 }.joined(separator: " — "))
        .contextMenu {
            if let track = session.currentTrack {
                MusicLinkActions(track: track)
                TrackMetadataActions(track: track, session: session)
                TrackRatingActions(session: session, track: track)
            }
        }
    }
}

struct TransportButtons: View {
    let session: AppSession
    var prominent = true

    var body: some View {
        HStack(spacing: 20) {
            Button("Previous Song", systemImage: "backward.end.fill", action: session.previous)
                .help("Previous Song")
                .disabled(!session.queue.hasPrevious && !session.player.clock.isPastRestartThreshold)
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
            Button("Next Song", systemImage: "forward.end.fill", action: session.next)
                .help("Next Song")
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
    @State private var isWindowVisible = true
    @State private var coveredSeconds = 0

    private var duration: Double { session.player.clock.duration }
    /// A fully covered window shows its last value instead of observing the
    /// clock, so progress reports do not redraw it.
    private var position: Double {
        if isEditing { return proposedTime }
        return Double(isWindowVisible ? session.player.clock.elapsedSeconds : coveredSeconds)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(playbackTime(position)).frame(minWidth: 35, alignment: .trailing)
                .accessibilityHidden(true)
            // No `step`: a stepped slider draws one tick mark per second of the
            // song, and redrawing those dominated the app's playback CPU.
            Slider(value: Binding(get: { min(max(0, position), max(1, duration)) },
                                  set: {
                                      proposedTime = $0.rounded()
                                      if !isEditing { session.seek(to: proposedTime) }
                                  }), in: 0...max(1, duration)) { editing in
                if editing { proposedTime = session.player.clock.position }
                isEditing = editing
                if !editing { session.seek(to: proposedTime) }
            }
            .controlSize(.small)
            .disabled(duration <= 0 || session.currentTrack == nil)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(playbackTime(position)) elapsed of \(playbackTime(duration))")
            Text(duration > 0 ? playbackTime(duration) : "—").frame(minWidth: 35, alignment: .leading)
                .accessibilityHidden(true)
        }
        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        .onChange(of: session.queue.currentOccurrence) { isEditing = false; proposedTime = 0 }
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .onChange(of: isWindowVisible) {
            if !isWindowVisible { coveredSeconds = session.player.clock.elapsedSeconds }
        }
    }
}

/// Reports whether any part of the hosting window is visible on screen.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ReaderView { ReaderView() }

    func updateNSView(_ view: ReaderView, context: Context) {
        let binding = $isVisible
        view.onChange = { visible in
            if binding.wrappedValue != visible { binding.wrappedValue = visible }
        }
    }

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
            occlusionChanged()
        }

        @objc private func occlusionChanged() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            // Report after the current view update; state cannot change during one.
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }
    }
}

struct VolumeView: View {
    let session: AppSession
    var body: some View {
        HStack(spacing: 7) {
            Button(session.player.volume == 0 ? "Unmute" : "Mute",
                   systemImage: session.player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                   action: session.toggleMute)
            .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
            .help(session.player.volume == 0 ? "Unmute" : "Mute")
            // Keep the setter explicit for Swift 6.2's actor-isolated callback conversion.
            // No `step`, which would draw 101 tick marks; round in the setter instead.
            Slider(value: Binding(get: { session.player.volume },
                                  set: { value in session.setVolume((value * 100).rounded() / 100) }), in: 0...1)
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
            .modifier(PlaybackStateMark(isActive: session.queue.isShuffled))
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
            .modifier(PlaybackStateMark(isActive: session.queue.repeatMode != .off))
            .accessibilityValue(session.queue.repeatMode.localizedTitle)
            .help("Repeat: \(session.queue.repeatMode.localizedTitle)")
            .disabled(session.queue.entries.isEmpty)
    }
}

private struct PlaybackStateMark: ViewModifier {
    let isActive: Bool
    func body(content: Content) -> some View {
        content
            .frame(minWidth: 24, minHeight: 24)
            .overlay(alignment: .bottom) {
                if isActive {
                    Capsule().fill(.primary).frame(width: 10, height: 2)
                        .offset(y: 3).accessibilityHidden(true)
                }
            }
    }
}

struct MiniPlayerView: View {
    @Bindable var session: AppSession
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MiniPlayerWindowLevel.preferenceKey)
    private var keepsOnTop = false

    init(session: AppSession) {
        self.session = session
        _keepsOnTop = AppStorage(wrappedValue: false, MiniPlayerWindowLevel.preferenceKey, store: session.preferences)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                TrackIdentityView(session: session, artworkSize: 64)
                Spacer(minLength: 4)
                AudioOutputPicker().frame(width: 20, height: 20)
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
            CompactPlayerDestinations(session: session)
            if let message = session.player.errorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Button("Retry Playback", action: session.retryPlayback)
            }
        }
        .padding(20)
        .frame(minWidth: 350, idealWidth: 390, maxWidth: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowLevelSetter(level: MiniPlayerWindowLevel.level(keepsOnTop: keepsOnTop)).frame(width: 0, height: 0))
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
            CompactPlayerDestinations(session: session)
        }
        .buttonStyle(.borderless)
        .padding(16)
        .frame(width: 290)
    }
}
