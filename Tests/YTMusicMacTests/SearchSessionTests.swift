import Foundation
import Testing
import WebKit
@testable import YouTubeMusic
@testable import YTMusicMac

/// Drives `AppSession` against a local transport. No request leaves the process.
@Suite("Search session") @MainActor
struct SearchSessionTests {
    private static let songs = MusicSearchFilter.songs.params!
    private static let videos = MusicSearchFilter.videos.params!
    private static let albums = MusicSearchFilter.albums.params!

    @Test func anOlderSearchNeverReplacesANewerOne() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "search:first|", with: searchPage(["first-song"]), hold: true)
        await transport.respond(to: "search:second|", with: searchPage(["second-song"]))
        let harness = SessionHarness(transport)
        defer { harness.remove() }
        let session = harness.session
        session.searchText = "first"
        session.submitSearch()
        let older = session.pageTask
        await transport.waitForArrival("search:first|")
        session.searchText = "second"
        session.submitSearch()
        await session.pageTask?.value
        #expect(trackIDs(session) == ["second-song"])
        await transport.release("search:first|")
        await older?.value
        #expect(trackIDs(session) == ["second-song"])
        #expect(session.destination == .search("second"))
        #expect(!session.isLoading)
    }

    @Test func changingTheFilterReloadsTheSearchAndIgnoresTheOlderResponse() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "search:example|", with: searchPage(["mixed"]), hold: true)
        await transport.respond(to: "search:example|\(Self.songs)", with: searchPage(["song"]))
        let harness = SessionHarness(transport)
        defer { harness.remove() }
        let session = harness.session
        session.searchText = "example"
        session.submitSearch()
        let older = session.pageTask
        await transport.waitForArrival("search:example|")
        session.searchFilter = .songs
        await session.pageTask?.value
        await transport.release("search:example|")
        await older?.value
        #expect(trackIDs(session) == ["song"])
        #expect(session.destination == .search("example"))
        #expect(await transport.keys == ["search:example|", "search:example|\(Self.songs)"])
    }

    @Test func theFilterStaysForNewQueriesAndIsNotSentWhileBrowsing() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "search:one|\(Self.albums)", with: searchPage(["one"]))
        await transport.respond(to: "search:two|\(Self.albums)", with: searchPage(["two"]))
        let harness = SessionHarness(transport)
        defer { harness.remove() }
        let session = harness.session
        session.searchFilter = .albums
        #expect(await transport.keys.isEmpty, "Choosing a filter outside search loads nothing.")
        session.searchText = "one"
        session.submitSearch()
        await session.pageTask?.value
        session.searchText = "two"
        session.submitSearch()
        await session.pageTask?.value
        #expect(session.searchFilter == .albums)
        #expect(trackIDs(session) == ["two"])
        #expect(await transport.keys == ["search:one|\(Self.albums)", "search:two|\(Self.albums)"])
    }

    @Test func loadMoreContinuesFilteredResults() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "search:example|\(Self.songs)", with: searchPage(["a", "b"], token: "page-2"))
        await transport.respond(to: "next:page-2", with: continuationPage(["b", "c"]))
        let harness = SessionHarness(transport)
        defer { harness.remove() }
        let session = harness.session
        session.searchFilter = .songs
        session.searchText = "example"
        session.submitSearch()
        await session.pageTask?.value
        session.loadMore()
        await session.pageTask?.value
        #expect(trackIDs(session) == ["a", "b", "c"])
        #expect(session.page?.continuation == nil)
        #expect(await transport.keys == ["search:example|\(Self.songs)", "next:page-2"])
    }

    @Test func aLoadMoreForTheOldFilterNeverAddsToTheNewResults() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "search:example|\(Self.songs)", with: searchPage(["song"], token: "page-2"))
        await transport.respond(to: "next:page-2", with: continuationPage(["late-song"]), hold: true)
        await transport.respond(to: "search:example|\(Self.videos)", with: searchPage(["video"]))
        let harness = SessionHarness(transport)
        defer { harness.remove() }
        let session = harness.session
        session.searchFilter = .songs
        session.searchText = "example"
        session.submitSearch()
        await session.pageTask?.value
        session.loadMore()
        let older = session.pageTask
        await transport.waitForArrival("next:page-2")
        session.searchFilter = .videos
        await session.pageTask?.value
        await transport.release("next:page-2")
        await older?.value
        #expect(trackIDs(session) == ["video"])
        #expect(!session.isLoadingMore)
    }

    @Test func returnSearchesTheHighlightedSuggestionWithoutReopeningTheList() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "suggest:exam", with: suggestionPage(["example", "example song"]))
        await transport.respond(to: "search:example song|", with: searchPage(["song"]))
        let harness = SessionHarness(transport)
        defer { harness.remove() }
        let session = harness.session
        session.searchText = "exam"
        session.searchTextChanged()
        await session.searchSuggestions.task?.value
        #expect(session.searchSuggestions.items.map(\.query) == ["example", "example song"])
        session.searchSuggestions.moveHighlight(by: 1)
        session.searchSuggestions.moveHighlight(by: 1)
        session.submitSearch()
        #expect(session.searchText == "example song")
        #expect(session.destination == .search("example song"))
        #expect(!session.searchSuggestions.isVisible)
        // The search field reports the filled-in text as a change.
        session.searchTextChanged()
        #expect(session.searchSuggestions.task == nil)
        await session.pageTask?.value
        #expect(trackIDs(session) == ["song"])
        #expect(await transport.keys == ["suggest:exam", "search:example song|"])
    }

    @Test func returnWithNothingHighlightedSearchesTheTypedText() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "suggest:exam", with: suggestionPage(["example"]))
        await transport.respond(to: "search:exam|", with: searchPage(["typed"]))
        let harness = SessionHarness(transport)
        defer { harness.remove() }
        let session = harness.session
        session.searchText = "exam"
        session.searchTextChanged()
        await session.searchSuggestions.task?.value
        #expect(session.searchSuggestions.isVisible)
        session.submitSearch()
        #expect(session.searchText == "exam")
        #expect(session.destination == .search("exam"))
        #expect(!session.searchSuggestions.isVisible)
        await session.pageTask?.value
        #expect(trackIDs(session) == ["typed"])
    }

    @Test func choosingASuggestionWithThePointerSearchesForIt() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "search:picked|", with: searchPage(["picked"]))
        let harness = SessionHarness(transport)
        defer { harness.remove() }
        let session = harness.session
        session.searchText = "pi"
        session.search(for: MusicSearchSuggestion(query: "picked"))
        session.searchTextChanged()
        #expect(session.searchSuggestions.task == nil)
        await session.pageTask?.value
        #expect(session.destination == .search("picked"))
        #expect(trackIDs(session) == ["picked"])
    }

    @Test func submittedQueriesAreRememberedButFilterChangesDoNotAddEntries() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "search:example|", with: searchPage(["song"]))
        await transport.respond(to: "search:example|\(Self.songs)", with: searchPage(["song"]))
        let harness = SessionHarness(transport)
        defer { harness.remove() }
        let session = harness.session
        session.searchText = " example "
        session.submitSearch()
        await session.pageTask?.value
        session.searchFilter = .songs
        await session.pageTask?.value
        #expect(session.searchHistory.queries == ["example"])
    }

    @Test func anAccountBoundaryClearsLocalQueriesAndFencesOldSuggestions() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "suggest:old", with: suggestionPage(["private suggestion"]), hold: true)
        let harness = SessionHarness(transport)
        defer { harness.remove() }
        let session = harness.session
        session.searchHistory.record("private query")
        session.searchText = "old"
        session.searchTextChanged()
        let older = session.searchSuggestions.task
        await transport.waitForArrival("suggest:old")
        session.account.onAccountChanged?(true)
        await transport.release("suggest:old")
        await older?.value
        await session.pageTask?.value
        #expect(session.searchHistory.queries.isEmpty)
        #expect(session.searchSuggestions.items.isEmpty)
        #expect(session.searchText.isEmpty)
    }

    @Test func libraryCategoriesHaveNativeDestinationsAndServiceRoutes() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "browse:FEmusic_liked_albums", with: searchPage(["album-song"]))
        await transport.respond(to: "browse:FEmusic_library_corpus_artists", with: searchPage(["artist-song"]))
        let harness = SessionHarness(transport, authenticated: true)
        defer { harness.remove() }
        let session = harness.session
        session.navigate(to: .libraryCategory(.albums))
        await session.pageTask?.value
        #expect(session.destination.title == "Albums")
        #expect(session.destination.libraryCategory == .albums)
        #expect(trackIDs(session) == ["album-song"])
        session.navigate(to: .libraryCategory(.artists))
        await session.pageTask?.value
        #expect(session.destination.title == "Artists")
        session.goBack()
        await session.pageTask?.value
        #expect(session.destination == .libraryCategory(.albums))
        #expect(await transport.keys == ["browse:FEmusic_liked_albums", "browse:FEmusic_library_corpus_artists", "browse:FEmusic_liked_albums"])
    }

    @Test func anOlderLibraryResponseCannotReplaceListeningHistory() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "browse:FEmusic_liked_albums", with: searchPage(["late-album"]), hold: true)
        await transport.respond(to: "browse:FEmusic_history", with: searchPage(["same", "same"]))
        let harness = SessionHarness(transport, authenticated: true)
        defer { harness.remove() }
        let session = harness.session
        session.navigate(to: .libraryCategory(.albums))
        let older = session.pageTask
        await transport.waitForArrival("browse:FEmusic_liked_albums")
        session.navigate(to: .history)
        await session.pageTask?.value
        await transport.release("browse:FEmusic_liked_albums")
        await older?.value
        #expect(session.destination == .history)
        #expect(session.destination.libraryCategory == nil)
        #expect(trackIDs(session) == ["same", "same"])
        #expect(!session.isLoading)
    }

    @Test func failedHistoryPagingKeepsVisiblePlaysAndCanBeRetried() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "browse:FEmusic_history", with: searchPage(["same"], token: "older-history"))
        await transport.respond(to: "next:older-history", with: data([:]))
        let harness = SessionHarness(transport, authenticated: true)
        defer { harness.remove() }
        let session = harness.session
        session.navigate(to: .history)
        await session.pageTask?.value
        session.loadMore()
        await session.pageTask?.value
        #expect(session.pageError != nil)
        #expect(trackIDs(session) == ["same"])
        #expect(session.page?.continuation != nil)
        await transport.respond(to: "next:older-history", with: continuationPage(["same", "older"]))
        session.loadMore()
        await session.pageTask?.value
        #expect(session.pageError == nil)
        #expect(trackIDs(session) == ["same", "same", "older"])
        #expect(session.page?.continuation == nil)
    }

    @Test func switchingFromDiscoveryDiscardsItsLateResponse() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "browse:FEmusic_charts", with: searchPage(["late-chart"]), hold: true)
        await transport.respond(to: "browse:UCdiscography", with: searchPage(["album-result"]))
        let harness = SessionHarness(transport)
        defer { harness.remove() }
        let session = harness.session
        session.navigate(to: .discovery(.charts))
        let older = session.pageTask
        await transport.waitForArrival("browse:FEmusic_charts")
        let target = MusicBrowseReference(browseID: "UCdiscography", params: "albums-scope", title: "Albums", kind: .discography)
        session.navigate(to: .browse(target))
        await session.pageTask?.value
        await transport.release("browse:FEmusic_charts")
        await older?.value
        #expect(session.destination == .browse(target))
        #expect(trackIDs(session) == ["album-result"])
        #expect(!session.isLoading)
    }

    @Test func browseFailureKeepsItsDestinationAndRetriesThroughReload() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "browse:UCdiscography", with: data(["unknownRenderer": [:]]))
        let harness = SessionHarness(transport)
        defer { harness.remove() }
        let session = harness.session
        let target = MusicBrowseReference(browseID: "UCdiscography", params: "albums-scope", title: "Albums", kind: .discography)
        session.navigate(to: .browse(target))
        await session.pageTask?.value
        #expect(session.pageError != nil)
        #expect(session.page == nil)
        #expect(session.destination == .browse(target))
        await transport.respond(to: "browse:UCdiscography", with: searchPage(["recovered"]))
        session.reload()
        await session.pageTask?.value
        #expect(session.pageError == nil)
        #expect(trackIDs(session) == ["recovered"])
    }

    @Test func browseLoadMoreNeverAppendsAfterChangingDiscoveryCategory() async throws {
        let transport = RoutedTransport()
        await transport.respond(to: "browse:UCdiscography", with: searchPage(["album"], token: "more-albums"))
        await transport.respond(to: "next:more-albums", with: continuationPage(["late-album"]), hold: true)
        await transport.respond(to: "browse:FEmusic_new_releases", with: searchPage(["release"]))
        let harness = SessionHarness(transport)
        defer { harness.remove() }
        let session = harness.session
        session.navigate(to: .browse(MusicBrowseReference(browseID: "UCdiscography", title: "Albums", kind: .discography)))
        await session.pageTask?.value
        session.loadMore()
        let older = session.pageTask
        await transport.waitForArrival("next:more-albums")
        session.navigate(to: .discovery(.newReleases))
        await session.pageTask?.value
        await transport.release("next:more-albums")
        await older?.value
        #expect(session.destination == .discovery(.newReleases))
        #expect(trackIDs(session) == ["release"])
        #expect(!session.isLoadingMore)
    }

    private func trackIDs(_ session: AppSession) -> [String] {
        session.page?.tracks.map(\.id) ?? []
    }
}

@MainActor
private struct SessionHarness {
    let session: AppSession
    private let domain = "io.github.z11r.ytmusicmac.tests.search.\(UUID().uuidString)"

    init(_ transport: RoutedTransport, authenticated: Bool = false) {
        let preferences = UserDefaults(suiteName: domain)!
        let client = YouTubeMusicClient(transport: transport, sessions: FixtureSession(authenticated: authenticated), pause: { _ in })
        session = AppSession(configuration: AppSessionConfiguration(
            preferences: preferences, dataStore: .nonPersistent(), credentials: MusicSessionStore(), client: client,
            queueStore: nil, queueStorageError: nil, installsSystemMedia: false, isSceneCheck: false))
    }

    func remove() { UserDefaults.standard.removePersistentDomain(forName: domain) }
}

private struct FixtureSession: MusicSessionProviding {
    let value: MusicSession
    init(authenticated: Bool = false) {
        value = MusicSession(scope: UUID(), accountID: authenticated ? "fixture-account" : nil,
            cookieHeader: authenticated ? "fixture=value" : nil, sapisid: authenticated ? "fixture" : nil,
            configuration: MusicClientConfiguration(apiKey: "fixture-key", clientVersion: "fixture-version"))
    }
    func snapshot() async -> MusicSession { value }
}

/// Answers by request content and can hold a response until the test releases it.
private actor RoutedTransport: MusicHTTPTransport {
    private var responses: [String: Data] = [:]
    private var holds: Set<String> = []
    private var held: [String: CheckedContinuation<Void, Never>] = [:]
    private var arrivals: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var keys: [String] = []

    func respond(to key: String, with data: Data, hold: Bool = false) {
        responses[key] = data
        if hold { holds.insert(key) }
    }

    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        let key = Self.key(for: request)
        keys.append(key)
        arrivals.removeValue(forKey: key)?.forEach { $0.resume() }
        if holds.contains(key) { await withCheckedContinuation { held[key] = $0 } }
        guard let data = responses[key] else { throw URLError(.badServerResponse) }
        return MusicHTTPResponse(data: data, statusCode: 200)
    }

    func waitForArrival(_ key: String) async {
        if keys.contains(key) { return }
        await withCheckedContinuation { arrivals[key, default: []].append($0) }
    }

    func release(_ key: String) {
        holds.remove(key)
        held.removeValue(forKey: key)?.resume()
    }

    private static func key(for request: URLRequest) -> String {
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        if let token = body["continuation"] as? String { return "next:\(token)" }
        if request.url?.path.hasSuffix("/music/get_search_suggestions") == true {
            return "suggest:\(body["input"] as? String ?? "")"
        }
        if let browseID = body["browseId"] as? String { return "browse:\(browseID)" }
        return "search:\(body["query"] as? String ?? "")|\(body["params"] as? String ?? "")"
    }
}

private func song(_ id: String) -> [String: Any] {
    ["musicResponsiveListItemRenderer": ["playlistItemData": ["videoId": id],
        "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Title " + id]]]]]]]]
}

private func searchPage(_ ids: [String], token: String? = nil) -> Data {
    var shelf: [String: Any] = ["contents": ids.map(song)]
    if let token { shelf["continuations"] = [["nextContinuationData": ["continuation": token]]] }
    return data(["contents": ["tabbedSearchResultsRenderer": ["tabs": [["tabRenderer": ["content": [
        "sectionListRenderer": ["contents": [["musicShelfRenderer": shelf]]]]]]]]]])
}

private func continuationPage(_ ids: [String]) -> Data {
    data(["continuationContents": ["musicShelfContinuation": ["contents": ids.map(song)]]])
}

private func suggestionPage(_ queries: [String]) -> Data {
    data(["contents": [["searchSuggestionsSectionRenderer": ["contents": queries.map { query in
        ["searchSuggestionRenderer": ["suggestion": ["runs": [["text": query]]],
                                      "navigationEndpoint": ["searchEndpoint": ["query": query]]]]
    }]]]])
}

private func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
