import SwiftUI

struct SpotlightSettingsSection: View {
    let session: AppSession
    @State private var removesEntries = false

    var body: some View {
        Section("Spotlight") {
            Toggle("Find loaded library collections in Spotlight", isOn: Binding(
                get: { session.spotlight.isEnabled }, set: { session.setSpotlightEnabled($0) }))
                .disabled(!session.spotlight.isAvailable)
            Text("When enabled, macOS stores names, kinds and identifiers for up to 500 supported catalog collections loaded from Library. This metadata can appear in Spotlight outside the app and expires after seven days. Opening a result navigates to its collection.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Account changes, sign-out and turning this off remove this app's indexed library metadata. Spotlight storage is managed separately from the app's artwork and metadata caches.")
                .font(.caption).foregroundStyle(.secondary)
            if session.spotlight.isWorking {
                ProgressView("Updating Spotlight…").controlSize(.small)
            } else if session.spotlight.isRemovalPending {
                Text("Removal needs to be retried.").font(.callout)
            } else if session.spotlight.isEnabled {
                LabeledContent("Last submitted", value: "\(session.spotlight.lastSubmittedCount) catalog collections")
                Text("Open or refresh Library to add its loaded catalog collections. Unknown and upload routes are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Remove Spotlight Entries and Turn Off…", role: .destructive) { removesEntries = true }
                .disabled(!session.spotlight.isAvailable || session.spotlight.isWorking)
            if let error = session.spotlight.errorMessage { InlineMessage(message: error) }
        }
        .confirmationDialog("Remove this app's indexed library collections?", isPresented: $removesEntries, titleVisibility: .visible) {
            Button("Remove Entries and Turn Off", role: .destructive) { session.removeSpotlightEntries() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes this app's library metadata from Spotlight. Saved queues, local organization, caches and your sign-in session stay available.") }
    }
}
