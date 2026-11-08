import SwiftUI

struct LastFMSettings: View {
    let session: AppSession
    @Environment(\.openURL) private var openURL
    @State private var apiKey = ""
    @State private var sharedSecret = ""
    var body: some View {
        let reporting = session.lastFM
        let scope = reporting.scope
        Section {
            Text(LastFMText.text("Optional Last.fm reporting is off by default for each YouTube Music profile. It has separate consent and delivery records from ListenBrainz."))
                .font(.caption).foregroundStyle(.secondary)
            Text(LastFMText.text("Send qualifying catalog song title, artist, optional album, duration, and listening-start time to your Last.fm account. Listens may appear publicly. Uploads, podcasts, unknown content, artwork, YouTube IDs, and YouTube credentials are excluded. Now Playing is not sent."))
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(LastFMText.text("Registered app credentials")) {
                Text(LastFMText.text("Development setup requires your own registered Last.fm API key and shared secret. The app ships without credentials. Both are stored in Keychain with the authorized session; neither is written to listening-data files."))
                    .font(.caption).foregroundStyle(.secondary)
                SecureField(LastFMText.text("Last.fm API key"), text: $apiKey)
                SecureField(LastFMText.text("Last.fm shared secret"), text: $sharedSecret)
                Button(LastFMText.text("Save App Credentials")) {
                    let key = apiKey; let secret = sharedSecret; apiKey = ""; sharedSecret = ""
                    Task { await reporting.configure(apiKey: key, sharedSecret: secret, expectedScope: scope) }
                }.disabled(!LastFMAppCredentials(apiKey: apiKey, sharedSecret: sharedSecret).isValid || reporting.state.working)
            }
            if let name = reporting.state.username { LabeledContent(LastFMText.text("Saved Last.fm account"), value: name) }
            Button(LastFMText.text("Start Last.fm Authorization")) {
                Task { await reporting.beginAuthorization(expectedScope: scope) }
            }.disabled(!reporting.state.configured || reporting.state.working)
            if let authorizationID = reporting.state.authorizationID {
                Text(LastFMText.text("Open Last.fm, approve the registered app, then return here and complete authorization. No callback or polling is used. Approval tokens expire after one hour."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(LastFMText.text("Open Last.fm Approval")) {
                        Task {
                            if let url = await reporting.approvalURL(expectedScope: scope, authorizationID: authorizationID),
                               reporting.scope == scope, reporting.state.authorizationID == authorizationID { openURL(url) }
                        }
                    }.disabled(reporting.state.working)
                    Button(LastFMText.text("Complete Authorization")) {
                        Task { await reporting.completeAuthorization(expectedScope: scope, authorizationID: authorizationID) }
                    }.disabled(reporting.state.working)
                }
            }
            if reporting.state.authorizationID != nil || reporting.state.authorizing {
                Button(LastFMText.text("Cancel Authorization")) { Task { await reporting.cancelAuthorization(expectedScope: scope) } }
            }
            Toggle(LastFMText.text("Enable Last.fm Scrobbling"), isOn: Binding(get: { reporting.state.enabled }, set: { enabled in
                Task { await reporting.setEnabled(enabled, expectedScope: scope) }
            })).disabled(!reporting.state.available || (!reporting.state.enabled && (!reporting.state.connected || reporting.state.working)))
            Text(LastFMText.text("Starts with new song plays after enabling. Songs must exceed thirty seconds; only actual listening counts toward half the duration or four minutes. Seeks, ads, pauses, and buffering do not count."))
                .font(.caption).foregroundStyle(.secondary)
            Text(LastFMText.counts(ready: reporting.state.ready, uncertain: reporting.state.uncertain,
                                   refused: reporting.state.rejected, ignored: reporting.state.ignored))
                .font(.caption)
            Text(LastFMText.text("Uncertain submissions are never retried automatically. Explicitly refused requests can be retried with the button below after fixing authorization or a temporary service error. Ignored listens were not added to provider history."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(LastFMText.text("Send Unsent Listens")) { Task { await reporting.sendUnsent(expectedScope: scope) } }
                    .disabled(!reporting.state.enabled || reporting.state.ready == 0 || reporting.state.working)
                Button(LastFMText.text("Retry Explicitly Refused Requests")) { Task { await reporting.retryRefused(expectedScope: scope) } }
                    .disabled(!reporting.state.enabled || reporting.state.retryable == 0 || reporting.state.working)
            }
            Button(LastFMText.text("Discard Pending Last.fm Listens"), role: .destructive) {
                Task { await reporting.discardPending(expectedScope: scope) }
            }.disabled(reporting.state.working || reporting.state.ready + reporting.state.uncertain + reporting.state.rejected + reporting.state.retryable == 0)
            if let message = reporting.state.message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if reporting.state.working { ProgressView().controlSize(.small).accessibilityLabel(LastFMText.text("Updating Last.fm")) }
            Button(LastFMText.text("Disconnect and Delete Local Last.fm Data"), role: .destructive) {
                apiKey = ""; sharedSecret = ""
                Task { await reporting.disconnect(expectedScope: scope) }
            }.disabled(!reporting.state.available || (!reporting.state.configured && reporting.state.username == nil))
            Text(LastFMText.text("Disconnect removes local app credentials, the saved session, pending listens, and receipts. It does not delete Last.fm history or revoke an already granted provider permission."))
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Last.fm") }
        .disabled(!session.account.isSignedIn)
        .onChange(of: reporting.scope) { apiKey = ""; sharedSecret = "" }
        .onDisappear { apiKey = ""; sharedSecret = "" }
    }
}
