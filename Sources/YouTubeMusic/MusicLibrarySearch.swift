// Request shapes follow ytmusicapi, copyright (c) 2026 sigma67, MIT License.
// See THIRD_PARTY_NOTICES.md for the pinned search and continuation sources.
import Foundation
import MusicCore

public enum MusicLibrarySearchFilter: String, CaseIterable, Hashable, Sendable {
    case songs, videos, albums, artists, playlists, podcasts, episodes
    var params: String {
        let token: String
        switch self {
        case .songs: token = "II"
        case .videos: token = "IQ"
        case .albums: token = "IY"
        case .artists: token = "Ig"
        case .playlists: token = "Io"
        case .podcasts: token = "JQ"
        case .episodes: token = "JI"
        }
        return "EgWKAQ" + token + "AWoKEAUQCRADEAoYBA%3D%3D"
    }
}

struct MusicLibrarySearchContext: Sendable {
    let query: String
    let filter: MusicLibrarySearchFilter
    var body: [String: String] { ["query": query, "params": filter.params] }
    var isValid: Bool {
        !query.isEmpty && query.count <= 500 && query.utf8.count <= 4_096 &&
        !query.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

extension YouTubeMusicClient {
    public func searchLibrary(query: String, filter: MusicLibrarySearchFilter, expectedScope: UUID) async throws -> MusicPage {
        try Task.checkCancellation()
        let context = MusicLibrarySearchContext(query: query.trimmingCharacters(in: .whitespacesAndNewlines), filter: filter)
        guard context.isValid else { throw MusicServiceError.invalidInput }
        let session = await sessions.snapshot()
        guard session.scope == expectedScope else { throw MusicServiceError.sessionChanged }
        guard session.isAuthenticated else { throw MusicServiceError.signInRequired }
        let data = try await request(endpoint: .search, body: context.body, session: session, requiresAuthentication: true, checksScopeBeforeBootstrap: true)
        let parsed = try MusicResponseParser.parse(MusicLibrarySearchAdapter.prepare(data, continuation: false), preservesOccurrences: false)
        try MusicLibrarySearchAdapter.validate(parsed)
        return makePage(parsed, title: ServiceLocalization.text("Search Your Library"), endpoint: .search, session: session,
            requiresAuthentication: true, preservesOccurrences: false, librarySearch: context)
    }
}

enum MusicLibrarySearchAdapter {
    static func prepare(_ data: Data, continuation: Bool) throws -> Data {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw MusicServiceError.invalidResponse }
        guard var root = object as? [String: Any] else { throw MusicServiceError.invalidResponse }
        if root["error"] != nil { return data }
        if continuation {
            guard let containers = root["continuationContents"] as? [String: Any], containers.count == 1,
                  let shelf = containers["musicShelfContinuation"] as? [String: Any],
                  shelf["contents"] is [Any] || shelf["items"] is [Any] else { throw MusicServiceError.unsupportedResponse }
            try budget(shelf)
        } else {
            guard var contents = root["contents"] as? [String: Any] else { throw MusicServiceError.unsupportedResponse }
            if let tabbed = contents["tabbedSearchResultsRenderer"] as? [String: Any] {
                // Filtered library search has one result tab. Multiple tabs can
                // contain catalog/uploads: never traverse or guess among them.
                guard contents.count == 1, let tabs = tabbed["tabs"] as? [[String: Any]], tabs.count == 1,
                      let tab = tabs[0]["tabRenderer"] as? [String: Any], tab["selected"] as? Bool != false,
                      let content = tab["content"] as? [String: Any] else { throw MusicServiceError.unsupportedResponse }
                contents = content
            }
            guard contents.count == 1, contents["sectionListRenderer"] != nil || contents["itemSectionRenderer"] != nil || contents["musicShelfRenderer"] != nil else {
                throw MusicServiceError.unsupportedResponse
            }
            try budget(contents)
            root["contents"] = contents
        }
        return try JSONSerialization.data(withJSONObject: root)
    }
    static func validate(_ parsed: ParsedMusicPage) throws {
        guard parsed.items.count <= 1_000 else { throw MusicServiceError.pageLimitReached }
        for item in parsed.items {
            switch item {
            case let .collection(value): if value.isUploaded { throw MusicServiceError.unsupportedResponse }
            case let .track(value): if value.origin == .upload { throw MusicServiceError.unsupportedResponse }
            case .browse: throw MusicServiceError.unsupportedResponse
            }
        }
    }
    private static func budget(_ value: Any) throws {
        var nodes = 0, rows = 0
        func visit(_ value: Any, depth: Int) throws {
            nodes += 1
            guard depth <= 40, nodes <= 50_000 else { throw MusicServiceError.pageLimitReached }
            if let array = value as? [Any] { for child in array { try visit(child, depth: depth + 1) } }
            if let object = value as? [String: Any] {
                guard object["musicDeletePrivatelyOwnedEntityCommand"] == nil else { throw MusicServiceError.unsupportedResponse }
                if object["musicResponsiveListItemRenderer"] != nil || object["musicTwoRowItemRenderer"] != nil || object["musicMultiRowListItemRenderer"] != nil { rows += 1 }
                guard rows <= 1_000 else { throw MusicServiceError.pageLimitReached }
                if let id = object["browseId"] as? String, id.hasPrefix("FEmusic_library_privately_owned") { throw MusicServiceError.unsupportedResponse }
                for child in object.values { try visit(child, depth: depth + 1) }
            }
        }
        try visit(value, depth: 0)
    }
}
