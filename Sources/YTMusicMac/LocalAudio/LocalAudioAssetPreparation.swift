import AVFoundation
import Foundation

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
final class PreparedLocalAudioAsset {
    let asset: AVURLAsset
    let lease: LocalAudioResourceLease
    let duration: TimeInterval
    init(asset: AVURLAsset, lease: LocalAudioResourceLease, duration: TimeInterval) {
        self.asset = asset; self.lease = lease; self.duration = duration
    }
    func release() { asset.cancelLoading(); lease.release() }
}

@MainActor
protocol LocalAudioAssetPreparing: AnyObject {
    func prepare(_ lease: LocalAudioResourceLease) async throws -> PreparedLocalAudioAsset
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

    func prepare(_ lease: LocalAudioResourceLease) async throws -> PreparedLocalAudioAsset {
        do {
            return try await admission.perform {
                try Task.checkCancellation()
                guard !lease.isReleased else { throw LocalAudioAccessError.accessDenied }
                try LocalAudioFilePolicy.validateURL(lease.fileURL)
                let files = self.files
                let file = try await self.reads.perform { try files.inspect(lease.fileURL) }
                try LocalAudioFilePolicy.validate(file)
                guard file.identity == lease.identity else { throw LocalAudioAccessError.identityChanged }
                try Task.checkCancellation()
                let asset = AVURLAsset(url: lease.fileURL, options: LocalAudioAssetPolicy.options)
                do {
                    let playable = try await asset.load(.isPlayable)
                    let protected = try await asset.load(.hasProtectedContent)
                    let audio = try await asset.loadTracks(withMediaType: .audio)
                    let video = try await asset.loadTracks(withMediaType: .video)
                    let duration = try await asset.load(.duration).seconds
                    try LocalAudioAssetFacts(isPlayable: playable, hasAudio: !audio.isEmpty, hasVideo: !video.isEmpty,
                                            hasProtectedContent: protected, duration: duration).validate()
                    try Task.checkCancellation()
                    guard !lease.isReleased else { throw LocalAudioAccessError.accessDenied }
                    return PreparedLocalAudioAsset(asset: asset, lease: lease, duration: duration)
                } catch { asset.cancelLoading(); throw error }
            }
        } catch { lease.release(); throw error }
    }
}
