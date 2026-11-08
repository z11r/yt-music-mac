import AppKit
import SwiftUI

struct UploadReviewButton: View {
    let session: AppSession
    @State private var isPresented = false
    var body: some View {
        let generation = session.accountGeneration
        Button("Review Files for Upload…") {
            guard session.acceptsProfileActions, session.accountGeneration == generation else { return }
            isPresented = true
        }
        .disabled(!session.acceptsProfileActions)
        .sheet(isPresented: $isPresented) { UploadReviewView(session: session) }
    }
}

struct UploadReviewView: View {
    let session: AppSession
    @State private var review: UploadFileReview
    @Environment(\.dismiss) private var dismiss

    init(session: AppSession) {
        self.session = session
        _review = State(initialValue: UploadFileReview(context: session.accountGeneration,
            inspect: { try await NativeUploadFileMetadataReader.shared.inspect($0) },
            openURL: { NSWorkspace.shared.open($0) }, picker: NativeUploadReviewFilePicker(),
            isCurrent: { [weak session] context in
                guard let session else { return false }
                return session.acceptsProfileActions && session.accountGeneration == context
            }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Music Upload Files").font(.title2.bold())
            Text("Review file names, extensions and sizes on this Mac. This app does not upload, delete or modify files here.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose Files…", action: chooseFiles).disabled(review.isChoosing || review.isReviewing)
                if review.isReviewing {
                    ProgressView("Reviewing File Details…").controlSize(.small)
                    Button("Cancel Review") { review.cancel() }
                }
                Spacer()
                Button("Clear Review") { review.clear(context: session.accountGeneration) }
                    .disabled(review.rows.isEmpty && review.message == nil)
            }
            List {
                if review.rows.isEmpty {
                    Text("Choose or drop up to 100 files. Folders are not scanned.").foregroundStyle(.secondary)
                }
                ForEach(review.rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: row.name).fontWeight(.medium).lineLimit(2)
                            Spacer()
                            if let size = row.byteCount, size >= 0 {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        status(row.status).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary) }
            .dropDestination(for: URL.self) { urls, _ in
                guard session.acceptsProfileActions, review.context == session.accountGeneration, !review.isChoosing else { return false }
                return review.review(urls, expectedContext: session.accountGeneration)
            }
            Text(review.summary).font(.caption).foregroundStyle(.secondary)
            Text("A matching extension does not verify audio contents, DRM, account eligibility or remaining service quota.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Google lists FLAC, M4A, MP3, OGG and WMA. Uploading requires a personal account; Brand Accounts cannot upload.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("Your browser has a separate sign-in from this app. Check its account, then use the profile menu's Upload music action. This app cannot observe or cancel browser uploads.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = review.message { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Google Upload Guidance") { review.openHelp(expectedContext: session.accountGeneration) }
                Button("Open YouTube Music in Browser") { review.openService(expectedContext: session.accountGeneration) }
                Spacer()
                Button("Done", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 740, height: 650)
        .onChange(of: session.libraryEditingScope) {
            review.clear(context: session.accountGeneration)
        }
        .onChange(of: session.accountGeneration) {
            review.clear(context: session.accountGeneration)
            if !session.acceptsProfileActions { stop(); dismiss() }
        }
        .onChange(of: session.isProfileSuspended) {
            if session.isProfileSuspended { stop(); dismiss() }
        }
        .onChange(of: session.isShuttingDown) {
            if session.isShuttingDown { stop(); dismiss() }
        }
        .onDisappear(perform: stop)
    }

    @ViewBuilder private func status(_ value: UploadReviewRow.Status) -> some View {
        switch value {
        case .checking: Text("Checking file details")
        case .formatMatches: Text("Extension matches; service checks are still required")
        case let .issue(issue): Text(issue.title)
        }
    }
    private func chooseFiles() {
        guard session.acceptsProfileActions, review.context == session.accountGeneration else { return }
        review.chooseFiles(expectedContext: session.accountGeneration)
    }
    private func stop() {
        review.clear(context: UUID())
    }
}
