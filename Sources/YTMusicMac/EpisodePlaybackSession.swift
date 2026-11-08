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
    enum LocalStatusAction { case markCompleted, clearProgress }
    struct LocalStatusTarget {
        let episode: EpisodeIdentity
        let canMarkCompleted: Bool
        let canClearProgress: Bool
        fileprivate let duration: TimeInterval?
        fileprivate let account: String
        fileprivate let scope: UUID
        fileprivate let ownership: UUID
        fileprivate let statusScope: UUID
        fileprivate let occurrence: PlaybackOccurrence?
    }
    fileprivate struct Active {
        let episode: EpisodeIdentity
        let occurrence: PlaybackOccurrence
        var protectsBookmark = true
        var manualStatusHold = false
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
    private(set) var statusScope = UUID()
    @ObservationIgnored private var rateRequest = UUID()
    @ObservationIgnored weak var rateController: (any EpisodeRateControlling)?
    @ObservationIgnored private let persistenceGate: LocalPersistenceGate
    @ObservationIgnored private var writeBarrier: Task<Void, Never>?
    @ObservationIgnored private let load: @Sendable (String) async throws -> EpisodeProgressSnapshot?
    @ObservationIgnored private let save: @Sendable (EpisodeProgressSnapshot, UUID) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var accountHash: String?
    @ObservationIgnored private var scope = UUID()
    @ObservationIgnored private var ownershipID = UUID()
    @ObservationIgnored private var isProfileSuspended = false
    private var records: [String: EpisodeProgressRecord] = [:]
    /// A reset remains authoritative until its latest local state is saved;
    /// confirmed playback after the reset may replace the empty record.
    @ObservationIgnored private var clearedEpisodeKeys = Set<String>()
    /// Same-account confirmed samples not yet acknowledged by a matching write.
    /// Their causality survives privacy toggles and does not depend on the clock.
    @ObservationIgnored private var confirmedMemoryKeys = Set<String>()
    @ObservationIgnored private var active: Active?
    @ObservationIgnored private var verifiedOccurrence: PlaybackOccurrence?
    @ObservationIgnored private var writable = false
    @ObservationIgnored private var keepsInMemoryProgress = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var detachingSave: Task<Bool, Never>?

    convenience init(store: EpisodeProgressStore?, now: @escaping @Sendable () -> Date = { Date() }) {
        let gate = LocalPersistenceGate()
        self.init(load: { hash in
            guard let store else { throw EpisodeProgressError.invalidStorageURL }
            return try await store.load(accountHash: hash)
        }, saveWithPermission: { snapshot, permission in
            guard let store else { throw EpisodeProgressError.invalidStorageURL }
            try await store.save(snapshot, if: { gate.accepts(permission) })
        }, now: now, persistenceGate: gate)
    }

    convenience init(load: @escaping @Sendable (String) async throws -> EpisodeProgressSnapshot?,
         save: @escaping @Sendable (EpisodeProgressSnapshot) async throws -> Void,
         now: @escaping @Sendable () -> Date = { Date() }, saveDelay: Duration = .seconds(5),
         persistenceGate: LocalPersistenceGate = LocalPersistenceGate()) {
        self.init(load: load, saveWithPermission: { snapshot, permission in
            guard persistenceGate.accepts(permission) else { throw CancellationError() }
            try await save(snapshot)
        }, now: now, saveDelay: saveDelay, persistenceGate: persistenceGate)
    }

    /// Storage adapters receive the operation's original permission. They must
    /// check it again at their write boundary, after any asynchronous wait.
    init(load: @escaping @Sendable (String) async throws -> EpisodeProgressSnapshot?,
         saveWithPermission: @escaping @Sendable (EpisodeProgressSnapshot, UUID) async throws -> Void,
         now: @escaping @Sendable () -> Date = { Date() }, saveDelay: Duration = .seconds(5),
         persistenceGate: LocalPersistenceGate = LocalPersistenceGate()) {
        self.load = load; self.save = saveWithPermission; self.now = now; self.saveDelay = saveDelay
        self.persistenceGate = persistenceGate
    }

    func setPersistenceEnabled(_ enabled: Bool) {
        guard enabled != persistenceEnabled else { return }
        persistenceEnabled = enabled; persistenceGate.setEnabled(enabled)
        let prior = saveTask; prior?.cancel(); saveTask = nil
        let earlier = writeBarrier, pendingDetach = detachingSave
        writeBarrier = Task { await earlier?.value; await prior?.value; _ = await pendingDetach?.value }
        if enabled {
            let previous = accountHash, memoryRecords = records
            let cleared = clearedEpisodeKeys, confirmed = confirmedMemoryKeys
            let playback = active, verified = verifiedOccurrence
            let rates = availableRates, rate = currentRate
            accountHash = nil
            _ = bindAccount(previous, merging: memoryRecords, keepingInMemoryProgress: true, clearedKeys: cleared, confirmedKeys: confirmed)
            active = playback; verifiedOccurrence = verified
            availableRates = rates; currentRate = rate
        } else {
            scope = UUID(); loadTask?.cancel()
            isLoading = false; writable = accountHash != nil; errorMessage = nil
        }
        statusScope = UUID()
    }

    @discardableResult func bindAccount(_ hash: String?, merging memoryRecords: [String: EpisodeProgressRecord] = [:],
                                        keepingInMemoryProgress: Bool = false, clearedKeys: Set<String> = [], confirmedKeys: Set<String> = []) -> Bool {
        let hash = hash.flatMap { EpisodeProgressSnapshot.validAccountHash($0) ? $0 : nil }
        guard hash != accountHash else { return false }
        scope = UUID(); loadTask?.cancel(); saveTask?.cancel(); saveTask = nil
        statusScope = UUID(); clearedEpisodeKeys = clearedKeys
        confirmedMemoryKeys = confirmedKeys.intersection(memoryRecords.keys)
        accountHash = hash; records = memoryRecords; settings = .init(); active = nil; verifiedOccurrence = nil
        keepsInMemoryProgress = keepingInMemoryProgress
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
                let arrivals = self.records
                var restored: [String: EpisodeProgressRecord] = [:]
                if let snapshot {
                    guard snapshot.accountHash == hash else { throw EpisodeProgressError.invalidSnapshot }
                    restored = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.episode.key, $0) })
                    self.settings = snapshot.settings
                }
                for (key, record) in memoryRecords where record.completionSource == .manual || self.clearedEpisodeKeys.contains(key) || self.confirmedMemoryKeys.contains(key) || (restored[key].map({ $0.updatedAt <= record.updatedAt }) ?? true) {
                    restored[key] = record
                }
                // Confirmed same-account samples remain causal until a matching
                // write acknowledges them, including across a backward clock.
                for (key, record) in arrivals where self.confirmedMemoryKeys.contains(key) || record != memoryRecords[key] ||
                    (restored[key].map({ $0.updatedAt <= record.updatedAt }) ?? true) {
                    restored[key] = record
                }
                for key in self.clearedEpisodeKeys where arrivals[key] == nil { restored[key] = nil }
                self.records = restored
                self.trimRecords()
                self.writable = true; self.isLoading = false
                if !arrivals.isEmpty || !self.clearedEpisodeKeys.isEmpty { self.revision += 1; self.scheduleSave() }
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

    func suspendProfileOwnership() {
        isProfileSuspended = true; ownershipID = UUID()
        statusScope = UUID()
        rateRequest = UUID(); isRatePending = false; rateMessage = nil
        availableRates = []; currentRate = nil; verifiedOccurrence = nil
    }
    func resumeProfileOwnership() { isProfileSuspended = false; ownershipID = UUID(); statusScope = UUID() }

    func begin(track: Track, occurrence: PlaybackOccurrence) {
        guard !isProfileSuspended else { return }
        statusScope = UUID()
        availableRates = []; currentRate = nil; verifiedOccurrence = nil; rateRequest = UUID(); isRatePending = false; rateMessage = nil
        guard track.contentKind == .podcastEpisode, let episode = track.episode?.identity,
              EpisodeProgressSnapshot.validEpisode(episode), occurrence.trackID == track.id else { active = nil; return }
        let hold = active?.occurrence == occurrence && active?.episode.key == episode.key && active?.manualStatusHold == true
        active = Active(episode: episode, occurrence: occurrence, manualStatusHold: hold)
    }
    func clearPlayback() { active = nil; statusScope = UUID(); verifiedOccurrence = nil; availableRates = []; currentRate = nil; rateRequest = UUID(); isRatePending = false; rateMessage = nil }

    func continuationForRebind() -> Continuation? {
        guard let accountHash, let active else { return nil }
        return Continuation(accountHash: accountHash, active: active)
    }

    @discardableResult func restoreContinuation(_ continuation: Continuation) -> Bool {
        guard !isLoading, accountHash == continuation.accountHash, active == nil else { return false }
        active = continuation.active
        statusScope = UUID()
        return true
    }


    func progress(for track: Track) -> EpisodeProgressRecord? {
        track.episode.flatMap { records[$0.identity.key] }
    }

    func localStatusTarget(for track: Track) -> LocalStatusTarget? {
        guard !isProfileSuspended, !isLoading, writable, let accountHash,
              track.origin != .upload, track.contentKind == .podcastEpisode, let episode = track.episode?.identity,
              EpisodeProgressSnapshot.validEpisode(episode) else { return nil }
        let prior = records[episode.key]
        let duration = (prior?.duration ?? track.duration).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return .init(episode: episode, canMarkCompleted: duration != nil && prior?.completed != true,
            canClearProgress: prior != nil, duration: duration, account: accountHash, scope: scope,
            ownership: ownershipID, statusScope: statusScope, occurrence: active?.occurrence)
    }

    @discardableResult
    func changeLocalStatus(_ action: LocalStatusAction, target: LocalStatusTarget) -> Bool {
        guard !isProfileSuspended, !isLoading, writable, accountHash == target.account, scope == target.scope,
              ownershipID == target.ownership, statusScope == target.statusScope, active?.occurrence == target.occurrence else { return false }
        let key = target.episode.key
        switch action {
        case .markCompleted:
            // A newer confirmed sample may have corrected a renderer's duration
            // since the menu opened. Keep the current measured pair together.
            guard target.canMarkCompleted, records[key]?.completed != true,
                  let duration = records[key]?.duration ?? target.duration else { return false }
            records[key] = .init(episode: target.episode, position: records[key]?.position ?? 0,
                duration: duration, completed: true, updatedAt: now(), completionSource: .manual)
            clearedEpisodeKeys.remove(key); confirmedMemoryKeys.remove(key)
            trimRecords(keeping: [key])
        case .clearProgress:
            guard target.canClearProgress, records[key] != nil, rememberClear(key) else { return false }
            records[key] = nil; confirmedMemoryKeys.remove(key)
        }
        if active?.episode.key == target.episode.key { active?.manualStatusHold = true }
        statusScope = UUID(); revision += 1; scheduleSave()
        return true
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
        guard (writable || keepsInMemoryProgress), accountHash != nil else { return }
        guard !active.manualStatusHold else { return }
        if active.protectsBookmark, let prior = records[active.episode.key], !prior.completed,
           position < prior.position - 0.5 { return }
        active.protectsBookmark = false; self.active = active
        records[active.episode.key] = EpisodeProgressRecord(episode: active.episode, position: min(position, duration),
            duration: duration, completed: ended, updatedAt: now())
        confirmedMemoryKeys.insert(active.episode.key)
        trimRecords(keeping: [active.episode.key])
        revision += 1; scheduleSave()
    }

    func allowExplicitSeek() { active?.protectsBookmark = false; active?.manualStatusHold = false; statusScope = UUID() }
    @discardableResult func startOver(_ track: Track) -> Bool {
        guard !isProfileSuspended, writable, track.origin != .upload, track.contentKind == .podcastEpisode,
              let episode = track.episode?.identity, EpisodeProgressSnapshot.validEpisode(episode) else { return false }
        guard rememberClear(episode.key, evenWithoutRecord: true) else { return false }
        records[episode.key] = nil; confirmedMemoryKeys.remove(episode.key)
        if active?.episode.key == episode.key { active?.protectsBookmark = false; active?.manualStatusHold = false }
        statusScope = UUID()
        revision += 1; scheduleSave()
        return true
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
        let expected = scope, permission = persistenceGate.token
        let pendingDetach = detachingSave
        let prior = saveTask; prior?.cancel(); saveTask = nil
        await prior?.value
        _ = await pendingDetach?.value
        await writeBarrier?.value
        guard persistenceEnabled, persistenceGate.accepts(permission), expected == scope, writable, let snapshot = snapshot() else { return false }
        let cleared = clearedEpisodeKeys, confirmed = confirmedMemoryKeys
        do {
            try await save(snapshot, permission)
            guard expected == scope else { return false }
            acknowledge(snapshot, cleared: cleared, confirmed: confirmed)
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
        let permission = persistenceGate.token
        let prior = saveTask
        bindAccount(nil)
        guard let snapshot else { return detachingSave }
        let earlier = detachingSave
        let task = Task { [save, persistenceGate] in
            _ = await earlier?.value
            await prior?.value
            do {
                guard persistenceGate.accepts(permission) else { throw CancellationError() }
                try await save(snapshot, permission)
                return true
            }
            catch { return false }
        }
        detachingSave = task
        return task
    }

    private func snapshot() -> EpisodeProgressSnapshot? {
        accountHash.map { EpisodeProgressSnapshot(accountHash: $0, records: records.values.sorted { $0.episode.key < $1.episode.key }, settings: settings) }
    }
    private func rememberClear(_ key: String, evenWithoutRecord: Bool = false) -> Bool {
        guard evenWithoutRecord || records[key] != nil else { return true }
        guard clearedEpisodeKeys.contains(key) || clearedEpisodeKeys.count < 2_000 else {
            errorMessage = AppLocalization.text("Local episode changes have reached their limit. Save the pending changes before clearing more progress.")
            return false
        }
        clearedEpisodeKeys.insert(key)
        return true
    }
    private func trimRecords(keeping: Set<String> = []) {
        guard records.count > 2_000 else { return }
        func priority(_ record: EpisodeProgressRecord) -> Int {
            if keeping.contains(record.episode.key) { return 3 }
            if confirmedMemoryKeys.contains(record.episode.key) { return 2 }
            if record.completionSource == .manual || clearedEpisodeKeys.contains(record.episode.key) { return 1 }
            return 0
        }
        let ordered = records.values.sorted {
            let left = priority($0), right = priority($1)
            if left != right { return left < right }
            return $0.updatedAt == $1.updatedAt ? $0.episode.key < $1.episode.key : $0.updatedAt < $1.updatedAt
        }
        for removed in ordered.prefix(records.count - 2_000) {
            records[removed.episode.key] = nil; confirmedMemoryKeys.remove(removed.episode.key)
        }
    }
    private func acknowledge(_ snapshot: EpisodeProgressSnapshot, cleared: Set<String>, confirmed: Set<String>) {
        let written = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.episode.key, $0) })
        // A completed older write cannot acknowledge newer local intent.
        clearedEpisodeKeys.subtract(cleared.filter { records[$0] == written[$0] })
        confirmedMemoryKeys.subtract(confirmed.filter { records[$0] == written[$0] })
    }
    private func scheduleSave() {
        guard persistenceEnabled, writable, !isLoading, saveTask == nil else { return }
        let expected = scope, permission = persistenceGate.token
        saveTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await Task.sleep(for: self.saveDelay)
                try Task.checkCancellation()
                guard self.scope == expected, self.persistenceGate.accepts(permission), let snapshot = self.snapshot() else { return }
                let revision = self.revision
                let cleared = self.clearedEpisodeKeys, confirmed = self.confirmedMemoryKeys
                try await self.save(snapshot, permission)
                guard self.scope == expected else { return }
                self.acknowledge(snapshot, cleared: cleared, confirmed: confirmed)
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
