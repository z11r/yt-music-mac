// Artist description paths follow ytmusicapi's get_artist (MIT License).
// See THIRD_PARTY_NOTICES.md and docs/COLLECTION_DETAILS.md.
import Foundation

/// Plain service text, including supplied credits. URLs are displayed, never opened.
public struct MusicArtistAbout: Hashable, Sendable {
    public let text: String
    public let sourceURLs: [String]

    public init?(text: String, sourceURLs: [String] = []) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16_384,
              !text.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" || $0.value == 127 }),
              sourceURLs.count <= 8, sourceURLs.allSatisfy(Self.permitsURL) else { return nil }
        self.text = text
        var seen: Set<String> = []
        self.sourceURLs = sourceURLs.filter { seen.insert($0).inserted }
    }
    private static func permitsURL(_ value: String) -> Bool {
        guard value.utf8.count <= 2_048, !value.lowercased().contains("%00"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.port == nil || url.port == 80 || url.port == 443 else { return false }
        return true
    }
}

enum MusicArtistAboutParser {
    static func parse(_ root: JSONNode) -> MusicArtistAbout? {
        // The artist request can return a different subscription channel ID.
        // Never use that button, related cards, or arbitrary nested descriptions as identity.
        let header = root["header"]["musicImmersiveHeaderRenderer"]
        guard case let .object(headers) = root["header"], case .object = header,
              !["musicDetailHeaderRenderer", "musicResponsiveHeaderRenderer", "musicVisualHeaderRenderer", "musicEditablePlaylistDetailHeaderRenderer"].contains(where: { headers[$0] != nil }) else { return nil }
        guard let selected = primarySections(root) else { return nil }
        let shelves = selected.filter { hasKey("musicDescriptionShelfRenderer", in: $0) }
        guard shelves.count <= 1 else { return nil }
        // An advertised malformed shelf cannot be bypassed with a header fallback.
        let description: JSONNode
        if let shelf = shelves.first {
            guard case .object = shelf["musicDescriptionShelfRenderer"] else { return nil }
            guard !hasKey("footer", in: shelf["musicDescriptionShelfRenderer"]) else { return nil }
            description = shelf["musicDescriptionShelfRenderer"]["description"]
        } else { description = header["description"] }
        guard case let .array(runs) = description["runs"], !runs.isEmpty, runs.count <= 256 else { return nil }
        var text = "", urls: [String] = [], seen: Set<String> = []
        for run in runs {
            guard case let .string(value) = run["text"], value.utf8.count <= 16_384 else { return nil }
            text += value
            guard text.utf8.count <= 16_384 else { return nil }
            let endpoint = run["navigationEndpoint"]
            if hasKey("navigationEndpoint", in: run) { guard case .object = endpoint else { return nil } }
            if hasKey("urlEndpoint", in: endpoint) {
                guard let url = endpoint["urlEndpoint"]["url"].string else { return nil }
                if seen.insert(url).inserted { urls.append(url) }
                guard urls.count <= 8 else { return nil }
            }
        }
        return MusicArtistAbout(text: text, sourceURLs: urls)
    }

    /// Direct description shelves only, from the selected primary artist tab.
    private static func primarySections(_ root: JSONNode) -> [JSONNode]? {
        let contents = root["contents"]
        if hasKey("contents", in: root) { guard case .object = contents else { return nil } }
        let keys = ["singleColumnBrowseResultsRenderer", "twoColumnBrowseResultsRenderer"].filter { hasKey($0, in: contents) }
        guard keys.count <= 1 else { return nil }
        // A supplied immersive-header description is independently usable when
        // the response has no tabbed primary content at all.
        guard let key = keys.first else { return [] }
        guard case let .array(tabs) = contents[key]["tabs"], !tabs.isEmpty, tabs.count <= 8,
              tabs.allSatisfy({ tab in
                  let renderer = tab["tabRenderer"]
                  guard case .object = renderer else { return false }
                  return ["selected", "disabled", "unselectable"].allSatisfy { !hasKey($0, in: renderer) || renderer[$0].bool != nil }
              }) else { return nil }
        let selected = tabs.filter { $0["tabRenderer"]["selected"].bool == true }
        let tab: JSONNode
        if selected.count == 1 { tab = selected[0]["tabRenderer"] }
        else if selected.isEmpty, tabs.count == 1, !hasKey("selected", in: tabs[0]["tabRenderer"]) { tab = tabs[0]["tabRenderer"] }
        else { return nil }
        guard tab["disabled"].bool != true, tab["unselectable"].bool != true,
              case let .array(items) = tab["content"]["sectionListRenderer"]["contents"], items.count <= 128 else { return nil }
        return items
    }
    private static func hasKey(_ key: String, in node: JSONNode) -> Bool {
        guard case let .object(values) = node else { return false }
        return values[key] != nil
    }
}
