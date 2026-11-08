import Foundation
import Testing
@testable import YTMusicMac

@Suite("Scoped local player engine", .serialized) @MainActor
struct LocalAudioPlayerEngineTests {
    @Test func engineIsLazyAndOrdinaryCommandsKeepOnePlayerAndFreshCallbackAuthority() async throws {
        let f = LocalAudioEngineFixture()
        #expect(f.factory.drivers.isEmpty)
        let first = try await f.start()
        #expect(f.factory.drivers.count == 1 && f.engine.hasConfirmedPosition)
        let oldCallback = try #require(f.factory.driver.history.last)
        let oldFrame = f.factory.driver.frame
        let calls = f.factory.driver.calls.filter { $0 == "play" }.count
        let next = try f.retarget(first, f.scope(intent: 2, itemID: first.scope.itemID))
        #expect(f.factory.driver.frame.control == .playing)
        try f.engine.setVolume(0.3, permit: next).get()
        #expect(f.factory.driver.calls.filter { $0 == "play" }.count == calls)
        let count = f.events.count; oldCallback(.ended(oldFrame))
        #expect(f.events.count == count)
        try f.engine.pause(permit: next).get()
        #expect(!f.engine.isOutputRetired && f.factory.driver.frame.control == .paused)
        try f.engine.play(permit: next).get()
        #expect(f.factory.drivers.count == 1)
        f.coordinator.quiesce()
    }

    @Test func nextItemRetargetPausesAndRetainsUntilExactReplacementThenEndsOnce() async throws {
        let f = LocalAudioEngineFixture(); let old = try await f.start()
        let oldItem = try #require(f.factory.driver.current)
        let oldCallback = try #require(f.factory.driver.history.last)
        let scope = f.scope(intent: 2, generation: 2); let next = try f.retarget(old, scope)
        #expect(f.factory.driver.current === oldItem && f.factory.driver.frame.muted)
        #expect(f.factory.driver.frame.control == .paused)
        let prepared = try await f.prepared(scope)
        try await f.engine.activate(prepared, permit: next, autoplay: true, volume: 0.5).get()
        #expect(f.factory.drivers.count == 1 && f.factory.driver.current?.mediaID != oldItem.mediaID)
        let calls = f.factory.driver.calls
        #expect(calls.lastIndex(of: "detach")! < calls.lastIndex(of: "install")!)
        let before = f.events.count
        var end = f.factory.driver.frame; end.position = 120
        oldCallback(.ended(end)); #expect(f.events.count == before)
        f.factory.driver.frame = end; f.factory.driver.emit(.ended(end)); f.factory.driver.emit(.ended(end))
        #expect(f.events.filter { if case .ended = $0.kind { true } else { false } }.count == 1)
        let repeated = await f.engine.activate(prepared, permit: next, autoplay: true, volume: 0.5)
        #expect(testLocalIssue(repeated) == .stale)
        f.coordinator.quiesce()
    }

    @Test func unknownReadinessHasABoundedWaitAndCannotAutoplay() async throws {
        let f = LocalAudioEngineFixture(); f.factory.readiness = .unknown
        let scope = f.scope(); let permit = try await f.bind(scope); let value = try await f.prepared(scope)
        let task = Task { await f.engine.activate(value, permit: permit, autoplay: true, volume: 0.5) }
        await f.clock.waitForSleep(); await f.clock.fire()
        let result = await task.value
        #expect(testLocalIssue(result) == .timedOut)
        #expect(!f.factory.driver.calls.contains("play") && f.factory.driver.snapshot.isQuiet)
        f.coordinator.quiesce()
    }

    @Test func staleLoadCancellationCannotRetireOrPauseReplacement() async throws {
        let f = LocalAudioEngineFixture(); f.factory.readiness = .unknown
        let firstScope = f.scope(); let first = try await f.bind(firstScope); let value = try await f.prepared(firstScope)
        let task = Task { await f.engine.activate(value, permit: first, autoplay: true, volume: 0.5) }
        await f.clock.waitForSleep()
        let scope = f.scope(intent: 2, generation: 2); let next = try f.retarget(first, scope)
        f.factory.driver.readiness = .ready
        let replacement = try await f.prepared(scope)
        try await f.engine.activate(replacement, permit: next, autoplay: true, volume: 0.5).get()
        let result = await task.value
        #expect(testLocalIssue(result) == .stale)
        #expect(f.coordinator.retireOutput(first) == nil)
        #expect(f.factory.driver.frame.control == .playing && !f.engine.isOutputRetired)
        f.coordinator.quiesce()
    }

    @Test func seekTimeoutAndOldCompletionCannotChangeAReplacementOccurrence() async throws {
        let f = LocalAudioEngineFixture(); let first = try await f.start()
        let command = try f.retarget(first, f.scope(intent: 2, itemID: first.scope.itemID))
        f.factory.driver.autoSeek = false
        let task = Task { await f.engine.seek(30, permit: command) }
        await f.factory.driver.waitSeek()
        let completion = try #require(f.factory.driver.seekCompletion)
        let scope = f.scope(intent: 3, generation: 2); let next = try f.retarget(command, scope)
        let replacement = try await f.prepared(scope)
        try await f.engine.activate(replacement, permit: next, autoplay: true, volume: 0.5).get()
        completion(true)
        let result = await task.value
        #expect(testLocalIssue(result) == .stale)
        #expect(f.factory.driver.frame.position == 0 && f.factory.driver.frame.control == .playing)
        f.coordinator.quiesce()
    }

    @Test func retirementIsPermanentAndBlockedDeadlineRetainsUntilExactNativeQuiet() async throws {
        let f = LocalAudioEngineFixture(); let permit = try await f.start()
        f.factory.driver.refuseQuiet = true
        let operation = try #require(f.coordinator.retireOutput(permit))
        #expect(f.engine.isOutputRetired && !operation.isConfirmedQuiet)
        await f.clock.waitForSleep(); await f.clock.fire()
        let receipt = await operation.settle()
        #expect(receipt.outcome == .blocked(.timedOut))
        let count = f.factory.driver.calls.count
        _ = f.engine.play(permit: permit); _ = f.engine.setVolume(1, permit: permit)
        _ = await f.engine.seek(10, permit: permit)
        #expect(f.factory.driver.calls.count == count)
        f.factory.driver.frame = .init(hasPlayer: true)
        f.factory.driver.signalOutput()
        #expect(operation.isConfirmedQuiet)
        #expect(operation.receipt?.outcome == .blocked(.timedOut))
    }

    @Test func nativeItemLifetimeOutlivesQuietAndKeepsReferenceAndProfileInUse() async throws {
        let f = LocalAudioEngineFixture(); let permit = try await f.start()
        f.factory.driver.retainsDetached = true
        let operation = try #require(f.coordinator.retireOutput(permit))
        #expect(operation.isConfirmedQuiet)
        #expect(f.references.useCount(f.reference) > 0 && f.holds.count > 0)
        #expect(throws: LocalAudioPlaybackIssue.busy) { try f.references.reserveRemoval(f.reference) }
        f.factory.driver.retained = []
        #expect(f.references.useCount(f.reference) == 0 && f.holds.count == 0)
    }

    @Test func retiringUnusedEngineNeverConstructsNativeDriver() async {
        let f = LocalAudioEngineFixture()
        let operation = f.engine.revokeOutput()
        let receipt = await operation.settle()
        #expect(receipt.outcome == .confirmed && f.factory.drivers.isEmpty)
    }
}

func testLocalIssue<T>(_ result: Result<T, LocalAudioPlaybackIssue>) -> LocalAudioPlaybackIssue? {
    if case let .failure(issue) = result { issue } else { nil }
}
