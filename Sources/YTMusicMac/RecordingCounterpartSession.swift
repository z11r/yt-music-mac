import Foundation
import MusicCore
import Observation
import YouTubeMusic

struct RecordingCounterpartTarget: Equatable {
    let profile: UUID
    let account: UUID
    let queueRevision: QueueRevision
    let entry: UUID
    let occurrence: PlaybackOccurrence
    let track: Track

    var isValid: Bool {
        track.isServiceTrack && track.origin != .upload && track.contentKind == .song &&
        Self.isVideoID(track.id) && entry == occurrence.entryID && track.id == occurrence.trackID
    }
    static func isVideoID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

struct RecordingCounterpartOwner: Equatable {
    let target: RecordingCounterpartTarget
    let credentialScope: UUID
}

struct RecordingCounterpartReview: Equatable, Identifiable {
    let id: UUID
    let owner: RecordingCounterpartOwner
    let pair: MusicRecordingCounterpart
    let createdAt: Date
}

/// One read across profile owners; cancellation never frees an unsettled slot.
@MainActor @Observable final class RecordingCounterpartReadAdmission {
    static let shared = RecordingCounterpartReadAdmission()
    private(set) var isBusy = false
    @ObservationIgnored private var ticket: UUID?
    func reserve() -> UUID? {
        guard !isBusy else { return nil }
        let value = UUID(); ticket = value; isBusy = true; return value
    }
    func release(_ value: UUID) {
        guard ticket == value else { return }
        ticket = nil; isBusy = false
    }
}

@MainActor @Observable final class RecordingCounterpartSession {
    enum State: Equatable {
        case idle, loading, unavailable, failed, canceled, expired
        case available(RecordingCounterpartReview), confirming(RecordingCounterpartReview)
    }
    private var target: RecordingCounterpartTarget?
    private var storedState: State = .idle
    @ObservationIgnored private let operations: ProfileOperationFence
    @ObservationIgnored private let admission: RecordingCounterpartReadAdmission
    @ObservationIgnored private let snapshot: @Sendable () async -> MusicSession
    @ObservationIgnored private let fetch: @Sendable (String, UUID) async throws -> MusicRecordingCounterpartResult
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var ownerIsCurrent: ((RecordingCounterpartTarget) -> Bool)?
    @ObservationIgnored private var accept: ((RecordingCounterpartOwner, Track) -> Bool)?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var confirmation: Task<Void, Never>?
    @ObservationIgnored private var confirmationID: UUID?

    var isBusy: Bool { admission.isBusy || confirmation != nil }
    var isPresented: Bool { target.map { ownerIsCurrent?($0) == true } == true }
    var state: State { isPresented ? storedState : .idle }

    init(operations: ProfileOperationFence, admission: RecordingCounterpartReadAdmission? = nil,
         snapshot: @escaping @Sendable () async -> MusicSession,
         fetch: @escaping @Sendable (String, UUID) async throws -> MusicRecordingCounterpartResult,
         now: @escaping () -> Date = Date.init) {
        self.operations = operations; self.admission = admission ?? .shared
        self.snapshot = snapshot; self.fetch = fetch; self.now = now
    }

    @discardableResult func open(_ target: RecordingCounterpartTarget,
        isCurrent: @escaping (RecordingCounterpartTarget) -> Bool,
        accept: @escaping (RecordingCounterpartOwner, Track) -> Bool) -> Bool {
        guard target.isValid, isCurrent(target), confirmation == nil, let ticket = admission.reserve() else { return false }
        requestID = UUID(); let id = requestID
        self.target = target; ownerIsCurrent = isCurrent; self.accept = accept; storedState = .loading
        task = Task { [weak self, snapshot, fetch, admission, operations] in
            defer { self?.task = nil; admission.release(ticket) }
            guard let self, self.accepts(id) else { return }
            guard operations.begin() else { self.clear(); return }
            defer { operations.end() }
            let original = await snapshot()
            guard self.accepts(id) else { return }
            guard original.isAuthenticated else { self.clear(); return }
            let owner = RecordingCounterpartOwner(target: target, credentialScope: original.scope)
            do {
                let result = try await fetch(target.track.id, original.scope)
                guard self.accepts(id) else { return }
                let current = await snapshot()
                guard self.accepts(id) else { return }
                guard current.isAuthenticated, current.scope == owner.credentialScope else { self.clear(); return }
                switch result {
                case .unavailable: self.storedState = .unavailable
                case let .available(pair):
                    guard pair.primaryVideoID == target.track.id, pair.primaryKind != pair.kind,
                          pair.track.isServiceTrack, pair.track.origin == .catalog, pair.track.contentKind == .song,
                          RecordingCounterpartTarget.isVideoID(pair.track.id), pair.track.id != target.track.id else {
                        self.storedState = .failed; return
                    }
                    self.storedState = .available(.init(id: UUID(), owner: owner, pair: pair, createdAt: self.now()))
                }
            } catch {
                guard self.accepts(id) else { return }
                let current = await snapshot()
                guard self.accepts(id) else { return }
                guard current.isAuthenticated, current.scope == owner.credentialScope else { self.clear(); return }
                self.storedState = .failed
            }
        }
        return true
    }

    /// Admission means a confirmation was started, never that playback is audible.
    @discardableResult func confirm(_ reviewID: UUID) -> Bool {
        guard case let .available(review) = state, review.id == reviewID, !isBusy else { return false }
        guard isFresh(review) else { storedState = .expired; return false }
        let id = requestID, confirmationID = UUID()
        self.confirmationID = confirmationID; storedState = .confirming(review)
        confirmation = Task { [weak self, snapshot] in
            defer {
                if let self, self.confirmationID == confirmationID { self.confirmation = nil; self.confirmationID = nil }
            }
            guard let self, self.accepts(id) else { return }
            let current = await snapshot()
            guard self.accepts(id) else { return }
            guard current.isAuthenticated, current.scope == review.owner.credentialScope else { self.clear(); return }
            guard self.isFresh(review) else { self.storedState = .expired; return }
            guard let action = self.accept else { self.clear(); return }
            // Revoke this exact review before a synchronous queue action can reenter.
            self.requestID = UUID(); self.target = nil; self.ownerIsCurrent = nil; self.accept = nil; self.storedState = .idle
            self.confirmation = nil; self.confirmationID = nil
            _ = action(review.owner, review.pair.track)
        }
        return true
    }
    func retry() {
        guard let target, let ownerIsCurrent, let accept, ownerIsCurrent(target) else { clear(); return }
        _ = open(target, isCurrent: ownerIsCurrent, accept: accept)
    }
    func cancel() { requestID = UUID(); task?.cancel(); confirmation?.cancel(); storedState = .canceled }
    func clear() {
        requestID = UUID(); task?.cancel(); confirmation?.cancel()
        target = nil; ownerIsCurrent = nil; accept = nil; storedState = .idle
    }
    func discardIfStale() { if let target, ownerIsCurrent?(target) != true { clear() } }
    func waitForIdle() async {
        let read = task, confirmed = confirmation
        await read?.value; await confirmed?.value
    }
    private func accepts(_ id: UUID) -> Bool {
        !Task.isCancelled && requestID == id && target.map { ownerIsCurrent?($0) == true } == true
    }
    private func isFresh(_ review: RecordingCounterpartReview) -> Bool {
        let age = now().timeIntervalSince(review.createdAt)
        return age.isFinite && (0...300).contains(age)
    }
}

enum RecordingCounterpartText {
    static func text(_ key: StaticString) -> String {
        AppLocalization.bundle.localizedString(forKey: String(describing: key), value: nil, table: "RecordingCounterpart")
    }
}
