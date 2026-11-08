import SwiftUI

struct NativeAccentSettingsView: View {
    let session: AppSession
    @AppStorage(NativeControlAccent.preferenceKey) private var rawAccent = "system"
    @AppStorage(CustomControlAccent.preferenceKey) private var rawCustomAccent = ""
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var editor: CustomAccentDraft?

    init(session: AppSession) {
        self.session = session
        _rawAccent = AppStorage(wrappedValue: "system", NativeControlAccent.preferenceKey, store: session.preferences)
        _rawCustomAccent = AppStorage(wrappedValue: "", CustomControlAccent.preferenceKey, store: session.preferences)
    }
    var body: some View {
        let generation = session.accountGeneration
        Picker("Control Accent", selection: Binding(
            get: { NativeControlAccent.effective(storedValue: rawAccent, customStoredValue: rawCustomAccent, increasedContrast: false) },
            set: { accent in
                guard session.acceptsProfileActions, generation == session.accountGeneration else { return }
                if accent == .custom, CustomControlAccent(storedValue: rawCustomAccent) == nil { openEditor(generation) }
                else {
                    NativeControlAccentPreference.write(accent, to: session.preferences,
                        expectedGeneration: generation, currentGeneration: session.accountGeneration, acceptsActions: session.acceptsProfileActions)
                }
            }
        )) {
            ForEach(NativeControlAccent.allCases) { accent in Text(accent.title).tag(accent) }
        }
        .pickerStyle(.menu)
        .disabled(!session.acceptsProfileActions)
        Button("Edit Custom Accent…") { openEditor(generation) }.disabled(!session.acceptsProfileActions)
        Text("Sets the tint of supported native controls in this local profile.")
            .font(.caption).foregroundStyle(.secondary)
        if !rawCustomAccent.isEmpty, CustomControlAccent(storedValue: rawCustomAccent) == nil {
            Text("The saved custom accent is unsupported. It is retained until you explicitly replace it with Apply.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if contrast == .increased {
            Text("Increase Contrast uses the system accent. Your chosen accent is kept for standard contrast.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Color.clear.frame(height: 0).sheet(item: $editor) { value in CustomAccentEditorView(session: session, draft: value) }
    }
    private func openEditor(_ generation: UUID) {
        guard session.acceptsProfileActions, generation == session.accountGeneration else { return }
        editor = CustomAccentDraft(storedValue: rawCustomAccent, generation: generation)
    }
}

private struct CustomAccentEditorView: View {
    let session: AppSession
    @State var draft: CustomAccentDraft
    @Environment(\.dismiss) private var dismiss
    private var isCurrent: Bool { draft.accepts(currentGeneration: session.accountGeneration, acceptsActions: session.acceptsProfileActions) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Accent").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if isCurrent {
                Text("Choose opaque sRGB accents for Light and Dark. Changes stay in this draft until Apply.")
                colorRow("Light Accent", dark: false)
                colorRow("Dark Accent", dark: true)
                Text("Reference checks require 4.5:1 against white for Light and black for Dark. They do not certify the contrast of native controls.")
                    .font(.caption).foregroundStyle(.secondary)
                if draft.pair == nil {
                    Text("Use six hexadecimal digits. Choose a darker Light accent and a lighter Dark accent to pass the reference checks.")
                        .font(.callout)
                }
                Text("Increase Contrast uses the system accent. Your chosen accent is kept for standard contrast.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("The profile changed. Close this draft and open Custom Accent again.") }
            HStack {
                Button("Cancel", role: .cancel) { draft.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") {
                    if draft.apply(to: session.preferences, currentGeneration: session.accountGeneration, acceptsActions: session.acceptsProfileActions) { dismiss() }
                }.disabled(!isCurrent || draft.pair == nil)
            }
        }.padding(24).frame(width: 510)
            .onDisappear { draft.cancel() }
    }
    private func colorRow(_ title: LocalizedStringKey, dark: Bool) -> some View {
        HStack {
            ColorPicker(title, selection: Binding(get: {
                let hex = dark ? draft.darkHex : draft.lightHex
                return (CustomAccentRGB(hex: hex) ?? CustomControlAccent.example.rgb(darkAppearance: dark)).color
            }, set: { value in
                guard isCurrent, let rgb = CustomAccentRGB(color: value) else { return }
                draft.edit(rgb.hex, dark: dark, currentGeneration: session.accountGeneration, acceptsActions: session.acceptsProfileActions)
            }), supportsOpacity: false)
            TextField(title, text: Binding(get: { dark ? draft.darkHex : draft.lightHex }, set: { value in
                draft.edit(value, dark: dark, currentGeneration: session.accountGeneration, acceptsActions: session.acceptsProfileActions)
            })).textFieldStyle(.roundedBorder).monospaced().frame(width: 110)
        }.disabled(!isCurrent)
    }
}
