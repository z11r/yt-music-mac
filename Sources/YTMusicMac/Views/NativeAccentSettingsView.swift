import SwiftUI

struct NativeAccentSettingsView: View {
    let session: AppSession
    @AppStorage(NativeControlAccent.preferenceKey) private var rawAccent = "system"
    @Environment(\.colorSchemeContrast) private var contrast

    init(session: AppSession) {
        self.session = session
        _rawAccent = AppStorage(wrappedValue: "system", NativeControlAccent.preferenceKey, store: session.preferences)
    }

    var body: some View {
        let generation = session.accountGeneration
        Picker("Control Accent", selection: Binding(
            get: { NativeControlAccent(storedValue: rawAccent) },
            set: { accent in
                NativeControlAccentPreference.write(accent, to: session.preferences,
                    expectedGeneration: generation, currentGeneration: session.accountGeneration,
                    acceptsActions: session.acceptsProfileActions)
            }
        )) {
            ForEach(NativeControlAccent.allCases) { accent in Text(accent.title).tag(accent) }
        }
        .pickerStyle(.menu)
        .disabled(!session.acceptsProfileActions)
        Text("Sets the tint of supported native controls in this local profile.")
            .font(.caption).foregroundStyle(.secondary)
        if contrast == .increased {
            Text("Increase Contrast uses the system accent. Your chosen accent is kept for standard contrast.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
