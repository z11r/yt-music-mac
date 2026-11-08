import ServiceManagement
import SwiftUI

struct StartupSettings: View {
    @State private var loginItem = LoginItemController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
        Toggle("Launch at Login", isOn: Binding(
            get: { loginItem.isEnabled },
            set: { value in Task { await loginItem.setEnabled(value) } }
        ))
        .disabled(!loginItem.isInstalled || loginItem.isUpdating)
        if !loginItem.isInstalled {
            Text("Move the app to Applications to enable launch at login.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if loginItem.state == .requiresApproval {
            Text("Allow this login item in System Settings to finish enabling it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if loginItem.isInstalled {
            Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
        }
        if let message = loginItem.errorMessage {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        }
        .onChange(of: scenePhase) { if scenePhase == .active { loginItem.refresh() } }
    }
}
