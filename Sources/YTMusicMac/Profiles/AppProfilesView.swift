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
                    if owner.isPendingDeletion(profile.id) {
                        Text("Deletion Pending").foregroundStyle(.secondary)
                        Button("Review Deletion…") { reviewDeletion(profile) }
                    } else {
                    if profile.id != owner.current.profile.id || profile.id != owner.savedSelectionID {
                        Button("Switch") {
                            let activation = owner.activationID
                            Task { guard owner.accepts(activation) else { return }; await owner.switchTo(profile.id) }
                        }
                    }
                    Button("Rename…") { name = profile.name ?? ""; renaming = profile }
                    if owner.deletion != nil, !profile.isDefault, profile.id != owner.current.profile.id, profile.id != owner.savedSelectionID {
                        Button("Delete…", role: .destructive) { reviewDeletion(profile) }
                    }
                    }
                }
            }
            Button("Create Profile…") { name = ""; showsCreate = true }
                .disabled(owner.profiles.count >= AppProfileArchive.maximumProfiles)
            Text("Profiles keep this app's YouTube sign-in, queue, local data and settings separate. Switching stops playback. A profile does not create a YouTube account.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Deletion protects the default and active profiles. Pending deletions stay blocked from opening until cleanup is confirmed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!owner.canEdit || owner.isLoading || owner.isSwitching || !owner.canManageProfiles)
        Section {
            if let message = owner.deletion?.message { Text(message).foregroundStyle(.secondary) }
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
        .sheet(item: Binding(get: { owner.deletion?.review }, set: { if $0 == nil { owner.deletion?.cancelReview() } })) { review in
            if let deletion = owner.deletion { ProfileDeletionReviewView(controller: deletion, review: review) }
        }
    }
    private func reviewDeletion(_ profile: AppProfile) {
        guard let deletion = owner.deletion else { return }
        let activation = owner.activationID, generation = owner.current.session.accountGeneration
        let session = owner.current.session, activeID = owner.current.profile.id
        Task { [owner, session] in
            guard owner.accepts(activation), session.acceptsProfileActions, session.accountGeneration == generation else { return }
            await deletion.prepare(id: profile.id, activeID: activeID) { [weak owner, weak session] in
                guard let owner, let session else { return false }
                return owner.accepts(activation) && owner.current.profile.id == activeID &&
                    session.acceptsProfileActions && session.accountGeneration == generation
            }
        }
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
