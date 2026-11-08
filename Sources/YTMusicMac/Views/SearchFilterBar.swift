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
        self == .all ? "Shows every kind of result" : "Shows only \(title.lowercased()) in the results"
    }

    var title: String {
        switch self {
        case .all: "All"
        case .songs: "Songs"
        case .videos: "Videos"
        case .albums: "Albums"
        case .artists: "Artists"
        case .communityPlaylists: "Community Playlists"
        case .featuredPlaylists: "Featured Playlists"
        }
    }
}
