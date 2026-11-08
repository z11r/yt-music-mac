import Foundation
import MusicCore
import Observation
import YouTubeMusic

extension MusicCollection {
    var localReference: LocalCollectionReference {
        let localKind: LocalCollectionReference.Kind = switch kind {
        case .playlist: .playlist
        case .album: .album
        case .artist: .artist
        case .podcast: .podcast
        }
        return LocalCollectionReference(serviceID: id, kind: localKind, title: title)
    }
}

extension LocalCollectionReference {
    var collection: MusicCollection {
        let musicKind: MusicCollection.Kind = switch kind {
        case .playlist: .playlist
        case .album: .album
        case .artist: .artist
        case .podcast: .podcast
        }
        return MusicCollection(id: serviceID, kind: musicKind, title: title)
    }
    var symbol: String {
        switch kind {
        case .playlist: "music.note.list"
        case .album: "square.stack"
        case .artist: "music.mic"
        case .podcast: "mic.circle"
        }
    }
}

@MainActor @Observable
final class LocalCollectionsLibrary {
    private(set) var organization = LocalCollectionOrganization()
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var scope = UUID()
    private(set) var activeFilterID: UUID?
    var activeFilter: LocalSavedCollectionFilter? { organization.savedFilters.first { $0.id == activeFilterID } }
    @ObservationIgnored private let store: LocalCollectionStore?
    @ObservationIgnored let profileOperations = ProfileOperationFence()
    @ObservationIgnored private let sessions: any MusicSessionProviding

    init(store: LocalCollectionStore?, sessions: any MusicSessionProviding) {
        self.store = store
        self.sessions = sessions
    }

    func invalidate() {
        scope = UUID()
        organization = LocalCollectionOrganization()
        isWorking = false
        errorMessage = nil
        activeFilterID = nil
    }

    func refresh(expectedScope: UUID? = nil) async {
        await update(expectedScope: expectedScope) { try await $0.load(accountKey: $1) }
    }

    func setPinned(_ pinned: Bool, collection: MusicCollection, expectedScope: UUID) async {
        let reference = collection.localReference
        await update(expectedScope: expectedScope) { try await $0.setPinned(pinned, reference: reference, accountKey: $1) }
    }

    func move(_ collection: MusicCollection, to folderID: UUID?, expectedScope: UUID) async {
        let reference = collection.localReference
        await update(expectedScope: expectedScope) { try await $0.move(reference, to: folderID, accountKey: $1) }
    }

    func createFolder(name: String, expectedScope: UUID) async {
        await update(expectedScope: expectedScope) { try await $0.createFolder(name: name, accountKey: $1) }
    }

    func renameFolder(id: UUID, name: String, expectedScope: UUID) async {
        await update(expectedScope: expectedScope) { try await $0.renameFolder(id: id, name: name, accountKey: $1) }
    }

    func removeFolder(id: UUID, expectedScope: UUID) async {
        await update(expectedScope: expectedScope) { try await $0.removeFolder(id: id, accountKey: $1) }
    }

    func saveTag(id: UUID? = nil, name: String, expectedScope: UUID) async {
        await update(expectedScope: expectedScope) { try await $0.saveTag(id: id, name: name, accountKey: $1) }
    }

    func removeTag(id: UUID, expectedScope: UUID) async {
        await update(expectedScope: expectedScope) { try await $0.removeTag(id: id, accountKey: $1) }
    }

    func setTag(_ id: UUID, present: Bool, collection: MusicCollection, expectedScope: UUID) async {
        let reference = collection.localReference
        await update(expectedScope: expectedScope) { try await $0.setTag(id, present: present, reference: reference, accountKey: $1) }
    }

    func saveFilter(id: UUID? = nil, name: String, criteria: LocalCollectionFilterCriteria, expectedScope: UUID) async {
        await update(expectedScope: expectedScope) { try await $0.saveFilter(id: id, name: name, criteria: criteria, accountKey: $1) }
    }

    func removeFilter(id: UUID, expectedScope: UUID) async {
        await update(expectedScope: expectedScope) { try await $0.removeFilter(id: id, accountKey: $1) }
    }

    @discardableResult func activateFilter(id: UUID?, expectedScope: UUID) -> Bool {
        guard scope == expectedScope,
              id == nil || organization.savedFilters.contains(where: { $0.id == id }) else { return false }
        activeFilterID = id
        return true
    }

    func filteredCollections(in page: MusicPage) -> [MusicCollection] {
        guard let filter = activeFilter else { return [] }
        let loaded = (page.items + page.sections.flatMap(\.items)).compactMap { item -> MusicCollection? in
            if case let .collection(collection) = item { collection } else { nil }
        }
        let matches = Set(filter.criteria.apply(to: loaded.map(\.localReference), in: organization).map(\.id))
        var seen = Set<String>()
        return loaded.filter { seen.insert($0.localReference.id).inserted && matches.contains($0.localReference.id) }
    }

    func bookmark(for collection: MusicCollection) -> LocalCollectionBookmark? {
        organization.bookmarks.first { $0.id == collection.localReference.id }
    }

    private func update(expectedScope: UUID?,
                        _ action: @Sendable (LocalCollectionStore, String) async throws -> LocalCollectionOrganization) async {
        guard profileOperations.begin() else { return }
        defer { profileOperations.end() }
        let request = expectedScope ?? scope
        guard scope == request else { return }
        guard !isWorking else { return }
        guard let store else { errorMessage = AppLocalization.text("Local collection storage is unavailable."); return }
        isWorking = true
        errorMessage = nil
        defer { if scope == request { isWorking = false } }
        do {
            let session = await sessions.snapshot()
            try Task.checkCancellation()
            guard scope == request, session.isAuthenticated, let key = session.accountID,
                  NamedQueueStore.acceptsAccountKey(key) else { throw AccessError.signInRequired }
            let result = try await action(store, key)
            try Task.checkCancellation()
            let current = await sessions.snapshot()
            guard scope == request, current.scope == session.scope, current.accountID == key,
                  current.isAuthenticated else { throw AccessError.accountChanged }
            organization = result
            if activeFilterID != nil && activeFilter == nil { activeFilterID = nil }
        } catch {
            guard scope == request, !(error is CancellationError) else { return }
            if error is AccessError { organization = LocalCollectionOrganization(); activeFilterID = nil }
            switch error {
            case let error as LocalCollectionError: errorMessage = error.localizedDescription
            case let error as AccessError: errorMessage = error.localizedDescription
            default: errorMessage = AppLocalization.text("Could not read or save local collection organization. Existing files have been kept.")
            }
        }
    }

    private enum AccessError: Error, LocalizedError {
        case signInRequired, accountChanged
        var errorDescription: String? {
            switch self {
            case .signInRequired: AppLocalization.text("Sign in to a confirmed account to use local collection organization.")
            case .accountChanged: AppLocalization.text("The account changed. Open local collection organization again.")
            }
        }
    }
}

extension LocalCollectionReference.Kind {
    var localizedTitle: String {
        switch self {
        case .playlist: AppLocalization.text("Playlist")
        case .album: AppLocalization.text("Album")
        case .artist: AppLocalization.text("Artist")
        case .podcast: AppLocalization.text("Podcast")
        }
    }
}
