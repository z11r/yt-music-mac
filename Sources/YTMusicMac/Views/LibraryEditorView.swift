import Foundation
import MusicCore
import SwiftUI
import YouTubeMusic

enum LibraryEditorRequest: Identifiable {
    case createPlaylist(tracks: [Track])
    case renamePlaylist(MusicCollection)
    case deletePlaylist(MusicCollection)
    case addItems(tracks: [Track])
    case removeItems(playlist: MusicCollection, tracks: [Track], references: [PlaylistItemReference])

    var id: String {
        switch self {
        case .createPlaylist: "create"
        case let .renamePlaylist(value): "rename:\(value.id)"
        case let .deletePlaylist(value): "delete:\(value.id)"
        case .addItems: "add"
        case let .removeItems(value, _, _): "remove:\(value.id)"
        }
    }

    var title: String {
        switch self {
        case .createPlaylist: "New Playlist"
        case .renamePlaylist: "Rename Playlist"
        case .deletePlaylist: "Delete Playlist?"
        case .addItems: "Add to Playlist"
        case .removeItems: "Remove Songs?"
        }
    }

    var actionTitle: String {
        switch self {
        case .createPlaylist: "Create Playlist"
        case .renamePlaylist: "Save Name"
        case .deletePlaylist: "Delete Playlist"
        case .addItems: "Add Songs"
        case .removeItems: "Remove Songs"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .deletePlaylist, .removeItems: true
        default: false
        }
    }

    var tracks: [Track] {
        switch self {
        case let .createPlaylist(tracks), let .addItems(tracks), let .removeItems(_, tracks, _): tracks
        default: []
        }
    }
}

struct LibraryEditorView: View {
    let session: AppSession
    let request: LibraryEditorRequest
    @Environment(\.dismiss) private var dismiss
    @State private var accountScope: UUID
    @State private var title: String
    @State private var description = ""
    @State private var privacy = PlaylistPrivacy.private
    @State private var playlists: [MusicCollection] = []
    @State private var selectedPlaylistID = ""
    @State private var allowDuplicates = false
    @State private var isLoadingPlaylists = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var playlistLoadError: String?
    @State private var playlistLoadAttempt = 0
    @FocusState private var nameIsFocused: Bool

    init(session: AppSession, request: LibraryEditorRequest) {
        self.session = session
        self.request = request
        _accountScope = State(initialValue: session.libraryEditingScope)
        if case let .renamePlaylist(collection) = request {
            _title = State(initialValue: collection.title)
        } else {
            _title = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            fields.disabled(isSubmitting)
            if let issue = validationMessage {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            }
            if let errorMessage { InlineMessage(message: errorMessage) }
            HStack(spacing: 12) {
                if isSubmitting {
                    ProgressView("Saving…").controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isSubmitting)
                submitButton
                    .disabled(!session.remoteLibraryEditingEnabled || session.isEditingLibrary ||
                              isSubmitting || action == nil || validationMessage != nil)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(isSubmitting)
        .task(id: playlistLoadAttempt) {
            if case .addItems = request { await loadPlaylists() }
        }
        .onAppear {
            session.clearLibraryEditFeedback()
            switch request {
            case .createPlaylist, .renamePlaylist: nameIsFocused = true
            default: break
            }
        }
    }

    @ViewBuilder private var fields: some View {
        switch request {
        case .createPlaylist:
            nameField
            VStack(alignment: .leading, spacing: 6) {
                Text("Description (optional)").font(.callout)
                TextField("Playlist description", text: $description, axis: .vertical)
                    .lineLimit(3...5).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Playlist description")
            }
            Picker("Visibility", selection: $privacy) {
                Text("Private").tag(PlaylistPrivacy.private)
                Text("Unlisted").tag(PlaylistPrivacy.unlisted)
                Text("Public").tag(PlaylistPrivacy.public)
            }
            .pickerStyle(.menu)
            Text(privacyDescription).font(.caption).foregroundStyle(.secondary)
            if !request.tracks.isEmpty { selectionSummary }
        case .renamePlaylist:
            nameField
        case let .deletePlaylist(collection):
            Text("Delete “\(collection.title)” from YouTube Music? This cannot be undone.")
                .fixedSize(horizontal: false, vertical: true)
        case .addItems:
            selectionSummary
            if isLoadingPlaylists {
                ProgressView("Loading playlists…").controlSize(.small)
            } else if let playlistLoadError {
                InlineMessage(message: playlistLoadError, actionTitle: "Try Again") {
                    playlistLoadAttempt += 1
                }
            } else if playlists.isEmpty {
                Text("No playlists are available. Create a playlist in your library first.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Playlist", selection: $selectedPlaylistID) {
                    Text("Choose a playlist").tag("")
                    ForEach(playlists) { playlist in
                        Text(playlist.title).tag(playlist.id)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Allow duplicate songs", isOn: $allowDuplicates)
            }
        case let .removeItems(playlist, _, _):
            Text("Remove the selected songs from “\(playlist.title)”? Other copies in the playlist stay in place.")
                .fixedSize(horizontal: false, vertical: true)
            selectionSummary
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name").font(.callout)
            TextField("Playlist name", text: $title)
                .textFieldStyle(.roundedBorder).focused($nameIsFocused)
                .accessibilityLabel("Playlist name")
        }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(request.tracks.count == 1 ? "1 song selected" : "\(request.tracks.count) songs selected")
                .font(.callout.weight(.medium))
            Text(request.tracks.prefix(3).map(\.title).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
    }

    private var privacyDescription: String {
        switch privacy {
        case .private: "Only you can see this playlist."
        case .unlisted: "Anyone with the link can see this playlist."
        case .public: "Anyone can find and view this playlist."
        }
    }

    @ViewBuilder private var submitButton: some View {
        if request.isDestructive {
            Button(request.actionTitle, role: .destructive, action: submit)
        } else {
            Button(request.actionTitle, action: submit).keyboardShortcut(.defaultAction)
        }
    }

    private var cleanedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var validationMessage: String? {
        switch request {
        case .createPlaylist, .renamePlaylist:
            if cleanedTitle.isEmpty { return nil }
            if cleanedTitle.count > 150 || cleanedTitle.contains("<") || cleanedTitle.contains(">") ||
                cleanedTitle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                return "Use a name of up to 150 characters without angle brackets or control characters."
            }
            if description.count > 5_000 { return "Keep the description within 5,000 characters." }
        default: break
        }
        if request.tracks.count > 100 { return "Choose up to 100 songs for one change." }
        if case .addItems = request, !allowDuplicates,
           Set(request.tracks.map(\.id)).count != request.tracks.count {
            return "This selection includes repeated songs. Allow duplicates to add every occurrence."
        }
        return nil
    }

    private var action: MusicLibraryEditAction? {
        switch request {
        case let .createPlaylist(tracks):
            guard !cleanedTitle.isEmpty else { return nil }
            return .createPlaylist(title: cleanedTitle, description: description.isEmpty ? nil : description,
                                   privacy: privacy, videoIDs: tracks.map(\.id))
        case let .renamePlaylist(collection):
            guard !cleanedTitle.isEmpty else { return nil }
            return .renamePlaylist(id: collection.id, title: cleanedTitle)
        case let .deletePlaylist(collection): return .deletePlaylist(id: collection.id)
        case let .addItems(tracks):
            guard !isLoadingPlaylists, playlists.contains(where: { $0.id == selectedPlaylistID }), !tracks.isEmpty else { return nil }
            return .addItems(playlistID: selectedPlaylistID, videoIDs: tracks.map(\.id), allowDuplicates: allowDuplicates)
        case let .removeItems(collection, tracks, references):
            guard !references.isEmpty, tracks.count == references.count else { return nil }
            return .removeItems(playlistID: collection.id, items: references)
        }
    }

    private func submit() {
        guard let action, validationMessage == nil, !isSubmitting, !session.isEditingLibrary,
              session.remoteLibraryEditingEnabled, session.libraryEditingScope == accountScope else { return }
        let operationScope = accountScope
        isSubmitting = true
        errorMessage = nil
        Task { @MainActor in
            guard session.libraryEditingScope == operationScope else { return }
            let confirmed = await session.performLibraryEdit(action)
            guard session.libraryEditingScope == operationScope else { return }
            isSubmitting = false
            if confirmed { dismiss() }
            else { errorMessage = session.libraryEditError ?? "The change was not confirmed. Check your library before trying again." }
        }
    }

    private func loadPlaylists() async {
        guard session.remoteLibraryEditingEnabled, session.libraryEditingScope == accountScope else { return }
        let operationScope = accountScope
        isLoadingPlaylists = true
        playlistLoadError = nil
        defer { isLoadingPlaylists = false }
        do {
            let result = try await session.playlistsForEditing()
            try Task.checkCancellation()
            guard session.libraryEditingScope == operationScope else { return }
            playlists = result
        } catch is CancellationError {
        } catch {
            guard session.libraryEditingScope == operationScope else { return }
            playlistLoadError = error.localizedDescription
        }
    }
}

struct LibraryTrackActions: View {
    let session: AppSession
    let tracks: [Track]
    let presentEditor: (LibraryEditorRequest) -> Void
    var showsSeparator = true

    var body: some View {
        if !tracks.isEmpty && (session.remoteLibraryEditingEnabled || (tracks.count == 1 && session.hasRatingControls)) {
            if showsSeparator { Divider() }
            if tracks.count == 1, let track = tracks.first {
                TrackRatingActions(session: session, track: track)
            }
            if session.remoteLibraryEditingEnabled {
                Button("Add to Playlist…") { presentEditor(.addItems(tracks: tracks)) }
                    .disabled(session.isEditingLibrary)
                Button("New Playlist with Selection…") { presentEditor(.createPlaylist(tracks: tracks)) }
                    .disabled(session.isEditingLibrary)
            }
        }
    }
}

struct LibraryEditFeedbackView: View {
    let session: AppSession

    var body: some View {
        if session.isEditingLibrary {
            ProgressView("Updating your library…").controlSize(.small).padding(10)
        } else if let error = session.libraryEditError {
            InlineMessage(message: error, actionTitle: "Dismiss", action: session.clearLibraryEditFeedback)
        } else if let message = session.libraryEditMessage {
            HStack {
                Image(systemName: "checkmark.circle").accessibilityHidden(true)
                Text(message).font(.callout)
                Spacer()
                Button("Dismiss", action: session.clearLibraryEditFeedback)
            }
            .padding(12)
        }
    }
}
