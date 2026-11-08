// Request and response paths follow ytmusicapi, copyright (c) 2026 sigma67, MIT License.
// See THIRD_PARTY_NOTICES.md.
import Foundation

public enum MusicUploadCategory: String, CaseIterable, Hashable, Sendable {
    case songs, albums, artists
    public var title: String {
        switch self {
        case .songs: ServiceLocalization.text("Songs")
        case .albums: ServiceLocalization.text("Albums")
        case .artists: ServiceLocalization.text("Artists")
        }
    }
    var browseID: String {
        switch self {
        case .songs: "FEmusic_library_privately_owned_tracks"
        case .albums: "FEmusic_library_privately_owned_releases"
        case .artists: "FEmusic_library_privately_owned_artists"
        }
    }
}

enum MusicUploadRoutes {
    static let albumPrefix = "FEmusic_library_privately_owned_release_detail"
    static let artistPrefix = "FEmusic_library_privately_owned_artist_detail"
    static func isCollectionID(_ id: String) -> Bool { id.hasPrefix(albumPrefix) || id.hasPrefix(artistPrefix) }
    static func isVideoID(_ id: String) -> Bool {
        id.utf8.count == 11 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
}

extension YouTubeMusicClient {
    public func uploads(category: MusicUploadCategory = .songs) async throws -> MusicPage {
        try await firstPage(endpoint: .browse, body: ["browseId": category.browseID], title: ServiceLocalization.format("Uploaded %@", category.title),
                            requiresAuthentication: true, preservesOccurrences: category == .songs, contentOrigin: .upload)
    }

    public func searchUploads(query: String) async throws -> MusicPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500 else { throw MusicServiceError.invalidInput }
        return try await firstPage(endpoint: .search, body: ["query": query, "params": "agIYAw%3D%3D"], title: ServiceLocalization.text("Search Uploads"),
                                   requiresAuthentication: true, preservesOccurrences: false, contentOrigin: .upload)
    }

    public func uploadedAlbum(id: String) async throws -> MusicPage {
        try validateIdentifier(id)
        guard id.hasPrefix(MusicUploadRoutes.albumPrefix), id.count > MusicUploadRoutes.albumPrefix.count else { throw MusicServiceError.invalidInput }
        return try await firstPage(endpoint: .browse, body: ["browseId": id], title: ServiceLocalization.text("Uploaded Album"),
                                   requiresAuthentication: true, preservesOccurrences: true, contentOrigin: .upload)
    }

    public func uploadedArtist(id: String) async throws -> MusicPage {
        try validateIdentifier(id)
        guard id.hasPrefix(MusicUploadRoutes.artistPrefix), id.count > MusicUploadRoutes.artistPrefix.count else { throw MusicServiceError.invalidInput }
        return try await firstPage(endpoint: .browse, body: ["browseId": id], title: ServiceLocalization.text("Uploaded Artist"),
                                   requiresAuthentication: true, preservesOccurrences: true, contentOrigin: .upload)
    }
}

/// Adapts the established upload queue-target path without exposing deletion
/// entity IDs to track, collection, or playback identities.
enum MusicUploadResponseAdapter {
    static func prepare(_ data: Data, isSearch: Bool) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicServiceError.invalidResponse }
        if isSearch, let contents = root["contents"] as? [String: Any],
           let tabbed = contents["tabbedSearchResultsRenderer"] as? [String: Any] {
            guard let tabs = tabbed["tabs"] as? [[String: Any]], tabs.count > 2,
                  let tab = tabs[2]["tabRenderer"] as? [String: Any], let content = tab["content"] as? [String: Any] else {
                throw MusicServiceError.unsupportedResponse
            }
            root["contents"] = content
        }
        let prepared = try transform(root, depth: 0)
        return try JSONSerialization.data(withJSONObject: prepared)
    }

    private static func transform(_ value: Any, depth: Int) throws -> Any {
        guard depth < 40 else { return value }
        if let array = value as? [Any] {
            return try array.filter { !isPlaylistControl($0) }.map { try transform($0, depth: depth + 1) }
        }
        guard var object = value as? [String: Any] else { return value }
        if var row = object["musicResponsiveListItemRenderer"] as? [String: Any],
           let menu = row["menu"] as? [String: Any], let renderer = menu["menuRenderer"] as? [String: Any],
           let items = renderer["items"] as? [[String: Any]] {
            var targets = Set<String>()
            for item in items {
                let service = item["menuServiceItemRenderer"] as? [String: Any]
                let endpoint = service?["serviceEndpoint"] as? [String: Any]
                let queue = endpoint?["queueAddEndpoint"] as? [String: Any]
                let target = queue?["queueTarget"] as? [String: Any]
                if let id = target?["videoId"] as? String { targets.insert(id) }
            }
            if targets.count > 1 { throw MusicServiceError.unsupportedResponse }
            if let id = targets.first {
                guard MusicUploadRoutes.isVideoID(id) else { throw MusicServiceError.unsupportedResponse }
                var identity = row["playlistItemData"] as? [String: Any] ?? [:]
                if let existing = identity["videoId"] as? String, existing != id { throw MusicServiceError.unsupportedResponse }
                identity["videoId"] = id
                row["playlistItemData"] = identity
                object["musicResponsiveListItemRenderer"] = row
            } else if hasEntityCommand(row), !hasPlaybackVideo(row) {
                throw MusicServiceError.unsupportedResponse
            }
        }
        for (key, child) in object { object[key] = try transform(child, depth: depth + 1) }
        return object
    }

    private static func hasPlaybackVideo(_ row: [String: Any]) -> Bool {
        let identity = row["playlistItemData"] as? [String: Any]
        if let id = identity?["videoId"] as? String, MusicUploadRoutes.isVideoID(id) { return true }
        return navigationEndpoints(row).contains {
            guard let watch = $0["watchEndpoint"] as? [String: Any], let id = watch["videoId"] as? String else { return false }
            return MusicUploadRoutes.isVideoID(id)
        }
    }

    private static func isPlaylistControl(_ value: Any) -> Bool {
        guard let object = value as? [String: Any], let row = object["musicResponsiveListItemRenderer"] as? [String: Any],
              !hasPlaybackVideo(row), !hasEntityCommand(row) else { return false }
        return navigationEndpoints(row).contains { $0["watchPlaylistEndpoint"] != nil }
    }

    private static func navigationEndpoints(_ row: [String: Any]) -> [[String: Any]] {
        var endpoints = [row["navigationEndpoint"] as? [String: Any], row["onTap"] as? [String: Any]].compactMap { $0 }
        if let columns = row["flexColumns"] as? [[String: Any]] {
            for column in columns.prefix(1) {
                let renderer = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
                let text = renderer?["text"] as? [String: Any]
                let runs = text?["runs"] as? [[String: Any]] ?? []
                endpoints += runs.compactMap { $0["navigationEndpoint"] as? [String: Any] }
            }
        }
        return endpoints
    }

    private static func hasEntityCommand(_ value: Any, depth: Int = 0) -> Bool {
        guard depth < 16 else { return false }
        if let object = value as? [String: Any] {
            return object["musicDeletePrivatelyOwnedEntityCommand"] != nil || object.values.contains { hasEntityCommand($0, depth: depth + 1) }
        }
        if let array = value as? [Any] { return array.contains { hasEntityCommand($0, depth: depth + 1) } }
        return false
    }
}
