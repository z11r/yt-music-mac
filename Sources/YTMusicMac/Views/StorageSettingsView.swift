import MusicCore
import SwiftUI

struct StorageSettingsView: View {
    let session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var displayedScope: UUID
    @State private var artwork = MemoryCacheUsage(bytes: 0, count: 0)
    @State private var clearsArtwork = false

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
                    LabeledContent("Decoded images in memory", value: "\(bytes(artwork.bytes)) · \(artwork.count) images")
                    LabeledContent("Memory limit", value: "48 MiB · 160 images")
                    LabeledContent("Artwork disk cache", value: "0 bytes · memory only")
                    Button("Clear Cached Artwork…") { clearsArtwork = true }
                    Text("Usage counts decoded cache entries. Visible artwork stays available and browsing can refill the cache.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Saved Data") {
                    if session.account.isSignedIn, let usage = session.storage.protectedUsage {
                        LabeledContent("Current queue", value: bytes(usage.currentQueueBytes))
                        LabeledContent("Named queues for this account", value: bytes(usage.namedQueueBytes))
                        LabeledContent("Local collection organization", value: bytes(usage.organizationBytes))
                    } else {
                        Text("Sign in to a confirmed account to view its saved-data usage.").foregroundStyle(.secondary)
                    }
                    Text("Cache clearing preserves saved data, your credentials, and the WebKit sign-in session. Manage named queues and local organization in their own views.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = session.storage.errorMessage { InlineMessage(message: message) }
            }
            .formStyle(.grouped)
        }
        .padding(16).frame(width: 590, height: 430)
        .task { await refresh() }
        .onChange(of: session.storage.scope) { dismiss() }
        .confirmationDialog("Clear cached artwork?", isPresented: $clearsArtwork, titleVisibility: .visible) {
            Button("Clear Artwork Cache") {
                Task { await ArtworkCache.shared.clear(); artwork = ArtworkCache.shared.memory.usage() }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This clears decoded artwork kept in memory. Music and saved data stay available.") }
    }

    private func refresh() async {
        artwork = ArtworkCache.shared.memory.usage()
        await session.storage.refresh(expectedScope: displayedScope)
    }
    private func bytes(_ value: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
}
