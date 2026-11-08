import Foundation

/// Only native copy uses this lookup. Catalog titles and other service text
/// go directly to their views and never become localization keys.
enum AppLocalization {
    static let bundle: Bundle = AppIdentity.resourceBundle

    static func text(_ key: StaticString) -> String {
        bundle.localizedString(forKey: String(describing: key), value: nil, table: "Localizable")
    }

    static func format(_ key: StaticString, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.autoupdatingCurrent, arguments: arguments)
    }
}
