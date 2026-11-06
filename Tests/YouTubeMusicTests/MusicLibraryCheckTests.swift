import Foundation
import XCTest
@testable import YouTubeMusic

@MainActor
final class MusicLibraryCheckTests: XCTestCase {
    func testCheckReadsTwoPagesPerSurfaceAndReturnsOnlyCounts() async throws {
        let store = await session()
        let transport = LibraryCheckTransport([
            page([playlist()], token: "library-next"), page([playlist()], continuation: true),
            page([song("private-song")], token: "likes-next"), page([song("private-song")], continuation: true),
            page([song("private-song", occurrence: "private-occurrence")], token: "playlist-next"),
            page([song("private-song", occurrence: "private-occurrence-two")], token: "more", continuation: true),
        ])
        let result = try await YouTubeMusicClient(transport: transport, sessions: store).checkLibrary(maximumPages: 2)
        XCTAssertEqual(result.surfaces.map(\.surface), [.library, .likedSongs, .playlist])
        XCTAssertEqual(result.surfaces.map(\.status), [.ok, .ok, .ok])
        XCTAssertEqual(result.surfaces.map(\.pageCount), [2, 2, 2])
        XCTAssertEqual(result.surfaces.map(\.itemCount), [1, 2, 2])
        XCTAssertEqual(result.surfaces.map(\.pagination), [.checked, .checked, .checked])
        XCTAssertEqual(result.surfaces.last?.removableOccurrenceCount, 2)
        XCTAssertEqual(result.surfaces.last?.continuationAvailable, true)
        let data = try JSONEncoder().encode(result)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("private-"))
        XCTAssertFalse(json.contains("library-next"))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/youtubei/v1/browse" })
    }

    func testEmptyLibraryDoesNotInventAPlaylistOrPaginationCheck() async throws {
        let transport = LibraryCheckTransport([page([]), page([])])
        let result = try await YouTubeMusicClient(transport: transport, sessions: session()).checkLibrary()
        XCTAssertEqual(result.surfaces.map(\.status), [.ok, .ok, .notAvailable])
        XCTAssertEqual(result.surfaces.map(\.pageCount), [1, 1, 0])
        XCTAssertTrue(result.surfaces.allSatisfy { $0.pagination == .notAvailable })
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
    }

    func testCheckContinuesUntilSurfaceIsComplete() async throws {
        let transport = LibraryCheckTransport([
            page([song("one")], token: "second"),
            page([song("two")], token: "third", continuation: true),
            page([song("three")], continuation: true), page([]),
        ])
        let result = try await YouTubeMusicClient(transport: transport, sessions: session()).checkLibrary()
        XCTAssertEqual(result.surfaces.first?.pageCount, 3)
        XCTAssertEqual(result.surfaces.first?.itemCount, 3)
        XCTAssertEqual(result.surfaces.first?.pagination, .checked)
        XCTAssertEqual(result.surfaces.first?.continuationAvailable, false)
        let count = await transport.requests.count
        XCTAssertEqual(count, 4)
    }

    func testCheckPageLimitLeavesContinuationVisibleWithoutAnotherRequest() async throws {
        let transport = LibraryCheckTransport([page([song("one")], token: "second"), page([])])
        let result = try await YouTubeMusicClient(transport: transport, sessions: session()).checkLibrary(maximumPages: 1)
        XCTAssertEqual(result.surfaces.first?.pageCount, 1)
        XCTAssertEqual(result.surfaces.first?.continuationAvailable, true)
        XCTAssertEqual(result.surfaces.first?.pagination, .notAvailable)
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
    }

    func testCheckRejectsInvalidPageLimitsWithoutRequests() async throws {
        let transport = LibraryCheckTransport([])
        let store = await session()
        let client = YouTubeMusicClient(transport: transport, sessions: store)
        for limit in [0, 51] {
            do { _ = try await client.checkLibrary(maximumPages: limit); XCTFail("Expected bounded page limit") }
            catch { XCTAssertEqual(error as? MusicServiceError, .invalidInput) }
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testPlaylistDiscoveredOnTheSecondLibraryPageIsChecked() async throws {
        let transport = LibraryCheckTransport([page([], token: "next"), page([playlist()], continuation: true), page([]), page([])])
        let result = try await YouTubeMusicClient(transport: transport, sessions: session()).checkLibrary()
        XCTAssertEqual(result.surfaces.last?.status, .ok)
        XCTAssertEqual(result.surfaces.last?.pageCount, 1)
        let count = await transport.requests.count
        XCTAssertEqual(count, 4)
    }

    func testPartialPaginationFailureRetainsCountsAndSession() async throws {
        let store = await session()
        let original = await store.snapshot().scope
        let transport = LibraryCheckTransport([page([song("private-song")], token: "next"),
                                                MusicHTTPResponse(data: Data(), statusCode: 403), page([])])
        let result = try await YouTubeMusicClient(transport: transport, sessions: store).checkLibrary()
        XCTAssertEqual(result.surfaces.first?.status, .accessDenied)
        XCTAssertEqual(result.surfaces.first?.pagination, .failed)
        XCTAssertEqual(result.surfaces.first?.pageCount, 1)
        XCTAssertEqual(result.surfaces.first?.trackCount, 1)
        let current = await store.snapshot()
        XCTAssertTrue(current.isAuthenticated)
        XCTAssertEqual(current.scope, original)
    }

    func testUnsupportedContinuationReportsOnlyAllowlistedContainerPathsAndCounts() async throws {
        let unknown = MusicHTTPResponse(data: try JSONSerialization.data(withJSONObject: [
            "onResponseReceivedActions": [["commandExecutorCommand": ["commands": [[
                "appendContinuationItemsAction": ["continuationItems": [song("private-song")]],
            ]]]]],
            "private-account-key": ["contents": "private-secret"],
            "responseContext": ["visitorData": "private-visitor"],
        ]), statusCode: 200)
        let transport = LibraryCheckTransport([page([], token: "private-token"), unknown, page([])])
        let result = try await YouTubeMusicClient(transport: transport, sessions: session()).checkLibrary()
        XCTAssertEqual(result.schemaVersion, 2)
        XCTAssertEqual(result.surfaces.first?.status, .unsupportedResponse)
        XCTAssertEqual(result.surfaces.first?.pagination, .failed)
        let structure = try XCTUnwrap(result.surfaces.first?.responseStructure)
        XCTAssertTrue(structure.containers.contains { $0.path.contains("commandExecutorCommand/commands") })
        XCTAssertGreaterThan(structure.unknownKeyCount, 0)
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-"))
        XCTAssertFalse(encoded.contains("visitorData"))
    }

    func testStructuralReportHasABoundedTraversalWithoutExposingScalarValues() throws {
        let data = try JSONSerialization.data(withJSONObject: ["contents": Array(repeating: ["items": "private-value"], count: 5_000)])
        let report = try XCTUnwrap(MusicResponseStructure.summarize(data))
        XCTAssertTrue(report.truncated)
        XCTAssertLessThanOrEqual(report.containers.count, 256)
        XCTAssertLessThanOrEqual(report.containers.reduce(0) { $0 + $1.objects + $1.arrays + $1.scalars }, 2_048)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("private-value"))
    }

    func testUnknownDirectContinuationNameIsReportedWithoutItsContents() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "continuationContents": [
                "newLibraryContinuation": ["items": [["private-key": "private-value"]], "private-account": "private-id"],
                "private123Continuation": ["items": []],
                "private_keyContinuation": ["items": []],
                "éContinuation": ["items": []],
                "Continuation": ["items": []],
                String(repeating: "a", count: 65) + "Continuation": ["items": []],
            ],
            "contents": ["outsideContinuation": ["items": []]],
        ])
        let report = try XCTUnwrap(MusicResponseStructure.summarize(data))
        let terminal = try XCTUnwrap(report.containers.first { $0.path == "$/continuationContents/newLibraryContinuation" })
        XCTAssertEqual(terminal.objects, 1)
        XCTAssertFalse(report.containers.contains { $0.path.hasPrefix(terminal.path + "/") })
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private"))
        XCTAssertFalse(encoded.contains("outsideContinuation"))
        XCTAssertEqual(report.unknownKeyCount, 6)
    }

    func testUnknownDirectContinuationNamesAreLimitedToEight() throws {
        let names = "ABCDEFGHIJKL".map { "unknown\($0)Continuation" }
        let data = try JSONSerialization.data(withJSONObject: [
            "continuationContents": Dictionary(uniqueKeysWithValues: names.map { ($0, ["contents": "private-value"]) }),
        ])
        let report = try XCTUnwrap(MusicResponseStructure.summarize(data))
        XCTAssertEqual(report.containers.filter { $0.path.hasPrefix("$/continuationContents/") }.count, 8)
        XCTAssertTrue(report.truncated)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("private-value"))
    }

    func testAnonymousCheckNeverSendsARequest() async throws {
        let transport = LibraryCheckTransport([])
        do {
            _ = try await YouTubeMusicClient(transport: transport).checkLibrary()
            XCTFail("Expected sign-in requirement")
        } catch { XCTAssertEqual(error as? MusicServiceError, .signInRequired) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testAccountChangeRejectsTheEntireReport() async throws {
        let store = await session()
        let transport = LibraryCheckTransport([page([])], beforeResponse: { _ = await store.clear() })
        do {
            _ = try await YouTubeMusicClient(transport: transport, sessions: store).checkLibrary()
            XCTFail("Expected account fence")
        } catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
    }

    func testDeadlineCancelsAnInFlightRead() async throws {
        let store = await session()
        let transport = LibraryCheckTransport([page([])], beforeResponse: { try await Task.sleep(for: .seconds(60)) })
        do {
            _ = try await YouTubeMusicClient(transport: transport, sessions: store).checkLibrary(timeout: .milliseconds(5))
            XCTFail("Expected deadline")
        } catch { XCTAssertEqual(error as? MusicLibraryCheckError, .timedOut) }
        let current = await store.snapshot()
        XCTAssertTrue(current.isAuthenticated)
    }

    func testCallerCancellationDoesNotReturnAPartialReport() async throws {
        let store = await session()
        let transport = LibraryCheckTransport([page([])], beforeResponse: { try await Task.sleep(for: .seconds(60)) })
        let client = YouTubeMusicClient(transport: transport, sessions: store)
        let task = Task { try await client.checkLibrary() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func session() async -> MusicSessionStore {
        let store = MusicSessionStore()
        await store.replaceSession(accountID: "private-account", cookieHeader: "test=value", sapisid: "test-a",
            configuration: MusicClientConfiguration(apiKey: "test-key", clientVersion: "test-version"))
        return store
    }

    private func page(_ items: [[String: Any]], token: String? = nil, continuation: Bool = false) -> MusicHTTPResponse {
        var shelf: [String: Any] = ["contents": items]
        if let token { shelf["continuations"] = [["nextContinuationData": ["continuation": token]]] }
        let body: [String: Any] = continuation
            ? ["continuationContents": ["musicShelfContinuation": shelf]]
            : ["contents": ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": shelf]]]]]
        return MusicHTTPResponse(data: try! JSONSerialization.data(withJSONObject: body), statusCode: 200)
    }

    private func song(_ id: String, occurrence: String? = nil) -> [String: Any] {
        var item: [String: Any] = ["videoId": id]
        if let occurrence { item["playlistSetVideoId"] = occurrence }
        return ["musicResponsiveListItemRenderer": ["playlistItemData": item,
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "private-title"]]]]]]]]
    }

    private func playlist() -> [String: Any] {
        ["musicTwoRowItemRenderer": ["title": ["runs": [["text": "private-title"]]],
            "navigationEndpoint": ["browseEndpoint": ["browseId": "VLprivate-playlist",
                "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_PLAYLIST"]]]]]]
    }
}

private actor LibraryCheckTransport: MusicHTTPTransport {
    private var responses: [MusicHTTPResponse]
    private let beforeResponse: @Sendable () async throws -> Void
    private(set) var requests: [URLRequest] = []

    init(_ responses: [MusicHTTPResponse], beforeResponse: @escaping @Sendable () async throws -> Void = {}) {
        self.responses = responses
        self.beforeResponse = beforeResponse
    }

    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        try await beforeResponse()
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}
