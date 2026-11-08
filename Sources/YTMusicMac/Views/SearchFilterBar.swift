import AppKit
import SwiftUI
import YouTubeMusic

/// Chips that limit search results to one kind. The chosen filter stays for later searches.
struct SearchFilterBar: View {
    @Bindable var session: AppSession

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(MusicSearchFilter.allCases, id: \.self) { filter in
                    SearchFilterChip(title: filter.title, hint: filter.hint, isSelected: session.searchFilter == filter) {
                        session.searchFilter = filter
                    }
                }
            }
            .padding(4)
        }
        .scrollIndicators(.never)
        .padding(.horizontal, -4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search filters")
    }
}

private struct SearchFilterChip: View {
    let title: String
    let hint: String
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
                .background {
                    Capsule().fill(isSelected ? Color(nsColor: .controlAccentColor) : Color.primary.opacity(0.08))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .overlay {
            if isFocused {
                Capsule()
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(hint)
    }
}

extension MusicSearchFilter {
    var hint: String {
        self == .all ? AppLocalization.text("Shows every kind of result")
            : AppLocalization.format("Shows only %@ in the results", title)
    }

    var title: String {
        switch self {
        case .all: AppLocalization.text("All")
        case .songs: AppLocalization.text("Songs")
        case .videos: AppLocalization.text("Videos")
        case .albums: AppLocalization.text("Albums")
        case .artists: AppLocalization.text("Artists")
        case .communityPlaylists: AppLocalization.text("Community Playlists")
        case .featuredPlaylists: AppLocalization.text("Featured Playlists")
        }
    }
}
