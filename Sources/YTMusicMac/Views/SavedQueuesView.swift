import AppKit
import MusicCore
import SwiftUI
import UniformTypeIdentifiers

struct SavedQueuesView: View {
    let session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selection: UUID?
    @State private var pendingOpen: NamedQueue?
    @State private var pendingDelete: NamedQueue?
    @State private var renamedQueue: NamedQueue?
    @State private var renamedName = ""
    @State private var displayedScope: UUID

    init(session: AppSession) {
        self.session = session
        _displayedScope = State(initialValue: session.savedQueues.scope)
    }

    private var selected: NamedQueue? { session.savedQueues.queues.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Saved Queues").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Stored on this Mac for the signed-in account. Opening replaces the current queue without starting playback.")
                .font(.callout).foregroundStyle(.secondary)
            if session.account.isSignedIn && displayedScope == session.savedQueues.scope {
                HStack {
                    TextField("Name for current queue", text: $name)
                        .textFieldStyle(.roundedBorder)
                    Button("Save Current Queue") {
                        let snapshot = session.savedQueueSnapshot()
                        let scope = displayedScope
                        let title = name
                        Task { if await session.savedQueues.save(name: title, snapshot: snapshot, expectedScope: scope) { name = "" } }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.queue.isEmpty || session.savedQueues.isWorking)
                }
                List(session.savedQueues.queues, selection: $selection) { saved in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(saved.name).fontWeight(.medium)
                        Text("\(saved.snapshot.entries.count) songs · \(saved.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(saved.id)
                    .accessibilityElement(children: .combine)
                }
                .overlay {
                    if session.savedQueues.queues.isEmpty && !session.savedQueues.isWorking {
                        ContentUnavailableView("No Saved Queues", systemImage: "text.badge.plus",
                                               description: Text("Save the current queue to return to it later."))
                    }
                }
                HStack {
                    Button("Open…") { pendingOpen = selected }
                        .disabled(selected == nil || session.savedQueues.isWorking)
                    Button("Rename…") { renamedQueue = selected; renamedName = selected?.name ?? "" }
                        .disabled(selected == nil || session.savedQueues.isWorking)
                    Button("Delete…", role: .destructive) { pendingDelete = selected }
                        .disabled(selected == nil || session.savedQueues.isWorking)
                    Spacer()
                    if session.savedQueues.isWorking { ProgressView().controlSize(.small) }
                    Button("Refresh") { Task { await session.savedQueues.refresh(expectedScope: displayedScope) } }
                        .disabled(session.savedQueues.isWorking)
                }
                HStack {
                    Button("Import Metadata…", action: chooseImport)
                        .disabled(session.savedQueues.isWorking)
                    Button("Export Metadata…", action: chooseExport)
                        .disabled(selected == nil || session.savedQueues.isWorking)
                    Text("Song information and YouTube Music links")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("Sign In to Use Saved Queues", systemImage: "person.crop.circle",
                                       description: Text("Saved queues are kept separate for each confirmed account."))
                Button("Sign In") { dismiss(); session.openAccount() }
            }
            if let error = session.savedQueues.errorMessage { InlineMessage(message: error) }
            Text("Signing out clears the current queue. Named saved queues stay on this Mac until you delete them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 450, idealHeight: 500)
        .task { await session.savedQueues.refresh(expectedScope: displayedScope) }
        .onChange(of: session.savedQueues.scope) { dismiss() }
        .confirmationDialog("Replace the current queue?", isPresented: Binding(
            get: { pendingOpen != nil }, set: { if !$0 { pendingOpen = nil } }
        ), titleVisibility: .visible) {
            if let saved = pendingOpen {
                Button("Open \(saved.name)") {
                    let scope = displayedScope
                    Task { if await session.openSavedQueue(id: saved.id, expectedScope: scope) { dismiss() } }
                }
            }
            Button("Cancel", role: .cancel) { pendingOpen = nil }
        } message: { Text("Playback will pause. The saved queue opens without autoplay.") }
        .confirmationDialog("Delete this saved queue?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            if let saved = pendingDelete {
                Button("Delete \(saved.name)", role: .destructive) {
                    let scope = displayedScope
                    Task { _ = await session.savedQueues.remove(id: saved.id, expectedScope: scope) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("This deletes the local snapshot. Your YouTube Music playlists are unchanged.") }
        .alert("Rename Saved Queue", isPresented: Binding(
            get: { renamedQueue != nil }, set: { if !$0 { renamedQueue = nil } }
        )) {
            TextField("Name", text: $renamedName)
            Button("Save") {
                if let saved = renamedQueue {
                    let scope = displayedScope
                    let title = renamedName
                    Task { _ = await session.savedQueues.rename(id: saved.id, name: title, expectedScope: scope) }
                }
            }
            Button("Cancel", role: .cancel) { renamedQueue = nil }
        }
    }

    private func chooseImport() {
        let scope = displayedScope
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = AppLocalization.text("Import song information and links as a new local saved queue.")
        panel.begin { response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                _ = await session.savedQueues.importQueue(from: url, expectedScope: scope)
            }
        }
    }

    private func chooseExport() {
        guard let selected else { return }
        let scope = displayedScope
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = selected.name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-") + ".json"
        panel.message = AppLocalization.text("Export song information and links without account information or playback position.")
        panel.begin { response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                _ = await session.savedQueues.exportQueue(id: selected.id, to: url, expectedScope: scope)
            }
        }
    }
}
