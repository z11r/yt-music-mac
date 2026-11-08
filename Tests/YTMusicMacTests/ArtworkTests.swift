import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import YTMusicMac

@Suite("Artwork sources and decoding")
struct ArtworkTests {
    private let base = "https://yt3.googleusercontent.com/g8bzAg2zxvdnm7ismLMYLA9-9azb4y6VP2uOF56A2G2rpsqLHT6mrJWXRKq"

    @Test func googleImageURLsAreRequestedAtTheDisplaySize() throws {
        let row = try #require(URL(string: base + "=w120-h120-l90-rj"))
        #expect(ArtworkSource.resized(row, pixels: 72).absoluteString == base + "=w120-h120-l90-rj")
        #expect(ArtworkSource.resized(row, pixels: 128).absoluteString == base + "=w226-h226-l90-rj")
        #expect(ArtworkSource.resized(row, pixels: 352).absoluteString == base + "=w360-h360-l90-rj")
        let card = try #require(URL(string: base + "=w544-h544-l90-rj"))
        #expect(ArtworkSource.resized(card, pixels: 80).absoluteString == base + "=w120-h120-l90-rj")
    }

    @Test func nonSquareGoogleImagesKeepTheirShape() throws {
        let banner = try #require(URL(string: base + "=w540-h225-p-l90-rj"))
        #expect(ArtworkSource.resized(banner, pixels: 352).absoluteString == base + "=w864-h360-p-l90-rj")
        let avatar = try #require(URL(string: "https://yt3.ggpht.com/abc=s88-c-k-c0x00ffffff-no-rj"))
        #expect(ArtworkSource.resized(avatar, pixels: 100).absoluteString
            == "https://yt3.ggpht.com/abc=s120-c-k-c0x00ffffff-no-rj")
    }

    @Test func unknownImageURLsAreLeftAlone() throws {
        for value in ["https://example.com/a=w60-h60", "https://lh3.googleusercontent.com/abc",
                      "https://lh3.googleusercontent.com/abc=w60-h60?x=1"] {
            let url = try #require(URL(string: value))
            #expect(ArtworkSource.resized(url, pixels: 300) == url)
        }
    }

    @Test func videoFramesUseBarFreeSizesFirst() throws {
        let url = try #require(URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/sddefault.jpg?sqp=abc&rs=def"))
        let small = ArtworkSource.candidates(url: url, videoID: nil, pixels: 128)
        #expect(small.map(\.url.lastPathComponent) == ["mqdefault.jpg", "hqdefault.jpg", "sddefault.jpg"])
        #expect(small.map(\.isLetterboxed) == [false, true, true])
        #expect(small.allSatisfy { $0.url.query == nil && $0.url.path.hasPrefix("/vi/dQw4w9WgXcQ/") })
        let large = ArtworkSource.candidates(url: url, videoID: nil, pixels: 512)
        #expect(large.map(\.url.lastPathComponent) == ["hq720.jpg", "sddefault.jpg", "hqdefault.jpg"])
    }

    @Test func missingArtworkFallsBackToTheVideoFrame() {
        let sources = ArtworkSource.candidates(url: nil, videoID: "dQw4w9WgXcQ", pixels: 80)
        #expect(sources.first?.url.absoluteString == "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg")
        #expect(ArtworkSource.candidates(url: nil, videoID: "not a video", pixels: 80).isEmpty)
        #expect(ArtworkSource.candidates(url: nil, videoID: "../../x/abcd", pixels: 80).isEmpty)
        #expect(ArtworkSource.candidates(url: nil, videoID: nil, pixels: 80).isEmpty)
    }

    @Test func cropKeepsTheCentredSquareInsideTheLetterbox() {
        // Bars are 45 px; the 270 px picture keeps a 3 px margin.
        #expect(ArtworkDecoder.cropRect(width: 480, height: 360, letterboxed: true)
            == CGRect(x: 108, y: 48, width: 264, height: 264))
        #expect(ArtworkDecoder.cropRect(width: 480, height: 360, letterboxed: false)
            == CGRect(x: 60, y: 0, width: 360, height: 360))
        #expect(ArtworkDecoder.cropRect(width: 1280, height: 720, letterboxed: false)
            == CGRect(x: 280, y: 0, width: 720, height: 720))
        // A square source is never trimmed, even when the URL suggested bars.
        #expect(ArtworkDecoder.cropRect(width: 544, height: 544, letterboxed: true)
            == CGRect(x: 0, y: 0, width: 544, height: 544))
    }

    @Test func wideArtworkIsCroppedNotSquashed() throws {
        // 16:9 with a blue stripe at the far left; a centre crop removes it.
        let data = try png(width: 160, height: 90) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 90))
        }
        let image = try #require(ArtworkDecoder.squareImage(from: data, pixels: 64, letterboxed: false))
        #expect(image.width == 64 && image.height == 64)
        #expect(try color(of: image, x: 1, y: 32) == .white)
    }

    @Test func letterboxBarsAreRemoved() throws {
        // 4:3 frame with black bars above and below a white 16:9 picture.
        let data = try png(width: 480, height: 360) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 45))
            context.fill(CGRect(x: 0, y: 315, width: 480, height: 45))
        }
        let image = try #require(ArtworkDecoder.squareImage(from: data, pixels: 128, letterboxed: true))
        #expect(image.width == 128 && image.height == 128)
        #expect(try color(of: image, x: 64, y: 0) == .white)
        #expect(try color(of: image, x: 64, y: 127) == .white)
    }

    @Test func smallSourcesAreNotUpscaled() throws {
        let data = try png(width: 120, height: 120) { _ in }
        let image = try #require(ArtworkDecoder.squareImage(from: data, pixels: 256, letterboxed: false))
        #expect(image.width == 120 && image.height == 120)
    }

    @Test func undecodableDataIsRejected() {
        #expect(ArtworkDecoder.squareImage(from: Data("not an image".utf8), pixels: 64, letterboxed: false) == nil)
    }

    // MARK: - Helpers

    private enum Shade: Equatable { case white, black, blue, other }

    /// A white PNG drawn with a top-left origin.
    private func png(width: Int, height: Int, draw: (CGContext) -> Void) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData,
                                                                        UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The shade of one pixel, with `y` measured from the top.
    private func color(of image: CGImage, x: Int, y: Int) throws -> Shade {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        switch (pixel[0], pixel[1], pixel[2]) {
        case let (r, g, b) where r > 200 && g > 200 && b > 200: return .white
        case let (r, g, b) where r < 50 && g < 50 && b < 50: return .black
        case let (r, g, b) where r < 50 && g < 50 && b > 200: return .blue
        default: return .other
        }
    }
}
