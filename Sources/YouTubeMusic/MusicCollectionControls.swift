// Response paths follow Kaset and ytmusicapi; see THIRD_PARTY_NOTICES.md.
import Foundation

/// Missing fields are unknown. A known empty description is an empty string.
public struct MusicPlaylistDetails: Hashable, Sendable {
    public let description: String?
    public let privacy: PlaylistPrivacy?
    public init(description: String? = nil, privacy: PlaylistPrivacy? = nil) {
        self.description = description
        self.privacy = privacy
    }
}

/// Album navigation and library mutation identities are intentionally separate.
public struct MusicAlbumLibraryState: Hashable, Sendable {
    public let playlistID: String
    public let rating: MusicRating
    public var isSaved: Bool { rating == .liked }
    public init(playlistID: String, rating: MusicRating) { self.playlistID = playlistID; self.rating = rating }
}

/// The subscription button's channel may differ from the artist browse identity.
public struct MusicArtistSubscription: Hashable, Sendable {
    public let channelID: String
    public let isSubscribed: Bool
    public init(channelID: String, isSubscribed: Bool) { self.channelID = channelID; self.isSubscribed = isSubscribed }
}

enum MusicCollectionControls {
    static func playlistDetails(_ header: JSONNode) -> MusicPlaylistDetails? {
        let editable = header["musicEditablePlaylistDetailHeaderRenderer"]
        let edit = editable["editHeader"]["musicPlaylistEditHeaderRenderer"]
        let inner = editable["header"].exists ? editable["header"] : header
        var description = rawText(edit["description"])
        if description == nil {
            for key in ["musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer"] {
                let value = inner[key]["description"]
                description = rawText(value["musicDescriptionShelfRenderer"]["description"]) ?? rawText(value)
                if description != nil { break }
            }
        }
        let privacy = edit["privacy"].string.flatMap(PlaylistPrivacy.init(rawValue:))
        guard description != nil || privacy != nil else { return nil }
        return .init(description: description, privacy: privacy)
    }

    static func artistSubscriptions(_ header: JSONNode) -> Set<MusicArtistSubscription> {
        var states = Set<MusicArtistSubscription>()
        for key in ["musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer", "musicResponsiveHeaderRenderer"] {
            let button = header[key]["subscriptionButton"]["subscribeButtonRenderer"]
            guard !isDisabled(button) else { continue }
            if let id = button["channelId"].string, id.hasPrefix("UC"), let subscribed = button["subscribed"].bool {
                states.insert(.init(channelID: id, isSubscribed: subscribed))
            }
        }
        return states
    }

    static func albumLibraryStates(_ header: JSONNode) -> Set<MusicAlbumLibraryState> {
        var states = Set<MusicAlbumLibraryState>()
        collectAlbumStates(header, into: &states, depth: 0)
        return states
    }

    private static func collectAlbumStates(_ node: JSONNode, into states: inout Set<MusicAlbumLibraryState>, depth: Int) {
        guard depth < 12 else { return }
        let button = node["likeButtonRenderer"]
        if !isDisabled(button), let id = button["target"]["playlistId"].string, id.hasPrefix("OLAK"),
           let raw = button["likeStatus"].string, let rating = MusicRating(rawValue: raw) {
            states.insert(.init(playlistID: id, rating: rating))
        }
        for key in ["toggleButtonRenderer", "buttonRenderer"] {
            guard !isDisabled(node[key]) else { continue }
            let endpoint = node[key]["defaultServiceEndpoint"]["likeEndpoint"]
            if let id = endpoint["target"]["playlistId"].string, id.hasPrefix("OLAK") {
                // The offered default action is the inverse of current state.
                switch endpoint["status"].string {
                case "LIKE": states.insert(.init(playlistID: id, rating: .neutral))
                case "INDIFFERENT": states.insert(.init(playlistID: id, rating: .liked))
                default: break
                }
            }
        }
        switch node {
        case let .object(values): for value in values.values { collectAlbumStates(value, into: &states, depth: depth + 1) }
        case let .array(values): for value in values { collectAlbumStates(value, into: &states, depth: depth + 1) }
        default: break
        }
    }

    private static func isDisabled(_ node: JSONNode) -> Bool {
        node["isDisabled"].bool == true || node["disabled"].bool == true || node["enabled"].bool == false
    }

    private static func rawText(_ node: JSONNode) -> String? {
        if case let .string(value) = node { return value }
        if case let .string(value) = node["simpleText"] { return value }
        if case let .array(runs) = node["runs"] {
            return runs.compactMap { if case let .string(value) = $0["text"] { value } else { nil } }.joined()
        }
        return nil
    }
}
