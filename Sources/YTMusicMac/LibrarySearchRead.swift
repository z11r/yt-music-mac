import Foundation
import YouTubeMusic

struct LibrarySearchOwner: Equatable {
    let generation: UUID
    let account: String
}

/// Captures one confirmed native owner and its actual credentials. Tests inject
/// snapshots and held reads; production always supplies the current WebSession.
@MainActor enum LibrarySearchRead {
    static func perform(owner: LibrarySearchOwner, operations: ProfileOperationFence, snapshot: () async -> MusicSession,
                        isCurrent: () -> Bool, load: (UUID) async throws -> MusicPage) async throws -> MusicPage {
        try Task.checkCancellation()
        guard isCurrent(), operations.begin() else { throw MusicServiceError.sessionChanged }
        defer { operations.end() }
        let original = await snapshot()
        try Task.checkCancellation()
        guard isCurrent() else { throw MusicServiceError.sessionChanged }
        guard original.isAuthenticated, original.accountID == owner.account else { throw MusicServiceError.signInRequired }
        let page = try await load(original.scope)
        try Task.checkCancellation()
        guard isCurrent() else { throw MusicServiceError.sessionChanged }
        let latest = await snapshot()
        try Task.checkCancellation()
        guard isCurrent(), latest.scope == original.scope, latest.accountID == original.accountID, latest.isAuthenticated else {
            throw MusicServiceError.sessionChanged
        }
        return page
    }
}

extension AppSession {
    var librarySearchOwner: LibrarySearchOwner? {
        guard acceptsProfileActions, hasFinishedStartup, let key = account.confirmedAccountKey else { return nil }
        return .init(generation: accountGeneration, account: key)
    }
}

extension MusicDestination {
    var isSearchDestination: Bool {
        switch self { case .search, .librarySearch: true; default: false }
    }
}
