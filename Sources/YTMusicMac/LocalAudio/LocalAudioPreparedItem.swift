import Foundation
import MusicCore

@MainActor protocol LocalAudioPreparedSource: AnyObject, Sendable {
    var lease: LocalAudioResourceLease { get }
    var duration: TimeInterval { get }
    func release()
}

/// An exact once-consumed preparation, not output authority or a queue.
@MainActor final class LocalAudioPreparedItem {
    let scope: PlaybackOutputScope
    let track: Track
    let source: any LocalAudioPreparedSource
    let authorization: LocalAudioIOAuthorization
    let resumePosition: TimeInterval
    private(set) var consumed = false
    init(scope: PlaybackOutputScope, track: Track, source: any LocalAudioPreparedSource,
         authorization: LocalAudioIOAuthorization, resumePosition: TimeInterval = 0) throws {
        try authorization.check(); try track.validateLocalAudioSource()
        let lease = source.lease
        guard scope.engine == .local, track.origin == .localFile, let reference = track.localAudioReference,
              scope.occurrence.trackID == track.id, reference == lease.reference,
              lease.referenceUse.reference == reference,
              lease.referenceUse.registry.profileStorageID == authorization.profileStorageID,
              lease.profileLifetime.profileStorageID == authorization.profileStorageID,
              lease.profileLifetime.authorization === authorization,
              lease.libraryAccess?.reference == reference,
              lease.libraryAccess?.profileStorageID == authorization.profileStorageID,
              lease.hasValidReferenceOwnership, lease.acceptsNewUses, source.duration.isFinite, (0.001...604_800).contains(source.duration),
              resumePosition.isFinite, (0...source.duration).contains(resumePosition) else { throw LocalAudioPlaybackIssue.stale }
        self.scope = scope; self.track = track; self.source = source; self.authorization = authorization
        self.resumePosition = resumePosition
    }
    func consume(for permit: PlaybackOutputPermit) throws {
        try authorization.check()
        guard !consumed, scope == permit.scope, source.lease.acceptsNewUses else { throw LocalAudioPlaybackIssue.stale }
        consumed = true
    }
    func cancelIfUnconsumed() { if !consumed { consumed = true; source.release() } }
}

/// Explicit preparation only. Native errors never become shared error strings.
@MainActor final class LocalAudioItemPreparer {
    private let access: any LocalAudioAccessProviding
    private let assets: any LocalAudioAssetPreparing
    init(access: any LocalAudioAccessProviding, assets: any LocalAudioAssetPreparing) { self.access = access; self.assets = assets }
    func prepare(track: Track, scope: PlaybackOutputScope, expectedLibraryID: UUID,
                 authorization: LocalAudioIOAuthorization, resumePosition: TimeInterval = 0) async -> Result<LocalAudioPreparedItem, LocalAudioPlaybackIssue> {
        var lease: LocalAudioResourceLease?
        var prepared: (any LocalAudioPreparedSource)?
        do {
            try authorization.check()
            guard resumePosition.isFinite, resumePosition >= 0 else { throw LocalAudioPlaybackIssue.seekFailed }
            try track.validateLocalAudioSource()
            guard scope.engine == .local, let reference = track.localAudioReference, reference.libraryID == expectedLibraryID,
                  scope.occurrence.trackID == track.id else { throw LocalAudioPlaybackIssue.stale }
            let acquired = try await access.acquire(reference, expectedLibraryID: expectedLibraryID, authorization: authorization)
            lease = acquired; try authorization.check()
            let asset = try await assets.prepare(acquired)
            prepared = asset; try authorization.check()
            guard asset.duration.isFinite, (0.001...604_800).contains(asset.duration) else { throw LocalAudioPlaybackIssue.unsupported }
            let position = min(resumePosition, asset.duration)
            return .success(try LocalAudioPreparedItem(scope: scope, track: track, source: asset,
                authorization: authorization, resumePosition: position))
        } catch {
            prepared?.release(); lease?.release()
            return .failure(.sanitizing(error))
        }
    }
}
