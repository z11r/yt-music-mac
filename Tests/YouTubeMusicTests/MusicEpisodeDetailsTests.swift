import Foundation
import MusicCore
import XCTest
@testable import YouTubeMusic

@MainActor final class MusicEpisodeDetailsTests: XCTestCase {
    func testDocumentedSelectedHeaderAndDescriptionAreOpaqueAndReadOnly() throws {
        let reference = detailsReference()
        let runs: [[String: Any]] = [["text": "Long description\n[link](javascript:ignored) "],
            ["text": "01:30", "navigationEndpoint": ["watchEndpoint": ["videoId": reference.videoID, "startTimeSeconds": 90]]],
            ["text": " https://example.invalid/", "navigationEndpoint": ["urlEndpoint": ["url": "javascript:ignored"]]]]
        guard case let .available(details) = try MusicEpisodeDetailsParser.parse(detailsData(runs: runs), reference: reference) else { return XCTFail("Expected exact details") }
        XCTAssertEqual(details.reference, reference); XCTAssertEqual(details.title, "Selected episode")
        XCTAssertEqual(details.show, "Selected show"); XCTAssertEqual(details.publishedText, "Opaque publication label")
        XCTAssertEqual(details.durationText, "Opaque duration label")
        XCTAssertEqual(details.description, "Long description\n[link](javascript:ignored) 01:30 https://example.invalid/")
        XCTAssertEqual(details.timestamps, [.init(sourceIndex: 1, text: "01:30", seconds: 90)])
    }
    func testOnlyExplicitNumericSameVideoTimestampsBecomeSourceReferences() throws {
        let good: (Any, String?) -> [String: Any] = { seconds, video in
            var endpoint: [String: Any] = ["startTimeSeconds": seconds]
            if let video { endpoint["videoId"] = video }
            return ["text": "Source label", "navigationEndpoint": ["watchEndpoint": endpoint]]
        }
        let id = detailsReference().videoID
        let runs = [good(90, id), ["text": "01:23 chapter-like text"], good("90", id), good(true, id),
            good(-1, id), good(1.5, id), good(604_801, id), good(30, "xyzABC98_-7"), good(30, nil), good(0, id)]
        guard case let .available(details) = try MusicEpisodeDetailsParser.parse(detailsData(runs: runs), reference: detailsReference()) else { return XCTFail("Expected details") }
        XCTAssertEqual(details.timestamps.map(\.seconds), [90, 0])
        XCTAssertEqual(details.timestamps.map(\.sourceIndex), [0, 9])
        XCTAssertTrue(try XCTUnwrap(details.description).contains("01:23 chapter-like text"))
    }
    func testMissingOptionalFieldsStayUnknownAndRelatedDescriptionIsNotUsed() throws {
        var response = detailsObject()
        var columns = try XCTUnwrap((response["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"] as? [String: Any])
        columns["tabs"] = [["tabRenderer": ["selected": true, "content": ["sectionListRenderer": ["contents": [
            ["musicResponsiveHeaderRenderer": ["title": ["simpleText": "Selected episode"]]]]]]]]]
        columns["secondaryContents"] = ["sectionListRenderer": ["contents": [["otherRenderer": [:]],
            ["musicDescriptionShelfRenderer": ["description": ["runs": [["text": "Related description must stay hidden"]]]]]]]]
        response["contents"] = ["twoColumnBrowseResultsRenderer": columns]
        guard case let .available(details) = try MusicEpisodeDetailsParser.parse(json(response), reference: detailsReference()) else { return XCTFail("Expected header only") }
        XCTAssertNil(details.show); XCTAssertNil(details.publishedText); XCTAssertNil(details.durationText)
        XCTAssertNil(details.description); XCTAssertTrue(details.timestamps.isEmpty)
    }
    func testOnlyAnUnambiguousSelectedTabCanSupplyMetadata() throws {
        let header = detailsHeader()
        let variants: [[[String: Any]]] = [
            [["tabRenderer": ["content": tabContent(header)]], ["tabRenderer": ["content": tabContent(header)]]],
            [["tabRenderer": ["selected": true, "content": tabContent(header)]], ["tabRenderer": ["selected": true, "content": tabContent(header)]]],
        ]
        for tabs in variants {
            var response = detailsObject(); var columns = detailsColumns()
            columns["tabs"] = tabs; response["contents"] = ["twoColumnBrowseResultsRenderer": columns]
            XCTAssertThrowsError(try MusicEpisodeDetailsParser.parse(json(response), reference: detailsReference()))
        }
        var columns = detailsColumns()
        var related = detailsHeader(); related["title"] = ["simpleText": "Related"]
        columns["tabs"] = [["tabRenderer": ["selected": false, "content": tabContent(related)]],
            ["tabRenderer": ["selected": true, "content": tabContent(header)]]]
        guard case let .available(details) = try MusicEpisodeDetailsParser.parse(json(["contents": ["twoColumnBrowseResultsRenderer": columns]]), reference: detailsReference()) else { return XCTFail("Expected selected") }
        XCTAssertEqual(details.title, "Selected episode")
    }
    func testExplicitContradictoryOrMalformedVideoAndEpisodeIdentityAreRejected() throws {
        let endpoints: [[String: Any]] = [
            ["watchEndpoint": ["videoId": "xyzABC98_-7"]], ["watchEndpoint": ["videoId": ""]],
            ["watchEndpoint": ["videoId": 123]], ["browseEndpoint": ["browseId": "MPEDanother"]],
        ]
        for endpoint in endpoints {
            var header = detailsHeader(); header["navigationEndpoint"] = endpoint
            var columns = detailsColumns(); columns["tabs"] = [["tabRenderer": ["selected": true, "content": tabContent(header)]]]
            XCTAssertThrowsError(try MusicEpisodeDetailsParser.parse(json(["contents": ["twoColumnBrowseResultsRenderer": columns]]), reference: detailsReference()))
        }
    }
    func testMultipleHeadersOrDescriptionShelvesAreNotCombined() throws {
        for description in [false, true] {
            var columns = detailsColumns()
            if description { columns["secondaryContents"] = ["sectionListRenderer": ["contents": Array(repeating: ["musicDescriptionShelfRenderer": ["description": ["runs": [["text": "Ambiguous"]]]]], count: 2)]] }
            else { columns["tabs"] = [["tabRenderer": ["selected": true, "content": ["sectionListRenderer": ["contents": Array(repeating: ["musicResponsiveHeaderRenderer": detailsHeader()], count: 2)]]]]] }
            XCTAssertThrowsError(try MusicEpisodeDetailsParser.parse(json(["contents": ["twoColumnBrowseResultsRenderer": columns]]), reference: detailsReference()))
        }
    }
    func testPayloadRunTextTotalAndTimestampBoundsFailClosed() throws {
        XCTAssertThrowsError(try MusicEpisodeDetailsParser.parse(Data(repeating: 32, count: 1_048_577), reference: detailsReference()))
        let lists: [[[String: Any]]] = [
            Array(repeating: ["text": "x"], count: 1_025), [["text": String(repeating: "x", count: 16_385)]],
            Array(repeating: ["text": String(repeating: "x", count: 16_384)], count: 5), [["text": "bad\0text"]],
            Array(repeating: ["text": "0:00", "navigationEndpoint": ["watchEndpoint": ["videoId": detailsReference().videoID, "startTimeSeconds": 0]]], count: 129),
        ]
        for runs in lists { XCTAssertThrowsError(try MusicEpisodeDetailsParser.parse(detailsData(runs: runs), reference: detailsReference())) }
    }
    func testUnknownPageAndInvalidReferenceNeverInventAnEpisode() throws {
        XCTAssertEqual(try MusicEpisodeDetailsParser.parse(json(["contents": ["unrelatedRenderer": [:]]]), reference: detailsReference()), .unavailable)
        XCTAssertNil(MusicEpisodeDetailsReference(identity: .init(browseID: "MPSPshow"), videoID: "abcDEF12_-3"))
        XCTAssertNil(MusicEpisodeDetailsReference(identity: .init(browseID: "MPEDvalid"), videoID: "short"))
    }
    func testClientUsesExistingCanonicalBrowseReferenceAndNoRemoteWrite() async throws {
        let sessions = await detailSessions(), scope = await sessions.snapshot().scope
        let transport = EpisodeDetailTransport(data: detailsData())
        let client = YouTubeMusicClient(transport: transport, sessions: sessions)
        _ = try await client.episodeDetails(detailsReference(), expectedScope: scope)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.path, "/youtubei/v1/browse")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["browseId"] as? String, "MPEDcanonical-episode")
        XCTAssertNil(body["continuation"]); XCTAssertFalse(client.supportsRemoteLibraryEdits)
    }
    func testChangedScopeBeforeOrDuringReadCannotPublishDetails() async throws {
        let sessions = await detailSessions(), scope = await sessions.snapshot().scope
        let transport = EpisodeDetailTransport(data: detailsData(), held: true)
        let client = YouTubeMusicClient(transport: transport, sessions: sessions)
        do { _ = try await client.episodeDetails(detailsReference(), expectedScope: UUID()); XCTFail("Expected pre-read fence") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        let before = await transport.requests.count
        XCTAssertEqual(before, 0)
        let pending = Task { try await client.episodeDetails(detailsReference(), expectedScope: scope) }
        await transport.waitStarted(); await sessions.clear(); await transport.release()
        do { _ = try await pending.value; XCTFail("Expected post-read fence") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        let after = await transport.requests.count
        XCTAssertEqual(after, 1)
    }
}

private func detailsReference() -> MusicEpisodeDetailsReference { .init(identity: .init(browseID: "MPEDcanonical-episode", showBrowseID: "MPSPshow"), videoID: "abcDEF12_-3")! }
private func detailsHeader() -> [String: Any] { [
    "title": ["runs": [["text": "Selected episode"]]], "straplineTextOne": ["runs": [["text": "Selected show"]]],
    "subtitle": ["runs": [["text": "Opaque publication label"]]],
    "progress": ["musicPlaybackProgressRenderer": ["durationText": ["runs": [["text": "separator"], ["text": "Opaque duration label"]]]]],
    "navigationEndpoint": ["browseEndpoint": ["browseId": "MPEDcanonical-episode"]],
] }
private func tabContent(_ header: [String: Any]) -> [String: Any] { ["sectionListRenderer": ["contents": [["musicResponsiveHeaderRenderer": header]]]] }
private func detailsColumns(runs: [[String: Any]] = [["text": "Description"]]) -> [String: Any] { [
    "tabs": [["tabRenderer": ["selected": true, "content": tabContent(detailsHeader())]]],
    "secondaryContents": ["sectionListRenderer": ["contents": [["musicDescriptionShelfRenderer": ["description": ["runs": runs]]]]]],
] }
private func detailsObject() -> [String: Any] { ["contents": ["twoColumnBrowseResultsRenderer": detailsColumns()]] }
private func json(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
private func detailsData(runs: [[String: Any]] = [["text": "Description"]]) -> Data { json(["contents": ["twoColumnBrowseResultsRenderer": detailsColumns(runs: runs)]]) }
private func detailSessions() async -> MusicSessionStore {
    let sessions = MusicSessionStore()
    await sessions.replaceSession(accountID: "synthetic", cookieHeader: "synthetic=value", sapisid: "synthetic",
        configuration: .init(apiKey: "synthetic", clientVersion: "synthetic"))
    return sessions
}
private actor EpisodeDetailTransport: MusicHTTPTransport {
    let data: Data
    let held: Bool
    private(set) var requests: [URLRequest] = []
    private var waiter: CheckedContinuation<Void, Never>?, started: [CheckedContinuation<Void, Never>] = []
    init(data: Data, held: Bool = false) { self.data = data; self.held = held }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        if held { await withCheckedContinuation { waiter = $0; let callbacks = started; started = []; callbacks.forEach { $0.resume() } } }
        return .init(data: data, statusCode: 200)
    }
    func waitStarted() async { if waiter == nil { await withCheckedContinuation { started.append($0) } } }
    func release() { let value = waiter; waiter = nil; value?.resume() }
}
