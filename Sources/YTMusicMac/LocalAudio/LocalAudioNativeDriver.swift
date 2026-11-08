import Foundation

enum LocalAudioNativeReadiness: Sendable { case unknown, ready, failed }
enum LocalAudioNativeControl: Sendable { case paused, waiting, playing, unknown }
struct LocalAudioNativeSnapshot: Sendable {
    var hasPlayer = false
    var hasItem = false
    var mediaID: UUID?
    var readiness: LocalAudioNativeReadiness = .unknown
    var muted = true
    var rate: Double = 0
    var control: LocalAudioNativeControl = .paused
    var externalPlayback = false
    var position: TimeInterval?
    var duration: TimeInterval?
    var isQuiet: Bool {
        !hasItem && mediaID == nil && muted && rate.isFinite && rate == 0 && control == .paused && !externalPlayback
    }
}
enum LocalAudioNativeEvent { case state(LocalAudioNativeSnapshot), ended(LocalAudioNativeSnapshot), failed }
@MainActor protocol LocalAudioNativeItem: AnyObject {
    var mediaID: UUID { get }
    var source: any LocalAudioPreparedSource { get }
}
@MainActor protocol LocalAudioNativeObservation: AnyObject { func invalidate() }
@MainActor protocol LocalAudioNativeDriving: AnyObject {
    var outputInstanceID: UUID { get }
    var snapshot: LocalAudioNativeSnapshot { get }
    func makeItem(_ source: any LocalAudioPreparedSource) throws -> any LocalAudioNativeItem
    func install(_ item: any LocalAudioNativeItem) throws
    func detach()
    func mute(_ value: Bool)
    func pause()
    func play()
    func volume(_ value: Double)
    func seek(_ item: any LocalAudioNativeItem, to position: TimeInterval, completion: @escaping @MainActor (Bool) -> Void)
    func cancelSeeks(_ item: any LocalAudioNativeItem)
    func observe(_ item: any LocalAudioNativeItem, receive: @escaping @MainActor (LocalAudioNativeEvent) -> Void) -> any LocalAudioNativeObservation
    func observeOutput(_ changed: @escaping @MainActor () -> Void) -> any LocalAudioNativeObservation
    /// Permanent, including reentrant install/play/unmute attempts.
    func holdOutput()
}

@MainActor final class LocalAudioOperationWait {
    private var outcome: Result<Void, LocalAudioPlaybackIssue>?
    private var continuation: CheckedContinuation<Result<Void, LocalAudioPlaybackIssue>, Never>?
    private var timer: Task<Void, Never>?
    init(sleep: @escaping @Sendable () async throws -> Void) {
        timer = Task { [weak self] in
            do { try Task.checkCancellation(); try await sleep(); try Task.checkCancellation() } catch { return }
            self?.finish(.failure(.timedOut))
        }
    }
    func finish(_ result: Result<Void, LocalAudioPlaybackIssue>) {
        guard outcome == nil else { return }
        outcome = result; timer?.cancel(); timer = nil
        let waiting = continuation; continuation = nil; waiting?.resume(returning: result)
    }
    func result() async -> Result<Void, LocalAudioPlaybackIssue> {
        await withTaskCancellationHandler {
            if Task.isCancelled { finish(.failure(.cancelled)) }
            if let outcome { return outcome }
            return await withCheckedContinuation { continuation = $0 }
        } onCancel: { Task { @MainActor in self.finish(.failure(.cancelled)) } }
    }
}
