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
        default: false
        }
    }

    var body: some View {
        Group {
            if session.isLoading && session.page == nil {
                ProgressView("Loading \(session.destination.title.lowercased())…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let page = session.page {
                if usesTrackList {
                    CollectionTracksView(session: session, page: page, presentEditor: presentEditor)
                } else {
                    shelves(page)
                }
            } else {
                unavailable
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func shelves(_ page: MusicPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.destination.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        if case let .search(query) = session.destination {
                            Text("Results for “\(query)”").foregroundStyle(.secondary)
                        } else if !page.title.isEmpty && page.title != session.destination.title {
                            Text(page.title).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if session.destination == .library && session.remoteLibraryEditingEnabled {
                        Button("New Playlist", systemImage: "plus") { presentEditor(.createPlaylist(tracks: [])) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).help("New Playlist")
                            .disabled(session.isEditingLibrary)
                    }
                    Button("Refresh", systemImage: "arrow.clockwise", action: session.reload)
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Refresh this page")
                }
                if page.sections.isEmpty && page.items.isEmpty {
                    ContentUnavailableView("Nothing Here Yet", systemImage: "music.note.list",
                                           description: Text("Try another page or search for something to play."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
                ForEach(Array(page.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 14) {
                        if !section.title.isEmpty {
                            Text(section.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
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
                if page.sections.isEmpty && !page.items.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 220), spacing: 20)],
                              alignment: .leading, spacing: 26) {
                        ForEach(Array(page.items.enumerated()), id: \.offset) { _, item in
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
                ArtworkView(url: item.artworkURL, isArtist: isArtist)
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
                Text(item.title).font(.headline).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .accessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(isTrack ? "Play song" : "Open collection")
        .accessibilityActions {
            if case let .track(track) = item {
                Button("Play Next") { session.playNext([track]) }
                Button("Add to Queue") { session.addToQueue([track]) }
                LibraryTrackActions(session: session, tracks: [track], presentEditor: presentEditor,
                                    showsSeparator: false)
            }
        }
        .contextMenu {
            Button(isTrack ? "Play" : "Open") { session.activate(item) }
            if case let .track(track) = item {
                Button("Play Next") { session.playNext([track]) }
                Button("Add to Queue") { session.addToQueue([track]) }
                LibraryTrackActions(session: session, tracks: [track], presentEditor: presentEditor)
            }
        }
    }

    private var isTrack: Bool { if case .track = item { true } else { false } }
}

private struct CollectionTracksView: View {
    @Bindable var session: AppSession
    let page: MusicPage
    let presentEditor: (LibraryEditorRequest) -> Void
    @State private var selection: Set<Int> = []

    private struct Row: Identifiable {
        let id: Int
        let track: Track
        let removalReference: PlaylistItemReference?
    }
    private var allTracks: [Track] {
        page.tracks.isEmpty ? page.sections.flatMap(\.items).compactMap {
            if case let .track(track) = $0 { track } else { nil }
        } : page.tracks
    }
    private var rows: [Row] {
        let tracks = allTracks
        let query = session.collectionFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        // Match service occurrences before filtering, so identical song IDs
        // never borrow another occurrence's removal reference.
        return tracks.enumerated().compactMap { index, track in
            guard query.isEmpty || track.title.localizedCaseInsensitiveContains(query) ||
                track.artist.localizedCaseInsensitiveContains(query) else { return nil }
            let reference: PlaylistItemReference?
            if page.playlistItems.count == tracks.count, page.playlistItems[index].track == track {
                reference = page.playlistItems[index].removalReference
            } else { reference = nil }
            return Row(id: index, track: track, removalReference: reference)
        }
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
                HStack {
                    Button("Play", systemImage: "play.fill") { session.playTracks(session.visibleTracks) }
                        .buttonStyle(.borderedProminent).disabled(rows.isEmpty)
                    Button("Add to Queue", systemImage: "text.badge.plus") {
                        session.addToQueue(session.visibleTracks)
                    }.disabled(rows.isEmpty)
                    playlistActions
                }
                HStack {
                    TextField("Filter this collection", text: $session.collectionFilter)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 290)
                        .accessibilityLabel("Filter this collection")
                    Spacer()
                    Menu {
                        Button("Play Selected") { session.playTracks(selectedTracks) }
                        Button("Play Selected Next") { session.playNext(selectedTracks) }
                        Button("Add Selected to Queue") { session.addToQueue(selectedTracks) }
                        LibraryTrackActions(session: session, tracks: selectedTracks, presentEditor: presentEditor)
                        removalAction(for: selection)
                    } label: {
                        Label("Selected Songs", systemImage: "ellipsis.circle")
                    }
                    .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
                    .disabled(selection.isEmpty).help("Actions for selected songs")
                }
            }
            .padding(24)
            Table(rows, selection: $selection) {
                TableColumn("Title") { row in
                    HStack(spacing: 10) {
                        ArtworkView(url: row.track.artworkURL, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.track.title).fontWeight(.medium).lineLimit(1)
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
                    LibraryTrackActions(session: session, tracks: tracks, presentEditor: presentEditor)
                    removalAction(for: ids)
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
                        description: Text(session.collectionFilter.isEmpty ? "This collection has no songs to show." : "Try a different title or artist."))
                }
            }
            PaginationView(session: session).padding(12)
        }
        .onChange(of: session.collectionFilter) { selection.removeAll() }
        .onChange(of: session.destination) { selection.removeAll() }
    }

    @ViewBuilder private var playlistActions: some View {
        if session.remoteLibraryEditingEnabled,
           case let .collection(playlist) = session.destination, playlist.kind == .playlist,
           page.playlistCapabilities.canRename || page.playlistCapabilities.canDelete {
            Menu {
                if page.playlistCapabilities.canRename {
                    Button("Rename Playlist…") { presentEditor(.renamePlaylist(playlist)) }
                }
                if page.playlistCapabilities.canDelete {
                    Button("Delete Playlist…", role: .destructive) { presentEditor(.deletePlaylist(playlist)) }
                }
            } label: {
                Label("Playlist Actions", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
            .disabled(session.isEditingLibrary).help("Playlist actions")
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
            Text("\(session.visibleTracks.count) songs").foregroundStyle(.secondary)
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
            }
        }
    }
}
