import Foundation
import MusicCore
import Observation
import YouTubeMusic

@MainActor @Observable
final class DiscordPresenceSession {
    private(set) var scope = UUID()
    private(set) var applicationID: String?
    private(set) var isEnabled = false
    private(set) var isWorking = false
    private(set) var settingsBlocked = false
    private(set) var errorMessage: String?
    var isAccountAvailable: Bool { account != nil }
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let profileNamespace: String
    @ObservationIgnored private let sessions: any MusicSessionProviding
    @ObservationIgnored private let service: any DiscordPresenceProviding
    @ObservationIgnored private let monotonic: @Sendable () -> TimeInterval
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var account: String?
    @ObservationIgnored private var credentialScope: UUID?
    @ObservationIgnored private var lease: DiscordPresenceLease?
    @ObservationIgnored private var pending: Publication?
    @ObservationIgnored private var clears: [UUID: (lease: DiscordPresenceLease, account: String?)] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var deadline: TimeInterval?
    @ObservationIgnored private var lastPublished = -Double.infinity
    @ObservationIgnored private var occurrence: PlaybackOccurrence?
    @ObservationIgnored private var configurations = 0
    @ObservationIgnored private var configurationWaiters: [CheckedContinuation<Void, Never>] = []
    private struct Publication {
        let metadata: PublicPlaybackMetadata
        let applicationID: String
        let account: String
        let credentialScope: UUID
        let scope: UUID
        let lease: DiscordPresenceLease
    }
    private struct Settings: Codable {
        let version: Int
        let profileNamespace: String
        let account: String
        let applicationID: String
    }

    init(preferences: UserDefaults, profileNamespace: String, sessions: any MusicSessionProviding,
         service: any DiscordPresenceProviding, monotonic: @escaping @Sendable () -> TimeInterval = PlaybackOutputTime.monotonic,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.preferences = preferences; self.profileNamespace = profileNamespace; self.sessions = sessions
        self.service = service; self.monotonic = monotonic; self.sleep = sleep
    }
    func bindAccount(_ confirmedHash: String?) {
        let next = confirmedHash.flatMap { NamedQueueStore.acceptsAccountKey($0) ? $0 : nil }
        guard next != account else { return }
        disable(); account = next; applicationID = nil; settingsBlocked = false; errorMessage = nil
        guard let next else { return }
        do { applicationID = try load(account: next) }
        catch { settingsBlocked = true; errorMessage = DiscordPresenceError.invalidSettings.localizedDescription }
    }
    func quiesce() { bindAccount(nil) }
    func resume(confirmedAccountHash: String) { bindAccount(confirmedAccountHash) }

    func configure(applicationID: String, expectedScope: UUID) async {
        guard scope == expectedScope, !isEnabled, !isWorking, !settingsBlocked, let account else { return }
        let value = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DiscordIPCPolicy.acceptsApplicationID(value) else { errorMessage = DiscordPresenceError.invalidApplicationID.localizedDescription; return }
        isWorking = true; configurations += 1
        defer { finishConfiguration() }
        do {
            _ = try await authenticated(account)
            guard scope == expectedScope else { return }
            // Reload before replacing so a future or foreign configuration cannot be overwritten.
            _ = try load(account: account)
            let data = try JSONEncoder().encode(Settings(version: 1, profileNamespace: profileNamespace, account: account, applicationID: value))
            guard data.count <= 4_096 else { throw DiscordPresenceError.invalidSettings }
            preferences.set(data, forKey: try key(account))
            self.applicationID = value; errorMessage = nil
        } catch {
            if scope == expectedScope {
                if error as? DiscordPresenceError == .invalidSettings { settingsBlocked = true }
                errorMessage = error.localizedDescription
            }
        }
    }
    func enable(expectedScope: UUID) async {
        guard scope == expectedScope, !isEnabled, !isWorking, !settingsBlocked, let applicationID,
              DiscordIPCPolicy.acceptsApplicationID(applicationID), let account else { return }
        isWorking = true; configurations += 1
        defer { finishConfiguration() }
        do {
            let session = try await authenticated(account)
            guard scope == expectedScope else { return }
            guard try load(account: account) == applicationID else { throw DiscordPresenceError.invalidSettings }
            credentialScope = session.scope; isEnabled = true; errorMessage = nil
            // Connection starts only after a new verified eligible content sample.
        } catch {
            if scope == expectedScope {
                if error as? DiscordPresenceError == .invalidSettings { settingsBlocked = true }
                errorMessage = error.localizedDescription
            }
        }
    }
    func disable() { interrupt(); isEnabled = false; credentialScope = nil; scope = UUID() }
    func interrupt() {
        if let lease { lease.revoke(); clears[lease.id] = (lease, account) }
        lease = nil; pending = nil; occurrence = nil; deadline = nil; lastPublished = -Double.infinity
        watchdog?.cancel(); watchdog = nil
        if !clears.isEmpty { drain() }
    }
    func sample(track: Track, occurrence: PlaybackOccurrence, ended: Bool) {
        guard isEnabled, let account, let credentialScope, let applicationID else { return }
        guard !ended, track.id == occurrence.trackID, let metadata = PublicPlaybackMetadata(track: track),
              metadata.title.utf8.count <= 128, metadata.artist.utf8.count <= 128 else { interrupt(); return }
        let now = monotonic()
        guard now.isFinite else { interrupt(); return }
        if let previous = self.occurrence, previous != occurrence { interrupt() }
        self.occurrence = occurrence; deadline = now + 15
        if lease == nil { lease = DiscordPresenceLease() }
        startWatchdog()
        guard now - lastPublished >= 15, let lease else { return }
        lastPublished = now
        pending = Publication(metadata: metadata, applicationID: applicationID, account: account,
            credentialScope: credentialScope, scope: scope, lease: lease)
        drain()
    }
    func forgetConfiguration(expectedScope: UUID) async {
        guard scope == expectedScope, !isWorking, let account else { return }
        disable(); let clearingScope = scope
        await waitForIdle()
        do {
            _ = try await authenticated(account)
            guard scope == clearingScope, self.account == account else { return }
            preferences.removeObject(forKey: try key(account))
            applicationID = nil; settingsBlocked = false; errorMessage = nil
        } catch { if scope == clearingScope { errorMessage = error.localizedDescription } }
    }
    func waitForIdle() async {
        if configurations > 0 { await withCheckedContinuation { configurationWaiters.append($0) } }
        await worker?.value
    }
    func stop() async { let timer = watchdog; disable(); await waitForIdle(); await timer?.value }

    private func finishConfiguration() {
        configurations -= 1; isWorking = configurations > 0 || worker != nil
        if configurations == 0 { let waiting = configurationWaiters; configurationWaiters = []; waiting.forEach { $0.resume() } }
    }
    private func drain() {
        guard worker == nil else { return }
        isWorking = true
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let clearing = self.clears.values.first {
                    self.clears.removeValue(forKey: clearing.lease.id)
                    let result = await self.service.clear(lease: clearing.lease)
                    if result == .unconfirmed, self.account == clearing.account { self.errorMessage = DiscordPresenceText.text("Discord did not confirm clearing. The local connection was closed; review your Discord activity manually.") }
                    continue
                }
                guard let next = self.pending else { break }
                self.pending = nil
                do {
                    _ = try await self.authenticated(next.account, nonce: next.credentialScope)
                    guard self.scope == next.scope, self.isEnabled, next.lease.isActive else { continue }
                    try await self.service.publish(next.metadata, applicationID: next.applicationID, lease: next.lease)
                } catch {
                    if self.scope == next.scope, self.isEnabled, next.lease.isActive {
                        self.errorMessage = (error as? DiscordPresenceError ?? .unavailable).localizedDescription
                        self.disable()
                    }
                }
            }
            self.worker = nil; self.isWorking = self.configurations > 0
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
    private func authenticated(_ owner: String, nonce: UUID? = nil) async throws -> MusicSession {
        let session = await sessions.snapshot()
        guard !Task.isCancelled, session.isAuthenticated, session.accountID == owner,
              nonce == nil || nonce == session.scope else { throw DiscordPresenceError.revoked }
        return session
    }
    private func key(_ account: String) throws -> String {
        guard NamedQueueStore.acceptsAccountKey(account), !profileNamespace.isEmpty, profileNamespace.utf8.count <= 256 else { throw DiscordPresenceError.invalidSettings }
        return "discordPresenceApplication.v1." + account
    }
    private func load(account: String) throws -> String? {
        guard let object = preferences.object(forKey: try key(account)) else { return nil }
        guard let data = object as? Data, data.count <= 4_096,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == ["version", "profileNamespace", "account", "applicationID"],
              let value = try? JSONDecoder().decode(Settings.self, from: data), value.version == 1,
              value.profileNamespace == profileNamespace, value.account == account,
              DiscordIPCPolicy.acceptsApplicationID(value.applicationID) else { throw DiscordPresenceError.invalidSettings }
        return value.applicationID
    }
}
