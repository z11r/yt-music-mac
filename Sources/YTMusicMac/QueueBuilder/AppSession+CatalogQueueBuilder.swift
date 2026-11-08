import Foundation
import MusicCore
import YouTubeMusic

extension AppSession {
    var catalogQueueOwner: CatalogQueueOwner? {
        guard acceptsProfileActions, hasFinishedStartup, isSceneCheck || links.isReady else { return nil }
        return .init(account: accountGeneration, startup: links.generation, queue: queue.revision)
    }
    func makeCatalogQueueBuilder() -> CatalogQueueBuilder {
        CatalogQueueBuilder(sessions: account.credentials, slot: .shared,
            owner: { [weak self] in self?.catalogQueueOwner },
            load: { [weak self] query, scope, owner in
                guard let self else { throw CancellationError() }
                return try await self.readCatalogQueue(query: query, scope: scope, owner: owner)
            },
            commit: { [weak self] owner, identity, tracks, name in
                await self?.commitCatalogQueue(owner: owner, identity: identity, tracks: tracks, name: name) ?? false
            })
    }
    func readCatalogQueue(query: String, scope: UUID, owner: CatalogQueueOwner) async throws -> MusicPage {
        try Task.checkCancellation()
        guard catalogQueueOwner == owner else { throw MusicServiceError.sessionChanged }
        return try await client.search(query: query, filter: .songs, expectedScope: scope)
    }
    func commitCatalogQueue(owner: CatalogQueueOwner, identity: CatalogQueueIdentity, tracks: [Track], name: String?) async -> Bool {
        guard catalogQueueOwner == owner, (1...50).contains(tracks.count),
              tracks.allSatisfy(QueueRecommendations.supports), Set(tracks.map(\.id)).count == tracks.count else { return false }
        let current = CatalogQueueIdentity(await account.credentials.snapshot())
        guard !Task.isCancelled, current == identity, catalogQueueOwner == owner else { return false }
        if let name {
            guard account.isSignedIn, identity.isAuthenticated, let key = identity.accountID else { return false }
            let scope = savedQueues.scope
            var queue = PlaybackQueue(); queue.replace(with: tracks)
            return await savedQueues.save(name: name, snapshot: queue.snapshot(), expectedScope: scope,
                expectedSession: .init(scope: identity.scope, account: key),
                isCurrent: { [weak self] in self?.catalogQueueOwner == owner })
        }
        guard queue.entries.count + tracks.count <= 10_000 else { return false }
        addToQueue(tracks)
        return true
    }
}
