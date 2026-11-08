import Foundation
import Testing
@testable import YTMusicMac

@Suite("Localized ListenBrainz presentation")
struct ListenBrainzLocalizationTests {
    @Test func countLabelsPreserveThreeIndependentNumericArguments() throws {
        let french = try frenchBundle()
        let key = "Unsent: %lld. Uncertain: %lld. Rejected: %lld."
        let format = french.localizedString(forKey: key, value: nil, table: "Localizable")
        let result = String(format: format, locale: Locale(identifier: "fr"), arguments: [Int64(1), Int64(2), Int64(0)])
        #expect(result == "Non envoyée : 1. Incertaines : 2. Rejetée : 0.")
        let reversed = String(format: format, locale: Locale(identifier: "fr"), arguments: [Int64(3), Int64(1), Int64(2)])
        #expect(reversed == "Non envoyées : 3. Incertaine : 1. Rejetées : 2.")
    }

    @Test func accountValuesAndDeliveryIdentifiersStayOpaqueAndErrorsHaveFrenchCopy() throws {
        var document = ListenBrainzDocument(profile: String(repeating: "a", count: 64))
        document.username = "Saved connection"
        let restored = try JSONDecoder().decode(ListenBrainzDocument.self, from: JSONEncoder().encode(document))
        #expect(restored.username == "Saved connection")
        #expect(restored.profile == String(repeating: "a", count: 64))
        #expect(ListenBrainzDeliveryState.uncertain.rawValue == "uncertain")
        let french = try frenchBundle()
        #expect(french.localizedString(forKey: "Saved connection", value: nil, table: "Localizable") == "Connexion enregistrée")
        let key = "This version of the local ListenBrainz data is not supported. Its file has been kept."
        #expect(french.localizedString(forKey: key, value: nil, table: "Localizable").contains("conservé"))
        #expect(french.localizedString(forKey: "ListenBrainz", value: nil, table: "Localizable") == "ListenBrainz")
    }

    private func frenchBundle() throws -> Bundle {
        let url = try #require(AppLocalization.bundle.url(forResource: "fr", withExtension: "lproj"))
        return try #require(Bundle(url: url))
    }
}
