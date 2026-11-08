import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

@Suite("Explicit native song credits requests") @MainActor
struct SongCreditsSessionTests {
    @Test func missingReferenceUploadsEpisodesAndStaleOwnersNeverFetch() async {
        let credits = SongCreditsSession(snapshot: { UUID() }, fetch: { _, _ in
            Issue.record("An ineligible selection must not fetch")
            return .unavailable
        })
        var missing = track("first"); missing.creditsReference = nil
        var upload = track("upload"); upload.origin = .upload
        var episode = track("episode"); episode.contentKind = .podcastEpisode
        for item in [missing, upload, episode] {
            let accepted = credits.open(track: item, isCurrent: { true })
            #expect(!accepted)
        }
        let accepted = credits.open(track: track("stale"), isCurrent: { false })
        #expect(!accepted)
        #expect(credits.state == .idle)
        #expect(credits.task == nil)
    }

    @Test func newestExplicitSongWinsEvenWhenThePreviousResponseIgnoresCancellation() async {
        let gate = CreditsGate()
        let credits = makeSession(gate)
        credits.open(track: track("first"), isCurrent: { true })
        let first = credits.task
        await gate.waitFor("MPTCfirst")
        credits.open(track: track("second"), isCurrent: { true })
        let second = credits.task
        await gate.waitFor("MPTCsecond")
        await gate.respond("MPTCsecond", with: .available([.init(title: "Role", text: "Second")]))
        await second?.value
        await gate.respond("MPTCfirst", with: .available([.init(title: "Wrong", text: "Stale")]))
        await first?.value
        #expect(credits.track?.id == "second")
        #expect(credits.state == .available([.init(title: "Role", text: "Second")]))
    }

    @Test func cancellationOffersExplicitRetryOfTheSameReferenceAndClearRemovesMetadata() async {
        let gate = CreditsGate()
        let credits = makeSession(gate)
        credits.open(track: track("same"), isCurrent: { true })
        let cancelled = credits.task
        await gate.waitFor("MPTCsame")
        credits.cancel()
        await gate.respond("MPTCsame", with: .available([.init(title: "Stale", text: "Cancelled")]))
        await cancelled?.value
        #expect(credits.state == .failed)
        #expect(credits.track?.id == "same")
        credits.retry()
        let retried = credits.task
        await gate.waitFor("MPTCsame", count: 2)
        await gate.respond("MPTCsame", with: .unavailable)
        await retried?.value
        #expect(credits.state == .unavailable)
        #expect(await gate.requests.map(\.0) == ["MPTCsame", "MPTCsame"])
        credits.clear()
        #expect(credits.state == .idle)
        #expect(credits.track == nil)
    }

    @Test func generationChangeBeforeScopeSnapshotPreventsTheRequest() async {
        let gate = CreditsScopeGate()
        let owner = CreditsOwner()
        let credits = SongCreditsSession(snapshot: { await gate.snapshot() }, fetch: { _, _ in
            Issue.record("The owner changed while capturing scope")
            return .unavailable
        })
        credits.open(track: track("first"), isCurrent: { owner.isCurrent })
        let pending = credits.task
        await gate.waitForSnapshot()
        owner.isCurrent = false
        await gate.release()
        await pending?.value
        #expect(credits.state == .idle)
    }

    @Test func changedActualScopeOrOwnerCannotPublishAnOldReply() async {
        for rotateScope in [true, false] {
            let gate = CreditsGate()
            let owner = CreditsOwner()
            let credits = makeSession(gate)
            credits.open(track: track("first"), isCurrent: { owner.isCurrent })
            let pending = credits.task
            await gate.waitFor("MPTCfirst")
            if rotateScope { await gate.rotate() }
            else { owner.isCurrent = false }
            await gate.respond("MPTCfirst", with: .available([.init(title: "Private", text: "Old")]))
            await pending?.value
            #expect(credits.state == .idle)
            #expect(credits.track == nil)
        }
    }

    @Test func failedRequestDoesNotExposeArbitraryErrorTextOrRetryAutomatically() async {
        struct PrivateError: LocalizedError { var errorDescription: String? { "Private response or credential" } }
        let scope = UUID()
        let probe = CreditsFailureProbe()
        let credits = SongCreditsSession(snapshot: { scope }, fetch: { _, _ in
            await probe.increment()
            throw PrivateError()
        })
        credits.open(track: track("first"), isCurrent: { true })
        await credits.task?.value
        #expect(credits.state == .failed)
        #expect(credits.track?.id == "first")
        #expect(await probe.count == 1)
    }

    @Test func internalDragPreservesReferenceAndPortableMetadataIsNotRequired() throws {
        let original = Track(id: "abcDEF12_-3", title: "Song", artist: "Artist", creditsReference: .init(browseID: "MPTCopaque"))
        let scope = UUID()
        let restored = try SongTransfer.decode(SongTransfer(tracks: [original, original], scope: scope).encoded())
        #expect(restored.tracks.map(\.creditsReference) == [original.creditsReference, original.creditsReference])
        #expect(restored.scope == scope)
    }

    @Test func nativeBoundaryRejectsOldGenerationAndShutdownWithoutChangingTheQueue() async throws {
        let suite = "SongCreditsSessionTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = AppSession(configuration: .sceneCheck(preferences: preferences, transport: SceneCheckTransport()))
        let generation = session.accountGeneration
        let before = session.queue.snapshot()
        #expect(!session.openSongCredits(track: track("song"), expectedAccountGeneration: UUID()))
        #expect(session.openSongCredits(track: track("song"), expectedAccountGeneration: generation))
        session.quiesceForProfileSwitch()
        #expect(session.credits.track == nil && session.credits.state == .idle)
        #expect(!session.openSongCredits(track: track("song"), expectedAccountGeneration: session.accountGeneration))
        await session.settleForProfileSwitch()
        session.resumePausedProfileOwnership()
        #expect(!session.openSongCredits(track: track("song"), expectedAccountGeneration: generation))
        #expect(session.openSongCredits(track: track("song"), expectedAccountGeneration: session.accountGeneration))
        session.accountGeneration = UUID()
        #expect(session.credits.track == nil)
        #expect(session.credits.state == .idle)
        #expect(session.queue.snapshot() == before)
        await session.shutdown()
        #expect(!session.openSongCredits(track: track("song"), expectedAccountGeneration: session.accountGeneration))
    }

    private func track(_ id: String) -> Track {
        .init(id: id, title: "Song", artist: "Artist", creditsReference: .init(browseID: "MPTC" + id))
    }
    private func makeSession(_ gate: CreditsGate) -> SongCreditsSession {
        .init(snapshot: { await gate.scope }, fetch: { try await gate.fetch($0, $1) })
    }
}

private actor CreditsGate {
    private(set) var scope = UUID()
    private(set) var requests: [(String, UUID)] = []
    private var replies: [String: CheckedContinuation<MusicSongCredits, any Error>] = [:]
    private var arrivals: [String: [(Int, CheckedContinuation<Void, Never>)]] = [:]
    func rotate() { scope = UUID() }
    func fetch(_ reference: SongCreditsReference, _ scope: UUID) async throws -> MusicSongCredits {
        let id = reference.browseID
        requests.append((id, scope))
        let count = requests.filter { $0.0 == id }.count
        let ready = arrivals[id, default: []].filter { $0.0 <= count }
        arrivals[id, default: []].removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
        return try await withCheckedThrowingContinuation { replies[id] = $0 }
    }
    func waitFor(_ id: String, count: Int = 1) async {
        if requests.filter({ $0.0 == id }).count >= count { return }
        await withCheckedContinuation { arrivals[id, default: []].append((count, $0)) }
    }
    func respond(_ id: String, with credits: MusicSongCredits) { replies.removeValue(forKey: id)?.resume(returning: credits) }
}

private actor CreditsScopeGate {
    private var reply: CheckedContinuation<UUID, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    func snapshot() async -> UUID {
        arrivals.forEach { $0.resume() }; arrivals.removeAll()
        return await withCheckedContinuation { reply = $0 }
    }
    func waitForSnapshot() async {
        if reply != nil { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func release() { reply?.resume(returning: UUID()); reply = nil }
}

private actor CreditsFailureProbe {
    private(set) var count = 0
    func increment() { count += 1 }
}

@MainActor private final class CreditsOwner {
    var isCurrent = true
}
