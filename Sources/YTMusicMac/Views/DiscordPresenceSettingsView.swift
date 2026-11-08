import SwiftUI

struct DiscordPresenceSettingsView: View {
    let session: AppSession
    @State private var applicationID = ""
    @State private var confirmsEnable = false
    @State private var confirmsForget = false
    @State private var consentScope: UUID?
    var body: some View {
        if let presence = session.discordPresence {
            Section(DiscordPresenceText.text("Discord Presence")) {
                Text(DiscordPresenceText.text("Off by default. With your explicit consent, sends verified song title and artist to the running Discord client. Discord can show that activity to others according to your Discord privacy settings."))
                    .font(.caption).foregroundStyle(.secondary)
                if session.account.isSignedIn, presence.isAccountAvailable {
                    if presence.settingsBlocked {
                        Text(DiscordPresenceText.text("Forget the unsupported configuration before saving another application ID.")).font(.caption)
                    } else {
                        TextField(DiscordPresenceText.text("Registered Discord Application ID"), text: $applicationID)
                            .textFieldStyle(.roundedBorder).disabled(presence.isEnabled || presence.isWorking)
                        Button(DiscordPresenceText.text("Save Application ID")) {
                            let value = applicationID; let scope = presence.scope
                            Task { await presence.configure(applicationID: value, expectedScope: scope) }
                        }.disabled(presence.isEnabled || presence.isWorking || applicationID.isEmpty)
                        Toggle(DiscordPresenceText.text("Share for This Listening Session"), isOn: Binding(get: { presence.isEnabled }, set: {
                            if $0 { consentScope = presence.scope; confirmsEnable = true }
                            else { presence.disable() }
                        })).disabled(presence.applicationID == nil || (presence.isWorking && !presence.isEnabled))
                    }
                    if presence.applicationID != nil || presence.settingsBlocked {
                        Button(DiscordPresenceText.text("Forget Discord Configuration…"), role: .destructive) {
                            consentScope = presence.scope; confirmsForget = true
                        }.disabled(presence.isWorking)
                    }
                    if presence.isWorking { ProgressView().controlSize(.small) }
                } else {
                    Text(DiscordPresenceText.text("Confirm a signed-in account to configure presence. Application IDs stay separate for each local profile and account."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(DiscordPresenceText.text("Requires an application you registered and local Discord IPC support. Enter your application ID; this app supplies no registered ID or secret. It never requests Discord credentials or OAuth permissions. Rejected or failed requests stop sharing until you explicitly enable it again."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(DiscordPresenceText.text("Uploads, episodes, unknown content, links, artwork, playback IDs, account details, and credentials are excluded. Pause, ads, buffering, stale progress, account changes, and normal shutdown request clearing and close the local connection. Discord display changes can lag."))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = presence.errorMessage { InlineMessage(message: error) }
            }
            .task { applicationID = presence.applicationID ?? "" }
            .onChange(of: presence.scope) {
                applicationID = presence.applicationID ?? ""; consentScope = nil; confirmsEnable = false; confirmsForget = false
            }
            .onChange(of: presence.applicationID) { applicationID = presence.applicationID ?? "" }
            .confirmationDialog(DiscordPresenceText.text("Share song text with Discord for this session?"), isPresented: $confirmsEnable, titleVisibility: .visible) {
                Button(DiscordPresenceText.text("Enable for This Session")) {
                    if let scope = consentScope { Task { await presence.enable(expectedScope: scope) } }
                }
                Button(DiscordPresenceText.text("Cancel"), role: .cancel) { }
            } message: {
                Text(DiscordPresenceText.text("A new verified eligible song sample starts local presence sharing. Only title and artist are activity text; the application ID, process ID and request nonce are required routing fields. Enable again after relaunching or switching account or profile."))
            }
            .confirmationDialog(DiscordPresenceText.text("Forget this Discord application ID?"), isPresented: $confirmsForget, titleVisibility: .visible) {
                Button(DiscordPresenceText.text("Forget Configuration"), role: .destructive) {
                    if let scope = consentScope { Task { await presence.forgetConfiguration(expectedScope: scope) } }
                }
                Button(DiscordPresenceText.text("Cancel"), role: .cancel) { }
            } message: { Text(DiscordPresenceText.text("Sharing stops and this account's saved application ID is removed from this local profile.")) }
        }
    }
}
