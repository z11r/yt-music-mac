import Foundation
import MusicCore
import Testing
@testable import YouTubeMusic

private actor QueueWriteTransport: MusicHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var entries: [(String, String)] = []
    private var title = ""
    private var includesTitle = true
    private var includesOccurrences = true
    func omitTitle() { includesTitle = false }
    func omitOccurrences() { includesOccurrences = false }
    func send(_ request: URLRequest) throws -> MusicHTTPResponse {
        requests.append(request)
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        let path = request.url?.path ?? ""
        if path.hasSuffix("playlist/create") {
            title = body["title"] as? String ?? ""
            return response(["playlistId": "PLsaved"])
        }
        if path.hasSuffix("browse/edit_playlist") {
            let actions = body["actions"] as? [[String: String]] ?? []
            let results: [[String: Any]] = actions.compactMap { action in
                guard let id = action["addedVideoId"] else { return nil }
                let occurrence = "service-\(entries.count)="; entries.append((id, occurrence))
                return ["playlistEditVideoAddedResultData": ["videoId": id, "setVideoId": occurrence]]
            }
            return response(["status": "STATUS_SUCCEEDED", "playlistEditResults": results])
        }
        if path.hasSuffix("browse") {
            let offset = (body["continuation"] as? String).flatMap { Int($0.dropFirst(5)) } ?? 0
            let last = min(entries.count, offset + 2)
            let rows: [[String: Any]] = entries[offset..<last].map { id, occurrence in
                var data = ["videoId": id]
                if includesOccurrences { data["playlistSetVideoId"] = occurrence }
                return ["musicResponsiveListItemRenderer": ["playlistItemData": data,
                    "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Song"]]]]]]]]
            }
            var shelf: [String: Any] = ["contents": rows]
            if last < entries.count { shelf["continuations"] = [["nextContinuationData": ["continuation": "next-\(last)"]]] }
            if offset > 0 { return response(["continuationContents": ["musicPlaylistShelfContinuation": shelf]]) }
            var inner: [String: Any] = [:]
            if includesTitle { inner["title"] = ["runs": [["text": title]]] }
            return response(["header": ["musicEditablePlaylistDetailHeaderRenderer": [
                "header": ["musicDetailHeaderRenderer": inner],
                "editHeader": ["musicPlaylistEditHeaderRenderer": ["privacy": "PRIVATE"]]]],
                "contents": ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": shelf]]]]])
        }
        throw URLError(.badURL)
    }
    private func response(_ object: [String: Any]) -> MusicHTTPResponse {
        MusicHTTPResponse(data: try! JSONSerialization.data(withJSONObject: object), statusCode: 200)
    }
}

@Suite("Reserved queue playlist client writes")
struct QueuePlaylistWritesTests {
    private func session() async -> MusicSessionStore {
        let store = MusicSessionStore()
        await store.replaceSession(accountID: String(repeating: "a", count: 64), cookieHeader: "fixture=1", sapisid: "fixture",
            configuration: MusicClientConfiguration(apiKey: "fixture", clientVersion: "fixture"))
        return store
    }

    @Test func ordinaryDefaultCapabilitiesSendNoCreateOrAppendRequest() async throws {
        let transport = QueueWriteTransport()
        let sessions = await session()
        let client = YouTubeMusicClient(transport: transport, sessions: sessions)
        let scope = await sessions.snapshot().scope
        await #expect(throws: MusicLibraryEditError.featureUnavailable) { try await client.beginQueuePlaylistSave(expectedScope: scope) }
        #expect(!client.libraryEditCapabilities.playlists)
        #expect(await transport.requests.isEmpty)
    }

    @Test func reservationBlocksOtherAppMutationsAndWritesPrivateDuplicatePreservingBatches() async throws {
        let transport = QueueWriteTransport()
        let sessions = await session()
        let client = YouTubeMusicClient(transport: transport, sessions: sessions, libraryEditCapabilities: .init(playlists: true))
        let scope = await sessions.snapshot().scope
        let token = try await client.beginQueuePlaylistSave(expectedScope: scope)
        await #expect(throws: MusicLibraryEditError.operationInProgress) {
            try await client.performLibraryEdit(.renamePlaylist(id: "PLsaved", title: "Concurrent"), expectedScope: scope)
        }
        await #expect(throws: MusicLibraryEditError.operationInProgress) { try await client.beginQueuePlaylistSave(expectedScope: scope) }
        let id = try await client.createQueuePlaylist(title: "Reviewed", token: token, expectedScope: scope)
        let videos = ["abcDEF12_-3", "abcDEF12_-3", "xyzABC34_-5"]
        let added = try await client.appendQueuePlaylist(id: id, videoIDs: videos, token: token, expectedScope: scope)
        let read = try await client.readQueuePlaylist(id: id, token: token, expectedScope: scope)
        #expect(read.title == "Reviewed" && read.isPrivate && read.canAddItems && read.occurrences == added)
        #expect(read.occurrences.map(\.videoID) == videos && Set(read.occurrences.map(\.setVideoID)).count == 3)
        let requests = await transport.requests
        #expect(requests.count == 4)
        let createBody = try #require(requests[0].httpBody)
        let create = try #require(JSONSerialization.jsonObject(with: createBody) as? [String: Any])
        #expect(create["privacyStatus"] as? String == "PRIVATE" && create["videoIds"] == nil)
        let appendBody = try #require(requests[1].httpBody)
        let append = try #require(JSONSerialization.jsonObject(with: appendBody) as? [String: Any])
        let actions = try #require(append["actions"] as? [[String: String]])
        #expect(actions.map { $0["addedVideoId"] } == videos.map(Optional.init))
        #expect(actions.allSatisfy { $0["dedupeOption"] == "DEDUPE_OPTION_SKIP" })
        await client.endQueuePlaylistSave(token: token)
        let next = try await client.beginQueuePlaylistSave(expectedScope: scope)
        await client.endQueuePlaylistSave(token: next)
    }

    @Test func changedScopesAndOversizedBatchesFailBeforeAnyFurtherRequest() async throws {
        let transport = QueueWriteTransport()
        let sessions = await session()
        let client = YouTubeMusicClient(transport: transport, sessions: sessions, libraryEditCapabilities: .init(playlists: true))
        let scope = await sessions.snapshot().scope
        let token = try await client.beginQueuePlaylistSave(expectedScope: scope)
        await #expect(throws: MusicLibraryEditError.invalidPlaylistItems) {
            try await client.appendQueuePlaylist(id: "PLsaved", videoIDs: Array(repeating: "abcDEF12_-3", count: 101), token: token, expectedScope: scope)
        }
        await sessions.replaceSession(accountID: String(repeating: "b", count: 64), cookieHeader: "fixture=2", sapisid: "fixture")
        await #expect(throws: MusicServiceError.sessionChanged) { try await client.createQueuePlaylist(title: "Wrong account", token: token, expectedScope: scope) }
        #expect(await transport.requests.isEmpty)
        await client.endQueuePlaylistSave(token: token)
    }

    @Test func authoritativeTitleAndEveryOccurrenceAreRequiredForReadback() async throws {
        for missingTitle in [true, false] {
            let transport = QueueWriteTransport()
            let sessions = await session()
            let client = YouTubeMusicClient(transport: transport, sessions: sessions, libraryEditCapabilities: .init(playlists: true))
            let scope = await sessions.snapshot().scope
            let token = try await client.beginQueuePlaylistSave(expectedScope: scope)
            let id = try await client.createQueuePlaylist(title: "Reviewed", token: token, expectedScope: scope)
            _ = try await client.appendQueuePlaylist(id: id, videoIDs: ["abcDEF12_-3"], token: token, expectedScope: scope)
            if missingTitle { await transport.omitTitle() } else { await transport.omitOccurrences() }
            await #expect(throws: (any Error).self) { try await client.readQueuePlaylist(id: id, token: token, expectedScope: scope) }
            await client.endQueuePlaylistSave(token: token)
        }
    }
}
