import SwiftUI
import YouTubeMusic

/// Native destinations use the service's dedicated category endpoints. Liked
/// Songs is separate; it is not presented as the account's saved Songs library.
struct LibraryCategoryBar: View {
    let session: AppSession

    var body: some View {
        Picker("Library Category", selection: Binding(
            get: { session.destination.libraryCategory ?? .all },
            set: { category in
                session.navigate(to: category == .all ? .library : .libraryCategory(category))
            })) {
            ForEach(YouTubeMusicClient.LibraryCategory.allCases, id: \.self) { category in
                Text(category == .all ? "All" : category.title).tag(category)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityHint("Shows this category from your YouTube Music library")
    }
}
