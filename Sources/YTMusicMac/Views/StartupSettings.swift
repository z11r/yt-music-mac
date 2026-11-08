import ServiceManagement
import SwiftUI

struct StartupSettings: View {
    var windowPreferences: StartupWindowPreferences? = nil
    @State private var loginItem = LoginItemController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let windowPreferences {
                Picker(StartupWindowText.text("When the App Opens"), selection: Binding(
                    get: { windowPreferences.selection }, set: { windowPreferences.select($0) })) {
                    ForEach(StartupWindowPolicy.allCases, id: \.self) { policy in
                        Text(verbatim: policy.title).tag(policy).disabled(policy != .system && !windowPreferences.supportsSelection)
                    }
                }
                Text(verbatim: StartupWindowText.text("Window changes apply next launch to all local profiles. Playback stays paused. The Dock and menu bar remain available."))
                    .font(.caption).foregroundStyle(.secondary)
                if !windowPreferences.supportsSelection {
                    Text(verbatim: StartupWindowText.text("Window selection requires macOS 15 or later. This Mac uses its current main-window and restoration behavior; saved choices are kept."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if windowPreferences.hasUnknownValue {
                    Text(verbatim: StartupWindowText.text("This saved window setting is not supported. It was kept; macOS window settings will be used."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
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
