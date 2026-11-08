import SwiftUI

struct SettingsView: View {
    @Bindable var session: AppSession
    var songNotifications: SongChangeNotifier? = nil
    @AppStorage("appearance", store: AppIdentity.preferences)
    private var appearance = "system"
    @Environment(\.openWindow) private var openWindow
    @State private var isSigningOut = false
    @State private var showsStorage = false

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
            Section("Storage") {
                Button("Manage Storage…") { showsStorage = true }
                Text("View cache usage, clear cached artwork and library metadata, and read your last library snapshot.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Text("Sign-out clears this app's session and current queue. Named saved queues and local collection organization stay on this Mac for their account until deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(10)
        .frame(width: 470, height: 580)
        .sheet(isPresented: $showsStorage) { StorageSettingsView(session: session) }
    }
}
