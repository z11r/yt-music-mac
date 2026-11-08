import SwiftUI

struct SettingsView: View {
    @Bindable var session: AppSession
    var songNotifications: SongChangeNotifier? = nil
    var playbackBindings: PlaybackShortcutBindings? = nil
    var profiles: AppProfileOwner<NativeAppProfileRuntime>? = nil
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.openWindow) private var openWindow
    @State private var isSigningOut = false
    @State private var showsStorage = false
    @State private var showsKeyboardSettings = false

    init(session: AppSession, songNotifications: SongChangeNotifier? = nil,
         playbackBindings: PlaybackShortcutBindings? = nil,
         profiles: AppProfileOwner<NativeAppProfileRuntime>? = nil) {
        self.session = session; self.songNotifications = songNotifications
        self.playbackBindings = playbackBindings; self.profiles = profiles
        _appearance = AppStorage(wrappedValue: "system", "appearance", store: session.preferences)
    }

    var body: some View {
        Form {
            if let profiles { AppProfilesSection(owner: profiles) }
            LocalPrivacySection(session: session)
            Section("Startup") { StartupSettings() }
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                NativeAccentSettingsView(session: session)
            }
            Section("Playback") {
                LabeledContent("Volume") { VolumeView(session: session).frame(width: 190) }
                LabeledContent("Sleep Timer") { SleepTimerMenu(session: session) }
                Toggle(isOn: Binding(get: { session.radio.autoplayEnabled }, set: { session.setAutoplayEnabled($0) })) {
                    Text("Autoplay")
                    Text("When the queue ends with repeat off, keep playing related songs.")
                }
                Button("Open Mini-Player", systemImage: "pip") { openWindow(id: "mini-player") }
                KeepMiniPlayerOnTopToggle(preferences: session.preferences)
            }
            if playbackBindings != nil {
                Section("Keyboard") {
                    Button("Customize Playback Shortcuts…") { showsKeyboardSettings = true }
                }
            }
            if let songNotifications {
                Section("Notifications") {
                    SongNotificationSettings(notifier: songNotifications)
                }
                .task { await songNotifications.refreshAuthorization() }
            }
            Section("Uploads") { UploadReviewButton(session: session) }
            Section("Storage") {
                Button("Manage Storage…") { showsStorage = true }
                Text("View cache usage, clear cached artwork and library metadata, and read your last library snapshot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SpotlightSettingsSection(session: session)
            Section("Account") {
                LabeledContent("YouTube Music", value: session.account.isSignedIn ? AppLocalization.text("Signed in") : AppLocalization.text("Not signed in"))
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
                Text("Sign-out clears this app's session and current queue. Saved queues, organization, song rules, episode progress and optional scrobbling records remain on this Mac for their account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ListenBrainzSettings(session: session)
            LastFMSettings(session: session)
            StreamingExportSettingsView(session: session)
            DiscordPresenceSettingsView(session: session)
        }
        .formStyle(.grouped)
        .padding(10)
        .frame(width: 600, height: 750)
        .sheet(isPresented: $showsStorage) { StorageSettingsView(session: session) }
        .sheet(isPresented: $showsKeyboardSettings) {
            if let playbackBindings { PlaybackShortcutSettings(bindings: playbackBindings) }
        }
    }
}
