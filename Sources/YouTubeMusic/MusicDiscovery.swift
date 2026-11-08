// Endpoint shapes adapted from Kaset, copyright (c) 2025 sozercan, under the MIT License.
// See THIRD_PARTY_NOTICES.md for the license and upstream source paths.
import Foundation

public enum MusicDiscoveryCategory: String, CaseIterable, Hashable, Sendable {
    case charts, moodsAndGenres, newReleases

    public var title: String {
        switch self {
        case .charts: "Charts"
        case .moodsAndGenres: "Moods & Genres"
        case .newReleases: "New Releases"
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
    /// Only the three shelf page types established by the pinned parser are offered.
    static func shelfReference(_ node: JSONNode, title: String) -> MusicBrowseReference? {
        let button = node["header"]["musicCarouselShelfBasicHeaderRenderer"]["moreContentButton"]["buttonRenderer"]
        let endpoint = button["command"].exists ? button["command"] : button["navigationEndpoint"]
        let browse = endpoint["browseEndpoint"]
        let kind: MusicBrowseReference.Kind
        switch browse["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string {
        case "MUSIC_PAGE_TYPE_PLAYLIST": kind = .playlist
        case "MUSIC_PAGE_TYPE_ARTIST": kind = .artist
        case "MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY": kind = .discography
        default: return nil
        }
        return reference(browse, title: title, kind: kind)
    }

    static func navigationReference(_ node: JSONNode) -> MusicBrowseReference? {
        guard let title = node["buttonText"].text else { return nil }
        return reference(node["clickCommand"]["browseEndpoint"], title: title, kind: .category)
    }

    private static func reference(_ browse: JSONNode, title: String, kind: MusicBrowseReference.Kind) -> MusicBrowseReference? {
        guard let id = browse["browseId"].string else { return nil }
        // Reject malformed fields rather than silently dropping scoped parameters.
        if browse["params"].exists && browse["params"].string == nil { return nil }
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
