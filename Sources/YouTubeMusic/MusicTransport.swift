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
        let transfer = Transfer(maximumResponseBytes: transferDelegate.maximumResponseBytes)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let response: MusicHTTPResponse = try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                transferDelegate.register(transfer, for: task)
                if transfer.install(task: task, continuation: continuation) {
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
private final class Transfer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumResponseBytes: Int
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<MusicHTTPResponse, any Error>?
    private var result: Result<MusicHTTPResponse, any Error>?
    private var response: HTTPURLResponse?
    private var data = Data()

    init(maximumResponseBytes: Int) { self.maximumResponseBytes = maximumResponseBytes }

    func install(task: URLSessionDataTask, continuation: CheckedContinuation<MusicHTTPResponse, any Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.task = task
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func receive(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse,
              response.expectedContentLength <= Int64(maximumResponseBytes) else {
            fail(MusicServiceError.invalidResponse)
            return false
        }
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        self.response = response
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), 256 * 1024))
        }
        lock.unlock()
        return true
    }

    func append(_ chunk: Data) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        guard chunk.count <= maximumResponseBytes - data.count else {
            lock.unlock()
            fail(MusicServiceError.invalidResponse)
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    func complete(error: (any Error)?) {
        if let error { fail(error); return }
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        guard let response else {
            lock.unlock()
            fail(MusicServiceError.invalidResponse)
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        let completed = MusicHTTPResponse(data: data, statusCode: response.statusCode, headers: headers)
        let continuation = self.continuation
        result = .success(completed)
        self.continuation = nil
        task = nil
        self.response = nil
        data = Data()
        lock.unlock()
        continuation?.resume(returning: completed)
    }

    func fail(_ error: any Error) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = .failure(error)
        let task = self.task
        let continuation = self.continuation
        self.task = nil
        self.continuation = nil
        response = nil
        data = Data()
        lock.unlock()
        task?.cancel()
        continuation?.resume(throwing: error)
    }
}

private final class TransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let maximumResponseBytes: Int
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]

    init(maximumResponseBytes: Int) { self.maximumResponseBytes = maximumResponseBytes }

    func register(_ transfer: Transfer, for task: URLSessionTask) {
        lock.lock()
        transfers[task.taskIdentifier] = transfer
        lock.unlock()
    }

    func remove(_ task: URLSessionTask) {
        lock.lock()
        transfers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }

    private func transfer(for task: URLSessionTask) -> Transfer? {
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
        // Trust evaluation stays with the platform. Account authentication uses only explicit request headers.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
