import Foundation

public struct MusicHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]
    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

public protocol MusicHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse
}

/// Bounded, ephemeral networking with explicit credentials and no redirects.
public final class URLSessionMusicTransport: NSObject, MusicHTTPTransport, @unchecked Sendable {
    public static let defaultMaximumResponseBytes = 16 * 1024 * 1024
    private let session: URLSession
    private let transferDelegate: TransferDelegate

    public override convenience init() {
        self.init(configuration: .ephemeral)
    }

    /// Copies the configuration and always disables shared cookies, credentials, and caches.
    /// Custom protocol classes allow tests to provide responses without contacting the service.
    public init(configuration: URLSessionConfiguration, maximumResponseBytes: Int = defaultMaximumResponseBytes) {
        precondition(maximumResponseBytes > 0)
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        configuration.httpMaximumConnectionsPerHost = 4
        transferDelegate = TransferDelegate(maximumResponseBytes: maximumResponseBytes)
        session = URLSession(configuration: configuration, delegate: transferDelegate, delegateQueue: nil)
        super.init()
    }

    public func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "music.youtube.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { throw MusicServiceError.invalidInput }
        var request = request
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let transfer = MusicTransfer(maximumResponseBytes: transferDelegate.maximumResponseBytes)
        let submitted = request
        return try await transfer.response {
            // This nonreentrant factory creates/registers a suspended task only.
            // It cannot resume, cancel, perform I/O or call a transfer callback.
            let task = self.session.dataTask(with: submitted)
            self.transferDelegate.register(transfer, for: task)
            return task
        }
    }

    deinit { session.invalidateAndCancel() }
}

/// Only suspended task creation/registration occurs inside the transfer lock.
/// Resume, cancel, native completion and continuation callbacks occur outside it.
protocol MusicTransportTask: AnyObject, Sendable {
    var taskIdentifier: Int { get }
    func resume()
    func cancel()
}
extension URLSessionDataTask: MusicTransportTask {}

final class MusicTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumResponseBytes: Int
    private var task: (any MusicTransportTask)?
    private var continuation: CheckedContinuation<MusicHTTPResponse, any Error>?
    private var result: Result<MusicHTTPResponse, any Error>?
    private var pendingFailure: (any Error)?
    private var hasStarted = false
    private var response: HTTPURLResponse?
    private var data = Data()
    var hasPendingTask: Bool { lock.withLock { task != nil } }

    init(maximumResponseBytes: Int) { precondition(maximumResponseBytes > 0); self.maximumResponseBytes = maximumResponseBytes }

    /// The injected factory is tiny and nonreentrant: creation/registration only,
    /// with no task start, cancellation, native I/O or transfer callback.
    func response(createTask: @escaping @Sendable () -> any MusicTransportTask) async throws -> MusicHTTPResponse {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: MusicHTTPResponse = try await withCheckedThrowingContinuation { continuation in
                self.start(continuation: continuation, createTask: createTask)
            }
            try Task.checkCancellation()
            return value
        } onCancel: { self.fail(CancellationError()) }
    }
    private func start(continuation: CheckedContinuation<MusicHTTPResponse, any Error>, createTask: () -> any MusicTransportTask) {
        lock.lock()
        guard !hasStarted else {
            lock.unlock(); continuation.resume(throwing: MusicServiceError.invalidResponse); return
        }
        hasStarted = true
        if let pendingFailure {
            result = .failure(pendingFailure)
            lock.unlock(); continuation.resume(throwing: pendingFailure); return
        }
        // Creation is atomic with cancellation admission. The task remains
        // suspended until registration and this lock have both been released.
        let task = createTask()
        self.task = task; self.continuation = continuation
        lock.unlock()
        task.resume()
    }

    func receive(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse,
              response.expectedContentLength <= Int64(maximumResponseBytes) else {
            fail(MusicServiceError.invalidResponse); return false
        }
        lock.lock()
        guard result == nil, pendingFailure == nil else { lock.unlock(); return false }
        self.response = response
        if response.expectedContentLength > 0 { data.reserveCapacity(min(Int(response.expectedContentLength), 256 * 1024)) }
        lock.unlock(); return true
    }
    func append(_ chunk: Data) {
        lock.lock()
        guard result == nil, pendingFailure == nil else { lock.unlock(); return }
        guard chunk.count <= maximumResponseBytes - data.count else {
            lock.unlock(); fail(MusicServiceError.invalidResponse); return
        }
        data.append(chunk); lock.unlock()
    }

    /// The delegate removes this exact task from its registry before calling here.
    /// A timeout/cancel request is never a substitute for the native completion.
    func complete(taskIdentifier: Int, error: (any Error)?) {
        lock.lock()
        guard result == nil, task?.taskIdentifier == taskIdentifier else { lock.unlock(); return }
        let completed: Result<MusicHTTPResponse, any Error>
        if let error = pendingFailure ?? error { completed = .failure(error) }
        else if let response {
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
            }
            completed = .success(.init(data: data, statusCode: response.statusCode, headers: headers))
        } else { completed = .failure(MusicServiceError.invalidResponse) }
        let continuation = self.continuation
        result = completed; self.continuation = nil; task = nil
        pendingFailure = nil; self.response = nil; data = Data()
        lock.unlock(); continuation?.resume(with: completed)
    }
    func fail(_ error: any Error) {
        lock.lock()
        guard result == nil, pendingFailure == nil else { lock.unlock(); return }
        pendingFailure = error
        let task = self.task
        response = nil; data = Data()
        lock.unlock()
        // Keep task, continuation and caller admission until exact didComplete.
        task?.cancel()
    }
}

private final class TransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let maximumResponseBytes: Int
    private let lock = NSLock()
    private var transfers: [Int: MusicTransfer] = [:]

    init(maximumResponseBytes: Int) { self.maximumResponseBytes = maximumResponseBytes }

    func register(_ transfer: MusicTransfer, for task: URLSessionTask) {
        lock.lock()
        transfers[task.taskIdentifier] = transfer
        lock.unlock()
    }

    func remove(_ task: URLSessionTask) {
        lock.lock()
        transfers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }

    private func transfer(for task: URLSessionTask) -> MusicTransfer? {
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
        transfer?.complete(taskIdentifier: task.taskIdentifier, error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Preserve the original status even when the loading system omits a separate response callback.
        _ = transfer(for: task)?.receive(response)
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Trust evaluation stays with the platform. Account authentication uses only explicit request headers.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
