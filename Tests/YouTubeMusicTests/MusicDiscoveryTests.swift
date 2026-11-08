// Synthetic shapes follow Kaset's HomeResponseParser and ArtistParser.
// Copyright (c) 2025 sozercan, MIT License; see THIRD_PARTY_NOTICES.md.
import Foundation
import MusicCore
import XCTest
@testable import YouTubeMusic

@MainActor
final class MusicDiscoveryTests: XCTestCase {
    func testDiscoveryPagesUseEstablishedBrowseIDs() async throws {
        let transport = DiscoveryTransport(Array(repeating: discoveryPage([]), count: 3))
        let client = YouTubeMusicClient(transport: transport, sessions: DiscoverySession(), pause: { _ in })
        for category in MusicDiscoveryCategory.allCases { _ = try await client.discovery(category) }
        let requests = await transport.requests
        XCTAssertEqual(try requests.map { try requestBody($0)["browseId"] as? String },
                       ["FEmusic_charts", "FEmusic_moods_and_genres", "FEmusic_new_releases"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/youtubei/v1/browse" })
        XCTAssertTrue(try requests.allSatisfy { try requestBody($0)["formData"] == nil })
    }

    func testMoodButtonsKeepDistinctScopedParamsAndDoNotBecomePlaylists() async throws {
        let transport = DiscoveryTransport([discoveryPage([
            navigationButton("Calm", params: "calm=scope"), navigationButton("Focus", params: "focus=scope")
        ]), discoveryPage([song("focus-song")])])
        let client = YouTubeMusicClient(transport: transport, sessions: DiscoverySession(), pause: { _ in })
        let page = try await client.discovery(.moodsAndGenres)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(Set(page.items.map(\.id)).count, 2)
        guard case let .browse(reference) = page.items[1] else { return XCTFail("Expected category action") }
        XCTAssertEqual(reference.kind, .category)
        XCTAssertNotNil(reference.scope)
        let detail = try await client.browse(reference)
        XCTAssertEqual(detail.tracks.map(\.id), ["focus-song"])
        let requests = await transport.requests
        let body = try requestBody(requests[1])
        XCTAssertEqual(body["browseId"] as? String, "FEmusic_moods_and_genres_category")
        XCTAssertEqual(body["params"] as? String, "focus=scope")
    }

    func testSeeAllSurvivesEmptyPreviewAndUnknownPageTypesStayHidden() throws {
        for type in ["MUSIC_PAGE_TYPE_PLAYLIST", "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY"] {
            let page = try MusicResponseParser.parse(carousel(type: type), preservesOccurrences: false)
            let reference = try XCTUnwrap(page.sections.first?.browseReference)
            XCTAssertEqual(reference.browseID, "UCfixture")
            XCTAssertEqual(reference.params, "shelf-scope==")
        }
        let page = try MusicResponseParser.parse(carousel(type: "MUSIC_PAGE_TYPE_UNKNOWN"), preservesOccurrences: false)
        XCTAssertTrue(page.sections.isEmpty)
        let poisoned = try MusicResponseParser.parse(carousel(type: "MUSIC_PAGE_TYPE_ARTIST", params: ["unexpected": "value"]), preservesOccurrences: false)
        XCTAssertTrue(poisoned.sections.isEmpty)
    }

    func testSeeAllRequestAndPaginationPreservePlaylistOccurrences() async throws {
        let first = discoveryPage([song("same"), song("same")], token: "older")
        let next = data(["continuationContents": ["musicPlaylistShelfContinuation": ["contents": [song("same")]]]])
        let transport = DiscoveryTransport([first, next])
        let client = YouTubeMusicClient(transport: transport, sessions: DiscoverySession(), pause: { _ in })
        let reference = MusicBrowseReference(browseID: "VLfixture", params: "exact-scope==", title: "Top Songs", kind: .playlist)
        let page = try await client.browse(reference)
        let more = try await client.nextPage(XCTUnwrap(page.continuation))
        XCTAssertEqual(page.tracks.map(\.id), ["same", "same"])
        XCTAssertEqual(more.tracks.map(\.id), ["same"])
        let requests = await transport.requests
        XCTAssertEqual(try requestBody(requests[0])["params"] as? String, "exact-scope==")
        XCTAssertEqual(try requestBody(requests[1])["continuation"] as? String, "older")
        XCTAssertNil(try requestBody(requests[1])["params"])
    }

    func testServiceBrowseActionsCannotCrossAccountScopes() async throws {
        let store = MusicSessionStore()
        await store.replaceSession(accountID: "first", cookieHeader: "fixture=value", sapisid: "fixture", configuration: configuration)
        let transport = DiscoveryTransport([carousel(type: "MUSIC_PAGE_TYPE_ARTIST")])
        let client = YouTubeMusicClient(transport: transport, sessions: store, pause: { _ in })
        let page = try await client.explore()
        let reference = try XCTUnwrap(page.sections.first?.browseReference)
        await store.replaceSession(accountID: "second", cookieHeader: "fixture=other", sapisid: "other", configuration: configuration)
        do { _ = try await client.browse(reference); XCTFail("Expected account fence") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testBrowseRejectsMalformedIdentifiersAndParamsBeforeRequest() async {
        let transport = DiscoveryTransport([])
        let client = YouTubeMusicClient(transport: transport, sessions: DiscoverySession())
        for reference in [
            MusicBrowseReference(browseID: "https://example.invalid", title: "Bad", kind: .category),
            MusicBrowseReference(browseID: "UCfixture", params: "bad\nvalue", title: "Bad", kind: .artist),
            MusicBrowseReference(browseID: "UCfixture", params: String(repeating: "a", count: 4097), title: "Bad", kind: .artist)
        ] {
            do { _ = try await client.browse(reference); XCTFail("Expected invalid input") }
            catch { XCTAssertEqual(error as? MusicServiceError, .invalidInput) }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testUnsupportedDetailIsAnErrorAndTheReferenceCanRetry() async throws {
        let transport = DiscoveryTransport([data(["newRenderer": [:]]), discoveryPage([song("recovered")])])
        let client = YouTubeMusicClient(transport: transport, sessions: DiscoverySession(), pause: { _ in })
        let reference = MusicBrowseReference(browseID: "UCfixture", params: "scope", title: "Albums", kind: .discography)
        do { _ = try await client.browse(reference); XCTFail("Expected unsupported format") }
        catch { XCTAssertEqual(error as? MusicServiceError, .unsupportedResponse) }
        let page = try await client.browse(reference)
        XCTAssertEqual(page.tracks.map(\.id), ["recovered"])
        let requests = await transport.requests
        XCTAssertEqual(try requestBody(requests[0])["params"] as? String, try requestBody(requests[1])["params"] as? String)
    }

    func testUnknownWrappedContentDoesNotLookLikeAnEmptyPage() throws {
        let unknown: [String: Any] = ["futureMusicRenderer": ["title": text("Unknown format")]]
        XCTAssertThrowsError(try MusicResponseParser.parse(discoveryPage([unknown]), preservesOccurrences: false)) {
            XCTAssertEqual($0 as? MusicServiceError, .unsupportedResponse)
        }
        let partial = try MusicResponseParser.parse(discoveryPage([song("readable"), unknown]), preservesOccurrences: false)
        XCTAssertEqual(partial.items.map(\.id), ["track:readable"])
        XCTAssertTrue(partial.hasUnsupportedContent)
        XCTAssertEqual(partial.unavailableItemCount, 0)
        let empty = try MusicResponseParser.parse(discoveryPage([["messageRenderer": ["text": text("No results")]]]), preservesOccurrences: false)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertFalse(empty.hasUnsupportedContent)
    }

    func testSeeAllCommandVariantIsReadWithoutTraversingMenus() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: carousel(type: "MUSIC_PAGE_TYPE_ARTIST")) as? [String: Any])
        // Use a separate minimal command-form header, as documented by ArtistParser.
        let command: [String: Any] = ["browseEndpoint": ["browseId": "UCfixture", "params": "command-scope",
            "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_ARTIST"]]]]
        let header: [String: Any] = ["musicCarouselShelfBasicHeaderRenderer": ["title": text("Artist Songs"),
            "moreContentButton": ["buttonRenderer": ["command": command]]]]
        let response = data(["contents": ["sectionListRenderer": ["contents": [["musicCarouselShelfRenderer": ["header": header, "contents": []]]]]],
                             "menu": object])
        let page = try MusicResponseParser.parse(response, preservesOccurrences: false)
        XCTAssertEqual(page.sections.count, 1)
        XCTAssertEqual(page.sections.first?.browseReference?.params, "command-scope")
    }
}

private let configuration = MusicClientConfiguration(apiKey: "fixture-key", clientVersion: "fixture-version")
private struct DiscoverySession: MusicSessionProviding {
    let value = MusicSession(scope: UUID(), configuration: configuration)
    func snapshot() async -> MusicSession { value }
}
private actor DiscoveryTransport: MusicHTTPTransport {
    var responses: [Data]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [Data]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return MusicHTTPResponse(data: responses.removeFirst(), statusCode: 200)
    }
}
private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
}
private func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
private func text(_ value: String) -> [String: Any] { ["runs": [["text": value]]] }
private func song(_ id: String) -> [String: Any] {
    ["musicResponsiveListItemRenderer": ["playlistItemData": ["videoId": id], "title": text(id)]]
}
private func discoveryPage(_ items: [[String: Any]], token: String? = nil) -> Data {
    var shelf: [String: Any] = ["contents": items]
    if let token { shelf["continuations"] = [["nextContinuationData": ["continuation": token]]] }
    return data(["contents": ["sectionListRenderer": ["contents": [["musicShelfRenderer": shelf]]]]])
}
private func navigationButton(_ title: String, params: String) -> [String: Any] {
    ["musicNavigationButtonRenderer": ["buttonText": text(title), "clickCommand": ["browseEndpoint": [
        "browseId": "FEmusic_moods_and_genres_category", "params": params
    ]]]]
}
private func carousel(type: String, params: Any = "shelf-scope==") -> Data {
    data(["contents": ["sectionListRenderer": ["contents": [["musicCarouselShelfRenderer": [
        "header": ["musicCarouselShelfBasicHeaderRenderer": ["title": text("Albums"), "moreContentButton": ["buttonRenderer": [
            "navigationEndpoint": ["browseEndpoint": ["browseId": "UCfixture", "params": params,
                "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": type]]]]
        ]]]], "contents": []
    ]]]]]])
}
