import SwiftUI
import YouTubeMusic

struct RecentSearchesMenu: View {
    let session: AppSession

    var body: some View {
        Menu {
            Text("This App Session")
            ForEach(session.searchHistory.queries, id: \.self) { query in
                Button(query) { session.search(for: MusicSearchSuggestion(query: query)) }
                    .accessibilityLabel("Search again for \(query)")
            }
            Divider()
            Button("Clear Recent Searches", role: .destructive) { session.searchHistory.clear() }
        } label: {
            Label("Recent Searches", systemImage: "clock.arrow.circlepath")
        }
        .disabled(session.searchHistory.queries.isEmpty)
        .help("Recent searches from this app session")
    }
}
