import Foundation

/// Verbatim metadata supplied by the current collection header, separate from
/// counts or durations measured from the playable rows already loaded.
public struct MusicCollectionHeader: Hashable, Sendable {
    public let subtitle: String?
    public let summary: String?
    public let description: String?
    public let collaboration: MusicPlaylistCollaboration?
    public let artistAbout: MusicArtistAbout?

    public init(subtitle: String? = nil, summary: String? = nil, description: String? = nil,
                collaboration: MusicPlaylistCollaboration? = nil, artistAbout: MusicArtistAbout? = nil) {
        self.subtitle = Self.bounded(subtitle, bytes: 4_096)
        self.summary = Self.bounded(summary, bytes: 4_096)
        self.description = Self.bounded(description, bytes: 16_384)
        self.collaboration = collaboration
        self.artistAbout = artistAbout
    }

    private static func bounded(_ value: String?, bytes: Int) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= bytes,
              !value.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" || $0.value == 127 }) else { return nil }
        return value
    }
}

enum MusicCollectionHeaderParser {
    private static let keys = ["musicDetailHeaderRenderer", "musicResponsiveHeaderRenderer", "musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer"]
    static func parse(_ root: JSONNode) -> MusicCollectionHeader? {
        guard let value = currentHeader(root) else { return nil }
        let parsed = MusicCollectionHeader(subtitle: value["subtitle"].text,
            summary: value["secondSubtitle"].text,
            description: value["description"]["musicDescriptionShelfRenderer"]["description"].text ?? value["description"].text,
            collaboration: MusicPlaylistCollaborationParser.parse(value), artistAbout: MusicArtistAboutParser.parse(root))
        return parsed.subtitle == nil && parsed.summary == nil && parsed.description == nil && parsed.collaboration == nil && parsed.artistAbout == nil ? nil : parsed
    }

    /// The exact primary renderer, independent of whether its display fields validate.
    static func currentHeader(_ root: JSONNode) -> JSONNode? {
        let top = root["header"]
        if top["musicEditablePlaylistDetailHeaderRenderer"].exists || keys.contains(where: { top[$0].exists }) {
            return headerValue(top)
        }
        // The responsive header can be the first item of the collection's
        // selected primary tab. Related shelves and arbitrary menus are excluded.
        let tabs = root["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].array
        guard tabs.count <= 8, tabs.allSatisfy({
            let flag = $0["tabRenderer"]["selected"]
            return !flag.exists || flag.bool != nil
        }) else { return nil }
        let selected = tabs.filter { $0["tabRenderer"]["selected"].bool == true }
        let tab: JSONNode?
        if selected.count == 1 { tab = selected.first }
        else if selected.isEmpty && tabs.count == 1 && !tabs[0]["tabRenderer"]["selected"].exists { tab = tabs.first }
        else { tab = nil }
        guard let first = tab?["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array.first else { return nil }
        return headerValue(first)
    }

    private static func headerValue(_ node: JSONNode) -> JSONNode? {
        let editable = node["musicEditablePlaylistDetailHeaderRenderer"]["header"]
        let candidates = keys.flatMap { key in [node[key], editable[key]].filter(\.exists) }
        return candidates.count == 1 ? candidates.first : nil
    }
}
