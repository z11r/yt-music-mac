import YouTubeMusic

enum LibraryEditPolicy {
    static func usesClientPreflight(_ action: MusicLibraryEditAction) -> Bool {
        switch action {
        case .setPlaylistDescription, .setPlaylistPrivacy, .movePlaylistItem: true
        default: false
        }
    }
    static func normalizedID(_ id: String) -> String {
        id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
    }

    static func playlistID(for action: MusicLibraryEditAction) -> String? {
        switch action {
        case .setLiked, .setRating, .createPlaylist: nil
        case let .renamePlaylist(id, _), let .deletePlaylist(id): id
        case let .addItems(id, _, _), let .removeItems(id, _): id
        case let .setPlaylistDescription(id, _), let .setPlaylistPrivacy(id, _), let .movePlaylistItem(id, _, _): id
        }
    }

    static func permits(_ action: MusicLibraryEditAction, capabilities: MusicPlaylistCapabilities) -> Bool {
        switch action {
        case .setLiked, .setRating, .createPlaylist: true
        case .renamePlaylist: capabilities.canRename
        case .deletePlaylist: capabilities.canDelete
        case .addItems: capabilities.canAddItems
        case .removeItems: capabilities.canRemoveItems
        case .setPlaylistDescription: capabilities.canEditDescription
        case .setPlaylistPrivacy: capabilities.canEditPrivacy
        case .movePlaylistItem: capabilities.canReorder
        }
    }

}
