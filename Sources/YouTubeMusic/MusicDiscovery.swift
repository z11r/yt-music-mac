// Endpoint shapes adapted from Kaset, copyright (c) 2025 sozercan, under the MIT License.
// Discovery shelf-title paths follow ytmusicapi's Explore parser (MIT License).
// See THIRD_PARTY_NOTICES.md for the license and upstream source paths.
import Foundation

public enum MusicDiscoveryCategory: String, CaseIterable, Hashable, Sendable {
    case charts, moodsAndGenres, newReleases

    public var title: String {
        switch self {
        case .charts: ServiceLocalization.text("Charts")
        case .moodsAndGenres: ServiceLocalization.text("Moods & Genres")
        case .newReleases: ServiceLocalization.text("New Releases")
        }
    }

    var browseID: String {
        switch self {
        case .charts: "FEmusic_charts"
        case .moodsAndGenres: "FEmusic_moods_and_genres"
        case .newReleases: "FEmusic_new_releases"
        }
    }
}

/// A service-provided browse action. Parameters belong to this exact destination;
/// they must not be reused for another shelf, artist, or mood.
public struct MusicBrowseReference: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case playlist, artist, discography, category }
    public let browseID: String
    public let params: String?
    public let title: String
    public let kind: Kind
    var scope: UUID?

    public init(browseID: String, params: String? = nil, title: String, kind: Kind) {
        self.browseID = browseID
        self.params = params
        self.title = title
        self.kind = kind
        scope = nil
    }
}

enum MusicBrowseParser {
    /// Explore's category links use these exact service-issued browse IDs without
    /// a collection page type. They are not playlist IDs or fabricated routes.
    private static let discoveryShelfIDs: Set<String> = [
        "FEmusic_new_releases_albums", "FEmusic_new_releases_videos", "FEmusic_moods_and_genres"
    ]

    /// Only explicit shelf actions are read. Menu actions and other text runs
    /// cannot supply a destination, and conflicting actions hide See All.
    static func shelfReference(_ node: JSONNode, title: String) -> MusicBrowseReference? {
        guard case let .object(header) = node["header"]["musicCarouselShelfBasicHeaderRenderer"] else { return nil }
        var endpoints: [JSONNode] = []
        if let more = header["moreContentButton"] {
            guard case let .object(fields) = more, let renderer = fields["buttonRenderer"],
                  case let .object(button) = renderer else { return nil }
            // Dictionary presence preserves explicit nulls for rejection below.
            let commands = ["command", "navigationEndpoint"].compactMap { button[$0] }
            guard !commands.isEmpty else { return nil }
            endpoints += commands
        }
        if let titleNode = header["title"] {
            guard case let .object(fields) = titleNode else { return nil }
            if let rawRuns = fields["runs"] {
                guard case let .array(runs) = rawRuns, runs.count <= 64 else { return nil }
                // Only the first run's explicit action has an established path.
                for (index, run) in runs.enumerated() {
                    guard case let .object(fields) = run else { return nil }
                    if let endpoint = fields["navigationEndpoint"] {
                        guard index == 0 else { return nil }
                        endpoints.append(endpoint)
                    }
                }
            }
        }
        guard !endpoints.isEmpty else { return nil }
        var result: MusicBrowseReference?
        for endpoint in endpoints {
            guard case let .object(fields) = endpoint,
                  !["watchEndpoint", "watchPlaylistEndpoint", "urlEndpoint", "commandExecutorCommand"].contains(where: { fields.keys.contains($0) }) else { return nil }
            guard let candidate = shelfDestination(endpoint["browseEndpoint"], title: title) else { return nil }
            if let result, result != candidate { return nil }
            result = candidate
        }
        return result
    }

    private static func shelfDestination(_ browse: JSONNode, title: String) -> MusicBrowseReference? {
        // Present malformed context must not become an untyped category action.
        guard case let .object(fields) = browse else { return nil }
        var pageType: JSONNode?
        if let context = fields["browseEndpointContextSupportedConfigs"] {
            guard case let .object(configs) = context else { return nil }
            if let config = configs["browseEndpointContextMusicConfig"] {
                guard case let .object(music) = config else { return nil }
                pageType = music["pageType"]
            }
        }
        let kind: MusicBrowseReference.Kind
        switch pageType?.string {
        case "MUSIC_PAGE_TYPE_PLAYLIST": kind = .playlist
        case "MUSIC_PAGE_TYPE_ARTIST": kind = .artist
        case "MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY": kind = .discography
        case nil:
            guard case nil = pageType, let id = browse["browseId"].string, discoveryShelfIDs.contains(id) else { return nil }
            kind = .category
        default: return nil
        }
        // A category ID must never inherit a contradictory collection page type.
        if let id = browse["browseId"].string, discoveryShelfIDs.contains(id), kind != .category { return nil }
        return reference(browse, title: title, kind: kind)
    }

    static func navigationReference(_ node: JSONNode) -> MusicBrowseReference? {
        guard let title = node["buttonText"].text else { return nil }
        return reference(node["clickCommand"]["browseEndpoint"], title: title, kind: .category)
    }

    private static func reference(_ browse: JSONNode, title: String, kind: MusicBrowseReference.Kind) -> MusicBrowseReference? {
        guard case let .object(fields) = browse, let id = browse["browseId"].string else { return nil }
        // Reject malformed fields rather than silently dropping scoped parameters.
        if let params = fields["params"], params.string == nil { return nil }
        let value = MusicBrowseReference(browseID: id, params: browse["params"].string, title: title, kind: kind)
        return value.isValid ? value : nil
    }
}

extension MusicBrowseReference {
    func scoped(to scope: UUID) -> Self {
        var result = self
        result.scope = scope
        return result
    }

    var isValid: Bool {
        let validParams = params.map { value in
            value.count <= 4096 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        } ?? true
        return !browseID.isEmpty && browseID.count <= 256 && browseID.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        } && !title.isEmpty && title.count <= 500 && !title.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        && validParams
    }
}
