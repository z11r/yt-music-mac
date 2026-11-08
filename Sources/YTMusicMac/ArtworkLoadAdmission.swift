import Foundation

/// Optional, explicit portrait reads keep their original UI authority until the
/// exact native task starts. Construction is inert; no transport exists yet.
struct ArtworkLoadAdmission: Sendable {
    typealias Starter = @MainActor @Sendable (URL, CheckedContinuation<Data, any Error>, ArtworkCancellation) -> Void
    private let isCurrent: @MainActor @Sendable () -> Bool
    private let start: Starter

    init(isCurrent: @escaping @MainActor @Sendable () -> Bool,
         start: @escaping Starter = { url, continuation, cancellation in
             ArtworkTransfer.shared.start(url, continuation: continuation, cancellation: cancellation)
         }) {
        self.isCurrent = isCurrent; self.start = start
    }

    @MainActor func load(_ url: URL) async throws -> Data {
        guard ArtworkTransfer.allows(url) else { throw ArtworkTransfer.Failure.refused }
        let cancellation = ArtworkCancellation()
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Check and actual create/register/resume are one synchronous
                // MainActor admission. Do not insert an await into this boundary.
                guard !Task.isCancelled, isCurrent() else {
                    continuation.resume(throwing: CancellationError()); return
                }
                start(url, continuation, cancellation)
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        return data
    }
}
