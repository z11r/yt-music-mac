import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@Suite("Local library localization")
struct LocalAudioLibraryLocalizationTests {
    @Test func completeTablesPreserveFormatGrammarAndFrenchControls() throws {
        let en = try language("en"), fr = try language("fr")
        func strings(_ bundle: Bundle) throws -> [String: String] {
            let url = try #require(bundle.url(forResource: "LocalAudioLibrary", withExtension: "strings"))
            return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        }
        let english = try strings(en), french = try strings(fr)
        #expect(english.count >= 44 && english.keys.sorted() == french.keys.sorted())
        let regex = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|@)"#)
        for key in english.keys {
            func tokens(_ value: String) -> [String] {
                regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { (value as NSString).substring(with: $0.range) }.sorted()
            }
            #expect(tokens(english[key]!) == tokens(french[key]!))
        }
        #expect(fr.localizedString(forKey: "Save Selected Locations", value: nil, table: "LocalAudioLibrary") == "Enregistrer les emplacements sélectionnés")
        #expect(fr.localizedString(forKey: "Locate or Reauthorize…", value: nil, table: "LocalAudioLibrary") == "Localiser ou autoriser à nouveau…")
        for key in ["%lld local files", "%lld files selected"] {
            let format = fr.localizedString(forKey: key, value: nil, table: "LocalAudioLibrary")
            let one = String(format: format, locale: Locale(identifier: "fr"), arguments: [Int64(1)])
            let many = String(format: format, locale: Locale(identifier: "fr"), arguments: [Int64(2)])
            #expect(one.contains("1 fichier") && !one.contains("fichiers"))
            #expect(many.contains("2 fichiers"))
        }
    }

    @Test func metadataStaysOpaqueAndProviderErrorsStayBounded() throws {
        let metadata = LocalAudioMetadata(title: "Reload %@ العربية", artist: "Local Audio", album: "Save Selected Locations", duration: 60, byteCount: 1)
        let track = try metadata.track(reference: .init(libraryID: UUID(), fileID: UUID()))
        #expect(track.title == metadata.title && track.artist == metadata.artist && track.album == metadata.album)
        let hidden = NSError(domain: "/private/file.wav", code: 12, userInfo: [NSLocalizedDescriptionKey: "secret location"])
        #expect(LocalAudioLibraryIssue.mapped(hidden) == .unsupportedAudio)
        for issue in LocalAudioLibraryIssue.allCases {
            #expect(issue.message.utf8.count < 1_024 && !issue.message.contains("/private/"))
        }
    }

    private func language(_ value: String) throws -> Bundle {
        let url = try #require(AppLocalization.bundle.url(forResource: value, withExtension: "lproj"))
        return try #require(Bundle(url: url))
    }
}
