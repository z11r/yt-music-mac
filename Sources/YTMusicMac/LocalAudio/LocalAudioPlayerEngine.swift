import Foundation
import MusicCore

struct LocalAudioEngineEvent {
    enum Kind { case state, ended, failed(LocalAudioPlaybackIssue) }
    let binding: PlaybackOutputEventBinding
    let kind: Kind
    let position: TimeInterval?
    let duration: TimeInterval?
    let playing: Bool
    let buffering: Bool
}

/// One lazy, owned native player, with no queue or live/global output registration.
@MainActor final class LocalAudioPlayerEngine: PlaybackOutputEngine {
    let outputInstanceID = UUID()
    let outputKind = PlaybackOutputEngineKind.local
    private(set) var isOutputRetired = false
    let clock = PlaybackClock()
    private(set) var hasConfirmedPosition = false
    private(set) var issue: LocalAudioPlaybackIssue?
    var onEvent: ((LocalAudioEngineEvent) -> Void)?
    private let profileStorageID: UUID
    private let factory: @MainActor (UUID) -> any LocalAudioNativeDriving
    private let bindEvents: @MainActor (PlaybackOutputPermit, any PlaybackOutputEngine, UUID) -> PlaybackOutputEventBinding?
    private let acceptsEvent: @MainActor (PlaybackOutputEventBinding) -> Bool
    private let sleep: @Sendable () async throws -> Void
    private var driver: (any LocalAudioNativeDriving)?
    private var item: (any LocalAudioNativeItem)?
    private var prepared: LocalAudioPreparedItem?
    private var observation: (any LocalAudioNativeObservation)?
    private var binding: PlaybackOutputEventBinding?
    private var request = UUID()
    private var loadWait: LocalAudioOperationWait?
    private var seekWait: LocalAudioOperationWait?
    private var seekRevision: UInt64 = 0
    private var ended = false
    private var retirement: PlaybackOutputRetirement?
    private var retirementOwner: LocalAudioEngineRetirementOwner?

    init(profileStorageID: UUID,
         factory: @escaping @MainActor (UUID) -> any LocalAudioNativeDriving = { NativeLocalAudioPlayerDriver(outputInstanceID: $0) },
         bindEvents: @escaping @MainActor (PlaybackOutputPermit, any PlaybackOutputEngine, UUID) -> PlaybackOutputEventBinding?,
         acceptsEvent: @escaping @MainActor (PlaybackOutputEventBinding) -> Bool,
         sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }) {
        self.profileStorageID = profileStorageID; self.factory = factory
        self.bindEvents = bindEvents; self.acceptsEvent = acceptsEvent; self.sleep = sleep
    }

    func activate(_ value: LocalAudioPreparedItem, permit: PlaybackOutputPermit, autoplay: Bool, volume: Double) async -> Result<Void, LocalAudioPlaybackIssue> {
        guard allowed(permit), value.authorization.profileStorageID == profileStorageID,
              volume.isFinite, (0...1).contains(volume) else { return .failure(.stale) }
        do { try value.consume(for: permit) } catch { return .failure(.sanitizing(error)) }
        invalidateOutputScopes(.nextItemPreparation)
        let id = UUID(); request = id; issue = nil; hasConfirmedPosition = false; clock.reset()
        do {
            guard allowed(permit) else { throw LocalAudioPlaybackIssue.stale }
            if driver == nil { driver = factory(outputInstanceID) }
            guard let driver, driver.outputInstanceID == outputInstanceID, allowed(permit) else { throw LocalAudioPlaybackIssue.stale }
            try checkActivation(permit, request: id); driver.mute(true)
            try checkActivation(permit, request: id); driver.pause()
            if let item { try checkActivation(permit, request: id); driver.cancelSeeks(item) }
            try checkActivation(permit, request: id)
            observation?.invalidate(); observation = nil; driver.detach(); item = nil; prepared = nil
            let quiet = LocalAudioOperationWait(sleep: sleep); loadWait = quiet
            let quietObservation = driver.observeOutput { [weak self] in
                guard let self, self.request == id, self.allowed(permit) else { quiet.finish(.failure(.stale)); return }
                if driver.snapshot.isQuiet { quiet.finish(.success(())) }
            }
            if driver.snapshot.isQuiet { quiet.finish(.success(())) }
            let quietResult = await quiet.result(); quietObservation.invalidate()
            try quietResult.get()
            guard allowed(permit), request == id else { throw LocalAudioPlaybackIssue.stale }
            let native = try driver.makeItem(value.source)
            guard allowed(permit), request == id else { throw LocalAudioPlaybackIssue.stale }
            item = native; prepared = value; ended = false
            try driver.install(native)
            guard allowed(permit), request == id, driver.snapshot.mediaID == native.mediaID, driver.snapshot.hasItem else {
                throw LocalAudioPlaybackIssue.stale
            }
            let wait = LocalAudioOperationWait(sleep: sleep); loadWait = wait
            try observe(permit, native: native)
            inspectReady(driver.snapshot, wait: wait)
            try await wait.result().get()
            guard allowed(permit), request == id, item === native else { throw LocalAudioPlaybackIssue.stale }
            loadWait = nil
            if value.resumePosition > 0 { try await seek(value.resumePosition, permit: permit).get() }
            guard allowed(permit), request == id else { throw LocalAudioPlaybackIssue.stale }
            if autoplay { try play(permit: permit, volume: volume).get() }
            else { driver.volume(volume); driver.mute(true); publishState(driver.snapshot) }
            return .success(())
        } catch {
            let failure = LocalAudioPlaybackIssue.sanitizing(error)
            if request == id, allowed(permit) {
                issue = failure; loadWait = nil; driver?.mute(true); driver?.pause()
                observation?.invalidate(); observation = nil; binding = nil
                if let item { driver?.cancelSeeks(item) }
                driver?.detach(); item = nil; prepared = nil; value.source.release()
            }
            return .failure(failure)
        }
    }

    func play(permit: PlaybackOutputPermit, volume: Double? = nil) -> Result<Void, LocalAudioPlaybackIssue> {
        guard commandAllowed(permit), let driver, let item else { return .failure(.stale) }
        guard driver.snapshot.readiness == .ready else { return .failure(.notReady) }
        if let volume {
            guard volume.isFinite, (0...1).contains(volume) else { return .failure(.unsupported) }
            driver.volume(volume)
        }
        guard commandAllowed(permit) else { return .failure(.stale) }; driver.mute(false)
        guard commandAllowed(permit) else { return .failure(.stale) }; driver.play()
        return rebind(permit, item: item)
    }
    func pause(permit: PlaybackOutputPermit) -> Result<Void, LocalAudioPlaybackIssue> {
        guard commandAllowed(permit), let driver, let item else { return .failure(.stale) }
        driver.pause(); return rebind(permit, item: item)
    }
    func setVolume(_ value: Double, permit: PlaybackOutputPermit) -> Result<Void, LocalAudioPlaybackIssue> {
        guard commandAllowed(permit), let driver, let item else { return .failure(.stale) }
        guard value.isFinite, (0...1).contains(value) else { return .failure(.unsupported) }
        driver.volume(value); return rebind(permit, item: item)
    }
    func seek(_ position: TimeInterval, permit: PlaybackOutputPermit) async -> Result<Void, LocalAudioPlaybackIssue> {
        guard commandAllowed(permit), let driver, let item, driver.snapshot.readiness == .ready,
              let duration = driver.snapshot.duration, duration.isFinite, position.isFinite,
              (0...duration).contains(position) else { return .failure(.notReady) }
        observation?.invalidate(); observation = nil; binding = nil
        seekRevision &+= 1; let revision = seekRevision
        let wait = LocalAudioOperationWait(sleep: sleep); seekWait?.finish(.failure(.stale)); seekWait = wait
        driver.seek(item, to: position) { [weak self, weak item] finished in
            guard let self, let item, self.seekRevision == revision, self.commandAllowed(permit), self.item === item,
                  driver.snapshot.mediaID == item.mediaID else { wait.finish(.failure(.stale)); return }
            wait.finish(finished ? .success(()) : .failure(.seekFailed))
        }
        let result = await wait.result()
        guard seekRevision == revision, commandAllowed(permit), self.item === item else { return .failure(.stale) }
        seekWait = nil
        if case .failure = result { driver.cancelSeeks(item); issue = result.failure; return result }
        let snapshot = driver.snapshot
        guard let actual = snapshot.position, actual.isFinite, actual >= 0, actual <= duration + 0.5 else {
            issue = .seekFailed; return .failure(.seekFailed)
        }
        if actual < duration { ended = false }
        return rebind(permit, item: item)
    }

    func invalidateOutputScopes(_ effect: PlaybackOutputRetargetEffect) {
        request = UUID(); binding = nil; seekRevision &+= 1
        loadWait?.finish(.failure(.stale)); loadWait = nil
        seekWait?.finish(.failure(.stale)); seekWait = nil
        observation?.invalidate(); observation = nil
        if let item { driver?.cancelSeeks(item) }
        if case .nextItemPreparation = effect { driver?.mute(true); driver?.pause() }
    }
    func revokeOutput() -> PlaybackOutputRetirement {
        if let retirement { return retirement }
        isOutputRetired = true; invalidateOutputScopes(.nextItemPreparation)
        let owner = LocalAudioEngineRetirementOwner(driver: driver, item: item, instanceID: outputInstanceID)
        retirementOwner = owner; driver?.holdOutput(); item = nil; prepared = nil
        let operation = PlaybackOutputRetirement(engine: .local, instanceID: outputInstanceID, retaining: owner, sleep: sleep)
        retirement = operation
        operation.onConfirmedQuiet { [weak self] in self?.driver = nil; self?.retirementOwner = nil }
        owner.begin(operation: operation)
        return operation
    }
    private func allowed(_ permit: PlaybackOutputPermit) -> Bool {
        !isOutputRetired && permit.scope.engine == .local && permit.authorizes(self)
    }
    private func checkActivation(_ permit: PlaybackOutputPermit, request id: UUID) throws {
        guard request == id, allowed(permit) else { throw LocalAudioPlaybackIssue.stale }
    }
    private func commandAllowed(_ permit: PlaybackOutputPermit) -> Bool {
        guard allowed(permit), let prepared, let item, let driver else { return false }
        let old = prepared.scope, new = permit.scope
        return old.sessionID == new.sessionID && old.profileGeneration == new.profileGeneration && old.accountGeneration == new.accountGeneration &&
            old.itemID == new.itemID && old.occurrence == new.occurrence && driver.snapshot.hasItem && driver.snapshot.mediaID == item.mediaID
    }
    private func rebind(_ permit: PlaybackOutputPermit, item: any LocalAudioNativeItem) -> Result<Void, LocalAudioPlaybackIssue> {
        do { try observe(permit, native: item); publishState(driver?.snapshot ?? .init()); return .success(()) }
        catch { return .failure(.sanitizing(error)) }
    }
    private func observe(_ permit: PlaybackOutputPermit, native: any LocalAudioNativeItem) throws {
        guard commandAllowed(permit), let driver,
              let token = bindEvents(permit, self, native.mediaID), token.isCurrent else { throw LocalAudioPlaybackIssue.stale }
        observation?.invalidate(); binding = token
        observation = driver.observe(native) { [weak self] event in self?.receive(event, token: token) }
    }
    private func receive(_ event: LocalAudioNativeEvent, token: PlaybackOutputEventBinding) {
        guard !isOutputRetired, binding === token, acceptsEvent(token), token.isCurrent,
              item?.mediaID == token.nativeMediaID, driver?.snapshot.mediaID == token.nativeMediaID else { return }
        switch event {
        case let .state(snapshot):
            if let loadWait { inspectReady(snapshot, wait: loadWait) }
            if snapshot.readiness == .failed {
                issue = .unavailable
                onEvent?(.init(binding: token, kind: .failed(.unavailable), position: nil, duration: nil, playing: false, buffering: false))
                return
            }
            publishState(snapshot)
        case let .ended(snapshot):
            guard loadWait == nil, seekWait == nil, !ended, let position = validPosition(snapshot),
                  position.0 >= position.1 - 0.25 else { return }
            ended = true; publishState(snapshot, ended: true)
        case .failed:
            issue = .unavailable; loadWait?.finish(.failure(.unavailable))
            onEvent?(.init(binding: token, kind: .failed(.unavailable), position: nil, duration: nil, playing: false, buffering: false))
        }
    }
    private func inspectReady(_ snapshot: LocalAudioNativeSnapshot, wait: LocalAudioOperationWait) {
        guard snapshot.hasItem, snapshot.mediaID == item?.mediaID else { wait.finish(.failure(.unavailable)); return }
        switch snapshot.readiness {
        case .ready: if validPosition(snapshot) != nil { wait.finish(.success(())) }
        case .failed: wait.finish(.failure(.unavailable))
        case .unknown: break
        }
    }
    private func validPosition(_ snapshot: LocalAudioNativeSnapshot) -> (Double, Double)? {
        guard snapshot.readiness == .ready, let position = snapshot.position, let duration = snapshot.duration,
              position.isFinite, duration.isFinite, (0.001...604_800).contains(duration), position >= 0, position <= duration + 0.5 else { return nil }
        return (min(position, duration), duration)
    }
    private func publishState(_ snapshot: LocalAudioNativeSnapshot, ended: Bool = false) {
        guard let binding, acceptsEvent(binding), binding.isCurrent, snapshot.mediaID == binding.nativeMediaID else { return }
        let position = loadWait == nil && seekWait == nil ? validPosition(snapshot) : nil
        if let position { clock.update(position: position.0, duration: position.1); hasConfirmedPosition = true }
        onEvent?(.init(binding: binding, kind: ended ? .ended : .state, position: position?.0, duration: position?.1,
            playing: snapshot.control == .playing && snapshot.rate > 0 && !snapshot.muted,
            buffering: loadWait != nil || seekWait != nil || snapshot.control == .waiting))
    }
}

@MainActor private final class LocalAudioEngineRetirementOwner {
    private let driver: (any LocalAudioNativeDriving)?
    private var item: (any LocalAudioNativeItem)?
    private var observation: (any LocalAudioNativeObservation)?
    private weak var operation: PlaybackOutputRetirement?
    private let instanceID: UUID
    init(driver: (any LocalAudioNativeDriving)?, item: (any LocalAudioNativeItem)?, instanceID: UUID) {
        self.driver = driver; self.item = item; self.instanceID = instanceID
    }
    func begin(operation: PlaybackOutputRetirement) {
        self.operation = operation
        observation = driver?.observeOutput { [weak self] in self?.inspect() }
        inspect()
    }
    private func inspect() {
        guard let operation, driver == nil || (driver?.outputInstanceID == instanceID && driver?.snapshot.isQuiet == true) else { return }
        observation?.invalidate(); observation = nil; item = nil
        operation.confirmQuiet(ticket: operation.ticket)
    }
}

private extension Result where Failure == LocalAudioPlaybackIssue {
    var failure: LocalAudioPlaybackIssue? { if case let .failure(issue) = self { issue } else { nil } }
}
