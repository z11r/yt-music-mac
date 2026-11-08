import Foundation
import Observation
import ServiceManagement

enum LoginItemState: Equatable {
    case disabled, enabled, requiresApproval, unavailable
}

struct LoginItemAccess {
    var status: @MainActor () -> LoginItemState
    var setEnabled: @MainActor (Bool) async throws -> Void

    static var system: LoginItemAccess {
        LoginItemAccess(status: {
            switch SMAppService.mainApp.status {
            case .enabled: .enabled
            case .notRegistered: .disabled
            case .requiresApproval: .requiresApproval
            case .notFound: .unavailable
            @unknown default: .unavailable
            }
        }, setEnabled: { enabled in
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
        })
    }
}

@MainActor @Observable
final class LoginItemController {
    private(set) var state: LoginItemState = .unavailable
    private(set) var isUpdating = false
    private(set) var errorMessage: String?
    let isInstalled: Bool
    @ObservationIgnored private let access: LoginItemAccess

    init(access: LoginItemAccess = .system, isInstalled: Bool = LoginItemController.isInstalledApp) {
        self.access = access
        self.isInstalled = isInstalled
        refresh()
    }

    var isEnabled: Bool { state == .enabled || state == .requiresApproval }

    func refresh() {
        state = isInstalled ? access.status() : .unavailable
    }

    func setEnabled(_ enabled: Bool) async {
        guard isInstalled, !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        defer { refresh(); isUpdating = false }
        do { try await access.setEnabled(enabled) }
        catch { errorMessage = "The login item could not be changed. Check Login Items in System Settings." }
    }

    static var isInstalledApp: Bool {
        let url = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return Bundle.main.bundleIdentifier == AppIdentity.identifier && url.pathExtension == "app" &&
            url.deletingLastPathComponent().lastPathComponent == "Applications"
    }
}
