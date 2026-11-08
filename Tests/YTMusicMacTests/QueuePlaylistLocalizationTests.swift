import Foundation
import Testing
@testable import MusicCore
@testable import YTMusicMac

@Suite("Localized queue playlist review")
struct QueuePlaylistLocalizationTests {
    @Test func entryCountsUseTheTotalArgumentForSingularAndPlural() throws {
        let bundle = try french(AppLocalization.bundle)
        func format(_ key: String, _ args: CVarArg...) -> String {
            String(format: bundle.localizedString(forKey: key, value: nil, table: "Localizable"),
                   locale: Locale(identifier: "fr"), arguments: args)
        }
        #expect(format("%lld entries", Int64(1)) == "1 élément")
        #expect(format("%lld entries", Int64(2)) == "2 éléments")
        #expect(format("%lld of %lld entries", Int64(1), Int64(2)) == "1 sur 2 éléments")
        #expect(format("%lld of %lld entries", Int64(1), Int64(1)) == "1 sur 1 élément")
        let confirmed = "%lld of %lld song entries confirmed · Last recorded %@"
        #expect(format(confirmed, Int64(1), Int64(1), "8 novembre") ==
                "1 sur 1 entrée de titre confirmée · Dernier enregistrement : 8 novembre")
        #expect(format(confirmed, Int64(1), Int64(2), "8 novembre") ==
                "1 sur 2 entrées de titres confirmées · Dernier enregistrement : 8 novembre")
        #expect(format("%lld reviewed song entries · Requested privacy: Private", Int64(1)) ==
                "1 entrée de titre examinée · Confidentialité demandée : privée")
    }

    @Test func nativeErrorsDoNotChangeTheReviewedMetadataOrJournalSchema() throws {
        let song = QueuePlaylistPlan.Song(id: UUID(), videoID: "abcDEF12_-3", title: "Save Queue as Playlist", artist: "Artist")
        let plan = try QueuePlaylistPlan(title: "Private", createdAt: Date(timeIntervalSince1970: 1_700_000_000), songs: [song])
        let decoded = try JSONDecoder().decode(QueuePlaylistPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded.title == "Private" && decoded.songs.first?.title == "Save Queue as Playlist")
        #expect(decoded.songs.first?.videoID == "abcDEF12_-3")
        let core = try french(CoreLocalization.bundle)
        let podcast = "Saving podcast episodes to a music playlist is not verified. Save this queue locally instead."
        #expect(core.localizedString(forKey: podcast, value: nil, table: "Localizable").contains("épisodes de podcast"))
        let version = "Pending playlist-save version %lld is unsupported. Its file has been kept."
        let text = String(format: core.localizedString(forKey: version, value: nil, table: "Localizable"),
                          locale: Locale(identifier: "fr"), arguments: [Int64(42)])
        #expect(text.contains("42") && text.contains("conservé"))
    }

    private func french(_ bundle: Bundle) throws -> Bundle {
        let url = try #require(bundle.url(forResource: "fr", withExtension: "lproj"))
        return try #require(Bundle(url: url))
    }
}
