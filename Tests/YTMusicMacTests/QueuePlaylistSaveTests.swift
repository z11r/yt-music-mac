import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

private struct QueueSaveFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QueuePlaylistSaveTests-" + UUID().uuidString)
    let key = String(repeating: "a", count: 64)
    let other = String(repeating: "b", count: 64)
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func snapshot(_ count: Int = 201) -> QueueSnapshot {
        var queue = PlaybackQueue()
        queue.append((0..<count).map { Track(id: $0.isMultiple(of: 2) ? "abcDEF12_-3" : "xyzABC34_-5", title: "Song \($0)", artist: "Artist") })
        return queue.snapshot()
    }
    @MainActor func flow(store: QueuePlaylistJournalStore, service: FakeQueuePlaylistService, sessions: MusicSessionStore) -> QueuePlaylistSave {
        QueuePlaylistSave(store: store, service: service, sessions: sessions)
    }
}

private actor FakeQueuePlaylistService: QueuePlaylistSavingService {
    enum Loss: Sendable { case none, applied, unapplied, partial }
    enum Pause: Sendable { case create, append, read }
    enum Corruption: Sendable { case none, title, privacy, permission, occurrence, extra }
    nonisolated let supportsQueuePlaylistSave: Bool
    private let sessions: MusicSessionStore
    private let journal: QueuePlaylistJournalStore
    private let key: String
    private var lease: (UUID, UUID)?
    private var title = ""
    private var refs: [QueuePlaylistOccurrence] = []
    private var loss: Loss = .none
    private var losesCreate = false
    private var pause: Pause?
    private var paused: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var corruptRead: (Int, Corruption)?
    private var deferred: [String] = []
    private var serial = 0
    private(set) var creates = 0
    private(set) var batches: [[String]] = []
    private(set) var reads = 0
    private(set) var phasesAtWrites: [QueuePlaylistPending.Phase] = []
    private(set) var ended = 0
    init(sessions: MusicSessionStore, journal: QueuePlaylistJournalStore, key: String, enabled: Bool = true) {
        self.sessions = sessions; self.journal = journal; self.key = key; supportsQueuePlaylistSave = enabled
    }
    func setLoss(_ value: Loss) { loss = value }
    func loseCreation() { losesCreate = true }
    func pauseNext(_ value: Pause) { pause = value }
    func corrupt(onRead: Int, _ value: Corruption) { corruptRead = (onRead, value) }
    func waitForPause() async { if paused == nil { await withCheckedContinuation { observer = $0 } } }
    func releasePause() { paused?.resume(); paused = nil }
    func completeDeferredBatch() { append(deferred); deferred = [] }
    func occurrences() -> [QueuePlaylistOccurrence] { refs }
    func beginQueuePlaylistSave(expectedScope: UUID) async throws -> UUID {
        guard supportsQueuePlaylistSave else { throw MusicLibraryEditError.featureUnavailable }
        guard lease == nil else { throw MusicLibraryEditError.operationInProgress }
        let token = UUID(); lease = (token, expectedScope)
        try await check(token, expectedScope)
        return token
    }
    func endQueuePlaylistSave(token: UUID) { if lease?.0 == token { lease = nil; ended += 1 } }
    func createQueuePlaylist(title: String, token: UUID, expectedScope: UUID) async throws -> String {
        try await check(token, expectedScope)
        if let phase = try await journal.load(accountKey: key)?.phase { phasesAtWrites.append(phase) }
        creates += 1; self.title = title
        await gate(.create)
        if losesCreate { losesCreate = false; throw MusicLibraryEditError.unconfirmedOutcome }
        return "PLsaved"
    }
    func appendQueuePlaylist(id: String, videoIDs: [String], token: UUID, expectedScope: UUID) async throws -> [QueuePlaylistOccurrence] {
        try await check(token, expectedScope)
        if let phase = try await journal.load(accountKey: key)?.phase { phasesAtWrites.append(phase) }
        batches.append(videoIDs)
        await gate(.append)
        let currentLoss = loss; loss = .none
        if currentLoss == .unapplied { throw MusicLibraryEditError.unconfirmedOutcome }
        if currentLoss == .partial {
            let count = max(1, videoIDs.count / 2); append(Array(videoIDs.prefix(count))); deferred = Array(videoIDs.dropFirst(count))
            throw MusicLibraryEditError.unconfirmedOutcome
        }
        let previous = refs.count; append(videoIDs)
        if currentLoss == .applied { throw MusicLibraryEditError.unconfirmedOutcome }
        return Array(refs.dropFirst(previous))
    }
    func readQueuePlaylist(id: String, token: UUID, expectedScope: UUID) async throws -> QueuePlaylistReadback {
        await gate(.read)
        try await check(token, expectedScope)
        reads += 1
        var privateValue = true; var permission = true; var actualTitle = title
        if let (count, corruption) = corruptRead, count == reads {
            switch corruption {
            case .none: break
            case .title: actualTitle = "Manually renamed"
            case .privacy: privateValue = false
            case .permission: permission = false
            case .occurrence:
                if let first = refs.first { refs[0] = QueuePlaylistOccurrence(videoID: first.videoID, setVideoID: "manually-replaced=") }
            case .extra: append(["xyzABC34_-5"])
            }
        }
        return QueuePlaylistReadback(targetID: id, title: actualTitle, isPrivate: privateValue, canAddItems: permission, occurrences: refs)
    }
    private func append(_ ids: [String]) {
        for id in ids { serial += 1; refs.append(QueuePlaylistOccurrence(videoID: id, setVideoID: "occurrence-\(serial)=")) }
    }
    private func check(_ token: UUID, _ scope: UUID) async throws {
        try Task.checkCancellation()
        let current = await sessions.snapshot()
        guard lease?.0 == token, lease?.1 == scope, current.scope == scope, current.isAuthenticated else { throw MusicServiceError.sessionChanged }
    }
    private func gate(_ point: Pause) async {
        if pause == point {
            pause = nil
            await withCheckedContinuation { paused = $0; observer?.resume(); observer = nil }
        }
    }
}

@MainActor @Suite("Reviewed queue playlist saves", .serialized)
struct QueuePlaylistSaveTests {
    private func session(_ fixture: QueueSaveFixture) async -> MusicSessionStore {
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.key, cookieHeader: "fixture=1", sapisid: "fixture")
        return sessions
    }
    private func start(_ flow: QueuePlaylistSave, snapshot: QueueSnapshot) async throws {
        await flow.prepare(snapshot: snapshot, expectedScope: flow.scope)
        let review = try #require(flow.review)
        await flow.start(title: "Reviewed queue", reviewID: review.id, expectedScope: flow.scope)
    }

    @Test func privateCreationAndBoundedBatchesKeepTheReviewedOrderAndDuplicates() async throws {
        let fixture = QueueSaveFixture(); defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory)
        let sessions = await session(fixture)
        let service = FakeQueuePlaylistService(sessions: sessions, journal: store, key: fixture.key)
        let flow = fixture.flow(store: store, service: service, sessions: sessions)
        let snapshot = fixture.snapshot()
        try await start(flow, snapshot: snapshot)
        #expect(flow.pending?.phase == .completed && flow.pending?.confirmed.count == 201 && flow.errorMessage == nil)
        #expect(await service.occurrences().map(\.videoID) == snapshot.entries.map(\.track.id))
        #expect(await service.batches.map(\.count) == [100, 100, 1])
        #expect(await service.creates == 1)
        #expect(await service.phasesAtWrites == [.creating, .batchPending, .batchPending, .batchPending])
        #expect(try await store.load(accountKey: fixture.key)?.phase == .completed)
        #expect(await service.ended == 1)
    }

    @Test func anUnknownCreationBlocksAnotherCreateAcrossRelaunch() async throws {
        let fixture = QueueSaveFixture(); defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory)
        let sessions = await session(fixture)
        let service = FakeQueuePlaylistService(sessions: sessions, journal: store, key: fixture.key)
        await service.loseCreation()
        let flow = fixture.flow(store: store, service: service, sessions: sessions)
        try await start(flow, snapshot: fixture.snapshot(3))
        #expect(flow.pending?.phase == .creating && flow.pending?.targetID == nil && flow.errorMessage != nil)
        let recovered = fixture.flow(store: store, service: service, sessions: sessions)
        await recovered.prepare(snapshot: fixture.snapshot(1), expectedScope: recovered.scope)
        let pending = try #require(recovered.pending)
        #expect(recovered.review == nil && pending.plan.songs.count == 3)
        await recovered.resume(operationID: pending.plan.id, expectedScope: recovered.scope)
        #expect(await service.creates == 1)
        #expect(await service.batches.isEmpty)
        #expect(recovered.pending?.phase == .creating)
    }

    @Test func aKnownTargetThatCannotBeDurablyRecordedStillBlocksDuplicateCreation() async throws {
        let fixture = QueueSaveFixture(); defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let songs = try QueuePlaylistPlan.reviewedSongs(fixture.snapshot(3))
        let plan = try QueuePlaylistPlan(title: "Reviewed queue", createdAt: date, songs: songs)
        let initial = QueuePlaylistPending(plan: plan, now: date)
        var creating = initial; creating.phase = .creating
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let limit = max(try encoder.encode(initial).count, try encoder.encode(creating).count)
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory, maximumBytes: limit, now: { date })
        let sessions = await session(fixture)
        let service = FakeQueuePlaylistService(sessions: sessions, journal: store, key: fixture.key)
        let flow = QueuePlaylistSave(store: store, service: service, sessions: sessions, now: { date })
        await flow.prepare(snapshot: QueueSnapshot(entries: songs.map {
            QueueEntry(id: $0.id, track: Track(id: $0.videoID, title: $0.title, artist: $0.artist))
        }), expectedScope: flow.scope)
        let review = try #require(flow.review)
        await flow.start(title: plan.title, reviewID: review.id, expectedScope: flow.scope)
        #expect(flow.pending?.phase == .creating && flow.knownTargetID == "PLsaved" && flow.errorMessage != nil)
        #expect(try await store.load(accountKey: fixture.key)?.phase == .creating)
        let recovered = fixture.flow(store: store, service: service, sessions: sessions)
        await recovered.prepare(snapshot: fixture.snapshot(1), expectedScope: recovered.scope)
        let id = try #require(recovered.pending?.plan.id)
        await recovered.resume(operationID: id, expectedScope: recovered.scope)
        #expect(await service.creates == 1)
        #expect(await service.batches.isEmpty)
    }

    @Test func anAppliedLostBatchIsReconciledBeforeOnlyTheRemainingSongsAreWritten() async throws {
        let fixture = QueueSaveFixture(); defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory)
        let sessions = await session(fixture)
        let service = FakeQueuePlaylistService(sessions: sessions, journal: store, key: fixture.key)
        await service.setLoss(.applied)
        let flow = fixture.flow(store: store, service: service, sessions: sessions)
        let snapshot = fixture.snapshot()
        try await start(flow, snapshot: snapshot)
        #expect(flow.pending?.phase == .batchPending && flow.pending?.confirmed.count == 0)
        #expect(await service.occurrences().count == 100)
        let recovered = fixture.flow(store: store, service: service, sessions: sessions)
        await recovered.prepare(snapshot: fixture.snapshot(1), expectedScope: recovered.scope)
        let id = try #require(recovered.pending?.plan.id)
        await recovered.resume(operationID: id, expectedScope: recovered.scope)
        #expect(recovered.pending?.phase == .completed && recovered.pending?.confirmed.count == 201)
        #expect(await service.creates == 1)
        #expect(await service.batches.map(\.count) == [100, 100, 1])
        #expect(await service.occurrences().map(\.videoID) == snapshot.entries.map(\.track.id))
    }

    @Test func anUnappliedUncertainBatchIsNeverBlindlyResent() async throws {
        let fixture = QueueSaveFixture(); defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory)
        let sessions = await session(fixture)
        let service = FakeQueuePlaylistService(sessions: sessions, journal: store, key: fixture.key)
        await service.setLoss(.unapplied)
        let flow = fixture.flow(store: store, service: service, sessions: sessions)
        try await start(flow, snapshot: fixture.snapshot())
        let id = try #require(flow.pending?.plan.id)
        await flow.resume(operationID: id, expectedScope: flow.scope, recheckOnly: true)
        await flow.resume(operationID: id, expectedScope: flow.scope)
        #expect(await service.creates == 1)
        #expect(await service.batches.count == 1)
        #expect(await service.occurrences().isEmpty)
        #expect(flow.pending?.phase == .batchPending && flow.errorMessage != nil)
    }

    @Test func partialBatchesStayBlockedUntilTheEntireOriginalAttemptIsObserved() async throws {
        let fixture = QueueSaveFixture(); defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory)
        let sessions = await session(fixture)
        let service = FakeQueuePlaylistService(sessions: sessions, journal: store, key: fixture.key)
        await service.setLoss(.partial)
        let flow = fixture.flow(store: store, service: service, sessions: sessions)
        try await start(flow, snapshot: fixture.snapshot())
        let id = try #require(flow.pending?.plan.id)
        await flow.resume(operationID: id, expectedScope: flow.scope)
        #expect(await service.batches.count == 1)
        #expect(await service.occurrences().count == 50)
        await service.completeDeferredBatch()
        await flow.resume(operationID: id, expectedScope: flow.scope)
        #expect(flow.pending?.phase == .completed)
        #expect(await service.batches.map(\.count) == [100, 100, 1])
        #expect(await service.occurrences().count == 201)
    }

    @Test func freshReadbackRejectsManualOccurrenceAndMetadataChangesBeforeAnotherWrite() async throws {
        for corruption in [FakeQueuePlaylistService.Corruption.occurrence, .title, .privacy, .permission, .extra] {
            let fixture = QueueSaveFixture(); defer { fixture.remove() }
            let store = QueuePlaylistJournalStore(directoryURL: fixture.directory)
            let sessions = await session(fixture)
            let service = FakeQueuePlaylistService(sessions: sessions, journal: store, key: fixture.key)
            await service.corrupt(onRead: 3, corruption)
            let flow = fixture.flow(store: store, service: service, sessions: sessions)
            try await start(flow, snapshot: fixture.snapshot())
            #expect(await service.batches.count == 1)
            #expect(flow.pending?.phase == .targetKnown && flow.pending?.confirmed.count == 100 && flow.errorMessage != nil)
        }
    }

    @Test func cancellationDuringCreateKeepsTheKnownTargetAndNeverDeletesOrAppends() async throws {
        let fixture = QueueSaveFixture(); defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory)
        let sessions = await session(fixture)
        let service = FakeQueuePlaylistService(sessions: sessions, journal: store, key: fixture.key)
        await service.pauseNext(.create)
        let flow = fixture.flow(store: store, service: service, sessions: sessions)
        let task = Task { try await start(flow, snapshot: fixture.snapshot(3)) }
        await service.waitForPause()
        flow.cancel()
        await service.releasePause()
        try await task.value
        #expect(flow.pending?.phase == .targetKnown && flow.pending?.targetID == "PLsaved")
        #expect(await service.creates == 1)
        #expect(await service.batches.isEmpty)
        #expect(try await store.load(accountKey: fixture.key)?.targetID == "PLsaved")
    }

    @Test func accountChangeDuringCreateKeepsBookkeepingOnlyInTheOriginalNamespace() async throws {
        let fixture = QueueSaveFixture(); defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory)
        let sessions = await session(fixture)
        let service = FakeQueuePlaylistService(sessions: sessions, journal: store, key: fixture.key)
        await service.pauseNext(.create)
        let flow = fixture.flow(store: store, service: service, sessions: sessions)
        let task = Task { try await start(flow, snapshot: fixture.snapshot(3)) }
        await service.waitForPause()
        flow.invalidate()
        await sessions.replaceSession(accountID: fixture.other, cookieHeader: "fixture=2", sapisid: "fixture")
        await service.releasePause(); try await task.value
        #expect(flow.pending == nil && flow.review == nil && flow.knownTargetID == nil)
        #expect(try await store.load(accountKey: fixture.key)?.targetID == "PLsaved")
        #expect(try await store.load(accountKey: fixture.other) == nil)
        #expect(await service.batches.isEmpty)
    }

    @Test func cancellationDuringABatchPersistsTheAcknowledgementForReadOnlyRecovery() async throws {
        let fixture = QueueSaveFixture(); defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory)
        let sessions = await session(fixture)
        let service = FakeQueuePlaylistService(sessions: sessions, journal: store, key: fixture.key)
        await service.pauseNext(.append)
        let flow = fixture.flow(store: store, service: service, sessions: sessions)
        let task = Task { try await start(flow, snapshot: fixture.snapshot()) }
        await service.waitForPause(); flow.cancel(); await service.releasePause(); try await task.value
        #expect(flow.pending?.phase == .batchPending && flow.pending?.acknowledged?.count == 100)
        let id = try #require(flow.pending?.plan.id)
        await flow.resume(operationID: id, expectedScope: flow.scope, recheckOnly: true)
        #expect(flow.pending?.phase == .targetKnown && flow.pending?.confirmed.count == 100)
        #expect(await service.batches.count == 1)
    }

    @Test func cancellationDuringReadbackKeepsTheKnownTargetAndPreventsAppending() async throws {
        let fixture = QueueSaveFixture(); defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory)
        let sessions = await session(fixture)
        let service = FakeQueuePlaylistService(sessions: sessions, journal: store, key: fixture.key)
        await service.pauseNext(.read)
        let flow = fixture.flow(store: store, service: service, sessions: sessions)
        let task = Task { try await start(flow, snapshot: fixture.snapshot(3)) }
        await service.waitForPause(); flow.cancel(); await service.releasePause(); try await task.value
        #expect(flow.pending?.phase == .targetKnown && flow.pending?.targetID == "PLsaved")
        #expect(await service.creates == 1)
        #expect(await service.reads == 0)
        #expect(await service.batches.isEmpty)
        #expect(await service.ended == 1)
        let record = try #require(flow.pending)
        await flow.resume(operationID: record.plan.id, expectedScope: flow.scope)
        #expect(flow.pending?.phase == .completed && flow.pending?.confirmed.count == 3)
        #expect(await service.creates == 1)
        #expect(await service.batches.count == 1)
    }

    @Test func disabledWritesAndStaleReviewsNeverCreateAJournalOrServicePlaylist() async throws {
        let fixture = QueueSaveFixture(); defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory)
        let sessions = await session(fixture)
        let service = FakeQueuePlaylistService(sessions: sessions, journal: store, key: fixture.key, enabled: false)
        let flow = fixture.flow(store: store, service: service, sessions: sessions)
        try await start(flow, snapshot: fixture.snapshot(3))
        #expect(!flow.canWrite && flow.pending == nil && flow.errorMessage != nil)
        #expect(await service.creates == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        let review = try #require(flow.review)
        let oldScope = flow.scope
        flow.invalidate()
        await flow.start(title: "Stale", reviewID: review.id, expectedScope: oldScope)
        #expect(await service.creates == 0)
    }

    @Test func explicitForgetOnlyRemovesTheLocalRecordAndReleasesTheFileLease() async throws {
        let fixture = QueueSaveFixture(); defer { fixture.remove() }
        let store = QueuePlaylistJournalStore(directoryURL: fixture.directory)
        let sessions = await session(fixture)
        let service = FakeQueuePlaylistService(sessions: sessions, journal: store, key: fixture.key)
        let flow = fixture.flow(store: store, service: service, sessions: sessions)
        try await start(flow, snapshot: fixture.snapshot(3))
        let record = try #require(flow.pending)
        await flow.forget(operationID: record.plan.id, revision: record.revision, expectedScope: flow.scope)
        #expect(flow.pending == nil && flow.review == nil)
        #expect(try await store.load(accountKey: fixture.key) == nil)
        #expect(await service.occurrences().count == 3)
        let lease = try await store.acquire(accountKey: fixture.key); await store.release(lease)
    }
}
