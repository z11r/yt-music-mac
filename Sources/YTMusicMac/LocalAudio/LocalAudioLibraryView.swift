import MusicCore
import SwiftUI

/// Reusable content; its persistent profile owner supplies storage and queue actions.
struct LocalAudioLibraryWindowContent<Target: Equatable & Sendable>: View {
    let controller: LocalAudioLibraryController<Target>
    @State private var selection: Set<UUID> = []
    @State private var removal: LocalAudioRemovalReview?

    var body: some View {
        let scope = controller.scope
        let owner = controller.owner
        let target = controller.queueTarget
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: LocalAudioLibraryCopy.text("Local Audio" )).font(.title2.bold())
            Text(verbatim: LocalAudioLibraryCopy.text("Keep file locations and metadata in this local profile. Audio files stay where you chose them; they are not uploaded or copied."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(LocalAudioLibraryCopy.text("Choose Files…")) { controller.chooseFiles(expected: scope) }
                    .disabled(controller.isBusy || !controller.canWrite)
                Button(LocalAudioLibraryCopy.text("Reload")) { controller.refresh(expected: scope) }
                    .disabled(controller.isBusy)
                Spacer()
                if controller.isBusy { ProgressView().controlSize(.small).accessibilityLabel(LocalAudioLibraryCopy.text("Checking local files")) }
            }
            Text(verbatim: LocalAudioLibraryCopy.format("%lld local files", Int64(controller.records.count)))
                .font(.caption).foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(controller.records) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: record.metadata.title).lineLimit(2)
                        Text(verbatim: record.metadata.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(record.id)
                    .contextMenu {
                        Button(LocalAudioLibraryCopy.text("Locate or Reauthorize…")) {
                            controller.chooseFiles(expected: scope, reauthorizing: record.reference)
                        }.disabled(controller.isBusy || !controller.canWrite)
                        Button(LocalAudioLibraryCopy.text("Remove from Local Library…"), role: .destructive) {
                            if let revision = controller.document?.revision {
                                removal = .init(reference: record.reference, revision: revision, scope: scope)
                            }
                        }.disabled(controller.isBusy || !controller.canWrite)
                    }
                }
            }
            .overlay {
                if controller.records.isEmpty && !controller.isBusy {
                    Text(verbatim: LocalAudioLibraryCopy.text("Choose audio files to review before adding them to this local library."))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
                }
            }
            if let message = controller.message {
                Text(verbatim: message).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if controller.hasQueueActions {
                HStack {
                    Button(LocalAudioLibraryCopy.text("Add to Queue")) {
                        if let target { controller.requestQueueAction(play: false, selectedIDs: selection, target: target, expected: scope) }
                    }
                    Button(LocalAudioLibraryCopy.text("Play Selection")) {
                        if let target { controller.requestQueueAction(play: true, selectedIDs: selection, target: target, expected: scope) }
                    }
                    Spacer()
                }.disabled(controller.isBusy || selection.isEmpty || selection.count > 100 || target == nil)
            }
        }
        .padding(20).frame(minWidth: 480, idealWidth: 660, minHeight: 360, idealHeight: 560)
        .task(id: owner) { await controller.open(expectedOwner: owner) }
        .onDisappear { controller.quiesce() }
        .onChange(of: controller.scope) { _, _ in selection = []; removal = nil }
        .onChange(of: controller.document?.revision) { _, _ in selection.formIntersection(Set(controller.records.map(\.id))) }
        .sheet(isPresented: Binding(get: { controller.review != nil }, set: { if !$0 { controller.cancelReview() } })) {
            LocalAudioImportReviewView(controller: controller)
        }
        .confirmationDialog(LocalAudioLibraryCopy.text("Remove this library record?"), isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            if let removal {
                Button(LocalAudioLibraryCopy.text("Remove Record"), role: .destructive) {
                    controller.remove(removal.reference, revision: removal.revision, expected: removal.scope)
                    self.removal = nil
                }
            }
            Button(LocalAudioLibraryCopy.text("Cancel"), role: .cancel) { removal = nil }
        } message: {
            Text(verbatim: LocalAudioLibraryCopy.text("Only this profile’s saved location and metadata will be removed. The audio file stays on disk. Existing queue references may become unavailable. Stop playback first; other app instances may still have access."))
        }
    }
}

private struct LocalAudioRemovalReview {
    let reference: LocalAudioReference
    let revision: UUID
    let scope: LocalAudioLibraryUIScope
}

private struct LocalAudioImportReviewView<Target: Equatable & Sendable>: View {
    let controller: LocalAudioLibraryController<Target>
    @State private var selected: Set<UUID> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let review = controller.review {
                let ready = Set(review.rows.filter { $0.reviewed != nil }.map(\.id))
                Text(verbatim: LocalAudioLibraryCopy.text("Review Local Files")).font(.title2.bold())
                Text(verbatim: LocalAudioLibraryCopy.text("Confirm to save the selected file locations and metadata in this profile. No audio will be copied or uploaded. Access is saved only after confirmation."))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                if case .reauthorize = review.purpose {
                    Text(verbatim: LocalAudioLibraryCopy.text("Reauthorization must identify the same file. Import a different file as a new library record. Reauthorization does not start playback."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                List(review.rows, selection: $selected) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: row.reviewed?.metadata.title ?? row.filename).lineLimit(2)
                        switch row.status {
                        case .checking:
                            Text(verbatim: LocalAudioLibraryCopy.text("Checking file…")).foregroundStyle(.secondary)
                        case let .ready(file):
                            Text(verbatim: file.metadata.artist).foregroundStyle(.secondary).lineLimit(1)
                        case let .issue(issue):
                            Text(verbatim: issue.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }.tag(row.id)
                }
                .onChange(of: ready, initial: true) { _, value in selected = value }
                .disabled(controller.isBusy)
                Text(verbatim: LocalAudioLibraryCopy.format("%lld files selected", Int64(selected.intersection(ready).count)))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(LocalAudioLibraryCopy.text("Cancel"), role: .cancel) { controller.cancelReview() }
                    if case .reauthorize = review.purpose {
                        Button(LocalAudioLibraryCopy.text("Import as New…")) {
                            controller.cancelReview()
                            controller.chooseFiles(expected: review.scope)
                        }.disabled(controller.isBusy)
                    }
                    Spacer()
                    Button(LocalAudioLibraryCopy.text("Save Selected Locations")) {
                        controller.confirm(reviewID: review.id, selectedIDs: selected, expected: review.scope)
                    }.disabled(controller.isBusy || selected.isEmpty || !selected.isSubset(of: ready))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }.padding(20).frame(minWidth: 480, idealWidth: 640, minHeight: 340, idealHeight: 460)
            .interactiveDismissDisabled(controller.isBusy)
    }
}
