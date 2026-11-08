import Foundation

/// Bounded ephemeral networking for a single public hash-prefix lookup.
final class SponsorBlockHTTPTransport: NSObject, SponsorBlockTransport, @unchecked Sendable {
    static let defaultMaximumResponseBytes = SponsorBlockRequest.byteLimit
    private let session: URLSession
    private let transferDelegate: TransferDelegate

    override convenience init() {
        self.init(configuration: .ephemeral)
    }

    /// Copies the configuration and always disables shared cookies, credentials, and caches.
    /// Custom protocol classes allow tests to provide responses without contacting the service.
    init(configuration: URLSessionConfiguration, maximumResponseBytes: Int = defaultMaximumResponseBytes) {
        precondition(maximumResponseBytes > 0)
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.httpMaximumConnectionsPerHost = 1
        transferDelegate = TransferDelegate(maximumResponseBytes: min(SponsorBlockRequest.byteLimit, maximumResponseBytes))
        session = URLSession(configuration: configuration, delegate: transferDelegate, delegateQueue: nil)
        super.init()
    }

    func send(_ request: URLRequest) async throws -> SponsorBlockResponse {
        guard SponsorBlockRequest.permits(request) else { throw SponsorBlockError.invalidRequest }
        let input = request
        var request = input
        for header in input.allHTTPHeaderFields?.keys ?? Dictionary<String, String>().keys {
            request.setValue(nil, forHTTPHeaderField: header)
        }
        request.mainDocumentURL = nil
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("YTMusicMac-Sections/1", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let transfer = SponsorBlockTransfer(maximumResponseBytes: transferDelegate.maximumResponseBytes)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let response: SponsorBlockResponse = try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                transferDelegate.register(transfer, for: task)
                if transfer.install(cancel: { task.cancel() }, continuation: continuation) {
                    task.resume()
                } else {
                    transferDelegate.remove(task)
                    task.cancel()
                }
            }
            try Task.checkCancellation()
            return response
        } onCancel: {
            transfer.fail(CancellationError())
        }
    }

    deinit { session.invalidateAndCancel() }
}

/// URLSession delivers data in chunks. Locks protect registration/cancellation from delegate callbacks;
/// neither continuations nor URLSession methods are invoked while a lock is held.
final class SponsorBlockTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumResponseBytes: Int
    private var cancelTask: (@Sendable () -> Void)?
    private var pendingFailure: (any Error)?
    private var continuation: CheckedContinuation<SponsorBlockResponse, any Error>?
    private var result: Result<SponsorBlockResponse, any Error>?
    private var response: HTTPURLResponse?
    private var data = Data()

    init(maximumResponseBytes: Int) { self.maximumResponseBytes = maximumResponseBytes }

    func install(cancel: @escaping @Sendable () -> Void, continuation: CheckedContinuation<SponsorBlockResponse, any Error>) -> Bool {
        lock.lock()
        // A cancellation before installation admits no underlying transfer.
        if let pendingFailure {
            result = .failure(pendingFailure)
            lock.unlock()
            continuation.resume(throwing: pendingFailure)
            return false
        }
        self.cancelTask = cancel
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func receive(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse,
              response.expectedContentLength <= Int64(maximumResponseBytes) else {
            fail(SponsorBlockError.invalidResponse)
            return false
        }
        lock.lock()
        guard result == nil, pendingFailure == nil else { lock.unlock(); return false }
        self.response = response
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), 256 * 1024))
        }
        lock.unlock()
        return true
    }

    func append(_ chunk: Data) {
        lock.lock()
        guard result == nil, pendingFailure == nil else { lock.unlock(); return }
        guard chunk.count <= maximumResponseBytes - data.count else {
            lock.unlock()
            fail(SponsorBlockError.invalidResponse)
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    /// Called only after the delegate has removed this completed task from its registry.
    func complete(error: (any Error)?) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        let completed: Result<SponsorBlockResponse, any Error>
        if let failure = pendingFailure ?? error {
            completed = .failure(failure)
        } else if let response {
            let retry = response.value(forHTTPHeaderField: "Retry-After")
            completed = .success(SponsorBlockResponse(data: data, statusCode: response.statusCode,
                retryAfter: retry.flatMap { $0.utf8.count <= 128 ? $0 : nil }))
        } else {
            completed = .failure(SponsorBlockError.invalidResponse)
        }
        let continuation = self.continuation
        result = completed
        self.continuation = nil
        cancelTask = nil; pendingFailure = nil; response = nil; data = Data()
        lock.unlock()
        continuation?.resume(with: completed)
    }

    func fail(_ error: any Error) {
        lock.lock()
        guard result == nil, pendingFailure == nil else { lock.unlock(); return }
        pendingFailure = error
        let cancel = cancelTask
        response = nil; data = Data()
        lock.unlock()
        // Cancellation is only a request. Keep the continuation, transport and admission
        // alive until URLSession's completion callback settles the admitted task.
        cancel?()
    }

}

private final class TransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let maximumResponseBytes: Int
    private let lock = NSLock()
    private var transfers: [Int: SponsorBlockTransfer] = [:]

    init(maximumResponseBytes: Int) { self.maximumResponseBytes = maximumResponseBytes }

    func register(_ transfer: SponsorBlockTransfer, for task: URLSessionTask) {
        lock.lock()
        transfers[task.taskIdentifier] = transfer
        lock.unlock()
    }

    func remove(_ task: URLSessionTask) {
        lock.lock()
        transfers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }

    private func transfer(for task: URLSessionTask) -> SponsorBlockTransfer? {
        lock.lock()
        defer { lock.unlock() }
        return transfers[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        completionHandler(transfer(for: dataTask)?.receive(response) == true ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfer(for: dataTask)?.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let transfer = transfer(for: task)
        remove(task)
        transfer?.complete(error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Preserve the original status even when the loading system omits a separate response callback.
        _ = transfer(for: task)?.receive(response)
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Only platform server-trust evaluation is allowed.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
