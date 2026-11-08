import MusicCore
import SwiftUI
import YouTubeMusic

struct MusicContentView: View {
    @Bindable var session: AppSession
    let presentEditor: (LibraryEditorRequest) -> Void

    private var usesTrackList: Bool {
        switch session.destination {
        case .likedSongs: true
        case let .collection(value): value.kind != .artist
        case let .browse(reference): reference.kind == .playlist
        default: false
        }
    }

    private var showsResultGrid: Bool {
        switch session.destination {
        case .search: session.searchFilter != .all
        case let .browse(reference): reference.kind == .discography
        default: false
        }
    }

    private var showsSortedLibrary: Bool {
        session.destination.libraryCategory != nil && (session.libraryDisplayOrder != .serviceOrder ||
            !session.libraryFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        Group {
            if session.isLoading && session.page == nil {
                ProgressView("Loading \(session.destination.title.lowercased())…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let page = session.page {
                if session.destination == .library, let filter = session.localCollections.activeFilter {
                    LocalLibraryFilterResultsView(session: session, page: page, filter: filter)
                } else if usesTrackList {
                    CollectionTracksView(session: session, page: page, presentEditor: presentEditor)
                } else {
                    shelves(page)
                }
            } else {
                unavailable
            }
        }
        // Outside the page content, so the filters stay in place (and keep focus) while results load.
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .search = session.destination {
                VStack(spacing: 0) {
                    SearchFilterBar(session: session)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 8)
                    Divider()
                }
                .background(.bar)
            } else if session.destination.libraryCategory != nil {
                VStack(spacing: 0) {
                    LibraryCategoryBar(session: session)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 8)
                    Divider()
                }
                .background(.bar)
            } else if showsDiscoveryCategories {
                VStack(spacing: 0) {
                    DiscoveryCategoryBar(session: session)
                        .padding(.horizontal, 28).padding(.vertical, 8)
                    Divider()
                }
                .background(.bar)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var showsDiscoveryCategories: Bool {
        switch session.destination {
        case .explore, .discovery: true
        default: false
        }
    }

    private func shelves(_ page: MusicPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.destination.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        if case let .search(query) = session.destination {
                            Text("Results for “\(query)”").foregroundStyle(.secondary)
                        } else if session.destination == .history {
                            Text("Listening history from your YouTube Music account")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else if !page.title.isEmpty && page.title != session.destination.title {
                            Text(page.title).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    CollectionLibraryActions(session: session, page: page)
                    if session.remoteLibraryEditingEnabled,
                       session.destination.libraryCategory == .all || session.destination.libraryCategory == .playlists {
                        Button("New Playlist", systemImage: "plus") { presentEditor(.createPlaylist(tracks: [])) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).help("New Playlist")
                            .disabled(session.isEditingLibrary)
                    }
                    Button("Refresh", systemImage: "arrow.clockwise", action: session.reload)
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Refresh this page")
                }
                UnavailableMusicNotice(page: page)
                if page.sections.isEmpty && page.items.isEmpty {
                    if case let .search(query) = session.destination {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        ContentUnavailableView("Nothing Here Yet", systemImage: "music.note.list",
                                               description: Text("Try another page or search for something to play."))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                if showsSortedLibrary, !page.items.isEmpty,
                   LibraryDisplayOrder.filtered(page.items, matching: session.libraryFilter).isEmpty {
                    ContentUnavailableView.search(text: session.libraryFilter)
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
                // A filtered search is one list that grows page by page, so show it as one grid.
                ForEach(Array((showsResultGrid || showsSortedLibrary ? [] : page.sections).enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            if !section.title.isEmpty {
                                Text(section.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                            }
                            Spacer()
                            if let reference = section.browseReference {
                                Button("See All") { session.navigate(to: .browse(reference)) }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("See all \(section.title)")
                            }
                        }
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 20) {
                                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                    MusicCard(item: item, session: session, presentEditor: presentEditor)
                                }
                            }
                            .padding(.bottom, 6)
                        }
                        .scrollIndicators(.automatic)
                    }
                }
                if (showsResultGrid || showsSortedLibrary || page.sections.isEmpty) && !page.items.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 220), spacing: 20)],
                              alignment: .leading, spacing: 26) {
                        ForEach(Array((showsSortedLibrary ? session.libraryDisplayOrder.sorted(LibraryDisplayOrder.filtered(page.items, matching: session.libraryFilter)) : page.items).enumerated()), id: \.offset) { _, item in
                            MusicCard(item: item, session: session, presentEditor: presentEditor)
                        }
                    }
                }
                PaginationView(session: session)
            }
            .padding(28)
        }
    }

    private var unavailable: some View {
        VStack(spacing: 18) {
            ContentUnavailableView {
                Label(session.account.isSignedIn ? "Couldn't Load Music" : "Listen with YouTube Music",
                      systemImage: session.account.isSignedIn ? "wifi.exclamationmark" : "music.note")
            } description: {
                Text(session.pageError ?? "Browse music, bring your library, and keep listening on your Mac.")
                    .frame(maxWidth: 390)
            } actions: {
                if !session.account.isSignedIn {
                    Button("Sign In", action: session.openAccount).buttonStyle(.borderedProminent)
                }
                Button("Try Again", action: session.reload)
                if session.currentTrack != nil {
                    Button("Open Web Player") { session.showsWebPlayer = true }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MusicCard: View {
    let item: MusicItem
    let session: AppSession
    let presentEditor: (LibraryEditorRequest) -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isArtist: Bool {
        if case let .collection(value) = item { value.kind == .artist } else { false }
    }

    var body: some View {
        Button { session.activate(item) } label: {
            VStack(alignment: .leading, spacing: 9) {
                ArtworkView(url: item.artworkURL, isArtist: isArtist, videoID: trackID)
                    .overlay(alignment: .bottomTrailing) {
                        if isHovered || isFocused {
                            Image(systemName: isTrack ? "play.fill" : "arrow.up.forward")
                                .font(.body.weight(.semibold))
                                .frame(width: 32, height: 32)
                                .background {
                                    if reduceTransparency { Circle().fill(Color(nsColor: .windowBackgroundColor)) }
                                    else { Circle().fill(.regularMaterial) }
                                }
                                .padding(9)
                                .accessibilityHidden(true)
                        }
                    }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(item.title).font(.headline).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if case let .track(track) = item { ExplicitContentBadge(track: track) }
                }
                Text(item.subtitle ?? (isArtist ? "Artist" : ""))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(width: 176, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onHover { isHovered = $0 }
        .help([item.title, item.subtitle].compactMap { $0 }.joined(separator: " — "))
        .accessibilityLabel([item.title, item.subtitle, explicitLabel].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(isTrack ? "Play song" : "Open collection")
        .accessibilityActions {
            if case let .track(track) = item {
                Button("Play Next") { session.playNext([track]) }
                Button("Add to Queue") { session.addToQueue([track]) }
                Button("Start Radio") { session.startRadio(from: track) }
                LibraryTrackActions(session: session, tracks: [track], presentEditor: presentEditor,
                                    showsSeparator: false)
                TrackMetadataActions(track: track, session: session)
            } else if case let .collection(collection) = item, collection.radioPlaylistID != nil {
                Button("Start Radio") { session.startRadio(from: collection) }
            }
        }
        .contextMenu {
            switch item {
            case let .track(track): MusicLinkActions(link: .track(track.id))
            case let .collection(collection): MusicLinkActions(link: .collection(collection))
            case .browse: EmptyView()
            }
            Button(isTrack ? "Play" : "Open") { session.activate(item) }
            if case let .track(track) = item {
                Button("Play Next") { session.playNext([track]) }
                Button("Add to Queue") { session.addToQueue([track]) }
                Button("Start Radio") { session.startRadio(from: track) }
                LibraryTrackActions(session: session, tracks: [track], presentEditor: presentEditor)
                TrackMetadataActions(track: track, session: session)
            } else if case let .collection(collection) = item {
                LocalCollectionActions(session: session, collection: collection)
                if collection.radioPlaylistID != nil {
                    Button("Start Radio") { session.startRadio(from: collection) }
                }
            }
        }
    }

    private var isTrack: Bool { if case .track = item { true } else { false } }
    private var trackID: String? { if case let .track(track) = item { track.id } else { nil } }
    private var explicitLabel: String? {
        if case let .track(track) = item, track.isExplicit == true { "Explicit content" } else { nil }
    }
}

private struct CollectionTracksView: View {
    @Bindable var session: AppSession
    let page: MusicPage
    let presentEditor: (LibraryEditorRequest) -> Void
    @State private var selection: Set<Int> = []

    private typealias Row = CollectionDisplayRow
    private var allTracks: [Track] { CollectionPresentation.tracks(in: page) }
    private var rows: [Row] {
        CollectionPresentation.rows(in: page, matching: session.collectionFilter, order: session.collectionDisplayOrder)
    }
    private var selectedTracks: [Track] { rows.filter { selection.contains($0.id) }.map(\.track) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 20) {
                        if case let .collection(value) = session.destination {
                            ArtworkView(url: value.artworkURL, size: 120)
                        }
                        collectionHeading.frame(minWidth: 220, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                    collectionHeading.frame(maxWidth: .infinity, alignment: .leading)
                }
                ViewThatFits(in: .horizontal) {
                    collectionButtonRow(compact: false)
                    collectionButtonRow(compact: true)
                }
                .disabled(session.isLoadingMore || session.collectionPlayback.isLoading)
                CollectionPlaybackStatus(session: session)
                HStack {
                    TextField("Filter loaded songs", text: $session.collectionFilter)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 290)
                        .accessibilityLabel("Filter loaded songs by title, artist, or album")
                    if !session.collectionFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Menu("Loaded Matches") {
                            Button("Play Loaded Matches") { session.playTracks(session.visibleTracks) }
                            Button("Add Loaded Matches to Queue") { session.addToQueue(session.visibleTracks) }
                        }
                        .disabled(rows.isEmpty)
                        .help("Use matching songs from the pages already loaded")
                    }
                    Spacer()
                    Picker("Sort Loaded Songs", selection: $session.collectionDisplayOrder) {
                        ForEach(CollectionDisplayOrder.allCases, id: \.self) { order in Text(order.title).tag(order) }
                    }
                    .pickerStyle(.menu).fixedSize()
                    .help("Sorts loaded songs. Play All uses service order.")
                    Menu {
                        Button("Play Selected") { session.playTracks(selectedTracks) }
                        Button("Play Selected Next") { session.playNext(selectedTracks) }
                        Button("Add Selected to Queue") { session.addToQueue(selectedTracks) }
                        LibraryTrackActions(session: session, tracks: selectedTracks, presentEditor: presentEditor)
                        removalAction(for: selection)
                        reorderActions(for: selection)
                    } label: {
                        Label("Selected Songs", systemImage: "ellipsis.circle")
                    }
                    .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
                    .disabled(selection.isEmpty).help("Actions for selected songs")
                }
                if page.continuation != nil {
                    Text("Filtering searches the \(allTracks.count) loaded songs. Play All, Shuffle All, and Add All to Queue include the remaining pages.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            Table(rows, selection: $selection) {
                TableColumn("Title") { row in
                    HStack(spacing: 10) {
                        ArtworkView(url: row.track.artworkURL, size: 36, videoID: row.track.id)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(row.track.title).fontWeight(.medium).lineLimit(1)
                                ExplicitContentBadge(track: row.track)
                            }
                            Text(row.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .help("\(row.track.title) — \(row.track.artist)")
                    .accessibilityActions {
                        Button("Play") { session.play(row.track) }
                        Button("Play Next") { session.playNext([row.track]) }
                        Button("Add to Queue") { session.addToQueue([row.track]) }
                        Button("Start Radio") { session.startRadio(from: row.track) }
                        TrackRatingActions(session: session, track: row.track)
                        TrackMetadataActions(track: row.track, session: session)
                        reorderActions(for: [row.id])
                    }
                }.width(min: 190, ideal: 380)
                TableColumn("Time") { row in
                    Text(row.track.duration.map(playbackTime) ?? "—")
                        .monospacedDigit().foregroundStyle(.secondary)
                }.width(55)
            }
            .accessibilityLabel("Songs in \(session.destination.title)")
            .contextMenu(forSelectionType: Int.self) { ids in
                let tracks = rows.filter { ids.contains($0.id) }.map(\.track)
                if !tracks.isEmpty {
                    Button("Play") { session.playTracks(tracks) }
                    Button("Play Next") { session.playNext(tracks) }
                    Button("Add to Queue") { session.addToQueue(tracks) }
                    if tracks.count == 1, let track = tracks.first { MusicLinkActions(link: .track(track.id)) }
                    if tracks.count == 1, let track = tracks.first {
                        Button("Start Radio") { session.startRadio(from: track) }
                    }
                    LibraryTrackActions(session: session, tracks: tracks, presentEditor: presentEditor)
                    if tracks.count == 1, let track = tracks.first {
                        TrackMetadataActions(track: track, session: session)
                    }
                    removalAction(for: ids)
                    reorderActions(for: ids)
                }
            } primaryAction: { ids in
                if let first = rows.firstIndex(where: { ids.contains($0.id) }) {
                    session.playTracks(rows.map(\.track), startingAt: first)
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(session.collectionFilter.isEmpty ? "No Songs Yet" : "No Matching Songs",
                        systemImage: "music.note.list",
                        description: Text(session.collectionFilter.isEmpty ? "This collection has no songs to show." : "Try a different title, artist, or album."))
                }
            }
            PaginationView(session: session).padding(12)
        }
        .onChange(of: session.collectionFilter) { selection.removeAll() }
        .onChange(of: session.destination) { selection.removeAll() }
        .onChange(of: session.collectionDisplayOrder) { selection.removeAll() }
    }

    private var canQueueCollection: Bool { !allTracks.isEmpty || page.continuation != nil }

    private func collectionButtonRow(compact: Bool) -> some View {
        HStack {
            Button("Play All", systemImage: "play.fill") { session.performCollectionAction(.play) }
                .buttonStyle(.borderedProminent).disabled(!canQueueCollection)
                .help("Load every page and play the entire collection in order")
            if !compact {
                Button("Shuffle All", systemImage: "shuffle") { session.performCollectionAction(.shuffle) }
                    .disabled(!canQueueCollection)
            }
            Menu {
                if compact {
                    Button("Shuffle All", systemImage: "shuffle") { session.performCollectionAction(.shuffle) }
                        .disabled(!canQueueCollection)
                }
                Button("Add All to Queue", systemImage: "text.badge.plus") { session.performCollectionAction(.append) }
                    .disabled(!canQueueCollection)
                if case let .collection(collection) = session.destination {
                    if collection.radioPlaylistID != nil {
                        Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { session.startRadio(from: collection) }
                    }
                    MusicLinkActions(link: .collection(collection))
                }
                playlistActions
                CollectionLibraryActions(session: session, page: page)
            } label: {
                Label("Collection Actions", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly).help("Collection Actions")
        }
    }

    @ViewBuilder private var playlistActions: some View {
        if session.account.isSignedIn,
           case let .collection(playlist) = session.destination, playlist.kind == .playlist,
           hasPlaylistMenuActions {
            Menu {
                if session.remoteLibraryEditingEnabled && page.playlistCapabilities.canRename {
                    Button("Rename Playlist…") { presentEditor(.renamePlaylist(playlist)) }
                }
                if session.remoteLibraryEditingEnabled && page.playlistCapabilities.canDelete {
                    Button("Delete Playlist…", role: .destructive) { presentEditor(.deletePlaylist(playlist)) }
                }
                if session.libraryEditCapabilities.playlistDescription && page.playlistCapabilities.canEditDescription,
                   let description = page.playlistDetails?.description {
                    Button("Edit Description…") { presentEditor(.editDescription(playlist, description: description)) }
                }
                if session.libraryEditCapabilities.playlistPrivacy && page.playlistCapabilities.canEditPrivacy,
                   let privacy = page.playlistDetails?.privacy {
                    Button("Edit Visibility…") { presentEditor(.editPrivacy(playlist, privacy: privacy)) }
                }
            } label: {
                Label("Playlist Actions", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
            .disabled(session.isEditingLibrary).help("Playlist actions")
        }
    }

    private var hasPlaylistMenuActions: Bool {
        (session.remoteLibraryEditingEnabled && (page.playlistCapabilities.canRename || page.playlistCapabilities.canDelete)) ||
        (session.libraryEditCapabilities.playlistDescription && page.playlistCapabilities.canEditDescription && page.playlistDetails?.description != nil) ||
        (session.libraryEditCapabilities.playlistPrivacy && page.playlistCapabilities.canEditPrivacy && page.playlistDetails?.privacy != nil)
    }

    @ViewBuilder private func reorderActions(for ids: Set<Int>) -> some View {
        if session.account.isSignedIn, session.libraryEditCapabilities.playlistReorder, page.playlistCapabilities.canReorder,
           case let .collection(playlist) = session.destination, playlist.kind == .playlist,
           ids.count == 1, let index = ids.first, page.playlistItems.count == allTracks.count {
            let filtered = session.collectionDisplayOrder != .serviceOrder ||
                !session.collectionFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let action = PlaylistReorder.action(playlistID: playlist.id, index: index, direction: .up,
                                                   items: page.playlistItems, hasMore: page.continuation != nil, isFiltered: filtered) {
                Button("Move Up in Playlist") { session.submitLibraryEdit(action) }.disabled(session.isEditingLibrary)
            }
            if let action = PlaylistReorder.action(playlistID: playlist.id, index: index, direction: .down,
                                                   items: page.playlistItems, hasMore: page.continuation != nil, isFiltered: filtered) {
                Button("Move Down in Playlist") { session.submitLibraryEdit(action) }.disabled(session.isEditingLibrary)
            }
        }
    }

    @ViewBuilder private func removalAction(for ids: Set<Int>) -> some View {
        if session.remoteLibraryEditingEnabled, page.playlistCapabilities.canRemoveItems,
           case let .collection(playlist) = session.destination, playlist.kind == .playlist {
            let selected = rows.filter { ids.contains($0.id) }
            let references = selected.compactMap(\.removalReference)
            if !selected.isEmpty && references.count == selected.count {
                Button("Remove from Playlist…", role: .destructive) {
                    presentEditor(.removeItems(playlist: playlist, tracks: selected.map(\.track), references: references))
                }.disabled(session.isEditingLibrary)
            }
        }
    }

    private var collectionHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.destination.title).font(.largeTitle.bold()).lineLimit(3)
                .accessibilityAddTraits(.isHeader).help(session.destination.title)
            if case let .collection(value) = session.destination, let subtitle = value.subtitle {
                Text(subtitle).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(page.continuation == nil ? "\(allTracks.count) songs" : "\(allTracks.count) songs loaded")
                .foregroundStyle(.secondary)
            UnavailableMusicNotice(page: page)
        }
    }
}

private struct CollectionPlaybackStatus: View {
    let session: AppSession

    var body: some View {
        let operation = session.collectionPlayback
        if operation.isLoading {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading all songs… \(operation.loadedTrackCount) loaded")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Cancel", action: operation.cancel)
            }
        } else if let message = operation.errorMessage {
            HStack {
                Text(message).font(.callout).foregroundStyle(.secondary)
                if operation.canRetry { Button("Try Again") { operation.retry() } }
                Button("Dismiss", action: operation.cancel)
            }
        }
    }
}

private struct PaginationView: View {
    let session: AppSession
    var body: some View {
        VStack(spacing: 10) {
            if let message = session.pageError {
                InlineMessage(message: message, actionTitle: "Try Again") {
                    if session.page?.continuation != nil { session.loadMore() } else { session.reload() }
                }
            }
            if session.isLoadingMore {
                ProgressView("Loading more…").controlSize(.small)
            } else if session.page?.continuation != nil {
                Button("Load More", action: session.loadMore)
                    .frame(maxWidth: .infinity)
                    .disabled(session.collectionPlayback.isLoading)
            }
        }
    }
}
