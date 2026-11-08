import MusicCore
import SwiftUI

struct LocalSongRulesSidebar: View {
    let session: AppSession
    var body: some View {
        if session.account.isSignedIn {
            Section("Local Song Rules") {
                ForEach(session.songRules.archive.rules) { rule in
                    let scope = session.songRules.scope
                    Button {
                        session.songRules.select(rule.id, expectedScope: scope)
                        session.showsSongRules = true
                    } label: { Label(rule.name, systemImage: "line.3.horizontal.decrease.circle") }
                    .help("Open local results from captured loaded songs")
                }
                Button("Edit Local Song Rules…") {
                    session.songRules.select(nil, expectedScope: session.songRules.scope)
                    session.showsSongRules = true
                }
            }
        }
    }
}

struct LocalSongRulesView: View {
    let session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var displayedScope: UUID
    @State private var draft: LocalSongRule
    @State private var selection = Set<UUID>()
    @State private var deletesRule = false
    @State private var deletionID: UUID?
    @State private var clearsSnapshot = false

    init(session: AppSession) {
        self.session = session
        _displayedScope = State(initialValue: session.songRules.scope)
        _draft = State(initialValue: session.songRules.selectedRule ?? Self.newRule())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Local Song Rules").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Rules evaluate this account's captured song metadata on this Mac. Every rule uses the same dated snapshot of loaded songs.")
                .font(.callout).foregroundStyle(.secondary)
            if session.account.isSignedIn && session.songRules.scope == displayedScope {
                HSplitView {
                    VStack(alignment: .leading, spacing: 10) {
                        List(session.songRules.archive.rules, selection: Binding(get: { session.songRules.selectedID }, set: {
                            session.songRules.select($0, expectedScope: displayedScope)
                        })) { rule in Text(rule.name).tag(rule.id) }
                        HStack {
                            Button("New") { session.songRules.select(nil, expectedScope: displayedScope); draft = Self.newRule() }
                            Button("Delete…", role: .destructive) {
                                deletionID = session.songRules.selectedID; deletesRule = true
                            }.disabled(session.songRules.selectedID == nil)
                        }
                    }
                    .frame(minWidth: 170, idealWidth: 190).padding(.trailing, 10)
                    VStack(alignment: .leading, spacing: 14) {
                        editor
                        Divider()
                        sourceControls
                        results
                    }
                    .padding(.leading, 12).frame(minWidth: 610)
                }
                .disabled(session.songRules.isWorking)
            } else {
                ContentUnavailableView("Sign In to Use Local Song Rules", systemImage: "person.crop.circle")
            }
            if session.songRules.isWorking { ProgressView("Loading or saving local song rules…").controlSize(.small) }
            if let error = session.songRules.errorMessage { InlineMessage(message: error) }
        }
        .padding(20)
        .frame(minWidth: 870, idealWidth: 1_010, minHeight: 660, idealHeight: 730)
        .task { await session.songRules.refresh(expectedScope: displayedScope) }
        .onChange(of: session.songRules.scope) { dismiss() }
        .onChange(of: session.songRules.selectedID) { draft = session.songRules.selectedRule ?? Self.newRule(); selection.removeAll() }
        .onChange(of: session.songRules.revision) { selection = selection.intersection(Set(session.songRules.evaluation.matches.map(\.id))) }
        .confirmationDialog("Delete this local song rule?", isPresented: $deletesRule, titleVisibility: .visible) {
            Button("Delete Rule", role: .destructive) {
                if let deletionID { Task { await session.songRules.remove(id: deletionID, expectedScope: displayedScope) } }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("The shared captured-song snapshot and your YouTube Music library stay available.") }
        .confirmationDialog("Clear the captured songs for this account?", isPresented: $clearsSnapshot, titleVisibility: .visible) {
            Button("Clear Captured Songs", role: .destructive) { Task { await session.songRules.clearSnapshot(expectedScope: displayedScope) } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Saved rules remain. Capture loaded songs again to evaluate them.") }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Local song-rule name", text: $draft.name).textFieldStyle(.roundedBorder)
                Picker("Match", selection: $draft.match) {
                    Text("All conditions").tag(LocalSongRuleMatch.all)
                    Text("Any condition").tag(LocalSongRuleMatch.any)
                }.labelsHidden().frame(width: 180)
                Button("Save Rule") {
                    let rule = draft
                    Task {
                        await session.songRules.save(rule, expectedScope: displayedScope)
                        if session.songRules.scope == displayedScope, session.songRules.errorMessage == nil,
                           let saved = session.songRules.selectedRule { draft = saved }
                    }
                }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($draft.clauses) { $clause in
                        LocalSongRuleClauseEditor(clause: $clause, canRemove: draft.clauses.count > 1) {
                            draft.clauses.removeAll { $0.id == clause.id }
                        }
                    }
                }.padding(.trailing, 4)
            }.frame(minHeight: 60, idealHeight: 105, maxHeight: 150)
            HStack {
                Button("Add Condition", systemImage: "plus") { draft.clauses.append(Self.newClause()) }
                    .disabled(draft.clauses.count >= 12)
                Spacer()
                Text("Save edits to update results.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Capture All Loaded Songs") { Task { await session.captureLoadedSongsForRules(expectedScope: displayedScope) } }
                    .disabled(session.page == nil)
                Button("Clear Snapshot…", role: .destructive) { clearsSnapshot = true }.disabled(session.songRules.archive.snapshot == nil)
                Spacer()
                Button("Reload Rules") { Task { await session.songRules.refresh(expectedScope: displayedScope) } }
            }
            if let snapshot = session.songRules.archive.snapshot {
                Text("\(snapshot.songs.count) song entries from “\(snapshot.sourceName)” · \(snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if snapshot.hasMorePages || snapshot.wasLoading || snapshot.isTruncated || snapshot.hasUnsupportedContent || snapshot.unavailableCount > 0 || snapshot.skippedCount > 0 {
                    Text(LocalSongRulePresentation.scopeDescription(snapshot)).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Open a page with songs, then capture its loaded metadata. Rules cover captured loaded songs only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var results: some View {
        let revision = session.songRules.revision
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(session.songRules.evaluation.matches.count) matching captured songs").font(.headline)
                Spacer()
                Button("Play Matches") { perform(play: true, selected: nil, revision: revision) }
                    .disabled(session.songRules.evaluation.matches.isEmpty)
                Button("Add Matches to Queue") { perform(play: false, selected: nil, revision: revision) }
                    .disabled(session.songRules.evaluation.matches.isEmpty)
            }
            Table(session.songRules.evaluation.matches, selection: $selection) {
                TableColumn("Title") { Text($0.title ?? AppLocalization.text("Unknown title")).lineLimit(1) }.width(min: 130, ideal: 210)
                TableColumn("Artist") { Text($0.artist ?? AppLocalization.text("Unknown artist")).lineLimit(1) }.width(min: 100, ideal: 150)
                TableColumn("Album") { Text($0.album ?? AppLocalization.text("Unknown")).lineLimit(1) }.width(min: 90, ideal: 130)
                TableColumn("Time") { Text($0.duration.map(playbackTime) ?? AppLocalization.text("Unknown")).monospacedDigit() }.width(70)
                TableColumn("Explicit") { Text($0.isExplicit.map { $0 ? AppLocalization.text("Yes") : AppLocalization.text("No") } ?? AppLocalization.text("Unknown")) }.width(80)
            }
            .frame(minHeight: 150)
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Play Selected") { perform(play: true, selected: ids, revision: revision) }.disabled(ids.isEmpty)
                Button("Add Selected to Queue") { perform(play: false, selected: ids, revision: revision) }.disabled(ids.isEmpty)
            }
            HStack {
                Text("Loaded snapshot only · \(session.songRules.evaluation.unknownCount) results unknown because metadata is missing")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Play Selected") { perform(play: true, selected: selection, revision: revision) }.disabled(selection.isEmpty)
                Button("Add Selected") { perform(play: false, selected: selection, revision: revision) }.disabled(selection.isEmpty)
            }
        }
    }

    private func perform(play: Bool, selected: Set<UUID>?, revision: UUID) {
        Task { await session.performSongRuleAction(play: play, selectedIDs: selected, expectedScope: displayedScope, expectedRevision: revision) }
    }
    private static func newClause() -> LocalSongRuleClause { LocalSongRuleClause(text: "") }
    private static func newRule() -> LocalSongRule { LocalSongRule(name: "", clauses: [newClause()]) }
}

private struct LocalSongRuleClauseEditor: View {
    @Binding var clause: LocalSongRuleClause
    let canRemove: Bool
    let remove: () -> Void
    var body: some View {
        HStack {
            Picker("Field", selection: $clause.field) {
                ForEach(LocalSongRuleField.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
            }.labelsHidden().frame(width: 100)
            Picker("Condition", selection: $clause.operation) {
                ForEach(clause.allowedOperators, id: \.self) { Text($0.localizedTitle).tag($0) }
            }.labelsHidden().frame(width: 145)
            if clause.usesText {
                TextField("Text", text: Binding(get: { clause.text ?? "" }, set: { clause.text = $0 })).textFieldStyle(.roundedBorder)
            } else if clause.usesNumber {
                TextField("Seconds", value: Binding(get: { clause.number ?? 180 }, set: { clause.number = $0 }), format: .number)
                    .textFieldStyle(.roundedBorder)
                Text("seconds").foregroundStyle(.secondary)
            } else { Spacer() }
            Button("Remove Condition", systemImage: "minus.circle", action: remove).labelStyle(.iconOnly).disabled(!canRemove)
        }
        .onChange(of: clause.field) { normalize() }
        .onChange(of: clause.operation) { normalize() }
    }
    private func normalize() {
        if !clause.allowedOperators.contains(clause.operation) { clause.operation = clause.allowedOperators[0] }
        clause.text = clause.usesText ? clause.text ?? "" : nil
        clause.number = clause.usesNumber ? clause.number ?? 180 : nil
    }

}
