import Foundation
import MusicCore
import Observation
import YouTubeMusic

/// Session-only consent; saved target receipts stay inside the injected profile's preferences.
@MainActor @Observable
final class StreamingMetadataExport {
    private(set) var scope = UUID()
    private(set) var isEnabled = false
    private(set) var isWorking = false
    private(set) var receipt: StreamingExportReceipt?
    private(set) var errorMessage: String?
    private(set) var settingsBlocked = false
    var isAccountAvailable: Bool { owner != nil }
    @ObservationIgnored private let settings: StreamingExportSettings
    @ObservationIgnored private let sessions: any MusicSessionProviding
    @ObservationIgnored private let writer: any StreamingMetadataWriting
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let monotonic: @Sendable () -> TimeInterval
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let gate = PlaybackOutputGate()
    @ObservationIgnored private var owner: String?
    @ObservationIgnored private var credentialScope: UUID?
    @ObservationIgnored private var permit: PlaybackOutputGate.Permit?
    @ObservationIgnored private var possibleOutput = false
    @ObservationIgnored private var lastOccurrence: PlaybackOccurrence?
    @ObservationIgnored private var lastPublished = -Double.infinity
    @ObservationIgnored private var deadline: TimeInterval?
    @ObservationIgnored private var pending: Publication?
    @ObservationIgnored private var clears: [UUID: Clear] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var configurations = 0
    @ObservationIgnored private var configurationWaiters: [CheckedContinuation<Void, Never>] = []
    private struct Publication {
        let metadata: PublicPlaybackMetadata
        let receipt: StreamingExportReceipt
        let account: String
        let credentialScope: UUID
        let scope: UUID
        let permit: PlaybackOutputGate.Permit
        let date: Date
    }
    private struct Clear {
        let receipt: StreamingExportReceipt
        let account: String
        let revision: UInt64
    }

    init(preferences: UserDefaults, profileNamespace: String, sessions: any MusicSessionProviding,
         writer: any StreamingMetadataWriting = StreamingExportFile(), now: @escaping @Sendable () -> Date = Date.init,
         monotonic: @escaping @Sendable () -> TimeInterval = PlaybackOutputTime.monotonic,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        settings = StreamingExportSettings(preferences: preferences, profileNamespace: profileNamespace)
        self.sessions = sessions; self.writer = writer; self.now = now; self.monotonic = monotonic; self.sleep = sleep
    }

    func bindAccount(_ confirmedHash: String?) {
        let next = confirmedHash.flatMap { NamedQueueStore.acceptsAccountKey($0) ? $0 : nil }
        guard owner != next else { return }
        disable()
        scope = UUID(); receipt = nil; errorMessage = nil; settingsBlocked = false; credentialScope = nil
        owner = next
        guard let owner else { return }
        do { receipt = try settings.load(account: owner) }
        catch { settingsBlocked = true; errorMessage = StreamingExportError.unsupportedSettings.localizedDescription }
    }

    func configure(url: URL, format: StreamingMetadataFormat, expectedScope: UUID) async {
        guard scope == expectedScope, !isWorking, !isEnabled, receipt == nil, !settingsBlocked, let owner else { return }
        isWorking = true; configurations += 1; errorMessage = nil
        let revision = gate.revoke()
        defer { finishConfiguration() }
        do {
            let session = try await authenticated(owner)
            guard scope == expectedScope else { throw StreamingExportError.revoked }
            let created = try await writer.create(url: url, format: format, now: now(), gate: gate, revision: revision)
            // A known empty target belongs to its original confirmed account, even if the account changed during IO.
            try settings.create(created, account: owner)
            _ = try await authenticated(owner, nonce: session.scope)
            guard scope == expectedScope else { throw StreamingExportError.revoked }
            receipt = created
        } catch { if scope == expectedScope { errorMessage = error.localizedDescription } }
    }

    func enable(expectedScope: UUID) async {
        guard scope == expectedScope, !isWorking, !isEnabled, !settingsBlocked, let owner, let receipt else { return }
        isWorking = true; configurations += 1; errorMessage = nil
        defer { finishConfiguration() }
        let revision = gate.revoke()
        do {
            let session = try await authenticated(owner)
            guard scope == expectedScope else { throw StreamingExportError.revoked }
            let cleared = try await writer.clear(receipt: receipt, now: now(), gate: gate, through: revision)
            try settings.update(cleared, account: owner)
            _ = try await authenticated(owner, nonce: session.scope)
            guard scope == expectedScope else { throw StreamingExportError.revoked }
            self.receipt = cleared; credentialScope = session.scope
            isEnabled = true; permit = gate.activate(target: cleared.id)
        } catch { if scope == expectedScope { errorMessage = error.localizedDescription } }
    }

    func disable() {
        interrupt()
        isEnabled = false; credentialScope = nil; scope = UUID()
    }

    func quiesce() { bindAccount(nil) }
    func resume(confirmedAccountHash: String) { bindAccount(confirmedAccountHash) }

    /// Revoke before any suspension; a delayed public write can no longer pass the gate.
    func interrupt() {
        let revision = gate.revoke()
        permit = nil; pending = nil; deadline = nil; lastPublished = -Double.infinity; lastOccurrence = nil
        watchdog?.cancel(); watchdog = nil
        if possibleOutput, let receipt, let owner {
            clears[receipt.id] = Clear(receipt: receipt, account: owner, revision: revision)
            possibleOutput = false
            drain()
        }
    }

    /// Only verified actual content progress may call this; ad/loading clocks never publish metadata.
    func sample(track: Track, occurrence: PlaybackOccurrence, ended: Bool) {
        guard isEnabled, !settingsBlocked, let owner, let credentialScope, let receipt else { return }
        guard !ended, occurrence.trackID == track.id, let metadata = PublicPlaybackMetadata(track: track) else { interrupt(); return }
        let instant = monotonic(); let date = now()
        guard instant.isFinite, date.timeIntervalSinceReferenceDate.isFinite else { interrupt(); return }
        if let lastOccurrence, lastOccurrence != occurrence { interrupt() }
        lastOccurrence = occurrence; deadline = instant + 15
        if permit == nil { permit = gate.activate(target: receipt.id) }
        startWatchdog()
        guard instant - lastPublished >= 5, let permit else { return }
        lastPublished = instant
        pending = Publication(metadata: metadata, receipt: receipt, account: owner, credentialScope: credentialScope,
            scope: scope, permit: permit, date: date)
        possibleOutput = true
        drain()
    }

    func forgetTarget(expectedScope: UUID) async {
        guard scope == expectedScope, !isWorking, let owner else { return }
        disable()
        let clearingScope = scope
        await waitForIdle()
        guard scope == clearingScope, self.owner == owner else { return }
        do {
            _ = try await authenticated(owner)
            guard scope == clearingScope, self.owner == owner else { return }
            try settings.forget(account: owner); receipt = nil; settingsBlocked = false; errorMessage = nil
        } catch { if scope == clearingScope { errorMessage = error.localizedDescription } }
    }

    func waitForIdle() async {
        if configurations > 0 { await withCheckedContinuation { configurationWaiters.append($0) } }
        await worker?.value
    }
    func stop() async {
        let timer = watchdog
        disable(); await waitForIdle(); await timer?.value
    }

    private func finishConfiguration() {
        configurations -= 1
        isWorking = worker != nil || configurations > 0
        if configurations == 0 {
            let waiting = configurationWaiters; configurationWaiters = []
            waiting.forEach { $0.resume() }
        }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let scope = scope
        watchdog = Task { [weak self, sleep] in
            while let self, self.scope == scope, self.isEnabled, let deadline = self.deadline {
                let remaining = deadline - self.monotonic()
                if remaining <= 0 { self.interrupt(); return }
                do { try await sleep(.seconds(min(15, remaining))) } catch { return }
                if Task.isCancelled { return }
            }
        }
    }
    private func drain() {
        guard worker == nil else { return }
        isWorking = true
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let clear = self.clears.values.first {
                    self.clears.removeValue(forKey: clear.receipt.id)
                    do {
                        let saved = try await self.writer.clear(receipt: clear.receipt, now: self.now(), gate: self.gate, through: clear.revision)
                        self.record(saved, account: clear.account)
                    } catch StreamingExportError.revoked { }
                    catch { if self.owner == clear.account { self.errorMessage = error.localizedDescription } }
                    continue
                }
                guard let next = self.pending else { break }
                self.pending = nil
                do {
                    _ = try await self.authenticated(next.account, nonce: next.credentialScope)
                    guard self.scope == next.scope, self.isEnabled else { continue }
                    let document = StreamingMetadataDocument(metadata: next.metadata, now: next.date)
                    let saved = try await self.writer.write(document, receipt: next.receipt, gate: self.gate, permit: next.permit)
                    self.record(saved, account: next.account)
                } catch StreamingExportError.revoked {
                    if self.scope == next.scope, self.isEnabled, self.permit?.revision == next.permit.revision { self.disable() }
                }
                catch {
                    if self.scope == next.scope { self.errorMessage = error.localizedDescription; self.disable() }
                }
            }
            self.worker = nil; self.isWorking = false
        }
    }
    private func record(_ saved: StreamingExportReceipt, account: String) {
        do {
            try settings.update(saved, account: account)
            if owner == account, receipt?.id == saved.id, saved.revision >= (receipt?.revision ?? 0) { receipt = saved }
        } catch { if owner == account { errorMessage = StreamingExportError.unsupportedSettings.localizedDescription } }
    }
    private func authenticated(_ owner: String, nonce: UUID? = nil) async throws -> MusicSession {
        let session = await sessions.snapshot()
        guard !Task.isCancelled, session.isAuthenticated, session.accountID == owner,
              nonce == nil || nonce == session.scope else { throw StreamingExportError.revoked }
        return session
    }
}
