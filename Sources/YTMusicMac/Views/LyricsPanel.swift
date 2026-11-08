import SwiftUI
import YouTubeMusic

struct LyricsPanel: View {
    let session: AppSession
    @Environment(\.dismissWindow) private var dismissWindow

    private struct Target: Hashable {
        let videoID: String?
        let accountScope: UUID
    }

    private var visibleState: LyricsSession.State {
        if session.currentTrack?.hasLocalAudioSource == true { return .unavailable }
        guard session.lyrics.videoID == session.currentTrack?.id else {
            return session.currentTrack == nil ? .idle : .loading
        }
        return session.lyrics.state
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Lyrics").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    if let track = session.currentTrack {
                        Text(track.title).font(.headline)
                        Text(track.artist).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismissWindow(id: "lyrics") }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 430, idealWidth: 560, minHeight: 400, idealHeight: 620)
        .task(id: Target(videoID: session.currentTrack?.isServiceTrack == true ? session.currentTrack?.id : nil,
                         accountScope: session.libraryEditingScope)) {
            session.lyrics.load(track: session.currentTrack)
        }
        .onDisappear { session.lyrics.clear() }
    }

    @ViewBuilder private var content: some View {
        switch visibleState {
        case .idle:
            ContentUnavailableView("Choose a Song", systemImage: "music.note",
                                   description: Text("Lyrics appear here when available for the selected recording."))
        case .loading:
            ProgressView("Loading lyrics…")
        case .unavailable:
            ContentUnavailableView("No Lyrics Available", systemImage: "text.quote",
                description: Text("This recording may be instrumental, or YouTube Music may not supply its lyrics."))
        case let .failed(message):
            VStack(spacing: 14) {
                ContentUnavailableView("Couldn't Load Lyrics", systemImage: "wifi.exclamationmark", description: Text(message))
                Button("Try Again") { session.lyrics.retry() }
            }
            .padding(20)
        case let .available(lyrics):
            VStack(spacing: 0) {
                switch lyrics {
                case let .plain(text, _):
                    ScrollView {
                        Text(text).font(.title3).lineSpacing(8)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                    }
                case let .timed(lines, _):
                    TimedLyricsView(session: session, lyrics: lyrics, lines: lines)
                case .unavailable:
                    EmptyView()
                }
                Divider()
                Text(lyrics.source ?? AppLocalization.text("Provided by YouTube Music"))
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
    }
}

private struct TimedLyricsView: View {
    let session: AppSession
    let lyrics: MusicLyrics
    let lines: [MusicLyricLine]
    @State private var followsPlayback = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Reuse the existing display clock. The panel adds no polling timer or
    // WebKit process, and plain lyrics do not observe playback progress.
    private var activeLine: Int? { lyrics.activeLineIndex(at: Double(session.player.clock.elapsedSeconds)) }
    private var canSeek: Bool {
        session.player.clock.duration > 0 && session.lyrics.videoID == session.currentTrack?.id
    }

    var body: some View {
        let currentLine = activeLine
        VStack(spacing: 0) {
            Toggle("Follow Playback", isOn: $followsPlayback)
                .toggleStyle(.switch).controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 20).padding(.vertical, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Button {
                                guard canSeek, session.lyrics.videoID == session.currentTrack?.id else { return }
                                session.seek(to: line.startTime)
                            } label: {
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.title3.weight(index == currentLine ? .semibold : .regular))
                                    .foregroundStyle(index == currentLine ? Color.accentColor : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!canSeek || line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel(line.text)
                            .accessibilityValue(index == currentLine ? "Current lyric" : "")
                            .accessibilityHint(canSeek ? "Seeks to this lyric line" : "")
                            .id(index)
                        }
                    }
                    .padding(24)
                }
                .onAppear {
                    if followsPlayback, let currentLine { proxy.scrollTo(currentLine, anchor: .center) }
                }
                .onChange(of: currentLine) {
                    guard followsPlayback, let currentLine else { return }
                    if reduceMotion { proxy.scrollTo(currentLine, anchor: .center) }
                    else { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(currentLine, anchor: .center) } }
                }
                .onChange(of: followsPlayback) {
                    if followsPlayback, let currentLine { proxy.scrollTo(currentLine, anchor: .center) }
                }
            }
        }
    }
}
