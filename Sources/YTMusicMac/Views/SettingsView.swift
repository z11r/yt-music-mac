import SwiftUI

struct SettingsView: View {
    @Bindable var session: AppSession
    @AppStorage("appearance", store: AppIdentity.preferences)
    private var appearance = "system"
    @Environment(\.openWindow) private var openWindow
    @State private var isSigningOut = false

    var body: some View {
        Form {
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
                Button("Open Mini-Player", systemImage: "pip") { openWindow(id: "mini-player") }
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
        .frame(width: 470, height: 400)
    }
}
