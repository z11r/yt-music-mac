import Foundation
import MusicCore
import Observation

@MainActor @Observable final class LocalAudioLibraryController<Target: Equatable & Sendable> {
    private(set) var owner: LocalAudioLibraryOwner
    private(set) var presentation = UUID()
    private(set) var document: LocalAudioLibraryDocument?
    private(set) var review: LocalAudioImportReview?
    private(set) var isOpen = false
    private(set) var isBusy = false
    private(set) var canWrite = false
    private(set) var message: String?
    @ObservationIgnored private let store: any LocalAudioLibraryStoring
    @ObservationIgnored private let profiles: any LocalAudioProfileLifetimeProviding
    @ObservationIgnored private let references: LocalAudioReferenceUseRegistry
    @ObservationIgnored private let picker: any LocalAudioLibraryFilePicking
    @ObservationIgnored private let probe: any LocalAudioImportProbing
    @ObservationIgnored private let reads: LocalAudioReadAdmission
    @ObservationIgnored private let preparations: LocalAudioPreparationAdmission
    @ObservationIgnored private let current: @MainActor (LocalAudioLibraryOwner) -> Bool
    @ObservationIgnored private let actions: LocalAudioLibraryQueueActions<Target>?
    @ObservationIgnored private let identifier: @MainActor () -> UUID
    @ObservationIgnored private let operations = ProfileOperationFence()
    @ObservationIgnored private var workers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var draft: LocalAudioPrivateImportDraft?
    @ObservationIgnored private var permission: LocalAudioLibraryWritePermission?

    init(owner: LocalAudioLibraryOwner, store: any LocalAudioLibraryStoring,
         profiles: any LocalAudioProfileLifetimeProviding, references: LocalAudioReferenceUseRegistry,
         picker: any LocalAudioLibraryFilePicking, probe: any LocalAudioImportProbing,
         reads: LocalAudioReadAdmission = .shared, preparations: LocalAudioPreparationAdmission = .shared,
         actions: LocalAudioLibraryQueueActions<Target>? = nil,
         identifier: @escaping @MainActor () -> UUID = UUID.init, isCurrent: @escaping @MainActor (LocalAudioLibraryOwner) -> Bool) {
        self.owner = owner; self.store = store; self.profiles = profiles; self.references = references
        self.picker = picker; self.probe = probe; self.reads = reads; self.preparations = preparations
        self.actions = actions; self.identifier = identifier; current = isCurrent
    }

    var scope: LocalAudioLibraryUIScope { .init(owner: owner, presentation: presentation) }
    var records: [LocalAudioLibraryRecord] { document?.records ?? [] }
    var hasQueueActions: Bool { actions != nil }
    var queueTarget: Target? { accepts(scope) ? actions?.capture(owner) : nil }

    func open(expectedOwner: LocalAudioLibraryOwner) async {
        guard owner == expectedOwner, current(owner), references.profileStorageID == owner.profileStorageID else { return }
        quiesce()
        presentation = identifier(); isOpen = true
        let captured = scope
        await operations.waitForIdle()
        guard accepts(captured) else { return }
        operations.resume()
        await refresh(expected: captured)?.value
    }

    /// Close revokes future IO synchronously; accepted work retains its original
    /// profile resources and is drained separately by the persistent owner.
    func quiesce() {
        isOpen = false; presentation = identifier(); operations.quiesce()
        permission?.revoke(); picker.cancel()
        workers.values.forEach { $0.cancel() }
        clearDraft(); document = nil; canWrite = false; message = nil
    }
    func waitForIdle() async { await operations.waitForIdle() }
    func resume(owner newOwner: LocalAudioLibraryOwner) {
        guard newOwner.profileStorageID == owner.profileStorageID, !isBusy else { return }
        quiesce(); owner = newOwner; operations.resume()
    }
    func cancelReview() {
        permission?.revoke(); picker.cancel(); workers.values.forEach { $0.cancel() }
        clearDraft()
    }

    @discardableResult func refresh(expected: LocalAudioLibraryUIScope) -> Task<Void, Never>? {
        guard accepts(expected), !isBusy else { return nil }
        clearDraft(); canWrite = false
        return start(expected) {
            do {
                let authorization = self.authorization(expected)
                let lifetime = try await self.acquire(authorization)
                defer { withExtendedLifetime(lifetime) {} }
                try self.check(expected)
                guard lifetime.profileStorageID == self.owner.profileStorageID else { throw LocalAudioLibraryIssue.stale }
                let value = try await self.readDocument(authorization)
                try self.check(expected)
                self.document = value; self.canWrite = true; self.message = nil
            } catch {
                guard self.accepts(expected) else { return }
                self.document = nil; self.canWrite = false
                self.message = (LocalAudioLibraryIssue.mapped(error) == .busy ? LocalAudioLibraryIssue.busy : .libraryUnavailable).message
            }
        }
    }

    @discardableResult func chooseFiles(expected: LocalAudioLibraryUIScope, reauthorizing reference: LocalAudioReference? = nil) -> Task<Void, Never>? {
        guard accepts(expected), !isBusy, canWrite else { return nil }
        clearDraft()
        return start(expected) {
            var reservation: LocalAudioRemovalReservation?
            var transferred = false
            defer { if !transferred { reservation?.release() } }
            do {
                let authorization = self.authorization(expected)
                let lifetime = try await self.acquire(authorization)
                defer { withExtendedLifetime(lifetime) {} }
                try self.check(expected)
                guard lifetime.profileStorageID == expected.owner.profileStorageID else { throw LocalAudioLibraryIssue.stale }
                let snapshot = try await self.readDocument(authorization)
                try self.check(expected)
                guard snapshot == self.document else { throw LocalAudioLibraryIssue.conflict }
                let purpose: LocalAudioImportPurpose
                let libraryID: UUID
                if let reference {
                    guard let snapshot else { throw LocalAudioLibraryIssue.libraryUnavailable }
                    let record = try snapshot.record(for: reference)
                    reservation = try self.reserve(reference)
                    purpose = .reauthorize(reference, record.identity); libraryID = snapshot.libraryID
                } else {
                    guard (snapshot?.records.count ?? 0) < LocalAudioLibraryDocument.maximumRecords else { throw LocalAudioLibraryIssue.capacity }
                    purpose = .importFiles; libraryID = snapshot?.libraryID ?? self.identifier()
                }
                try self.check(expected)
                // The task may have been queued before a window/profile closed.
                let urls = await self.picker.chooseFiles(multiple: reference == nil)
                try self.check(expected)
                guard let urls else { return }
                guard !urls.isEmpty, urls.count <= (reference == nil ? 100 : 1),
                      urls.allSatisfy({ $0.absoluteString.utf8.count <= 8_192 }) else { throw LocalAudioLibraryIssue.fileLimit }
                let rows = urls.map { url in
                    LocalAudioImportRow(id: self.identifier(), filename: self.displayName(url), status: .checking)
                }
                guard Set(rows.map(\.id)).count == rows.count else { throw LocalAudioLibraryIssue.rejected }
                let privateDraft = LocalAudioPrivateImportDraft(id: self.identifier(), scope: expected, purpose: purpose,
                    snapshot: snapshot, libraryID: libraryID, lifetime: lifetime, reservation: reservation,
                    urls: Dictionary(uniqueKeysWithValues: zip(rows.map(\.id), urls)))
                self.draft = privateDraft; transferred = true
                self.review = .init(id: privateDraft.id, scope: expected, purpose: purpose, expectedRevision: snapshot?.revision,
                    libraryID: libraryID, rows: rows)
                var seen = snapshot?.records.map(\.identity) ?? []
                for (index, row) in rows.enumerated() {
                    try self.checkDraft(privateDraft)
                    guard let url = privateDraft.urls[row.id] else { throw LocalAudioLibraryIssue.stale }
                    do {
                        try self.validateURL(url)
                        let ref: LocalAudioReference
                        switch purpose {
                        case .importFiles: ref = .init(libraryID: libraryID, fileID: row.id)
                        case let .reauthorize(value, _): ref = value
                        }
                        let use = try reservation?.acquireReviewUse() ?? self.references.acquireUse(ref)
                        let context = LocalAudioImportProbeContext(reference: ref, lifetime: lifetime, use: use)
                        privateDraft.contexts[row.id] = context
                        let value = try await self.preparations.perform {
                            try authorization.check()
                            return try await self.probe.review(url, context: context)
                        }
                        try self.checkDraft(privateDraft)
                        try value.metadata.validate(); try value.identity.validate()
                        switch purpose {
                        case .importFiles:
                            guard !seen.contains(value.identity) else { throw LocalAudioLibraryIssue.duplicate }
                            seen.append(value.identity)
                        case let .reauthorize(_, identity):
                            guard value.identity == identity else { throw LocalAudioLibraryIssue.differentFile }
                        }
                        self.review?.rows[index].status = .ready(value)
                    } catch {
                        try self.checkDraft(privateDraft)
                        self.review?.rows[index].status = .issue(LocalAudioLibraryIssue.mapped(error))
                    }
                }
            } catch { self.show(error, expected) }
        }
    }

    @discardableResult func confirm(reviewID: UUID, selectedIDs: Set<UUID>, expected: LocalAudioLibraryUIScope) -> Task<Void, Never>? {
        guard accepts(expected), !isBusy, canWrite, let draft, !draft.consumed, draft.id == reviewID,
              let review, review.id == reviewID, !selectedIDs.isEmpty,
              selectedIDs.isSubset(of: Set(review.rows.filter { $0.reviewed != nil }.map(\.id))) else { return nil }
        let selected = review.rows.filter { selectedIDs.contains($0.id) }
        guard case .importFiles = draft.purpose else {
            return confirmSelected(draft, selected: selected, expected: expected)
        }
        guard (draft.snapshot?.records.count ?? 0) + selected.count <= LocalAudioLibraryDocument.maximumRecords else {
            message = LocalAudioLibraryIssue.capacity.message; return nil
        }
        return confirmSelected(draft, selected: selected, expected: expected)
    }

    private func confirmSelected(_ draft: LocalAudioPrivateImportDraft, selected: [LocalAudioImportRow], expected: LocalAudioLibraryUIScope) -> Task<Void, Never>? {
        guard accepts(expected), draft.scope == expected else { return nil }
        draft.consumed = true
        let permission = LocalAudioLibraryWritePermission(); self.permission = permission
        return start(expected) {
            defer {
                permission.revoke(); if self.permission === permission { self.permission = nil }
                draft.reservation?.release()
                if self.draft === draft { self.clearDraft() }
                withExtendedLifetime(draft) {}
            }
            var proposed: LocalAudioLibraryDocument?
            do {
                let authorization = draft.lifetime.authorization
                try self.checkDraft(draft, allowConsumed: true)
                let fresh = try await self.readDocument(authorization)
                try self.checkDraft(draft, allowConsumed: true)
                guard fresh == draft.snapshot else { throw LocalAudioLibraryIssue.conflict }
                var records = fresh?.records ?? []
                for row in selected {
                    try self.checkDraft(draft, allowConsumed: true)
                    guard let url = draft.urls[row.id], let context = draft.contexts[row.id], let original = row.reviewed else { throw LocalAudioLibraryIssue.stale }
                    let current = try await self.preparations.perform {
                        try authorization.check(); return try await self.probe.review(url, context: context)
                    }
                    try self.checkDraft(draft, allowConsumed: true)
                    guard current == original else { throw LocalAudioLibraryIssue.changedFile }
                    let bookmark = try await self.probe.confirmedBookmark(url, expected: original, context: context)
                    try self.checkDraft(draft, allowConsumed: true); try bookmark.validate()
                    let record = LocalAudioLibraryRecord(reference: context.reference, metadata: original.metadata, identity: original.identity, bookmark: bookmark)
                    try record.validate()
                    switch draft.purpose {
                    case .importFiles:
                        guard !records.contains(where: { $0.identity == record.identity || $0.id == record.id }) else { throw LocalAudioLibraryIssue.duplicate }
                        records.append(record)
                    case let .reauthorize(reference, identity):
                        guard selected.count == 1, identity == record.identity,
                              let index = records.firstIndex(where: { $0.reference == reference }) else { throw LocalAudioLibraryIssue.changedFile }
                        records[index] = record
                    }
                }
                let next = LocalAudioLibraryDocument(profileID: expected.owner.profileStorageID, libraryID: draft.libraryID,
                    revision: self.identifier(), records: records)
                try next.validate(); proposed = next
                try self.checkDraft(draft, allowConsumed: true)
                try await self.store.save(next, replacing: draft.snapshot?.revision, if: { permission.permits })
                guard self.accepts(expected) else { return }
                self.document = next; self.canWrite = true
                self.message = LocalAudioLibraryCopy.text("Local library saved. Your audio files were not copied or uploaded.")
            } catch {
                guard self.accepts(expected) else { return }
                if let proposed { await self.reconcile(proposed, scope: expected, authorization: draft.lifetime.authorization) }
                else { self.show(error, expected) }
            }
        }
    }

    @discardableResult func remove(_ reference: LocalAudioReference, revision: UUID, expected: LocalAudioLibraryUIScope) -> Task<Void, Never>? {
        guard accepts(expected), !isBusy, canWrite, let reviewed = document, reviewed.revision == revision,
              reviewed.records.contains(where: { $0.reference == reference }) else { return nil }
        let permission = LocalAudioLibraryWritePermission(); self.permission = permission
        return start(expected) {
            var reservation: LocalAudioRemovalReservation?
            var lifetime: LocalAudioProfileLifetime?
            defer {
                reservation?.release(); permission.revoke(); if self.permission === permission { self.permission = nil }
                withExtendedLifetime(lifetime) {}
            }
            var proposed: LocalAudioLibraryDocument?
            do {
                let authorization = self.authorization(expected)
                lifetime = try await self.acquire(authorization)
                try self.check(expected)
                reservation = try self.reserve(reference)
                let fresh = try await self.readDocument(authorization)
                try self.check(expected)
                guard fresh == reviewed else { throw LocalAudioLibraryIssue.conflict }
                let next = LocalAudioLibraryDocument(profileID: reviewed.profileID, libraryID: reviewed.libraryID,
                    revision: self.identifier(), records: reviewed.records.filter { $0.reference != reference })
                proposed = next
                try await self.store.save(next, replacing: revision, if: { permission.permits })
                guard self.accepts(expected) else { return }
                self.document = next
                self.message = LocalAudioLibraryCopy.text("Removed from this local library. The audio file was not deleted.")
            } catch {
                guard self.accepts(expected) else { return }
                if let proposed { await self.reconcile(proposed, scope: expected, authorization: self.authorization(expected)) }
                else { self.show(error, expected) }
            }
        }
    }

    /// The injected facade must fence its own asynchronous mutation against this
    /// captured target. Acceptance can itself advance the queue/intent revision.
    @discardableResult func requestQueueAction(play: Bool, selectedIDs: Set<UUID>, target: Target, expected: LocalAudioLibraryUIScope) -> Task<Void, Never>? {
        guard accepts(expected), !isBusy, let actions, actions.isCurrent(target, expected.owner), let reviewed = document,
              !selectedIDs.isEmpty, selectedIDs.count <= 100 else { return nil }
        let selected = reviewed.records.filter { selectedIDs.contains($0.id) }
        guard selected.count == selectedIDs.count else { return nil }
        return start(expected) {
            do {
                let authorization = self.authorization(expected)
                let lifetime = try await self.acquire(authorization)
                defer { withExtendedLifetime(lifetime) {} }
                try self.check(expected)
                let fresh = try await self.readDocument(authorization)
                try self.check(expected)
                guard fresh == reviewed, actions.isCurrent(target, expected.owner) else { throw LocalAudioLibraryIssue.queueChanged }
                let tracks = try selected.map { try $0.metadata.track(reference: $0.reference) }
                let accepted = await (play ? actions.play(tracks, target) : actions.add(tracks, target))
                try self.check(expected)
                self.message = accepted ? LocalAudioLibraryCopy.text("The queue request was accepted.") : LocalAudioLibraryIssue.rejected.message
            } catch { self.show(error, expected) }
        }
    }

    private func accepts(_ scope: LocalAudioLibraryUIScope) -> Bool {
        isOpen && self.scope == scope && current(scope.owner) && references.profileStorageID == scope.owner.profileStorageID
    }
    private func check(_ scope: LocalAudioLibraryUIScope) throws {
        try Task.checkCancellation(); guard accepts(scope) else { throw LocalAudioLibraryIssue.stale }
    }
    private func checkDraft(_ value: LocalAudioPrivateImportDraft, allowConsumed: Bool = false) throws {
        try check(value.scope)
        guard draft === value, !value.consumed || allowConsumed else { throw LocalAudioLibraryIssue.stale }
    }
    private func authorization(_ scope: LocalAudioLibraryUIScope) -> LocalAudioIOAuthorization {
        .init(profileStorageID: scope.owner.profileStorageID) { [weak self] in self?.accepts(scope) == true }
    }
    private func acquire(_ authorization: LocalAudioIOAuthorization) async throws -> LocalAudioProfileLifetime {
        try authorization.check()
        let lifetime = try await profiles.acquire(authorization: authorization)
        try authorization.check()
        guard lifetime.profileStorageID == authorization.profileStorageID else { throw LocalAudioLibraryIssue.stale }
        return lifetime
    }
    private func start(_ scope: LocalAudioLibraryUIScope, operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard accepts(scope), !isBusy, operations.begin() else { return nil }
        isBusy = true; message = nil
        let id = identifier()
        let task = Task {
            defer { self.workers[id] = nil; self.isBusy = !self.workers.isEmpty; self.operations.end() }
            guard self.accepts(scope), !Task.isCancelled else { return }
            await operation()
        }
        workers[id] = task; return task
    }
    private func readDocument(_ authorization: LocalAudioIOAuthorization) async throws -> LocalAudioLibraryDocument? {
        let store = store
        let value: LocalAudioLibraryDocument?
        do {
            value = try await reads.perform {
                try await authorization.check()
                return try await store.load()
            }
        } catch {
            if error is CancellationError || error is LocalAudioLibraryError || error is LocalAudioAccessError || error is LocalAudioPlaybackIssue {
                throw error
            }
            throw LocalAudioLibraryIssue.libraryUnavailable
        }
        try authorization.check()
        if let value { try value.validate(); guard value.profileID == authorization.profileStorageID else { throw LocalAudioLibraryError.wrongProfile } }
        return value
    }
    private func reconcile(_ proposed: LocalAudioLibraryDocument, scope: LocalAudioLibraryUIScope, authorization: LocalAudioIOAuthorization) async {
        canWrite = false
        do {
            let actual = try await readDocument(authorization)
            try check(scope)
            document = actual
            // Even exact readback cannot retroactively acknowledge a failed
            // durable commit. A new explicit reload/review is required.
            if actual == proposed { message = LocalAudioLibraryCopy.text("The reviewed records are present, but saving was not confirmed. Reload before another submission.") }
            else { message = LocalAudioLibraryIssue.unconfirmed.message }
        } catch { guard accepts(scope) else { return }; message = LocalAudioLibraryIssue.unconfirmed.message }
    }
    private func reserve(_ reference: LocalAudioReference) throws -> LocalAudioRemovalReservation {
        do { return try references.reserveRemoval(reference) } catch { throw LocalAudioLibraryIssue.inUse }
    }
    private func clearDraft() {
        draft?.reservation?.release(); draft = nil; review = nil
    }
    private func show(_ error: any Error, _ scope: LocalAudioLibraryUIScope) {
        guard accepts(scope) else { return }
        message = LocalAudioLibraryIssue.mapped(error).message
    }
    private func validateURL(_ url: URL) throws {
        try LocalAudioFilePolicy.validateURL(url)
        guard url.absoluteString.utf8.count <= 8_192, url.lastPathComponent.utf8.count <= 1_024 else { throw LocalAudioLibraryIssue.invalidFile }
    }
    private func displayName(_ url: URL) -> String {
        (try? validateURL(url)) != nil ? url.lastPathComponent : LocalAudioLibraryCopy.text("Unsupported File")
    }
}

@MainActor private final class LocalAudioPrivateImportDraft {
    let id: UUID
    let scope: LocalAudioLibraryUIScope
    let purpose: LocalAudioImportPurpose
    let snapshot: LocalAudioLibraryDocument?
    let libraryID: UUID
    let lifetime: LocalAudioProfileLifetime
    let reservation: LocalAudioRemovalReservation?
    let urls: [UUID: URL]
    var contexts: [UUID: LocalAudioImportProbeContext] = [:]
    var consumed = false
    init(id: UUID, scope: LocalAudioLibraryUIScope, purpose: LocalAudioImportPurpose, snapshot: LocalAudioLibraryDocument?,
         libraryID: UUID, lifetime: LocalAudioProfileLifetime, reservation: LocalAudioRemovalReservation?, urls: [UUID: URL]) {
        self.id = id; self.scope = scope; self.purpose = purpose; self.snapshot = snapshot; self.libraryID = libraryID
        self.lifetime = lifetime; self.reservation = reservation; self.urls = urls
    }
}
