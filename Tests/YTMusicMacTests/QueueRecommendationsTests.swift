import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

private func recommendedSong(_ number: Int) -> Track {
    Track(id: String(format: "%011d", number), title: "Song \(number)", artist: "Artist", origin: .catalog, contentKind: .song)
}

private actor RecommendationReadFake {
    enum Failure: Error { case unavailable }
    private(set) var requests: [(String, UUID)] = []
    private var pending: [Int: CheckedContinuation<[Track], any Error>] = [:]
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    func read(_ id: String, scope: UUID) async throws -> [Track] {
        let index = requests.count; requests.append((id, scope))
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            let ready = waiting.filter { $0.0 < requests.count }
            waiting.removeAll { $0.0 < requests.count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForRequest(_ index: Int) async {
        if requests.count > index { return }
        await withCheckedContinuation { waiting.append((index, $0)) }
    }
    func finish(_ index: Int, _ result: Result<[Track], any Error>) { pending.removeValue(forKey: index)?.resume(with: result) }
}

private actor GatedRecommendationSessions: MusicSessionProviding {
    let store: MusicSessionStore
    private var pauseNext = false
    private var paused: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    init(store: MusicSessionStore) { self.store = store }
    func pause() { pauseNext = true }
    func waitForPause() async { if paused == nil { await withCheckedContinuation { waiter = $0 } } }
    func release() { paused?.resume(); paused = nil }
    func snapshot() async -> MusicSession {
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { paused = $0; waiter?.resume(); waiter = nil }
        }
        return await store.snapshot()
    }
}

@MainActor private final class RecommendationOwner {
    var account = UUID()
    var intent = UUID()
    var wantsPlayback = false
    var enabled = true
    var queue = PlaybackQueue()
    var appends = 0
    init() {
        queue.replace(with: [recommendedSong(1), recommendedSong(2), recommendedSong(1)], startAt: 0)
    }
    var context: QueueRecommendationContext {
        QueueRecommendationContext(account: account, revision: queue.revision, currentEntryID: queue.currentEntryID,
            occurrence: queue.currentOccurrence, intent: intent, wantsPlayback: wantsPlayback, repeatMode: queue.repeatMode)
    }
    func start(_ recommendations: QueueRecommendations) throws -> Task<Void, Never> {
        let captured = context
        let seed = try #require(queue.currentTrack)
        let task = recommendations.start(seed: seed, queue: queue, context: captured,
            isCurrent: { self.enabled && self.context == captured }, append: { tracks in
                self.appends += 1; self.queue.append(tracks, origin: .recommendation)
            })
        return try #require(task)
    }
}

@MainActor @Suite("Explicit queue recommendation previews", .serialized)
struct QueueRecommendationsTests {
    private let key = String(repeating: "a", count: 64)
    private func session() async -> MusicSessionStore {
        let store = MusicSessionStore()
        await store.replaceSession(accountID: key, cookieHeader: "fixture=1", sapisid: "fixture")
        return store
    }
    private func model(_ sessions: any MusicSessionProviding, _ fake: RecommendationReadFake) -> QueueRecommendations {
        QueueRecommendations(sessions: sessions, now: { Date(timeIntervalSince1970: 1_800_000_000) }) { id, scope in
            try await fake.read(id, scope: scope)
        }
    }
    private func finish(_ task: Task<Void, Never>, fake: RecommendationReadFake, offered: [Track], index: Int = 0) async {
        await fake.waitForRequest(index); await fake.finish(index, .success(offered)); await task.value
    }

    @Test func immutablePreviewAndExplicitSelectionAppendInServiceOrderWithoutChangingExistingOccurrences() async throws {
        let sessions = await session(); let fake = RecommendationReadFake(); let recommendations = model(sessions, fake)
        let owner = RecommendationOwner()
        owner.queue.repeatMode = .one; owner.queue.setShuffle(true)
        let original = owner.queue.snapshot(); let occurrence = owner.queue.currentOccurrence
        let task = try owner.start(recommendations)
        await finish(task, fake: fake, offered: [recommendedSong(1), recommendedSong(4), recommendedSong(4), recommendedSong(3), recommendedSong(2)])
        let preview = try #require(recommendations.preview)
        #expect(preview.tracks.map(\.id) == [recommendedSong(4).id, recommendedSong(3).id])
        #expect(owner.queue.snapshot() == original && owner.appends == 0)
        #expect(await recommendations.accept(previewID: preview.id, selectedIDs: Set(preview.tracks.reversed().map(\.id)), expectedScope: recommendations.scope))
        #expect(Array(owner.queue.entries.prefix(3)) == original.entries)
        #expect(owner.queue.entries.suffix(2).map(\.track.id) == preview.tracks.map(\.id))
        #expect(owner.queue.entries.suffix(2).allSatisfy { $0.origin == .recommendation && $0.track.origin == .catalog })
        #expect(owner.queue.currentOccurrence == occurrence && owner.queue.currentEntryID == original.currentEntryID)
        #expect(owner.queue.repeatMode == .one && owner.queue.isShuffled && !owner.wantsPlayback)
        #expect(owner.appends == 1 && recommendations.preview == nil)
        #expect(!(await recommendations.accept(previewID: preview.id, selectedIDs: Set(preview.tracks.map(\.id)), expectedScope: recommendations.scope)))
        #expect(owner.queue.undo() && owner.queue.snapshot() == original)
    }

    @Test func candidatesRequireActualSongMetadataAndStrictIDs() async throws {
        let sessions = await session(); let fake = RecommendationReadFake(); let recommendations = model(sessions, fake)
        let owner = RecommendationOwner()
        var variants: [Track] = []
        for index in 10..<19 {
            var track = recommendedSong(index)
            switch index {
            case 10: track.origin = .upload
            case 11: track.contentKind = .podcastEpisode
            case 12: track.contentKind = nil
            case 13: track.artist = "Unknown artist"
            case 14: track.artist = "Artiste inconnu"
            case 15: track.artist = " "
            case 16: track.title = track.id
            case 17: track.title = ""
            default: track.title = String(repeating: "x", count: 2_049)
            }
            variants.append(track)
        }
        variants.append(Track(id: "file:///private", title: "Source", artist: "Artist", contentKind: .song))
        let task = try owner.start(recommendations)
        await finish(task, fake: fake, offered: variants + [recommendedSong(3)])
        #expect(recommendations.preview?.tracks == [recommendedSong(3)])
        let badSeed = variants[0]
        let unsupported = recommendations.start(seed: badSeed, queue: owner.queue, context: owner.context, isCurrent: { true }, append: { _ in })
        #expect(unsupported == nil)
        #expect(await fake.requests.count == 1)
    }

    @Test func pageAndPreviewCapsAndTheQueueLimitAreConservative() async throws {
        let sessions = await session(); let fake = RecommendationReadFake(); let recommendations = model(sessions, fake)
        let owner = RecommendationOwner()
        var task = try owner.start(recommendations)
        await finish(task, fake: fake, offered: (3..<250).map(recommendedSong))
        #expect(recommendations.preview?.tracks.count == 20)
        task = try owner.start(recommendations)
        await finish(task, fake: fake, offered: Array(repeating: recommendedSong(1), count: 200) + [recommendedSong(3)], index: 1)
        #expect(recommendations.preview?.tracks.isEmpty == true)
        owner.queue.append(Array(repeating: recommendedSong(2), count: 9_995))
        task = try owner.start(recommendations)
        await finish(task, fake: fake, offered: (3..<25).map(recommendedSong), index: 2)
        #expect(recommendations.preview?.tracks.count == 2)
        let preview = try #require(recommendations.preview)
        #expect(await recommendations.accept(previewID: preview.id, selectedIDs: Set(preview.tracks.map(\.id)), expectedScope: recommendations.scope))
        #expect(owner.queue.entries.count == 10_000)
        let seed = try #require(owner.queue.currentTrack)
        let atLimit = recommendations.start(seed: seed, queue: owner.queue, context: owner.context,
            isCurrent: { true }, append: { _ in })
        #expect(atLimit == nil)
        #expect(await fake.requests.count == 3)
    }

    @Test func staleAccountIntentCurrentOccurrenceSelectionAndQueueEditsRejectAcceptance() async throws {
        for change in 0..<7 {
            let sessions = await session(); let fake = RecommendationReadFake(); let recommendations = model(sessions, fake)
            let owner = RecommendationOwner()
            let task = try owner.start(recommendations)
            await finish(task, fake: fake, offered: [recommendedSong(3)])
            let preview = try #require(recommendations.preview); let scope = recommendations.scope
            switch change {
            case 0: owner.account = UUID()
            case 1: owner.intent = UUID() // A pause/play cycle is stale even if its final Boolean is unchanged.
            case 2: _ = owner.queue.beginPlayback()
            case 3: _ = owner.queue.select(entryID: owner.queue.entries[1].id)
            case 4: owner.queue.append([recommendedSong(4)])
            case 5: owner.wantsPlayback.toggle()
            default: owner.queue.repeatMode = .all
            }
            #expect(!(await recommendations.accept(previewID: preview.id, selectedIDs: [recommendedSong(3).id], expectedScope: scope)))
            #expect(owner.appends == 0 && recommendations.preview == nil)
        }
    }

    @Test func changesDuringAnInFlightReadDiscardTheOldPreview() async throws {
        for change in 0..<4 {
            let sessions = await session(); let fake = RecommendationReadFake(); let recommendations = model(sessions, fake)
            let owner = RecommendationOwner(); let task = try owner.start(recommendations)
            await fake.waitForRequest(0)
            switch change {
            case 0: owner.account = UUID()
            case 1: owner.intent = UUID()
            case 2: _ = owner.queue.beginPlayback()
            default: owner.queue.append([recommendedSong(4)])
            }
            await fake.finish(0, .success([recommendedSong(3)])); await task.value
            #expect(recommendations.preview == nil && !recommendations.isLoading && owner.appends == 0)
        }
    }

    @Test func freshCredentialFencesRejectChangedAccountsSessionsAndSignOutAtLoadAndAccept() async throws {
        for change in 0..<3 {
            for atAcceptance in [false, true] {
                let sessions = await session(); let fake = RecommendationReadFake(); let recommendations = model(sessions, fake)
                let owner = RecommendationOwner(); let task = try owner.start(recommendations)
                await fake.waitForRequest(0)
                if atAcceptance { await fake.finish(0, .success([recommendedSong(3)])); await task.value }
                let preview = recommendations.preview; let scope = recommendations.scope
                if change == 2 { await sessions.clear() }
                else { await sessions.replaceSession(accountID: change == 0 ? String(repeating: "b", count: 64) : key,
                    cookieHeader: "fixture=2", sapisid: "fixture-new") }
                if let preview { #expect(!(await recommendations.accept(previewID: preview.id, selectedIDs: [recommendedSong(3).id], expectedScope: scope))) }
                else { await fake.finish(0, .success([recommendedSong(3)])); await task.value }
                #expect(recommendations.preview == nil && owner.appends == 0)
            }
        }
    }

    @Test func cancellationAndOutOfOrderCompletionsCannotReviveAnOldPreview() async throws {
        let sessions = await session(); let fake = RecommendationReadFake(); let recommendations = model(sessions, fake)
        let owner = RecommendationOwner(); let first = try owner.start(recommendations)
        await fake.waitForRequest(0); recommendations.cancel()
        let second = try owner.start(recommendations)
        await finish(second, fake: fake, offered: [recommendedSong(4)], index: 1)
        let preview = try #require(recommendations.preview)
        await fake.finish(0, .success([recommendedSong(3)])); await first.value
        #expect(recommendations.preview?.id == preview.id && recommendations.preview?.tracks == [recommendedSong(4)])
        #expect(owner.appends == 0 && recommendations.errorMessage == nil && !recommendations.isLoading)
    }

    @Test func failedReadsRequireAnExplicitRetryAndSelectionsStayWithinTheImmutablePreview() async throws {
        let sessions = await session(); let fake = RecommendationReadFake(); let recommendations = model(sessions, fake)
        let owner = RecommendationOwner(); let task = try owner.start(recommendations)
        await fake.waitForRequest(0); await fake.finish(0, .failure(RecommendationReadFake.Failure.unavailable)); await task.value
        #expect(recommendations.canRetry && recommendations.errorMessage != nil && owner.appends == 0)
        #expect(await fake.requests.count == 1)
        let retry = try #require(recommendations.retry())
        await finish(retry, fake: fake, offered: [recommendedSong(3)], index: 1)
        let preview = try #require(recommendations.preview)
        #expect(!(await recommendations.accept(previewID: preview.id, selectedIDs: [recommendedSong(4).id], expectedScope: recommendations.scope)))
        #expect(!(await recommendations.accept(previewID: preview.id, selectedIDs: [], expectedScope: recommendations.scope)))
        #expect(owner.appends == 0 && recommendations.preview?.id == preview.id)
        let seeds = await fake.requests.map(\.0)
        #expect(seeds == [recommendedSong(1).id, recommendedSong(1).id])
    }

    @Test func anIntentChangeDuringAcceptanceAndConcurrentAcceptanceCannotAppendTwice() async throws {
        for changesIntent in [false, true] {
            let sessions = await session(); let gate = GatedRecommendationSessions(store: sessions)
            let fake = RecommendationReadFake(); let recommendations = model(gate, fake)
            let owner = RecommendationOwner(); let task = try owner.start(recommendations)
            await finish(task, fake: fake, offered: [recommendedSong(3)])
            let preview = try #require(recommendations.preview); let scope = recommendations.scope
            await gate.pause()
            let accepting = Task { await recommendations.accept(previewID: preview.id, selectedIDs: [recommendedSong(3).id], expectedScope: scope) }
            await gate.waitForPause()
            #expect(!(await recommendations.accept(previewID: preview.id, selectedIDs: [recommendedSong(3).id], expectedScope: scope)))
            if changesIntent { owner.intent = UUID() }
            await gate.release()
            #expect(await accepting.value == !changesIntent)
            #expect(owner.appends == (changesIntent ? 0 : 1))
            #expect(recommendations.preview == nil && !recommendations.isAccepting)
        }
    }

    @Test func signedOutOrUnconfirmedSessionsCannotRequestRecommendations() async throws {
        for accountKey in [nil, "unconfirmed"] as [String?] {
            let sessions = MusicSessionStore()
            if let accountKey { await sessions.replaceSession(accountID: accountKey, cookieHeader: "fixture=1", sapisid: "fixture") }
            let fake = RecommendationReadFake(); let recommendations = model(sessions, fake)
            let owner = RecommendationOwner(); let task = try owner.start(recommendations)
            await task.value
            #expect(await fake.requests.isEmpty)
            #expect(recommendations.preview == nil && !recommendations.isLoading && owner.appends == 0)
        }
    }

    @Test func isolatedNativeSessionStaysOffAndExplicitIntentsInvalidatePendingWork() async throws {
        let preferences = SceneCheckPreferences(); defer { preferences.remove() }
        let transport = SceneCheckTransport()
        let session = AppSession(configuration: .sceneCheck(preferences: preferences.defaults, transport: transport))
        session.queue.replace(with: [recommendedSong(1), recommendedSong(2)])
        let original = session.queue.snapshot()
        #expect(!session.canPreviewRecommendations)
        session.previewQueueRecommendations()
        #expect(!session.recommendations.isLoading && session.recommendations.preview == nil)
        for change in 0..<4 {
            let captured = session.recommendationContext
            let pending = session.recommendations.start(seed: recommendedSong(1), queue: session.queue, context: captured,
                isCurrent: { session.recommendationContext == captured }, append: { _ in Issue.record("An isolated session cannot append recommendations.") })
            #expect(session.recommendations.isLoading)
            switch change {
            case 0: session.pause()
            case 1: session.queue.append([recommendedSong(3)])
            case 2: session.accountGeneration = UUID()
            default: session.seek(to: 0)
            }
            #expect(!session.recommendations.isLoading && session.recommendations.preview == nil)
            await pending?.value
            if change == 0 { #expect(session.queue.snapshot() == original) }
        }
        #expect(await transport.attempts == 0)
        await session.shutdown()
    }

    @Test func frenchRecommendationCopyKeepsServiceTitlesVerbatim() throws {
        let url = try #require(AppLocalization.bundle.url(forResource: "fr", withExtension: "lproj"))
        let french = try #require(Bundle(url: url))
        #expect(french.localizedString(forKey: "Add Selected to Queue End", value: nil, table: "Localizable") == "Ajouter la sélection à la fin de la file")
        let title = "A %@ %lld مقطوعة"
        let format = french.localizedString(forKey: "Based on %@", value: nil, table: "Localizable")
        #expect(String(format: format, locale: Locale(identifier: "fr"), arguments: [title]).contains(title))
    }
}
