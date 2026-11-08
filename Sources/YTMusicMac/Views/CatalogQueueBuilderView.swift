import SwiftUI

struct CatalogQueueBuilderView: View {
    let session: AppSession
    @State private var builder: CatalogQueueBuilder
    @State private var selected = Set<String>()
    @State private var name = ""
    @Environment(\.dismissWindow) private var dismissWindow

    init(session: AppSession) {
        self.session = session
        _builder = State(initialValue: session.makeCatalogQueueBuilder())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(QueueBuilderCopy.text("Build a Queue from Searches")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(QueueBuilderCopy.text("Done")) { builder.cancel(); dismissWindow(id: "catalog-queue-builder") }
                    .keyboardShortcut(.cancelAction)
            }
            Text(QueueBuilderCopy.text("Enter up to five search phrases, one per line. Review real catalog results before adding songs or saving a local queue."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if builder.review == nil {
                TextEditor(text: Binding(get: { builder.input }, set: { builder.edit($0) }))
                    .font(.body).frame(height: 95)
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary).allowsHitTesting(false) }
                    .accessibilityLabel(QueueBuilderCopy.text("Catalog search phrases"))
                    .disabled(builder.isSaving)
                HStack {
                    Button(QueueBuilderCopy.text("Search Catalog")) { selected = []; builder.search() }
                        .disabled(builder.isBusy || session.catalogQueueOwner == nil)
                    if builder.isLoading {
                        ProgressView().controlSize(.small)
                        Text(QueueBuilderCopy.text("Completed searches:") + " \(builder.completedQueries)").font(.caption)
                        Button(QueueBuilderCopy.text("Cancel Search")) { builder.cancel(clearInput: false) }
                    } else if builder.isBusy {
                        Text(QueueBuilderCopy.text("Waiting for the previous operation to finish…")).font(.caption)
                    }
                }
            } else {
                Button(QueueBuilderCopy.text("Edit Search Phrases")) { builder.cancel(clearInput: false); selected = [] }
                    .disabled(builder.isBusy)
            }
            if let review = builder.review {
                results(review)
            } else {
                ContentUnavailableView(QueueBuilderCopy.text("Review Catalog Songs"), systemImage: "music.note.list",
                    description: Text(QueueBuilderCopy.text("Searches do not change playback or your current queue.")))
            }
            if let message = builder.message { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true) }
            Text(QueueBuilderCopy.text("Each phrase reads one song-results page. Up to 20 songs per phrase are interleaved into at most 50 unique songs. Results may be incomplete and do not verify mood or genre matches."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(minWidth: 650, idealWidth: 740, minHeight: 620, idealHeight: 740)
        .onDisappear { builder.cancel() }
        .onChange(of: session.accountGeneration) { clear() }
        .onChange(of: session.links.generation) { clear() }
        .onChange(of: session.isProfileSuspended) { if session.isProfileSuspended { clear() } }
        .onChange(of: session.queue.revision) { builder.cancel(clearInput: false); selected = [] }
        .onChange(of: builder.review?.id) { selected = [] }
    }

    private func results(_ review: CatalogQueueReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(QueueBuilderCopy.text("Search Coverage")) {
                ForEach(Array(review.reports.enumerated()), id: \.offset) { _, report in
                    HStack {
                        Text(verbatim: report.query).lineLimit(2)
                        Spacer()
                        if report.incomplete { Text(QueueBuilderCopy.text("Partial results")).foregroundStyle(.secondary) }
                    }.font(.caption)
                }
            }
            if review.rows.isEmpty {
                ContentUnavailableView(QueueBuilderCopy.text("No Eligible Songs"), systemImage: "music.note",
                    description: Text(QueueBuilderCopy.text("These result pages offered no songs with supported metadata. Try more specific search phrases.")))
            } else {
                List(review.rows, selection: $selected) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.track.title).lineLimit(1)
                        Text(row.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(row.queries.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(row.id)
                }.accessibilityLabel(QueueBuilderCopy.text("Catalog songs to select"))
            }
            HStack {
                Button(QueueBuilderCopy.text("Select All")) { selected = Set(review.rows.map(\.id)) }
                Button(QueueBuilderCopy.text("Clear Selection")) { selected = [] }
                Spacer()
                Button(QueueBuilderCopy.text("Add Selected to Queue End")) { accept(review, name: nil) }
                    .disabled(selected.isEmpty || builder.isBusy || session.queue.entries.count + selected.count > 10_000)
            }
            Divider()
            HStack {
                TextField(QueueBuilderCopy.text("Local queue name"), text: $name)
                Button(QueueBuilderCopy.text("Save Selected as Local Queue")) { accept(review, name: name) }
                    .disabled(!session.account.isSignedIn || selected.isEmpty || name.isEmpty || builder.isBusy)
            }
            Text(QueueBuilderCopy.text("Local saved queues require sign-in and stay in this app profile. This action does not create a YouTube Music playlist or start playback."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.disabled(builder.isSaving)
    }
    private func accept(_ review: CatalogQueueReview, name: String?) {
        let ids = selected
        Task { _ = await builder.accept(reviewID: review.id, selectedIDs: ids, name: name) }
    }
    private func clear() { builder.cancel(); selected = []; name = "" }
}
