import Foundation
import XCTest
@testable import YouTubeMusic

final class MusicLinkTests: XCTestCase {
    func testSupportedLinksCanonicalizeWithoutTracking() throws {
        let cases: [(String, MusicLink, String)] = [
            ("https://youtu.be/abcDEF12_-3?si=tracking", .track("abcDEF12_-3"), "https://music.youtube.com/watch?v=abcDEF12_-3"),
            ("https://www.youtube.com/watch?v=abcDEF12_-3&list=PLexample&t=30", .track("abcDEF12_-3"), "https://music.youtube.com/watch?v=abcDEF12_-3"),
            ("https://music.youtube.com/browse/VLPLexample", .playlist("PLexample"), "https://music.youtube.com/playlist?list=PLexample"),
            ("https://music.youtube.com/browse/MPREexample", .album("MPREexample"), "https://music.youtube.com/browse/MPREexample"),
            ("https://music.youtube.com/playlist?list=OLAKexample", .album("OLAKexample"), "https://music.youtube.com/playlist?list=OLAKexample"),
            ("https://music.youtube.com/channel/UCexample", .artist("UCexample"), "https://music.youtube.com/channel/UCexample"),
            ("ytmusicmac://watch?v=abcDEF12_-3", .track("abcDEF12_-3"), "https://music.youtube.com/watch?v=abcDEF12_-3"),
            ("ytmusicmac-debug://playlist?list=PLexample", .playlist("PLexample"), "https://music.youtube.com/playlist?list=PLexample"),
        ]
        for (input, expected, canonical) in cases {
            let parsed = try XCTUnwrap(MusicLink(url: XCTUnwrap(URL(string: input))))
            XCTAssertEqual(parsed, expected)
            XCTAssertEqual(parsed.url?.absoluteString, canonical)
            XCTAssertEqual(parsed.url.flatMap(MusicLink.init(url:)), parsed)
        }
    }

    func testUntrustedOrAmbiguousLinksAreRejected() throws {
        for input in [
            "http://music.youtube.com/watch?v=abcDEF12_-3",
            "https://music.youtube.com.evil.test/watch?v=abcDEF12_-3",
            "https://music.youtube.com@evil.test/watch?v=abcDEF12_-3",
            "https://user:password@music.youtube.com/watch?v=abcDEF12_-3",
            "https://music.youtube.com:444/watch?v=abcDEF12_-3",
            "https://music.youtube.com/watch?v=abcDEF12_-3&v=other123456",
            "https://music.youtube.com/playlist?list=PLone&list=PLtwo",
            "https://music.youtube.com/playlist?list=VL",
            "https://music.youtube.com/channel/UCexample/extra",
            "https://music.youtube.com/browse/MPRE%2Fexample",
            "https://youtu.be/abcDEF12_-3/extra",
            "ytmusicmac://watch:123?v=abcDEF12_-3",
            "file:///watch?v=abcDEF12_-3",
            "javascript:alert(1)",
        ] {
            XCTAssertNil(MusicLink(url: try XCTUnwrap(URL(string: input))), input)
        }
    }

    func testShareURLsRejectInvalidIdentifiers() {
        XCTAssertNil(MusicLink.track("short").url)
        XCTAssertNil(MusicLink.playlist("VL").url)
        XCTAssertNil(MusicLink.album("../private").url)
        XCTAssertNil(MusicLink.artist("bad/id").url)
        XCTAssertEqual(MusicLink.playlist("VLPLexample").url?.absoluteString,
                       "https://music.youtube.com/playlist?list=PLexample")
    }
}
