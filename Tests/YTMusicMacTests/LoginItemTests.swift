import Foundation
import Testing
@testable import YTMusicMac

@MainActor
@Suite("Login item", .serialized)
struct LoginItemTests {
    @Test func initializationAndRefreshNeverRegister() {
        let fixture = LoginFixture()
        let controller = LoginItemController(access: fixture.access, isInstalled: true)
        #expect(controller.state == .disabled)
        fixture.state = .enabled
        controller.refresh()
        #expect(controller.isEnabled)
        #expect(fixture.writes.isEmpty)
    }

    @Test func onlyAnExplicitToggleChangesRegistration() async {
        let fixture = LoginFixture()
        let controller = LoginItemController(access: fixture.access, isInstalled: true)
        await controller.setEnabled(true)
        #expect(controller.state == .enabled)
        await controller.setEnabled(false)
        #expect(controller.state == .disabled)
        #expect(fixture.writes == [true, false])
    }

    @Test func failedRegistrationUsesActualStateAndOffersRecovery() async {
        let fixture = LoginFixture()
        fixture.shouldFail = true
        let controller = LoginItemController(access: fixture.access, isInstalled: true)
        await controller.setEnabled(true)
        #expect(controller.state == .disabled)
        #expect(controller.errorMessage != nil)
        #expect(!controller.isUpdating)
    }

    @Test func uninstalledBuildCannotChangeLoginItems() async {
        let fixture = LoginFixture()
        let controller = LoginItemController(access: fixture.access, isInstalled: false)
        await controller.setEnabled(true)
        #expect(controller.state == .unavailable)
        #expect(fixture.writes.isEmpty)
    }

    @Test func pendingApprovalIsDistinctFromEnabled() {
        let fixture = LoginFixture()
        fixture.state = .requiresApproval
        let controller = LoginItemController(access: fixture.access, isInstalled: true)
        #expect(controller.state == .requiresApproval)
        #expect(controller.isEnabled)
        #expect(fixture.writes.isEmpty)
    }
}

@MainActor
private final class LoginFixture {
    var state: LoginItemState = .disabled
    var writes: [Bool] = []
    var shouldFail = false
    var access: LoginItemAccess {
        LoginItemAccess(status: { self.state }, setEnabled: { value in
            self.writes.append(value)
            if self.shouldFail { throw CocoaError(.fileWriteNoPermission) }
            self.state = value ? .enabled : .disabled
        })
    }
}
