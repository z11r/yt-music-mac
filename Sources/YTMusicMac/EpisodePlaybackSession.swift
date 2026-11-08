import Foundation
import MusicCore
import Observation

@MainActor protocol EpisodeRateControlling: AnyObject {
    /// True only after the current occurrence's player confirms this exact rate.
    func setEpisodeRate(_ rate: Double, occurrence: PlaybackOccurrence) async -> Bool
    func refreshEpisodeRates(occurrence: PlaybackOccurrence)
}

extension EpisodeRateControlling {
    func refreshEpisodeRates(occurrence: PlaybackOccurrence) {}
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
    private(set) var persistenceEnabled = true
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var settings = EpisodePlaybackSettings()
    private(set) var availableRates: [Double] = []
    private(set) var currentRate: Double?
    private(set) var isRatePending = false
    private(set) var rateMessage: String?
    @ObservationIgnored private var rateRequest = UUID()
    @ObservationIgnored weak var rateController: (any EpisodeRateControlling)?
    @ObservationIgnored private let persistenceGate: LocalPersistenceGate
    @ObservationIgnored private var writeBarrier: Task<Void, Never>?
    @ObservationIgnored private let load: @Sendable (String) async throws -> EpisodeProgressSnapshot?
    @ObservationIgnored private let save: @Sendable (EpisodeProgressSnapshot) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var accountHash: String?
    @ObservationIgnored private var scope = UUID()
    @ObservationIgnored private var ownershipID = UUID()
    @ObservationIgnored private var isProfileSuspended = false
    private var records: [String: EpisodeProgressRecord] = [:]
    @ObservationIgnored private var active: Active?
    @ObservationIgnored private var verifiedOccurrence: PlaybackOccurrence?
    @ObservationIgnored private var writable = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var detachingSave: Task<Bool, Never>?

    convenience init(store: EpisodeProgressStore?, now: @escaping @Sendable () -> Date = { Date() }) {
        let gate = LocalPersistenceGate()
        self.init(load: { hash in
            guard let store else { throw EpisodeProgressError.invalidStorageURL }
            return try await store.load(accountHash: hash)
        }, save: { snapshot in
            guard let store else { throw EpisodeProgressError.invalidStorageURL }
            let token = gate.token
            try await store.save(snapshot, if: { gate.accepts(token) })
        }, now: now, persistenceGate: gate)
    }

    init(load: @escaping @Sendable (String) async throws -> EpisodeProgressSnapshot?,
         save: @escaping @Sendable (EpisodeProgressSnapshot) async throws -> Void,
         now: @escaping @Sendable () -> Date = { Date() }, saveDelay: Duration = .seconds(5),
         persistenceGate: LocalPersistenceGate = LocalPersistenceGate()) {
        self.load = load; self.save = save; self.now = now; self.saveDelay = saveDelay
        self.persistenceGate = persistenceGate
    }

    func setPersistenceEnabled(_ enabled: Bool) {
        guard enabled != persistenceEnabled else { return }
        persistenceEnabled = enabled; persistenceGate.setEnabled(enabled)
        let prior = saveTask; prior?.cancel(); saveTask = nil
        let earlier = writeBarrier
        writeBarrier = Task { await earlier?.value; await prior?.value }
        if enabled {
            let previous = accountHash, memoryRecords = records
            let playback = active, verified = verifiedOccurrence
            let rates = availableRates, rate = currentRate
            accountHash = nil
            _ = bindAccount(previous, merging: memoryRecords)
            active = playback; verifiedOccurrence = verified
            availableRates = rates; currentRate = rate
        } else {
            scope = UUID(); loadTask?.cancel()
            isLoading = false; writable = accountHash != nil; errorMessage = nil
        }
    }

    @discardableResult func bindAccount(_ hash: String?, merging memoryRecords: [String: EpisodeProgressRecord] = [:]) -> Bool {
        let hash = hash.flatMap { EpisodeProgressSnapshot.validAccountHash($0) ? $0 : nil }
        guard hash != accountHash else { return false }
        scope = UUID(); loadTask?.cancel(); saveTask?.cancel(); saveTask = nil
        accountHash = hash; records = [:]; settings = .init(); active = nil; verifiedOccurrence = nil
        availableRates = []; currentRate = nil; rateRequest = UUID(); isRatePending = false; rateMessage = nil; errorMessage = nil; writable = false; isLoading = hash != nil
        guard let hash else { return true }
        guard persistenceEnabled else { isLoading = false; writable = true; return true }
        let expected = scope
        let pendingSave = detachingSave
        let barrier = writeBarrier
        loadTask = Task { [weak self, load] in
            do {
                _ = await pendingSave?.value
                await barrier?.value
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
                for (key, record) in memoryRecords where self.records[key].map({ $0.updatedAt <= record.updatedAt }) ?? true {
                    self.records[key] = record
                }
                self.writable = true; self.isLoading = false
                if !memoryRecords.isEmpty { self.revision += 1; self.scheduleSave() }
            } catch is CancellationError { }
            catch {
                guard let self, self.scope == expected else { return }
                self.isLoading = false
                self.records = memoryRecords
                self.errorMessage = AppLocalization.text("Local episode progress could not be loaded. Existing data has been retained.")
            }
        }
        return true
    }

    func waitUntilLoaded() async { await loadTask?.value }

    func suspendProfileOwnership() {
        isProfileSuspended = true; ownershipID = UUID()
        rateRequest = UUID(); isRatePending = false; rateMessage = nil
        availableRates = []; currentRate = nil; verifiedOccurrence = nil
    }
    func resumeProfileOwnership() { isProfileSuspended = false; ownershipID = UUID() }

    func begin(track: Track, occurrence: PlaybackOccurrence) {
        guard !isProfileSuspended else { return }
        availableRates = []; currentRate = nil; verifiedOccurrence = nil; rateRequest = UUID(); isRatePending = false; rateMessage = nil
        guard track.contentKind == .podcastEpisode, let episode = track.episode?.identity,
              EpisodeProgressSnapshot.validEpisode(episode), occurrence.trackID == track.id else { active = nil; return }
        active = Active(episode: episode, occurrence: occurrence)
    }
    func clearPlayback() { active = nil; verifiedOccurrence = nil; availableRates = []; currentRate = nil; rateRequest = UUID(); isRatePending = false; rateMessage = nil }

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
        guard !isProfileSuspended, confirmedContent, var active,
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
        guard !isProfileSuspended, writable, let episode = track.episode?.identity else { return }
        records[episode.key] = nil
        if active?.episode.key == episode.key { active?.protectsBookmark = false }
        revision += 1; scheduleSave()
    }

    func setSkipIntervals(backward: TimeInterval, forward: TimeInterval) {
        guard !isProfileSuspended, writable, [backward, forward].allSatisfy({ $0.isFinite && (5...120).contains($0) }) else { return }
        settings = .init(skipBackward: backward, skipForward: forward); revision += 1; scheduleSave()
    }

    var canControlRate: Bool { !isProfileSuspended && rateController != nil && active?.occurrence == verifiedOccurrence && !availableRates.isEmpty && !isRatePending }
    var canRefreshRate: Bool { !isProfileSuspended && rateController != nil && active != nil && active?.occurrence == verifiedOccurrence && !isRatePending }
    func refreshRates() {
        guard canRefreshRate, let active else { return }
        rateController?.refreshEpisodeRates(occurrence: active.occurrence)
    }
    func clearRates(occurrence: PlaybackOccurrence) {
        guard !isProfileSuspended, active?.occurrence == occurrence, verifiedOccurrence == occurrence else { return }
        availableRates = []; currentRate = nil
        rateMessage = AppLocalization.text("Playback speed is unavailable for the current episode.")
    }
    func reportRates(_ rates: [Double], current: Double, occurrence: PlaybackOccurrence) {
        guard !isProfileSuspended, active?.occurrence == occurrence, verifiedOccurrence == occurrence else { return }
        guard rates.count <= 16, rates.allSatisfy({ $0.isFinite && (0.25...4).contains($0) }), rates.contains(current) else {
            availableRates = []; currentRate = nil; return
        }
        availableRates = Array(Set(rates)).sorted(); currentRate = current; rateMessage = nil
    }
    @discardableResult func setRate(_ rate: Double, expectedOccurrence: PlaybackOccurrence? = nil) async -> Bool {
        guard !isProfileSuspended, canControlRate, availableRates.contains(rate), let active, let rateController,
              expectedOccurrence == nil || expectedOccurrence == active.occurrence else { return false }
        let expected = scope, owner = ownershipID
        let request = UUID(); rateRequest = request; isRatePending = true; rateMessage = nil
        let confirmed = await rateController.setEpisodeRate(rate, occurrence: active.occurrence)
        guard !isProfileSuspended, ownershipID == owner, scope == expected, rateRequest == request, self.active?.occurrence == active.occurrence,
              verifiedOccurrence == active.occurrence else { return false }
        isRatePending = false
        guard confirmed else {
            rateMessage = AppLocalization.text("The episode speed change was not confirmed. Refresh available speeds to try again.")
            return false
        }
        currentRate = rate
        return true
    }

    @discardableResult func flush() async -> Bool {
        let expected = scope
        let prior = saveTask; prior?.cancel(); saveTask = nil
        await prior?.value
        await writeBarrier?.value
        guard persistenceEnabled, expected == scope, writable, let snapshot = snapshot() else { return false }
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
        let snapshot = persistenceEnabled && writable ? snapshot() : nil
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
        guard persistenceEnabled, saveTask == nil else { return }
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
