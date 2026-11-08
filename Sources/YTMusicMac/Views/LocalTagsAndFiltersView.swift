import MusicCore
import SwiftUI
import YouTubeMusic

struct LocalTagsAndFiltersView: View {
    let session: AppSession
    var onApply: () -> Void = { }
    @Environment(\.dismiss) private var dismiss
    @State private var displayedScope: UUID
    @State private var selectedTag: UUID?
    @State private var tagName = ""
    @State private var selectedFilter: UUID?
    @State private var filterName = ""
    @State private var criteria = LocalCollectionFilterCriteria()
    @State private var deletesTag = false
    @State private var deletesFilter = false

    init(session: AppSession, onApply: @escaping () -> Void = { }) {
        self.session = session
        self.onApply = onApply
        _displayedScope = State(initialValue: session.localCollections.scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Local Tags and Saved Filters").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Stored on this Mac for this account. Filters match library collections currently loaded; Load More includes more collections.")
                .font(.callout).foregroundStyle(.secondary)
            if session.account.isSignedIn && session.localCollections.scope == displayedScope {
                TabView {
                    tags.tabItem { Label("Local Tags", systemImage: "tag") }
                    filters.tabItem { Label("Saved Filters", systemImage: "line.3.horizontal.decrease.circle") }
                }
                .disabled(session.localCollections.isWorking)
            } else {
                ContentUnavailableView("Sign In to Organize Collections", systemImage: "person.crop.circle")
            }
            if let error = session.localCollections.errorMessage { InlineMessage(message: error) }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 470, idealHeight: 510)
        .onChange(of: session.localCollections.scope) { dismiss() }
        .onChange(of: selectedTag) {
            tagName = session.localCollections.organization.tags.first { $0.id == selectedTag }?.name ?? ""
        }
        .onChange(of: selectedFilter) { loadSelectedFilter() }
        .confirmationDialog("Delete this local tag?", isPresented: $deletesTag, titleVisibility: .visible) {
            Button("Delete Tag", role: .destructive) {
                if let selectedTag {
                    Task {
                        await session.localCollections.removeTag(id: selectedTag, expectedScope: displayedScope)
                        if session.localCollections.errorMessage == nil { self.selectedTag = nil; tagName = "" }
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes the tag from local collection bookmarks. Saved filters using it must be updated or deleted first.") }
        .confirmationDialog("Delete this saved local filter?", isPresented: $deletesFilter, titleVisibility: .visible) {
            Button("Delete Filter", role: .destructive) {
                if let selectedFilter {
                    Task {
                        await session.localCollections.removeFilter(id: selectedFilter, expectedScope: displayedScope)
                        if session.localCollections.errorMessage == nil { self.selectedFilter = nil; loadSelectedFilter() }
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Collection bookmarks, tags and your YouTube Music library remain available.") }
    }

    private var tags: some View {
        HSplitView {
            List(session.localCollections.organization.tags, selection: $selectedTag) { tag in
                Label(tag.name, systemImage: "tag").tag(tag.id)
            }
            .frame(minWidth: 190)
            VStack(alignment: .leading, spacing: 16) {
                TextField("Local tag name", text: $tagName).textFieldStyle(.roundedBorder)
                HStack {
                    Button(selectedTag == nil ? "Create Tag" : "Save Tag") {
                        let name = tagName
                        let id = selectedTag
                        Task { await session.localCollections.saveTag(id: id, name: name, expectedScope: displayedScope) }
                    }.disabled(tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("New") { selectedTag = nil; tagName = "" }
                    Button("Delete…", role: .destructive) { deletesTag = true }.disabled(selectedTag == nil)
                }
                Text("Use a collection's Local Tags context menu to assign or remove tags. A collection can have several tags.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16).frame(minWidth: 350)
        }
        .padding(12)
    }

    private var filters: some View {
        HSplitView {
            List(session.localCollections.organization.savedFilters, selection: $selectedFilter) { filter in
                Label(filter.name, systemImage: "line.3.horizontal.decrease.circle").tag(filter.id)
            }
            .frame(minWidth: 190)
            VStack(alignment: .leading, spacing: 16) {
                Form {
                    TextField("Filter name", text: $filterName)
                    TextField("Title contains", text: $criteria.titleContains)
                    Picker("Collection kind", selection: $criteria.kind) {
                        Text("Any kind").tag(Optional<LocalCollectionReference.Kind>.none)
                        Text("Playlist").tag(Optional(LocalCollectionReference.Kind.playlist))
                        Text("Album").tag(Optional(LocalCollectionReference.Kind.album))
                        Text("Artist").tag(Optional(LocalCollectionReference.Kind.artist))
                    }
                    Toggle("Locally pinned only", isOn: $criteria.pinnedOnly)
                    Picker("Local folder", selection: $criteria.folderID) {
                        Text("Any folder").tag(Optional<UUID>.none)
                        ForEach(session.localCollections.organization.folders) { folder in Text(folder.name).tag(Optional(folder.id)) }
                    }
                    Picker("Local tag", selection: $criteria.tagID) {
                        Text("Any tag").tag(Optional<UUID>.none)
                        ForEach(session.localCollections.organization.tags) { tag in Text(tag.name).tag(Optional(tag.id)) }
                    }
                }
                HStack {
                    Button(selectedFilter == nil ? "Create Filter" : "Save Filter") {
                        let name = filterName
                        let value = criteria
                        let id = selectedFilter
                        Task { await session.localCollections.saveFilter(id: id, name: name, criteria: value, expectedScope: displayedScope) }
                    }.disabled(filterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("New") { selectedFilter = nil; loadSelectedFilter() }
                    Button("Delete…", role: .destructive) { deletesFilter = true }.disabled(selectedFilter == nil)
                }
                Button("Apply Saved Filter to Loaded Library") {
                    if let selectedFilter, session.localCollections.activateFilter(id: selectedFilter, expectedScope: displayedScope) {
                        if session.destination != .library { session.navigate(to: .library) }
                        dismiss()
                        onApply()
                    }
                }.disabled(selectedFilter == nil)
                Text("All chosen criteria must match. Save edits before applying a filter. Results include only collection metadata already loaded from Library.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(16).frame(minWidth: 350)
        }
        .padding(12)
    }

    private func loadSelectedFilter() {
        let value = session.localCollections.organization.savedFilters.first { $0.id == selectedFilter }
        filterName = value?.name ?? ""
        criteria = value?.criteria ?? LocalCollectionFilterCriteria()
    }
}

struct LocalLibraryFilterResultsView: View {
    let session: AppSession
    let page: MusicPage
    let filter: LocalSavedCollectionFilter

    var body: some View {
        let collections = session.localCollections.filteredCollections(in: page)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(filter.name).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text("\(collections.count) matching loaded library collections")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                let scope = session.localCollections.scope
                Button("Clear Filter") { session.localCollections.activateFilter(id: nil, expectedScope: scope) }
            }
            Text("This local filter checks library collections currently loaded. Load More includes more collections.")
                .font(.callout).foregroundStyle(.secondary)
            List(collections) { collection in
                Button { session.navigate(to: .collection(collection)) } label: {
                    Label(collection.title, systemImage: collection.localReference.symbol)
                }
                .buttonStyle(.plain)
                .contextMenu { LocalCollectionActions(session: session, collection: collection) }
            }
            .overlay {
                if collections.isEmpty {
                    ContentUnavailableView("No Loaded Collections Match", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            if let error = session.pageError { InlineMessage(message: error, actionTitle: "Try Again", action: session.reload) }
            HStack {
                Button("Refresh Library", action: session.reload)
                Spacer()
                if session.isLoadingMore { ProgressView("Loading more…").controlSize(.small) }
                else if page.continuation != nil { Button("Load More", action: session.loadMore) }
            }
        }
        .padding(24)
    }
}
