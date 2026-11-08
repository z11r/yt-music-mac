import MusicCore
import SwiftUI
import YouTubeMusic

/// Collection context-menu actions change local organization only.
struct LocalCollectionActions: View {
    let session: AppSession
    let collection: MusicCollection

    var body: some View {
        if session.account.isSignedIn {
            let scope = session.localCollections.scope
            let bookmark = session.localCollections.bookmark(for: collection)
            Button(bookmark?.isPinned == true ? "Unpin Locally" : "Pin Locally") {
                Task { await session.localCollections.setPinned(bookmark?.isPinned != true, collection: collection, expectedScope: scope) }
            }
            .disabled(session.localCollections.isWorking)
            Menu("Local Folder") {
                Button("No Local Folder") {
                    Task { await session.localCollections.move(collection, to: nil, expectedScope: scope) }
                }
                ForEach(session.localCollections.organization.folders) { folder in
                    Button(folder.name) {
                        Task { await session.localCollections.move(collection, to: folder.id, expectedScope: scope) }
                    }
                }
                Divider()
                Button("Manage Local Folders…") { session.showsLocalFolders = true }
            }
            .disabled(session.localCollections.isWorking)
        }
    }
}

struct LocalCollectionsSidebar: View {
    let session: AppSession
    var body: some View {
        if session.account.isSignedIn {
            Section("Local Pins") {
                ForEach(session.localCollections.organization.pinned) { bookmark in
                    Label(bookmark.reference.title, systemImage: bookmark.reference.symbol)
                        .tag(MusicDestination.collection(bookmark.reference.collection))
                        .contextMenu { LocalCollectionActions(session: session, collection: bookmark.reference.collection) }
                }
            }
            Section("Local Folders") {
                ForEach(session.localCollections.organization.folders) { folder in
                    DisclosureGroup(folder.name) {
                        ForEach(session.localCollections.organization.members(of: folder.id)) { bookmark in
                            Label(bookmark.reference.title, systemImage: bookmark.reference.symbol)
                                .tag(MusicDestination.collection(bookmark.reference.collection))
                                .contextMenu { LocalCollectionActions(session: session, collection: bookmark.reference.collection) }
                        }
                    }
                }
                Button("Manage Local Folders…") { session.showsLocalFolders = true }
                    .disabled(session.localCollections.isWorking)
            }
        }
    }
}

struct LocalFoldersView: View {
    let session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selection: UUID?
    @State private var renamedName = ""
    @State private var renamePresented = false
    @State private var deletePresented = false
    @State private var displayedScope: UUID

    init(session: AppSession) {
        self.session = session
        _displayedScope = State(initialValue: session.localCollections.scope)
    }

    private var selected: LocalCollectionFolder? { session.localCollections.organization.folders.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Local Folders").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Organize collections on this Mac for this account. Local pins and folders do not change your YouTube Music library.")
                .font(.callout).foregroundStyle(.secondary)
            if session.account.isSignedIn && session.localCollections.scope == displayedScope {
                HStack {
                    TextField("New local folder", text: $name).textFieldStyle(.roundedBorder)
                    Button("Create") {
                        let title = name
                        Task {
                            await session.localCollections.createFolder(name: title, expectedScope: displayedScope)
                            if session.localCollections.errorMessage == nil { name = "" }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.localCollections.isWorking)
                }
                HSplitView {
                    List(session.localCollections.organization.folders, selection: $selection) { folder in
                        Label(folder.name, systemImage: "folder").tag(folder.id)
                    }
                    .frame(minWidth: 170)
                    List {
                        if let selected {
                            ForEach(session.localCollections.organization.members(of: selected.id)) { bookmark in
                                Button {
                                    session.navigate(to: .collection(bookmark.reference.collection))
                                    dismiss()
                                } label: { Label(bookmark.reference.title, systemImage: bookmark.reference.symbol) }
                                .buttonStyle(.plain)
                                .contextMenu { LocalCollectionActions(session: session, collection: bookmark.reference.collection) }
                            }
                        }
                    }
                    .frame(minWidth: 250)
                    .overlay {
                        if selected == nil {
                            ContentUnavailableView("Choose a Local Folder", systemImage: "folder")
                        }
                    }
                }
                HStack {
                    Button("Rename…") { renamedName = selected?.name ?? ""; renamePresented = true }
                        .disabled(selected == nil || session.localCollections.isWorking)
                    Button("Delete…", role: .destructive) { deletePresented = true }
                        .disabled(selected == nil || session.localCollections.isWorking)
                    Spacer()
                    if session.localCollections.isWorking { ProgressView().controlSize(.small) }
                    Button("Refresh") { Task { await session.localCollections.refresh(expectedScope: displayedScope) } }
                        .disabled(session.localCollections.isWorking)
                }
                Text("Use a collection's context menu to pin it locally or move it to a local folder.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("Sign In to Organize Collections", systemImage: "person.crop.circle")
            }
            if let error = session.localCollections.errorMessage { InlineMessage(message: error) }
        }
        .padding(20)
        .frame(minWidth: 600, idealWidth: 650, minHeight: 430, idealHeight: 480)
        .task { await session.localCollections.refresh(expectedScope: displayedScope) }
        .onChange(of: session.localCollections.scope) { dismiss() }
        .alert("Rename Local Folder", isPresented: $renamePresented) {
            TextField("Name", text: $renamedName)
            Button("Save") {
                if let selected {
                    let title = renamedName
                    Task { await session.localCollections.renameFolder(id: selected.id, name: title, expectedScope: displayedScope) }
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Delete this local folder?", isPresented: $deletePresented, titleVisibility: .visible) {
            if let selected {
                Button("Delete \(selected.name)", role: .destructive) {
                    Task { await session.localCollections.removeFolder(id: selected.id, expectedScope: displayedScope) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Pinned collections remain pinned. This removes only local organization; service playlists are unchanged.") }
    }
}
