// Header paths follow ytmusicapi's playlist parser (MIT License).
// See THIRD_PARTY_NOTICES.md and docs/COLLABORATIVE_PLAYLISTS.md.
import Foundation

/// Limited header attribution. It establishes no account role or write authority.
public struct MusicPlaylistCollaboration: Hashable, Sendable {
    public let label: String
    public let avatarURLs: [URL]

    public init?(label: String, avatarURLs: [URL] = []) {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.utf8.count <= 1_024,
              !label.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        self.label = label
        var seen: Set<URL> = []
        self.avatarURLs = avatarURLs.count > 32 ? [] : Array(avatarURLs.filter {
            Self.permitsAvatar($0) && seen.insert($0).inserted
        }.prefix(8))
    }

    private static func permitsAvatar(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 2_048, url.scheme == "https",
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["ggpht.com", "googleusercontent.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

enum MusicPlaylistCollaborationParser {
    static func hasMarker(_ header: JSONNode) -> Bool {
        header["facepile"]["avatarStackViewModel"]["rendererContext"]["commandContext"]["onTap"]["innertubeCommand"]["showEngagementPanelEndpoint"]["identifier"]["tag"].string == "PAplaylist_collaborate"
    }

    static func parse(_ header: JSONNode) -> MusicPlaylistCollaboration? {
        let stack = header["facepile"]["avatarStackViewModel"]
        let renderer = stack["rendererContext"]
        guard hasMarker(header),
              let label = renderer["accessibilityContext"]["label"].string else { return nil }
        let avatars = stack["avatars"].array
        let urls: [URL] = avatars.count > 32 ? [] : avatars.compactMap {
            $0["avatarViewModel"]["image"]["sources"].array.first?["url"].string.flatMap(URL.init(string:))
        }
        return MusicPlaylistCollaboration(label: label, avatarURLs: urls)
    }
}
