// Portions adapted from Kaset, copyright (c) 2025 sozercan, under the MIT License.
// See THIRD_PARTY_NOTICES.md for the license and upstream source paths.
import Foundation
import MusicCore

indirect enum JSONNode: Decodable {
    case object([String: JSONNode]), array([JSONNode]), string(String), bool(Bool), scalar, null
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode([String: JSONNode].self) { self = .object(value) }
        else if let value = try? container.decode([JSONNode].self) { self = .array(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if (try? container.decode(Double.self)) != nil { self = .scalar }
        else { throw MusicServiceError.invalidResponse }
    }
    subscript(_ key: String) -> JSONNode { if case let .object(value) = self { value[key] ?? .null } else { .null } }
    var array: [JSONNode] { if case let .array(value) = self { value } else { [] } }
    var string: String? { if case let .string(value) = self, !value.isEmpty { value } else { nil } }
    var bool: Bool? { if case let .bool(value) = self { value } else { nil } }
    var exists: Bool { if case .null = self { false } else { true } }
    var text: String? {
        if let value = self["simpleText"].string { return value }
        let joined = self["runs"].array.compactMap { $0["text"].string }.joined()
        return joined.isEmpty ? nil : joined
    }
}

struct ParsedMusicPage {
    var title: String?
    var sections: [MusicSection] = []
    var token: String?
    var recognized = false
    var playlistItems: [MusicPlaylistItem] = []
    var playlistCapabilities = MusicPlaylistCapabilities()
    var playlistEditingDenied = false
    var likeStateCandidates: [String: Set<Bool>] = [:]
    var likeStates: [String: Bool] {
        likeStateCandidates.compactMapValues { $0.count == 1 ? $0.first : nil }
    }
    var items: [MusicItem] { sections.flatMap(\.items) }
}

/// Traverses only content containers, never menus or arbitrary nested navigation actions.
enum MusicResponseParser {
    static func parse(_ data: Data, preservesOccurrences: Bool) throws -> ParsedMusicPage {
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
        var result = ParsedMusicPage()
        result.title = headerTitle(root["header"])
        playlistControls(root["header"], result: &result)
        let contents = root["contents"]
        visit(contents, result: &result, path: "content", preservesOccurrences: preservesOccurrences)
        for key in ["singleColumnBrowseResultsRenderer", "twoColumnBrowseResultsRenderer", "tabbedSearchResultsRenderer"] {
            let renderer = contents[key]
            for (index, tab) in renderer["tabs"].array.enumerated() {
                visit(tab["tabRenderer"]["content"], result: &result, path: "tab\(index)", preservesOccurrences: preservesOccurrences)
            }
            visit(renderer["secondaryContents"], result: &result, path: "secondary", preservesOccurrences: preservesOccurrences)
        }
        for key in ["sectionListContinuation", "itemSectionContinuation", "musicShelfContinuation", "musicPlaylistShelfContinuation", "gridContinuation"] {
            let container = root["continuationContents"][key]
            if container.exists {
                let previousToken = result.token
                result.token = nil
                result.recognized = true
                if key == "sectionListContinuation" || key == "itemSectionContinuation" {
                    visitChildren(container["contents"].array + container["items"].array,
                                  result: &result, path: "next", preservesOccurrences: preservesOccurrences)
                } else {
                    appendShelf(container, result: &result, path: "next", preservesOccurrences: preservesOccurrences)
                }
                result.token = key == "sectionListContinuation"
                    ? sectionListToken(container, collectionToken: result.token, previousToken: previousToken)
                    : result.token ?? continuation(container) ?? previousToken
            }
        }
        for key in ["onResponseReceivedActions", "onResponseReceivedEndpoints", "onResponseReceivedCommands"] {
            for (index, action) in root[key].array.enumerated() {
                for actionKey in ["appendContinuationItemsAction", "reloadContinuationItemsCommand"] {
                    let container = action[actionKey]
                    if container.exists {
                        result.recognized = true
                        appendShelfItems(container["continuationItems"].array, title: "", result: &result, path: "action\(index)",
                                         preservesOccurrences: preservesOccurrences)
                    }
                }
            }
        }
        guard result.recognized else { throw MusicServiceError.unsupportedResponse }
        return result
    }

    private static func visit(_ node: JSONNode, result: inout ParsedMusicPage, path: String, preservesOccurrences: Bool, depth: Int = 0) {
        guard depth < 16 else { return }
        if node["sectionListRenderer"].exists {
            let container = node["sectionListRenderer"]
            let previousToken = result.token
            result.token = nil
            result.recognized = true
            visitChildren(container["contents"].array, result: &result, path: path, preservesOccurrences: preservesOccurrences, depth: depth + 1)
            result.token = sectionListToken(container, collectionToken: result.token, previousToken: previousToken)
        } else if node["itemSectionRenderer"].exists {
            let container = node["itemSectionRenderer"]
            let previousToken = result.token
            result.token = nil
            result.recognized = true
            visitChildren(container["contents"].array, result: &result, path: path, preservesOccurrences: preservesOccurrences, depth: depth + 1)
            result.token = result.token ?? continuation(container) ?? previousToken
        } else if node["musicResponsiveHeaderRenderer"].exists {
            result.title = node["musicResponsiveHeaderRenderer"]["title"].text ?? result.title
            playlistControls(node, result: &result)
        } else {
            for key in ["musicCarouselShelfRenderer", "musicShelfRenderer", "musicPlaylistShelfRenderer", "musicCardShelfRenderer", "musicImmersiveCarouselShelfRenderer", "gridRenderer"] {
                if node[key].exists {
                    result.recognized = true
                    appendShelf(node[key], result: &result, path: path, preservesOccurrences: preservesOccurrences,
                                includesCard: key == "musicCardShelfRenderer")
                    return
                }
            }
            if let item = item(node) {
                result.recognized = true
                result.sections.append(MusicSection(id: path, title: "", items: [item]))
                if case let .track(track) = item { recordLikeState(node, track: track, result: &result) }
                if preservesOccurrences, case let .track(track) = item {
                    result.playlistItems.append(playlistItem(node, track: track))
                }
            }
            result.token = continuationItem(node) ?? result.token
        }
    }

    private static func visitChildren(_ children: [JSONNode], result: inout ParsedMusicPage, path: String,
                                      preservesOccurrences: Bool, depth: Int = 0) {
        // An explicit playlist shelf is authoritative, including when it is empty.
        let hasPlaylist = preservesOccurrences && children.contains { $0["musicPlaylistShelfRenderer"].exists }
        for (index, child) in children.enumerated() {
            if hasPlaylist && !child["musicPlaylistShelfRenderer"].exists && !child["musicResponsiveHeaderRenderer"].exists { continue }
            if preservesOccurrences, let title = child["musicShelfRenderer"]["title"].text?.lowercased(),
               title.contains("suggestion") || title == "recommended" { continue }
            visit(child, result: &result, path: "\(path).\(index)", preservesOccurrences: preservesOccurrences, depth: depth)
        }
    }

    private static func appendShelf(_ node: JSONNode, result: inout ParsedMusicPage, path: String,
                                    preservesOccurrences: Bool, includesCard: Bool = false) {
        let title = node["title"].text ?? node["header"]["musicCarouselShelfBasicHeaderRenderer"]["title"].text ?? ""
        let previousToken = result.token
        result.token = nil
        var children = node["contents"].array + node["items"].array
        if includesCard { children.insert(.object(["musicTwoRowItemRenderer": node]), at: 0) }
        appendShelfItems(children, title: title, result: &result, path: path, preservesOccurrences: preservesOccurrences)
        result.token = result.token ?? continuation(node) ?? previousToken
    }

    /// A track or grid cursor belongs to the collection and takes precedence over the section list's own cursor.
    /// When the section list holds a playlist shelf, its own cursor loads suggestions, so it is never followed.
    private static func sectionListToken(_ container: JSONNode, collectionToken: String?, previousToken: String?) -> String? {
        if container["contents"].array.contains(where: { $0["musicPlaylistShelfRenderer"].exists }) { return collectionToken }
        return collectionToken ?? continuation(container) ?? previousToken
    }

    private static func appendShelfItems(_ nodes: [JSONNode], title: String, result: inout ParsedMusicPage, path: String,
                                         preservesOccurrences: Bool) {
        let items = nodes.compactMap { node -> MusicItem? in
            guard let item = item(node) else { return nil }
            if case let .track(track) = item { recordLikeState(node, track: track, result: &result) }
            if preservesOccurrences, case let .track(track) = item {
                result.playlistItems.append(playlistItem(node, track: track))
            }
            return item
        }
        if !items.isEmpty { result.sections.append(MusicSection(id: path, title: title, items: items)) }
        for node in nodes { result.token = continuationItem(node) ?? result.token }
    }

    private static func continuation(_ node: JSONNode) -> String? {
        for value in node["continuations"].array {
            if let token = value["nextContinuationData"]["continuation"].string { return token }
        }
        return nil
    }

    private static func continuationItem(_ node: JSONNode) -> String? {
        let endpoint = node["continuationItemRenderer"]["continuationEndpoint"]
        if let token = endpoint["continuationCommand"]["token"].string { return token }
        for command in endpoint["commandExecutorCommand"]["commands"].array {
            if let token = command["continuationCommand"]["token"].string { return token }
        }
        return nil
    }

    private static func headerTitle(_ node: JSONNode) -> String? {
        for key in ["musicDetailHeaderRenderer", "musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer", "musicResponsiveHeaderRenderer"] {
            if let title = node[key]["title"].text { return title }
        }
        return node["musicEditablePlaylistDetailHeaderRenderer"]["header"]["musicDetailHeaderRenderer"]["title"].text
    }

    private static func item(_ node: JSONNode) -> MusicItem? {
        for key in ["musicResponsiveListItemRenderer", "musicTwoRowItemRenderer", "musicMultiRowListItemRenderer"] {
            if node[key].exists { return parseItem(node[key]) }
        }
        return nil
    }

    private static func playlistItem(_ node: JSONNode, track: Track) -> MusicPlaylistItem {
        for key in ["musicResponsiveListItemRenderer", "musicTwoRowItemRenderer", "musicMultiRowListItemRenderer"] {
            let renderer = node[key]
            guard renderer.exists else { continue }
            let direct = renderer["playlistItemData"]["playlistSetVideoId"].string
            let occurrence = direct ?? removalOccurrence(renderer["menu"], videoID: track.id)
            return MusicPlaylistItem(track: track, setVideoID: occurrence)
        }
        return MusicPlaylistItem(track: track)
    }

    private static func recordLikeState(_ node: JSONNode, track: Track, result: inout ParsedMusicPage) {
        for key in ["musicResponsiveListItemRenderer", "musicTwoRowItemRenderer", "musicMultiRowListItemRenderer"] {
            for button in node[key]["menu"]["menuRenderer"]["topLevelButtons"].array {
                let like = button["likeButtonRenderer"]
                if let target = like["target"]["videoId"].string, target != track.id { continue }
                switch like["likeStatus"].string {
                case "LIKE": result.likeStateCandidates[track.id, default: []].insert(true)
                case "INDIFFERENT", "DISLIKE": result.likeStateCandidates[track.id, default: []].insert(false)
                default: break
                }
            }
        }
    }

    private static func playlistControls(_ header: JSONNode, result: inout ParsedMusicPage) {
        // Inspect the current header only; another playlist's menu in a shelf cannot grant these actions.
        if containsEditDenial(header) {
            result.playlistEditingDenied = true
            result.playlistCapabilities = MusicPlaylistCapabilities()
        }
        guard !result.playlistEditingDenied else { return }
        if case .object = header["musicEditablePlaylistDetailHeaderRenderer"] {
            result.playlistCapabilities.canRename = true
            result.playlistCapabilities.canAddItems = true
            result.playlistCapabilities.canRemoveItems = true
        }
        if containsDeleteCommand(header) { result.playlistCapabilities.canDelete = true }
    }

    private static func containsDeleteCommand(_ node: JSONNode, depth: Int = 0) -> Bool {
        guard depth < 12 else { return false }
        if node["deletePlaylistEndpoint"]["playlistId"].string != nil { return true }
        if let address = node["urlEndpoint"]["url"].string, let url = URL(string: address),
           url.scheme == "https", url.host == "music.youtube.com", url.path == "/playlist/delete",
           url.user == nil, url.password == nil, url.port == nil || url.port == 443 { return true }
        switch node {
        case let .object(values): return values.values.contains { containsDeleteCommand($0, depth: depth + 1) }
        case let .array(values): return values.contains { containsDeleteCommand($0, depth: depth + 1) }
        default: return false
        }
    }

    private static func containsEditDenial(_ node: JSONNode, depth: Int = 0) -> Bool {
        guard depth < 12 else { return false }
        if node["isEditable"].bool == false { return true }
        switch node {
        case let .object(values): return values.values.contains { containsEditDenial($0, depth: depth + 1) }
        case let .array(values): return values.contains { containsEditDenial($0, depth: depth + 1) }
        default: return false
        }
    }

    private static func removalOccurrence(_ node: JSONNode, videoID: String, depth: Int = 0) -> String? {
        guard depth < 12 else { return nil }
        if node["action"].string == "ACTION_REMOVE_VIDEO", node["removedVideoId"].string == videoID {
            return node["setVideoId"].string
        }
        switch node {
        case let .object(values):
            for key in values.keys.sorted() {
                if let value = values[key], let id = removalOccurrence(value, videoID: videoID, depth: depth + 1) { return id }
            }
        case let .array(values):
            for value in values {
                if let id = removalOccurrence(value, videoID: videoID, depth: depth + 1) { return id }
            }
        default: break
        }
        return nil
    }

    private static func parseItem(_ node: JSONNode) -> MusicItem? {
        guard node["musicItemRendererDisplayPolicy"].string != "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT" else { return nil }
        let columns = node["flexColumns"].array.map { $0["musicResponsiveListItemFlexColumnRenderer"]["text"] }
        let titleNode = columns.first ?? node["title"]
        guard let title = titleNode.text else { return nil }
        var endpoints = [node["navigationEndpoint"], titleNode["runs"].array.first?["navigationEndpoint"] ?? .null, node["onTap"]]
        for key in ["overlay", "thumbnailOverlay"] {
            endpoints.append(node[key]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"])
        }
        endpoints = endpoints.map { $0["innertubeCommand"].exists ? $0["innertubeCommand"] : $0 }
        let metadata = columns.dropFirst().flatMap { $0["runs"].array } + node["subtitle"]["runs"].array + node["secondSubtitle"]["runs"].array
        let subtitle = metadata.compactMap { $0["text"].string }.joined()
        let artwork = thumbnail(node)
        // A browse destination takes precedence over the card's play overlay.
        for endpoint in endpoints {
            let browse = endpoint["browseEndpoint"]
            if let id = browse["browseId"].string, let kind = collectionKind(browse) {
                return .collection(MusicCollection(id: id, kind: kind, title: title, subtitle: subtitle.isEmpty ? nil : subtitle, artworkURL: artwork))
            }
        }
        for endpoint in endpoints {
            if let id = endpoint["watchPlaylistEndpoint"]["playlistId"].string {
                return .collection(MusicCollection(id: id, kind: .playlist, title: title, subtitle: subtitle, artworkURL: artwork))
            }
        }
        // Playlist cards sometimes expose only a watch endpoint.
        if metadata.first?["text"].string?.lowercased() == "playlist",
           let id = endpoints.compactMap({ $0["watchEndpoint"]["playlistId"].string }).first {
            return .collection(MusicCollection(id: id, kind: .playlist, title: title, subtitle: subtitle, artworkURL: artwork))
        }
        guard let videoID = node["playlistItemData"]["videoId"].string
                ?? endpoints.compactMap({ $0["watchEndpoint"]["videoId"].string }).first else { return nil }
        let artists = metadata.compactMap { run -> String? in
            collectionKind(run["navigationEndpoint"]["browseEndpoint"]) == .artist ? run["text"].string : nil
        }
        let album = metadata.first { collectionKind($0["navigationEndpoint"]["browseEndpoint"]) == .album }?["text"].string
        let fixed = node["fixedColumns"].array.compactMap { $0["musicResponsiveListItemFixedColumnRenderer"]["text"].text }
        let duration = (fixed + metadata.compactMap { $0["text"].string }).compactMap(parseDuration).first
        let fallback = metadata.compactMap { $0["text"].string?.trimmingCharacters(in: .whitespacesAndNewlines) }.first {
            !$0.isEmpty && !["•", "·", "&", "Song", "Video", "Album", "Single", "EP"].contains($0) && parseDuration($0) == nil
        }
        let artist = artists.isEmpty ? (fallback ?? "Unknown artist") : artists.joined(separator: ", ")
        return .track(Track(id: videoID, title: title, artist: artist, album: album, artworkURL: artwork, duration: duration))
    }

    private static func collectionKind(_ browse: JSONNode) -> MusicCollection.Kind? {
        let pageType = browse["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM": return .album
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST": return .artist
        case "MUSIC_PAGE_TYPE_PLAYLIST": return .playlist
        default: break
        }
        guard let id = browse["browseId"].string else { return nil }
        if id.hasPrefix("MPRE") || id.hasPrefix("OLAK") { return .album }
        if id.hasPrefix("VL") || id.hasPrefix("PL") || id.hasPrefix("RD") || id.hasPrefix("VM") { return .playlist }
        if id.hasPrefix("UC") { return .artist }
        return nil
    }

    private static func thumbnail(_ node: JSONNode, depth: Int = 0) -> URL? {
        guard depth < 6 else { return nil }
        for value in node["thumbnails"].array.reversed() {
            if var raw = value["url"].string {
                if raw.hasPrefix("//") { raw = "https:" + raw }
                if let url = URL(string: raw), url.scheme == "https", url.host != nil { return url }
            }
        }
        for key in ["thumbnail", "thumbnailRenderer", "foregroundThumbnail", "musicThumbnailRenderer", "croppedSquareThumbnailRenderer"] {
            if let url = thumbnail(node[key], depth: depth + 1) { return url }
        }
        return nil
    }

    static func parseDuration(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count, numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }
}
