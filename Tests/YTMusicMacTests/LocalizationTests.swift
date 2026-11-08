import Foundation
import Testing
@testable import MusicCore
@testable import YouTubeMusic
@testable import YTMusicMac

@Suite("Localization resources")
struct LocalizationTests {
    @Test func everyModuleHasBothLanguageResourcesWithoutChangingPreferences() throws {
        for bundle in [AppLocalization.bundle, CoreLocalization.bundle, ServiceLocalization.bundle] {
            for language in ["en", "fr"] {
                let localized = try languageBundle(language, in: bundle)
                #expect(localized.url(forResource: "Localizable", withExtension: "strings") != nil)
            }
        }
        let french = try languageBundle("fr", in: AppLocalization.bundle)
        #expect(french.localizedString(forKey: "Play", value: nil, table: "Localizable") == "Lire")
        let service = try languageBundle("fr", in: ServiceLocalization.bundle)
        #expect(service.localizedString(forKey: "Sign in to view your library.", value: nil, table: "Localizable") ==
                "Connectez-vous pour consulter votre bibliothèque.")
    }

    @Test func translatedFormatsPreserveOpaqueServiceTitlesAndNumericArguments() throws {
        let french = try languageBundle("fr", in: AppLocalization.bundle)
        let key = "Results for “%@”"
        let title = "Home %lld %@ — مقطوعة"
        let result = String(format: french.localizedString(forKey: key, value: nil, table: "Localizable"),
                            locale: Locale(identifier: "fr"), arguments: [title])
        // Foundation may add directional-isolation marks around a mixed-script
        // argument. The catalog metadata itself must stay byte-for-byte intact.
        #expect(result.contains(title))
        let visible = result.replacingOccurrences(of: "\u{2068}", with: "").replacingOccurrences(of: "\u{2069}", with: "")
        #expect(visible == "Résultats pour « \(title) »")
        let core = try languageBundle("fr", in: CoreLocalization.bundle)
        let version = String(format: core.localizedString(forKey: "Saved queue version %lld is not supported.", value: nil, table: "Localizable"),
                             locale: Locale(identifier: "fr"), arguments: [Int64(42)])
        #expect(version.contains("42"))
        #expect(!version.contains("%lld"))
    }

    @Test func englishAndFrenchTablesKeepKeysAndFormatArgumentTypes() throws {
        for bundle in [AppLocalization.bundle, CoreLocalization.bundle, ServiceLocalization.bundle] {
            let english = try strings(in: languageBundle("en", in: bundle))
            let french = try strings(in: languageBundle("fr", in: bundle))
            #expect(Set(english.keys) == Set(french.keys))
            for key in english.keys {
                #expect(try placeholders(english[key]!) == placeholders(french[key]!))
            }
        }
    }

    @Test func pluralTablesContainCompleteMatchingNumericRules() throws {
        for language in ["en", "fr"] {
            let bundle = try languageBundle(language, in: AppLocalization.bundle)
            let url = try #require(bundle.url(forResource: "Localizable", withExtension: "stringsdict"))
            let root = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
            let entry = try #require(root["%lld songs"] as? [String: Any])
            let rule = try #require(entry["songs"] as? [String: String])
            #expect(entry["NSStringLocalizedFormatKey"] as? String == "%#@songs@")
            #expect(rule["NSStringFormatValueTypeKey"] == "lld")
            #expect(rule["one"] != nil)
            #expect(rule["other"] != nil)
            let format = bundle.localizedString(forKey: "%lld songs", value: nil, table: "Localizable")
            let singular = String(format: format, locale: Locale(identifier: language), arguments: [Int64(1)])
            let plural = String(format: format, locale: Locale(identifier: language), arguments: [Int64(2)])
            #expect(singular == (language == "fr" ? "1 titre" : "1 song"))
            #expect(plural == (language == "fr" ? "2 titres" : "2 songs"))
        }
    }

    private func languageBundle(_ language: String, in bundle: Bundle) throws -> Bundle {
        let url = try #require(bundle.url(forResource: language, withExtension: "lproj"))
        return try #require(Bundle(url: url))
    }
    private func strings(in bundle: Bundle) throws -> [String: String] {
        let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }
    private func placeholders(_ text: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?(?:lld|ld|d|u|@|f|g)"#)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range, in: text)!]) }.sorted()
    }
}
