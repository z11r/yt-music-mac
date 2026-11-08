import Foundation
import MusicCore

/// Inert profile adapters. Explicit library and transport actions perform the work.
@MainActor struct LocalAudioSessionResources {
    let context: AppProfileContext
    let store: any LocalAudioLibraryStoring
    let profiles: any LocalAudioProfileLifetimeProviding
    let references: LocalAudioReferenceUseRegistry
    let bookmarks: any LocalAudioBookmarkAccessing
    let playback: LocalAudioPlaybackConfiguration
    private let reads: LocalAudioReadAdmission

    init(context: AppProfileContext, registry: any AppProfileRegistry, root: URL,
         references: LocalAudioReferenceUseRegistry) {
        self.context = context; self.references = references; reads = .shared
        let profiles = NativeLocalAudioProfileLifetimeProvider(context: context, registry: registry, root: root)
        self.profiles = profiles
        let store = LocalAudioLibraryStore(fileURL: context.dataDirectory.appendingPathComponent("LocalAudio/library.json"),
                                          profileID: context.websiteDataIdentifier)
        self.store = store
        // The current app is not sandboxed. Scoped grants require a separately
        // reviewed entitlement configuration; ordinary bookmarks are explicit.
        let bookmarks = NativeLocalAudioBookmarkAccess(mode: .ordinary)
        self.bookmarks = bookmarks
        let access = LocalAudioAccessController(store: store, bookmarks: bookmarks, files: NativeLocalAudioFileInspector(),
                                               profiles: profiles, references: references)
        let preparer = LocalAudioItemPreparer(access: access, assets: NativeLocalAudioAssetPreparer())
        playback = .init(profileStorageID: context.websiteDataIdentifier, prepare: { track, scope, authorization, position in
            guard let reference = track.localAudioReference else { return .failure(.unsupported) }
            return await preparer.prepare(track: track, scope: scope, expectedLibraryID: reference.libraryID,
                                          authorization: authorization, resumePosition: position)
        }, makeEngine: { bind, accepts in
            LocalAudioPlayerEngine(profileStorageID: context.websiteDataIdentifier, bindEvents: bind, acceptsEvent: accepts)
        })
    }

    init(context: AppProfileContext, store: any LocalAudioLibraryStoring,
         profiles: any LocalAudioProfileLifetimeProviding, references: LocalAudioReferenceUseRegistry,
         bookmarks: any LocalAudioBookmarkAccessing, playback: LocalAudioPlaybackConfiguration,
         reads: LocalAudioReadAdmission = .shared) {
        self.context = context; self.store = store; self.profiles = profiles
        self.references = references; self.bookmarks = bookmarks; self.playback = playback; self.reads = reads
    }

    func loadLibrary(authorization: LocalAudioIOAuthorization) async throws -> LocalAudioLibraryDocument? {
        let lifetime = try await profiles.acquire(authorization: authorization)
        try authorization.check()
        let result = try await reads.perform { [store] in
            try await lifetime.checkCurrent()
            let document = try await store.load()
            try await lifetime.checkCurrent()
            return document
        }
        try authorization.check()
        return result
    }
}

/// This value is captured by a library action before any asynchronous validation.
struct LocalAudioQueueTarget: Equatable, Sendable {
    let profile: UUID
    let account: UUID
    let queueRevision: QueueRevision
    let occurrence: PlaybackOccurrence?
}
