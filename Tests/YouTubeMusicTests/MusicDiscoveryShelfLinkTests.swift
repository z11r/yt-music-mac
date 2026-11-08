// Synthetic shelf shapes follow ytmusicapi's Explore parser and Kaset's
// HomeResponseParser (MIT License). See THIRD_PARTY_NOTICES.md.
import Foundation
import MusicCore
import XCTest
@testable import YouTubeMusic

@MainActor final class MusicDiscoveryShelfLinkTests: XCTestCase {
    func testKnownCategoryTitleLinksWorkWithoutAButtonOrPreview() throws {
        for id in categoryIDs {
            let parsed = try MusicResponseParser.parse(page(shelf(titleAction: browse(id))), preservesOccurrences: false)
            let reference = try XCTUnwrap(parsed.sections.first?.browseReference)
            XCTAssertEqual(reference.browseID, id)
            XCTAssertEqual(reference.kind, .category)
            XCTAssertEqual(reference.title, "Nouveautés proposées")
            XCTAssertEqual(reference.params, "exact%3Dscope==")
            XCTAssertTrue(parsed.items.isEmpty)
        }
        let noParams = try parsedReference(shelf(titleAction: ["browseEndpoint": ["browseId": categoryIDs[1]]]))
        XCTAssertEqual(noParams?.browseID, categoryIDs[1])
        XCTAssertNil(noParams?.params)
    }

    func testMatchingTitleAndBothButtonVariantsProduceOneReference() throws {
        let action = browse(categoryIDs[1])
        let parsed = try MusicResponseParser.parse(page(shelf(titleAction: action, command: action, navigation: action)), preservesOccurrences: false)
        XCTAssertEqual(parsed.sections.count, 1)
        XCTAssertEqual(parsed.sections.first?.browseReference?.browseID, categoryIDs[1])
    }

    func testConflictingTitleOrButtonActionsNeverChooseAnArbitraryDestination() throws {
        let first = browse(categoryIDs[0])
        for value in [
            shelf(titleAction: first, navigation: browse(categoryIDs[1])),
            shelf(titleAction: first, command: browse(categoryIDs[0], params: "other-scope")),
            shelf(command: first, navigation: browse(categoryIDs[1])),
            shelf(titleAction: first, command: ["watchEndpoint": ["videoId": "abcDEF12_-3"]]),
            shelf(titleAction: first, command: ["browseEndpoint": ["browseId": categoryIDs[0], "params": 3]])
        ] { XCTAssertNil(try parsedReference(value)) }
    }

    func testExplicitNullActionOrTypeFieldsNeverBecomeAbsentFields() throws {
        let action = browse(categoryIDs[1])
        for field in ["watchEndpoint", "watchPlaylistEndpoint", "urlEndpoint", "commandExecutorCommand"] {
            var mixed = action; mixed[field] = NSNull()
            XCTAssertNil(try parsedReference(shelf(titleAction: mixed)))
        }
        var destination = action["browseEndpoint"] as! [String: Any]
        for context: Any in [NSNull(), ["browseEndpointContextMusicConfig": NSNull()],
                             ["browseEndpointContextMusicConfig": ["pageType": NSNull()]]] {
            destination["browseEndpointContextSupportedConfigs"] = context
            XCTAssertNil(try parsedReference(shelf(titleAction: ["browseEndpoint": destination])))
        }
        for field in ["command", "navigationEndpoint"] {
            var basic: [String: Any] = ["title": text("Title")]
            basic["moreContentButton"] = ["buttonRenderer": [field: NSNull(),
                field == "command" ? "navigationEndpoint" : "command": action]]
            let renderer: [String: Any] = ["header": ["musicCarouselShelfBasicHeaderRenderer": basic]]
            XCTAssertNil(MusicBrowseParser.shelfReference(try node(renderer), title: "Title"))
        }
        let base: [String: Any] = ["title": ["runs": [["text": "Title", "navigationEndpoint": action]]]]
        for field in ["moreContentButton", "title"] {
            var basic = base
            basic[field] = field == "title" ? ["runs": NSNull()] : NSNull()
            if field == "title" { basic["moreContentButton"] = ["buttonRenderer": ["command": action]] }
            let renderer: [String: Any] = ["header": ["musicCarouselShelfBasicHeaderRenderer": basic]]
            XCTAssertNil(MusicBrowseParser.shelfReference(try node(renderer), title: "Title"))
        }
        let basic: [String: Any] = ["title": ["runs": [["text": "Title", "navigationEndpoint": NSNull()]]],
            "moreContentButton": ["buttonRenderer": ["command": action]]]
        XCTAssertNil(MusicBrowseParser.shelfReference(try node(["header": ["musicCarouselShelfBasicHeaderRenderer": basic]]), title: "Title"))
    }

    func testUnknownContradictoryMalformedAndUnboundedActionsStayHidden() throws {
        var poisoned = browse(categoryIDs[0])
        var destination = poisoned["browseEndpoint"] as! [String: Any]
        destination["params"] = ["opaque": "object"]
        poisoned["browseEndpoint"] = destination
        for action in [
            browse("FEmusic_invented_mixes"),
            browse("FEmusic_new_releases_videos_other"),
            browse(categoryIDs[0], type: "MUSIC_PAGE_TYPE_PLAYLIST"),
            browse(categoryIDs[1], type: "MUSIC_PAGE_TYPE_UNKNOWN"),
            browse(categoryIDs[1], type: 7),
            browse(categoryIDs[1], params: NSNull()),
            browse(categoryIDs[1], params: String(repeating: "x", count: 4_097)),
            browse(categoryIDs[1], params: "scope\nother"),
            ["urlEndpoint": ["url": "https://music.youtube.com/explore"]], poisoned
        ] { XCTAssertNil(try parsedReference(shelf(titleAction: action))) }
        var malformed = shelf(titleAction: browse(categoryIDs[0]))
        var renderer = malformed["musicCarouselShelfRenderer"] as! [String: Any]
        var header = renderer["header"] as! [String: Any]
        var basic = header["musicCarouselShelfBasicHeaderRenderer"] as! [String: Any]
        basic["moreContentButton"] = ["buttonRenderer": ["text": text("More")]]
        header["musicCarouselShelfBasicHeaderRenderer"] = basic; renderer["header"] = header
        malformed["musicCarouselShelfRenderer"] = renderer
        XCTAssertNil(try parsedReference(malformed))
        let valid = try node(shelf(titleAction: browse(categoryIDs[1])))["musicCarouselShelfRenderer"]
        XCTAssertNil(MusicBrowseParser.shelfReference(valid, title: String(repeating: "x", count: 501)))
        XCTAssertNil(MusicBrowseParser.shelfReference(valid, title: ""))
    }

    func testMenusRelatedItemsAndAdditionalActionBearingTitleRunsCannotSupplyASeeAll() throws {
        let action = browse(categoryIDs[1])
        var value = shelf()
        var renderer = value["musicCarouselShelfRenderer"] as! [String: Any]
        renderer["menu"] = ["navigationEndpoint": action]
        renderer["contents"] = [["relatedShelf": ["title": ["runs": [["text": "Related", "navigationEndpoint": action]]]]]]
        value["musicCarouselShelfRenderer"] = renderer
        XCTAssertNil(try parsedReference(value))
        var header = renderer["header"] as! [String: Any]
        var basic = header["musicCarouselShelfBasicHeaderRenderer"] as! [String: Any]
        basic["title"] = ["runs": [["text": "One", "navigationEndpoint": action], ["text": "Two", "navigationEndpoint": action]]]
        header["musicCarouselShelfBasicHeaderRenderer"] = basic; renderer["header"] = header
        XCTAssertNil(MusicBrowseParser.shelfReference(try node(renderer), title: "OneTwo"))
        basic["title"] = ["runs": Array(repeating: ["text": "x"], count: 65)]
        header["musicCarouselShelfBasicHeaderRenderer"] = basic; renderer["header"] = header
        XCTAssertNil(MusicBrowseParser.shelfReference(try node(renderer), title: "Title"))
    }

    func testTitleOnlyPlaylistKeepsTheExistingOccurrenceBehavior() async throws {
        let transport = ShelfLinkTransport([page(shelf(titleAction: browse("VLfixture", type: "MUSIC_PAGE_TYPE_PLAYLIST"))),
            grid([video("same"), video("same")])])
        let client = makeClient(transport)
        let offered = try await client.explore()
        let reference = try XCTUnwrap(offered.sections.first?.browseReference)
        XCTAssertEqual(reference.kind, .playlist)
        let detail = try await client.browse(reference)
        XCTAssertEqual(detail.tracks.map(\.id), ["same", "same"])
    }

    func testCategoryActionRetainsItsExactParamsAndUsesBoundScopedPagination() async throws {
        let transport = ShelfLinkTransport([page(shelf(titleAction: browse(categoryIDs[1]))),
            grid([video("first"), video("first")], token: "offered-cursor"),
            continuation([video("first"), video("second")])])
        let client = makeClient(transport)
        let offered = try await client.explore()
        let reference = try XCTUnwrap(offered.sections.first?.browseReference)
        XCTAssertNotNil(reference.scope)
        let detail = try await client.browse(reference)
        let next = try await client.nextPage(XCTUnwrap(detail.continuation))
        XCTAssertEqual(detail.tracks.map(\.id), ["first"])
        XCTAssertEqual(next.tracks.map(\.id), ["second"])
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" && $0.url?.path == "/youtubei/v1/browse" })
        let initial = try body(requests[1]), more = try body(requests[2])
        XCTAssertEqual(initial["browseId"] as? String, categoryIDs[1])
        XCTAssertEqual(initial["params"] as? String, "exact%3Dscope==")
        XCTAssertEqual(Set(initial.keys), ["browseId", "params", "context"])
        XCTAssertEqual(more["continuation"] as? String, "offered-cursor")
        XCTAssertEqual(Set(more.keys), ["continuation", "context"])
    }

    func testFailureRetainsTheSameActionAndCursorForExplicitRetry() async throws {
        let invalid = bytes(["unknownRenderer": [:]])
        let transport = ShelfLinkTransport([page(shelf(titleAction: browse(categoryIDs[0]))), invalid,
            grid([video("first")], token: "same-cursor"), invalid, continuation([video("second")])])
        let client = makeClient(transport)
        let offered = try await client.explore()
        let reference = try XCTUnwrap(offered.sections.first?.browseReference)
        do { _ = try await client.browse(reference); XCTFail("Expected an unsupported response") }
        catch { XCTAssertEqual(error as? MusicServiceError, .unsupportedResponse) }
        let detail = try await client.browse(reference)
        let cursor = try XCTUnwrap(detail.continuation)
        do { _ = try await client.nextPage(cursor); XCTFail("Expected an unsupported response") }
        catch { XCTAssertEqual(error as? MusicServiceError, .unsupportedResponse) }
        let recovered = try await client.nextPage(cursor)
        XCTAssertEqual(recovered.tracks.map(\.id), ["second"])
        let requests = await transport.requests
        XCTAssertEqual(try body(requests[1])["params"] as? String, try body(requests[2])["params"] as? String)
        XCTAssertEqual(try body(requests[3])["continuation"] as? String, try body(requests[4])["continuation"] as? String)
    }

    func testChangedAccountRejectsBothTheOfferedActionAndItsCursorBeforeAnyFurtherRead() async throws {
        let store = MusicSessionStore()
        await store.replaceSession(accountID: "synthetic-first", cookieHeader: "fixture=one", sapisid: "one", configuration: shelfConfiguration)
        let transport = ShelfLinkTransport([page(shelf(titleAction: browse(categoryIDs[1]))), grid([video("first")], token: "old")])
        let client = YouTubeMusicClient(transport: transport, sessions: store, pause: { _ in })
        let offered = try await client.explore()
        let reference = try XCTUnwrap(offered.sections.first?.browseReference)
        let detail = try await client.browse(reference)
        let cursor = try XCTUnwrap(detail.continuation)
        await store.replaceSession(accountID: "synthetic-second", cookieHeader: "fixture=two", sapisid: "two", configuration: shelfConfiguration)
        do { _ = try await client.browse(reference); XCTFail("Expected stale action") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        do { _ = try await client.nextPage(cursor); XCTFail("Expected stale cursor") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
    }

    func testHeldResultCannotPublishAfterScopeChangeOrCancellation() async throws {
        for cancel in [false, true] {
            let store = MusicSessionStore()
            await store.replaceSession(accountID: "synthetic", cookieHeader: "fixture=one", sapisid: "one", configuration: shelfConfiguration)
            let transport = ShelfLinkTransport([page(shelf(titleAction: browse(categoryIDs[1]))), grid([video("late")])], holds: [1])
            let client = YouTubeMusicClient(transport: transport, sessions: store, pause: { _ in })
            let offered = try await client.explore()
            let reference = try XCTUnwrap(offered.sections.first?.browseReference)
            let task = Task { try await client.browse(reference) }
            await transport.waitForRequests(2)
            if cancel { task.cancel() }
            else { _ = await store.clear() }
            await transport.release(1)
            do { _ = try await task.value; XCTFail("Expected revoked result") }
            catch { if cancel { XCTAssertTrue(error is CancellationError) } else { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) } }
            let count = await transport.requests.count
            XCTAssertEqual(count, 2)
        }
    }
}

private let categoryIDs = ["FEmusic_new_releases_albums", "FEmusic_new_releases_videos", "FEmusic_moods_and_genres"]
private let shelfConfiguration = MusicClientConfiguration(apiKey: "synthetic-key", clientVersion: "synthetic-version")
private struct ShelfLinkSession: MusicSessionProviding {
    let value = MusicSession(scope: UUID(), configuration: shelfConfiguration)
    func snapshot() async -> MusicSession { value }
}
private actor ShelfLinkTransport: MusicHTTPTransport {
    let responses: [Data], holds: Set<Int>
    private(set) var requests: [URLRequest] = []
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]
    private var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []
    init(_ responses: [Data], holds: Set<Int> = []) { self.responses = responses; self.holds = holds }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        let index = requests.count; requests.append(request)
        let ready = arrivals.filter { $0.0 <= requests.count }; arrivals.removeAll { $0.0 <= requests.count }
        ready.forEach { $0.1.resume() }
        guard responses.indices.contains(index) else { throw URLError(.badServerResponse) }
        if holds.contains(index) { await withCheckedContinuation { held[index] = $0 } }
        return .init(data: responses[index], statusCode: 200)
    }
    func waitForRequests(_ count: Int) async {
        if requests.count < count { await withCheckedContinuation { arrivals.append((count, $0)) } }
    }
    func release(_ index: Int) { held.removeValue(forKey: index)?.resume() }
}
private func makeClient(_ transport: ShelfLinkTransport) -> YouTubeMusicClient {
    YouTubeMusicClient(transport: transport, sessions: ShelfLinkSession(), pause: { _ in })
}
private func bytes(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
private func node(_ value: [String: Any]) throws -> JSONNode { try JSONDecoder().decode(JSONNode.self, from: bytes(value)) }
private func body(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
}
private func text(_ value: String) -> [String: Any] { ["runs": [["text": value]]] }
private func browse(_ id: String, params: Any = "exact%3Dscope==", type: Any? = nil) -> [String: Any] {
    var value: [String: Any] = ["browseId": id, "params": params]
    if let type { value["browseEndpointContextSupportedConfigs"] = ["browseEndpointContextMusicConfig": ["pageType": type]] }
    return ["browseEndpoint": value]
}
private func shelf(titleAction: [String: Any]? = nil, command: [String: Any]? = nil, navigation: [String: Any]? = nil) -> [String: Any] {
    var run: [String: Any] = ["text": "Nouveautés proposées"]
    if let titleAction { run["navigationEndpoint"] = titleAction }
    var header: [String: Any] = ["title": ["runs": [run]]]
    var button: [String: Any] = [:]
    if let command { button["command"] = command }
    if let navigation { button["navigationEndpoint"] = navigation }
    if !button.isEmpty { header["moreContentButton"] = ["buttonRenderer": button] }
    return ["musicCarouselShelfRenderer": ["header": ["musicCarouselShelfBasicHeaderRenderer": header], "contents": []]]
}
private func page(_ value: [String: Any]) -> Data {
    bytes(["contents": ["singleColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": ["selected": true,
        "content": ["sectionListRenderer": ["contents": [value]]]]]]]]])
}
private func parsedReference(_ value: [String: Any]) throws -> MusicBrowseReference? {
    try MusicBrowseParser.shelfReference(node(value)["musicCarouselShelfRenderer"], title: "Nouveautés proposées")
}
private func video(_ id: String) -> [String: Any] {
    ["musicTwoRowItemRenderer": ["title": text(id), "subtitle": text("Artist"), "navigationEndpoint": ["watchEndpoint": ["videoId": id,
        "watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": "MUSIC_VIDEO_TYPE_OMV"]]]]]]
}
private func grid(_ items: [[String: Any]], token: String? = nil) -> Data {
    var renderer: [String: Any] = ["items": items]
    if let token { renderer["continuations"] = [["nextContinuationData": ["continuation": token]]] }
    return page(["gridRenderer": renderer])
}
private func continuation(_ items: [[String: Any]]) -> Data {
    bytes(["continuationContents": ["gridContinuation": ["items": items]]])
}
