import SwiftUI

struct CommandReviewView: View {
    let review: CommandReviewSession
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On-device Command Review").font(.title2)
            Text("Interpret one request, check the proposed exact command, then choose Run Proposed Command. Interpretation never runs an action by itself.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Describe one supported action", text: Binding(get: { review.input }, set: { review.edit($0) }))
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { review.interpret() }
            Text("Use digits for volume and minutes, m:ss for a position, or double quotes around an exact search query.")
                .font(.caption).foregroundStyle(.secondary)
            if review.isBusy {
                ProgressView("Interpreting or stopping the previous request…")
                Button("Cancel Interpretation") { review.cancel() }
            }
            if let message = review.message { Text(message).fixedSize(horizontal: false, vertical: true) }
            if let proposal = review.proposal {
                GroupBox("Proposed Exact Command") {
                    Text(verbatim: proposal.exact).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                Text("Check the action and every value. Search opens results; choosing a recording remains a separate action.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Run Proposed Command") { _ = review.run(ticket: proposal.ticket) }
                    .disabled(review.isBusy)
            }
            HStack {
                Button("Close", role: .cancel) { review.invalidate() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Interpret Request") { review.interpret() }
                    .disabled(!review.enabled || review.isBusy || review.input.isEmpty)
            }
        }
        .padding(20).frame(width: 580)
        .onAppear { focused = true }
        .onExitCommand { review.invalidate() }
    }
}

struct CommandInterpretationSettings: View {
    let session: AppSession
    var body: some View {
        let generation = session.accountGeneration
        Section("On-device Commands") {
            Toggle("Enable On-device Command Interpretation", isOn: Binding(
                get: { session.commandReview.enabled },
                set: { value in session.commandReview.setEnabled(value, expectedGeneration: generation) }
            )).disabled(!session.acceptsProfileActions)
            Text("Only the text you explicitly submit is given to Apple's on-device model. The app sends no account, queue or listening metadata with it and stores no prompt or response history. A proposed action always needs your review and Run.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Requires macOS 26, an eligible Apple silicon Mac, Apple Intelligence enabled and a ready model. The app does not enable Apple Intelligence, download a model or use a cloud fallback. Exact Quick Commands remain available on macOS 14 and Intel.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CommandReviewFocusKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var openCommandReview: (() -> Void)? {
        get { self[CommandReviewFocusKey.self] }
        set { self[CommandReviewFocusKey.self] = newValue }
    }
}
struct CommandReviewMenuButton: View {
    @FocusedValue(\.openCommandReview) private var open
    var body: some View { Button("On-device Command Review…") { open?() }.disabled(open == nil) }
}
