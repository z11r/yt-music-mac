import MusicCore

extension RepeatMode {
    var localizedTitle: String {
        switch self {
        case .off: AppLocalization.text("Off")
        case .all: AppLocalization.text("All")
        case .one: AppLocalization.text("One")
        }
    }
}
