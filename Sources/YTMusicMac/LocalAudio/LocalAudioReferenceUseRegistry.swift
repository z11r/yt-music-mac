import Foundation
import MusicCore

/// Process-local reference ownership only. Metadata CAS and other app processes use separate OS locks.
final class LocalAudioReferenceUseRegistry: @unchecked Sendable {
    let profileStorageID: UUID
    private let lock = NSLock()
    private struct Entry { var uses = 0; var removal: UUID? }
    private var entries: [LocalAudioReference: Entry] = [:]
    private let maximumEntries: Int
    private let maximumUses: Int
    init(profileStorageID: UUID, maximumEntries: Int = 2_000, maximumUses: Int = 4_096) {
        self.profileStorageID = profileStorageID
        self.maximumEntries = min(2_000, max(1, maximumEntries)); self.maximumUses = min(4_096, max(1, maximumUses))
    }
    func acquireUse(_ reference: LocalAudioReference) throws -> LocalAudioReferenceUse {
        try lock.withLock {
            var entry = entries[reference] ?? Entry()
            guard entry.removal == nil, entries[reference] != nil || entries.count < maximumEntries,
                  entries.values.reduce(0, { $0 + $1.uses }) < maximumUses else { throw LocalAudioPlaybackIssue.busy }
            entry.uses += 1; entries[reference] = entry
            return LocalAudioReferenceUse(registry: self, reference: reference)
        }
    }
    func reserveRemoval(_ reference: LocalAudioReference) throws -> LocalAudioRemovalReservation {
        try lock.withLock {
            let entry = entries[reference] ?? Entry()
            guard entry.uses == 0, entry.removal == nil, entries[reference] != nil || entries.count < maximumEntries else {
                throw LocalAudioPlaybackIssue.busy
            }
            let id = UUID(); entries[reference] = Entry(uses: 0, removal: id)
            return LocalAudioRemovalReservation(registry: self, reference: reference, id: id)
        }
    }
    func useCount(_ reference: LocalAudioReference) -> Int { lock.withLock { entries[reference]?.uses ?? 0 } }
    fileprivate func reviewUse(_ reference: LocalAudioReference, reservation: UUID) throws -> LocalAudioReferenceUse {
        try lock.withLock {
            guard var entry = entries[reference], entry.removal == reservation,
                  entries.values.reduce(0, { $0 + $1.uses }) < maximumUses else { throw LocalAudioPlaybackIssue.busy }
            entry.uses += 1; entries[reference] = entry
            return LocalAudioReferenceUse(registry: self, reference: reference)
        }
    }
    fileprivate func endUse(_ reference: LocalAudioReference) {
        lock.withLock {
            guard var entry = entries[reference], entry.uses > 0 else { return }
            entry.uses -= 1
            if entry.uses == 0 && entry.removal == nil { entries[reference] = nil } else { entries[reference] = entry }
        }
    }
    fileprivate func endRemoval(_ reference: LocalAudioReference, id: UUID) {
        lock.withLock {
            guard var entry = entries[reference], entry.removal == id else { return }
            entry.removal = nil
            if entry.uses == 0 { entries[reference] = nil } else { entries[reference] = entry }
        }
    }
}

final class LocalAudioReferenceUse: Sendable {
    let registry: LocalAudioReferenceUseRegistry
    let reference: LocalAudioReference
    fileprivate init(registry: LocalAudioReferenceUseRegistry, reference: LocalAudioReference) { self.registry = registry; self.reference = reference }
    deinit { registry.endUse(reference) }
}
final class LocalAudioRemovalReservation: @unchecked Sendable {
    let reference: LocalAudioReference
    let profileStorageID: UUID
    private let registry: LocalAudioReferenceUseRegistry
    private let id: UUID
    private let lock = NSLock()
    private var released = false
    fileprivate init(registry: LocalAudioReferenceUseRegistry, reference: LocalAudioReference, id: UUID) {
        self.registry = registry; self.reference = reference; self.id = id; profileStorageID = registry.profileStorageID
    }
    func release() {
        let shouldRelease = lock.withLock { if released { return false }; released = true; return true }
        if shouldRelease { registry.endRemoval(reference, id: id) }
    }
    /// Private reauthorization review only; it grants no library/playback membership proof.
    func acquireReviewUse() throws -> LocalAudioReferenceUse {
        guard lock.withLock({ !released }) else { throw LocalAudioPlaybackIssue.stale }
        return try registry.reviewUse(reference, reservation: id)
    }
    deinit { release() }
}

/// Inject one factory-owned pool across reactivated runtimes; old retained uses keep its weak entry alive.
@MainActor final class LocalAudioReferenceUseRegistryPool {
    private final class WeakEntry { weak var registry: LocalAudioReferenceUseRegistry?; init(_ value: LocalAudioReferenceUseRegistry) { registry = value } }
    private var entries: [UUID: WeakEntry] = [:]
    func registry(for context: AppProfileContext) throws -> LocalAudioReferenceUseRegistry {
        entries = entries.filter { $0.value.registry != nil }
        if let existing = entries[context.websiteDataIdentifier]?.registry { return existing }
        guard entries.count < AppProfileArchive.maximumProfiles else { throw LocalAudioPlaybackIssue.busy }
        let value = LocalAudioReferenceUseRegistry(profileStorageID: context.websiteDataIdentifier)
        entries[context.websiteDataIdentifier] = WeakEntry(value); return value
    }
}
