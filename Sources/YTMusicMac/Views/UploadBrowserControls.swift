import SwiftUI
import YouTubeMusic

struct UploadBrowserControls: View {
    let session: AppSession
    @State private var query = ""

    var body: some View {
        HStack(spacing: 14) {
            Menu("Browse Uploads") {
                ForEach(MusicUploadCategory.allCases, id: \.self) { category in
                    Button(category.title) { session.navigate(to: .uploads(category)) }
                }
            }
            Text("Your account's uploaded music").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            TextField("Search Uploads", text: $query)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                .accessibilityLabel("Search your uploaded music")
                .onSubmit(search)
            Button("Search Uploads", action: search)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .disabled(!session.account.isSignedIn)
        .onChange(of: session.libraryEditingScope) { query = "" }
    }

    private func search() {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 500 else { return }
        session.navigate(to: .uploadSearch(cleaned))
    }
}
