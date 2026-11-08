import Foundation
import Observation
import YouTubeMusic

enum NativeSearchScope: Hashable { case catalog, library }
enum RecentSearchSource: Hashable {
    case catalog(MusicSearchFilter), library(MusicLibrarySearchFilter)
}
struct RecentSearch: Hashable, Identifiable {
    let query: String
    let source: RecentSearchSource
    var id: Self { self }
}

/// Queries submitted during the current app/account session. Nothing is written
/// to disk or synchronized with the music service's search history.
@MainActor @Observable
final class SearchHistory {
    static let maximumCount = 12
    private(set) var entries: [RecentSearch] = []
    var queries: [String] { entries.map(\.query) }

    func record(_ text: String, source: RecentSearchSource = .catalog(.all)) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500,
              query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }
        entries.removeAll { $0.source == source && $0.query.caseInsensitiveCompare(query) == .orderedSame }
        entries.insert(.init(query: query, source: source), at: 0)
        if entries.count > Self.maximumCount { entries.removeLast(entries.count - Self.maximumCount) }
    }

    func clear() { entries.removeAll() }
}
