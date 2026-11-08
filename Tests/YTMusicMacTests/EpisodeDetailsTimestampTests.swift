import Testing
@testable import YTMusicMac

struct EpisodeDetailsTimestampTests {
    @Test func episodeTimestampFormattingRetainsAllAdmittedWholeSeconds() {
        let cases: [(Int, String)] = [
            (0, "0:00"), (59, "0:59"), (60, "1:00"), (3_599, "59:59"), (3_600, "1:00:00"),
            (359_999, "99:59:59"), (360_000, "100:00:00"), (604_800, "168:00:00")
        ]
        for (seconds, expected) in cases {
            #expect(EpisodeDetailsTimestampFormatter.text(seconds) == expected)
        }
    }
    @Test func outOfRangeSourcePositionsStayUnknownRatherThanClamping() {
        for seconds in [Int.min, -1, 604_801, Int.max] {
            #expect(EpisodeDetailsTimestampFormatter.text(seconds) == nil)
        }
    }
}
