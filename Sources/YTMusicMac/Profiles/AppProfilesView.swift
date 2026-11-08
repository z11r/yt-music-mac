import SwiftUI

struct AppProfilesSection: View {
    @Bindable var owner: AppProfileOwner<NativeAppProfileRuntime>
    @State private var showsCreate = false
    @State private var renaming: AppProfile?
    @State private var name = ""

    var body: some View {
        Section("Local App Profiles") {
            LabeledContent("Current Profile", value: owner.current.profile.displayName)
            ForEach(owner.profiles) { profile in
                HStack {
                    Text(profile.displayName)
                    if !profile.isInitialized { Text("Setup Incomplete").foregroundStyle(.secondary) }
                    Spacer()
                    if profile.id != owner.current.profile.id || profile.id != owner.savedSelectionID {
                        Button("Switch") {
                            let activation = owner.activationID
                            Task { guard owner.accepts(activation) else { return }; await owner.switchTo(profile.id) }
                        }
                    }
                    Button("Rename…") { name = profile.name ?? ""; renaming = profile }
                }
            }
            Button("Create Profile…") { name = ""; showsCreate = true }
                .disabled(owner.profiles.count >= AppProfileArchive.maximumProfiles)
            Text("Profiles keep this app's YouTube sign-in, queue, local data and settings separate. Switching stops playback. A profile does not create a YouTube account.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Profile deletion is not available. Existing profile records are kept when setup fails.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!owner.canEdit || owner.isLoading || owner.isSwitching)
        Section {
            if let error = owner.errorMessage {
                Text(error).foregroundStyle(.secondary)
                Button("Reload Profiles") {
                    let activation = owner.activationID
                    Task { guard owner.accepts(activation) else { return }; await owner.reload() }
                }
            }
        }
        .sheet(isPresented: $showsCreate) { editor(creating: true) }
        .sheet(item: $renaming) { _ in editor(creating: false) }
    }

    private func editor(creating: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(creating ? AppLocalization.text("Create Local Profile") : AppLocalization.text("Rename Local Profile")).font(.headline)
            TextField("Profile Name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showsCreate = false; renaming = nil }
                Button(creating ? AppLocalization.text("Create") : AppLocalization.text("Rename")) {
                    let value = name; let id = renaming?.id
                    let activation = owner.activationID
                    showsCreate = false; renaming = nil
                    Task {
                        guard owner.accepts(activation) else { return }
                        if creating { await owner.create(name: value) }
                        else if let id { await owner.rename(id, name: value) }
                    }
                }.keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 420)
    }
}

struct LocalPrivacySection: View {
    @Bindable var session: AppSession
    @Environment(\.openURL) private var openURL
    var body: some View {
        Section("Local Privacy") {
            Toggle("Save and Restore This Profile's Queue", isOn: Binding(
                get: { session.persistsLocalQueue }, set: { session.setPersistsLocalQueue($0) }))
            Text("Turning this off stops future automatic queue saves and restore. Existing saved data stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Save This Profile's Episode Progress", isOn: Binding(
                get: { session.episodePlayback.persistenceEnabled }, set: { session.setPersistsEpisodeProgress($0) }))
            Text("Turning this off keeps episode progress in memory only. Existing saved progress stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear Recent Searches in This App") { session.searchHistory.clear() }
                .disabled(session.searchHistory.queries.isEmpty)
            Text("Recent searches here are held in memory for this app session. This does not clear YouTube search or watch history.")
                .font(.caption).foregroundStyle(.secondary)
            Button("YouTube Music History Controls…") {
                openURL(URL(string: "https://support.google.com/youtubemusic/answer/6364666?hl=en")!)
            }
            Text("Playback can still appear in the signed-in account's YouTube history. Use YouTube's own controls to pause or delete service history. Local profiles do not provide private listening.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
