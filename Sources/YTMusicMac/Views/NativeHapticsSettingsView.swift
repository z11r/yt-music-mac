import SwiftUI

struct NativeHapticsSettingsView: View {
    let session: AppSession
    var body: some View {
        let owner = session.nativeHapticOwner
        Section(HapticsText.text("Haptic Feedback")) {
            Toggle(HapticsText.text("Use Haptics for Direct Queue Controls"), isOn: Binding(
                get: { session.nativeHaptics.isEnabled },
                set: { session.setNativeHapticsEnabled($0, owner: owner) }
            )).disabled(!session.acceptsProfileActions || session.account.isWorking)
            Text(HapticsText.text("Off by default for each local profile. Requests a brief tactile response for direct queue moves, Undo, Shuffle and Repeat changes. A supported Force Touch trackpad is required; macOS may suppress feedback. Visual controls remain available. Automated and background actions stay silent."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
