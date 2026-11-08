import Foundation
import MusicCore
import Observation
import YouTubeMusic

enum CollectionPlaybackAction: Equatable, Sendable {
    case play, shuffle, append
}

/// Loads every remaining page before committing a queue operation. Failed reads
/// retain their cursor and accumulated pages; cancellation discards the operation.
@MainActor @Observable
final class CollectionPlayback {
    private(set) var isLoading = false
    private(set) var loadedTrackCount = 0
    private(set) var errorMessage: String?
    private(set) var canRetry = false

    @ObservationIgnored private let loadNext: @Sendable (MusicContinuation) async throws -> MusicPage
    @ObservationIgnored private let maximumPages: Int
    @ObservationIgnored private let maximumTracks: Int
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var task: Task<Void, Never>?

    private struct Request {
        let id = UUID()
        let action: CollectionPlaybackAction
        var page: MusicPage
        var pageCount = 1
        let isCurrent: @MainActor () -> Bool
        let commit: @MainActor (MusicPage, CollectionPlaybackAction) -> Void
    }

    private enum LoadError: LocalizedError {
        case tooManySongs, noSongs

        var errorDescription: String? {
            switch self {
            case .tooManySongs: "This collection is too large to queue at once. Select a smaller group of loaded songs."
            case .noSongs: "This collection has no playable songs."
            }
        }
    }

    init(maximumPages: Int = 100, maximumTracks: Int = 10_000,
         loadNext: @escaping @Sendable (MusicContinuation) async throws -> MusicPage) {
        precondition(maximumPages > 0 && maximumTracks > 0)
        self.maximumPages = maximumPages
        self.maximumTracks = maximumTracks
        self.loadNext = loadNext
    }

    @discardableResult
    func start(page: MusicPage, action: CollectionPlaybackAction,
               isCurrent: @escaping @MainActor () -> Bool,
               commit: @escaping @MainActor (MusicPage, CollectionPlaybackAction) -> Void) -> Task<Void, Never> {
        cancel()
        let request = Request(action: action, page: Self.normalized(page), isCurrent: isCurrent, commit: commit)
        self.request = request
        loadedTrackCount = request.page.tracks.count
        return run(request.id)
    }

    @discardableResult
    func retry() -> Task<Void, Never>? {
        guard canRetry, let request, !isLoading else { return nil }
        return run(request.id)
    }

    func cancel() {
        task?.cancel()
        task = nil
        request = nil
        isLoading = false
        loadedTrackCount = 0
        errorMessage = nil
        canRetry = false
    }

    private func run(_ id: UUID) -> Task<Void, Never> {
        isLoading = true
        errorMessage = nil
        canRetry = false
        let nextTask = Task { [weak self] in
            guard let self else { return }
            await self.load(id)
        }
        task = nextTask
        return nextTask
    }

    private func load(_ id: UUID) async {
        do {
            while let current = currentRequest(id) {
                guard current.page.tracks.count <= maximumTracks else { throw LoadError.tooManySongs }
                guard let continuation = current.page.continuation else {
                    guard !current.page.tracks.isEmpty else { throw LoadError.noSongs }
                    request = nil
                    task = nil
                    isLoading = false
                    current.commit(current.page, current.action)
                    return
                }
                guard current.pageCount < maximumPages else { throw MusicServiceError.pageLimitReached }
                let next = try await loadNext(continuation)
                guard var updated = currentRequest(id) else { return }
                updated.page = Self.append(next, to: updated.page)
                updated.pageCount += 1
                request = updated
                loadedTrackCount = updated.page.tracks.count
            }
        } catch {
            guard let current = currentRequest(id) else { return }
            if error is CancellationError { cancel(); return }
            isLoading = false
            task = nil
            errorMessage = error.localizedDescription
            let serviceError = error as? MusicServiceError
            canRetry = !(error is LoadError) && serviceError != .pageLimitReached &&
                serviceError != .paginationLoop && serviceError != .sessionChanged
            if !canRetry { request = nil }
            else { request = current }
        }
    }

    private func currentRequest(_ id: UUID) -> Request? {
        guard let request, request.id == id else { return nil }
        guard !Task.isCancelled, request.isCurrent() else {
            cancel()
            return nil
        }
        return request
    }

    private static func normalized(_ page: MusicPage) -> MusicPage {
        MusicPage(title: page.title, sections: page.sections,
                  items: page.items.isEmpty ? page.sections.flatMap(\.items) : page.items,
                  continuation: page.continuation, playlistItems: page.playlistItems,
                  playlistCapabilities: page.playlistCapabilities, likeStates: page.likeStates, ratings: page.ratings)
    }

    private static func append(_ next: MusicPage, to previous: MusicPage) -> MusicPage {
        let next = normalized(next)
        return MusicPage(title: previous.title, sections: previous.sections + next.sections,
                         items: previous.items + next.items, continuation: next.continuation,
                         playlistItems: previous.playlistItems + next.playlistItems,
                         playlistCapabilities: previous.playlistCapabilities,
                         likeStates: previous.likeStates.merging(next.likeStates) { _, new in new },
                         ratings: previous.ratings.merging(next.ratings) { _, new in new })
    }
}
