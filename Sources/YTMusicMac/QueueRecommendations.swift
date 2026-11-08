import Foundation
import MusicCore
import Observation
import YouTubeMusic

struct QueueRecommendationContext: Equatable, Sendable {
    let account: UUID
    let revision: QueueRevision
    let currentEntryID: UUID?
    let occurrence: PlaybackOccurrence?
    let intent: UUID
    let wantsPlayback: Bool
    let repeatMode: RepeatMode

    func matches(_ queue: PlaybackQueue) -> Bool {
        revision == queue.revision && currentEntryID == queue.currentEntryID && occurrence == queue.currentOccurrence && repeatMode == queue.repeatMode
    }
}

struct QueueRecommendationPreview: Identifiable, Sendable {
    let id: UUID
    let seed: Track
    let tracks: [Track]
    let capturedAt: Date
    let context: QueueRecommendationContext
}

/// A single explicit radio read followed by a separate explicit, local append.
@MainActor @Observable
final class QueueRecommendations {
    static let previewLimit = 20
    static let inspectedLimit = 200
    static let queueLimit = 10_000
    private(set) var scope = UUID()
    private(set) var preview: QueueRecommendationPreview?
    private(set) var isLoading = false
    private(set) var isAccepting = false
    private(set) var errorMessage: String?
    private(set) var canRetry = false
    @ObservationIgnored private let sessions: any MusicSessionProviding
    @ObservationIgnored private let load: @Sendable (String, UUID) async throws -> [Track]
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var request: Request?

    private struct Request {
        let id = UUID()
        let seed: Track
        let context: QueueRecommendationContext
        let excludedIDs: Set<String>
        let maximum: Int
        let isCurrent: @MainActor () -> Bool
        let append: @MainActor ([Track]) -> Void
        var accountKey: String?
        var credentialScope: UUID?
    }

    init(sessions: any MusicSessionProviding, now: @escaping @Sendable () -> Date = Date.init,
         load: @escaping @Sendable (String, UUID) async throws -> [Track]) {
        self.sessions = sessions; self.now = now; self.load = load
    }

    static func supports(_ track: Track) -> Bool {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return track.contentKind == .song && track.episode == nil && track.origin != .upload &&
            track.id.utf8.count == 11 && track.id.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
            } && !title.isEmpty && title != track.id && !artist.isEmpty &&
            !["unknown artist", "artiste inconnu"].contains(artist.lowercased()) &&
            title.utf8.count <= 2_048 && artist.utf8.count <= 2_048 &&
            !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
            !artist.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    @discardableResult
    func start(seed: Track, queue: PlaybackQueue, context: QueueRecommendationContext,
               isCurrent: @escaping @MainActor () -> Bool,
               append: @escaping @MainActor ([Track]) -> Void) -> Task<Void, Never>? {
        cancel()
        guard Self.supports(seed), queue.currentTrack == seed, context.matches(queue), isCurrent(), queue.entries.count < Self.queueLimit else { return nil }
        let request = Request(seed: seed, context: context, excludedIDs: Set(queue.entries.map(\.track.id)),
            maximum: min(Self.previewLimit, Self.queueLimit - queue.entries.count), isCurrent: isCurrent, append: append)
        self.request = request
        return run(request.id)
    }

    @discardableResult
    func retry() -> Task<Void, Never>? {
        guard !isLoading, !isAccepting, canRetry, let request, request.isCurrent() else { return nil }
        return run(request.id)
    }

    func cancel() {
        task?.cancel(); task = nil; request = nil; preview = nil
        isLoading = false; isAccepting = false; canRetry = false; errorMessage = nil; scope = UUID()
    }

    /// Called by the native owner when its account, intent, occurrence or queue context changes.
    func discardIfStale() {
        if let request, !request.isCurrent() { cancel() }
    }

    func accept(previewID: UUID, selectedIDs: Set<String>, expectedScope: UUID) async -> Bool {
        discardIfStale()
        guard scope == expectedScope, !isLoading, !isAccepting, let preview, preview.id == previewID,
              let request, request.id == previewID, !selectedIDs.isEmpty,
              selectedIDs.isSubset(of: Set(preview.tracks.map(\.id))), request.isCurrent() else { return false }
        isAccepting = true
        defer { if scope == expectedScope { isAccepting = false } }
        do {
            try await fresh(request)
            guard scope == expectedScope, self.request?.id == request.id, !Task.isCancelled, request.isCurrent() else { return false }
            let selected = preview.tracks.filter { selectedIDs.contains($0.id) }
            guard !selected.isEmpty, selected.allSatisfy(Self.supports) else { return false }
            // Consume before calling the synchronous owner so repeated acceptance cannot append twice.
            self.request = nil; self.preview = nil; canRetry = false; errorMessage = nil
            request.append(selected)
            return true
        } catch {
            if scope == expectedScope { cancel() }
            return false
        }
    }

    private func run(_ id: UUID) -> Task<Void, Never> {
        isLoading = true; canRetry = false; preview = nil; errorMessage = nil
        let next = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.fetch(id)
        }
        task = next
        return next
    }

    private func fetch(_ id: UUID) async {
        do {
            guard var current = currentRequest(id) else { return }
            let session = await sessions.snapshot()
            guard session.isAuthenticated, let key = session.accountID, NamedQueueStore.acceptsAccountKey(key) else { throw MusicServiceError.signInRequired }
            guard currentRequest(id) != nil else { return }
            if current.accountKey == nil {
                current.accountKey = key; current.credentialScope = session.scope; request = current
            }
            try await fresh(current)
            let offered = try await load(current.seed.id, session.scope)
            try await fresh(current)
            guard currentRequest(id) != nil else { return }
            var seen = current.excludedIDs
            let tracks = offered.prefix(Self.inspectedLimit).filter { Self.supports($0) && seen.insert($0.id).inserted }
            preview = QueueRecommendationPreview(id: id, seed: current.seed, tracks: Array(tracks.prefix(current.maximum)),
                capturedAt: now(), context: current.context)
            isLoading = false; task = nil
        } catch {
            guard let current = currentRequest(id) else { return }
            isLoading = false; task = nil
            if error is CancellationError { cancel(); return }
            if (try? await fresh(current)) == nil { if request?.id == id { cancel() }; return }
            guard currentRequest(id) != nil else { return }
            errorMessage = AppLocalization.text("Recommendations could not be loaded. Retry reads the same song's radio; your queue is unchanged.")
            canRetry = true
        }
    }
    private func currentRequest(_ id: UUID) -> Request? {
        guard let request, request.id == id else { return nil }
        guard !Task.isCancelled, request.isCurrent() else { cancel(); return nil }
        return request
    }
    private func fresh(_ request: Request) async throws {
        let session = await sessions.snapshot()
        guard !Task.isCancelled, self.request?.id == request.id, request.isCurrent(), session.isAuthenticated,
              session.accountID == request.accountKey, session.scope == request.credentialScope else { throw MusicServiceError.sessionChanged }
    }
}
