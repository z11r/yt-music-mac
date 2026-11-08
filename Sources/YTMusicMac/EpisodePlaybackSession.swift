import Foundation
import MusicCore
import Observation

@MainActor protocol EpisodeRateControlling: AnyObject {
    /// True only after the current occurrence's player confirms this exact rate.
    func setEpisodeRate(_ rate: Double, occurrence: PlaybackOccurrence) async -> Bool
}

@MainActor @Observable
final class EpisodePlaybackSession {
    fileprivate struct Active {
        let episode: EpisodeIdentity
        let occurrence: PlaybackOccurrence
        var protectsBookmark = true
    }
    struct Continuation {
        fileprivate let accountHash: String
        fileprivate let active: Active
        var occurrence: PlaybackOccurrence { active.occurrence }
        var episodeKey: String { active.episode.key }
    }
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var settings = EpisodePlaybackSettings()
    private(set) var availableRates: [Double] = []
    private(set) var currentRate: Double?
    @ObservationIgnored weak var rateController: (any EpisodeRateControlling)?
    @ObservationIgnored private let load: @Sendable (String) async throws -> EpisodeProgressSnapshot?
    @ObservationIgnored private let save: @Sendable (EpisodeProgressSnapshot) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var accountHash: String?
    @ObservationIgnored private var scope = UUID()
    private var records: [String: EpisodeProgressRecord] = [:]
    @ObservationIgnored private var active: Active?
    @ObservationIgnored private var verifiedOccurrence: PlaybackOccurrence?
    @ObservationIgnored private var writable = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var detachingSave: Task<Bool, Never>?

    convenience init(store: EpisodeProgressStore?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(load: { hash in
            guard let store else { throw EpisodeProgressError.invalidStorageURL }
            return try await store.load(accountHash: hash)
        }, save: { snapshot in
            guard let store else { throw EpisodeProgressError.invalidStorageURL }
            try await store.save(snapshot)
        }, now: now)
    }

    init(load: @escaping @Sendable (String) async throws -> EpisodeProgressSnapshot?,
         save: @escaping @Sendable (EpisodeProgressSnapshot) async throws -> Void,
         now: @escaping @Sendable () -> Date = { Date() }, saveDelay: Duration = .seconds(5)) {
        self.load = load; self.save = save; self.now = now; self.saveDelay = saveDelay
    }

    @discardableResult func bindAccount(_ hash: String?) -> Bool {
        let hash = hash.flatMap { EpisodeProgressSnapshot.validAccountHash($0) ? $0 : nil }
        guard hash != accountHash else { return false }
        scope = UUID(); loadTask?.cancel(); saveTask?.cancel(); saveTask = nil
        accountHash = hash; records = [:]; settings = .init(); active = nil; verifiedOccurrence = nil
        availableRates = []; currentRate = nil; errorMessage = nil; writable = false; isLoading = hash != nil
        guard let hash else { return true }
        let expected = scope
        let pendingSave = detachingSave
        loadTask = Task { [weak self, load] in
            do {
                _ = await pendingSave?.value
                try Task.checkCancellation()
                let snapshot = try await load(hash)
                try Task.checkCancellation()
                try snapshot?.validate()
                guard let self, self.scope == expected else { return }
                if let snapshot {
                    guard snapshot.accountHash == hash else { throw EpisodeProgressError.invalidSnapshot }
                    self.records = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.episode.key, $0) })
                    self.settings = snapshot.settings
                }
                self.writable = true; self.isLoading = false
            } catch is CancellationError { }
            catch {
                guard let self, self.scope == expected else { return }
                self.isLoading = false
                self.errorMessage = AppLocalization.text("Local episode progress could not be loaded. Existing data has been retained.")
            }
        }
        return true
    }

    func waitUntilLoaded() async { await loadTask?.value }

    func begin(track: Track, occurrence: PlaybackOccurrence) {
        availableRates = []; currentRate = nil; verifiedOccurrence = nil
        guard track.contentKind == .podcastEpisode, let episode = track.episode?.identity,
              EpisodeProgressSnapshot.validEpisode(episode), occurrence.trackID == track.id else { active = nil; return }
        active = Active(episode: episode, occurrence: occurrence)
    }
    func clearPlayback() { active = nil; verifiedOccurrence = nil; availableRates = []; currentRate = nil }

    func continuationForRebind() -> Continuation? {
        guard let accountHash, let active else { return nil }
        return Continuation(accountHash: accountHash, active: active)
    }

    @discardableResult func restoreContinuation(_ continuation: Continuation) -> Bool {
        guard !isLoading, accountHash == continuation.accountHash, active == nil else { return false }
        active = continuation.active
        return true
    }


    func progress(for track: Track) -> EpisodeProgressRecord? {
        track.episode.flatMap { records[$0.identity.key] }
    }
    func resumePosition(for track: Track) -> TimeInterval {
        guard let record = progress(for: track), !record.completed else { return 0 }
        return track.duration.map { min(record.position, max(0, $0 - 1)) } ?? record.position
    }

    func record(occurrence: PlaybackOccurrence, position: TimeInterval, duration: TimeInterval,
                confirmedContent: Bool, ended: Bool = false) {
        guard confirmedContent, var active,
              active.occurrence == occurrence, position.isFinite, position > 0, duration.isFinite, duration > 0,
              position <= duration + 2 else { return }
        verifiedOccurrence = occurrence
        guard !isLoading, writable, accountHash != nil else { return }
        if active.protectsBookmark, let prior = records[active.episode.key], !prior.completed,
           position < prior.position - 0.5 { return }
        active.protectsBookmark = false; self.active = active
        records[active.episode.key] = EpisodeProgressRecord(episode: active.episode, position: min(position, duration),
            duration: duration, completed: ended, updatedAt: now())
        if records.count > 2_000 {
            let oldest = records.values.sorted { $0.updatedAt == $1.updatedAt ? $0.episode.key < $1.episode.key : $0.updatedAt < $1.updatedAt }.first
            if let oldest { records[oldest.episode.key] = nil }
        }
        revision += 1; scheduleSave()
    }

    func allowExplicitSeek() { active?.protectsBookmark = false }
    func startOver(_ track: Track) {
        guard writable, let episode = track.episode?.identity else { return }
        records[episode.key] = nil
        if active?.episode.key == episode.key { active?.protectsBookmark = false }
        revision += 1; scheduleSave()
    }

    func setSkipIntervals(backward: TimeInterval, forward: TimeInterval) {
        guard writable, [backward, forward].allSatisfy({ $0.isFinite && (5...120).contains($0) }) else { return }
        settings = .init(skipBackward: backward, skipForward: forward); revision += 1; scheduleSave()
    }

    var canControlRate: Bool { rateController != nil && active?.occurrence == verifiedOccurrence && !availableRates.isEmpty }
    func reportRates(_ rates: [Double], current: Double, occurrence: PlaybackOccurrence) {
        guard active?.occurrence == occurrence, verifiedOccurrence == occurrence else { return }
        guard rates.count <= 16, rates.allSatisfy({ $0.isFinite && (0.25...4).contains($0) }), rates.contains(current) else {
            availableRates = []; currentRate = nil; return
        }
        availableRates = Array(Set(rates)).sorted(); currentRate = current
    }
    @discardableResult func setRate(_ rate: Double, expectedOccurrence: PlaybackOccurrence? = nil) async -> Bool {
        guard canControlRate, availableRates.contains(rate), let active, let rateController,
              expectedOccurrence == nil || expectedOccurrence == active.occurrence else { return false }
        let expected = scope
        let confirmed = await rateController.setEpisodeRate(rate, occurrence: active.occurrence)
        guard confirmed, scope == expected, self.active?.occurrence == active.occurrence,
              verifiedOccurrence == active.occurrence else { return false }
        currentRate = rate
        return true
    }

    @discardableResult func flush() async -> Bool {
        let expected = scope
        let prior = saveTask; prior?.cancel(); saveTask = nil
        await prior?.value
        guard expected == scope, writable, let snapshot = snapshot() else { return false }
        do {
            try await save(snapshot)
            guard expected == scope else { return false }
            errorMessage = nil
            return true
        }
        catch {
            guard expected == scope else { return false }
            errorMessage = AppLocalization.text("Local episode progress could not be saved.")
            return false
        }
    }

    /// Fence immediately, then finish writing only the captured old account's
    /// confirmed data. A later account cannot change this task's destination.
    func detachAccount() -> Task<Bool, Never>? {
        let snapshot = writable ? snapshot() : nil
        let prior = saveTask
        bindAccount(nil)
        guard let snapshot else { return detachingSave }
        let earlier = detachingSave
        let task = Task { [save] in
            _ = await earlier?.value
            await prior?.value
            do { try await save(snapshot); return true }
            catch { return false }
        }
        detachingSave = task
        return task
    }

    private func snapshot() -> EpisodeProgressSnapshot? {
        accountHash.map { EpisodeProgressSnapshot(accountHash: $0, records: records.values.sorted { $0.episode.key < $1.episode.key }, settings: settings) }
    }
    private func scheduleSave() {
        guard saveTask == nil else { return }
        let expected = scope
        saveTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await Task.sleep(for: self.saveDelay)
                try Task.checkCancellation()
                guard self.scope == expected, let snapshot = self.snapshot() else { return }
                let revision = self.revision
                try await self.save(snapshot)
                guard self.scope == expected else { return }
                self.saveTask = nil; self.errorMessage = nil
                if self.revision != revision { self.scheduleSave() }
            } catch is CancellationError { }
            catch {
                guard let self, self.scope == expected else { return }
                self.saveTask = nil; self.errorMessage = AppLocalization.text("Local episode progress could not be saved.")
            }
        }
    }
}

enum EpisodeSkip {
    static func target(track: Track, position: TimeInterval, duration: TimeInterval, offset: TimeInterval,
                       positionConfirmed: Bool) -> TimeInterval? {
        guard track.contentKind == .podcastEpisode, track.episode != nil, positionConfirmed,
              position.isFinite, position >= 0, duration.isFinite, duration > 0,
              offset.isFinite, (5...120).contains(abs(offset)) else { return nil }
        return min(duration, max(0, position + offset))
    }
}
