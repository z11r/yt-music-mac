import MusicCore

extension LocalSongRuleField {
    var localizedTitle: String {
        switch self {
        case .title: AppLocalization.text("Title")
        case .artist: AppLocalization.text("Artist")
        case .album: AppLocalization.text("Album")
        case .duration: AppLocalization.text("Duration")
        case .explicit: AppLocalization.text("Explicit")
        }
    }
}

extension LocalSongRuleOperator {
    var localizedTitle: String {
        switch self {
        case .contains: AppLocalization.text("contains")
        case .doesNotContain: AppLocalization.text("does not contain")
        case .equals: AppLocalization.text("is")
        case .doesNotEqual: AppLocalization.text("is not")
        case .lessThan: AppLocalization.text("is less than")
        case .atMost: AppLocalization.text("is at most")
        case .greaterThan: AppLocalization.text("is greater than")
        case .atLeast: AppLocalization.text("is at least")
        case .isTrue: AppLocalization.text("is explicit")
        case .isFalse: AppLocalization.text("is not explicit")
        case .isUnknown: AppLocalization.text("is unknown")
        case .isKnown: AppLocalization.text("is known")
        }
    }
}

enum LocalSongRulePresentation {
    static func scopeDescription(_ value: LocalSongRuleSnapshot) -> String {
        var details: [String] = []
        if value.hasMorePages { details.append(AppLocalization.text("More source pages were available")) }
        if value.wasLoading { details.append(AppLocalization.text("Captured while source loading was in progress")) }
        if value.isTruncated { details.append(AppLocalization.text("Snapshot limited to the first 5,000 loaded rows")) }
        if value.hasUnsupportedContent { details.append(AppLocalization.text("The source included unsupported items")) }
        if value.unavailableCount > 0 { details.append(AppLocalization.format("%lld unavailable source rows", value.unavailableCount)) }
        if value.skippedCount > 0 { details.append(AppLocalization.format("%lld source rows could not be captured", value.skippedCount)) }
        return details.joined(separator: " · ")
    }
}
