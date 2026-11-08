import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@Suite("Local app profile registry")
struct AppProfileRegistryTests {
    @Test func legacyContextPreservesEveryNamespaceAndAdditionalProfilesAreDisjoint() throws {
        let directory = URL(fileURLWithPath: "/isolated-fixture/app")
        let legacyID = UUID(uuidString: "5D12B9C4-C139-4D87-A86A-6137BFCD1D01")!
        let legacy = try AppProfileContext(profile: .original, appIdentifier: "fixture.app", legacyDirectory: directory, legacyWebsiteDataIdentifier: legacyID)
        #expect(legacy.namespace == "fixture.app")
        #expect(legacy.websiteDataIdentifier == legacyID)
        #expect(legacy.dataDirectory == directory)
        #expect(legacy.listenBrainzCredentialService == "fixture.app.listenbrainz")
        #expect(legacy.lastFMCredentialService == "fixture.app.lastfm")
        let a = try AppProfile.additional(name: "A", identifier: profileA)
        let b = try AppProfile.additional(name: "B", identifier: profileB)
        let contexts = try [a, b].map { try AppProfileContext(profile: $0, appIdentifier: "fixture.app", legacyDirectory: directory, legacyWebsiteDataIdentifier: legacyID) }
        #expect(contexts[0].namespace == "fixture.app.profiles.\(a.id)")
        #expect(contexts[0].dataDirectory == directory.appendingPathComponent("Profiles/\(a.id)", isDirectory: true))
        #expect(Set(contexts.map(\.namespace) + [legacy.namespace]).count == 3)
        #expect(Set(contexts.map(\.websiteDataIdentifier) + [legacy.websiteDataIdentifier]).count == 3)
        #expect(Set(contexts.map(\.listenBrainzCredentialService) + [legacy.listenBrainzCredentialService]).count == 3)
    }

    @Test func revokedSaveTokensRejectQueuedWritesBeforeAnyStorageAccess() async throws {
        let gate = LocalPersistenceGate()
        let oldToken = gate.token
        gate.setEnabled(false); #expect(!gate.accepts(oldToken))
        gate.setEnabled(true); #expect(!gate.accepts(oldToken))
        let current = gate.token; #expect(gate.accepts(current))
        // Invalid non-file URLs ensure an allowed call would throw validation;
        // the denied calls must stop before opening or creating anything.
        let queue = QueueStore(fileURL: URL(string: "https://invalid.example/queue")!)
        await #expect(throws: CancellationError.self) {
            try await queue.save(PlaybackQueue().snapshot(), if: { gate.accepts(oldToken) })
        }
        let progress = EpisodeProgressStore(directory: URL(string: "https://invalid.example/progress")!)
        await #expect(throws: CancellationError.self) {
            try await progress.save(.init(accountHash: String(repeating: "a", count: 64), records: []), if: { false })
        }
    }

    @Test func absentRegistryLoadsDefaultWithoutCreatingAnything() async throws {
        let io = ProfileMemoryIO()
        let loaded = try await AppProfileRegistryStore(io: io).load()
        #expect(loaded.archive == .original)
        #expect(loaded.revision == nil)
        #expect(io.readCount == 1 && io.writeCount == 0)
    }

    @Test func malformedFutureOversizeAndUnknownFieldsAreRetainedOnLoadAndSave() async {
        let encoder = JSONEncoder()
        let good = try! encoder.encode(AppProfileArchive.original)
        var object = try! JSONSerialization.jsonObject(with: good) as! [String: Any]
        object["unknown"] = true
        var nested = try! JSONSerialization.jsonObject(with: good) as! [String: Any]
        var profile = (nested["profiles"] as! [[String: Any]])[0]
        profile["futureField"] = true
        nested["profiles"] = [profile]
        var oversized = try! JSONSerialization.jsonObject(with: good) as! [String: Any]
        oversized["profiles"] = Array(repeating: (oversized["profiles"] as! [[String: Any]])[0], count: 9)
        let samples = [Data("bad".utf8), Data(#"{"version":99}"#.utf8), Data(repeating: 32, count: 65_537),
                       try! JSONSerialization.data(withJSONObject: object),
                       try! JSONSerialization.data(withJSONObject: nested),
                       try! JSONSerialization.data(withJSONObject: oversized)]
        for bytes in samples {
            let io = ProfileMemoryIO(bytes)
            let store = AppProfileRegistryStore(io: io)
            await #expect(throws: (any Error).self) { try await store.load() }
            await #expect(throws: (any Error).self) { try await store.save(.original, replacing: bytes) }
            #expect(io.data == bytes && io.writeCount == 0)
        }
    }

    @Test func strictRegistryRejectsDuplicateIDsNamesPendingSelectionAndReservedStores() throws {
        var a = try AppProfile.additional(name: "One", identifier: profileA); a.isInitialized = true
        let b = try AppProfile.additional(name: "ONE", identifier: profileB)
        #expect(throws: AppProfileError.duplicateName) { try AppProfileArchive(version: 1, selectedID: a.id, profiles: [.original, a, b]).validate() }
        #expect(throws: AppProfileError.invalidRegistry) { try AppProfileArchive(version: 1, selectedID: a.id, profiles: [.original, a, a]).validate() }
        #expect(throws: AppProfileError.invalidRegistry) { try AppProfileArchive(version: 1, selectedID: b.id, profiles: [.original, b]).validate() }
        for id in ["5d12b9c4-c139-4d87-a86a-6137bfcd1d01", "5d12b9c4-c139-4d87-a86a-6137bfcd1d02", "00000000-0000-0000-0000-000000000000"] {
            #expect(throws: AppProfileError.invalidRegistry) { try AppProfile(id: id, name: "Other", createdAt: .now, isInitialized: false).validate() }
        }
        #expect(throws: AppProfileError.invalidName) { try AppProfile.additional(name: "\n", identifier: profileA) }
        #expect(throws: AppProfileError.invalidName) { try AppProfile.additional(name: String(repeating: "a", count: 101), identifier: profileA) }
    }

    @Test func compareAndSwapRejectsConcurrentRegistryChangesWithoutOverwritingThem() async throws {
        let io = ProfileMemoryIO(); let store = AppProfileRegistryStore(io: io)
        let before = try await store.load()
        var archive = before.archive
        archive.profiles.append(try AppProfile.additional(name: "A", identifier: profileA))
        let saved = try await store.save(archive, replacing: before.revision)
        await #expect(throws: AppProfileError.stale) { try await store.save(.original, replacing: before.revision) }
        #expect(io.data == saved.revision && io.writeCount == 1)
    }
}

@MainActor @Suite("Local app profile ownership")
struct AppProfileOwnerTests {
    @Test func switchPersistsSelectionBeforeShutdownAndStartsOnePausedReplacement() async throws {
        let f = try ProfileOwnerFixture()
        await f.owner.start()
        f.events.clear()
        let oldActivation = f.owner.activationID
        await f.owner.switchTo(f.additional.id)
        #expect(f.events.values == ["unbind", "default.quiesce", "default.settle", "prepare.false", "save", "default.shutdown", "activate", "bind", "A.startPaused"])
        #expect(f.owner.current.profile.id == f.additional.id)
        #expect(f.owner.current.playing == false)
        #expect(!f.owner.accepts(oldActivation))
        #expect(f.owner.savedSelectionID == f.additional.id)
    }

    @Test func replacementWaitsForAcceptedOldWorkBeforeFactoryAndShutdown() async throws {
        let f = try ProfileOwnerFixture()
        await f.owner.start(); f.events.clear()
        let gate = ProfileTestGate()
        f.initial.onSettle = { await gate.wait() }
        let transition = Task { await f.owner.switchTo(f.additional.id) }
        while !gate.isWaiting { await Task.yield() }
        #expect(f.owner.isSwitching && f.owner.current === f.initial)
        #expect(!f.initial.playing && !f.initial.didShutdown)
        #expect(!f.events.values.contains("prepare.false"))
        await f.owner.create(name: "Ignored while switching")
        #expect(f.owner.profiles.count == 2)
        gate.open(); await transition.value
        #expect(f.initial.didShutdown && f.owner.current !== f.initial)
    }

    @Test func quitDuringPreparationAwaitsTransitionAndNeverStartsTheNewOwner() async throws {
        let gate = ProfileTestGate()
        let f = try ProfileOwnerFixture(prepareGate: gate)
        await f.owner.start(); f.events.clear()
        let transition = Task { await f.owner.switchTo(f.additional.id) }
        while !gate.isWaiting { await Task.yield() }
        let quit = Task { await f.owner.shutdown() }
        while f.events.values.filter({ $0 == "unbind" }).count < 2 { await Task.yield() }
        #expect(!f.initial.didShutdown)
        gate.open(); await transition.value; await quit.value
        #expect(f.owner.current.didShutdown)
        #expect(!f.events.values.contains("A.startPaused"))
        #expect(!f.owner.accepts(f.owner.activationID))
    }

    @Test func factoryFailureKeepsDurableSelectionAndResumesExistingOwnerPaused() async throws {
        let f = try ProfileOwnerFixture(failPreparation: true)
        await f.owner.start(); f.events.clear(); f.initial.playing = true
        await f.owner.switchTo(f.additional.id)
        #expect(f.owner.current === f.initial)
        #expect(!f.initial.playing && !f.initial.didShutdown)
        #expect(f.owner.savedSelectionID == AppProfile.defaultID)
        #expect(f.owner.errorMessage != nil)
        #expect(f.events.values == ["unbind", "default.quiesce", "default.settle", "prepare.false", "default.resumePaused", "bind", "default.startPaused"])
    }

    @Test func persistenceFailureNeverShutsDownOrActivatesThePreparedRuntime() async throws {
        let f = try ProfileOwnerFixture()
        await f.owner.start(); f.events.clear(); f.io.failWrites = true
        await f.owner.switchTo(f.additional.id)
        #expect(f.owner.current === f.initial && !f.initial.didShutdown)
        #expect(!f.events.values.contains("activate"))
        #expect(f.owner.savedSelectionID == AppProfile.defaultID)
        #expect(!f.initial.playing)
    }

    @Test func failedCreationRetainsOneBoundedPendingRecordAndNeverSelectsIt() async throws {
        let f = try ProfileOwnerFixture(failPreparation: true, hasAdditional: false)
        await f.owner.start()
        await f.owner.create(name: "New")
        #expect(f.owner.profiles.count == 2)
        #expect(f.owner.profiles[1].isInitialized == false)
        #expect(f.owner.savedSelectionID == AppProfile.defaultID)
        #expect(f.events.values.contains("prepare.true"))
        let saved = try await f.registry.load()
        #expect(saved.archive.profiles.count == 2 && saved.archive.selectedID == AppProfile.defaultID)
    }

    @Test func restoredSelectionCannotCreateAMissingStoreOrOverwriteTheSelectionOnFailure() async throws {
        let f = try ProfileOwnerFixture(failPreparation: true, selectedAdditional: true)
        await f.owner.start()
        #expect(f.owner.current === f.initial)
        #expect(f.owner.savedSelectionID == f.additional.id)
        #expect(f.events.values.contains("prepare.false"))
        #expect(!f.events.values.contains("prepare.true"))
        #expect(f.io.writeCount == 0)
        #expect(!f.initial.playing && !f.initial.didShutdown)
    }

    @Test func malformedRegistryStartsUsableDefaultPausedWithoutSavingOrPreparing() async throws {
        let f = try ProfileOwnerFixture(bytes: Data("malformed".utf8))
        await f.owner.start()
        #expect(f.owner.current === f.initial && !f.initial.playing)
        #expect(!f.owner.canEdit && f.owner.errorMessage != nil)
        #expect(f.io.writeCount == 0)
        #expect(f.events.values == ["bind", "default.startPaused"])
    }

    @Test func reenteringSameProfileUsesNewActivationAndNeverRevivesAnOldRuntime() async throws {
        let f = try ProfileOwnerFixture()
        await f.owner.start(); let oldID = f.owner.activationID
        await f.owner.switchTo(f.additional.id); let middle = f.owner.current
        await f.owner.switchTo(AppProfile.defaultID)
        #expect(f.owner.current !== f.initial && f.owner.current !== middle)
        #expect(f.initial.didShutdown && middle.didShutdown)
        #expect(!f.owner.accepts(oldID))
        #expect(!f.owner.current.playing)
    }

    @Test func operationFenceRejectsNewWorkAndWaitsForAcceptedWork() async {
        let fence = ProfileOperationFence()
        #expect(fence.begin())
        fence.quiesce(); #expect(!fence.begin())
        var finished = false
        let task = Task { await fence.waitForIdle(); finished = true }
        await Task.yield(); #expect(!finished)
        fence.end(); await task.value; #expect(finished)
        fence.resume(); #expect(fence.begin()); fence.end()
    }
}

private let profileA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let profileB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

private final class ProfileEvents: @unchecked Sendable {
    private let lock = NSLock(); private var entries: [String] = []
    var values: [String] { lock.withLock { entries } }
    func add(_ value: String) { lock.withLock { entries.append(value) } }
    func clear() { lock.withLock { entries.removeAll() } }
}
private final class ProfileMemoryIO: AppProfileRegistryIO, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var reads = 0, writes = 0, fails = false
    let events: ProfileEvents?
    init(_ bytes: Data? = nil, events: ProfileEvents? = nil) { self.bytes = bytes; self.events = events }
    var data: Data? { lock.withLock { bytes } }
    var readCount: Int { lock.withLock { reads } }
    var writeCount: Int { lock.withLock { writes } }
    var failWrites: Bool { get { lock.withLock { fails } } set { lock.withLock { fails = newValue } } }
    func read() throws -> Data? { lock.withLock { reads += 1; return bytes } }
    func replace(_ data: Data, expected: Data?) throws {
        try lock.withLock {
            guard !fails else { throw AppProfileError.unavailable }
            guard bytes == expected else { throw AppProfileError.stale }
            bytes = data; writes += 1; events?.add("save")
        }
    }
}
@MainActor private final class FakeProfileRuntime: AppProfileRuntime {
    var profile: AppProfile
    var playing = false, didShutdown = false
    let events: ProfileEvents
    var onSettle: (() async -> Void)?
    var label: String { profile.isDefault ? "default" : "A" }
    init(_ profile: AppProfile, events: ProfileEvents) { self.profile = profile; self.events = events }
    func quiesce() { playing = false; events.add(label + ".quiesce") }
    func settle() async { events.add(label + ".settle"); await onSettle?() }
    func resumePausedOwnership() { precondition(!didShutdown); playing = false; events.add(label + ".resumePaused") }
    func shutdown() async { didShutdown = true; events.add(label + ".shutdown") }
    func startPaused() async { precondition(!didShutdown); playing = false; events.add(label + ".startPaused") }
}
@MainActor private struct ProfileOwnerFixture {
    let events: ProfileEvents
    let io: ProfileMemoryIO
    let registry: AppProfileRegistryStore
    let additional: AppProfile
    let initial: FakeProfileRuntime
    let owner: AppProfileOwner<FakeProfileRuntime>
    init(failPreparation: Bool = false, hasAdditional: Bool = true, selectedAdditional: Bool = false, bytes: Data? = nil, prepareGate: ProfileTestGate? = nil) throws {
        let events = ProfileEvents()
        var additional = try AppProfile.additional(name: "A", identifier: profileA); additional.isInitialized = true
        let archive = AppProfileArchive(version: 1, selectedID: selectedAdditional ? additional.id : AppProfile.defaultID,
                                        profiles: hasAdditional ? [.original, additional] : [.original])
        let io = ProfileMemoryIO(try bytes ?? JSONEncoder().encode(archive), events: events)
        let registry = AppProfileRegistryStore(io: io)
        let initial = FakeProfileRuntime(.original, events: events)
        owner = AppProfileOwner(initial: initial, registry: registry, prepare: { profile, creation in
            events.add("prepare.\(creation)")
            await prepareGate?.wait()
            if failPreparation { throw AppProfileError.unavailable }
            return PreparedAppProfile { events.add("activate"); return FakeProfileRuntime(profile, events: events) }
        }, bind: { runtime, _ in events.add(runtime == nil ? "unbind" : "bind") })
        self.events = events; self.io = io; self.registry = registry; self.initial = initial; self.additional = additional
    }
}

@MainActor private final class ProfileTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { let pending = continuation; continuation = nil; pending?.resume() }
}
