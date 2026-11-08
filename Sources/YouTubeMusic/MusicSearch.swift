// Portions adapted from Kaset, copyright (c) 2025 sozercan, under the MIT License.
// See THIRD_PARTY_NOTICES.md for the license and upstream source paths.
import Foundation

/// Limits a search to one kind of result. A filtered search returns a single
/// shelf that continues page by page; the unfiltered search returns mixed shelves.
public enum MusicSearchFilter: String, CaseIterable, Hashable, Sendable {
    case all, songs, videos, albums, artists, communityPlaylists, featuredPlaylists

    /// The search request's `params` value. The unfiltered search sends none.
    var params: String? {
        switch self {
        case .all: nil
        case .songs: "EgWKAQIIAWoMEA4QChADEAQQCRAF"
        case .videos: "EgWKAQIQAWoMEA4QChADEAQQCRAF"
        case .albums: "EgWKAQIYAWoMEA4QChADEAQQCRAF"
        case .artists: "EgWKAQIgAWoMEA4QChADEAQQCRAF"
        case .communityPlaylists: "EgeKAQQoAEABagwQDhAKEAMQBBAJEAU="
        case .featuredPlaylists: "EgeKAQQoADgBagwQDhAKEAMQBBAJEAU="
        }
    }
}

/// A complete search query offered for partly typed text.
public struct MusicSearchSuggestion: Hashable, Identifiable, Sendable {
    public let query: String
    public var id: String { query }

    public init(query: String) {
        self.query = query
    }
}

/// Reads text suggestions from `music/get_search_suggestions`. Direct results
/// (artists, songs, albums) in the same response are not suggestions and are skipped.
enum MusicSearchSuggestionParser {
    static func parse(_ data: Data) throws -> [MusicSearchSuggestion] {
        let root: JSONNode
        do { root = try JSONDecoder().decode(JSONNode.self, from: data) }
        catch { throw MusicServiceError.invalidResponse }
        if root["error"].exists {
            switch root["error"]["status"].string {
            case "UNAUTHENTICATED": throw MusicServiceError.authenticationRejected
            case "PERMISSION_DENIED": throw MusicServiceError.accessDenied
            default: throw MusicServiceError.invalidResponse
            }
        }
        var seen = Set<String>()
        var suggestions: [MusicSearchSuggestion] = []
        for section in root["contents"].array {
            for entry in section["searchSuggestionsSectionRenderer"]["contents"].array {
                // Signed-in responses list recent searches with the same shape.
                let renderer = entry["searchSuggestionRenderer"].exists
                    ? entry["searchSuggestionRenderer"] : entry["historySuggestionRenderer"]
                guard renderer.exists else { continue }
                let text = renderer["navigationEndpoint"]["searchEndpoint"]["query"].string ?? renderer["suggestion"].text
                guard let query = text?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty,
                      query.count <= 500, !query.contains(where: \.isNewline),
                      seen.insert(query.lowercased()).inserted else { continue }
                suggestions.append(MusicSearchSuggestion(query: query))
            }
        }
        return suggestions
    }
}
