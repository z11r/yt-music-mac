import SwiftUI

struct QuickCommandsView: View {
    let palette: QuickCommandPalette
    @FocusState private var inputFocused: Bool
    private let examples = ["play / lire · pause · next / suivant · previous / précédent",
        "open home / ouvrir accueil · open library / ouvrir bibliothèque",
        "open songs · open artists · open followed artists · open uploads",
        "open podcasts · open your podcasts · open saved episodes · open queue",
        "search <text> / rechercher <texte>", "timer 30 min / minuterie 30 min",
        "timer end / minuterie fin · timer off / minuterie arrêt", "volume 50 · seek 1:30 / position 1:30",
        "shuffle on/off / aléatoire oui/non · repeat off/all/one / répétition non/toutes/une"]
    var body: some View {
        let ticket = palette.ticket
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Commands").font(.title2)
            Text("Exact commands run existing app controls. Search opens results without starting playback.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Type an exact command", text: Binding(get: { palette.input }, set: { palette.edit($0) }))
                .textFieldStyle(.roundedBorder).focused($inputFocused)
                .accessibilityIdentifier("quick-command-input")
                .onSubmit { _ = palette.run(ticket: ticket) }
            if let message = palette.message { Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("Examples (English / French)").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(examples, id: \.self) { example in Text(verbatim: example).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 240)
            HStack {
                Button("Close", role: .cancel) { palette.invalidate() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Run Command") { _ = palette.run(ticket: ticket) }
                    .keyboardShortcut(.defaultAction).disabled(palette.input.isEmpty)
            }
        }
        .padding(20).frame(width: 560)
        .task {
            await Task.yield()
            guard palette.isPresented, palette.ticket == ticket else { return }
            inputFocused = true
        }
        .onExitCommand { palette.invalidate() }
    }
}

private struct QuickCommandsFocusKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var openQuickCommands: (() -> Void)? {
        get { self[QuickCommandsFocusKey.self] }
        set { self[QuickCommandsFocusKey.self] = newValue }
    }
}
struct QuickCommandsMenuButton: View {
    @FocusedValue(\.openQuickCommands) private var open
    var body: some View { Button("Quick Commands…") { open?() }.disabled(open == nil) }
}
