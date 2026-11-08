import SwiftUI

struct SettingsView: View {
    @Bindable var session: AppSession
    var songNotifications: SongChangeNotifier? = nil
    @AppStorage("appearance", store: AppIdentity.preferences)
    private var appearance = "system"
    @Environment(\.openWindow) private var openWindow
    @State private var isSigningOut = false

    var body: some View {
        Form {
            Section("Startup") { StartupSettings() }
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section("Playback") {
                LabeledContent("Volume") { VolumeView(session: session).frame(width: 190) }
                LabeledContent("Sleep Timer") { SleepTimerMenu(session: session) }
                Toggle(isOn: Binding(get: { session.radio.autoplayEnabled }, set: { session.setAutoplayEnabled($0) })) {
                    Text("Autoplay")
                    Text("When the queue ends with repeat off, keep playing related songs.")
                }
                Button("Open Mini-Player", systemImage: "pip") { openWindow(id: "mini-player") }
                KeepMiniPlayerOnTopToggle()
            }
            if let songNotifications {
                Section("Notifications") {
                    SongNotificationSettings(notifier: songNotifications)
                }
                .task { await songNotifications.refreshAuthorization() }
            }
            Section("Account") {
                LabeledContent("YouTube Music", value: session.account.isSignedIn ? "Signed in" : "Not signed in")
                Button(session.account.isSignedIn ? "Open Account" : "Sign In") {
                    openWindow(id: "main")
                    session.openAccount()
                }
                if session.account.isSignedIn {
                    Button("Sign Out", role: .destructive) {
                        isSigningOut = true
                        Task {
                            await session.signOut()
                            isSigningOut = false
                        }
                    }.disabled(isSigningOut)
                }
                Text("Sign-out clears this app's session and saved queue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(10)
        .frame(width: 470, height: 580)
    }
}
