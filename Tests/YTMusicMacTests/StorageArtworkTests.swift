import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import YTMusicMac

private actor SuspendedArtworkLoader {
    private var continuation: CheckedContinuation<Data, Never>?
    private var requested: CheckedContinuation<Void, Never>?
    private var response: Data?
    private(set) var count = 0
    func load() async -> Data {
        count += 1
        if let response { return response }
        return await withCheckedContinuation {
            continuation = $0
            requested?.resume()
            requested = nil
        }
    }
    func waitForRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { requested = $0 }
    }
    func respond(_ data: Data) {
        response = data
        continuation?.resume(returning: data)
        continuation = nil
    }
}

@Suite("Measured and clearable artwork cache")
struct StorageArtworkTests {
    @Test func costAndCountLimitsEvictLeastRecentlyUsedEntriesAndReportExactUsage() {
        let cache = BoundedMemoryCache<String, Int>(byteLimit: 10, countLimit: 2)
        cache.insert(1, for: "one", cost: 4)
        cache.insert(2, for: "two", cost: 4)
        #expect(cache.value(for: "one") == 1)
        cache.insert(3, for: "three", cost: 4)
        #expect(cache.value(for: "two") == nil)
        #expect(cache.usage() == MemoryCacheUsage(bytes: 8, count: 2))
        cache.insert(4, for: "four", cost: 9)
        #expect(cache.usage() == MemoryCacheUsage(bytes: 9, count: 1))
        cache.insert(5, for: "oversized", cost: 11)
        cache.insert(6, for: "negative", cost: -1)
        #expect(cache.usage() == MemoryCacheUsage(bytes: 9, count: 1))
        cache.insert(7, for: "four", cost: 3)
        #expect(cache.usage() == MemoryCacheUsage(bytes: 3, count: 1))
        cache.removeAll()
        #expect(cache.usage() == MemoryCacheUsage(bytes: 0, count: 0))
    }

    @Test func parallelAccessKeepsBothLimitsAndClearingIsThreadSafe() async {
        let cache = BoundedMemoryCache<Int, Int>(byteLimit: 256, countLimit: 16)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<128 {
                group.addTask {
                    cache.insert(index, for: index, cost: 24)
                    _ = cache.value(for: index)
                    if index.isMultiple(of: 7) { cache.removeAll() }
                }
            }
            await group.waitForAll()
        }
        #expect(cache.usage().bytes <= 256 && cache.usage().count <= 16)
        cache.removeAll()
        #expect(cache.usage().count == 0)
    }

    @Test func clearingArtworkRejectsAResultStartedBeforeTheClearAndNewLoadsStillWork() async throws {
        let memory = BoundedMemoryCache<String, DecodedArtwork>(byteLimit: 1024 * 1024, countLimit: 8)
        let loader = SuspendedArtworkLoader()
        let cache = ArtworkCache(memory: memory, load: { _ in await loader.load() })
        let request = ArtworkRequest(url: URL(string: "https://i.ytimg.com/vi/abcDEF12_-3/mqdefault.jpg"), videoID: nil, pixels: 64)
        let pending = Task { await cache.image(for: request) }
        await loader.waitForRequest()
        await cache.clear()
        await loader.respond(try png())
        #expect(await pending.value == nil)
        #expect(memory.usage() == MemoryCacheUsage(bytes: 0, count: 0))
        let image = try #require(await cache.image(for: request))
        #expect(memory.usage().bytes == image.image.bytesPerRow * image.image.height)
        #expect(memory.usage().count == 1)
        _ = await cache.image(for: request)
        #expect(await loader.count == 2)
        await cache.clear()
        #expect(memory.usage().bytes == 0)
    }

    private func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
