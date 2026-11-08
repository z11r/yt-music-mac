import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

struct TestLocalAudioProfiles: LocalAudioProfileLifetimeProviding {
    let storageID: UUID
    let hold: (@Sendable () -> any Sendable)?
    nonisolated init(storageID: UUID, hold: (@Sendable () -> any Sendable)? = nil) { self.storageID = storageID; self.hold = hold }
    @MainActor func acquire(authorization: LocalAudioIOAuthorization) async throws -> LocalAudioProfileLifetime {
        try authorization.check()
        guard authorization.profileStorageID == storageID else { throw LocalAudioPlaybackIssue.stale }
        return .init(profileStorageID: storageID, authorization: authorization, retaining: hold?() ?? storageID)
    }
}

@MainActor final class LocalAudioTestOwner { var scope: PlaybackOutputScope?; var current = true }
@MainActor final class LocalAudioEngineFixture {
    let profileID = UUID()
    let reference = LocalAudioReference(libraryID: UUID(), fileID: UUID())
    let session = UUID(), profile = UUID(), account = UUID(), queueSession = UUID(), entry = UUID()
    let owner = LocalAudioTestOwner()
    let coordinator: PlaybackOutputCoordinator
    let factory = FakeLocalDriverFactory()
    let engine: LocalAudioPlayerEngine
    let references: LocalAudioReferenceUseRegistry
    let clock = LocalAudioTestClock()
    let holds = LocalAudioTestHolds()
    var events: [LocalAudioEngineEvent] = []
    init() {
        let owner = owner
        let coordinator = PlaybackOutputCoordinator(admission: PlaybackOutputAdmission(), isCurrent: { owner.current && owner.scope == $0 })
        self.coordinator = coordinator
        references = .init(profileStorageID: profileID)
        let factory = factory, clock = clock
        engine = LocalAudioPlayerEngine(profileStorageID: profileID, factory: { factory.make($0) },
            bindEvents: { [weak coordinator] in coordinator?.bindMediaEvents($0, engine: $1, nativeMediaID: $2) },
            acceptsEvent: { [weak coordinator] in coordinator?.acceptsEvent($0) == true }, sleep: { try await clock.sleep() })
        engine.onEvent = { [weak self] in self?.events.append($0) }
    }
    func scope(intent: UInt64 = 1, itemID: UUID = UUID(), generation: UInt64 = 1) -> PlaybackOutputScope {
        .init(sessionID: session, profileGeneration: profile, accountGeneration: account,
            occurrence: .init(sessionID: queueSession, entryID: entry, trackID: reference.trackID, generation: generation),
            engine: .local, itemID: itemID, intentRevision: intent)
    }
    func prepared(_ scope: PlaybackOutputScope, resume: Double = 0) async throws -> LocalAudioPreparedItem {
        let authorization = LocalAudioIOAuthorization(profileStorageID: profileID, isCurrent: { [owner] in owner.current && owner.scope == scope })
        let io = TestLocalAudioIO()
        let metadata = LocalAudioMetadata(title: "Fixture", artist: "Artist", duration: 120, byteCount: 512)
        let record = LocalAudioLibraryRecord(reference: reference, metadata: metadata, identity: io.identity,
            bookmark: .init(mode: .ordinary, data: Data([1])))
        let document = LocalAudioLibraryDocument(profileID: profileID, libraryID: reference.libraryID, records: [record])
        let holds = holds
        let access = LocalAudioAccessController(load: { document }, bookmarks: io, files: io,
            profiles: TestLocalAudioProfiles(storageID: profileID, hold: { holds.hold() }), references: references,
            admission: LocalAudioReadAdmission())
        let lease = try await access.acquire(reference, expectedLibraryID: reference.libraryID, authorization: authorization)
        return try LocalAudioPreparedItem(scope: scope, track: metadata.track(reference: reference),
            source: FakeLocalPreparedSource(lease: lease), authorization: authorization, resumePosition: resume)
    }
    func bind(_ scope: PlaybackOutputScope) async throws -> PlaybackOutputPermit {
        owner.scope = scope
        guard case let .prepared(prepared) = await coordinator.prepareOutput(scope),
              case let .permitted(permit) = coordinator.bindOutput(prepared, to: engine) else { throw LocalAudioPlaybackIssue.stale }
        return permit
    }
    func retarget(_ permit: PlaybackOutputPermit, _ scope: PlaybackOutputScope) throws -> PlaybackOutputPermit {
        owner.scope = scope
        guard case let .permitted(next) = coordinator.retargetOutput(permit, to: scope) else { throw LocalAudioPlaybackIssue.stale }
        return next
    }
    func start() async throws -> PlaybackOutputPermit {
        let scope = scope(); let permit = try await bind(scope); let value = try await prepared(scope)
        try await engine.activate(value, permit: permit, autoplay: true, volume: 0.6).get()
        return permit
    }
}

@MainActor final class FakeLocalDriverFactory {
    var drivers: [FakeLocalAudioDriver] = []
    var readiness: LocalAudioNativeReadiness = .ready
    func make(_ id: UUID) -> any LocalAudioNativeDriving {
        let value = FakeLocalAudioDriver(outputInstanceID: id); value.readiness = readiness; drivers.append(value); return value
    }
    var driver: FakeLocalAudioDriver { drivers[0] }
}
@MainActor final class FakeLocalAudioItem: LocalAudioNativeItem {
    let mediaID = UUID()
    let source: any LocalAudioPreparedSource
    private let use: LocalAudioResourceUse
    init(_ source: any LocalAudioPreparedSource) throws { self.source = source; use = try source.lease.retainUse() }
}
@MainActor final class FakeLocalAudioObservation: LocalAudioNativeObservation {
    private var cleanup: (() -> Void)?
    init(_ cleanup: @escaping () -> Void = {}) { self.cleanup = cleanup }
    func invalidate() { let action = cleanup; cleanup = nil; action?() }
}
@MainActor final class FakeLocalAudioDriver: LocalAudioNativeDriving {
    let outputInstanceID: UUID
    var frame = LocalAudioNativeSnapshot()
    var snapshot: LocalAudioNativeSnapshot { frame }
    var current: (any LocalAudioNativeItem)?
    var retained: [any LocalAudioNativeItem] = []
    var retainsDetached = false
    var refuseQuiet = false
    var readiness: LocalAudioNativeReadiness = .ready
    var autoSeek = true
    var seekCompletion: (@MainActor (Bool) -> Void)?
    var history: [@MainActor (LocalAudioNativeEvent) -> Void] = []
    var receive: (@MainActor (LocalAudioNativeEvent) -> Void)?
    var output: [UUID: @MainActor () -> Void] = [:]
    var calls: [String] = []
    private var installedWaiters: [CheckedContinuation<Void, Never>] = []
    private var seekWaiters: [CheckedContinuation<Void, Never>] = []
    private var held = false
    init(outputInstanceID: UUID) { self.outputInstanceID = outputInstanceID }
    func makeItem(_ source: any LocalAudioPreparedSource) throws -> any LocalAudioNativeItem { calls.append("make"); return try FakeLocalAudioItem(source) }
    func install(_ item: any LocalAudioNativeItem) throws {
        guard !held else { throw LocalAudioPlaybackIssue.stale }
        current = item; calls.append("install")
        frame = .init(hasPlayer: true, hasItem: true, mediaID: item.mediaID, readiness: readiness,
            position: 0, duration: item.source.duration)
        let waiting = installedWaiters; installedWaiters = []; waiting.forEach { $0.resume() }
    }
    func detach() {
        calls.append("detach")
        if retainsDetached, let current { retained.append(current) }
        current = nil; frame.hasItem = false; frame.mediaID = nil
        if refuseQuiet { frame.control = .playing; frame.rate = 1 }
    }
    func mute(_ value: Bool) { calls.append(value ? "mute" : "unmute"); if !held || value { frame.muted = value } }
    func pause() { calls.append("pause"); frame.rate = 0; frame.control = .paused }
    func play() { calls.append("play"); guard !held else { return }; frame.rate = 1; frame.control = .playing }
    func volume(_ value: Double) { calls.append("volume") }
    func seek(_ item: any LocalAudioNativeItem, to position: TimeInterval, completion: @escaping @MainActor (Bool) -> Void) {
        calls.append("seek")
        seekCompletion = completion
        let waiting = seekWaiters; seekWaiters = []; waiting.forEach { $0.resume() }
        if autoSeek { frame.position = position; completion(true) }
    }
    func cancelSeeks(_ item: any LocalAudioNativeItem) { calls.append("cancelSeek") }
    func observe(_ item: any LocalAudioNativeItem, receive: @escaping @MainActor (LocalAudioNativeEvent) -> Void) -> any LocalAudioNativeObservation {
        self.receive = receive; history.append(receive)
        return FakeLocalAudioObservation { [weak self] in self?.receive = nil }
    }
    func observeOutput(_ changed: @escaping @MainActor () -> Void) -> any LocalAudioNativeObservation {
        let id = UUID(); output[id] = changed
        return FakeLocalAudioObservation { [weak self] in self?.output[id] = nil }
    }
    func holdOutput() { held = true; calls.append("hold"); frame.muted = true; pause(); detach() }
    func signalOutput() { Array(output.values).forEach { $0() } }
    func emit(_ event: LocalAudioNativeEvent) { receive?(event) }
    func waitInstalled() async { if current == nil { await withCheckedContinuation { installedWaiters.append($0) } } }
    func waitSeek() async { if seekCompletion == nil { await withCheckedContinuation { seekWaiters.append($0) } } }
}

actor LocalAudioTestClock {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var observers: [CheckedContinuation<Void, Never>] = []
    func sleep() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { waiters[id] = $0; observers.forEach { $0.resume() }; observers = [] }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func waitForSleep() async { if waiters.isEmpty { await withCheckedContinuation { observers.append($0) } } }
    func fire() { let pending = waiters.values; waiters = [:]; pending.forEach { $0.resume() } }
}

final class LocalAudioTestHolds: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func hold() -> LocalAudioTestHold { lock.withLock { value += 1 }; return LocalAudioTestHold(self) }
    fileprivate func end() { lock.withLock { value -= 1 } }
}
final class LocalAudioTestHold: Sendable {
    let owner: LocalAudioTestHolds
    init(_ owner: LocalAudioTestHolds) { self.owner = owner }
    deinit { owner.end() }
}

@MainActor final class FakeLocalPreparedSource: LocalAudioPreparedSource {
    let lease: LocalAudioResourceLease
    let duration: TimeInterval
    private(set) var releases = 0
    init(lease: LocalAudioResourceLease, duration: TimeInterval = 120) { self.lease = lease; self.duration = duration }
    func release() { releases += 1; lease.release() }
}

struct TestLocalAudioIO: LocalAudioBookmarkAccessing, LocalAudioFileInspecting {
    let identity = LocalAudioFileIdentity(volumeID: "fixture", fileID: 42)
    func create(for url: URL, mode: LocalAudioBookmarkMode) throws -> LocalAudioBookmark { .init(mode: mode, data: Data([1])) }
    func resolve(_ bookmark: LocalAudioBookmark) throws -> LocalAudioResolvedBookmark {
        .init(url: URL(fileURLWithPath: "/synthetic/audio.wav"), isStale: false)
    }
    func beginAccess(to url: URL) -> Bool { false }
    func endAccess(to url: URL) { Issue.record("The ordinary fake grant was not acquired") }
    func inspect(_ url: URL) throws -> LocalAudioFileFacts {
        .init(identity: identity, byteCount: 512, isRegularFile: true, isSymbolicLink: false, isAliasFile: false,
              isLocalVolume: true, isLocallyAvailable: true, isReadable: true)
    }
}
