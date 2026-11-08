import Foundation
import MusicCore
import Testing
import WebKit
import YouTubeMusic
@testable import YTMusicMac

@MainActor
@Suite("Whole collection playback")
struct CollectionPlaybackTests {
    @Test func sevenPagesPreserveAll618OccurrencesBeforeCommitting() async throws {
        let counts = [97, 99, 100, 100, 99, 100, 23]
        let transport = CollectionTransport(counts.enumerated().map { index, count in
            .page(collectionData(Array(repeating: "same-song", count: count),
                                 next: index < counts.count - 1 ? "page-\(index + 2)" : nil,
                                 continuation: index != 0))
        })
        let client = collectionClient(transport)
        let first = try await client.playlist(id: "PLfixture")
        let operation = CollectionPlayback { try await client.nextPage($0) }
        var queue = PlaybackQueue()
        queue.append([collectionTrack("old")])
        let previous = queue.snapshot()
        var commits = 0
        let task = operation.start(page: first, action: .play, isCurrent: { queue.snapshot() == previous }) { page, action in
            #expect(action == .play)
            #expect(page.continuation == nil)
            commits += 1
            queue.replaceForPlayback(with: page.tracks, shuffled: false)
        }
        #expect(queue.snapshot() == previous)
        await task.value
        #expect(commits == 1)
        #expect(queue.entries.count == 618)
        #expect(Set(queue.entries.map(\.id)).count == 618)
        #expect(queue.entries.allSatisfy { $0.track.id == "same-song" })
        #expect(operation.loadedTrackCount == 618)
        #expect(!operation.isLoading)
        #expect(operation.errorMessage == nil)
        let requests = await transport.requests
        #expect(requests.count == 7)
    }

    @Test func failedPageRetriesTheSameCursorWithoutDuplicatingEarlierPages() async throws {
        let transport = CollectionTransport([
            .page(collectionData(["a"], next: "second")),
            .page(collectionData(["a"], next: "third", continuation: true)),
            .failure(.notConnectedToInternet),
            .page(collectionData(["b"], continuation: true)),
        ])
        let client = collectionClient(transport)
        let first = try await client.playlist(id: "PLfixture")
        let operation = CollectionPlayback { try await client.nextPage($0) }
        var queue = PlaybackQueue()
        queue.append([collectionTrack("old")])
        let previous = queue.snapshot()
        let task = operation.start(page: first, action: .append, isCurrent: { queue.snapshot() == previous }) { page, action in
            #expect(action == .append)
            queue.append(page.tracks)
        }
        await task.value
        #expect(queue.snapshot() == previous)
        #expect(operation.loadedTrackCount == 2)
        #expect(operation.canRetry)
        #expect(operation.errorMessage != nil)
        let retry = try #require(operation.retry())
        await retry.value
        #expect(queue.entries.map(\.track.id) == ["old", "a", "a", "b"])
        #expect(queue.entries.first?.id == previous.entries.first?.id)
        #expect(operation.errorMessage == nil)
        let requests = await transport.requests
        let cursors = try requests.dropFirst().map { request in
            try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        }.compactMap { $0?["continuation"] as? String }
        #expect(cursors == ["second", "third", "third"])
    }

    @Test func cancelAndANewerActionRejectTheOldResponse() async throws {
        let transport = CollectionTransport([.page(collectionData(["a"], next: "second")), .wait, .wait])
        let client = collectionClient(transport)
        let first = try await client.playlist(id: "PLfixture")
        let operation = CollectionPlayback { try await client.nextPage($0) }
        var committed: [String] = []
        let old = operation.start(page: first, action: .play, isCurrent: { true }) { page, _ in
            committed = page.tracks.map(\.id)
        }
        await transport.waitForRequestCount(2)
        let newer = operation.start(page: first, action: .append, isCurrent: { true }) { page, action in
            #expect(action == .append)
            committed = page.tracks.map(\.id)
        }
        await transport.waitForRequestCount(3)
        await transport.releaseFirst(collectionData(["stale"], continuation: true))
        await old.value
        #expect(committed.isEmpty)
        #expect(operation.isLoading)
        await transport.releaseFirst(collectionData(["current"], continuation: true))
        await newer.value
        #expect(committed == ["a", "current"])
    }

    @Test func changedContextDiscardsTheResultAndRetry() async throws {
        let transport = CollectionTransport([.page(collectionData(["a"], next: "second")), .wait])
        let client = collectionClient(transport)
        let first = try await client.playlist(id: "PLfixture")
        let operation = CollectionPlayback { try await client.nextPage($0) }
        let context = CollectionContext()
        var committed = false
        let task = operation.start(page: first, action: .shuffle, isCurrent: { context.isCurrent }) { _, _ in committed = true }
        await transport.waitForRequestCount(2)
        context.isCurrent = false
        await transport.releaseFirst(collectionData(["b"], continuation: true))
        await task.value
        #expect(!committed)
        #expect(!operation.isLoading)
        #expect(!operation.canRetry)
        #expect(operation.retry() == nil)
    }

    @Test func accountScopeChangeCannotCommitOrRetryAnOldContinuation() async throws {
        let transport = CollectionTransport([.page(collectionData(["a"], next: "second")), .wait])
        let store = MusicSessionStore()
        await store.replaceSession(accountID: "fixture-account", cookieHeader: "fixture=value", sapisid: "fixture",
                                   configuration: MusicClientConfiguration(apiKey: "fixture", clientVersion: "fixture"))
        let client = YouTubeMusicClient(transport: transport, sessions: store)
        let first = try await client.playlist(id: "PLfixture")
        let operation = CollectionPlayback { try await client.nextPage($0) }
        var committed = false
        let task = operation.start(page: first, action: .play, isCurrent: { true }) { _, _ in committed = true }
        await transport.waitForRequestCount(2)
        await store.clear()
        await transport.releaseFirst(collectionData(["b"], continuation: true))
        await task.value
        #expect(!committed)
        #expect(operation.errorMessage == MusicServiceError.sessionChanged.localizedDescription)
        #expect(!operation.canRetry)
    }

    @Test func pageLimitNeverCommitsATruncatedCollection() async throws {
        let transport = CollectionTransport([
            .page(collectionData(["a"], next: "second")),
            .page(collectionData(["b"], next: "third", continuation: true)),
        ])
        let client = collectionClient(transport)
        let first = try await client.playlist(id: "PLfixture")
        let operation = CollectionPlayback(maximumPages: 2) { try await client.nextPage($0) }
        var committed = false
        await operation.start(page: first, action: .play, isCurrent: { true }) { _, _ in committed = true }.value
        #expect(!committed)
        #expect(!operation.canRetry)
        #expect(operation.errorMessage == MusicServiceError.pageLimitReached.localizedDescription)
        let requests = await transport.requests
        #expect(requests.count == 2)
    }

    @Test func songLimitNeverCommitsATruncatedCollection() async throws {
        let transport = CollectionTransport([
            .page(collectionData(["a"], next: "second")),
            .page(collectionData(["b", "c"], continuation: true)),
        ])
        let client = collectionClient(transport)
        let first = try await client.playlist(id: "PLfixture")
        let operation = CollectionPlayback(maximumTracks: 2) { try await client.nextPage($0) }
        var committed = false
        await operation.start(page: first, action: .append, isCurrent: { true }) { _, _ in committed = true }.value
        #expect(!committed)
        #expect(operation.errorMessage != nil)
        #expect(!operation.canRetry)
    }

    @Test func anEmptyIntermediatePageStillFollowsItsCursor() async throws {
        let transport = CollectionTransport([
            .page(collectionData(["a"], next: "second")),
            .page(collectionData([], next: "third", continuation: true)),
            .page(collectionData(["b"], continuation: true)),
        ])
        let client = collectionClient(transport)
        let first = try await client.playlist(id: "PLfixture")
        let operation = CollectionPlayback { try await client.nextPage($0) }
        var committed: [String] = []
        await operation.start(page: first, action: .play, isCurrent: { true }) { page, _ in
            committed = page.tracks.map(\.id)
        }.value
        #expect(committed == ["a", "b"])
    }

    @Test func alreadyLoadedPagesAreNotFetchedOrAddedAgain() async throws {
        let transport = CollectionTransport([
            .page(collectionData(["a"], next: "second")),
            .page(collectionData(["b"], next: "third", continuation: true)),
            .page(collectionData(["c"], continuation: true)),
        ])
        let client = collectionClient(transport)
        let first = try await client.playlist(id: "PLfixture")
        let second = try await client.nextPage(#require(first.continuation))
        let loaded = MusicPage(title: first.title, sections: first.sections + second.sections,
                               items: first.items + second.items, continuation: second.continuation,
                               playlistItems: first.playlistItems + second.playlistItems)
        let operation = CollectionPlayback { try await client.nextPage($0) }
        var committed: [String] = []
        await operation.start(page: loaded, action: .append, isCurrent: { true }) { page, _ in
            committed = page.tracks.map(\.id)
        }.value
        #expect(committed == ["a", "b", "c"])
        let requests = await transport.requests
        #expect(requests.count == 3)
    }

    @Test func aggregatingCollectionPagesKeepsDislikeDistinctFromNeutral() async throws {
        let transport = CollectionTransport([
            .page(collectionData(["disliked"], next: "second", ratings: ["disliked": .disliked])),
            .page(collectionData(["neutral"], continuation: true, ratings: ["neutral": .neutral])),
        ])
        let client = collectionClient(transport)
        let first = try await client.playlist(id: "PLfixture")
        let operation = CollectionPlayback { try await client.nextPage($0) }
        var observed: [String: MusicRating] = [:]
        await operation.start(page: first, action: .append, isCurrent: { true }) { complete, _ in
            observed = complete.ratings
        }.value
        #expect(observed == ["disliked": .disliked, "neutral": .neutral])
    }

    @Test func emptyCollectionLeavesTheQueueUntouched() async {
        let operation = CollectionPlayback { _ in
            Issue.record("A terminal page must not send a request")
            throw MusicServiceError.invalidInput
        }
        let page = MusicPage(title: "Empty", sections: [], items: [])
        var committed = false
        await operation.start(page: page, action: .play, isCurrent: { true }) { _, _ in committed = true }.value
        #expect(!committed)
        #expect(operation.errorMessage != nil)
        #expect(!operation.canRetry)
    }

    @Test func manualQueueEditCancelsAnInFlightSessionAppend() async throws {
        let transport = CollectionTransport([.page(collectionData(["a"], next: "second")), .wait])
        let name = "collection-session-test.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let credentials = MusicSessionStore()
        let session = AppSession(configuration: AppSessionConfiguration(
            preferences: preferences, dataStore: .nonPersistent(), credentials: credentials,
            client: collectionClient(transport), queueStore: nil, queueStorageError: nil,
            installsSystemMedia: false, isSceneCheck: true))
        session.addToQueue([collectionTrack("old")])
        session.navigate(to: .collection(MusicCollection(id: "PLfixture", kind: .playlist, title: "Fixture")))
        try await waitUntil { !session.isLoading }
        let task = try #require(session.performCollectionAction(.append))
        await transport.waitForRequestCount(2)
        session.addToQueue([collectionTrack("manual")])
        await transport.releaseFirst(collectionData(["b"], continuation: true))
        await task.value
        #expect(session.queue.entries.map(\.track.id) == ["old", "manual"])
        #expect(!session.collectionPlayback.isLoading)
        #expect(!session.player.playbackIntent)
        #expect(session.player.webView.url == nil)
    }

    @Test func naturalQueueAdvancementKeepsAnExplicitCollectionAppend() async throws {
        let transport = CollectionTransport([.page(collectionData(["a"], next: "second")), .wait])
        let name = "collection-natural-advance-test.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let session = AppSession(configuration: AppSessionConfiguration(
            preferences: preferences, dataStore: .nonPersistent(), credentials: MusicSessionStore(),
            client: collectionClient(transport), queueStore: nil, queueStorageError: nil,
            installsSystemMedia: false, isSceneCheck: true))
        _ = session.queue.replace(with: [collectionTrack("old"), collectionTrack("next")], startAt: 0)
        let occurrence = try #require(session.queue.currentOccurrence)
        session.navigate(to: .collection(MusicCollection(id: "PLfixture", kind: .playlist, title: "Fixture")))
        try await waitUntil { !session.isLoading }
        let task = try #require(session.performCollectionAction(.append))
        await transport.waitForRequestCount(2)
        _ = session.queue.handleEnd(occurrence: occurrence)
        await transport.releaseFirst(collectionData(["b"], continuation: true))
        await task.value
        #expect(session.queue.entries.map(\.track.id) == ["old", "next", "a", "b"])
        #expect(session.queue.currentTrack?.id == "next")
        #expect(!session.player.playbackIntent)
    }

    @Test func startingCollectionActionSupersedesAnOlderExactLookup() async throws {
        let transport = CollectionTransport([.page(collectionData(["a"]))])
        let name = "collection-lookup-test.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let session = AppSession(configuration: AppSessionConfiguration(
            preferences: preferences, dataStore: .nonPersistent(), credentials: MusicSessionStore(),
            client: collectionClient(transport), queueStore: nil, queueStorageError: nil,
            installsSystemMedia: false, isSceneCheck: true))
        session.navigate(to: .collection(MusicCollection(id: "PLfixture", kind: .playlist, title: "Fixture")))
        try await waitUntil { !session.isLoading }
        let oldRequest = session.beginScriptedPlaybackRequest()
        let action = try #require(session.performCollectionAction(.append))
        await #expect(throws: AppScriptingError.superseded) {
            _ = try await session.playScriptedVideo("abcDEF12_-3", requestGeneration: oldRequest)
        }
        await action.value
        #expect(session.player.webView.url == nil)
    }

    @Test func navigatingAwayCancelsAnInFlightSessionAppend() async throws {
        let transport = CollectionTransport([
            .page(collectionData(["a"], next: "second")), .wait, .page(collectionData([])),
        ])
        let name = "collection-navigation-test.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let session = AppSession(configuration: AppSessionConfiguration(
            preferences: preferences, dataStore: .nonPersistent(), credentials: MusicSessionStore(),
            client: collectionClient(transport), queueStore: nil, queueStorageError: nil,
            installsSystemMedia: false, isSceneCheck: true))
        session.addToQueue([collectionTrack("old")])
        session.navigate(to: .collection(MusicCollection(id: "PLfixture", kind: .playlist, title: "Fixture")))
        try await waitUntil { !session.isLoading }
        let task = try #require(session.performCollectionAction(.append))
        await transport.waitForRequestCount(2)
        session.navigate(to: .explore)
        await transport.releaseFirst(collectionData(["b"], continuation: true))
        await task.value
        try await waitUntil { !session.isLoading }
        #expect(session.destination == .explore)
        #expect(session.queue.entries.map(\.track.id) == ["old"])
        #expect(!session.collectionPlayback.isLoading)
        #expect(session.player.webView.url == nil)
    }
}

@MainActor private final class CollectionContext {
    var isCurrent = true
}

private func collectionTrack(_ id: String) -> Track { Track(id: id, title: "Fixture Song", artist: "Fixture Artist") }

private func collectionData(_ ids: [String], next: String? = nil, continuation: Bool = false,
                            ratings: [String: MusicRating] = [:]) -> Data {
    let items: [[String: Any]] = ids.map { id in
        var renderer: [String: Any] = ["playlistItemData": ["videoId": id],
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Fixture Song"]]]]]]]
        if let rating = ratings[id] {
            renderer["menu"] = ["menuRenderer": ["topLevelButtons": [["likeButtonRenderer": ["likeStatus": rating.rawValue]]]]]
        }
        return ["musicResponsiveListItemRenderer": renderer]
    }
    var shelf: [String: Any] = ["contents": items]
    if let next { shelf["continuations"] = [["nextContinuationData": ["continuation": next]]] }
    let object: [String: Any] = continuation
        ? ["continuationContents": ["musicPlaylistShelfContinuation": shelf]]
        : ["contents": ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": shelf]]]]]
    return try! JSONSerialization.data(withJSONObject: object)
}

private func collectionClient(_ transport: CollectionTransport) -> YouTubeMusicClient {
    YouTubeMusicClient(transport: transport, sessions: CollectionFixtureSession())
}

private struct CollectionFixtureSession: MusicSessionProviding {
    private let value = MusicSession(scope: UUID(), configuration: MusicClientConfiguration(apiKey: "fixture", clientVersion: "fixture"))
    func snapshot() async -> MusicSession { value }
}

private actor CollectionTransport: MusicHTTPTransport {
    enum Step { case page(Data), failure(URLError.Code), wait }
    private var steps: [Step]
    private var pending: [CheckedContinuation<MusicHTTPResponse, any Error>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var requests: [URLRequest] = []

    init(_ steps: [Step]) { self.steps = steps }

    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        let ready = observers.filter { requests.count >= $0.0 }
        observers.removeAll { requests.count >= $0.0 }
        for observer in ready { observer.1.resume() }
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        switch steps.removeFirst() {
        case let .page(data): return MusicHTTPResponse(data: data, statusCode: 200)
        case let .failure(code): throw URLError(code)
        case .wait:
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
    }

    func waitForRequestCount(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func releaseFirst(_ data: Data) {
        pending.removeFirst().resume(returning: MusicHTTPResponse(data: data, statusCode: 200))
    }
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw MusicServiceError.serviceUnavailable }
        await Task.yield()
    }
}
