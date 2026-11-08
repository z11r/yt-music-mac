import MusicCore
import SwiftUI

struct QueueView: View {
    let session: AppSession
    @State private var selection: Set<UUID> = []
    @State private var filter = ""
    @State private var showsSavedQueues = false
    @State private var playlistReview: QueuePlaylistReviewRequest?
    @State private var showsRecommendations = false

    private var isFiltering: Bool { !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var rows: [QueueDisplayRow] { QueuePresentation.rows(in: session.queue.entries, matching: filter) }
    private var visibleIDs: Set<UUID> { Set(rows.map(\.id)) }

    private var remainingDescription: String {
        let duration = QueuePresentation.remaining(in: session.queue, position: session.remainingQueuePosition,
            confirmedCurrentDuration: session.player.hasConfirmedPosition ? session.player.clock.duration : nil)
        guard duration.songCount > 0 else { return "" }
        if duration.knownSeconds == 0, duration.unknownCount > 0 { return AppLocalization.text("Remaining duration unknown") }
        let time: String
        if duration.knownSeconds > 3_599_999 { time = AppLocalization.text("more than 999 hours") }
        else if duration.knownSeconds >= 360_000 { time = AppLocalization.format("%lld hours", Int(duration.knownSeconds / 3_600)) }
        else { time = playbackTime(duration.knownSeconds) }
        return duration.unknownCount == 0 ? AppLocalization.format("%@ remaining", time)
            : AppLocalization.format("At least %@ remaining · %lld unknown", time, duration.unknownCount)
    }

    var body: some View {
        let hapticTarget = session.nativeQueueInteractionTarget
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Queue").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(isFiltering ? "\(rows.count) of \(session.queue.entries.count) entries" : "\(session.queue.entries.count) entries")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(16)
            HStack(spacing: 16) {
                ShuffleButton(session: session)
                RepeatButton(session: session)
                Spacer()
                Button("Undo Queue Edit", systemImage: "arrow.uturn.backward") { session.performNativeQueueInteraction(.undo, target: hapticTarget) }
                    .disabled(!session.queue.canUndo)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                Menu {
                    Button("Saved Queues…") { showsSavedQueues = true }
                    Button("Save Queue as Playlist…") {
                        playlistReview = QueuePlaylistReviewRequest(snapshot: session.savedQueueSnapshot(),
                            accountGeneration: session.accountGeneration, scope: session.queuePlaylistSave.scope)
                    }
                    Button("Preview Recommendations…") { showsRecommendations = true }
                        .disabled(!session.canPreviewRecommendations)
                    Divider()
                    Button("Play Selected") { playSelection(selection) }.disabled(selection.isEmpty)
                    Button("Move Up") { moveSelection(up: true, target: hapticTarget) }.disabled(!canMove(up: true))
                    Button("Move Down") { moveSelection(up: false, target: hapticTarget) }.disabled(!canMove(up: false))
                    Divider()
                    Button("Remove Selected") { removeSelection() }.disabled(selection.isEmpty)
                    Button("Clear Queue") {
                        session.removeQueueEntries(Set(session.queue.entries.map(\.id)))
                        selection.removeAll()
                    }.disabled(session.queue.isEmpty)
                } label: {
                    Label("Queue Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize().labelStyle(.iconOnly)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Filter queue", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter queue by song, artist, or album")
                if !remainingDescription.isEmpty {
                    Text(remainingDescription).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            List(selection: $selection) {
                ForEach(QueuePresentation.groups(in: rows)) { group in
                    Section(group.title) {
                        ForEach(group.rows) { row in
                            queueRow(row.entry, index: row.index).tag(row.id)
                                .moveDisabled(isFiltering)
                        }
                        .onMove { offsets, destination in
                            guard let move = QueuePresentation.move(in: group, offsets: offsets,
                                destination: destination, isFiltering: isFiltering) else { return }
                            session.performNativeQueueInteraction(.move(move.offsets, destination: move.destination), target: hapticTarget)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .accessibilityLabel("Playback queue")
            .contextMenu(forSelectionType: UUID.self) { ids in
                if !ids.isEmpty {
                    Button("Play") { playSelection(ids) }
                    if ids.count == 1, let entry = session.queue.entries.first(where: { ids.contains($0.id) }) {
                        if entry.track.isCatalogSong { Button("Start Radio") { session.startRadio(from: entry.track) } }
                    }
                    Button("Remove from Queue") { session.removeQueueEntries(ids) }
                    if ids.count == 1, let entry = session.queue.entries.first(where: { ids.contains($0.id) }) {
                        TrackRatingActions(session: session, track: entry.track)
                        TrackMetadataActions(track: entry.track, session: session)
                    }
                }
            } primaryAction: { ids in playSelection(ids) }
            .onDeleteCommand { removeSelection() }
            .overlay {
                if session.queue.isEmpty {
                    ContentUnavailableView("Your Queue Is Empty", systemImage: "music.note.list",
                                           description: Text("Play a song or add music to the queue."))
                } else if rows.isEmpty {
                    ContentUnavailableView("No Matching Songs", systemImage: "magnifyingglass",
                                           description: Text("Try a different song, artist, or album."))
                }
            }
            if let message = session.queueError {
                InlineMessage(message: message)
            }
        }
        .modifier(QueueSongDropTarget(session: session))
        .onChange(of: session.queue.entries.map(\.id)) {
            selection.formIntersection(visibleIDs)
        }
        .onChange(of: filter) {
            selection.formIntersection(visibleIDs)
        }
        .sheet(isPresented: $showsSavedQueues) { SavedQueuesView(session: session) }
        .sheet(item: $playlistReview) { QueuePlaylistSaveView(session: session, request: $0) }
        .sheet(isPresented: $showsRecommendations) { QueueRecommendationsView(session: session) }
        .onChange(of: session.savedQueues.scope) { showsSavedQueues = false }
        .onChange(of: session.queuePlaylistSave.scope) { playlistReview = nil }
    }

    private func queueRow(_ entry: QueueEntry, index: Int) -> some View {
        let hapticTarget = session.nativeQueueInteractionTarget
        return HStack(spacing: 10) {
            ArtworkView(url: entry.track.remoteArtworkURL, size: 40, videoID: entry.track.remoteArtworkVideoID)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(entry.track.title).fontWeight(entry.id == session.queue.currentEntryID ? .semibold : .regular)
                        .lineLimit(1)
                    ExplicitContentBadge(track: entry.track)
                }
                ContentOriginBadge(isUploaded: entry.track.origin == .upload)
                if entry.origin == .recommendation {
                    Label("Recommendation Added by You", systemImage: "sparkles").font(.caption2).foregroundStyle(.secondary)
                }
                if entry.track.contentKind == .podcastEpisode { Text("Episode").font(.caption2).foregroundStyle(.secondary) }
                Text(entry.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            if entry.id == session.queue.currentEntryID {
                Image(systemName: session.player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .font(.caption).foregroundStyle(Color.accentColor)
                    .accessibilityLabel(session.player.isPlaying ? "Now playing" : "Current song")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.track.title), \(entry.track.artist)\(entry.track.origin == .upload ? AppLocalization.text(", uploaded music") : "")\(entry.track.isExplicit == true ? AppLocalization.text(", Explicit content") : "")\(entry.origin == .recommendation ? AppLocalization.text(", recommendation added by you") : "")")
        .accessibilityValue(queuePosition(entry, index: index))
        .help("\(entry.track.title) — \(entry.track.artist)")
        .accessibilityActions {
            Button("Play") { session.selectQueueEntry(entry.id) }
            if entry.track.isCatalogSong { Button("Start Radio") { session.startRadio(from: entry.track) } }
            if !isFiltering && index > 0 {
                Button("Move Up") { moveEntry(entry.id, up: true, target: hapticTarget) }
            }
            if !isFiltering && index + 1 < session.queue.entries.count {
                Button("Move Down") { moveEntry(entry.id, up: false, target: hapticTarget) }
            }
            Button("Remove from Queue") { session.removeQueueEntries([entry.id]) }
            TrackRatingActions(session: session, track: entry.track)
            TrackMetadataActions(track: entry.track, session: session)
        }
    }

    private func moveEntry(_ id: UUID, up: Bool, target: NativeQueueInteractionTarget) {
        guard !isFiltering, let index = session.queue.entries.firstIndex(where: { $0.id == id }),
              up ? index > 0 : index + 1 < session.queue.entries.count else { return }
        session.performNativeQueueInteraction(.move(IndexSet(integer: index), destination: up ? index - 1 : index + 2), target: target)
    }

    private func queuePosition(_ entry: QueueEntry, index: Int) -> String {
        let position = AppLocalization.format("%lld of %lld", index + 1, session.queue.entries.count)
        guard entry.id == session.queue.currentEntryID else { return position }
        let state = session.player.isPlaying ? AppLocalization.text("Now playing") : AppLocalization.text("Current song")
        return AppLocalization.format("%@, %@", state, position)
    }

    private func playSelection(_ ids: Set<UUID>) {
        if let entry = session.queue.entries.first(where: { ids.contains($0.id) }) {
            session.selectQueueEntry(entry.id)
        }
    }

    private var offsets: IndexSet {
        IndexSet(session.queue.entries.indices.filter { selection.contains(session.queue.entries[$0].id) })
    }

    private func canMove(up: Bool) -> Bool {
        guard !isFiltering else { return false }
        guard let first = offsets.first, let last = offsets.last else { return false }
        return up ? first > 0 : last < session.queue.entries.count - 1
    }

    private func moveSelection(up: Bool, target: NativeQueueInteractionTarget) {
        guard canMove(up: up), let first = offsets.first, let last = offsets.last else { return }
        session.performNativeQueueInteraction(.move(offsets, destination: up ? first - 1 : last + 2), target: target)
    }

    private func removeSelection() {
        guard !selection.isEmpty else { return }
        session.removeQueueEntries(selection)
        selection.removeAll()
    }
}
