import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StreamingExportSettingsView: View {
    let session: AppSession
    @State private var format: StreamingMetadataFormat = .json
    @State private var confirmsEnable = false
    @State private var confirmsForget = false
    @State private var consentScope: UUID?

    var body: some View {
        if let export = session.streamingExport {
            Section(StreamingExportText.text("Streaming Metadata Export")) {
                Text(StreamingExportText.text("Off by default. After you enable it for this listening session, writes the current verified song title and artist to your chosen file. JSON adds playback state and update/expiry times. Other apps and your stream audience may see this data."))
                    .font(.caption).foregroundStyle(.secondary)
                if session.account.isSignedIn, export.isAccountAvailable {
                    if let receipt = export.receipt {
                        Text(receipt.path).textSelection(.enabled).font(.caption)
                        Toggle(StreamingExportText.text("Export for This Listening Session"), isOn: Binding(
                            get: { export.isEnabled }, set: { enabled in
                                if enabled { consentScope = export.scope; confirmsEnable = true }
                                else { export.disable() }
                            })).disabled(export.isWorking && !export.isEnabled)
                    } else if !export.settingsBlocked {
                        Picker(StreamingExportText.text("Output Format"), selection: $format) {
                            Text(StreamingExportText.text("JSON with Expiry")).tag(StreamingMetadataFormat.json)
                            Text(StreamingExportText.text("TXT for OBS")).tag(StreamingMetadataFormat.text)
                        }.disabled(export.isWorking)
                        Button(StreamingExportText.text("Choose New Export File…")) { choose(export) }.disabled(export.isWorking)
                    }
                    if export.receipt != nil || export.settingsBlocked {
                        Button(StreamingExportText.text("Forget Saved Export Target…"), role: .destructive) {
                            consentScope = export.scope; confirmsForget = true
                        }.disabled(export.isWorking)
                    }
                    if export.isWorking { ProgressView().controlSize(.small) }
                } else {
                    Text(StreamingExportText.text("Confirm a signed-in account to configure its export target. Targets stay separate for each local profile and account."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(StreamingExportText.text("JSON readers must reject expired, invalid, or incomplete documents. TXT can be read partially during an update and can remain stale after a crash; OBS cannot enforce expiry. Pause, buffering, ads, sign-out, and normal shutdown clear owned output when the file is available."))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = export.errorMessage { InlineMessage(message: error) }
            }
            .onChange(of: export.scope) { confirmsEnable = false; confirmsForget = false; consentScope = nil }
            .confirmationDialog(StreamingExportText.text("Export public song text for this session?"), isPresented: $confirmsEnable, titleVisibility: .visible) {
                Button(StreamingExportText.text("Enable for This Session")) {
                    if let scope = consentScope { Task { await export.enable(expectedScope: scope) } }
                }
                Button(StreamingExportText.text("Cancel"), role: .cancel) { }
            } message: {
                Text(StreamingExportText.text("Song title and artist are exported; JSON also includes playback state and update/expiry times. Uploads, episodes, unknown content, artwork, links, playback IDs, account details, and credentials are excluded. Enable again after switching accounts, local profiles, or relaunching."))
            }
            .confirmationDialog(StreamingExportText.text("Forget this export configuration?"), isPresented: $confirmsForget, titleVisibility: .visible) {
                Button(StreamingExportText.text("Forget Target"), role: .destructive) {
                    if let scope = consentScope { Task { await export.forgetTarget(expectedScope: scope) } }
                }
                Button(StreamingExportText.text("Cancel"), role: .cancel) { }
            } message: {
                Text(StreamingExportText.text("Verified owned output is cleared if possible. Files are kept. Changed or unrecognized files are left untouched and may still contain old text."))
            }
        }
    }
    private func choose(_ export: StreamingMetadataExport) {
        let panel = NSSavePanel()
        panel.title = StreamingExportText.text("Choose a New Metadata File")
        panel.nameFieldStringValue = format == .json ? "Now Playing.json" : "Now Playing.txt"
        panel.allowedContentTypes = [format == .json ? .json : .plainText]
        panel.allowsOtherFileTypes = false; panel.canCreateDirectories = true
        let scope = export.scope; let selectedFormat = format
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await export.configure(url: url, format: selectedFormat, expectedScope: scope) }
    }
}
