import Foundation
import MusicCore
import Observation
import YouTubeMusic

struct NamedQueueSaveIdentity: Sendable {
    let scope: UUID
    let account: String
}

/// Account-bound local saved queues. The verified WebSession account hash is
/// used as-is; a credentials scope or a display name is never used as identity.
@MainActor @Observable
final class NamedQueueLibrary {
    private(set) var queues: [NamedQueue] = []
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var scope = UUID()
    @ObservationIgnored private let store: NamedQueueStore?
    @ObservationIgnored let profileOperations = ProfileOperationFence()
    @ObservationIgnored private let sessions: any MusicSessionProviding

    init(store: NamedQueueStore?, sessions: any MusicSessionProviding) {
        self.store = store
        self.sessions = sessions
    }

    func invalidate() {
        scope = UUID()
        queues = []
        errorMessage = nil
        isWorking = false
    }

    func refresh(expectedScope: UUID? = nil) async {
        let request = expectedScope ?? scope
        do { queues = try await perform(expectedScope: expectedScope) { try await $0.list(accountKey: $1) } }
        catch { report(error, request: request) }
    }

    func save(name: String, snapshot: QueueSnapshot, expectedScope: UUID? = nil,
              expectedSession: NamedQueueSaveIdentity? = nil,
              isCurrent: @MainActor () -> Bool = { true }) async -> Bool {
        let request = expectedScope ?? scope
        do {
            queues = try await perform(expectedScope: expectedScope, expectedSession: expectedSession, isCurrent: isCurrent) { store, account in
                try await store.save(name: name, snapshot: snapshot, accountKey: account)
                return try await store.list(accountKey: account)
            }
            return true
        } catch { report(error, request: request); return false }
    }

    func rename(id: UUID, name: String, expectedScope: UUID? = nil) async -> Bool {
        let request = expectedScope ?? scope
        do {
            queues = try await perform(expectedScope: expectedScope) { store, account in
                try await store.rename(id: id, name: name, accountKey: account)
                return try await store.list(accountKey: account)
            }
            return true
        } catch { report(error, request: request); return false }
    }

    func remove(id: UUID, expectedScope: UUID? = nil) async -> Bool {
        let request = expectedScope ?? scope
        do {
            queues = try await perform(expectedScope: expectedScope) { store, account in
                try await store.remove(id: id, accountKey: account)
                return try await store.list(accountKey: account)
            }
            return true
        } catch { report(error, request: request); return false }
    }

    func snapshot(id: UUID, expectedScope: UUID? = nil) async -> QueueSnapshot? {
        let request = expectedScope ?? scope
        do { return try await perform(expectedScope: expectedScope) { try await $0.snapshot(id: id, accountKey: $1) } }
        catch { report(error, request: request); return nil }
    }

    func importQueue(from url: URL, expectedScope: UUID) async -> Bool {
        let request = expectedScope
        do {
            queues = try await perform(expectedScope: expectedScope) { store, account in
                try await store.importQueue(from: url, accountKey: account)
                return try await store.list(accountKey: account)
            }
            return true
        } catch { report(error, request: request); return false }
    }

    func exportQueue(id: UUID, to url: URL, expectedScope: UUID) async -> Bool {
        do {
            try await perform(expectedScope: expectedScope) { store, account in
                try await store.exportQueue(id: id, to: url, accountKey: account)
            }
            return true
        } catch { report(error, request: expectedScope); return false }
    }

    private func perform<Value: Sendable>(
        expectedScope: UUID? = nil,
        expectedSession: NamedQueueSaveIdentity? = nil,
        isCurrent: @MainActor () -> Bool = { true },
        _ operation: @Sendable (NamedQueueStore, String) async throws -> Value
    ) async throws -> Value {
        guard profileOperations.begin() else { throw SavedQueueAccessError.accountChanged }
        defer { profileOperations.end() }
        guard expectedScope == nil || expectedScope == scope else { throw SavedQueueAccessError.accountChanged }
        guard isCurrent() else { throw SavedQueueAccessError.accountChanged }
        guard !isWorking else { throw SavedQueueAccessError.inProgress }
        guard let store else { throw SavedQueueAccessError.unavailable }
        let request = scope
        isWorking = true
        errorMessage = nil
        defer { if scope == request { isWorking = false } }
        let session = await sessions.snapshot()
        try Task.checkCancellation()
        guard scope == request, session.isAuthenticated, let key = session.accountID,
              NamedQueueStore.acceptsAccountKey(key) else { throw SavedQueueAccessError.signInRequired }
        guard isCurrent(), expectedSession.map({ $0.scope == session.scope && $0.account == key }) ?? true else {
            throw SavedQueueAccessError.accountChanged
        }
        // Admission captures this account's destination before hopping into the
        // store. Profile switching waits for accepted writes to finish here.
        let result = try await operation(store, key)
        try Task.checkCancellation()
        let current = await sessions.snapshot()
        guard scope == request, current.scope == session.scope, current.accountID == key,
              current.isAuthenticated else { throw SavedQueueAccessError.accountChanged }
        return result
    }

    private func report(_ error: any Error, request: UUID) {
        guard scope == request, !(error is CancellationError) else { return }
        if let access = error as? SavedQueueAccessError,
           access == .signInRequired || access == .accountChanged { queues = [] }
        switch error {
        case let error as NamedQueueError: errorMessage = error.localizedDescription
        case let error as NamedQueueExchangeError: errorMessage = error.localizedDescription
        case let error as QueuePersistenceError: errorMessage = error.localizedDescription
        case let error as SavedQueueAccessError: errorMessage = error.localizedDescription
        default: errorMessage = AppLocalization.text("Could not read or save these local queues. Existing files have been kept.")
        }
    }
}

enum SavedQueueAccessError: Error, Equatable, LocalizedError {
    case inProgress, unavailable, signInRequired, accountChanged
    var errorDescription: String? {
        switch self {
        case .inProgress: AppLocalization.text("Wait for the saved queue operation to finish.")
        case .unavailable: AppLocalization.text("Local saved queue storage is unavailable.")
        case .signInRequired: AppLocalization.text("Sign in to a confirmed account to use its local saved queues.")
        case .accountChanged: AppLocalization.text("The account changed. Open Saved Queues again.")
        }
    }
}
