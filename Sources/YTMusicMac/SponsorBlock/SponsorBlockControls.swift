import SwiftUI

struct SponsorBlockSettingsView: View {
    let session: AppSession
    var body: some View {
        if session.sponsorBlock != nil {
            Section(SponsorBlockText.text("Non-Music Sections")) { SponsorBlockControls(session: session) }
        }
    }
}

struct SponsorBlockPlayerAction: View {
    let session: AppSession
    @State private var showsPreview = false
    var body: some View {
        if session.sponsorBlock?.isEnabled == true {
            Button(SponsorBlockText.text("Review Non-Music Sections…"), systemImage: "scissors") { showsPreview = true }
                .controlSize(.small).padding(.bottom, 8)
                .popover(isPresented: $showsPreview) {
                    ScrollView { SponsorBlockControls(session: session).padding(20) }.frame(width: 460, height: 530)
                }
        }
    }
}

private struct SponsorBlockControls: View {
    let session: AppSession
    @State private var confirmsEnable = false
    @State private var consentScope: UUID?
    var body: some View {
        if let model = session.sponsorBlock {
            VStack(alignment: .leading, spacing: 12) {
                Text(SponsorBlockText.text("Off by default. SponsorBlock supplies community-marked non-music sections for catalog songs. Lookups and skips are always explicit; timings may be wrong."))
                    .font(.caption).foregroundStyle(.secondary)
                if session.acceptsProfileActions, session.account.isSignedIn, model.isAccountAvailable {
                    Toggle(SponsorBlockText.text("Allow Lookups for This Listening Session"), isOn: Binding(get: { model.isEnabled }, set: {
                        if $0 { consentScope = model.scope; confirmsEnable = true }
                        else { model.disable() }
                    })).disabled(model.isWorking && !model.isEnabled)
                    if model.isEnabled {
                        LabeledContent(SponsorBlockText.text("Current Position"), value: playbackTime(session.player.clock.position))
                        Button(SponsorBlockText.text("Look Up Current Song")) { model.lookup() }.disabled(!model.canLookup)
                        Text(SponsorBlockText.text("Requires recent confirmed song playback. One lookup at a time, at least 30 seconds apart. Changes to the recording or playback controls require a new preview."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.isWorking {
                        ProgressView(SponsorBlockText.text("Loading or finishing a canceled request…")).controlSize(.small)
                        if model.isLookupPending { Button(SponsorBlockText.text("Cancel Lookup")) { model.interrupt() } }
                    }
                    if let preview = model.preview {
                        if preview.sections.isEmpty {
                            Text(SponsorBlockText.text("No supported sections matched this recording and duration."))
                        } else {
                            Text(SponsorBlockText.text("Community Non-Music Sections")).font(.headline)
                            ForEach(preview.sections) { section in
                                HStack {
                                    Text(playbackTime(section.start) + " – " + playbackTime(section.end)).monospacedDigit()
                                    Spacer()
                                    Button(SponsorBlockText.text("Skip This Section")) {
                                        Task { await model.skip(section, previewID: preview.id) }
                                    }.disabled(!model.canSkip(section, previewID: preview.id))
                                }
                            }
                            Text(SponsorBlockText.text("Skip is available only while playing inside that section. Review the timing first; normal seeking remains available."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(SponsorBlockText.text("Confirm a signed-in account before enabling this optional provider. Consent does not carry across accounts, profiles, or relaunches."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.errorMessage { InlineMessage(message: error) }
                Text(SponsorBlockText.text("Each explicit lookup sends a four-character SHA-256 video-ID prefix, the non-music category and client name. SponsorBlock and its proxy also receive your connection IP. No cookies, account data, title, artist, artwork, or complete playback ID are sent."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(SponsorBlockText.text("Uses SponsorBlock contributor data under CC BY-NC-SA 4.0. Provider terms govern that data; this app keeps its own license. No submissions, votes, or skip tracking are sent."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("SponsorBlock", destination: URL(string: "https://sponsor.ajay.app/")!)
                    Link(SponsorBlockText.text("Data License"), destination: URL(string: "https://creativecommons.org/licenses/by-nc-sa/4.0/")!)
                    Link(SponsorBlockText.text("Privacy"), destination: URL(string: "https://gist.github.com/ajayyy/aa9f8ded2b573d4f73a3ffa0ef74f796")!)
                    Link(SponsorBlockText.text("Provider Terms"), destination: URL(string: "https://gist.github.com/ajayyy/9e8100f069348e0bc062641f34d6af12")!)
                }.font(.caption)
            }
            .onChange(of: model.scope) { confirmsEnable = false; consentScope = nil }
            .confirmationDialog(SponsorBlockText.text("Allow SponsorBlock lookups for this session?"), isPresented: $confirmsEnable, titleVisibility: .visible) {
                Button(SponsorBlockText.text("Enable for This Session")) {
                    if let scope = consentScope { Task { await model.enable(expectedScope: scope) } }
                }
                Button(SponsorBlockText.text("Cancel"), role: .cancel) { }
            } message: {
                Text(SponsorBlockText.text("Review the linked provider privacy policy, terms and data license. Enabling permits explicit prefix lookups only. It does not fetch or skip automatically, and no consent or timings are saved."))
            }
        }
    }
}
