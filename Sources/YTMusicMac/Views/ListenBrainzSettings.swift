import SwiftUI

struct ListenBrainzSettings: View {
    let session: AppSession
    @State private var token = ""
    var body: some View {
        let reporting = session.listenBrainz
        let scope = reporting.scope
        Section("ListenBrainz") {
            Text("Optional. Send qualifying catalog song title, artist, album when known, duration, listening-start time, and app/service name to your ListenBrainz account. Listens may appear on your public ListenBrainz profile.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Off by default for each YouTube Music profile. Only identified catalog songs qualify; uploads, podcasts, and unknown content are excluded. Artwork, YouTube IDs, and YouTube credentials are not sent. Now Playing is not sent.")
                .font(.caption).foregroundStyle(.secondary)
            if let name = reporting.state.username { LabeledContent("Saved connection", value: name) }
            SecureField("ListenBrainz user token", text: $token)
                .accessibilityLabel("ListenBrainz user token")
            HStack {
                Link("Get a User Token", destination: URL(string: "https://listenbrainz.org/settings/")!)
                Button("Verify and Save Token") {
                    let supplied = token; token = ""
                    Task { await reporting.connect(token: supplied, expectedScope: scope) }
                }.disabled(token.isEmpty || !reporting.state.available || reporting.state.working)
            }
            Toggle("Enable ListenBrainz scrobbling", isOn: Binding(get: { reporting.state.enabled }, set: { enabled in
                Task { await reporting.setEnabled(enabled, expectedScope: scope) }
            }))
            .disabled(!reporting.state.available || reporting.state.username == nil || (!reporting.state.enabled && reporting.state.working))
            Text("Starts with new song plays after enabling. Only actual listening counts: at least half a song or four minutes, for songs longer than 30 seconds.")
                .font(.caption).foregroundStyle(.secondary)
            if reporting.state.ready + reporting.state.uncertain + reporting.state.rejected > 0 {
                Text("Unsent: \(reporting.state.ready). Uncertain: \(reporting.state.uncertain). Rejected: \(reporting.state.rejected).")
                    .font(.caption)
                Text("Pending metadata stays on this Mac. Attempted or uncertain submissions are never automatically retried.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Check Connection and Send Unsent") { Task { await reporting.sendUnsent(expectedScope: scope) } }
                        .disabled(!reporting.state.enabled || reporting.state.ready == 0 || reporting.state.working)
                    Button("Discard Pending", role: .destructive) { Task { await reporting.discardPending(expectedScope: scope) } }
                        .disabled(reporting.state.working)
                }
            }
            if let message = reporting.state.message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if reporting.state.working { ProgressView().controlSize(.small).accessibilityLabel("Updating ListenBrainz connection") }
            Button("Disconnect and Delete Local ListenBrainz Data", role: .destructive) {
                token = ""
                Task { await reporting.disconnect(expectedScope: scope) }
            }.disabled(!reporting.state.available || reporting.state.username == nil || reporting.state.working)
        }
        .disabled(!session.account.isSignedIn)
        .onChange(of: reporting.scope) { token = "" }
        .onDisappear { token = "" }
    }
}
