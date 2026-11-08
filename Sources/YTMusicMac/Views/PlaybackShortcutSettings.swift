import SwiftUI

struct PlaybackShortcutSettings: View {
    let bindings: PlaybackShortcutBindings
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PlaybackShortcut?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Playback Shortcuts").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Form {
                Section {
                    Text("These shortcuts work only in this app. Text fields, search, web pages, and sheets keep their own keys.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let message = bindings.loadMessage { Text(message).foregroundStyle(.secondary) }
                    ForEach(PlaybackShortcut.allCases, id: \.self) { action in
                        LabeledContent(action.title) {
                            HStack(spacing: 12) {
                                if let binding = bindings.binding(for: action) {
                                    Text(binding.displayText).monospaced()
                                        .accessibilityLabel(binding.accessibilityText)
                                } else {
                                    Text("Disabled").foregroundStyle(.secondary)
                                }
                                Button("Edit…") { editing = action }
                                    .accessibilityLabel("Edit \(action.title) shortcut")
                            }
                        }
                    }
                }
                Section {
                    Button("Reset All Playback Shortcuts", action: bindings.resetAll)
                    Text("Navigation, search, and window shortcuts keep their standard bindings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 620, height: 570)
        .sheet(item: $editing) { action in PlaybackBindingEditor(action: action, bindings: bindings) }
    }
}

extension PlaybackShortcut: Identifiable { var id: String { rawValue } }

private struct PlaybackBindingEditor: View {
    let action: PlaybackShortcut
    let bindings: PlaybackShortcutBindings
    @Environment(\.dismiss) private var dismiss
    @State private var key: String
    @State private var modifiers: PlaybackBindingModifiers
    @State private var error: String?

    init(action: PlaybackShortcut, bindings: PlaybackShortcutBindings) {
        self.action = action
        self.bindings = bindings
        let binding = bindings.binding(for: action) ?? action.defaultBinding
        _key = State(initialValue: binding.key)
        _modifiers = State(initialValue: binding.modifiers)
    }

    private var candidate: PlaybackKeyBinding { PlaybackKeyBinding(key: key, modifiers: modifiers) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(action.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Picker("Key", selection: $key) {
                ForEach(PlaybackKeyBinding.supportedKeys, id: \.self) { key in
                    Text(PlaybackKeyBinding(key: key, modifiers: []).keyTitle).tag(key)
                }
            }.frame(maxWidth: 250)
            HStack(spacing: 16) {
                modifier(AppLocalization.text("Command"), flag: .command)
                modifier(AppLocalization.text("Option"), flag: .option)
                modifier(AppLocalization.text("Control"), flag: .control)
                modifier(AppLocalization.text("Shift"), flag: .shift)
            }
            Text(candidate.displayText).font(.title3.monospaced()).accessibilityLabel(candidate.accessibilityText)
            Text("Choose Command or Control with a key. Standard Mac and app combinations stay reserved. Play/Pause can keep its default Space key.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Use Default") { perform { try bindings.reset(action) } }
                    .disabled(bindings.isDefault(action))
                Button("Disable Shortcut") { perform { try bindings.assign(nil, to: action) } }
                    .disabled(bindings.binding(for: action) == nil)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { perform { try bindings.assign(candidate, to: action) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 650)
        .onChange(of: key) { error = nil }
        .onChange(of: modifiers) { error = nil }
    }

    private func modifier(_ title: String, flag: PlaybackBindingModifiers) -> some View {
        Toggle(title, isOn: Binding(get: { modifiers.contains(flag) }, set: { enabled in
            if enabled { modifiers.insert(flag) } else { modifiers.remove(flag) }
        }))
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
