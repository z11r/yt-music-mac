import Foundation
import Observation

/// A durable running marker always precedes a destructive call. Interrupted
/// steps are probed during an explicit review, never retried at app startup.
@MainActor @Observable
final class AppProfileDeletionController {
    private(set) var review: ProfileDeletionReview?
    private(set) var isWorking = false
    private(set) var message: String?
    @ObservationIgnored private let registry: any AppProfileRegistry
    @ObservationIgnored private let adapter: any ProfileCleanupPreparing
    @ObservationIgnored private let changed: (AppProfileRegistrySnapshot) -> Void
    @ObservationIgnored private var cleanup: (any ProfileCleanupSession)?
    @ObservationIgnored private var admitted: () -> Bool = { false }
    @ObservationIgnored private var activeID = ""
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(registry: any AppProfileRegistry, adapter: any ProfileCleanupPreparing,
         changed: @escaping (AppProfileRegistrySnapshot) -> Void) {
        self.registry = registry; self.adapter = adapter; self.changed = changed
    }
    func prepare(id: String, activeID: String, isCurrent: @escaping () -> Bool) async {
        guard !isWorking else { return }
        cancelReview(); admitted = isCurrent; self.activeID = activeID; stopping = false
        guard isCurrent() else { message = ProfileCleanupProblem.stale.message; return }
        isWorking = true
        let operation = Task { await self.prepareReview(id: id, isCurrent: isCurrent) }
        task = operation; await operation.value; task = nil; isWorking = false
    }
    private func prepareReview(id: String, isCurrent: @escaping () -> Bool) async {
        do {
            guard isCurrent(), !stopping else { throw ProfileCleanupProblem.stale }
            let snapshot = try await registry.load()
            guard isCurrent(), !stopping, let target = snapshot.archive.profiles.first(where: { $0.id == id }) else { throw ProfileCleanupProblem.stale }
            try protect(target, archive: snapshot.archive)
            guard snapshot.archive.deletions.isEmpty || snapshot.archive.deletions[0].target == target else { throw ProfileCleanupProblem.busy }
            var probes: [ProfileCleanupProbe]
            do {
                let session = try await adapter.prepare(target)
                guard isCurrent(), !stopping else { session.close(); throw ProfileCleanupProblem.stale }
                cleanup = session
                probes = []
                let journal = snapshot.archive.deletions.first
                for step in ProfileCleanupStep.allCases {
                    guard isCurrent(), !stopping else { throw ProfileCleanupProblem.stale }
                    let state = journal?.states[step.index] ?? .pending
                    let probe = await session.probe(step, state: state)
                    probes.append(state == .complete && probe == .ready ? .blocked(.unavailable) : probe)
                }
            } catch let problem as ProfileCleanupProblem {
                cleanup?.close(); cleanup = nil
                probes = Array(repeating: .blocked(problem), count: ProfileCleanupStep.allCases.count)
            }
            guard isCurrent(), !stopping else { throw ProfileCleanupProblem.stale }
            review = .init(snapshot: snapshot, target: target, probes: probes)
            message = nil
        } catch { cleanup?.close(); cleanup = nil; message = failureMessage(error) }
    }
    func confirm(reviewID: UUID) async {
        guard !isWorking, let review, review.id == reviewID, admitted() else { message = ProfileCleanupProblem.stale.message; return }
        isWorking = true; stopping = false
        let operation = Task { await self.perform(review) }
        task = operation; await operation.value; task = nil; isWorking = false
    }
    func cancelStagedDeletion(reviewID: UUID) async {
        guard !isWorking, let review, review.id == reviewID, admitted(),
              let journal = review.snapshot.archive.deletions.first,
              journal.states.allSatisfy({ $0 == .pending }) else { return }
        isWorking = true; stopping = false
        let operation = Task {
            defer { self.cleanup?.close(); self.cleanup = nil; self.review = nil }
            do {
                guard self.admitted(), !self.stopping else { throw ProfileCleanupProblem.stale }
                let latest = try await self.registry.load()
                guard self.admitted(), !self.stopping, latest == review.snapshot else { throw ProfileCleanupProblem.stale }
                var archive = review.snapshot.archive; archive.deletions = []
                let saved = try await self.registry.save(archive, replacing: review.snapshot.revision)
                self.changed(saved)
                self.message = AppLocalization.text("Staged deletion canceled. The profile data was retained.")
            } catch { self.message = self.failureMessage(error) }
        }
        task = operation; await operation.value; task = nil; isWorking = false
    }
    func cancelReview() {
        if isWorking { stopping = true; return }
        cleanup?.close(); cleanup = nil; review = nil
    }
    func stopAndWait() async {
        stopping = true; await task?.value
        cleanup?.close(); cleanup = nil; review = nil
    }

    private func perform(_ review: ProfileDeletionReview) async {
        defer { cleanup?.close(); cleanup = nil; self.review = nil }
        do {
            guard admitted(), !stopping else { throw ProfileCleanupProblem.stale }
            var working = try await registry.load()
            guard admitted(), working == review.snapshot else { throw ProfileCleanupProblem.stale }
            try protect(review.target, archive: working.archive)
            var journal = working.archive.deletions.first ?? ProfileDeletionJournal(target: review.target)
            var archive = AppProfileArchive(version: 2, selectedID: working.archive.selectedID,
                profiles: working.archive.profiles, deletions: [journal])
            journal.problem = review.problem; archive.deletions = [journal]
            working = try await registry.save(archive, replacing: working.revision); changed(working)
            guard review.problem == nil, let cleanup else {
                message = review.problem?.message ?? ProfileCleanupProblem.unavailable.message; return
            }
            for step in ProfileCleanupStep.allCases {
                try await validatePrerequisites(cleanup, journal: journal, snapshot: working)
                let probe = await cleanup.probe(step, state: journal.states[step.index])
                if let problem = probe.problem { throw problem }
                if journal.states[step.index] == .complete && probe == .ready { throw ProfileCleanupProblem.unavailable }
                guard admitted(), !stopping else { throw ProfileCleanupProblem.stale }
                if probe == .absent || probe == .confirmed {
                    journal.states[step.index] = .complete
                } else {
                    let beforeRunning = journal
                    journal.states[step.index] = .running; journal.problem = nil
                    archive.deletions = [journal]
                    working = try await registry.save(archive, replacing: working.revision); changed(working)
                    guard admitted(), !stopping else { throw ProfileCleanupProblem.stale }
                    do {
                        // This operation has not been admitted yet. Probe with
                        // its prior state, rather than treating our new marker
                        // as an interrupted native call.
                        try await validatePrerequisites(cleanup, journal: beforeRunning, snapshot: working)
                    } catch {
                        if admitted(), !stopping {
                            journal = beforeRunning; journal.problem = (error as? ProfileCleanupProblem) ?? .unavailable
                            archive.deletions = [journal]
                            if let saved = try? await registry.save(archive, replacing: working.revision) { working = saved; changed(saved) }
                        }
                        throw error
                    }
                    do { try await cleanup.remove(step) }
                    catch {
                        journal.states[step.index] = .uncertain; journal.problem = (error as? ProfileCleanupProblem) ?? .unavailable
                        archive.deletions = [journal]
                        if let saved = try? await registry.save(archive, replacing: working.revision) { working = saved; changed(saved) }
                        throw error
                    }
                    journal.states[step.index] = .complete
                }
                archive.deletions = [journal]
                working = try await registry.save(archive, replacing: working.revision); changed(working)
            }
            guard admitted(), !stopping, try await registry.load() == working else { throw ProfileCleanupProblem.stale }
            for step in ProfileCleanupStep.allCases.filter({ $0 != .website }) + [.website] {
                guard admitted(), !stopping else { throw ProfileCleanupProblem.stale }
                let probe = await cleanup.probe(step, state: .complete)
                guard probe == .absent || probe == .confirmed else { throw probe.problem ?? .unavailable }
            }
            archive.profiles.removeAll { $0.id == review.target.id }; archive.deletions = []
            guard admitted(), !stopping else { throw ProfileCleanupProblem.stale }
            let saved = try await registry.save(archive, replacing: working.revision); changed(saved)
            message = AppLocalization.text("The additional local profile was deleted. External exports and YouTube service data were not removed.")
        } catch { message = failureMessage(error) }
    }
    private func validatePrerequisites(_ cleanup: any ProfileCleanupSession, journal: ProfileDeletionJournal,
                                       snapshot: AppProfileRegistrySnapshot) async throws {
        for step in ProfileCleanupStep.allCases.filter({ $0 != .website }) + [.website] {
            guard admitted(), !stopping else { throw ProfileCleanupProblem.stale }
            let state = journal.states[step.index]
            let probe = await cleanup.probe(step, state: state)
            guard admitted(), !stopping else { throw ProfileCleanupProblem.stale }
            if let problem = probe.problem { throw problem }
            if state == .complete && probe == .ready { throw ProfileCleanupProblem.unavailable }
        }
        guard admitted(), !stopping else { throw ProfileCleanupProblem.stale }
        let latest = try await registry.load()
        guard admitted(), !stopping, latest == snapshot else { throw ProfileCleanupProblem.stale }
    }
    private func failureMessage(_ error: any Error) -> String {
        if let problem = error as? ProfileCleanupProblem { return problem.message }
        if let error = error as? AppProfileError, error == .unavailable { return ProfileCleanupProblem.unavailable.message }
        return error.localizedDescription
    }
    private func protect(_ target: AppProfile, archive: AppProfileArchive) throws {
        guard !target.isDefault, target.id != activeID, target.id != archive.selectedID else { throw ProfileCleanupProblem.protectedProfile }
    }
}
