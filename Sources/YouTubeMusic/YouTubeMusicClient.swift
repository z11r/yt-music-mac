// Portions adapted from Kaset, copyright (c) 2025 sozercan, under the MIT License.
// See THIRD_PARTY_NOTICES.md for the license and upstream source paths.
import CryptoKit
import Foundation
import MusicCore

public actor YouTubeMusicClient {
    public enum LibraryCategory: String, CaseIterable, Hashable, Sendable {
        case all, playlists, albums, artists
        public var title: String {
            switch self {
            case .all: "Library"
            case .playlists: "Playlists"
            case .albums: "Albums"
            case .artists: "Artists"
            }
        }
        var browseID: String {
            switch self {
            case .all: "FEmusic_library_landing"
            case .playlists: "FEmusic_liked_playlists"
            case .albums: "FEmusic_liked_albums"
            case .artists: "FEmusic_library_corpus_artists"
            }
        }
    }

    public static let origin = URL(string: "https://music.youtube.com")!
    // The web client requires a browser-compatible user agent, including for anonymous configuration requests.
    public static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    /// Remote edits remain disabled until signed-in integration testing is complete.
    public nonisolated let libraryEditCapabilities: MusicLibraryEditCapabilities
    public nonisolated var supportsRemoteLibraryEdits: Bool { libraryEditCapabilities.hasAny }
    let transport: any MusicHTTPTransport
    let sessions: any MusicSessionProviding
    private let pause: @Sendable (Duration) async throws -> Void
    let now: @Sendable () -> Date
    private var bootstrapCache: (configuration: MusicClientConfiguration, expires: Date)?
    var libraryEditInProgress = false
    var pendingPlaylistEditCleanup: PendingPlaylistEditCleanup?

    public init(transport: any MusicHTTPTransport = URLSessionMusicTransport(),
                sessions: any MusicSessionProviding = MusicSessionStore(),
                libraryEditCapabilities: MusicLibraryEditCapabilities = .init(),
                pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.sessions = sessions
        self.libraryEditCapabilities = libraryEditCapabilities
        self.pause = pause
        self.now = now
    }

    public func home() async throws -> MusicPage { try await browse("FEmusic_home", title: "Home") }
    public func explore() async throws -> MusicPage { try await browse("FEmusic_explore", title: "Explore") }
    public func discovery(_ category: MusicDiscoveryCategory) async throws -> MusicPage {
        try await browse(category.browseID, title: category.title)
    }
    public func browse(_ reference: MusicBrowseReference) async throws -> MusicPage {
        guard reference.isValid else { throw MusicServiceError.invalidInput }
        var body = ["browseId": reference.browseID]
        if let params = reference.params { body["params"] = params }
        return try await firstPage(endpoint: .browse, body: body, title: reference.title,
                                   requiresAuthentication: false, preservesOccurrences: reference.kind == .playlist,
                                   expectedScope: reference.scope)
    }
    public func search(query: String, filter: MusicSearchFilter = .all) async throws -> MusicPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500 else { throw MusicServiceError.invalidInput }
        var body = ["query": query]
        if let params = filter.params { body["params"] = params }
        return try await firstPage(endpoint: .search, body: body, title: "Search", requiresAuthentication: false, preservesOccurrences: false)
    }
    public func library(category: LibraryCategory = .all) async throws -> MusicPage {
        var body = ["browseId": category.browseID]
        if case .artists = category { body["params"] = "ggMCCAU=" }
        return try await firstPage(endpoint: .browse, body: body, title: category.title, requiresAuthentication: true, preservesOccurrences: false)
    }
    /// Reads the account's listening history without changing it. Repeated
    /// plays remain distinct, including when they appear on different pages.
    public func history() async throws -> MusicPage {
        try await browse("FEmusic_history", title: "Listening History", requiresAuthentication: true, preservesOccurrences: true)
    }
    public func likedSongs() async throws -> MusicPage {
        try await browse("VLLM", title: "Liked Songs", requiresAuthentication: true, preservesOccurrences: true)
    }
    public func playlist(id: String) async throws -> MusicPage {
        guard !MusicUploadRoutes.isCollectionID(id) else { throw MusicServiceError.invalidInput }
        try validateIdentifier(id)
        let browseID = Self.playlistBrowseID(id)
        return try await browse(browseID, title: "Playlist", requiresAuthentication: ["VLLM", "VLSE"].contains(browseID), preservesOccurrences: true)
    }
    public func album(id: String) async throws -> MusicPage {
        if MusicUploadRoutes.isCollectionID(id) { return try await uploadedAlbum(id: id) }
        try validateIdentifier(id)
        let browseID = id.hasPrefix("OLAK") ? "VL" + id : id
        return try await browse(browseID, title: "Album", preservesOccurrences: true)
    }
    public func artist(id: String) async throws -> MusicPage {
        if MusicUploadRoutes.isCollectionID(id) { return try await uploadedArtist(id: id) }
        try validateIdentifier(id)
        return try await browse(id, title: "Artist")
    }

    public func nextPage(_ continuation: MusicContinuation) async throws -> MusicPage {
        switch try await readNextPage(continuation, includeStructure: false) {
        case let .page(page): return page
        case .unsupported: throw MusicServiceError.unsupportedResponse
        }
    }

    enum NextPageInspection {
        case page(MusicPage)
        case unsupported(MusicResponseStructure?)
    }

    func inspectNextPage(_ continuation: MusicContinuation) async throws -> NextPageInspection {
        try await readNextPage(continuation, includeStructure: true)
    }

    private func readNextPage(_ continuation: MusicContinuation, includeStructure: Bool) async throws -> NextPageInspection {
        let session = await sessions.snapshot()
        guard session.scope == continuation.scope else { throw MusicServiceError.sessionChanged }
        guard !continuation.previousTokens.contains(continuation.token) else { throw MusicServiceError.paginationLoop }
        let data = try await request(endpoint: continuation.endpoint, body: ["continuation": continuation.token],
                                     session: session, requiresAuthentication: continuation.requiresAuthentication)
        let parsed: ParsedMusicPage
        do {
            let prepared = try continuation.contentOrigin == .upload ? MusicUploadResponseAdapter.prepare(data, isSearch: continuation.endpoint == .search) : data
            parsed = try MusicResponseParser.parse(prepared, preservesOccurrences: continuation.preservesOccurrences)
            try validateUploadTracks(parsed, origin: continuation.contentOrigin)
        }
        catch MusicServiceError.unsupportedResponse {
            return .unsupported(includeStructure ? MusicResponseStructure.summarize(data) : nil)
        }
        var tokens = continuation.previousTokens
        tokens.insert(continuation.token)
        if let token = parsed.token, tokens.contains(token) { throw MusicServiceError.paginationLoop }
        return .page(makePage(parsed, title: continuation.title, endpoint: continuation.endpoint, session: session,
                        requiresAuthentication: continuation.requiresAuthentication,
                        preservesOccurrences: continuation.preservesOccurrences, previousTokens: tokens,
                        previousItems: continuation.previousItems, contentOrigin: continuation.contentOrigin))
    }

    /// Bounded collection for explicit exports or queue construction. The UI should load one page at a time.
    public func allPages(startingWith first: MusicPage, maximumPages: Int = 100) async throws -> [MusicPage] {
        guard maximumPages > 0, maximumPages <= 1000 else { throw MusicServiceError.invalidInput }
        var pages = [first]
        var continuation = first.continuation
        while let next = continuation {
            try Task.checkCancellation()
            guard pages.count < maximumPages else { throw MusicServiceError.pageLimitReached }
            let page = try await nextPage(next)
            pages.append(page)
            continuation = page.continuation
        }
        return pages
    }

    /// Resolves the current public web configuration without reading or sending any session cookies.
    public func bootstrapConfiguration() async throws -> MusicClientConfiguration {
        try Task.checkCancellation()
        if let cache = bootstrapCache, cache.expires > now() { return cache.configuration }
        var request = URLRequest(url: Self.origin)
        request.httpShouldHandleCookies = false
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let response = try await send(request)
        guard let html = String(data: response.data, encoding: .utf8),
              let apiKey = Self.configurationValue("INNERTUBE_API_KEY", html: html),
              let version = Self.configurationValue("INNERTUBE_CLIENT_VERSION", html: html)
                ?? Self.configurationValue("INNERTUBE_CONTEXT_CLIENT_VERSION", html: html)
        else { throw MusicServiceError.configurationUnavailable }
        let configuration = MusicClientConfiguration(apiKey: apiKey, clientVersion: version,
                                                     visitorData: Self.configurationValue("VISITOR_DATA", html: html))
        bootstrapCache = (configuration, now().addingTimeInterval(6 * 60 * 60))
        return configuration
    }

    private func browse(_ id: String, title: String, requiresAuthentication: Bool = false, preservesOccurrences: Bool = false) async throws -> MusicPage {
        try await firstPage(endpoint: .browse, body: ["browseId": id], title: title,
                            requiresAuthentication: requiresAuthentication, preservesOccurrences: preservesOccurrences)
    }

    func firstPage(endpoint: MusicEndpoint, body: [String: String], title: String,
                   requiresAuthentication: Bool, preservesOccurrences: Bool, expectedScope: UUID? = nil,
                   contentOrigin: MusicContentOrigin? = nil) async throws -> MusicPage {
        let session = await sessions.snapshot()
        if let expectedScope, expectedScope != session.scope { throw MusicServiceError.sessionChanged }
        let data = try await request(endpoint: endpoint, body: body, session: session, requiresAuthentication: requiresAuthentication)
        let prepared = try contentOrigin == .upload ? MusicUploadResponseAdapter.prepare(data, isSearch: endpoint == .search) : data
        let parsed = try MusicResponseParser.parse(prepared, preservesOccurrences: preservesOccurrences)
        try validateUploadTracks(parsed, origin: contentOrigin)
        return makePage(parsed, title: title, endpoint: endpoint, session: session,
                        requiresAuthentication: requiresAuthentication, preservesOccurrences: preservesOccurrences, contentOrigin: contentOrigin)
    }

    private func makePage(_ parsed: ParsedMusicPage, title: String, endpoint: MusicEndpoint, session: MusicSession,
                          requiresAuthentication: Bool, preservesOccurrences: Bool,
                          previousTokens: Set<String> = [], previousItems: Set<String> = [], contentOrigin: MusicContentOrigin? = nil) -> MusicPage {
        var seen = previousItems
        let sections = parsed.sections.compactMap { section -> MusicSection? in
            let items = section.items.filter { preservesOccurrences || seen.insert($0.id).inserted }.map { item in
                if contentOrigin == .upload, case var .track(track) = item {
                    track.origin = .upload
                    return MusicItem.track(track)
                }
                if case let .browse(reference) = item { return MusicItem.browse(reference.scoped(to: session.scope)) }
                return item
            }
            guard !items.isEmpty || section.browseReference != nil else { return nil }
            return MusicSection(id: "page\(previousTokens.count).\(section.id)", title: section.title, items: items,
                                browseReference: section.browseReference?.scoped(to: session.scope))
        }
        let next = parsed.token.map {
            MusicContinuation(token: $0, endpoint: endpoint, scope: session.scope, title: parsed.title ?? title,
                              requiresAuthentication: requiresAuthentication, preservesOccurrences: preservesOccurrences,
                              previousTokens: previousTokens, previousItems: seen, contentOrigin: contentOrigin)
        }
        return MusicPage(title: parsed.title ?? title, sections: sections, items: sections.flatMap(\.items), continuation: next,
                         playlistItems: parsed.playlistItems.map { item in
                            guard contentOrigin == .upload else { return item }
                            var track = item.track; track.origin = .upload
                            return MusicPlaylistItem(track: track, setVideoID: item.setVideoID)
                         }, playlistCapabilities: parsed.playlistCapabilities,
                         likeStates: parsed.likeStates, ratings: parsed.ratings,
                         unavailableItemCount: parsed.unavailableItemCount,
                         hasUnsupportedContent: parsed.hasUnsupportedContent,
                         playlistDetails: parsed.playlistDetails, albumLibraryState: parsed.albumLibraryState,
                         artistSubscription: parsed.artistSubscription)
    }

    private func validateUploadTracks(_ page: ParsedMusicPage, origin: MusicContentOrigin?) throws {
        guard origin == .upload else { return }
        for item in page.items {
            if case let .track(track) = item, !MusicUploadRoutes.isVideoID(track.id) { throw MusicServiceError.unsupportedResponse }
            if case let .collection(collection) = item, !collection.isUploaded { throw MusicServiceError.unsupportedResponse }
        }
    }

    func request(endpoint: MusicEndpoint, body: [String: Any], session: MusicSession, requiresAuthentication: Bool) async throws -> Data {
        try Task.checkCancellation()
        if requiresAuthentication && !session.isAuthenticated { throw MusicServiceError.signInRequired }
        let configuration: MusicClientConfiguration
        if let supplied = session.configuration { configuration = supplied }
        else { configuration = try await bootstrapConfiguration() }
        try await validateScope(session.scope)
        guard !configuration.apiKey.isEmpty, !configuration.clientVersion.isEmpty,
              !configuration.clientVersion.contains(where: { $0 == "\r" || $0 == "\n" })
        else { throw MusicServiceError.configurationUnavailable }
        var url = URLComponents(url: Self.origin.appendingPathComponent("youtubei/v1/\(endpoint.rawValue)"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey), URLQueryItem(name: "prettyPrint", value: "false")]
        var request = URLRequest(url: url.url!)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.origin.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue("67", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(configuration.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        var client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": configuration.clientVersion,
                                   "hl": configuration.language, "gl": configuration.region, "platform": "DESKTOP",
                                   "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60]
        if let visitor = configuration.visitorData { client["visitorData"] = visitor }
        var user: [String: Any] = ["lockedSafetyMode": false]
        if session.isAuthenticated, let cookie = session.cookieHeader, let sapisid = session.sapisid {
            guard !cookie.contains(where: { $0 == "\r" || $0 == "\n" }) else { throw MusicServiceError.invalidInput }
            let timestamp = Int(now().timeIntervalSince1970)
            let input = "\(timestamp) \(sapisid) \(Self.origin.absoluteString)"
            let hash = Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("SAPISIDHASH \(timestamp)_\(hash)", forHTTPHeaderField: "Authorization")
            request.setValue(String(session.authUser), forHTTPHeaderField: "X-Goog-AuthUser")
            request.setValue(Self.origin.absoluteString, forHTTPHeaderField: "X-Origin")
            if let delegated = session.delegatedSessionID { user["onBehalfOfUser"] = delegated }
        }
        var fullBody: [String: Any] = body
        fullBody["context"] = ["client": client, "user": user]
        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)
        let response = try await send(request, scope: session.scope)
        try await validateScope(session.scope)
        return response.data
    }

    private func send(_ request: URLRequest, scope: UUID? = nil) async throws -> MusicHTTPResponse {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if let scope { try await validateScope(scope) }
            do {
                let response = try await transport.send(request)
                try Task.checkCancellation()
                if let scope { try await validateScope(scope) }
                guard response.data.count <= 12 * 1024 * 1024 else { throw MusicServiceError.invalidResponse }
                if (200..<300).contains(response.statusCode) { return response }
                if response.statusCode == 401 { throw MusicServiceError.authenticationRejected }
                if response.statusCode == 403 { throw MusicServiceError.accessDenied }
                if response.statusCode == 429 || (500...599).contains(response.statusCode) {
                    if attempt < 2 {
                        let retryHeader = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
                        let retryAfter = retryHeader.flatMap { Double($0) }
                        // Leave long or date-based server delays to the caller; never retry ahead of them.
                        if retryHeader != nil && (retryAfter == nil || retryAfter!.isFinite == false || retryAfter! > 15) {
                            throw response.statusCode == 429 ? MusicServiceError.rateLimited : MusicServiceError.serviceUnavailable
                        }
                        let delay = max(0, retryAfter ?? pow(2, Double(attempt)))
                        try await pause(.milliseconds(Int64(delay * 1000)))
                        continue
                    }
                    throw response.statusCode == 429 ? MusicServiceError.rateLimited : MusicServiceError.serviceUnavailable
                }
                throw MusicServiceError.httpStatus(response.statusCode)
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                if attempt < 2 && [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
                    try await pause(.seconds(attempt + 1))
                    continue
                }
                throw MusicServiceError.network(error.code)
            } catch let error as MusicServiceError { throw error }
            catch { throw MusicServiceError.network(.unknown) }
        }
        throw MusicServiceError.serviceUnavailable
    }

    func validateScope(_ scope: UUID) async throws {
        try Task.checkCancellation()
        guard await sessions.snapshot().scope == scope else { throw MusicServiceError.sessionChanged }
    }

    func validateIdentifier(_ id: String) throws {
        guard !id.isEmpty, id.count <= 256, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { throw MusicServiceError.invalidInput }
    }

    static func playlistBrowseID(_ id: String) -> String {
        ["VL", "RD", "MPRE", "UC"].contains(where: { id.hasPrefix($0) }) ? id : "VL" + id
    }

    static func configurationValue(_ key: String, html: String) -> String? {
        let pattern = "\"" + NSRegularExpression.escapedPattern(for: key) + #""\s*:\s*("(?:[^"\\]|\\.)*")"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let range = Range(match.range(at: 1), in: html),
              let value = try? JSONDecoder().decode(String.self, from: Data(html[range].utf8)), !value.isEmpty else { return nil }
        return value
    }
}
