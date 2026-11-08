import Foundation
import Observation

/// Queries submitted during the current app/account session. Nothing is written
/// to disk or synchronized with the music service's search history.
@MainActor @Observable
final class SearchHistory {
    static let maximumCount = 12
    private(set) var queries: [String] = []

    func record(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500,
              query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }
        queries.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        queries.insert(query, at: 0)
        if queries.count > Self.maximumCount { queries.removeLast(queries.count - Self.maximumCount) }
    }

    func clear() { queries.removeAll() }
}
