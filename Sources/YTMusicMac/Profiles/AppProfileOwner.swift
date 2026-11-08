import Foundation
import Observation

@MainActor
protocol AppProfileRuntime: AnyObject {
    var profile: AppProfile { get set }
    func quiesce()
    func settle() async
    func resumePausedOwnership()
    func shutdown() async
    func startPaused() async
}

@MainActor
struct PreparedAppProfile<Runtime: AppProfileRuntime> {
    let activate: () -> Runtime
}

/// All fallible preparation precedes irreversible owner shutdown. A new runtime
/// never starts while old writes or native ownership are still active.
@MainActor @Observable
final class AppProfileOwner<Runtime: AppProfileRuntime> {
    private(set) var current: Runtime
    private(set) var activationID = UUID()
    private(set) var profiles: [AppProfile] = [.original]
    private(set) var deletion: AppProfileDeletionController?
    private(set) var deletionJournals: [ProfileDeletionJournal] = []
    private(set) var savedSelectionID = AppProfile.defaultID
    private(set) var isLoading = true
    private(set) var isSwitching = false
    private(set) var canEdit = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let registry: any AppProfileRegistry
    @ObservationIgnored private let prepare: (AppProfile, Bool) async throws -> PreparedAppProfile<Runtime>
    @ObservationIgnored private let bind: (Runtime?, UUID) -> Void
    @ObservationIgnored private let identifier: () -> UUID
    @ObservationIgnored private var snapshot: AppProfileRegistrySnapshot?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var quitting = false
    @ObservationIgnored private var transition: Task<Void, Never>?

    init(initial: Runtime, registry: any AppProfileRegistry,
         identifier: @escaping () -> UUID = UUID.init,
         prepare: @escaping (AppProfile, Bool) async throws -> PreparedAppProfile<Runtime>,
         bind: @escaping (Runtime?, UUID) -> Void) {
        current = initial; self.registry = registry; self.identifier = identifier
        self.prepare = prepare; self.bind = bind
    }

    func installDeletionAdapter(_ adapter: any ProfileCleanupPreparing) {
        guard deletion == nil else { return }
        deletion = AppProfileDeletionController(registry: registry, adapter: adapter) { [weak self] in self?.install($0) }
    }
    var canManageProfiles: Bool { deletion?.isWorking != true }
    func isPendingDeletion(_ id: String) -> Bool { deletionJournals.contains { $0.target.id == id } }

    func start() async {
        guard !started else { return }
        started = true; isLoading = true
        do {
            let loaded = try await registry.load()
            guard !quitting else { isLoading = false; return }
            install(loaded)
            if loaded.archive.selectedID != current.profile.id {
                guard let selected = loaded.archive.profiles.first(where: { $0.id == loaded.archive.selectedID }) else {
                    throw AppProfileError.invalidRegistry
                }
                await begin(profile: selected, staged: loaded.archive, persistPending: false, automatic: true)
                isLoading = false
            } else {
                bind(current, activationID)
                await current.startPaused()
                isLoading = false
            }
        } catch {
            canEdit = false; errorMessage = error.localizedDescription
            guard !quitting else { isLoading = false; return }
            bind(current, activationID)
            await current.startPaused()
            isLoading = false
        }
    }

    func reload() async {
        guard canManageProfiles, !isLoading, !isSwitching else { return }
        isLoading = true
        do { install(try await registry.load()); errorMessage = nil }
        catch { canEdit = false; errorMessage = error.localizedDescription }
        isLoading = false
    }

    func create(name: String) async {
        guard canManageProfiles, canEdit, !isSwitching, !isLoading, let snapshot else { return }
        do {
            guard snapshot.archive.profiles.count < AppProfileArchive.maximumProfiles else { throw AppProfileError.capacityReached }
            let profile = try AppProfile.additional(name: name, identifier: identifier())
            var archive = snapshot.archive; archive.profiles.append(profile)
            try archive.validate()
            await begin(profile: profile, staged: archive, persistPending: true, automatic: false)
        } catch { errorMessage = error.localizedDescription }
    }

    func rename(_ id: String, name: String) async {
        guard canManageProfiles, !isPendingDeletion(id), canEdit, !isSwitching, !isLoading, transition == nil, let snapshot else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var archive = snapshot.archive
            guard let index = archive.profiles.firstIndex(where: { $0.id == id }) else { throw AppProfileError.stale }
            archive.profiles[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            try archive.validate()
            let saved = try await registry.save(archive, replacing: snapshot.revision)
            install(saved)
            if current.profile.id == id { current.profile = saved.archive.profiles[index] }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func switchTo(_ id: String, automatic: Bool = false) async {
        guard canManageProfiles, !isPendingDeletion(id), canEdit, !isSwitching, !isLoading, !quitting, let snapshot,
              let profile = snapshot.archive.profiles.first(where: { $0.id == id }) else { return }
        if profile.id == current.profile.id {
            // Explicitly choosing the fallback profile also persists that choice.
            guard !automatic, snapshot.archive.selectedID != id else { return }
        }
        await begin(profile: profile, staged: snapshot.archive, persistPending: false, automatic: automatic)
    }

    func shutdown() async {
        quitting = true
        bind(nil, activationID)
        let initial = current
        initial.quiesce()
        await transition?.value
        if current !== initial { current.quiesce() }
        await deletion?.stopAndWait()
        await current.settle()
        await current.shutdown()
    }

    func accepts(_ id: UUID) -> Bool { id == activationID && !isLoading && !isSwitching && !quitting }

    private func begin(profile: AppProfile, staged: AppProfileArchive, persistPending: Bool, automatic: Bool) async {
        guard transition == nil, !quitting else { return }
        let task = Task { await perform(profile: profile, staged: staged, persistPending: persistPending, automatic: automatic) }
        transition = task
        await task.value
        transition = nil
    }

    private func perform(profile: AppProfile, staged: AppProfileArchive, persistPending: Bool, automatic: Bool) async {
        guard let snapshot else { return }
        isSwitching = true; errorMessage = nil
        let previous = current
        activationID = identifier(); bind(nil, activationID)
        previous.quiesce()
        await previous.settle()
        do {
            var working = snapshot
            if persistPending { working = try await registry.save(staged, replacing: working.revision); install(working) }
            guard !automatic || profile.isInitialized else { throw AppProfileError.missingStore }
            let prepared = try await prepare(profile, !automatic && !profile.isInitialized)
            var archive = working.archive
            guard let index = archive.profiles.firstIndex(where: { $0.id == profile.id }) else { throw AppProfileError.stale }
            archive.profiles[index].isInitialized = true
            archive.selectedID = profile.id
            if archive != working.archive {
                working = try await registry.save(archive, replacing: working.revision)
                install(working)
            }
            await previous.shutdown()
            let next = prepared.activate()
            next.profile = archive.profiles[index]
            current = next; activationID = identifier()
            if !quitting { bind(next, activationID); await next.startPaused() }
        } catch {
            errorMessage = error.localizedDescription
            if !quitting {
                previous.resumePausedOwnership()
                bind(previous, activationID); await previous.startPaused()
            }
        }
        isSwitching = false
    }

    private func install(_ value: AppProfileRegistrySnapshot) {
        snapshot = value; profiles = value.archive.profiles
        deletionJournals = value.archive.deletions
        savedSelectionID = value.archive.selectedID; canEdit = true
    }
}
