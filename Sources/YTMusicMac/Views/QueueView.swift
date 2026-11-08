import MusicCore
import SwiftUI

struct QueueView: View {
    let session: AppSession
    @State private var selection: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Queue").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(session.queue.entries.count) songs").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(16)
            HStack(spacing: 16) {
                ShuffleButton(session: session)
                RepeatButton(session: session)
                Spacer()
                Button("Undo Queue Edit", systemImage: "arrow.uturn.backward", action: session.undoQueueEdit)
                    .disabled(!session.queue.canUndo)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                Menu {
                    Button("Play Selected") { playSelection(selection) }.disabled(selection.isEmpty)
                    Button("Move Up") { moveSelection(up: true) }.disabled(!canMove(up: true))
                    Button("Move Down") { moveSelection(up: false) }.disabled(!canMove(up: false))
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
            Divider()
            List(selection: $selection) {
                ForEach(Array(session.queue.entries.enumerated()), id: \.element.id) { index, entry in
                    queueRow(entry, index: index).tag(entry.id)
                }
                .onMove(perform: session.moveQueueEntries)
            }
            .listStyle(.inset)
            .accessibilityLabel("Playback queue")
            .contextMenu(forSelectionType: UUID.self) { ids in
                if !ids.isEmpty {
                    Button("Play") { playSelection(ids) }
                    if ids.count == 1, let entry = session.queue.entries.first(where: { ids.contains($0.id) }) {
                        Button("Start Radio") { session.startRadio(from: entry.track) }
                    }
                    Button("Remove from Queue") { session.removeQueueEntries(ids) }
                }
            } primaryAction: { ids in playSelection(ids) }
            .onDeleteCommand { removeSelection() }
            .overlay {
                if session.queue.isEmpty {
                    ContentUnavailableView("Your Queue Is Empty", systemImage: "music.note.list",
                                           description: Text("Play a song or add music to the queue."))
                }
            }
            if let message = session.queueError {
                InlineMessage(message: message)
            }
        }
        .onChange(of: session.queue.entries.map(\.id)) {
            selection.formIntersection(Set(session.queue.entries.map(\.id)))
        }
    }

    private func queueRow(_ entry: QueueEntry, index: Int) -> some View {
        HStack(spacing: 10) {
            ArtworkView(url: entry.track.artworkURL, size: 40, videoID: entry.track.id)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.track.title).fontWeight(entry.id == session.queue.currentEntryID ? .semibold : .regular)
                    .lineLimit(1)
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
        .accessibilityLabel("\(entry.track.title), \(entry.track.artist)")
        .accessibilityValue(queuePosition(entry, index: index))
        .help("\(entry.track.title) — \(entry.track.artist)")
        .accessibilityActions {
            Button("Play") { session.selectQueueEntry(entry.id) }
            Button("Start Radio") { session.startRadio(from: entry.track) }
            if index > 0 {
                Button("Move Up") { moveEntry(entry.id, up: true) }
            }
            if index + 1 < session.queue.entries.count {
                Button("Move Down") { moveEntry(entry.id, up: false) }
            }
            Button("Remove from Queue") { session.removeQueueEntries([entry.id]) }
        }
    }

    private func moveEntry(_ id: UUID, up: Bool) {
        guard let index = session.queue.entries.firstIndex(where: { $0.id == id }),
              up ? index > 0 : index + 1 < session.queue.entries.count else { return }
        session.moveQueueEntries(from: IndexSet(integer: index), to: up ? index - 1 : index + 2)
    }

    private func queuePosition(_ entry: QueueEntry, index: Int) -> String {
        let position = "\(index + 1) of \(session.queue.entries.count)"
        guard entry.id == session.queue.currentEntryID else { return position }
        return "\(session.player.isPlaying ? "Now playing" : "Current song"), \(position)"
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
        guard let first = offsets.first, let last = offsets.last else { return false }
        return up ? first > 0 : last < session.queue.entries.count - 1
    }

    private func moveSelection(up: Bool) {
        guard canMove(up: up), let first = offsets.first, let last = offsets.last else { return }
        session.moveQueueEntries(from: offsets, to: up ? first - 1 : last + 2)
    }

    private func removeSelection() {
        guard !selection.isEmpty else { return }
        session.removeQueueEntries(selection)
        selection.removeAll()
    }
}
