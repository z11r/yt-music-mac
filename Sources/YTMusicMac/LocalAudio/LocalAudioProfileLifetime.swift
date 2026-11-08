import Foundation

/// Captures one render/request owner. A resumed profile must create a fresh authorization.
@MainActor final class LocalAudioIOAuthorization {
    let profileStorageID: UUID
    private let isCurrent: @MainActor () -> Bool
    init(profileStorageID: UUID, isCurrent: @escaping @MainActor () -> Bool) {
        self.profileStorageID = profileStorageID; self.isCurrent = isCurrent
    }
    func check() throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw LocalAudioPlaybackIssue.stale }
    }
}

/// Retained independently of audible output until the actual reader/grant/item lifetime ends.
final class LocalAudioProfileLifetime: Sendable {
    let profileStorageID: UUID
    let authorization: LocalAudioIOAuthorization
    private let retained: any Sendable
    init(profileStorageID: UUID, authorization: LocalAudioIOAuthorization, retaining value: any Sendable) {
        self.profileStorageID = profileStorageID; self.authorization = authorization; retained = value
    }
    func checkCurrent() async throws { try await authorization.check() }
}

@MainActor protocol LocalAudioProfileLifetimeProviding: Sendable {
    func acquire(authorization: LocalAudioIOAuthorization) async throws -> LocalAudioProfileLifetime
}

/// Inert until an explicit, current request. Default protection comes only from a validated context.
@MainActor final class NativeLocalAudioProfileLifetimeProvider: LocalAudioProfileLifetimeProviding {
    let context: AppProfileContext
    private let registry: any AppProfileRegistry
    private let acquireShared: @Sendable (String) throws -> any Sendable
    init(context: AppProfileContext, registry: any AppProfileRegistry, root: URL) {
        self.context = context; self.registry = registry
        acquireShared = { try ProfileLifecycleLease(root: root, profileID: $0, exclusive: false) }
    }
    init(context: AppProfileContext, registry: any AppProfileRegistry,
         acquireShared: @escaping @Sendable (String) throws -> any Sendable) {
        self.context = context; self.registry = registry; self.acquireShared = acquireShared
    }
    func acquire(authorization: LocalAudioIOAuthorization) async throws -> LocalAudioProfileLifetime {
        do {
            try authorization.check()
            guard authorization.profileStorageID == context.websiteDataIdentifier else { throw LocalAudioPlaybackIssue.stale }
            let initial = try await registry.load()
            try authorization.check(); try admits(initial.archive)
            let hold: any Sendable = context.isDefault ? context : try acquireShared(context.profileID)
            let confirmed = try await registry.load()
            try authorization.check(); try admits(confirmed.archive)
            return LocalAudioProfileLifetime(profileStorageID: context.websiteDataIdentifier, authorization: authorization, retaining: hold)
        } catch { throw LocalAudioPlaybackIssue.sanitizing(error) }
    }
    private func admits(_ archive: AppProfileArchive) throws {
        guard archive.profiles.contains(where: { $0.id == context.profileID && $0.isInitialized }),
              !archive.deletions.contains(where: { $0.target.id == context.profileID }) else { throw LocalAudioPlaybackIssue.stale }
    }
}
