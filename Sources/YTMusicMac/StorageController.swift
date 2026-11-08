import Foundation
import MusicCore
import Observation
import YouTubeMusic

@MainActor @Observable
final class StorageController {
    private(set) var scope = UUID()
    private(set) var protectedUsage: ProtectedStorageUsage?
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let inventory: ProtectedStorageInventory?
    @ObservationIgnored private let sessions: any MusicSessionProviding

    init(inventory: ProtectedStorageInventory?, sessions: any MusicSessionProviding) {
        self.inventory = inventory
        self.sessions = sessions
    }

    func invalidate() {
        scope = UUID()
        protectedUsage = nil
        errorMessage = nil
        isWorking = false
    }

    func refresh(expectedScope: UUID) async {
        guard scope == expectedScope, !isWorking, let inventory else { return }
        isWorking = true
        errorMessage = nil
        defer { if scope == expectedScope { isWorking = false } }
        do {
            let session = await sessions.snapshot()
            guard scope == expectedScope, session.isAuthenticated, let key = session.accountID,
                  NamedQueueStore.acceptsAccountKey(key) else { throw StorageAccessError.signInRequired }
            let usage = try await inventory.measure(accountKey: key)
            let current = await sessions.snapshot()
            guard scope == expectedScope, current.scope == session.scope, current.accountID == key,
                  current.isAuthenticated else { throw StorageAccessError.accountChanged }
            try Task.checkCancellation()
            protectedUsage = usage
        } catch {
            guard scope == expectedScope, !(error is CancellationError) else { return }
            if error is StorageAccessError { protectedUsage = nil }
            errorMessage = error.localizedDescription
        }
    }

    private enum StorageAccessError: Error, LocalizedError {
        case signInRequired, accountChanged
        var errorDescription: String? {
            switch self {
            case .signInRequired: "Sign in to a confirmed account to view its local storage usage."
            case .accountChanged: "The account changed. Open Storage again."
            }
        }
    }
}
