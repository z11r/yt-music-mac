import SwiftUI

struct ProfileDeletionReviewView: View {
    @Bindable var controller: AppProfileDeletionController
    let review: ProfileDeletionReview
    @State private var confirmation = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete Additional Local Profile").font(.title2.bold())
            Text(verbatim: review.target.displayName).font(.headline)
            Text("This affects only this local profile's sign-in, provider credentials, settings, named index and supported local data. It does not delete your YouTube account or service library. Exported files outside the profile folder remain.")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(ProfileCleanupStep.allCases, id: \.self) { step in
                HStack(alignment: .top) {
                    Text(step.title)
                    Spacer()
                    switch review.probes[step.index] {
                    case .absent: Text("Already Absent").foregroundStyle(.secondary)
                    case .confirmed: Text("Confirmed Complete").foregroundStyle(.secondary)
                    case .ready: Text("Ready for Confirmed Cleanup").foregroundStyle(.secondary)
                    case let .blocked(problem): Text(problem.message).foregroundStyle(.secondary).frame(maxWidth: 300, alignment: .leading)
                    }
                }
            }
            if let problem = review.problem {
                Text(problem.message).font(.callout)
                Text("Confirmation will stage deletion only. No cleanup runs until the missing prerequisites are resolved and you review it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if review.snapshot.archive.deletions.first?.states.allSatisfy({ $0 == .pending }) == true {
                Button("Cancel Staged Deletion") { Task { await controller.cancelStagedDeletion(reviewID: review.id) } }
                    .disabled(controller.isWorking)
            }
            Text("Type the profile name to confirm. Cleanup is permanent; interrupted steps remain recorded for explicit review.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Profile Name", text: $confirmation).textFieldStyle(.roundedBorder)
            if controller.isWorking { ProgressView("Recording Profile Cleanup…") }
            HStack {
                Button(controller.isWorking ? AppLocalization.text("Stop After Current Step") : AppLocalization.text("Cancel"), role: .cancel) {
                    controller.cancelReview(); dismiss()
                }
                Spacer()
                Button(review.problem == nil ? AppLocalization.text("Delete Local Profile") : AppLocalization.text("Stage Deletion"), role: .destructive) {
                    Task { await controller.confirm(reviewID: review.id) }
                }.disabled(controller.isWorking || confirmation != review.target.displayName)
            }
        }.padding(24)
        }.frame(width: 680, height: 620)
            .onDisappear { controller.cancelReview() }
    }
}
