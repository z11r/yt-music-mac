import Foundation
import MusicCore
import Observation
import YouTubeMusic

enum QueueBuilderCopy {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "QueueBuilder", bundle: .module, value: key, comment: "")
    }
}

struct CatalogQueueOwner: Equatable, Sendable {
    let account: UUID
    let startup: UUID
    let queue: QueueRevision
}
struct CatalogQueueIdentity: Equatable, Sendable {
    let scope: UUID
    let accountID: String?
    let isAuthenticated: Bool
    init(_ session: MusicSession) {
        scope = session.scope; accountID = session.accountID; isAuthenticated = session.isAuthenticated
    }
}
typealias CatalogQueueLoad = @MainActor @Sendable (String, UUID, CatalogQueueOwner) async throws -> MusicPage

enum CatalogQueueInput {
    static let byteLimit = 4_096
    static func queries(_ input: String) throws -> [String] {
        guard input.utf8.count <= byteLimit else { throw CatalogQueueIssue.input }
        let lines = input.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (1...5).contains(lines.count), lines.allSatisfy({
            $0.count <= 500 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { throw CatalogQueueIssue.input }
        var seen = Set<String>()
        return lines.filter { seen.insert($0.lowercased()).inserted }
    }
    static func name(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(name.count), name.utf8.count <= 400,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw CatalogQueueIssue.name }
        return name
    }
}

enum CatalogQueueIssue: Error, Equatable, Sendable {
    case input, name, busy
    var message: String {
        switch self {
        case .input: QueueBuilderCopy.text("Use 1–5 search phrases, one per line, with at most 500 characters each and 4,096 bytes in total.")
        case .name: QueueBuilderCopy.text("Use a local queue name of 1–100 characters without control characters.")
        case .busy: QueueBuilderCopy.text("The previous catalog read is finishing. Try again when it stops.")
        }
    }
}

/// One underlying read process-wide, including when a canceled transport has
/// not returned. No timer, retry, prefetch or idle work is owned here.
actor CatalogQueueReadSlot {
    static let shared = CatalogQueueReadSlot()
    private var busy = false
    func read(query: String, scope: UUID, owner: CatalogQueueOwner,
              load: CatalogQueueLoad) async throws -> MusicPage {
        try Task.checkCancellation()
        guard !busy else { throw CatalogQueueIssue.busy }
        busy = true; defer { busy = false }
        return try await load(query, scope, owner)
    }
}

struct CatalogQueueQueryReport: Sendable {
    let query: String
    let eligibleCount: Int
    let incomplete: Bool
}
struct CatalogQueueReview: Identifiable, Sendable {
    struct Row: Identifiable, Sendable {
        var id: String { track.id }
        let track: Track
        let queries: [String]
    }
    let id: UUID
    let rows: [Row]
    let reports: [CatalogQueueQueryReport]
}

@MainActor @Observable
final class CatalogQueueBuilder {
    private(set) var input = ""
    private(set) var review: CatalogQueueReview?
    private(set) var message: String?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var completedQueries = 0
    private(set) var scope = UUID()
    var isBusy: Bool { worker != nil || isSaving }
    @ObservationIgnored private(set) var worker: Task<Void, Never>?
    @ObservationIgnored private let owner: @MainActor () -> CatalogQueueOwner?
    @ObservationIgnored private let sessions: any MusicSessionProviding
    @ObservationIgnored private let slot: CatalogQueueReadSlot
    @ObservationIgnored private let load: CatalogQueueLoad
    @ObservationIgnored private let commit: @MainActor (CatalogQueueOwner, CatalogQueueIdentity, [Track], String?) async -> Bool
    @ObservationIgnored private var request: Request?
    private struct Request {
        let id: UUID
        let owner: CatalogQueueOwner
        let session: CatalogQueueIdentity
    }

    init(sessions: any MusicSessionProviding, slot: CatalogQueueReadSlot,
         owner: @escaping @MainActor () -> CatalogQueueOwner?,
         load: @escaping CatalogQueueLoad,
         commit: @escaping @MainActor (CatalogQueueOwner, CatalogQueueIdentity, [Track], String?) async -> Bool) {
        self.sessions = sessions; self.slot = slot; self.owner = owner; self.load = load; self.commit = commit
    }

    func edit(_ value: String) {
        cancel(clearInput: false)
        input = String(decoding: value.utf8.prefix(CatalogQueueInput.byteLimit + 1), as: UTF8.self)
    }
    func cancel(clearInput: Bool = true) {
        worker?.cancel(); scope = UUID(); request = nil; review = nil
        isLoading = false; completedQueries = 0; message = nil
        if clearInput { input = "" }
    }
    @discardableResult func search() -> Task<Void, Never>? {
        guard !isBusy else { message = CatalogQueueIssue.busy.message; return nil }
        let queries: [String]
        do { queries = try CatalogQueueInput.queries(input) }
        catch { message = CatalogQueueIssue.input.message; return nil }
        guard let owner = owner() else { cancel(); return nil }
        cancel(clearInput: false)
        let id = scope
        isLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; if self.scope == id { self.isLoading = false } }
            do {
                let session = CatalogQueueIdentity(await self.sessions.snapshot())
                guard self.current(id, owner) else { return }
                let request = Request(id: id, owner: owner, session: session)
                self.request = request
                var groups: [[Track]] = [], reports: [CatalogQueueQueryReport] = []
                for query in queries {
                    try await self.fresh(request)
                    let page = try await self.slot.read(query: query, scope: session.scope, owner: owner, load: self.load)
                    try await self.fresh(request)
                    var seen = Set<String>()
                    let songs = page.items.prefix(200).compactMap { item -> Track? in
                        guard case let .track(track) = item, QueueRecommendations.supports(track),
                              seen.insert(track.id).inserted else { return nil }
                        return track
                    }
                    groups.append(Array(songs.prefix(20)))
                    reports.append(.init(query: query, eligibleCount: songs.count,
                        incomplete: page.continuation != nil || page.items.count > 200 ||
                            page.unavailableItemCount > 0 || page.hasUnsupportedContent || songs.count > 20))
                    self.completedQueries += 1
                }
                try await self.fresh(request)
                var seen = Set<String>(), rows: [CatalogQueueReview.Row] = []
                for index in 0..<20 {
                    for group in groups where index < group.count {
                        let track = group[index]
                        guard rows.count < 50, seen.insert(track.id).inserted else { continue }
                        let sources = groups.indices.filter { groups[$0].contains(where: { $0.id == track.id }) }.map { queries[$0] }
                        rows.append(.init(track: track, queries: sources))
                    }
                }
                self.review = .init(id: id, rows: rows, reports: reports)
            } catch {
                guard self.current(id, owner) else { return }
                self.review = nil; self.request = nil
                if let issue = error as? CatalogQueueIssue { self.message = issue.message }
                else { self.message = QueueBuilderCopy.text("The catalog read could not finish. Search again to build a complete review; your queue has not changed.") }
            }
        }
        worker = task
        return task
    }

    func accept(reviewID: UUID, selectedIDs: Set<String>, name: String? = nil) async -> Bool {
        guard !isBusy, let review, review.id == reviewID, let request, scope == reviewID,
              !selectedIDs.isEmpty, selectedIDs.isSubset(of: Set(review.rows.map(\.id))) else { return false }
        let savedName: String?
        do { savedName = try name.map(CatalogQueueInput.name) }
        catch { message = CatalogQueueIssue.name.message; return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await fresh(request)
            let tracks = review.rows.filter { selectedIDs.contains($0.id) }.map(\.track)
            guard tracks.allSatisfy(QueueRecommendations.supports) else { return false }
            // Consume before any local write. A second click cannot duplicate it.
            self.review = nil; self.request = nil
            let accepted = await commit(request.owner, request.session, tracks, savedName)
            guard scope == reviewID else { return false }
            if accepted {
                message = savedName == nil ? QueueBuilderCopy.text("The selected songs were added to the queue.") :
                    QueueBuilderCopy.text("The selected songs were saved as a local queue.")
            } else {
                message = savedName == nil ? QueueBuilderCopy.text("The queue changed or reached its limit. Search again before adding songs.") :
                    QueueBuilderCopy.text("The local save could not be confirmed. Check Saved Queues before starting another review.")
            }
            return accepted
        } catch { if scope == reviewID { cancel(clearInput: false) }; return false }
    }
    private func current(_ id: UUID, _ expected: CatalogQueueOwner) -> Bool {
        scope == id && owner() == expected && !Task.isCancelled
    }
    private func fresh(_ request: Request) async throws {
        guard current(request.id, request.owner) else { throw CancellationError() }
        let session = await sessions.snapshot()
        guard current(request.id, request.owner), session.scope == request.session.scope,
              session.accountID == request.session.accountID, session.isAuthenticated == request.session.isAuthenticated else {
            throw MusicServiceError.sessionChanged
        }
    }
}
