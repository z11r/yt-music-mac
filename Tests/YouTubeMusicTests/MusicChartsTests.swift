import Foundation
import XCTest
@testable import YouTubeMusic

@MainActor final class MusicChartsTests: XCTestCase {
    func testCountryChoicesAreBoundedDeduplicatedAndTakenOnlyFromTheOfferedPayload() async throws {
        let transport = ChartTransport([chartPage(codes: ["CA", "ZZ", "CA", "https://example.com", "ca", "GB", "USA", "C\n"], label: "Service region %@")])
        let client = YouTubeMusicClient(transport: transport, sessions: ChartSession(), pause: { _ in })
        let response = try await client.charts()
        XCTAssertEqual(response.countries.map(\.code), ["CA", "ZZ", "GB"])
        XCTAssertEqual(response.selectedCountryLabel, "Service region %@")
        XCTAssertEqual(response.page.tracks.map(\.id), ["abcDEF12_-3"])
        let requests = await transport.requests
        let body = try chartBody(requests[0])
        XCTAssertEqual(body["browseId"] as? String, "FEmusic_charts")
        XCTAssertNil(body["formData"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
    }

    func testAnOfferedChoiceUsesFormDataAndPagingUsesOnlyItsScopedCursor() async throws {
        let continuation: [String: Any] = ["continuationContents": ["musicShelfContinuation": ["contents": []]]]
        let transport = ChartTransport([chartPage(codes: ["CA"], label: "Initial"),
            chartPage(codes: ["CA"], label: "Canada", token: "country-cursor"), try JSONSerialization.data(withJSONObject: continuation)])
        let client = YouTubeMusicClient(transport: transport, sessions: ChartSession(), pause: { _ in })
        let first = try await client.charts()
        let selected = try await client.charts(country: XCTUnwrap(first.countries.first))
        XCTAssertEqual(selected.selectedCountryLabel, "Canada")
        _ = try await client.nextPage(XCTUnwrap(selected.page.continuation))
        let requests = await transport.requests
        let body = try chartBody(requests[1])
        XCTAssertEqual((body["formData"] as? [String: [String]])?["selectedValues"], ["CA"])
        XCTAssertNil(body["params"])
        let next = try chartBody(requests[2])
        XCTAssertEqual(next["continuation"] as? String, "country-cursor")
        XCTAssertNil(next["formData"])
    }

    func testCountryChoicesCannotBorrowANewerSessionOrSendMalformedTokens() async throws {
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: "first", cookieHeader: "fixture=first", sapisid: "fixture", configuration: chartConfiguration)
        let transport = ChartTransport([chartPage(codes: ["CA"], label: "Canada")])
        let client = YouTubeMusicClient(transport: transport, sessions: sessions, pause: { _ in })
        let response = try await client.charts()
        let original = try XCTUnwrap(response.countries.first)
        for code in ["ca", "USA", "C\n", "https://example.com"] {
            do { _ = try await client.charts(country: MusicChartCountry(code: code, scope: original.scope)); XCTFail("Expected invalid country") }
            catch { XCTAssertEqual(error as? MusicServiceError, .invalidInput) }
        }
        await sessions.replaceSession(accountID: "second", cookieHeader: "fixture=second", sapisid: "other", configuration: chartConfiguration)
        do { _ = try await client.charts(country: original); XCTFail("Expected session fence") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testExcessOfferedChoicesStayBoundedWithoutFollowingAnotherPage() async throws {
        let codes = (65...90).flatMap { first in (65...90).map { second in
            String(UnicodeScalar(first)!) + String(UnicodeScalar(second)!)
        } }
        let transport = ChartTransport([chartPage(codes: codes, label: nil)])
        let response = try await YouTubeMusicClient(transport: transport, sessions: ChartSession()).charts()
        XCTAssertEqual(response.countries.count, 300)
        XCTAssertEqual(Set(response.countries.map(\.code)).count, 300)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testMissingCountryControlsDoNotInventAnAvailableOrSelectedRegion() async throws {
        let transport = ChartTransport([chartPage(codes: [], label: nil)])
        let response = try await YouTubeMusicClient(transport: transport, sessions: ChartSession()).charts()
        XCTAssertTrue(response.countries.isEmpty)
        XCTAssertNil(response.selectedCountryLabel)
        XCTAssertEqual(response.page.tracks.count, 1)
    }
}

private let chartConfiguration = MusicClientConfiguration(apiKey: "fixture-key", clientVersion: "fixture-version")
private struct ChartSession: MusicSessionProviding {
    let value = MusicSession(scope: UUID(), configuration: chartConfiguration)
    func snapshot() async -> MusicSession { value }
}
private actor ChartTransport: MusicHTTPTransport {
    private var responses: [Data]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [Data]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return MusicHTTPResponse(data: responses.removeFirst(), statusCode: 200)
    }
}
private func chartBody(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
}
private func chartPage(codes: [String], label: String?, token: String? = nil) -> Data {
    func text(_ value: String) -> [String: Any] { ["runs": [["text": value]]] }
    var shelf: [String: Any] = ["contents": [["musicResponsiveListItemRenderer": ["playlistItemData": ["videoId": "abcDEF12_-3"], "title": text("Chart song")]]]]
    if let label {
        shelf["subheaders"] = [["musicSideAlignedItemRenderer": ["startItems": [["musicSortFilterButtonRenderer": ["title": text(label)]]]]]]
    }
    if let token { shelf["continuations"] = [["nextContinuationData": ["continuation": token]]] }
    return try! JSONSerialization.data(withJSONObject: [
        "contents": ["singleColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": ["content": ["sectionListRenderer": ["contents": [["musicShelfRenderer": shelf]]]]]]]]],
        "frameworkUpdates": ["entityBatchUpdate": ["mutations": codes.map { ["payload": ["musicFormBooleanChoice": ["opaqueToken": $0]]] }]],
        "menu": ["musicFormBooleanChoice": ["opaqueToken": "FR"]],
    ])
}
