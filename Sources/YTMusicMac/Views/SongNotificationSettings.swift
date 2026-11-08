import AppKit
import SwiftUI

struct SongNotificationSettings: View {
    let notifier: SongChangeNotifier

    var body: some View {
        Toggle("Show song changes in Notification Center", isOn: Binding(
            get: { notifier.isEnabled },
            set: { value in Task { await notifier.setEnabled(value) } }))
            .disabled(notifier.isRequesting || !notifier.isAvailable)
        Text("Shows the song and artist when a new song starts while another app is in front.")
            .font(.caption).foregroundStyle(.secondary)
        if let message = notifier.message {
            HStack(alignment: .firstTextBaseline) {
                Text(message).font(.caption)
                Spacer(minLength: 8)
                if notifier.authorization == .denied, let url = SongChangeNotifier.settingsURL {
                    Button("Open Notification Settings") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}
