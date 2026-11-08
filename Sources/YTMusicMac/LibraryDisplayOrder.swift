import Foundation
import YouTubeMusic

/// A display order for the loaded library cards. It never changes the service's
/// playlist order, the playback queue, or history chronology.
enum LibraryDisplayOrder: String, CaseIterable {
    case serviceOrder, titleAscending, titleDescending

    var title: String {
        switch self {
        case .serviceOrder: AppLocalization.text("Service Order")
        case .titleAscending: AppLocalization.text("Title A–Z")
        case .titleDescending: AppLocalization.text("Title Z–A")
        }
    }

    static func filtered(_ items: [MusicItem], matching query: String) -> [MusicItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? items : items.filter {
            $0.title.localizedStandardContains(query) || ($0.subtitle?.localizedStandardContains(query) ?? false)
        }
    }

    func sorted(_ items: [MusicItem]) -> [MusicItem] {
        guard self != .serviceOrder else { return items }
        return items.enumerated().sorted { left, right in
            let comparison = left.element.title.localizedStandardCompare(right.element.title)
            if comparison == .orderedSame { return left.offset < right.offset }
            return self == .titleAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }.map(\.element)
    }
}
