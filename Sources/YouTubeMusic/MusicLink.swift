import Foundation

/// A music destination, stripped of tracking parameters and unrelated navigation.
public enum MusicLink: Hashable, Sendable {
    case track(String)
    case playlist(String)
    case album(String)
    case artist(String)

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil else { return nil }
        let scheme = parts.scheme?.lowercased()
        let host = parts.host?.lowercased() ?? ""
        let path: String
        if scheme == "https" {
            guard parts.port == nil || parts.port == 443 else { return nil }
            if host == "youtu.be" {
                let id = String(parts.path.dropFirst())
                guard Self.isVideoID(id) else { return nil }
                self = .track(id)
                return
            }
            guard ["music.youtube.com", "youtube.com", "www.youtube.com", "m.youtube.com"].contains(host) else { return nil }
            path = parts.path
        } else if ["ytmusicmac", "ytmusicmac-debug"].contains(scheme ?? "") {
            guard parts.port == nil, !host.isEmpty else { return nil }
            path = "/" + host + parts.path
        } else { return nil }
        func parameter(_ name: String) -> String? {
            let values = (parts.queryItems ?? []).filter { $0.name == name }
            return values.count == 1 ? values[0].value : nil
        }
        if path == "/watch", let id = parameter("v"), Self.isVideoID(id) {
            self = .track(id)
        } else if path == "/playlist", let id = parameter("list"), Self.isIdentifier(id) {
            let playlist = Self.playlistID(id)
            guard Self.isIdentifier(playlist) else { return nil }
            self = id.hasPrefix("OLAK") ? .album(id) : .playlist(playlist)
        } else if path.hasPrefix("/browse/") || path.hasPrefix("/channel/") {
            let id = String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
            guard path.split(separator: "/").count == 2, Self.isIdentifier(id) else { return nil }
            if id.hasPrefix("UC") { self = .artist(id) }
            else if id.hasPrefix("MPRE") || id.hasPrefix("OLAK") { self = .album(id) }
            else if id.hasPrefix("VL"), Self.isIdentifier(Self.playlistID(id)) { self = .playlist(Self.playlistID(id)) }
            else { return nil }
        } else { return nil }
    }

    public var url: URL? {
        let id: String
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "music.youtube.com"
        switch self {
        case let .track(value):
            guard Self.isVideoID(value) else { return nil }
            id = value
            parts.path = "/watch"
            parts.queryItems = [URLQueryItem(name: "v", value: id)]
        case let .playlist(value):
            id = Self.playlistID(value)
            guard Self.isIdentifier(id) else { return nil }
            parts.path = "/playlist"
            parts.queryItems = [URLQueryItem(name: "list", value: id)]
        case let .album(value):
            guard Self.isIdentifier(value) else { return nil }
            id = value
            if id.hasPrefix("OLAK") {
                parts.path = "/playlist"
                parts.queryItems = [URLQueryItem(name: "list", value: id)]
            } else {
                parts.path = "/browse/" + id
            }
        case let .artist(value):
            guard Self.isIdentifier(value) else { return nil }
            id = value
            parts.path = "/channel/" + id
        }
        return parts.url
    }

    public static func collection(_ value: MusicCollection) -> MusicLink {
        switch value.kind {
        case .playlist: .playlist(value.id)
        case .album: .album(value.id)
        case .artist: .artist(value.id)
        }
    }

    private static func isVideoID(_ id: String) -> Bool { id.utf8.count == 11 && isIdentifier(id) }
    private static func isIdentifier(_ id: String) -> Bool {
        (1...256).contains(id.utf8.count) && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private static func playlistID(_ id: String) -> String { id.hasPrefix("VL") ? String(id.dropFirst(2)) : id }
}
