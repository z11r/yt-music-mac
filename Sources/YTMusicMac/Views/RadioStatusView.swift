import SwiftUI

/// Shows radio loading and why autoplay or a radio stopped, with a retry when one can help.
struct RadioStatusView: View {
    let session: AppSession

    var body: some View {
        if let status = session.radio.status {
            if status.isLoading {
                loading(status.message)
            } else if status.retry != nil {
                InlineMessage(message: status.message, actionTitle: "Try Again") { session.retryRadio() }
            } else {
                InlineMessage(message: status.message)
            }
        }
    }

    private func loading(_ message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(message).font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .accessibilityElement(children: .combine)
    }
}
