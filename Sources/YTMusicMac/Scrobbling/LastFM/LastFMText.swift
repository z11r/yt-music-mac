import Foundation

enum LastFMText {
    static func text(_ key: String, bundle: Bundle = AppIdentity.resourceBundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: "LastFM")
    }
    static func counts(ready: Int, uncertain: Int, refused: Int, ignored: Int, bundle: Bundle = AppIdentity.resourceBundle) -> String {
        String(format: text("Unsent: %ld. Uncertain: %ld. Refused: %ld. Ignored: %ld.", bundle: bundle),
               locale: Locale.autoupdatingCurrent, ready, uncertain, refused, ignored)
    }
}
