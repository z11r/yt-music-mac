import Foundation
import MusicCore
import Observation
import YouTubeMusic

/// Explicit detail requests only. A new selection, account, profile boundary,
/// panel close or cancellation invalidates even an uncancellable response.
@MainActor @Observable
final class SongCreditsSession {
    enum State: Equatable {
        case idle, loading, unavailable
        case available([MusicSongCreditSection])
        case failed
    }

    private(set) var state: State = .idle
    private(set) var track: Track?
    @ObservationIgnored private let snapshot: @Sendable () async -> UUID
    @ObservationIgnored private let fetch: @Sendable (SongCreditsReference, UUID) async throws -> MusicSongCredits
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var ownerIsCurrent: (@MainActor () -> Bool)?
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(snapshot: @escaping @Sendable () async -> UUID,
         fetch: @escaping @Sendable (SongCreditsReference, UUID) async throws -> MusicSongCredits) {
        self.snapshot = snapshot; self.fetch = fetch
    }

    @discardableResult
    func open(track: Track, isCurrent: @escaping @MainActor () -> Bool) -> Bool {
        guard isCurrent(), track.isCatalogSong, let reference = track.creditsReference else { return false }
        clear()
        self.track = track
        ownerIsCurrent = isCurrent
        state = .loading
        let id = requestID
        task = Task { [weak self, snapshot, fetch] in
            let scope = await snapshot()
            guard let self, self.accepts(id) else { return }
            do {
                let credits = try await fetch(reference, scope)
                guard self.accepts(id) else { return }
                let currentScope = await snapshot()
                guard self.accepts(id), scope == currentScope else {
                    if self.requestID == id { self.clear() }
                    return
                }
                switch credits {
                case .unavailable: self.state = .unavailable
                case let .available(sections): self.state = .available(sections)
                }
            } catch {
                guard self.accepts(id) else { return }
                let currentScope = await snapshot()
                guard self.accepts(id), scope == currentScope else {
                    if self.requestID == id { self.clear() }
                    return
                }
                self.state = .failed
            }
        }
        return true
    }

    func retry() {
        guard let track, let ownerIsCurrent, ownerIsCurrent() else { clear(); return }
        open(track: track, isCurrent: ownerIsCurrent)
    }

    func cancel() {
        requestID = UUID(); task?.cancel(); task = nil
        // Retain the explicit selection so the user can retry the same reference.
        state = track == nil ? .idle : .failed
    }

    func clear() {
        requestID = UUID(); task?.cancel(); task = nil
        track = nil; ownerIsCurrent = nil; state = .idle
    }

    private func accepts(_ id: UUID) -> Bool {
        guard !Task.isCancelled, requestID == id else { return false }
        guard ownerIsCurrent?() == true else { clear(); return false }
        return true
    }
}
