import MusicCore
import SwiftUI
import YouTubeMusic

struct QueuePlaylistReviewRequest: Identifiable {
    let id = UUID()
    let snapshot: QueueSnapshot
    let accountGeneration: UUID
    let scope: UUID
}

struct QueuePlaylistSaveView: View {
    let session: AppSession
    let request: QueuePlaylistReviewRequest
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var confirmsCreate = false
    @State private var confirmsForget = false

    private var save: QueuePlaylistSave { session.queuePlaylistSave }
    private var songs: [QueuePlaylistPlan.Song] { save.pending?.plan.songs ?? save.review?.songs ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Save Queue as Playlist").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if save.isWorking {
                    Button(save.stopRequested ? "Stopping…" : "Stop After Current Request") { save.cancel() }
                        .disabled(save.stopRequested).keyboardShortcut(.cancelAction)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            Text("Review the entire captured queue in order, including repeated songs. The requested service playlist is private. Your playback queue stays available.")
                .font(.callout).foregroundStyle(.secondary)
            if session.account.isSignedIn && save.scope == request.scope {
                if let pending = save.pending {
                    Text(pending.plan.title).font(.headline)
                    Text("\(pending.confirmed.count) of \(pending.plan.songs.count) song entries confirmed · Last recorded \(pending.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let target = pending.targetID ?? save.knownTargetID {
                        Button("Open Existing Playlist") {
                            guard save.scope == request.scope else { return }
                            session.navigate(to: .collection(MusicCollection(id: target, kind: .playlist, title: pending.plan.title)))
                            dismiss()
                        }.disabled(save.isWorking)
                    }
                    if pending.phase == .creating {
                        Text(save.knownTargetID == nil
                            ? "Creation may have succeeded without returning a confirmed playlist ID. Review your service library manually. This save will not create another playlist automatically."
                            : "A playlist target was returned but could not be durably recorded. Keep this window available to review the existing playlist before forgetting the local record.")
                            .font(.callout)
                        Button("Open Library to Review") { session.navigate(to: .library); dismiss() }.disabled(save.isWorking)
                    } else if pending.phase == .completed {
                        Text("All reviewed song entries were confirmed. The playlist is kept when this local record is cleared.").font(.callout)
                    }
                } else if save.review != nil {
                    TextField("Private playlist title", text: $title).textFieldStyle(.roundedBorder).disabled(save.isWorking)
                    Text("\(songs.count) reviewed song entries · Requested privacy: Private").font(.caption).foregroundStyle(.secondary)
                }
                List(Array(songs.enumerated()), id: \.element.id) { index, song in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.title.isEmpty ? AppLocalization.text("Untitled song") : song.title).lineLimit(1)
                            Text(song.artist.isEmpty ? AppLocalization.text("Unknown artist") : song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .frame(minHeight: 180)
                actions
            } else {
                ContentUnavailableView("Sign In to Review This Account's Queue", systemImage: "person.crop.circle")
            }
            if save.isLoading { ProgressView("Reading the local pending record…").controlSize(.small) }
            if save.isWorking {
                ProgressView(value: Double(save.pending?.confirmed.count ?? 0), total: Double(max(1, songs.count)))
            }
            if let message = save.statusMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
            if let error = save.errorMessage { InlineMessage(message: error) }
            if !save.canWrite {
                Text("Service playlist writing is not enabled in this build. Local saved queues and metadata export remain available.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Stopping keeps any created playlist. Uncertain batches are rechecked rather than resent; no partial playlist is deleted automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(minWidth: 620, idealWidth: 690, minHeight: 500, idealHeight: 600)
        .task { await session.prepareQueuePlaylistReview(snapshot: request.snapshot, expectedAccount: request.accountGeneration, expectedScope: request.scope) }
        .onChange(of: save.scope) { dismiss() }
        .confirmationDialog("Create the reviewed private playlist?", isPresented: $confirmsCreate, titleVisibility: .visible) {
            Button("Create Private Playlist") {
                if let pending = save.pending, pending.phase == .prepared {
                    Task { await save.resume(operationID: pending.plan.id, expectedScope: request.scope) }
                } else if let review = save.review {
                    let reviewedTitle = title
                    Task { await save.start(title: reviewedTitle, reviewID: review.id, expectedScope: request.scope) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Songs will be added in batches of at most 100 and read back in the reviewed order. The captured queue is fixed for this save.") }
        .confirmationDialog("Forget this local pending-save record?", isPresented: $confirmsForget, titleVisibility: .visible) {
            if let pending = save.pending {
                Button("Forget Local Record", role: .destructive) {
                    Task { await save.forget(operationID: pending.plan.id, revision: pending.revision, expectedScope: request.scope) }
                }
            }
            Button("Keep Record", role: .cancel) { }
        } message: { Text("The service playlist will remain. Review YouTube Music first: forgetting an uncertain create record permits a later save to create another playlist.") }
    }

    private var actions: some View {
        HStack {
            if let pending = save.pending {
                if pending.phase == .prepared {
                    Button("Create Reviewed Playlist…") { confirmsCreate = true }.disabled(!save.canWrite || save.isWorking || save.isLoading)
                } else if pending.phase != .creating && pending.phase != .completed {
                    Button("Recheck Only") { Task { await save.resume(operationID: pending.plan.id, expectedScope: request.scope, recheckOnly: true) } }
                        .disabled(!save.canWrite || save.isWorking || save.isLoading)
                    Button("Continue Reviewed Save") { Task { await save.resume(operationID: pending.plan.id, expectedScope: request.scope) } }
                        .disabled(!save.canWrite || save.isWorking || save.isLoading)
                }
                Spacer()
                Button(pending.phase == .completed ? "Clear Completed Local Record…" : "Forget Local Record…", role: .destructive) { confirmsForget = true }
                    .disabled(save.isWorking || save.isLoading)
            } else if save.review != nil {
                Button("Create Private Playlist…") { confirmsCreate = true }
                    .disabled(!save.canWrite || save.isWorking || save.isLoading || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
