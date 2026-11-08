import Foundation
import MusicCore
import Observation
import YouTubeMusic

protocol LibrarySpotlightIndex: Sendable {
    func index(_ records: [SpotlightCatalogRecord]) async throws
    func delete(domain: String) async throws
}

struct SpotlightLibrarySource: Sendable {
    fileprivate let scope: UUID
    fileprivate let accountScope: UUID
    fileprivate let accountKey: String
}

@MainActor @Observable
final class SpotlightLibraryController {
    private(set) var isEnabled: Bool
    private(set) var scope = UUID()
    private(set) var isWorking = false
    private(set) var lastSubmittedCount = 0
    private(set) var errorMessage: String?
    var isAvailable: Bool { index != nil }
    var hasIndexedMetadata: Bool { receipt != nil || receiptUnavailable }
    var isRemovalPending: Bool { receipt?.pendingRemoval == true || receiptUnavailable }
    @ObservationIgnored private let index: (any LibrarySpotlightIndex)?
    @ObservationIgnored private let sessions: any MusicSessionProviding
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored let policy: SpotlightCatalogPolicy
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var receipt: Receipt?
    @ObservationIgnored private var receiptUnavailable = false
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var pending: Intent?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var reconciliation: Task<Void, Never>?
    @ObservationIgnored private var references: [String: LocalCollectionReference] = [:]

    private struct Receipt: Codable {
        let version: Int
        let accountKey: String
        var count: Int
        var pendingRemoval: Bool
    }
    private struct Intent {
        let revision: UUID
        let accountKey: String?
        let records: [SpotlightCatalogRecord]
        let forceCleanup: Bool
    }

    init(index: (any LibrarySpotlightIndex)?, sessions: any MusicSessionProviding,
         preferences: UserDefaults, namespace: String, now: @escaping @Sendable () -> Date = Date.init) {
        self.index = index
        self.sessions = sessions
        self.preferences = preferences
        self.policy = SpotlightCatalogPolicy(namespace: namespace)
        self.now = now
        isEnabled = preferences.bool(forKey: "spotlightLibraryEnabled")
        if let data = preferences.data(forKey: "spotlightLibraryReceipt") {
            if data.count <= 1_024, let stored = try? JSONDecoder().decode(Receipt.self, from: data),
               stored.version == 1, NamedQueueStore.acceptsAccountKey(stored.accountKey),
               (0...SpotlightCatalogPolicy.recordLimit).contains(stored.count) {
                receipt = stored
                lastSubmittedCount = stored.count
            } else {
                receiptUnavailable = true
                errorMessage = AppLocalization.text("The Spotlight cleanup record is unsupported. Remove this app's indexed collections before indexing again.")
            }
        }
    }

    func quiesce() {
        scope = UUID(); revision = UUID(); pending = nil
        reconciliation?.cancel(); reconciliation = nil
        references.removeAll()
    }

    func start() {
        guard !receiptUnavailable else { return }
        if receipt?.pendingRemoval == true || (!isEnabled && receipt != nil) { enqueueCleanup() }
    }

    func setEnabled(_ enabled: Bool) {
        guard !enabled || isAvailable else { return }
        isEnabled = enabled
        preferences.set(enabled, forKey: "spotlightLibraryEnabled")
        revision = UUID()
        pending = nil
        errorMessage = receiptUnavailable ? errorMessage : nil
        if !enabled { enqueueCleanup() }
    }

    /// Preserve same-account receipts on a cold restore; invalidate all in-flight source identities.
    func accountChanged(isSignedIn: Bool) {
        reconciliation?.cancel()
        reconciliation = nil
        scope = UUID()
        revision = UUID()
        pending = nil
        references.removeAll()
        lastSubmittedCount = 0
        if !isSignedIn || worker != nil { enqueueCleanup(); return }
        let request = scope
        reconciliation = Task { [weak self] in
            guard let self else { return }
            let session = await self.sessions.snapshot()
            guard self.scope == request, !Task.isCancelled else { return }
            if !session.isAuthenticated || self.receipt?.accountKey != session.accountID {
                self.enqueueCleanup()
            } else { self.lastSubmittedCount = self.receipt?.count ?? 0 }
        }
    }

    func removeIndexedMetadata() {
        scope = UUID()
        references.removeAll()
        enqueueCleanup(force: true)
    }

    /// This identity is captured before a library request, even while indexing is disabled.
    func beginSource() async -> SpotlightLibrarySource? {
        guard isAvailable else { return nil }
        let request = scope
        let session = await sessions.snapshot()
        guard scope == request, !Task.isCancelled, session.isAuthenticated, let key = session.accountID,
              policy.domain(accountKey: key) != nil else { return nil }
        return SpotlightLibrarySource(scope: request, accountScope: session.scope, accountKey: key)
    }

    func capture(_ page: MusicPage, source: SpotlightLibrarySource) async {
        guard isEnabled, !receiptUnavailable, scope == source.scope, !Task.isCancelled else { return }
        let request = revision
        let session = await sessions.snapshot()
        guard isEnabled, revision == request, accepts(session, source: source), !Task.isCancelled else { return }
        let loaded = (page.items + page.sections.flatMap(\.items)).lazy.compactMap { item -> LocalCollectionReference? in
            // Only conservative catalog IDs pass the policy below; private/upload routes are excluded.
            if case let .collection(collection) = item, !collection.isUploaded { collection.localReference } else { nil }
        }
        let records = policy.records(from: loaded, accountKey: source.accountKey, now: now())
        enqueue(accountKey: source.accountKey, records: records)
    }

    func resolve(_ identifier: String) async -> LocalCollectionReference? {
        guard isEnabled, !receiptUnavailable, receipt?.pendingRemoval != true,
              policy.accountKey(in: identifier) != nil else { return nil }
        let request = scope
        let generation = revision
        let session = await sessions.snapshot()
        guard scope == request, revision == generation, isEnabled, receipt?.pendingRemoval != true,
              session.isAuthenticated, let key = session.accountID,
              let reference = policy.reference(for: identifier, accountKey: key) else { return nil }
        return references[identifier] ?? reference
    }

    func waitForIdle() async { await reconciliation?.value; await worker?.value }

    private func accepts(_ session: MusicSession, source: SpotlightLibrarySource) -> Bool {
        scope == source.scope && session.scope == source.accountScope && session.accountID == source.accountKey && session.isAuthenticated
    }

    private func enqueue(accountKey: String, records: [SpotlightCatalogRecord]) {
        revision = UUID()
        pending = Intent(revision: revision, accountKey: accountKey, records: records, forceCleanup: false)
        errorMessage = nil
        startWorker()
    }

    private func enqueueCleanup(force: Bool = false) {
        revision = UUID()
        references.removeAll()
        lastSubmittedCount = 0
        if var receipt { receipt.pendingRemoval = true; saveReceipt(receipt) }
        guard force || receipt != nil || receiptUnavailable || worker != nil else { return }
        pending = Intent(revision: revision, accountKey: nil, records: [], forceCleanup: force || receiptUnavailable)
        startWorker()
    }

    private func startWorker() {
        guard worker == nil, index != nil else { return }
        isWorking = true
        worker = Task { [weak self] in await self?.run() }
    }

    /// One writer waits for each OS acknowledgement. There is only one coalesced pending replacement.
    private func run() async {
        guard let index else { worker = nil; isWorking = false; return }
        while let next = pending {
            pending = nil
            do {
                if receipt != nil || receiptUnavailable || next.forceCleanup {
                    try await index.delete(domain: policy.rootDomain)
                    saveReceipt(nil)
                    receiptUnavailable = false
                    lastSubmittedCount = 0
                    errorMessage = nil
                }
                guard revision == next.revision, isEnabled, let key = next.accountKey, !next.records.isEmpty else { continue }
                saveReceipt(Receipt(version: 1, accountKey: key, count: 0, pendingRemoval: false))
                for offset in stride(from: 0, to: next.records.count, by: SpotlightCatalogPolicy.batchLimit) {
                    guard revision == next.revision, isEnabled else { break }
                    let end = min(offset + SpotlightCatalogPolicy.batchLimit, next.records.count)
                    try await index.index(Array(next.records[offset..<end]))
                }
                guard revision == next.revision, isEnabled else {
                    if pending == nil { enqueueCleanup() }
                    continue
                }
                saveReceipt(Receipt(version: 1, accountKey: key, count: next.records.count, pendingRemoval: false))
                references = Dictionary(uniqueKeysWithValues: next.records.map { ($0.identifier, $0.reference) })
                lastSubmittedCount = next.records.count
                errorMessage = nil
            } catch {
                if var receipt { receipt.pendingRemoval = true; saveReceipt(receipt) }
                pending = nil
                lastSubmittedCount = 0
                references.removeAll()
                errorMessage = AppLocalization.text("Spotlight could not finish updating this app's entries. Retry removing indexed collections before indexing again.")
                break
            }
        }
        worker = nil
        isWorking = false
    }

    private func saveReceipt(_ value: Receipt?) {
        receipt = value
        if let value, let data = try? JSONEncoder().encode(value) { preferences.set(data, forKey: "spotlightLibraryReceipt") }
        else { preferences.removeObject(forKey: "spotlightLibraryReceipt") }
    }
}
