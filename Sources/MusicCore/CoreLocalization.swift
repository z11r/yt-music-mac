import Foundation

enum CoreLocalization {
    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "YTMusicMac_MusicCore", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    static func text(_ key: StaticString) -> String {
        bundle.localizedString(forKey: String(describing: key), value: nil, table: "Localizable")
    }

    static func format(_ key: StaticString, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.autoupdatingCurrent, arguments: arguments)
    }
}
