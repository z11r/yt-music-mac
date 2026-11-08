import Foundation
import YouTubeMusic

/// A display order for the loaded library cards. It never changes the service's
/// playlist order, the playback queue, or history chronology.
enum LibraryDisplayOrder: String, CaseIterable {
    case serviceOrder, titleAscending, titleDescending

    var title: String {
        switch self {
        case .serviceOrder: "Service Order"
        case .titleAscending: "Title A–Z"
        case .titleDescending: "Title Z–A"
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
