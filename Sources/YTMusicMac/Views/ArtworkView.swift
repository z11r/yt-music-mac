import AppKit
import ImageIO
import SwiftUI

struct ArtworkView: View {
    let url: URL?
    var size: CGFloat = 176
    var isArtist = false
    @Environment(\.displayScale) private var displayScale
    @State private var artwork: NSImage?

    private var request: ArtworkRequest {
        ArtworkRequest(url: url, pixels: min(512, max(64, Int(size * displayScale))))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: isArtist ? size / 2 : 8)
                .fill(.quaternary)
            if let artwork {
                Image(nsImage: artwork).resizable().scaledToFill()
            } else {
                Image(systemName: isArtist ? "person.crop.circle" : "music.note")
                    .font(.system(size: max(16, size * 0.22), weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: isArtist ? size / 2 : 8))
        .accessibilityHidden(true)
        .task(id: request) {
            artwork = nil
            guard let decoded = await ArtworkCache.shared.image(for: request), !Task.isCancelled else { return }
            artwork = NSImage(cgImage: decoded.image, size: NSSize(width: size, height: size))
        }
    }
}

private struct ArtworkRequest: Hashable, Sendable {
    let url: URL?
    let pixels: Int
}

private final class DecodedArtwork: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private actor ArtworkCache {
    static let shared = ArtworkCache()
    private let cache: NSCache<NSString, DecodedArtwork> = {
        let value = NSCache<NSString, DecodedArtwork>()
        value.totalCostLimit = 48 * 1024 * 1024
        value.countLimit = 120
        return value
    }()

    func image(for request: ArtworkRequest) async -> DecodedArtwork? {
        guard let url = request.url, ArtworkTransfer.allows(url), !Task.isCancelled else { return nil }
        let key = "\(request.pixels):\(url.absoluteString)" as NSString
        if let value = cache.object(forKey: key) { return value }
        guard let data = try? await ArtworkTransfer.shared.load(url), !Task.isCancelled else { return nil }
        let decoded = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                CGImageSourceGetCount(source) > 0,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0, width <= 16_384, height <= 16_384,
                Double(width) * Double(height) <= 50_000_000 else { return nil as DecodedArtwork? }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: request.pixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(DecodedArtwork.init)
        }.value
        guard !Task.isCancelled, let decoded else { return nil }
        cache.setObject(decoded, forKey: key, cost: decoded.image.bytesPerRow * decoded.image.height)
        return decoded
    }
}

/// All mutable transfer state is protected by the lock. This session has no
/// cookies, credential storage, or disk cache, and never reads the account store.
private final class ArtworkTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = ArtworkTransfer()
    private static let byteLimit = 4 * 1024 * 1024
    private let lock = NSLock()
    private var requests: [Int: Request] = [:]
    private var session: URLSession!

    private struct Request {
        let continuation: CheckedContinuation<Data, any Error>
        var data = Data()
        var redirects = 0
    }

    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["googleusercontent.com", "ggpht.com", "ytimg.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        } || host == "img.youtube.com"
    }

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.httpMaximumConnectionsPerHost = 4
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func load(_ url: URL) async throws -> Data {
        guard Self.allows(url) else { throw URLError(.unsupportedURL) }
        let cancellation = ArtworkCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                var request = URLRequest(url: url)
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                request.httpShouldHandleCookies = false
                let task = session.dataTask(with: request)
                lock.withLock { requests[task.taskIdentifier] = Request(continuation: continuation) }
                cancellation.set(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = http.url, Self.allows(url),
              http.mimeType?.lowercased().hasPrefix("image/") == true,
              http.expectedContentLength <= Self.byteLimit else {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceedsLimit = lock.withLock {
            guard let count = requests[dataTask.taskIdentifier]?.data.count,
                  count + data.count <= Self.byteLimit else { return true }
            requests[dataTask.taskIdentifier]?.data.append(data)
            return false
        }
        if exceedsLimit { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let value = lock.withLock { requests.removeValue(forKey: task.taskIdentifier) }
        guard let value else { return }
        if let error { value.continuation.resume(throwing: error) }
        else if value.data.isEmpty { value.continuation.resume(throwing: URLError(.zeroByteResource)) }
        else { value.continuation.resume(returning: value.data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let permitsRedirect = lock.withLock {
            guard var value = requests[task.taskIdentifier], value.redirects < 3,
                  let url = request.url, Self.allows(url) else { return false }
            value.redirects += 1
            requests[task.taskIdentifier] = value
            return true
        }
        completionHandler(permitsRedirect ? request : nil)
    }
}

private final class ArtworkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false
    func set(_ task: URLSessionTask) {
        let cancel = lock.withLock { self.task = task; return isCancelled }
        if cancel { task.cancel() }
    }
    func cancel() {
        let current = lock.withLock { isCancelled = true; return task }
        current?.cancel()
    }
}
