import Foundation

public enum MusicLibraryCheckError: Error, Equatable, Sendable {
    case timedOut
}

/// Counts and fixed status codes only. No account, music, playlist, or continuation identifiers are returned.
public struct MusicLibraryCheck: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let surfaces: [MusicLibrarySurfaceCheck]

    public init(surfaces: [MusicLibrarySurfaceCheck]) {
        self.schemaVersion = 2
        self.surfaces = surfaces
    }
}

public struct MusicLibrarySurfaceCheck: Codable, Equatable, Sendable {
    public enum Surface: String, Codable, Sendable { case library, likedSongs, playlist }
    public enum Status: String, Codable, Sendable {
        case ok, notAvailable, signInRequired, authenticationRejected, accessDenied
        case networkFailure, rateLimited, serviceUnavailable, requestRejected, unsupportedResponse, invalidResponse, paginationLoop
    }
    public enum Pagination: String, Codable, Sendable { case notAvailable, checked, failed }

    public let surface: Surface
    public var status: Status
    public var pageCount = 0
    public var itemCount = 0
    public var trackCount = 0
    public var collectionCount = 0
    public var playlistOccurrenceCount = 0
    public var removableOccurrenceCount = 0
    public var continuationAvailable = false
    public var pagination: Pagination = .notAvailable
    /// HTTP status only; response bodies, headers, and request parameters are excluded.
    public var httpStatusCode: Int?
    /// Included only for an unsupported continuation response; contains allowlisted schema paths and counts.
    public var responseStructure: MusicResponseStructure?

    public init(surface: Surface, status: Status = .ok) {
        self.surface = surface
        self.status = status
    }

    mutating func include(_ page: MusicPage) {
        pageCount += 1
        itemCount += page.items.count
        trackCount += page.tracks.count
        collectionCount += page.items.filter { if case .collection = $0 { true } else { false } }.count
        playlistOccurrenceCount += page.playlistItems.count
        removableOccurrenceCount += page.playlistItems.filter { $0.removalReference != nil }.count
        continuationAvailable = page.continuation != nil
    }
}

extension YouTubeMusicClient {
    /// Reads a bounded number of pages from each surface, without changing playback, navigation, or the library.
    public func checkLibrary(maximumPages: Int = 25, timeout: Duration = .seconds(20)) async throws -> MusicLibraryCheck {
        guard (1...50).contains(maximumPages), timeout > .zero, timeout <= .seconds(25) else { throw MusicServiceError.invalidInput }
        return try await withThrowingTaskGroup(of: MusicLibraryCheck.self) { group in
            group.addTask { try await self.readLibraryCheck(maximumPages: maximumPages) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MusicLibraryCheckError.timedOut
            }
            defer { group.cancelAll() }
            guard let report = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return report
        }
    }

    private func readLibraryCheck(maximumPages: Int) async throws -> MusicLibraryCheck {
        let session = await sessions.snapshot()
        guard session.isAuthenticated else { throw MusicServiceError.signInRequired }
        let (library, playlistID) = try await inspectLibrarySurface(.library, scope: session.scope, maximumPages: maximumPages) {
            try await self.library()
        }
        let (liked, _) = try await inspectLibrarySurface(.likedSongs, scope: session.scope, maximumPages: maximumPages) {
            try await self.likedSongs()
        }
        let playlist: MusicLibrarySurfaceCheck
        if let playlistID {
            (playlist, _) = try await inspectLibrarySurface(.playlist, scope: session.scope, maximumPages: maximumPages) {
                try await self.playlist(id: playlistID)
            }
        } else {
            playlist = MusicLibrarySurfaceCheck(surface: .playlist, status: .notAvailable)
        }
        try await validateScope(session.scope)
        return MusicLibraryCheck(surfaces: [library, liked, playlist])
    }

    private func inspectLibrarySurface(_ surface: MusicLibrarySurfaceCheck.Surface, scope: UUID, maximumPages: Int,
                                       firstPage: () async throws -> MusicPage) async throws -> (MusicLibrarySurfaceCheck, String?) {
        var result = MusicLibrarySurfaceCheck(surface: surface)
        var playlistID: String?
        do {
            try await validateScope(scope)
            var page = try await firstPage()
            try await validateScope(scope)
            playlistID = Self.firstPlaylistID(in: page)
            result.include(page)
            while let continuation = page.continuation, result.pageCount < maximumPages {
                try Task.checkCancellation()
                result.pagination = .failed
                let inspection = try await inspectNextPage(continuation)
                try await validateScope(scope)
                guard case let .page(next) = inspection else {
                    if case let .unsupported(structure) = inspection { result.responseStructure = structure }
                    result.status = .unsupportedResponse
                    return (result, playlistID)
                }
                result.include(next)
                page = next
                playlistID = playlistID ?? Self.firstPlaylistID(in: next)
                result.pagination = .checked
            }
        } catch {
            try await validateScope(scope)
            if error is CancellationError { throw error }
            result.status = Self.libraryCheckStatus(error)
            if let serviceError = error as? MusicServiceError,
               case let .httpStatus(code) = serviceError, (100...599).contains(code) {
                result.httpStatusCode = code
            }
        }
        return (result, playlistID)
    }

    private static func firstPlaylistID(in page: MusicPage) -> String? {
        page.items.compactMap { item -> String? in
            guard case let .collection(value) = item, value.kind == .playlist,
                  value.id != "LM", value.id != "VLLM" else { return nil }
            return value.id
        }.first
    }

    private static func libraryCheckStatus(_ error: any Error) -> MusicLibrarySurfaceCheck.Status {
        switch error as? MusicServiceError {
        case .signInRequired: .signInRequired
        case .authenticationRejected: .authenticationRejected
        case .accessDenied: .accessDenied
        case .network: .networkFailure
        case .rateLimited: .rateLimited
        case .serviceUnavailable: .serviceUnavailable
        case let .httpStatus(code): (500...599).contains(code) ? .serviceUnavailable : .requestRejected
        case .unsupportedResponse: .unsupportedResponse
        case .paginationLoop: .paginationLoop
        default: .invalidResponse
        }
    }
}
