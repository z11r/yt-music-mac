import AppKit
import ImageIO
import SwiftUI

struct ArtworkView: View {
    let url: URL?
    var size: CGFloat = 176
    var isArtist = false
    /// A song's video ID, used for YouTube's public frame thumbnail when the
    /// service returned no artwork.
    var videoID: String?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loaded: LoadedArtwork?

    private var request: ArtworkRequest {
        ArtworkRequest(url: url, videoID: videoID,
                       pixels: min(512, max(64, Int((size * displayScale).rounded(.up)))))
    }

    /// Artist portraits are round; other artwork gets corners that scale down for small rows.
    private var shape: AnyShape {
        isArtist ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: min(8, max(4, (size * 0.11).rounded())), style: .continuous))
    }

    var body: some View {
        let request = request
        // A memory-cache hit draws on the first frame, so rows that are rebuilt
        // while scrolling never flash the placeholder.
        let artwork = loaded?.request == request ? loaded?.artwork : ArtworkCache.cached(request)
        ZStack {
            Rectangle().fill(.quaternary)
            if let artwork {
                Image(decorative: artwork.image, scale: displayScale).resizable().scaledToFill()
            } else {
                Image(systemName: isArtist ? "person.crop.circle" : "music.note")
                    .font(.system(size: max(16, size * 0.22), weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
        .task(id: request) {
            guard ArtworkCache.cached(request) == nil,
                  let artwork = await ArtworkCache.shared.image(for: request),
                  !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                loaded = LoadedArtwork(request: request, artwork: artwork)
            }
        }
    }
}

private struct ArtworkRequest: Hashable, Sendable {
    let url: URL?
    let videoID: String?
    let pixels: Int

    var cacheKey: NSString {
        "\(pixels)|\(url?.absoluteString ?? "")|\(videoID ?? "")" as NSString
    }
}

private struct LoadedArtwork {
    let request: ArtworkRequest
    let artwork: DecodedArtwork
}

private final class DecodedArtwork: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// One URL to try for a piece of artwork.
struct ArtworkSource: Hashable, Sendable {
    let url: URL
    /// YouTube's 4:3 frame thumbnails pad a 16:9 picture with black bars.
    let isLetterboxed: Bool

    /// Server sizes requested for square artwork. Views of similar size share a download.
    static let sizeSteps = [120, 226, 360, 544]

    /// YouTube's public frame thumbnails, with the side of the largest
    /// bar-free square each one can supply.
    private static let videoFrames: [(name: String, square: Int, isLetterboxed: Bool)] = [
        ("mqdefault", 180, false), ("hqdefault", 270, true), ("sddefault", 360, true), ("hq720", 720, false),
    ]

    /// URLs to try in order for a square image `pixels` wide.
    static func candidates(url: URL?, videoID: String?, pixels: Int) -> [ArtworkSource] {
        if let url, let id = frameVideoID(url) { return frames(for: id, pixels: pixels) }
        if let url { return [ArtworkSource(url: resized(url, pixels: pixels), isLetterboxed: false)] }
        if let videoID, isVideoID(videoID) { return frames(for: videoID, pixels: pixels) }
        return []
    }

    /// Picks the smallest frame thumbnail that covers the square, then larger
    /// ones, then smaller ones. Not every video has the larger sizes.
    private static func frames(for id: String, pixels: Int) -> [ArtworkSource] {
        let large = videoFrames.filter { $0.square >= pixels }
        let small = videoFrames.filter { $0.square < pixels }.reversed()
        return (large + small).prefix(3).compactMap { frame in
            URL(string: "https://i.ytimg.com/vi/\(id)/\(frame.name).jpg")
                .map { ArtworkSource(url: $0, isLetterboxed: frame.isLetterboxed) }
        }
    }

    /// Rewrites the size options of a Google image URL (`=w120-h120-l90-rj`,
    /// `=s88-c-k`) so the server returns at least `pixels` on the short side.
    static func resized(_ url: URL, pixels: Int) -> URL {
        guard let host = url.host?.lowercased(),
              ["googleusercontent.com", "ggpht.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              url.query == nil, url.fragment == nil else { return url }
        let string = url.absoluteString
        guard let slash = string.lastIndex(of: "/"),
              let equals = string[slash...].lastIndex(of: "=") else { return url }
        var options = string[string.index(after: equals)...].split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        func number(_ prefix: Character) -> (index: Int, value: Int)? {
            for (index, option) in options.enumerated() where option.first == prefix {
                if let value = Int(option.dropFirst()), value > 0 { return (index, value) }
            }
            return nil
        }
        let target = sizeSteps.first { $0 >= pixels } ?? pixels
        if let width = number("w"), let height = number("h") {
            let shortest = min(width.value, height.value)
            func scaled(_ value: Int) -> Int { (value * target + shortest - 1) / shortest }
            options[width.index] = "w\(scaled(width.value))"
            options[height.index] = "h\(scaled(height.value))"
        } else if let side = number("s") {
            options[side.index] = "s\(target)"
        } else {
            return url
        }
        return URL(string: String(string[...equals]) + options.joined(separator: "-")) ?? url
    }

    /// The video ID in an `i.ytimg.com/vi/<id>/…` frame thumbnail URL.
    static func frameVideoID(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), host == "ytimg.com" || host.hasSuffix(".ytimg.com") else { return nil }
        let parts = url.pathComponents
        guard parts.count >= 4, ["vi", "vi_webp"].contains(parts[1]), isVideoID(parts[2]) else { return nil }
        return parts[2]
    }

    static func isVideoID(_ value: String) -> Bool {
        value.count == 11 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }
}

enum ArtworkDecoder {
    /// Decodes a centre-cropped square `pixels` wide, or smaller when the
    /// source is smaller. Letterboxed sources lose their bars first.
    static func squareImage(from data: Data, pixels: Int, letterboxed: Bool) -> CGImage? {
        guard pixels > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              Double(width) * Double(height) <= 50_000_000 else { return nil }
        let crop = cropRect(width: width, height: height, letterboxed: letterboxed)
        let target = min(pixels, Int(crop.width))
        // Decode just large enough that the crop still covers the target.
        let longest = max(width, height)
        let decodeSize = min(longest, Int((Double(target) * Double(longest) / crop.width).rounded(.up)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard target > 0,
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                          CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // Map the crop into the decoded image, which is smaller and may be rotated.
        let rect = cropRect(width: decoded.width, height: decoded.height, letterboxed: letterboxed)
        let scale = Double(target) / rect.width
        context.interpolationQuality = .high
        // Core Graphics puts the origin at the bottom left; `rect` uses the top left.
        context.draw(decoded, in: CGRect(x: -rect.minX * scale, y: -(Double(decoded.height) - rect.maxY) * scale,
                                         width: Double(decoded.width) * scale, height: Double(decoded.height) * scale))
        return context.makeImage()
    }

    /// The centred square to keep, in top-left image coordinates.
    static func cropRect(width: Int, height: Int, letterboxed: Bool) -> CGRect {
        let width = Double(width), height = Double(height)
        var top = 0.0, bottom = height
        // Stay a little inside a letterboxed picture, so the blurred bar edge
        // and JPEG ringing never reach the crop.
        if letterboxed, abs(width / height - 4.0 / 3.0) < 0.02 {
            let picture = width * 9 / 16
            let margin = (picture * 0.01).rounded(.up)
            top = ((height - picture) / 2 + margin).rounded(.up)
            bottom = ((height + picture) / 2 - margin).rounded(.down)
        }
        let side = min(width, bottom - top).rounded(.down)
        return CGRect(x: ((width - side) / 2).rounded(.down), y: (top + (bottom - top - side) / 2).rounded(.down),
                      width: side, height: side)
    }
}

private actor ArtworkCache {
    static let shared = ArtworkCache()
    /// NSCache is thread-safe, so views read it synchronously while drawing.
    private nonisolated(unsafe) static let memory: NSCache<NSString, DecodedArtwork> = {
        let value = NSCache<NSString, DecodedArtwork>()
        value.totalCostLimit = 48 * 1024 * 1024
        value.countLimit = 160
        return value
    }()
    /// Sources the server refused, such as frame sizes a video lacks.
    private var refused: Set<URL> = []

    nonisolated static func cached(_ request: ArtworkRequest) -> DecodedArtwork? {
        memory.object(forKey: request.cacheKey)
    }

    func image(for request: ArtworkRequest) async -> DecodedArtwork? {
        if let value = Self.cached(request) { return value }
        let sources = ArtworkSource.candidates(url: request.url, videoID: request.videoID, pixels: request.pixels)
        for source in sources where ArtworkTransfer.allows(source.url) && !refused.contains(source.url) {
            guard !Task.isCancelled else { return nil }
            let data: Data
            do {
                data = try await ArtworkTransfer.shared.load(source.url)
            } catch ArtworkTransfer.Failure.refused {
                if refused.count >= 512 { refused.removeAll() }
                refused.insert(source.url)
                continue
            } catch {
                continue
            }
            let pixels = request.pixels
            let decoded = await Task.detached(priority: .utility) {
                ArtworkDecoder.squareImage(from: data, pixels: pixels, letterboxed: source.isLetterboxed)
                    .map(DecodedArtwork.init)
            }.value
            guard !Task.isCancelled else { return nil }
            guard let decoded else { continue }
            Self.memory.setObject(decoded, forKey: request.cacheKey,
                                  cost: decoded.image.bytesPerRow * decoded.image.height)
            return decoded
        }
        return nil
    }
}

/// All mutable transfer state is protected by the lock. This session has no
/// cookies, credential storage, or disk cache, and never reads the account store.
private final class ArtworkTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: Error { case refused }

    static let shared = ArtworkTransfer()
    private static let byteLimit = 4 * 1024 * 1024
    private let lock = NSLock()
    private var requests: [Int: Request] = [:]
    private var session: URLSession!

    private struct Request {
        let continuation: CheckedContinuation<Data, any Error>
        var data = Data()
        var redirects = 0
        /// The server's answer rules this URL out, as opposed to a network failure.
        var isRefused = false
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
        guard Self.allows(url) else { throw Failure.refused }
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
            lock.withLock { requests[dataTask.taskIdentifier]?.isRefused = true }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceedsLimit = lock.withLock {
            guard let count = requests[dataTask.taskIdentifier]?.data.count,
                  count + data.count <= Self.byteLimit else {
                requests[dataTask.taskIdentifier]?.isRefused = true
                return true
            }
            requests[dataTask.taskIdentifier]?.data.append(data)
            return false
        }
        if exceedsLimit { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let value = lock.withLock { requests.removeValue(forKey: task.taskIdentifier) }
        guard let value else { return }
        if value.isRefused { value.continuation.resume(throwing: Failure.refused) }
        else if let error { value.continuation.resume(throwing: error) }
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
