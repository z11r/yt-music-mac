import Foundation
@testable import MusicCore
import Testing
@testable import YTMusicMac

@Suite("Localized local song-rule presentation")
struct LocalSongRuleLocalizationTests {
    @Test func frenchCountMessagesPreserveOpaqueSourceNamesAndAllArguments() throws {
        let bundle = try frenchBundle(AppLocalization.bundle)
        let key = "%lld song entries from “%@” · %@"
        let sourceName = "Local Song Rules · مقطوعة %lld"
        let date = "8 novembre"
        let format = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
        let one = String(format: format, locale: Locale(identifier: "fr"), arguments: [Int64(1), sourceName, date])
        #expect(one.hasPrefix("1 entrée de titre"))
        #expect(one.contains(sourceName) && one.contains(date))
        let plural = String(format: format, locale: Locale(identifier: "fr"), arguments: [Int64(2), sourceName, date])
        #expect(plural.hasPrefix("2 entrées de titres"))
        let counts: [(String, String, String)] = [
            ("%lld matching captured songs", "1 titre capturé correspondant", "2 titres capturés correspondants"),
            ("%lld unavailable source rows", "1 ligne de la source indisponible", "2 lignes de la source indisponibles"),
            ("%lld source rows could not be captured", "1 ligne de la source n’a pas pu être capturée", "2 lignes de la source n’ont pas pu être capturées"),
            ("Loaded snapshot only · %lld results unknown because metadata is missing",
             "Instantané chargé uniquement · 1 résultat inconnu faute de métadonnées",
             "Instantané chargé uniquement · 2 résultats inconnus faute de métadonnées"),
        ]
        for (key, one, other) in counts {
            let format = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            #expect(String(format: format, locale: Locale(identifier: "fr"), arguments: [Int64(1)]) == one)
            #expect(String(format: format, locale: Locale(identifier: "fr"), arguments: [Int64(2)]) == other)
        }
    }

    @Test func nativeCopyDoesNotTranslateRuleSchemaOrCapturedMetadata() throws {
        let clause = LocalSongRuleClause(field: .duration, operation: .atLeast, number: 180)
        let encoded = try JSONEncoder().encode(clause)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["field"] as? String == "duration")
        #expect(json["operation"] as? String == "atLeast")
        let song = LocalSongRuleSong(videoID: "abcDEF12_-3", title: "Title", artist: "Artist")
        let snapshot = LocalSongRuleSnapshot(capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceName: "Local Song Rules", songs: [song], hasMorePages: true, wasLoading: true,
            unavailableCount: 1, hasUnsupportedContent: true, isTruncated: true, skippedCount: 2)
        let summary = LocalSongRulePresentation.scopeDescription(snapshot)
        #expect(summary.components(separatedBy: " · ").count == 6)
        #expect(snapshot.sourceName == "Local Song Rules" && snapshot.songs.first?.title == "Title")
        #expect(snapshot.songs.first?.artist == "Artist")
    }

    @Test func frenchFieldsConditionsAndVersionErrorsHaveNativeTranslations() throws {
        let app = try frenchBundle(AppLocalization.bundle)
        #expect(app.localizedString(forKey: "Duration", value: nil, table: "Localizable") == "Durée")
        #expect(app.localizedString(forKey: "does not contain", value: nil, table: "Localizable") == "ne contient pas")
        #expect(app.localizedString(forKey: "Unknown artist", value: nil, table: "Localizable") == "Artiste inconnu")
        let core = try frenchBundle(CoreLocalization.bundle)
        let key = "Local song-rule version %lld is not supported. Its file has been kept."
        let message = String(format: core.localizedString(forKey: key, value: nil, table: "Localizable"),
                             locale: Locale(identifier: "fr"), arguments: [Int64(42)])
        #expect(message.contains("42") && message.contains("conservé"))
    }

    private func frenchBundle(_ bundle: Bundle) throws -> Bundle {
        let url = try #require(bundle.url(forResource: "fr", withExtension: "lproj"))
        return try #require(Bundle(url: url))
    }
}
