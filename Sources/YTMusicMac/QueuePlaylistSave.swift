import Foundation
import MusicCore
import Observation
import YouTubeMusic

protocol QueuePlaylistSavingService: Sendable {
    var supportsQueuePlaylistSave: Bool { get }
    func beginQueuePlaylistSave(expectedScope: UUID) async throws -> UUID
    func endQueuePlaylistSave(token: UUID) async
    func createQueuePlaylist(title: String, token: UUID, expectedScope: UUID) async throws -> String
    func appendQueuePlaylist(id: String, videoIDs: [String], token: UUID, expectedScope: UUID) async throws -> [QueuePlaylistOccurrence]
    func readQueuePlaylist(id: String, token: UUID, expectedScope: UUID) async throws -> QueuePlaylistReadback
}
extension YouTubeMusicClient: QueuePlaylistSavingService {
    nonisolated var supportsQueuePlaylistSave: Bool { libraryEditCapabilities.playlists }
}

struct QueuePlaylistReview: Identifiable, Sendable {
    let id: UUID
    let capturedAt: Date
    let songs: [QueuePlaylistPlan.Song]
}

private enum QueuePlaylistSaveError: Error, LocalizedError {
    case unavailable, accountChanged, stopped, unknownCreate, uncertainBatch, changedPlaylist
    var errorDescription: String? {
        switch self {
        case .unavailable: "Service playlist saving is not enabled in this build. Local saved queues remain available."
        case .accountChanged: "The confirmed account or session changed. The pending save has been kept for its original account."
        case .stopped: "Stopped after the current request. The playlist and pending save record have been kept."
        case .unknownCreate: "A playlist creation may already have succeeded, but no target was confirmed. Review YouTube Music manually before forgetting this record. Another playlist will not be created automatically."
        case .uncertainBatch: "The last song batch is not fully confirmed. Recheck later; it will not be resent while its outcome is uncertain."
        case .changedPlaylist: "The playlist's details, permissions, order or occurrences differ from this save. No further songs were written. Review the existing playlist manually."
        }
    }
}

@MainActor @Observable
final class QueuePlaylistSave {
    private(set) var scope = UUID()
    private(set) var review: QueuePlaylistReview?
    private(set) var pending: QueuePlaylistPending?
    private(set) var knownTargetID: String?
    private(set) var isWorking = false
    private(set) var isLoading = false
    private(set) var stopRequested = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    var canWrite: Bool { store != nil && service.supportsQueuePlaylistSave }
    @ObservationIgnored private let store: QueuePlaylistJournalStore?
    @ObservationIgnored private let service: any QueuePlaylistSavingService
    @ObservationIgnored private let sessions: any MusicSessionProviding
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var ownerKey: String?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<QueuePlaylistReadback, Error>?

    init(store: QueuePlaylistJournalStore?, service: any QueuePlaylistSavingService, sessions: any MusicSessionProviding,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.service = service; self.sessions = sessions; self.now = now
    }
    func invalidate() {
        readTask?.cancel()
        stopRequested = true; scope = UUID(); review = nil; pending = nil; knownTargetID = nil; ownerKey = nil
        errorMessage = nil; statusMessage = nil; isLoading = false
    }
    func cancel() {
        if isWorking || operationTask != nil {
            stopRequested = true; readTask?.cancel(); statusMessage = "Stopping after the current request…"
        }
    }

    func prepare(snapshot: QueueSnapshot, expectedScope: UUID) async {
        guard scope == expectedScope, !isWorking, operationTask == nil, !isLoading else { return }
        review = nil; pending = nil; knownTargetID = nil; ownerKey = nil; errorMessage = nil; statusMessage = nil; isLoading = true
        defer { if scope == expectedScope { isLoading = false } }
        do {
            guard let store else { throw QueuePlaylistSaveError.unavailable }
            let session = try await authenticated()
            guard scope == expectedScope, let key = session.accountID else { throw QueuePlaylistSaveError.accountChanged }
            let stored = try await store.load(accountKey: key)
            let current = try await authenticated()
            guard scope == expectedScope, current.scope == session.scope, current.accountID == key else { throw QueuePlaylistSaveError.accountChanged }
            ownerKey = key; pending = stored; knownTargetID = stored?.targetID
            if stored == nil { review = QueuePlaylistReview(id: UUID(), capturedAt: now(), songs: try QueuePlaylistPlan.reviewedSongs(snapshot)) }
        } catch { if scope == expectedScope { errorMessage = error.localizedDescription } }
    }

    func start(title: String, reviewID: UUID, expectedScope: UUID) async {
        guard scope == expectedScope, !isWorking, !isLoading, let review, review.id == reviewID, pending == nil else { return }
        do {
            let plan = try QueuePlaylistPlan(id: review.id, title: title, createdAt: review.capturedAt, songs: review.songs)
            await launch(expectedScope: expectedScope, newPlan: plan, recheckOnly: false)
        } catch { if scope == expectedScope { errorMessage = error.localizedDescription } }
    }
    func resume(operationID: UUID, expectedScope: UUID, recheckOnly: Bool = false) async {
        guard scope == expectedScope, !isWorking, !isLoading, pending?.plan.id == operationID else { return }
        await launch(expectedScope: expectedScope, newPlan: nil, recheckOnly: recheckOnly)
    }
    func waitForIdle() async { await operationTask?.value }

    private func launch(expectedScope: UUID, newPlan: QueuePlaylistPlan?, recheckOnly: Bool) async {
        guard operationTask == nil, !Task.isCancelled else { return }
        stopRequested = false
        let task = Task { await run(expectedScope: expectedScope, newPlan: newPlan, recheckOnly: recheckOnly) }
        operationTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { Task { @MainActor in self.cancel() } }
        operationTask = nil
    }

    func forget(operationID: UUID, revision: UUID, expectedScope: UUID) async {
        guard scope == expectedScope, !isWorking, operationTask == nil, !isLoading, pending?.plan.id == operationID, let store, let key = ownerKey else { return }
        isLoading = true
        var lease: QueuePlaylistJournalLease?
        do {
            let session = try await authenticated()
            guard scope == expectedScope, session.accountID == key else { throw QueuePlaylistSaveError.accountChanged }
            let acquired = try await store.acquire(accountKey: key); lease = acquired
            let current = try await authenticated()
            guard scope == expectedScope, current.scope == session.scope, current.accountID == key else { throw QueuePlaylistSaveError.accountChanged }
            try await store.forget(id: operationID, revision: revision, lease: acquired)
            if scope == expectedScope {
                pending = nil; review = nil; knownTargetID = nil; errorMessage = nil
                statusMessage = "Local record removed. Any service playlist remains. Close this review before starting another."
            }
        } catch { if scope == expectedScope { errorMessage = error.localizedDescription } }
        if let lease { await store.release(lease) }
        if scope == expectedScope { isLoading = false }
    }

    private func run(expectedScope: UUID, newPlan: QueuePlaylistPlan?, recheckOnly: Bool) async {
        guard scope == expectedScope, !isWorking else { return }
        guard canWrite, let store, let key = ownerKey else { errorMessage = QueuePlaylistSaveError.unavailable.localizedDescription; return }
        isWorking = true; errorMessage = nil; statusMessage = "Checking the reviewed save…"
        var fileLease: QueuePlaylistJournalLease?
        var serviceLease: UUID?
        do {
            let session = try await authenticated()
            guard scope == expectedScope, session.accountID == key else { throw QueuePlaylistSaveError.accountChanged }
            try await fresh(key: key, nonce: session.scope, expectedScope: expectedScope)
            let acquired = try await store.acquire(accountKey: key); fileLease = acquired
            try await fresh(key: key, nonce: session.scope, expectedScope: expectedScope)
            var record: QueuePlaylistPending
            if let newPlan { record = try await store.begin(newPlan, lease: acquired) }
            else {
                guard let stored = try await store.load(accountKey: key), stored.plan.id == pending?.plan.id else { throw QueuePlaylistJournalError.stale }
                record = stored
            }
            publish(record, expectedScope: expectedScope)
            if record.phase == .creating { throw QueuePlaylistSaveError.unknownCreate }
            if record.phase == .completed { statusMessage = "This save was already confirmed complete." }
            else {
                try await fresh(key: key, nonce: session.scope, expectedScope: expectedScope)
                let token = try await service.beginQueuePlaylistSave(expectedScope: session.scope); serviceLease = token
                if record.phase == .prepared {
                    if recheckOnly { throw QueuePlaylistSaveError.uncertainBatch }
                    try await fresh(key: key, nonce: session.scope, expectedScope: expectedScope)
                    var creating = record; creating.phase = .creating
                    record = try await save(creating, previous: record, lease: acquired, expectedScope: expectedScope)
                    do { try await fresh(key: key, nonce: session.scope, expectedScope: expectedScope) }
                    catch {
                        var unsent = record; unsent.phase = .prepared
                        record = try await save(unsent, previous: record, lease: acquired, expectedScope: expectedScope)
                        throw error
                    }
                    let id = try await service.createQueuePlaylist(title: record.plan.title, token: token, expectedScope: session.scope)
                    guard QueuePlaylistPlan.validPlaylistID(id) else { throw QueuePlaylistSaveError.unknownCreate }
                    if scope == expectedScope { knownTargetID = id }
                    var known = record; known.phase = .targetKnown; known.targetID = id
                    // Bookkeeping for a confirmed target belongs to its original account even after cancellation or an account change.
                    record = try await save(known, previous: record, lease: acquired, expectedScope: expectedScope)
                }
                if record.phase == .batchPending || recheckOnly {
                    record = try await reconcile(record, key: key, nonce: session.scope, token: token, lease: acquired, expectedScope: expectedScope)
                }
                if !recheckOnly {
                    while record.confirmed.count < record.plan.songs.count {
                        record = try await reconcile(record, key: key, nonce: session.scope, token: token, lease: acquired, expectedScope: expectedScope)
                        try await fresh(key: key, nonce: session.scope, expectedScope: expectedScope)
                        guard let target = record.targetID else { throw QueuePlaylistSaveError.unknownCreate }
                        let end = min(record.confirmed.count + 100, record.plan.songs.count)
                        let ids = record.plan.songs[record.confirmed.count..<end].map(\.videoID)
                        var attempted = record; attempted.phase = .batchPending; attempted.attemptedEnd = end
                        record = try await save(attempted, previous: record, lease: acquired, expectedScope: expectedScope)
                        do { try await fresh(key: key, nonce: session.scope, expectedScope: expectedScope) }
                        catch {
                            var unsent = record; unsent.phase = .targetKnown; unsent.attemptedEnd = nil
                            record = try await save(unsent, previous: record, lease: acquired, expectedScope: expectedScope)
                            throw error
                        }
                        let added = try await service.appendQueuePlaylist(id: target, videoIDs: ids, token: token, expectedScope: session.scope)
                        guard added.count == ids.count, added.map(\.videoID).sorted() == ids.sorted(), added.allSatisfy(QueuePlaylistPlan.validOccurrence),
                              Set((record.confirmed + added).map(\.setVideoID)).count == record.confirmed.count + added.count else { throw QueuePlaylistSaveError.uncertainBatch }
                        var acknowledged = record; acknowledged.acknowledged = added
                        record = try await save(acknowledged, previous: record, lease: acquired, expectedScope: expectedScope)
                        record = try await reconcile(record, key: key, nonce: session.scope, token: token, lease: acquired, expectedScope: expectedScope)
                    }
                }
                if scope == expectedScope { statusMessage = record.phase == .completed ? "All reviewed songs were confirmed in the private playlist." : "The exact saved prefix is confirmed. Continue only when ready to write the remaining songs." }
            }
        } catch { if scope == expectedScope { errorMessage = error.localizedDescription; statusMessage = nil } }
        if let serviceLease { await service.endQueuePlaylistSave(token: serviceLease) }
        if let fileLease { await store.release(fileLease) }
        isWorking = false
    }

    private func reconcile(_ record: QueuePlaylistPending, key: String, nonce: UUID, token: UUID, lease: QueuePlaylistJournalLease,
                           expectedScope: UUID) async throws -> QueuePlaylistPending {
        try await fresh(key: key, nonce: nonce, expectedScope: expectedScope)
        guard let target = record.targetID else { throw QueuePlaylistSaveError.unknownCreate }
        if scope == expectedScope { statusMessage = "Reading back the exact playlist order…" }
        let task = Task { try await service.readQueuePlaylist(id: target, token: token, expectedScope: nonce) }
        readTask = task
        defer { readTask = nil }
        let read = try await task.value
        try await fresh(key: key, nonce: nonce, expectedScope: expectedScope)
        let refs = read.occurrences
        guard read.targetID == target, read.title == record.plan.title, read.isPrivate, read.canAddItems,
              refs.count <= record.plan.songs.count, refs.allSatisfy(QueuePlaylistPlan.validOccurrence),
              Set(refs.map(\.setVideoID)).count == refs.count, Array(refs.prefix(record.confirmed.count)) == record.confirmed else {
            throw QueuePlaylistSaveError.changedPlaylist
        }
        if record.phase == .batchPending {
            guard let end = record.attemptedEnd else { throw QueuePlaylistJournalError.invalidJournal }
            guard refs.count == end else {
                if refs.count >= record.confirmed.count, refs.count < end,
                   refs.map(\.videoID) == record.plan.songs.prefix(refs.count).map(\.videoID) { throw QueuePlaylistSaveError.uncertainBatch }
                throw QueuePlaylistSaveError.changedPlaylist
            }
            guard refs.map(\.videoID) == record.plan.songs.prefix(end).map(\.videoID) else { throw QueuePlaylistSaveError.changedPlaylist }
            if let acknowledged = record.acknowledged {
                let tail = Array(refs.dropFirst(record.confirmed.count))
                guard tail.sorted(by: { $0.setVideoID < $1.setVideoID }) == acknowledged.sorted(by: { $0.setVideoID < $1.setVideoID }) else {
                    throw QueuePlaylistSaveError.changedPlaylist
                }
            }
            var verified = record; verified.confirmed = refs; verified.attemptedEnd = nil; verified.acknowledged = nil
            verified.phase = refs.count == record.plan.songs.count ? .completed : .targetKnown
            return try await save(verified, previous: record, lease: lease, expectedScope: expectedScope)
        }
        guard refs == record.confirmed else { throw QueuePlaylistSaveError.changedPlaylist }
        return record
    }
    private func authenticated() async throws -> MusicSession {
        let session = await sessions.snapshot()
        guard session.isAuthenticated, let key = session.accountID, NamedQueueStore.acceptsAccountKey(key) else { throw QueuePlaylistSaveError.accountChanged }
        return session
    }
    private func fresh(key: String, nonce: UUID, expectedScope: UUID) async throws {
        let session = try await authenticated()
        guard scope == expectedScope, session.accountID == key, session.scope == nonce else { throw QueuePlaylistSaveError.accountChanged }
        guard !stopRequested, !Task.isCancelled else { throw QueuePlaylistSaveError.stopped }
    }
    private func save(_ next: QueuePlaylistPending, previous: QueuePlaylistPending, lease: QueuePlaylistJournalLease,
                      expectedScope: UUID) async throws -> QueuePlaylistPending {
        guard let store else { throw QueuePlaylistSaveError.unavailable }
        let saved = try await store.update(next, expectedRevision: previous.revision, lease: lease)
        publish(saved, expectedScope: expectedScope)
        return saved
    }
    private func publish(_ record: QueuePlaylistPending, expectedScope: UUID) {
        if scope == expectedScope { pending = record; review = nil; knownTargetID = record.targetID ?? knownTargetID }
    }
}
