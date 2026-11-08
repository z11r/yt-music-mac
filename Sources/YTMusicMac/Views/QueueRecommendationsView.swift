import MusicCore
import SwiftUI

struct QueueRecommendationsView: View {
    let session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var accepting = false
    private var recommendations: QueueRecommendations { session.recommendations }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Queue Recommendations").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(recommendations.isLoading ? AppLocalization.text("Cancel") : AppLocalization.text("Done")) { recommendations.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(accepting)
            }
            Text("Read one page of YouTube Music radio for the current song, then choose songs to add at the end. Plain shuffle and existing queue entries keep their order.")
                .font(.callout).foregroundStyle(.secondary)
            if recommendations.isLoading {
                ProgressView("Reading song radio…")
            } else if let preview = recommendations.preview {
                Text(AppLocalization.format("Based on %@", preview.seed.title)).font(.headline)
                Text(preview.capturedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                if preview.tracks.isEmpty {
                    ContentUnavailableView("No New Song Recommendations", systemImage: "sparkles",
                        description: Text("This radio page offered no eligible songs outside your current queue."))
                } else {
                    List(preview.tracks, selection: $selection) { track in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.tag(track.id)
                    }
                    .accessibilityLabel("Recommended songs to add at the end")
                    HStack {
                        Button("Select All") { selection = Set(preview.tracks.map(\.id)) }.disabled(accepting)
                        Spacer()
                        Button("Add Selected to Queue End") {
                            let scope = recommendations.scope
                            let ids = selection
                            accepting = true
                            Task {
                                let accepted = await recommendations.accept(previewID: preview.id, selectedIDs: ids, expectedScope: scope)
                                accepting = false
                                if accepted { dismiss() }
                            }
                        }.disabled(selection.isEmpty || accepting || recommendations.isAccepting)
                    }
                }
            } else if let error = recommendations.errorMessage {
                InlineMessage(message: error)
                if recommendations.canRetry {
                    Button("Retry Radio Read") { recommendations.retry() }
                }
            } else {
                ContentUnavailableView("This Preview Is No Longer Current", systemImage: "arrow.clockwise",
                    description: Text("Open a new preview after changing accounts, playback, or queue entries."))
            }
            Spacer(minLength: 0)
            Text("Up to 20 songs from one radio page. Uploads, episodes, unknown music types, and songs already in this queue are excluded. Nothing is added until you choose Add Selected.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(minWidth: 580, idealWidth: 640, minHeight: 450, idealHeight: 540)
        .task { session.previewQueueRecommendations() }
        .onDisappear { recommendations.cancel() }
        .onChange(of: recommendations.preview?.id) { selection = [] }
    }
}
