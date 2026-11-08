import Foundation
import MusicCore
import Observation
import YouTubeMusic

struct LibraryMetadataCaptureContext: Sendable {
    fileprivate let scope: UUID
    fileprivate let accountScope: UUID
    fileprivate let accountKey: String
    fileprivate let writeToken: LibraryMetadataWriteToken
    fileprivate let captureID: UUID
}

@MainActor @Observable
final class StorageController {
    private(set) var scope = UUID()
    private(set) var snapshot: LibraryMetadataSnapshot?
    private(set) var metadataBytes = 0
    private(set) var protectedUsage: ProtectedStorageUsage?
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var metadataEnabled: Bool
    @ObservationIgnored private let cache: LibraryMetadataCache?
    @ObservationIgnored private let inventory: ProtectedStorageInventory?
    @ObservationIgnored private let sessions: any MusicSessionProviding
    @ObservationIgnored private let preferences: UserDefaults?
    @ObservationIgnored private var latestCapture = UUID()

    init(cache: LibraryMetadataCache? = nil, inventory: ProtectedStorageInventory?,
         sessions: any MusicSessionProviding, preferences: UserDefaults? = nil) {
        self.cache = cache
        self.inventory = inventory
        self.sessions = sessions
        self.preferences = preferences
        metadataEnabled = preferences?.object(forKey: "cacheLibraryMetadata") == nil || preferences?.bool(forKey: "cacheLibraryMetadata") == true
    }

    var isAvailable: Bool { cache != nil }

    func invalidate() {
        scope = UUID()
        snapshot = nil
        metadataBytes = 0
        protectedUsage = nil
        errorMessage = nil
        isWorking = false
        latestCapture = UUID()
    }

    func setMetadataEnabled(_ enabled: Bool) {
        metadataEnabled = enabled
        preferences?.set(enabled, forKey: "cacheLibraryMetadata")
    }

    /// Capture before the library request begins, so old page metadata can never acquire a new account identity.
    func beginCapture() async -> LibraryMetadataCaptureContext? {
        guard metadataEnabled, let cache else { return nil }
        let request = scope
        let captureID = UUID()
        latestCapture = captureID
        let session = await sessions.snapshot()
        guard scope == request, metadataEnabled, session.isAuthenticated, let key = session.accountID,
              NamedQueueStore.acceptsAccountKey(key), !Task.isCancelled,
              let token = try? await cache.beginWrite(accountKey: key) else { return nil }
        return LibraryMetadataCaptureContext(scope: request, accountScope: session.scope, accountKey: key, writeToken: token, captureID: captureID)
    }

    func capture(_ page: MusicPage, context: LibraryMetadataCaptureContext) async {
        guard scope == context.scope, metadataEnabled, let cache, !Task.isCancelled else { return }
        let session = await sessions.snapshot()
        guard accepts(session, context: context), metadataEnabled, !Task.isCancelled else { return }
        let collections = (page.items + page.sections.flatMap(\.items)).compactMap { item -> LocalCollectionReference? in
            if case let .collection(value) = item { value.localReference } else { nil }
        }
        do {
            let result = try await cache.save(collections: collections, accountKey: context.accountKey, token: context.writeToken)
            let bytes = try await cache.storedBytes(accountKey: context.accountKey)
            let current = await sessions.snapshot()
            guard accepts(current, context: context), latestCapture == context.captureID, !Task.isCancelled else { return }
            snapshot = result
            metadataBytes = bytes
            errorMessage = nil
        } catch is CancellationError { }
        catch LibraryMetadataCacheError.superseded { }
        catch {
            guard scope == context.scope, latestCapture == context.captureID, !Task.isCancelled else { return }
            errorMessage = AppLocalization.text("Library metadata could not be cached. The existing file has been kept.")
        }
    }

    func refresh(expectedScope: UUID) async {
        guard scope == expectedScope, !isWorking, cache != nil || inventory != nil else { return }
        isWorking = true
        errorMessage = nil
        defer { if scope == expectedScope { isWorking = false } }
        do {
            let session = await sessions.snapshot()
            guard scope == expectedScope, session.isAuthenticated, let key = session.accountID,
                  NamedQueueStore.acceptsAccountKey(key) else { throw StorageAccessError.signInRequired }
            let bytes = try await cache?.storedBytes(accountKey: key) ?? 0
            let usage = try await inventory?.measure(accountKey: key)
            var cached: LibraryMetadataSnapshot?
            var readError: String?
            do { cached = try await cache?.load(accountKey: key) }
            catch { readError = error.localizedDescription }
            let current = await sessions.snapshot()
            guard scope == expectedScope, current.scope == session.scope, current.accountID == key,
                  current.isAuthenticated else { throw StorageAccessError.accountChanged }
            try Task.checkCancellation()
            metadataBytes = bytes
            protectedUsage = usage
            snapshot = cached
            errorMessage = readError
        } catch { handle(error, expectedScope: expectedScope) }
    }

    func clearMetadata(expectedScope: UUID) async {
        guard scope == expectedScope, !isWorking, let cache else { return }
        latestCapture = UUID()
        isWorking = true
        errorMessage = nil
        defer { if scope == expectedScope { isWorking = false } }
        do {
            let session = await sessions.snapshot()
            guard scope == expectedScope, session.isAuthenticated, let key = session.accountID,
                  NamedQueueStore.acceptsAccountKey(key) else { throw StorageAccessError.signInRequired }
            try Task.checkCancellation()
            try await cache.clear(accountKey: key)
            let current = await sessions.snapshot()
            guard scope == expectedScope, current.scope == session.scope, current.accountID == key,
                  current.isAuthenticated else { throw StorageAccessError.accountChanged }
            snapshot = nil
            metadataBytes = 0
        } catch { handle(error, expectedScope: expectedScope) }
    }

    private func accepts(_ session: MusicSession, context: LibraryMetadataCaptureContext) -> Bool {
        scope == context.scope && session.scope == context.accountScope && session.accountID == context.accountKey && session.isAuthenticated
    }

    private func handle(_ error: any Error, expectedScope: UUID) {
        guard scope == expectedScope, !(error is CancellationError) else { return }
        if error is StorageAccessError { snapshot = nil; metadataBytes = 0; protectedUsage = nil }
        errorMessage = error.localizedDescription
    }

    private enum StorageAccessError: Error, LocalizedError {
        case signInRequired, accountChanged
        var errorDescription: String? {
            switch self {
            case .signInRequired: AppLocalization.text("Sign in to a confirmed account to view its local metadata storage.")
            case .accountChanged: AppLocalization.text("The account changed. Open Storage again.")
            }
        }
    }
}
