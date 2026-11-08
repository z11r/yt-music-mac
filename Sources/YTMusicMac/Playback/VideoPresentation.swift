import Foundation

/// Presentation data is optional. Missing or malformed capability fields never
/// grant access to a command or change playback validation.
struct VideoPresentationSnapshot: Decodable, Equatable, Sendable {
    var hasVideo = false
    var supportsPictureInPicture = false
    var isPictureInPictureActive = false

    init(hasVideo: Bool = false, supportsPictureInPicture: Bool = false, isPictureInPictureActive: Bool = false) {
        self.hasVideo = hasVideo
        self.supportsPictureInPicture = supportsPictureInPicture
        self.isPictureInPictureActive = isPictureInPictureActive
    }

    private enum CodingKeys: CodingKey { case hasVideo, supportsPictureInPicture, isPictureInPictureActive }
    init(from decoder: any Decoder) throws {
        let values = try? decoder.container(keyedBy: CodingKeys.self)
        hasVideo = (try? values?.decode(Bool.self, forKey: .hasVideo)) ?? false
        supportsPictureInPicture = hasVideo && ((try? values?.decode(Bool.self, forKey: .supportsPictureInPicture)) ?? false)
        isPictureInPictureActive = (try? values?.decode(Bool.self, forKey: .isPictureInPictureActive)) ?? false
    }
}

enum VideoPresentationResult: Equatable, Sendable {
    case confirmed(active: Bool), unsupported, rejected, stale, cancelled
}

/// A stalled script cannot leave an optional presentation control pending.
/// The callback and timeout share a single completion gate.
@MainActor
final class VideoPresentationReply {
    private var continuation: CheckedContinuation<VideoPresentationResult, Never>?
    private var timeout: Task<Void, Never>?
    private var completed: VideoPresentationResult?

    func wait(timeout duration: Duration = .seconds(3),
              start: (@escaping @MainActor (VideoPresentationResult) -> Void) -> Void) async -> VideoPresentationResult {
        if Task.isCancelled { finish(.cancelled) }
        if let completed { return completed }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: duration) } catch { return }
                self?.finish(.rejected)
            }
            start { [weak self] result in self?.finish(result) }
        }
    }

    func finish(_ result: VideoPresentationResult) {
        guard completed == nil else { return }
        completed = result
        timeout?.cancel(); timeout = nil
        continuation?.resume(returning: result); continuation = nil
    }
}
