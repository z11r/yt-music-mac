import AVFoundation
import Foundation
import ObjectiveC

struct LocalAudioAssetFacts: Sendable {
    let isPlayable: Bool
    let hasAudio: Bool
    let hasVideo: Bool
    let hasProtectedContent: Bool
    let duration: TimeInterval

    func validate() throws {
        guard isPlayable, hasAudio, !hasVideo, !hasProtectedContent,
              duration.isFinite, (0.001...604_800).contains(duration) else { throw LocalAudioAccessError.unsupportedAsset }
    }
}

enum LocalAudioAssetPolicy {
    static var options: [String: Any] { [
        AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        AVURLAssetShouldSupportAliasDataReferencesKey: false,
        AVURLAssetAllowsCellularAccessKey: false,
        AVURLAssetAllowsExpensiveNetworkAccessKey: false,
        AVURLAssetAllowsConstrainedNetworkAccessKey: false,
    ] }
}

/// Shared by all native preparers; a canceled caller cannot admit another underlying preparation early.
@MainActor
final class LocalAudioPreparationAdmission {
    static let shared = LocalAudioPreparationAdmission()
    private(set) var isBusy = false

    func perform<Value: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !isBusy else { throw LocalAudioAccessError.busy }
        isBusy = true
        let worker = Task { try await operation() }
        defer { isBusy = false }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: { worker.cancel() }
    }
}

/// Retain alongside the AVPlayerItem until that item and its observers are retired.
@MainActor
final class PreparedLocalAudioAsset: LocalAudioPreparedSource {
    let asset: AVURLAsset
    let lease: LocalAudioResourceLease
    let duration: TimeInterval
    fileprivate init(asset: AVURLAsset, lease: LocalAudioResourceLease, duration: TimeInterval) {
        self.asset = asset; self.lease = lease; self.duration = duration
    }
    func release() { asset.cancelLoading(); lease.release() }
}

@MainActor
protocol LocalAudioAssetPreparing: AnyObject {
    func prepare(_ lease: LocalAudioResourceLease) async throws -> any LocalAudioPreparedSource
}

/// No player, file picker, media copying, or URL resource-loader bypass.
@MainActor
final class NativeLocalAudioAssetPreparer: LocalAudioAssetPreparing {
    private let admission: LocalAudioPreparationAdmission
    private let files: any LocalAudioFileInspecting
    private let reads: LocalAudioReadAdmission
    init(admission: LocalAudioPreparationAdmission = .shared, files: any LocalAudioFileInspecting = NativeLocalAudioFileInspector(),
         reads: LocalAudioReadAdmission = .shared) {
        self.admission = admission; self.files = files; self.reads = reads
    }

    func prepare(_ lease: LocalAudioResourceLease) async throws -> any LocalAudioPreparedSource {
        do {
            return try await admission.perform {
                try Task.checkCancellation()
                try await lease.profileLifetime.checkCurrent()
                guard lease.acceptsNewUses, lease.hasValidReferenceOwnership,
                      lease.profileLifetime.authorization.profileStorageID == lease.profileLifetime.profileStorageID else {
                    throw LocalAudioAccessError.accessDenied
                }
                try LocalAudioFilePolicy.validateURL(lease.fileURL)
                let files = self.files
                let file = try await self.reads.perform { try files.inspect(lease.fileURL) }
                try LocalAudioFilePolicy.validate(file)
                guard file.identity == lease.identity else { throw LocalAudioAccessError.identityChanged }
                try Task.checkCancellation()
                try await lease.profileLifetime.checkCurrent()
                let use = try lease.retainUse()
                let asset = AVURLAsset(url: lease.fileURL, options: LocalAudioAssetPolicy.options)
                NativeLocalAudioAssetLifetime.attach(use, to: asset)
                do {
                    let playable = try await asset.load(.isPlayable)
                    try await lease.profileLifetime.checkCurrent()
                    let protected = try await asset.load(.hasProtectedContent)
                    try await lease.profileLifetime.checkCurrent()
                    let audio = try await asset.loadTracks(withMediaType: .audio)
                    try await lease.profileLifetime.checkCurrent()
                    let video = try await asset.loadTracks(withMediaType: .video)
                    try await lease.profileLifetime.checkCurrent()
                    let duration = try await asset.load(.duration).seconds
                    try LocalAudioAssetFacts(isPlayable: playable, hasAudio: !audio.isEmpty, hasVideo: !video.isEmpty,
                                            hasProtectedContent: protected, duration: duration).validate()
                    try Task.checkCancellation()
                    guard !lease.isReleased else { throw LocalAudioAccessError.accessDenied }
                    return PreparedLocalAudioAsset(asset: asset, lease: lease, duration: duration)
                } catch { asset.cancelLoading(); throw error }
            }
        } catch { lease.release(); throw LocalAudioPlaybackIssue.sanitizing(error) }
    }
}

/// The holder has no reference to the asset, driver, item or engine.
@MainActor private enum NativeLocalAudioAssetLifetime {
    private static var key: UInt8 = 0
    static func attach(_ use: LocalAudioResourceUse, to asset: AVURLAsset) {
        objc_setAssociatedObject(asset, &key, use, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
