import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

@Suite("Loaded collection summaries") @MainActor
struct CollectionLoadedSummaryTests {
    @Test func duplicatesAndUnknownDurationsRemainDistinctFromServiceSummaryAndFiltering() {
        let song = Track(id: "same", title: "Repeated", artist: "Artist", duration: 280)
        let unknown = Track(id: "unknown", title: "Unknown", artist: "Artist")
        var invalid = Track(id: "invalid", title: "Invalid", artist: "Artist"); invalid.duration = -.infinity
        let page = MusicPage(title: "Playlist", sections: [], items: [song, song, unknown, invalid].map(MusicItem.track),
            unavailableItemCount: 1, collectionHeader: .init(summary: "100 songs • 5 hours"))
        let summary = CollectionLoadedSummary(page: page)
        #expect(summary.playableCount == 4 && summary.knownSeconds == 560 && summary.unknownDurationCount == 2)
        #expect(!summary.isComplete)
        #expect(CollectionPresentation.rows(in: page, matching: "Unknown", order: .serviceOrder).count == 1)
        #expect(summary.durationDescription?.contains("9:20") == true)
        #expect(page.collectionHeader?.summary == "100 songs • 5 hours")
    }

    @Test func emptyAndUnsupportedPagesDoNotInventAnExactCollectionDuration() {
        let empty = CollectionLoadedSummary(page: .init(title: "Empty", sections: [], items: []))
        #expect(empty.playableCount == 0 && empty.durationDescription == nil && empty.isComplete)
        let unknown = CollectionLoadedSummary(page: .init(title: "Unknown", sections: [], items: [
            .track(.init(id: "live", title: "Live", artist: "Artist", duration: 0))
        ], hasUnsupportedContent: true))
        #expect(!unknown.isComplete && unknown.unknownDurationCount == 1 && unknown.knownSeconds == 0)
        #expect(unknown.durationDescription == AppLocalization.text("Loaded duration unknown"))
        #expect(unknown.countDescription(episodes: true) == AppLocalization.format("%lld episodes loaded", 1))
    }

    @Test func hugeDurationSumsSaturateSafelyAndNeverBecomeAFalseShortTime() {
        let track = Track(id: "long", title: "Long", artist: "Artist", duration: .greatestFiniteMagnitude)
        let summary = CollectionLoadedSummary(page: .init(title: "Long", sections: [], items: [.track(track), .track(track)]))
        #expect(summary.knownSeconds.isFinite && summary.unknownDurationCount == 0)
        #expect(summary.durationDescription == AppLocalization.format("Loaded playable duration: %@", AppLocalization.text("more than 999 hours")))
    }

    @Test func unknownDurationPluralRetainsTheOpaqueTimeInBothLanguages() throws {
        for language in ["en", "fr"] {
            let path = try #require(AppLocalization.bundle.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            let format = bundle.localizedString(forKey: "At least %@ loaded · %lld durations unknown", value: nil, table: "Localizable")
            let result = String(format: format, locale: Locale(identifier: language), arguments: ["9:20", Int64(1)])
            #expect(result.contains("9:20"))
            #expect(result.contains(language == "fr" ? "1 durée inconnue" : "1 duration unknown"))
        }
    }
}
