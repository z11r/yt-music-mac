import MusicCore
import SwiftUI

struct StorageSettingsView: View {
    let session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var displayedScope: UUID
    @State private var artwork = MemoryCacheUsage(bytes: 0, count: 0)
    @State private var clearsArtwork = false
    @State private var clearsMetadata = false
    @State private var showsSnapshot = false

    init(session: AppSession) {
        self.session = session
        _displayedScope = State(initialValue: session.storage.scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Storage").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Refresh Usage") { Task { await refresh() } }.disabled(session.storage.isWorking)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Form {
                Section("Artwork Cache") {
                    LabeledContent("Decoded images in memory", value: AppLocalization.format("%@ · %lld images", bytes(artwork.bytes), artwork.count))
                    LabeledContent("Memory limit", value: AppLocalization.text("48 MiB · 160 images"))
                    LabeledContent("Artwork disk cache", value: AppLocalization.text("0 bytes · memory only"))
                    Button("Clear Cached Artwork…") { clearsArtwork = true }
                    Text("Usage counts decoded cache entries. Visible artwork stays available and browsing can refill the cache.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Library Metadata Cache") {
                    Toggle("Save read-only library metadata on this Mac", isOn: Binding(
                        get: { session.storage.metadataEnabled }, set: { session.storage.setMetadataEnabled($0) }))
                    Text("Saves names and IDs of loaded library collections. Snapshots expire after seven days; expired files stay until refreshed or cleared. Turning this off stops new snapshots. Listening requires a connection.")
                        .font(.caption).foregroundStyle(.secondary)
                    if session.account.isSignedIn && session.storage.scope == displayedScope {
                        LabeledContent("This account's metadata file", value: bytes(session.storage.metadataBytes))
                        LabeledContent("Limit per account", value: AppLocalization.text("2 MiB · 2,000 collections · 7 days"))
                        if let snapshot = session.storage.snapshot {
                            LabeledContent("Snapshot saved", value: snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened))
                            Button("Read Saved Library Metadata") {
                                Task {
                                    await session.storage.refresh(expectedScope: displayedScope)
                                    if session.storage.snapshot != nil { showsSnapshot = true }
                                }
                            }
                            .disabled(session.storage.isWorking)
                        } else {
                            Text("No unexpired snapshot is available. Open Library while connected to save its loaded collections.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Button("Clear Library Metadata Cache…", role: .destructive) { clearsMetadata = true }
                            .disabled(session.storage.isWorking || !session.storage.isAvailable)
                    } else {
                        Text("Sign in to a confirmed account to view its metadata cache.").foregroundStyle(.secondary)
                    }
                }
                if session.account.isSignedIn, let usage = session.storage.protectedUsage {
                    Section("Saved Data") {
                        LabeledContent("Local audio library metadata", value: bytes(usage.localAudioBytes))
                        LabeledContent("Current queue", value: bytes(usage.currentQueueBytes))
                        LabeledContent("Named queues for this account", value: bytes(usage.namedQueueBytes))
                        LabeledContent("Local collection organization", value: bytes(usage.organizationBytes))
                        LabeledContent("Local Song Rules", value: bytes(usage.songRuleBytes))
                        LabeledContent("Local episode progress", value: bytes(usage.episodeProgressBytes))
                        LabeledContent("ListenBrainz records", value: bytes(usage.listenBrainzBytes))
                        LabeledContent("Last.fm records", value: bytes(usage.lastFMBytes))
                        LabeledContent("Pending playlist save", value: bytes(usage.pendingPlaylistBytes))
                        Text("Cache clearing preserves saved data, credentials and the WebKit sign-in session. Manage queues, organization, song rules, episode progress, scrobbling and pending playlist saves in their own controls.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message = session.storage.errorMessage { InlineMessage(message: message) }
            }
            .formStyle(.grouped)
        }
        .padding(16).frame(width: 590, height: 650)
        .task { await refresh() }
        .onChange(of: session.storage.scope) { dismiss() }
        .confirmationDialog("Clear cached artwork?", isPresented: $clearsArtwork, titleVisibility: .visible) {
            Button("Clear Artwork Cache") {
                Task { await ArtworkCache.shared.clear(); artwork = ArtworkCache.shared.memory.usage() }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This clears decoded artwork kept in memory. Music and saved data stay available.") }
        .confirmationDialog("Clear this account's library metadata cache?", isPresented: $clearsMetadata, titleVisibility: .visible) {
            Button("Clear Metadata Cache", role: .destructive) {
                Task { await session.storage.clearMetadata(expectedScope: displayedScope) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("The read-only library snapshot will be removed. Queue files, local organization and your sign-in session stay available.") }
        .sheet(isPresented: $showsSnapshot) { OfflineLibraryMetadataView(session: session, expectedScope: displayedScope) }
    }

    private func refresh() async {
        artwork = ArtworkCache.shared.memory.usage()
        await session.storage.refresh(expectedScope: displayedScope)
    }
    private func bytes(_ value: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
}

private struct OfflineLibraryMetadataView: View {
    let session: AppSession
    let expectedScope: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Saved Library Metadata").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if session.account.isSignedIn, session.storage.scope == expectedScope,
               let snapshot = session.storage.snapshot {
                Text("Saved \(snapshot.capturedAt.formatted(date: .long, time: .shortened))")
                Text("Read-only names from the library collections loaded at that time. Listening requires a connection.")
                    .font(.callout).foregroundStyle(.secondary)
                if snapshot.isTruncated { Text("The snapshot includes the first 2,000 loaded collections.").font(.caption).foregroundStyle(.secondary) }
                List(snapshot.collections) { collection in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(collection.title, systemImage: collection.symbol)
                        Text(collection.kind.localizedTitle).font(.caption).foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            } else {
                ContentUnavailableView("No Unexpired Snapshot", systemImage: "clock")
            }
        }
        .padding(20).frame(minWidth: 500, minHeight: 400)
        .onChange(of: session.storage.scope) { dismiss() }
    }
}
