import Foundation
import MusicCore
import YouTubeMusic

enum CollectionDisplayOrder: String, CaseIterable {
    case serviceOrder, titleAscending, titleDescending, artistAscending, albumAscending, durationAscending, durationDescending

    var title: String {
        switch self {
        case .serviceOrder: "Service Order"
        case .titleAscending: "Title A–Z"
        case .titleDescending: "Title Z–A"
        case .artistAscending: "Artist A–Z"
        case .albumAscending: "Album A–Z"
        case .durationAscending: "Shortest First"
        case .durationDescending: "Longest First"
        }
    }
}

struct CollectionDisplayRow: Identifiable {
    /// The original service ordinal survives sorting and filtering.
    let id: Int
    let track: Track
    let removalReference: PlaylistItemReference?
}

enum CollectionPresentation {
    static func tracks(in page: MusicPage) -> [Track] {
        page.tracks.isEmpty ? page.sections.flatMap(\.items).compactMap {
            if case let .track(track) = $0 { track } else { nil }
        } : page.tracks
    }

    static func rows(in page: MusicPage, matching query: String,
                     order: CollectionDisplayOrder) -> [CollectionDisplayRow] {
        let tracks = tracks(in: page)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = tracks.enumerated().compactMap { index, track -> CollectionDisplayRow? in
            guard query.isEmpty || [track.title, track.artist, track.album ?? ""].contains(where: {
                $0.localizedStandardContains(query)
            }) else { return nil }
            let reference = page.playlistItems.count == tracks.count && page.playlistItems[index].track == track
                ? page.playlistItems[index].removalReference : nil
            return CollectionDisplayRow(id: index, track: track, removalReference: reference)
        }
        guard order != .serviceOrder else { return rows }
        return rows.sorted { left, right in
            let result: ComparisonResult
            switch order {
            case .serviceOrder: return left.id < right.id
            case .titleAscending, .titleDescending:
                result = left.track.title.localizedStandardCompare(right.track.title)
            case .artistAscending: result = left.track.artist.localizedStandardCompare(right.track.artist)
            case .albumAscending:
                if left.track.album == nil || right.track.album == nil {
                    if left.track.album == right.track.album { return left.id < right.id }
                    return left.track.album != nil
                }
                result = left.track.album!.localizedStandardCompare(right.track.album!)
            case .durationAscending, .durationDescending:
                guard let a = left.track.duration, let b = right.track.duration else {
                    if left.track.duration == right.track.duration { return left.id < right.id }
                    return left.track.duration != nil
                }
                result = a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
            }
            if result == .orderedSame { return left.id < right.id }
            return order == .titleDescending || order == .durationDescending
                ? result == .orderedDescending : result == .orderedAscending
        }
    }
}
