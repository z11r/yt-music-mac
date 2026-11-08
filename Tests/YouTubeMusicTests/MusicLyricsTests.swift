import Foundation
import XCTest
@testable import YouTubeMusic

@MainActor
final class MusicLyricsTests: XCTestCase {
    private let videoID = "abcDEF12_-3"

    func testLyricsBrowseTabIsSelectedByItsIdentifierNotItsTitleOrPosition() throws {
        let reference = try MusicLyricsParser.nextReference(next(tabs: [
            tab("FEmusic_related", title: "Lyrics"), tab("MPLYtfixture", title: "Paroles"),
        ]))
        XCTAssertEqual(reference.browseID, "MPLYtfixture")
        XCTAssertNil(reference.lyrics)
    }

    func testPlainLyricsPreserveLineBreaksAndProviderAttribution() throws {
        let result = try MusicLyricsParser.browseLyrics(plain(["First synthetic line\n", "Second synthetic line"], source: "Lyrics by Fixture Provider"))
        XCTAssertEqual(result, .plain(text: "First synthetic line\nSecond synthetic line", source: "Lyrics by Fixture Provider"))
        XCTAssertNil(result.activeLineIndex(at: 20))
    }

    func testNestedServiceTimingEnablesLineBoundariesAndGaps() throws {
        let reference = try MusicLyricsParser.nextReference(timed([
            line("First synthetic line", start: "1000", duration: "500"),
            line("Second synthetic line", start: "2000", duration: "1000"),
        ]))
        let lyrics = try XCTUnwrap(reference.lyrics)
        guard case let .timed(lines, source) = lyrics else { return XCTFail("Expected validated service timing") }
        XCTAssertEqual(lines.first?.startTime, 1)
        XCTAssertNil(source, "A provider name is not invented when the model has none.")
        XCTAssertNil(lyrics.activeLineIndex(at: 0.99))
        XCTAssertEqual(lyrics.activeLineIndex(at: 1), 0)
        XCTAssertNil(lyrics.activeLineIndex(at: 1.5))
        XCTAssertEqual(lyrics.activeLineIndex(at: 2), 1)
        XCTAssertNil(lyrics.activeLineIndex(at: 3))
        XCTAssertNil(lyrics.activeLineIndex(at: .nan))
        XCTAssertNil(lyrics.activeLineIndex(at: -.infinity))
    }

    func testMissingDurationsUseTheNextLineBoundaryAndAllowInstrumentalGaps() throws {
        let lyrics = try XCTUnwrap(MusicLyricsParser.nextReference(timed([
            line("First synthetic line", start: "0"), line("", start: "1500"), line("Last synthetic line", start: "3000"),
        ])).lyrics)
        XCTAssertEqual(lyrics.activeLineIndex(at: 1), 0)
        XCTAssertEqual(lyrics.activeLineIndex(at: 2), 1)
        XCTAssertEqual(lyrics.activeLineIndex(at: 3), 2)
    }

    func testInvalidOrUnorderedTimingFallsBackToPlainTextWithoutSeeking() throws {
        let invalid: [[[String: Any]]] = [
            [line("One synthetic line", start: "invalid")],
            [line("One synthetic line", start: "-1")],
            [line("One synthetic line", start: "0", duration: "-1")],
            [line("First", start: "2000"), line("Second", start: "1000")],
            [line("First", start: "0"), line("Second", start: "0")],
        ]
        for entries in invalid {
            let result = try XCTUnwrap(MusicLyricsParser.nextReference(timed(entries)).lyrics)
            guard case .plain = result else { return XCTFail("Malformed timing must never enable synced playback") }
            XCTAssertNil(result.activeLineIndex(at: 10))
        }
    }

    func testDisabledTabsDoNotExposeInlineLyricsOrRequestABrowsePage() throws {
        let data = next(tabs: [["tabRenderer": ["disabled": true,
            "endpoint": ["browseEndpoint": ["browseId": "MPLYtprivate"]],
            "content": ["musicQueueRenderer": ["content": ["timedLyricsModel": ["lyricsData": [line("Private line", start: "0")]]]]],
        ]]])
        let reference = try MusicLyricsParser.nextReference(data)
        XCTAssertNil(reference.lyrics)
        XCTAssertNil(reference.browseID)
    }

    func testUnrelatedMenusCannotSupplyLyricsAndAmbiguousModelsAreRejected() throws {
        let unrelated = json(["menu": ["timedLyricsModel": ["lyricsData": [line("Wrong line", start: "0")]]],
            "contents": ["singleColumnMusicWatchNextResultsRenderer": ["tabbedRenderer": [
                "watchNextTabbedResultsRenderer": ["tabs": []],
            ]]]])
        XCTAssertNil(try MusicLyricsParser.nextReference(unrelated).lyrics)
        let ambiguous = next(tabs: [timedTab([line("First", start: "0")]), timedTab([line("Other recording", start: "0")])])
        XCTAssertThrowsError(try MusicLyricsParser.nextReference(ambiguous)) {
            XCTAssertEqual($0 as? MusicServiceError, .unsupportedResponse)
        }
    }

    func testMissingLyricsAreDistinctFromAnUnsupportedOrRejectedResponse() throws {
        XCTAssertEqual(try MusicLyricsParser.browseLyrics(plain([" \n "], source: nil)), .unavailable)
        XCTAssertThrowsError(try MusicLyricsParser.browseLyrics(json([:]))) {
            XCTAssertEqual($0 as? MusicServiceError, .unsupportedResponse)
        }
        XCTAssertThrowsError(try MusicLyricsParser.nextReference(json(["error": ["status": "PERMISSION_DENIED"]]))) {
            XCTAssertEqual($0 as? MusicServiceError, .accessDenied)
        }
    }

    func testLyricsSizeAndLineBoundsFailExplicitly() throws {
        XCTAssertThrowsError(try MusicLyricsParser.browseLyrics(plain([String(repeating: "a", count: MusicLyricsParser.maximumTextCount + 1)], source: nil)))
        XCTAssertThrowsError(try MusicLyricsParser.nextReference(timed(Array(repeating: line("x", start: "0"), count: MusicLyricsParser.maximumLineCount + 1))))
    }

    func testClientRequestsOnlyYouTubeMusicUsingTheExactVideoIdentifier() async throws {
        let transport = LyricsTransport([next(tabs: [tab("MPLYtfixture")]), plain(["Synthetic lyric"], source: "Fixture Provider")])
        let client = client(transport)
        let lyrics = try await client.lyrics(videoID: videoID)
        XCTAssertEqual(lyrics.source, "Fixture Provider")
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.host }, ["music.youtube.com", "music.youtube.com"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/youtubei/v1/next", "/youtubei/v1/browse"])
        let bodies = try requests.map(body)
        XCTAssertEqual(Set(bodies[0].keys), ["videoId", "enablePersistentPlaylistPanel", "isAudioOnly", "tunerSettingValue", "context"])
        XCTAssertEqual(bodies[0]["videoId"] as? String, videoID)
        XCTAssertEqual(bodies[0]["isAudioOnly"] as? Bool, true)
        XCTAssertEqual(bodies[0]["enablePersistentPlaylistPanel"] as? Bool, true)
        XCTAssertEqual(bodies[1]["browseId"] as? String, "MPLYtfixture")
    }

    func testValidatedInlineTimingDoesNotMakeAnotherRequest() async throws {
        let transport = LyricsTransport([timed([line("Synthetic line", start: "1000")])])
        let result = try await client(transport).lyrics(videoID: videoID)
        guard case .timed = result else { return XCTFail("Expected service timing") }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testNoLyricsTabReturnsUnavailableWithoutABrowseRequest() async throws {
        let transport = LyricsTransport([next(tabs: [tab("FEmusic_related")])])
        let result = try await client(transport).lyrics(videoID: videoID)
        XCTAssertEqual(result, .unavailable)
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testInvalidIdentifiersAndDeadlinesNeverSendARequest() async throws {
        let transport = LyricsTransport([])
        let client = client(transport)
        for id in ["", "short", "abcdefghijé", "https://youtu.be/abcDEF12_-3"] {
            do { _ = try await client.lyrics(videoID: id); XCTFail("Expected exact identifier check") }
            catch { XCTAssertEqual(error as? MusicServiceError, .invalidInput) }
        }
        do { _ = try await client.lyrics(videoID: videoID, timeout: .zero); XCTFail("Expected bounded deadline") }
        catch { XCTAssertEqual(error as? MusicServiceError, .invalidInput) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testAccountChangeDuringNextResponseCannotFetchOldAccountLyrics() async throws {
        let store = MusicSessionStore()
        await store.replaceSession(accountID: "fixture", cookieHeader: "fixture=value", sapisid: "fixture",
            configuration: MusicClientConfiguration(apiKey: "fixture", clientVersion: "fixture"))
        let transport = LyricsTransport([next(tabs: [tab("MPLYtprivate")])], beforeResponse: { _ = await store.clear() })
        do { _ = try await client(transport, sessions: store).lyrics(videoID: videoID); XCTFail("Expected account fence") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testDeadlineCancelsThePendingRequest() async throws {
        let transport = LyricsTransport([], beforeResponse: { try await Task.sleep(for: .seconds(60)) })
        do { _ = try await client(transport).lyrics(videoID: videoID, timeout: .milliseconds(5)); XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error as? MusicLyricsError, .timedOut) }
    }

    func testCallerCancellationDoesNotReturnLyricsOrStartAnotherRequest() async throws {
        let transport = LyricsTransport([], beforeResponse: { try await Task.sleep(for: .seconds(60)) })
        let client = client(transport)
        let task = Task { try await client.lyrics(videoID: videoID) }
        await transport.waitForRequest()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    private func client(_ transport: LyricsTransport, sessions: (any MusicSessionProviding)? = nil) -> YouTubeMusicClient {
        YouTubeMusicClient(transport: transport, sessions: sessions ?? LyricsFixtureSession(), pause: { _ in })
    }
}

private struct LyricsFixtureSession: MusicSessionProviding {
    let value = MusicSession(scope: UUID(), configuration: MusicClientConfiguration(apiKey: "fixture", clientVersion: "fixture"))
    func snapshot() async -> MusicSession { value }
}

private actor LyricsTransport: MusicHTTPTransport {
    var responses: [Data]
    let beforeResponse: @Sendable () async throws -> Void
    private(set) var requests: [URLRequest] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    init(_ responses: [Data], beforeResponse: @escaping @Sendable () async throws -> Void = {}) {
        self.responses = responses
        self.beforeResponse = beforeResponse
    }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        arrivals.forEach { $0.resume() }
        arrivals.removeAll()
        try await beforeResponse()
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return MusicHTTPResponse(data: responses.removeFirst(), statusCode: 200)
    }
    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
}

private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
private func body(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
}
private func tab(_ id: String, title: String = "Lyrics") -> [String: Any] {
    ["tabRenderer": ["title": title, "endpoint": ["browseEndpoint": ["browseId": id]]]]
}
private func next(tabs: [[String: Any]]) -> Data {
    json(["contents": ["singleColumnMusicWatchNextResultsRenderer": ["tabbedRenderer": ["watchNextTabbedResultsRenderer": ["tabs": tabs]]]]])
}
private func plain(_ runs: [String], source: String?) -> Data {
    var shelf: [String: Any] = ["description": ["runs": runs.map { ["text": $0] }]]
    if let source { shelf["footer"] = ["runs": [["text": source]]] }
    return json(["contents": ["sectionListRenderer": ["contents": [["musicDescriptionShelfRenderer": shelf]]]]])
}
private func line(_ text: String, start: String, duration: String? = nil) -> [String: Any] {
    var line: [String: Any] = ["lyricLine": text, "startTimeMs": start]
    if let duration { line["durationMs"] = duration }
    return line
}
private func timedTab(_ lines: [[String: Any]]) -> [String: Any] {
    ["tabRenderer": ["content": ["musicQueueRenderer": ["content": ["timedLyricsModel": ["lyricsData": lines]]]]]]
}
private func timed(_ lines: [[String: Any]]) -> Data { next(tabs: [timedTab(lines)]) }
