import Foundation
import MusicCore
import Observation
import YouTubeMusic

struct SponsorBlockPlaybackIdentity: Equatable, Sendable {
    let occurrence: PlaybackOccurrence
    let loadID: UUID
    let documentID: UUID
    let mediaGeneration: Int
    let commandRevision: Int
    let duration: TimeInterval
    static func verified(_ message: PlaybackBridgeMessage, occurrence: PlaybackOccurrence, commandRevision: Int) -> Self? {
        guard message.kind == .state || message.kind == .progress,
              message.confirmsEpisodeProgress, message.playbackIntent, message.mediaGeneration > 0,
              message.commandRevision == commandRevision, message.identity == PlaybackBridgeIdentity(occurrence),
              message.videoID == occurrence.trackID, message.position < message.duration else { return nil }
        return Self(occurrence: occurrence, loadID: message.loadID, documentID: message.documentID,
            mediaGeneration: message.mediaGeneration, commandRevision: message.commandRevision, duration: message.duration)
    }
}
struct SponsorBlockContext: Equatable, Sendable {
    let accountGeneration: UUID
    let playback: SponsorBlockPlaybackIdentity
    var videoID: String { playback.occurrence.trackID }
    static func make(track: Track, playback: SponsorBlockPlaybackIdentity, accountGeneration: UUID) -> Self? {
        guard PublicPlaybackMetadata(track: track) != nil, playback.occurrence.trackID == track.id,
              playback.mediaGeneration > 0, playback.duration.isFinite, playback.duration > 0, playback.duration <= 43_200 else { return nil }
        return Self(accountGeneration: accountGeneration, playback: playback)
    }
}
struct SponsorBlockPreview: Identifiable, Sendable {
    let id = UUID()
    let context: SponsorBlockContext
    let sections: [SponsorBlockSection]
    let expires: TimeInterval
}
struct SponsorBlockSeek: Sendable {
    let playback: SponsorBlockPlaybackIdentity
    let start: TimeInterval
    let end: TimeInterval
    var payload: [String: Any] {
        let occurrence = playback.occurrence
        return ["documentID": playback.documentID.uuidString.lowercased(), "mediaGeneration": playback.mediaGeneration,
            "expectedRevision": playback.commandRevision, "duration": playback.duration, "start": start, "end": end,
            "identity": ["sessionID": occurrence.sessionID.uuidString.lowercased(), "entryID": occurrence.entryID.uuidString.lowercased(),
                         "trackID": occurrence.trackID, "generation": String(occurrence.generation)]]
    }
}

@MainActor final class SponsorBlockSeekReply {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?
    private var result: Bool?
    func wait(sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
              start: (@escaping @MainActor (Bool) -> Void) -> Void) async -> Bool {
        if Task.isCancelled { finish(false) }
        if let result { return result }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in
                do { try await sleep() } catch { return }
                self?.finish(false)
            }
            start { [weak self] in self?.finish($0) }
        }
    }
    func finish(_ value: Bool) {
        guard result == nil else { return }
        result = value; timeout?.cancel(); timeout = nil
        continuation?.resume(returning: value); continuation = nil
    }
}

/// Consent and the sole preview are memory-only. Nothing automatically fetches or skips.
@MainActor @Observable
final class SponsorBlockSession {
    private(set) var scope = UUID()
    private(set) var isEnabled = false
    private(set) var isWorking = false
    private(set) var preview: SponsorBlockPreview?
    private(set) var errorMessage: String?
    var isAccountAvailable: Bool { account != nil }
    var isLookupPending: Bool { worker != nil }
    var hasEligiblePlayback: Bool { currentContext() != nil }
    var canLookup: Bool { isEnabled && !isWorking && currentContext() != nil && monotonic() >= nextLookup }
    @ObservationIgnored var currentContext: @MainActor () -> SponsorBlockContext? = { nil }
    @ObservationIgnored var currentPosition: @MainActor () -> TimeInterval = { .nan }
    @ObservationIgnored var performSeek: @MainActor (SponsorBlockContext, SponsorBlockSection) async -> Bool = { _, _ in false }
    @ObservationIgnored private let sessions: any MusicSessionProviding
    @ObservationIgnored private let service: any SponsorBlockProviding
    @ObservationIgnored private let profileNamespace: String
    @ObservationIgnored private let monotonic: @Sendable () -> TimeInterval
    @ObservationIgnored private var account: String?
    @ObservationIgnored private var credentialScope: UUID?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pendingContext: SponsorBlockContext?
    @ObservationIgnored private var nextLookup = -Double.infinity
    @ObservationIgnored private var actions = 0
    @ObservationIgnored private var actionWaiters: [CheckedContinuation<Void, Never>] = []

    init(sessions: any MusicSessionProviding, profileNamespace: String, service: any SponsorBlockProviding,
         monotonic: @escaping @Sendable () -> TimeInterval = PlaybackOutputTime.monotonic) {
        self.sessions = sessions; self.profileNamespace = profileNamespace; self.service = service; self.monotonic = monotonic
    }
    func bindAccount(_ confirmedHash: String?) {
        let next = confirmedHash.flatMap { NamedQueueStore.acceptsAccountKey($0) ? $0 : nil }
        guard account != next else { return }
        disable(); account = next; errorMessage = nil
    }
    func enable(expectedScope: UUID) async {
        guard scope == expectedScope, !isEnabled, !isWorking, let account,
              !profileNamespace.isEmpty, profileNamespace.utf8.count <= 256 else { return }
        actions += 1; isWorking = true
        defer { finishAction() }
        let session = await sessions.snapshot()
        guard scope == expectedScope, self.account == account, !Task.isCancelled,
              session.isAuthenticated, session.accountID == account else { return }
        credentialScope = session.scope; isEnabled = true; errorMessage = nil
    }
    func disable() { interrupt(); isEnabled = false; credentialScope = nil }
    func quiesce() { bindAccount(nil) }
    func interrupt() {
        scope = UUID(); preview = nil; pendingContext = nil
        worker?.cancel()
        // Keep the handle until its underlying read settles; cancellation cannot create another slot.
    }
    func playbackChanged() {
        if let preview, preview.expires <= monotonic() { interrupt(); return }
        guard let expected = pendingContext ?? preview?.context else { return }
        if currentContext() != expected { interrupt() }
    }
    func lookup() {
        guard canLookup, let account, let credentialScope, let context = currentContext() else { return }
        let instant = monotonic()
        guard instant.isFinite else { return }
        let expected = scope
        nextLookup = instant + 30; pendingContext = context; preview = nil; errorMessage = nil; isWorking = true
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.pendingContext = nil; self.isWorking = self.actions > 0 }
            do {
                let session = await self.sessions.snapshot()
                guard !Task.isCancelled, self.scope == expected, self.isEnabled, self.currentContext() == context else { return }
                guard session.isAuthenticated, session.accountID == account, session.scope == credentialScope else { self.disable(); return }
                let sections = try await self.service.sections(videoID: context.videoID, duration: context.playback.duration)
                guard !Task.isCancelled, self.scope == expected, self.isEnabled, self.currentContext() == context else { return }
                let fresh = await self.sessions.snapshot()
                guard !Task.isCancelled, self.scope == expected, self.isEnabled, self.currentContext() == context else { return }
                guard fresh.isAuthenticated, fresh.accountID == account, fresh.scope == credentialScope else { self.disable(); return }
                guard sections.count <= 64, sections.allSatisfy({ Self.valid($0, duration: context.playback.duration) }),
                      Set(sections.map(\.id)).count == sections.count else { throw SponsorBlockError.invalidResponse }
                self.preview = SponsorBlockPreview(context: context, sections: sections, expires: self.monotonic() + 300)
            } catch {
                if let failure = error as? SponsorBlockError, case let .cooldown(delay) = failure, delay.isFinite {
                    self.nextLookup = max(self.nextLookup, self.monotonic() + max(30, min(delay, 315_360_000)))
                }
                if self.scope == expected, !Task.isCancelled { self.errorMessage = (error as? SponsorBlockError ?? .unavailable).localizedDescription }
            }
        }
    }
    func canSkip(_ section: SponsorBlockSection, previewID: UUID) -> Bool {
        !isWorking && matchesPreview(section, previewID: previewID)
    }
    private func matchesPreview(_ section: SponsorBlockSection, previewID: UUID) -> Bool {
        guard isEnabled, let preview, preview.id == previewID,
              preview.expires > monotonic(), preview.context == currentContext(),
              preview.sections.contains(section), Self.valid(section, duration: preview.context.playback.duration) else { return false }
        let position = currentPosition()
        return position.isFinite && position >= section.start && position < section.end
    }
    @discardableResult func skip(_ section: SponsorBlockSection, previewID: UUID) async -> Bool {
        guard canSkip(section, previewID: previewID), let preview, let account, let credentialScope else { return false }
        let expected = scope
        actions += 1; isWorking = true
        defer { finishAction() }
        let session = await sessions.snapshot()
        guard scope == expected, !Task.isCancelled, matchesPreview(section, previewID: previewID) else { return false }
        guard session.isAuthenticated, session.accountID == account, session.scope == credentialScope else { disable(); return false }
        self.preview = nil
        let accepted = await performSeek(preview.context, section)
        guard scope == expected, isEnabled, !Task.isCancelled else { return false }
        if !accepted { errorMessage = SponsorBlockText.text("The section skip was not confirmed. Playback may have changed; review a fresh preview.") }
        return accepted
    }
    func waitForIdle() async {
        if actions > 0 { await withCheckedContinuation { actionWaiters.append($0) } }
        await worker?.value
    }
    func stop() async { disable(); await waitForIdle() }
    private func finishAction() {
        actions -= 1; isWorking = actions > 0 || worker != nil
        if actions == 0 { let waiting = actionWaiters; actionWaiters = []; waiting.forEach { $0.resume() } }
    }
    private static func valid(_ section: SponsorBlockSection, duration: TimeInterval) -> Bool {
        section.id.utf8.count == 64 && section.id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
            duration.isFinite && duration > 0 && duration <= 43_200 && section.start.isFinite && section.end.isFinite &&
            section.start >= 0 && section.start < section.end && section.end < duration
    }
}
