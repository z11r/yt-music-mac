import SwiftUI
import YouTubeMusic

struct RecentSearchesMenu: View {
    let session: AppSession

    var body: some View {
        Menu {
            Text("This App Session")
            ForEach(session.searchHistory.entries) { entry in
                Button { session.repeatSearch(entry) } label: { Text(verbatim: title(entry)) }
            }
            Divider()
            Button("Clear Recent Searches", role: .destructive) { session.searchHistory.clear() }
        } label: {
            Label("Recent Searches", systemImage: "clock.arrow.circlepath")
        }
        .disabled(session.searchHistory.queries.isEmpty)
        .help("Recent searches from this app session")
    }

    private func title(_ entry: RecentSearch) -> String {
        let source: String
        switch entry.source {
        case let .catalog(filter): source = AppLocalization.format("Catalog · %@", filter.title)
        case let .library(filter): source = AppLocalization.format("Your Library · %@", filter.title)
        }
        return entry.query + " · " + source
    }
}
