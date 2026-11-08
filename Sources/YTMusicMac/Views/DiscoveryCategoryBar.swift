import SwiftUI
import YouTubeMusic

struct DiscoveryCategoryBar: View {
    let session: AppSession

    var body: some View {
        Picker("Explore", selection: Binding(get: { session.destination }, set: { session.navigate(to: $0) })) {
            Text("Featured").tag(MusicDestination.explore)
            ForEach(MusicDiscoveryCategory.allCases, id: \.self) { category in
                Text(category.title).tag(MusicDestination.discovery(category))
            }
        }
        .pickerStyle(.segmented).fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Discovery category")
    }
}
