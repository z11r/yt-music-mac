import Foundation
import Testing
@testable import YTMusicMac

@Suite("Startup window language resources")
struct StartupWindowLocalizationTests {
    @Test func englishAndFrenchTablesAreCompleteAndPlainProductCopy() throws {
        func table(_ language: String) throws -> (Bundle, [String: String]) {
            let folder = try #require(AppIdentity.resourceBundle.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: folder))
            let file = try #require(bundle.url(forResource: "StartupWindow", withExtension: "strings"))
            let values = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: String])
            return (bundle, values)
        }
        let (_, en) = try table("en"), (french, fr) = try table("fr")
        #expect(en.count == 14 && en.keys.sorted() == fr.keys.sorted())
        for value in en.values { #expect(!value.contains("executor") && !value.contains("bridge") && !value.contains("%@")) }
        #expect(french.localizedString(forKey: "No Startup Window", value: nil, table: "StartupWindow") == "Aucune fenêtre au démarrage")
        #expect(french.localizedString(forKey: "Use Default Startup and Quit", value: nil, table: "StartupWindow") == "Utiliser le démarrage par défaut et quitter")
    }
}
