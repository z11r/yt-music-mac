import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

@Suite("Reviewed catalog queue building") @MainActor
struct CatalogQueueBuilderTests {
    @Test func phrasesStayOpaqueAndInvalidOrExcessiveInputNeverStartsARead() async throws {
        #expect(try CatalogQueueInput.queries("  Björk live ; play\nJazz  1990\nbJÖrK live ; play\n") == ["Björk live ; play", "Jazz  1990"])
        let h = BuilderHarness()
        for input in ["", " \n ", "a\nb\nc\nd\ne\nf", "a\u{0}b", "a\tb", String(repeating: "a", count: 501), String(repeating: "界", count: 1_366)] {
            h.model.edit(input)
            #expect(h.model.search() == nil)
        }
        #expect(await h.probe.calls.isEmpty)
        #expect(h.commits.isEmpty)
    }
    @Test func readResultsInterleaveAndDeduplicateWithoutChangingPlaybackOrQueue() async throws {
        let h = BuilderHarness()
        await h.probe.set("rock", tracks: [song(1), song(2)])
        await h.probe.set("jazz", tracks: [song(3), song(1), song(4)])
        h.model.edit("rock\njazz"); await h.model.search()?.value
        let review = try #require(h.model.review)
        #expect(review.rows.map(\.id) == [song(1).id, song(3).id, song(2).id, song(4).id])
        #expect(review.rows[0].queries == ["rock", "jazz"])
        #expect(h.commits.isEmpty && h.model.completedQueries == 2)
        #expect(await h.probe.calls.map(\.0) == ["rock", "jazz"])
    }
    @Test func unknownUploadsEpisodesUnavailableNamesAndInvalidIDsAreExcluded() async throws {
        let h = BuilderHarness()
        var unknown = song(2); unknown.contentKind = nil
        var upload = song(3); upload.origin = .upload
        var episode = song(4); episode.contentKind = .podcastEpisode
        var missing = song(5); missing.artist = "Artiste inconnu"
        let malformed = Track(id: "bad", title: "Song", artist: "Artist", contentKind: .song)
        await h.probe.set("music", tracks: [song(1), unknown, upload, episode, missing, malformed])
        h.model.edit("music"); await h.model.search()?.value
        #expect(h.model.review?.rows.map(\.id) == [song(1).id])
    }
    @Test func previewBoundsAndPartialCoverageAreExplicit() async throws {
        let h = BuilderHarness()
        let queries = (0..<5).map { "query\($0)" }
        for (index, query) in queries.enumerated() {
            await h.probe.set(query, tracks: (0..<201).map { song(index * 1_000 + $0) })
        }
        h.model.edit(queries.joined(separator: "\n")); await h.model.search()?.value
        let review = try #require(h.model.review)
        #expect(review.rows.count == 50)
        #expect(review.rows.prefix(5).map(\.id) == (0..<5).map { song($0 * 1_000).id })
        #expect(review.reports.allSatisfy { $0.incomplete && $0.eligibleCount == 200 })
        #expect(await h.probe.calls.count == 5)
    }
    @Test func aFailedPhraseNeverPublishesOrCommitsAPartialReviewOrRetriesAutomatically() async {
        let h = BuilderHarness()
        await h.probe.set("first", tracks: [song(1)])
        await h.probe.fail("second")
        h.model.edit("first\nsecond\nthird"); await h.model.search()?.value
        #expect(h.model.review == nil && h.model.message != nil)
        #expect(await h.probe.calls.map(\.0) == ["first", "second"])
        #expect(h.commits.isEmpty)
    }
    @Test func canceledReadsRetainTheirSlotUntilUnderlyingWorkSettles() async {
        let slot = CatalogQueueReadSlot(), first = BuilderHarness(), second = BuilderHarness()
        let a = first.makeModel(slot: slot), b = second.makeModel(slot: slot)
        await first.probe.hold("held")
        a.edit("held\nnever"); let pending = a.search()
        await first.probe.waitForHeld()
        a.cancel()
        #expect(a.isBusy && a.search() == nil)
        b.edit("other"); await b.search()?.value
        #expect(b.review == nil && b.message == CatalogQueueIssue.busy.message)
        #expect(await second.probe.calls.isEmpty)
        await first.probe.release(); await pending?.value
        #expect(!a.isBusy && a.review == nil)
        #expect(await first.probe.calls.map(\.0) == ["held"])
    }
    @Test func editsOwnerChangesAndCredentialChangesFenceHeldReplies() async {
        for change in 0..<3 {
            let h = BuilderHarness()
            await h.probe.hold("held")
            h.model.edit("held"); let pending = h.model.search()
            await h.probe.waitForHeld()
            if change == 0 { h.model.edit("new text") }
            else if change == 1 { h.current = nil }
            else { await h.sessions.clear() }
            await h.probe.release(); await pending?.value
            #expect(h.model.review == nil && h.commits.isEmpty)
        }
    }
    @Test func selectedSourceOrderAndOnceOnlyCommitArePreserved() async throws {
        let h = BuilderHarness()
        await h.probe.set("songs", tracks: [song(1), song(2), song(3)])
        h.model.edit("songs"); await h.model.search()?.value
        let review = try #require(h.model.review)
        #expect(!(await h.model.accept(reviewID: review.id, selectedIDs: ["foreign"])))
        let ids: Set<String> = [song(3).id, song(1).id]
        let first = Task { await h.model.accept(reviewID: review.id, selectedIDs: ids) }
        let duplicate = Task { await h.model.accept(reviewID: review.id, selectedIDs: ids) }
        _ = await first.value; _ = await duplicate.value
        #expect(h.commits.count == 1 && h.commits[0].0.map(\.id) == [song(1).id, song(3).id])
        #expect(h.commits[0].1 == nil && h.model.review == nil)
    }
    @Test func staleReviewCannotWriteAndInvalidNameDoesNotConsumeAValidReview() async throws {
        let h = BuilderHarness()
        await h.probe.set("songs", tracks: [song(1)])
        h.model.edit("songs"); await h.model.search()?.value
        let review = try #require(h.model.review)
        #expect(!(await h.model.accept(reviewID: review.id, selectedIDs: [song(1).id], name: "\n")))
        #expect(h.model.review != nil)
        #expect(await h.model.accept(reviewID: review.id, selectedIDs: [song(1).id], name: "  Favorite search  "))
        #expect(h.commits.first?.1 == "Favorite search")
        h.model.edit("songs"); await h.model.search()?.value
        let next = try #require(h.model.review)
        h.current = nil
        #expect(!(await h.model.accept(reviewID: next.id, selectedIDs: [song(1).id])))
        #expect(h.commits.count == 1)
    }
    @Test func nativeAppendKeepsCurrentOccurrencesAndProfileBoundaries() async throws {
        let domain = "CatalogQueueNativeTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        let session = AppSession(configuration: .sceneCheck(preferences: preferences, transport: SceneCheckTransport()))
        await session.start()
        session.addToQueue([song(1), song(1)])
        let owner = try #require(session.catalogQueueOwner)
        let identity = CatalogQueueIdentity(await session.account.credentials.snapshot())
        let before = session.queue.snapshot()
        #expect(await session.commitCatalogQueue(owner: owner, identity: identity, tracks: [song(2)], name: nil))
        #expect(Array(session.queue.entries.prefix(2)) == before.entries)
        #expect(session.queue.currentOccurrence == nil && !session.wantsPlayback)
        #expect(!(await session.commitCatalogQueue(owner: owner, identity: identity, tracks: [song(3)], name: nil)))
        let current = try #require(session.catalogQueueOwner)
        #expect(!(await session.commitCatalogQueue(owner: current, identity: identity, tracks: [song(3)], name: "Needs account")))
        session.quiesceForProfileSwitch()
        #expect(!(await session.commitCatalogQueue(owner: current, identity: identity, tracks: [song(3)], name: nil)))
        await session.shutdown()
    }
    @Test func nativeReadRechecksOwnerAfterSlotAndNativeCommitKeepsTheReviewedCredentialScope() async throws {
        let domain = "CatalogQueueAdmissionTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        let transport = SceneCheckTransport()
        let session = AppSession(configuration: .sceneCheck(preferences: preferences, transport: transport))
        await session.start()
        let owner = try #require(session.catalogQueueOwner)
        let identity = CatalogQueueIdentity(await session.account.credentials.snapshot())
        await session.account.credentials.clear()
        #expect(session.catalogQueueOwner == owner)
        #expect(!(await session.commitCatalogQueue(owner: owner, identity: identity, tracks: [song(1)], name: nil)))
        #expect(session.queue.isEmpty)
        let slot = CatalogQueueReadSlot()
        await #expect(throws: MusicServiceError.sessionChanged) {
            try await slot.read(query: "phrase", scope: identity.scope, owner: owner, load: { query, scope, captured in
                session.quiesceForProfileSwitch()
                return try await session.readCatalogQueue(query: query, scope: scope, owner: captured)
            })
        }
        #expect(await transport.attempts == 0)
        await session.shutdown()
    }
    @Test func savedQueueAdmissionRejectsChangedCredentialOrOwnerAfterItsSnapshotAwait() async throws {
        for changeOwner in [false, true] {
            let old = MusicSession(scope: UUID(), accountID: String(repeating: "a", count: 64), cookieHeader: "fixture=1", sapisid: "fixture")
            let gate = BuilderSaveSnapshotGate()
            // A permitted call would reject this non-file URL. The expected
            // account-changed feedback proves refusal before store access.
            let library = NamedQueueLibrary(store: NamedQueueStore(directoryURL: URL(string: "https://example.invalid/unused")!), sessions: gate)
            var ownerCurrent = true
            let saving = Task { await library.save(name: "Reviewed", snapshot: PlaybackQueue().snapshot(),
                expectedScope: library.scope, expectedSession: .init(scope: old.scope, account: old.accountID!),
                isCurrent: { ownerCurrent }) }
            await gate.waitUntilHeld()
            if changeOwner { ownerCurrent = false }
            await gate.release(changeOwner ? old : MusicSession(scope: UUID(), accountID: old.accountID, cookieHeader: "fixture=1", sapisid: "fixture"))
            #expect(!(await saving.value))
            #expect(library.errorMessage == SavedQueueAccessError.accountChanged.localizedDescription)
        }
    }
    @Test(arguments: [false, true])
    func nativeSettlementAndShutdownWaitForHeldCatalogReads(_ shutdown: Bool) async throws {
        let domain = "CatalogQueueSettlementTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        let transport = BuilderHeldHTTP(), credentials = MusicSessionStore()
        await credentials.replaceSession(accountID: String(repeating: "a", count: 64), cookieHeader: "fixture=1", sapisid: "fixture",
            configuration: .init(apiKey: "fixture", clientVersion: "fixture"))
        let session = AppSession(configuration: .init(preferences: preferences, dataStore: .nonPersistent(), credentials: credentials,
            client: YouTubeMusicClient(transport: transport, sessions: credentials), queueStore: nil, queueStorageError: nil,
            installsSystemMedia: false, isSceneCheck: true))
        let owner = try #require(session.catalogQueueOwner), scope = await credentials.snapshot().scope
        let reading = Task { try await session.readCatalogQueue(query: "held fixture", scope: scope, owner: owner) }
        await transport.waitUntilHeld()
        session.quiesceForProfileSwitch()
        if shutdown { reading.cancel() }
        var started = false, settled = false
        let settling = Task {
            started = true
            if shutdown { await session.shutdown() }
            else { await session.settleForProfileSwitch() }
            settled = true
        }
        while !started { await Task.yield() }
        // Give other idle session components a chance to drain. The held HTTP
        // operation must remain an independent settlement barrier throughout.
        for _ in 0..<200 { await Task.yield() }
        #expect(!settled)
        await #expect(throws: MusicServiceError.sessionChanged) {
            try await session.readCatalogQueue(query: "must not start", scope: scope, owner: owner)
        }
        #expect(await transport.attempts == 1)
        await transport.release()
        if shutdown { await #expect(throws: CancellationError.self) { try await reading.value } }
        else { await #expect(throws: MusicServiceError.sessionChanged) { try await reading.value } }
        await settling.value
        #expect(settled && session.queue.isEmpty && !session.wantsPlayback)
        if !shutdown { await session.shutdown() }
    }
}

private func song(_ number: Int) -> Track {
    .init(id: String(format: "s%010d", number), title: "Song \(number)", artist: "Artist", duration: 180, contentKind: .song)
}
private actor BuilderProbe {
    private(set) var calls: [(String, UUID)] = []
    private var pages: [String: MusicPage] = [:]
    private var failures = Set<String>()
    private var heldQuery: String?
    private var held: CheckedContinuation<MusicPage, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func set(_ query: String, tracks: [Track]) { pages[query] = .init(title: query, sections: [], items: tracks.map(MusicItem.track)) }
    func fail(_ query: String) { failures.insert(query) }
    func hold(_ query: String) { heldQuery = query }
    func waitForHeld() async { if held == nil { await withCheckedContinuation { arrival = $0 } } }
    func release() { held?.resume(returning: .init(title: "Held", sections: [], items: [MusicItem.track(song(1))])); held = nil }
    func read(_ query: String, _ scope: UUID) async throws -> MusicPage {
        calls.append((query, scope))
        if heldQuery == query {
            return await withCheckedContinuation { held = $0; arrival?.resume(); arrival = nil }
        }
        if failures.contains(query) { throw URLError(.timedOut) }
        return pages[query] ?? .init(title: query, sections: [], items: [])
    }
}
@MainActor private final class BuilderHarness {
    let sessions = MusicSessionStore()
    let probe = BuilderProbe()
    var current: CatalogQueueOwner? = .init(account: UUID(), startup: UUID(), queue: PlaybackQueue().revision)
    var commits: [([Track], String?)] = []
    lazy var model = makeModel(slot: CatalogQueueReadSlot())
    func makeModel(slot: CatalogQueueReadSlot) -> CatalogQueueBuilder {
        .init(sessions: sessions, slot: slot, owner: { [weak self] in self?.current },
            load: { [probe] query, scope, _ in try await probe.read(query, scope) },
            commit: { [weak self] owner, _, tracks, name in
                guard let self, self.current == owner else { return false }
                self.commits.append((tracks, name)); return true
            })
    }
}
private actor BuilderSaveSnapshotGate: MusicSessionProviding {
    private var pending: CheckedContinuation<MusicSession, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func snapshot() async -> MusicSession {
        await withCheckedContinuation { pending = $0; arrival?.resume(); arrival = nil }
    }
    func waitUntilHeld() async { if pending == nil { await withCheckedContinuation { arrival = $0 } } }
    func release(_ value: MusicSession) { pending?.resume(returning: value); pending = nil }
}
private actor BuilderHeldHTTP: MusicHTTPTransport {
    private var reply: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private(set) var attempts = 0
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        attempts += 1
        #expect(request.url?.path == "/youtubei/v1/search")
        // Deliberately does not cooperate with Task cancellation until release.
        await withCheckedContinuation { reply = $0; arrival?.resume(); arrival = nil }
        return .init(data: Data(#"{"contents":{"sectionListRenderer":{"contents":[]}}}"#.utf8), statusCode: 200)
    }
    func waitUntilHeld() async { if reply == nil { await withCheckedContinuation { arrival = $0 } } }
    func release() { reply?.resume(); reply = nil }
}
