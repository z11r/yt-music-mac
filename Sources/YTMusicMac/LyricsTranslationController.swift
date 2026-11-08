import Foundation
import MusicCore
import Observation
import YouTubeMusic

struct LyricsTranslationSource: Equatable, Sendable {
    static let maximumBytes = 16_384
    let requestID: UUID
    let videoID: String
    let text: String
    let originalProvider: String?
    private init(requestID: UUID, videoID: String, text: String, originalProvider: String?) {
        self.requestID = requestID; self.videoID = videoID; self.text = text; self.originalProvider = originalProvider
    }
    static func capture(requestID: UUID, videoID: String, lyrics: MusicLyrics) -> Self? {
        guard videoID.utf8.count == 11, videoID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let originalProvider = lyrics.source
        if let originalProvider {
            guard originalProvider.utf8.prefix(16_385).count <= 16_384, originalProvider.count <= 4_096,
                  !originalProvider.contains("\0") else { return nil }
        }
        let text: String
        switch lyrics {
        case let .plain(value, _):
            guard value.utf8.prefix(maximumBytes + 1).count <= maximumBytes,
                  value.split(separator: "\n", omittingEmptySubsequences: false).count <= 500 else { return nil }
            text = value
        case let .timed(lines, _):
            guard lines.count <= 500 else { return nil }
            var bytes = max(0, lines.count - 1)
            for line in lines {
                bytes += line.text.utf8.prefix(maximumBytes + 1).count
                guard bytes <= maximumBytes else { return nil }
            }
            text = lines.map(\.text).joined(separator: "\n")
        case .unavailable: return nil
        }
        guard text.split(separator: "\n", omittingEmptySubsequences: false).count <= 500,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.contains("\0") else { return nil }
        return .init(requestID: requestID, videoID: videoID, text: text, originalProvider: originalProvider)
    }
}
struct LyricsTranslationTarget: Identifiable, Equatable, Sendable {
    let id: UUID
    let profile: UUID
    let account: UUID
    let entry: UUID
    let occurrence: PlaybackOccurrence?
    let source: LyricsTranslationSource
    func matches(profile: UUID, account: UUID, entry: UUID?, occurrence: PlaybackOccurrence?, source: LyricsTranslationSource?) -> Bool {
        self.profile == profile && self.account == account && self.entry == entry && self.occurrence == occurrence && self.source == source
    }
}
struct LyricsTranslationLanguage: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}
struct LyricsTranslationPair: Equatable, Sendable { let source: String; let target: String }
struct LyricsTranslationJob: Equatable, Sendable {
    let id: UUID
    let target: LyricsTranslationTarget
    let pair: LyricsTranslationPair
}
struct LyricsTranslationResponse: Sendable {
    let text: String
    let sourceLanguage: String
    let targetLanguage: String
}
@MainActor protocol LyricsTranslating: AnyObject {
    func supportsPair() async throws -> Bool
    func prepare() async throws
    func translate(_ text: String) async throws -> LyricsTranslationResponse
}
/// One immutable task host may revoke this token once. It never calls a native
/// session, and a replacement host always receives a distinct token.
final class LyricsTranslationHostLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true
    func revoke() { lock.withLock { isActive = false } }
    func check() throws { guard lock.withLock({ isActive }), !Task.isCancelled else { throw CancellationError() } }
}

/// The native task and fake tests use the same synchronous cancellation boundary.
/// The token contains no native reference and can be revoked without an actor hop.
@MainActor func withLyricsTranslationHostLifetime(_ lifetime: LyricsTranslationHostLifetime,
                                                 operation: @MainActor () async -> Void) async {
    await withTaskCancellationHandler { await operation() } onCancel: { lifetime.revoke() }
}
@MainActor @Observable final class LyricsTranslationAdmission {
    static let shared = LyricsTranslationAdmission()
    private(set) var ticket: UUID?
    var isBusy: Bool { ticket != nil }
    func reserve() -> UUID? { guard ticket == nil else { return nil }; let id = UUID(); ticket = id; return id }
    func release(_ id: UUID) { if ticket == id { ticket = nil } }
}

/// Owns only ephemeral source/results and cancellation authority, never a reusable native session.
@MainActor @Observable final class LyricsTranslationController {
    enum State: Equatable { case idle, loadingLanguages, preparing, translating, available(String), unavailable, failed, canceled }
    private var storedTarget: LyricsTranslationTarget?
    private var storedState: State = .idle
    private var storedLanguages: [LyricsTranslationLanguage] = []
    @ObservationIgnored private let admission: LyricsTranslationAdmission
    @ObservationIgnored private var ownerIsCurrent: (@MainActor () -> Bool)?
    @ObservationIgnored private var currentJob: LyricsTranslationJob?
    @ObservationIgnored private var ticket: UUID?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var settlementWaiters: [CheckedContinuation<Void, Never>] = []
    var target: LyricsTranslationTarget? { ownerIsCurrent?() == true ? storedTarget : nil }
    var state: State { target != nil ? storedState : .idle }
    var languages: [LyricsTranslationLanguage] { target != nil ? storedLanguages : [] }
    var isBusy: Bool { admission.isBusy }
    init(admission: LyricsTranslationAdmission? = nil) { self.admission = admission ?? .shared }
    @discardableResult func open(_ target: LyricsTranslationTarget, isCurrent: @escaping @MainActor () -> Bool) -> Bool {
        guard isCurrent() else { return false }
        clear(); storedTarget = target; ownerIsCurrent = isCurrent
        return true
    }
    func close(_ id: UUID) { if storedTarget?.id == id { clear() } }
    func cancel(_ id: UUID) {
        guard storedTarget?.id == id else { return }
        let hadWork = ticket != nil
        cancel()
        if !hadWork { storedState = .idle }
    }
    func clear() {
        cancel(); storedTarget = nil; ownerIsCurrent = nil; storedLanguages = []; storedState = .idle
    }
    func cancel() {
        currentJob = nil; storedState = .canceled; worker?.cancel()
        // A configuration that never reached its adapter admitted no async call.
        if !active, let ticket { settled(ticket) }
    }
    func loadLanguages(for target: LyricsTranslationTarget, _ fetch: @escaping @MainActor () async throws -> [LyricsTranslationLanguage]) {
        guard self.target == target, ticket == nil, let ticket = admission.reserve() else { return }
        self.ticket = ticket; active = true; storedState = .loadingLanguages
        worker = Task { [self] in
            defer { settled(ticket) }
            guard accepts(target), !Task.isCancelled else { return }
            do {
                let values = try await fetch()
                guard accepts(target), !Task.isCancelled else { return }
                guard !values.isEmpty, values.count <= 256,
                      values.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.prefix(129).count <= 128 && !$0.name.isEmpty && $0.name.utf8.prefix(513).count <= 512 }),
                      Set(values.map(\.id)).count == values.count else {
                    storedState = .unavailable; return
                }
                storedLanguages = values; storedState = .idle
            } catch { if accepts(target), !Task.isCancelled { storedState = .failed } }
        }
    }
    func begin(for target: LyricsTranslationTarget, pair: LyricsTranslationPair) -> LyricsTranslationJob? {
        guard self.target == target, ticket == nil, pair.source != pair.target,
              storedLanguages.contains(where: { $0.id == pair.source }), storedLanguages.contains(where: { $0.id == pair.target }),
              let ticket = admission.reserve() else { return nil }
        let job = LyricsTranslationJob(id: UUID(), target: target, pair: pair)
        self.ticket = ticket; active = false; currentJob = job; storedState = .preparing
        return job
    }
    func run(_ job: LyricsTranslationJob, using provider: any LyricsTranslating) async {
        guard let ticket, !active, currentJob == job else { return }
        guard accepts(job.target), !Task.isCancelled else {
            currentJob = nil; settled(ticket); storedState = .canceled; return
        }
        active = true
        // Run inline in the view-supplied task. Never transfer its native session
        // into an unstructured worker that can outlive SwiftUI cancellation.
        defer {
            if currentJob == job, Task.isCancelled { storedState = .canceled }
            settled(ticket)
        }
        guard accepts(job), !Task.isCancelled else { return }
        do {
            let supported = try await provider.supportsPair()
            guard accepts(job), !Task.isCancelled else { return }
            guard supported else { storedState = .unavailable; return }
            try await provider.prepare()
            // No lyric text reaches the adapter after a stale preparation.
            guard accepts(job), !Task.isCancelled else { return }
            storedState = .translating
            let result = try await provider.translate(job.target.source.text)
            guard accepts(job), !Task.isCancelled else { return }
            guard result.sourceLanguage == job.pair.source, result.targetLanguage == job.pair.target,
                  result.text.utf8.prefix(65_537).count <= 65_536, !result.text.contains("\0"),
                  !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                storedState = .unavailable; return
            }
            storedState = .available(result.text)
        } catch {
            if accepts(job), !Task.isCancelled { storedState = error is CancellationError ? .canceled : .failed }
        }
    }
    func waitForIdle() async {
        if ticket != nil { await withCheckedContinuation { settlementWaiters.append($0) } }
    }
    private func accepts(_ target: LyricsTranslationTarget) -> Bool { self.target == target }
    private func accepts(_ job: LyricsTranslationJob) -> Bool { currentJob == job && accepts(job.target) }
    private func settled(_ value: UUID) {
        admission.release(value)
        guard ticket == value else { return }
        ticket = nil; active = false; worker = nil; currentJob = nil
        let waiters = settlementWaiters; settlementWaiters = []; waiters.forEach { $0.resume() }
    }
}

enum LyricsTranslationText {
    static func text(_ key: StaticString) -> String {
        AppLocalization.bundle.localizedString(forKey: String(describing: key), value: nil, table: "LyricsTranslation")
    }
}
