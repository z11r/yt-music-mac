import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@MainActor @Suite("Episode persistence privacy and in-flight progress")
struct EpisodePersistencePrivacyTests {
    @Test(arguments: [false, true])
    func queuedDetachCannotAcquireNewPermissionAfterOffOnWhilePriorWriteIsHeld(usesOriginalPermission: Bool) async throws {
        let gate = LocalPersistenceGate()
        let store = HeldPermissionEpisodeStore(gate: gate)
        let session: EpisodePlaybackSession
        if usesOriginalPermission {
            // Production storage receives the admitted token through every wait.
            session = EpisodePlaybackSession(load: { _ in nil }, saveWithPermission: { snapshot, permission in
                try await store.save(snapshot, permission: permission)
            }, saveDelay: .zero, persistenceGate: gate)
        } else {
            // Preserve the reproduction's original late-capturing injected closure.
            session = EpisodePlaybackSession(load: { _ in nil }, save: { snapshot in
                let permission = gate.token
                try await store.save(snapshot, permission: permission)
            }, saveDelay: .zero, persistenceGate: gate)
        }
        session.bindAccount(accountHash); await session.waitUntilLoaded()
        let occurrence = occurrence()
        session.begin(track: episodeTrack, occurrence: occurrence)
        session.record(occurrence: occurrence, position: 10, duration: 600, confirmedContent: true)
        await store.waitForFirstAttempt()
        let detached = try #require(session.detachAccount())
        session.setPersistenceEnabled(false)
        session.setPersistenceEnabled(true)
        var flushStarted = false, flushFinished = false
        let waitingFlush = Task {
            flushStarted = true
            _ = await session.flush()
            flushFinished = true
        }
        while !flushStarted { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(!flushFinished)
        await store.releaseFirstAttempt()
        #expect(!(await detached.value))
        #expect(await store.writes.isEmpty)
        #expect(await store.attempts == 1)
        await waitingFlush.value
        #expect(flushFinished)
    }

    @Test(arguments: [false, true])
    func profileQuiesceFlushWaitsDetachedWriteWithoutAnActiveAccount(changesAccount: Bool) async throws {
        let gate = LocalPersistenceGate()
        let store = HeldPermissionEpisodeStore(gate: gate)
        let session = EpisodePlaybackSession(load: { _ in nil }, saveWithPermission: { snapshot, permission in
            try await store.save(snapshot, permission: permission)
        }, saveDelay: .seconds(60), persistenceGate: gate)
        session.bindAccount(accountHash); await session.waitUntilLoaded()
        let occurrence = occurrence()
        session.begin(track: episodeTrack, occurrence: occurrence)
        session.record(occurrence: occurrence, position: 10, duration: 600, confirmedContent: true)
        let detached = try #require(session.detachAccount())
        await store.waitForFirstAttempt()
        #expect(!session.isLoading)
        session.suspendProfileOwnership()
        var settlingStarted = false, replacementCanActivate = false
        let settling = Task {
            settlingStarted = true
            let flushed = await session.flush()
            replacementCanActivate = true
            return flushed
        }
        while !settlingStarted { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(!replacementCanActivate)
        if changesAccount { session.bindAccount(String(repeating: "b", count: 64)) }
        await store.releaseFirstAttempt()
        #expect(await detached.value)
        #expect(!(await settling.value))
        await session.waitUntilLoaded()
        #expect(replacementCanActivate)
        #expect(await store.attempts == 1)
        #expect(await store.writes.map(\.accountHash) == [accountHash])
    }

    @Test func confirmedProgressDuringReenableLoadSurvivesMergeAndIsTheNextSavedPosition() async throws {
        let reader = HeldEpisodeReload()
        let writer = MemoryEpisodeWrites()
        let session = EpisodePlaybackSession(load: { await reader.load($0) }, save: { await writer.save($0) },
            now: { Date(timeIntervalSince1970: 1_000) }, saveDelay: .seconds(60))
        session.setPersistenceEnabled(false)
        session.bindAccount(accountHash)
        let occurrence = occurrence()
        session.begin(track: episodeTrack, occurrence: occurrence)
        session.record(occurrence: occurrence, position: 10, duration: 600, confirmedContent: true)
        session.setPersistenceEnabled(true)
        await reader.waitForRequest()
        session.record(occurrence: occurrence, position: 20, duration: 600, confirmedContent: true)
        #expect(session.resumePosition(for: episodeTrack) == 20)
        #expect(await writer.writes.isEmpty)
        let saved = EpisodeProgressSnapshot(accountHash: accountHash, records: [
            .init(episode: episodeTrack.episode!.identity, position: 5, duration: 600, completed: false,
                  updatedAt: Date(timeIntervalSince1970: 900))
        ])
        await reader.finish(saved)
        await session.waitUntilLoaded()
        #expect(session.resumePosition(for: episodeTrack) == 20)
        #expect(await session.flush())
        #expect(await writer.writes.last?.records.first?.position == 20)
    }
}

private let accountHash = String(repeating: "a", count: 64)
private let episodeTrack = Track(id: "abcDEF12_-3", title: "Episode", artist: "Show", duration: 600,
    contentKind: .podcastEpisode, episode: .init(identity: .init(browseID: "MPEDprivacy")))
private func occurrence() -> PlaybackOccurrence {
    .init(sessionID: UUID(), entryID: UUID(), trackID: episodeTrack.id, generation: 1)
}
private actor HeldPermissionEpisodeStore {
    let gate: LocalPersistenceGate
    private var first: CheckedContinuation<Void, Never>?
    private(set) var attempts = 0
    private(set) var writes: [EpisodeProgressSnapshot] = []
    init(gate: LocalPersistenceGate) { self.gate = gate }
    func save(_ snapshot: EpisodeProgressSnapshot, permission: UUID) async throws {
        attempts += 1
        if attempts == 1 { await withCheckedContinuation { first = $0 } }
        guard gate.accepts(permission) else { throw CancellationError() }
        writes.append(snapshot)
    }
    func waitForFirstAttempt() async { while first == nil { await Task.yield() } }
    func releaseFirstAttempt() { let pending = first; first = nil; pending?.resume() }
}
private actor HeldEpisodeReload {
    private var pending: CheckedContinuation<EpisodeProgressSnapshot?, Never>?
    func load(_ hash: String) async -> EpisodeProgressSnapshot? { await withCheckedContinuation { pending = $0 } }
    func waitForRequest() async { while pending == nil { await Task.yield() } }
    func finish(_ value: EpisodeProgressSnapshot?) { let continuation = pending; pending = nil; continuation?.resume(returning: value) }
}
private actor MemoryEpisodeWrites {
    private(set) var writes: [EpisodeProgressSnapshot] = []
    func save(_ snapshot: EpisodeProgressSnapshot) { writes.append(snapshot) }
}
