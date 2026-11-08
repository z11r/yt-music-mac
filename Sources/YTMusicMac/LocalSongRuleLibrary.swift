import Foundation
import MusicCore
import Observation
import YouTubeMusic

struct LocalSongSourceIdentity: Sendable {
    fileprivate let scope: UUID
    fileprivate let accountScope: UUID
    fileprivate let accountKey: String
}

@MainActor @Observable
final class LocalSongRuleLibrary {
    private(set) var archive = LocalSongRuleArchive()
    private(set) var evaluation = LocalSongRuleEvaluation(rule: nil, snapshot: nil)
    private(set) var selectedID: UUID?
    private(set) var scope = UUID()
    private(set) var revision = UUID()
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    var selectedRule: LocalSongRule? { archive.rules.first { $0.id == selectedID } }
    @ObservationIgnored private let store: LocalSongRuleStore?
    @ObservationIgnored let profileOperations = ProfileOperationFence()
    @ObservationIgnored private let sessions: any MusicSessionProviding
    @ObservationIgnored private var archiveAccountKey: String?

    init(store: LocalSongRuleStore?, sessions: any MusicSessionProviding) { self.store = store; self.sessions = sessions }

    func invalidate() {
        scope = UUID(); revision = UUID(); selectedID = nil; archiveAccountKey = nil
        archive = LocalSongRuleArchive(); evaluation = LocalSongRuleEvaluation(rule: nil, snapshot: nil)
        isWorking = false; errorMessage = nil
    }

    func select(_ id: UUID?, expectedScope: UUID) {
        guard scope == expectedScope, id == nil || archive.rules.contains(where: { $0.id == id }) else { return }
        selectedID = id
        recompute()
    }

    func refresh(expectedScope: UUID) async {
        await update(expectedScope: expectedScope) { try await $0.load(accountKey: $1) }
    }

    func save(_ rule: LocalSongRule, expectedScope: UUID) async {
        if await update(expectedScope: expectedScope, { try await $0.save(rule, accountKey: $1) }), scope == expectedScope {
            if selectedID != rule.id { selectedID = rule.id; recompute() }
        }
    }

    func remove(id: UUID, expectedScope: UUID) async {
        await update(expectedScope: expectedScope) { try await $0.remove(id: id, accountKey: $1) }
    }

    func clearSnapshot(expectedScope: UUID) async {
        await update(expectedScope: expectedScope) { try await $0.clearSnapshot(accountKey: $1) }
    }

    func reportSourceUnavailable(expectedScope: UUID) {
        guard scope == expectedScope else { return }
        errorMessage = AppLocalization.text("Reload a music page with songs before capturing a snapshot.")
    }

    /// A page keeps the verified account identity from before its network request began.
    func beginSource() async -> LocalSongSourceIdentity? {
        guard store != nil else { return nil }
        let request = scope
        let session = await sessions.snapshot()
        guard scope == request, session.isAuthenticated, let key = session.accountID,
              NamedQueueStore.acceptsAccountKey(key), !Task.isCancelled else { return nil }
        return LocalSongSourceIdentity(scope: request, accountScope: session.scope, accountKey: key)
    }

    func capture(tracks: [Track], sourceName: String, hasMorePages: Bool, wasLoading: Bool, unavailableCount: Int,
                 hasUnsupportedContent: Bool, source: LocalSongSourceIdentity, expectedScope: UUID) async {
        guard source.scope == expectedScope else { return }
        await update(expectedScope: expectedScope, source: source) {
            try await $0.capture(tracks: tracks, sourceName: sourceName, hasMorePages: hasMorePages, wasLoading: wasLoading,
                                 unavailableCount: unavailableCount, hasUnsupportedContent: hasUnsupportedContent, accountKey: $1)
        }
    }

    /// A stale selection cannot borrow another account's current matches or refresh a superseded result set.
    func actionTracks(selectedIDs: Set<UUID>?, expectedScope: UUID, expectedRevision: UUID) async -> [Track]? {
        guard scope == expectedScope, revision == expectedRevision, !Task.isCancelled else { return nil }
        let session = await sessions.snapshot()
        guard scope == expectedScope, revision == expectedRevision, !Task.isCancelled, session.isAuthenticated,
              session.accountID == archiveAccountKey, archiveAccountKey != nil else { return nil }
        return evaluation.matches.filter { selectedIDs?.contains($0.id) ?? true }.map(\.track)
    }

    @discardableResult private func update(expectedScope: UUID, source: LocalSongSourceIdentity? = nil,
        _ action: @Sendable (LocalSongRuleStore, String) async throws -> LocalSongRuleArchive) async -> Bool {
        guard profileOperations.begin() else { return false }
        defer { profileOperations.end() }
        guard scope == expectedScope, !isWorking else { return false }
        guard let store else { errorMessage = AppLocalization.text("Local song-rule storage is unavailable."); return false }
        isWorking = true; errorMessage = nil
        defer { if scope == expectedScope { isWorking = false } }
        do {
            let session = await sessions.snapshot()
            guard scope == expectedScope, session.isAuthenticated, let key = session.accountID,
                  NamedQueueStore.acceptsAccountKey(key) else { throw AccessError.signInRequired }
            if let source {
                guard source.scope == scope, source.accountScope == session.scope, source.accountKey == key else { throw AccessError.sourceChanged }
            }
            try Task.checkCancellation()
            let result = try await action(store, key)
            let current = await sessions.snapshot()
            guard scope == expectedScope, current.scope == session.scope, current.accountID == key,
                  current.isAuthenticated else { throw AccessError.accountChanged }
            try Task.checkCancellation()
            archive = result; archiveAccountKey = key
            if selectedID != nil && selectedRule == nil { selectedID = nil }
            recompute()
            return true
        } catch {
            guard scope == expectedScope, !(error is CancellationError) else { return false }
            if error is AccessError {
                archive = LocalSongRuleArchive(); archiveAccountKey = nil; selectedID = nil; recompute()
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func recompute() {
        revision = UUID()
        evaluation = LocalSongRuleEvaluation(rule: selectedRule, snapshot: archive.snapshot)
    }

    private enum AccessError: Error, LocalizedError {
        case signInRequired, accountChanged, sourceChanged
        var errorDescription: String? {
            switch self {
            case .signInRequired: AppLocalization.text("Sign in to a confirmed account to use its local song rules.")
            case .accountChanged: AppLocalization.text("The account changed. Open Local Song Rules again.")
            case .sourceChanged: AppLocalization.text("The page's account or session changed. Reload the music page before capturing its songs.")
            }
        }
    }
}
