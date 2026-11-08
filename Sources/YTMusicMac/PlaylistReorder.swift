import YouTubeMusic

enum PlaylistReorder {
    enum Direction { case up, down }

    /// Indices refer to loaded service order. A partial page cannot establish
    /// the successor after its final item, so moving that boundary stays disabled.
    static func action(playlistID: String, index: Int, direction: Direction,
                       items: [MusicPlaylistItem], hasMore: Bool, isFiltered: Bool) -> MusicLibraryEditAction? {
        guard !isFiltered, items.indices.contains(index), let item = items[index].removalReference else { return nil }
        let before: PlaylistItemReference?
        switch direction {
        case .up:
            guard index > 0, let previous = items[index - 1].removalReference else { return nil }
            before = previous
        case .down:
            guard index + 1 < items.count else { return nil }
            if index + 2 < items.count {
                guard let successor = items[index + 2].removalReference else { return nil }
                before = successor
            } else {
                guard !hasMore else { return nil }
                before = nil
            }
        }
        guard before?.setVideoID != item.setVideoID else { return nil }
        return .movePlaylistItem(playlistID: playlistID, item: item, before: before)
    }
}
