import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

struct PlaybackResumeTests {
    private let song = Track(id: "resume-song", title: "Song", artist: "Artist", duration: 240)

    @Test func failedRestoreAndShutdownPreserveTheSavedPositionOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        var original = PlaybackQueue()
        original.replace(with: [song])
        try await store.save(original.snapshot(resumePosition: 120))

        let saved = try #require(try await store.load())
        var queue = try PlaybackQueue(snapshot: saved)
        var recovery = PlaybackResumeState()
        recovery.restore(saved)
        let position = recovery.position(for: queue, playerPosition: 0)
        let occurrenceRequest = queue.beginPlayback()
        let occurrence = try #require(occurrenceRequest)
        recovery.begin(occurrence, recovering: position)

        // Loading, a failed page, and shutdown all report zero before the requested seek succeeds.
        for confirmed in [false, false, true] {
            let snapshot = recovery.snapshot(queue: queue, playerPosition: 0, playerDuration: 0,
                                             positionConfirmed: confirmed)
            try await store.save(snapshot)
        }

        let reopened = try #require(try await store.load())
        #expect(reopened.resumePosition == 120)
        #expect(reopened.currentEntryID == saved.currentEntryID)
        #expect(try PlaybackQueue(snapshot: reopened).currentOccurrence == nil)
    }

    @Test func retryUsesRetainedPositionUntilTheNewOccurrenceConfirmsItsSeek() throws {
        var queue = PlaybackQueue()
        let firstRequest = queue.replace(with: [song], startAt: 0)
        let first = try #require(firstRequest)
        var recovery = PlaybackResumeState()
        recovery.begin(first, recovering: 80)
        let savedPosition1 = recovery.snapshot(queue: queue, playerPosition: 0, playerDuration: 240,
                                  positionConfirmed: true).resumePosition
        #expect(savedPosition1 == 80)

        let retryPosition = recovery.position(for: queue, playerPosition: 0)
        let retryRequest = queue.beginPlayback()
        let retry = try #require(retryRequest)
        #expect(retry != first)
        recovery.begin(retry, recovering: retryPosition)
        let savedPosition2 = recovery.snapshot(queue: queue, playerPosition: 3, playerDuration: 240,
                                  positionConfirmed: true).resumePosition
        #expect(savedPosition2 == 80)
        let savedPosition3 = recovery.snapshot(queue: queue, playerPosition: 80.2, playerDuration: 240,
                                  positionConfirmed: false).resumePosition
        #expect(savedPosition3 == 80)

        // A ready seek can finish while paused. Later real clock positions must replace the checkpoint.
        let savedPosition4 = recovery.snapshot(queue: queue, playerPosition: 80.2, playerDuration: 240,
                                  positionConfirmed: true).resumePosition
        #expect(savedPosition4 == 80.2)
        let savedPosition5 = recovery.snapshot(queue: queue, playerPosition: 85, playerDuration: 240,
                                  positionConfirmed: true).resumePosition
        #expect(savedPosition5 == 85)
    }

    @Test func automaticRecoveryRetainsThePointThroughOldAndFreshPageClocks() throws {
        var queue = PlaybackQueue()
        let occurrenceRequest = queue.replace(with: [song], startAt: 0)
        let occurrence = try #require(occurrenceRequest)
        var recovery = PlaybackResumeState()
        let recoveryResult16 = recovery.recover(occurrence, queue: queue, playerPosition: 75)
        #expect(recoveryResult16 == 75)

        // A paused navigation retains the old display clock, but that clock is not confirmation.
        let savedPosition6 = recovery.snapshot(queue: queue, playerPosition: 75, playerDuration: 240,
                                  positionConfirmed: false).resumePosition
        #expect(savedPosition6 == 75)
        let freshPage = recovery.snapshot(queue: queue, playerPosition: 0, playerDuration: 240,
                                          positionConfirmed: true)
        let persisted = try JSONDecoder().decode(QueueSnapshot.self, from: JSONEncoder().encode(freshPage))
        #expect(persisted.resumePosition == 75)

        // A further recovery before the pending seek succeeds must request the retained point again.
        let recoveryResult17 = recovery.recover(occurrence, queue: queue, playerPosition: 0)
        #expect(recoveryResult17 == 75)
        let savedPosition7 = recovery.snapshot(queue: queue, playerPosition: 75, playerDuration: 240,
                                  positionConfirmed: true).resumePosition
        #expect(savedPosition7 == 75)
        #expect(recovery.position(for: queue, playerPosition: 76) == 76)
    }

    @Test func anOldOccurrenceCannotReplaceAnActiveRecoveryPoint() throws {
        var queue = PlaybackQueue()
        let oldRequest = queue.replace(with: [song], startAt: 0)
        let old = try #require(oldRequest)
        let currentRequest = queue.beginPlayback()
        let current = try #require(currentRequest)
        var recovery = PlaybackResumeState()
        recovery.begin(current, recovering: 120)
        let recoveryResult18 = recovery.recover(old, queue: queue, playerPosition: 5)
        #expect(recoveryResult18 == nil)
        #expect(recovery.position(for: queue, playerPosition: 0) == 120)
    }

    @Test func nextDuplicateAndReplayNeverInheritThePreviousRecoveryPoint() throws {
        var queue = PlaybackQueue()
        let firstRequest = queue.replace(with: [song, song], startAt: 0)
        let first = try #require(firstRequest)
        var recovery = PlaybackResumeState()
        recovery.begin(first, recovering: 80)
        let nextRequest = queue.next()
        let next = try #require(nextRequest)
        #expect(next.trackID == first.trackID)
        #expect(next.entryID != first.entryID)
        let savedPosition8 = recovery.snapshot(queue: queue, playerPosition: 0, playerDuration: 0,
                                  positionConfirmed: false).resumePosition
        #expect(savedPosition8 == 0)

        recovery.begin(next, recovering: 40)
        let replayRequest = queue.beginPlayback()
        let replay = try #require(replayRequest)
        #expect(replay.entryID == next.entryID)
        #expect(replay.generation != next.generation)
        let savedPosition9 = recovery.snapshot(queue: queue, playerPosition: 0, playerDuration: 0,
                                  positionConfirmed: false).resumePosition
        #expect(savedPosition9 == 0)
    }

    @Test func manualSeekToStartAndAccountResetClearPendingRecovery() throws {
        var queue = PlaybackQueue()
        let occurrenceRequest = queue.replace(with: [song], startAt: 0)
        let occurrence = try #require(occurrenceRequest)
        var recovery = PlaybackResumeState()
        recovery.begin(occurrence, recovering: 100)
        recovery.clear()
        let savedPosition10 = recovery.snapshot(queue: queue, playerPosition: 0, playerDuration: 240,
                                  positionConfirmed: true).resumePosition
        #expect(savedPosition10 == 0)

        recovery.begin(occurrence, recovering: 100)
        recovery.clear()
        queue = PlaybackQueue()
        let savedPosition11 = recovery.snapshot(queue: queue, playerPosition: 100, playerDuration: 240,
                                  positionConfirmed: false).resumePosition
        #expect(savedPosition11 == 0)
        queue.replace(with: [song])
        #expect(recovery.position(for: queue, playerPosition: 100) == 0)
    }

    @Test func queueEditsPreserveTheCurrentPointButRemovingItsEntryDropsIt() throws {
        var queue = PlaybackQueue()
        let occurrenceRequest = queue.replace(with: [song, song], startAt: 0)
        let occurrence = try #require(occurrenceRequest)
        var recovery = PlaybackResumeState()
        recovery.begin(occurrence, recovering: 90)
        queue.append([song])
        queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        let savedPosition12 = recovery.snapshot(queue: queue, playerPosition: 0, playerDuration: 0,
                                  positionConfirmed: false).resumePosition
        #expect(savedPosition12 == 90)

        queue.remove(entryIDs: [occurrence.entryID])
        let savedPosition13 = recovery.snapshot(queue: queue, playerPosition: 0, playerDuration: 0,
                                  positionConfirmed: false).resumePosition
        #expect(savedPosition13 == 0)
    }

    @Test func shortSavedPointSurvivesZeroAndDurationClampingCanConfirmResume() throws {
        var queue = PlaybackQueue()
        let occurrenceRequest = queue.replace(with: [song], startAt: 0)
        let occurrence = try #require(occurrenceRequest)
        var recovery = PlaybackResumeState()
        recovery.begin(occurrence, recovering: 0.1)
        let savedPosition14 = recovery.snapshot(queue: queue, playerPosition: 0, playerDuration: 240,
                                  positionConfirmed: true).resumePosition
        #expect(savedPosition14 == 0.1)

        recovery.begin(occurrence, recovering: 240)
        let savedPosition15 = recovery.snapshot(queue: queue, playerPosition: 199.95, playerDuration: 200,
                                  positionConfirmed: true).resumePosition
        #expect(savedPosition15 == 199.95)
        #expect(recovery.position(for: queue, playerPosition: 200) == 200)
    }
}
