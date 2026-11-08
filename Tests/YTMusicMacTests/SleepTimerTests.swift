import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

private func occurrence(entry: UUID = UUID(), session: UUID = UUID(), generation: UInt64 = 1) -> PlaybackOccurrence {
    PlaybackOccurrence(sessionID: session, entryID: entry, trackID: "same-song", generation: generation)
}

@Suite("Sleep timer decisions")
struct SleepTimerStateTests {
    @Test func aDeadlineExpiresOnceAndBlocksAutoplayUntilExplicitPlayback() {
        let now = ContinuousClock.now
        var timer = SleepTimerState()
        let armed = timer.arm(after: .seconds(900), now: now)
        let early = timer.expireIfNeeded(at: now.advanced(by: .seconds(899)))
        let expired = timer.expireIfNeeded(at: now.advanced(by: .seconds(900)))
        let repeated = timer.expireIfNeeded(at: now.advanced(by: .seconds(901)))
        #expect(armed && !early && expired && !repeated)
        #expect(timer.schedule == .off && timer.blocksAutoplay)
        timer.allowPlayback()
        #expect(!timer.blocksAutoplay)
    }

    @Test func anOverdueTimerExpiresWhenTheClockIsCheckedAfterWake() {
        let now = ContinuousClock.now
        var timer = SleepTimerState()
        timer.arm(after: .seconds(60), now: now)
        let expired = timer.expireIfNeeded(at: now.advanced(by: .seconds(7_200)))
        #expect(expired && timer.blocksAutoplay)
    }

    @Test func invalidDurationsLeaveAnExistingTimerIntact() {
        let now = ContinuousClock.now
        var timer = SleepTimerState()
        timer.arm(after: .seconds(60), now: now)
        let expected = timer
        for duration in [Duration.zero, .seconds(-1), .seconds(86_401)] {
            let armed = timer.arm(after: duration, now: now)
            #expect(!armed && timer == expected)
        }
    }

    @Test func cancellationDisarmsExpiryAndClearsItsAutoplayLatch() {
        let now = ContinuousClock.now
        var timer = SleepTimerState()
        timer.arm(after: .seconds(60), now: now)
        timer.cancel()
        let expired = timer.expireIfNeeded(at: now.advanced(by: .seconds(120)))
        #expect(!expired && !timer.blocksAutoplay && timer.schedule == .off)
    }

    @Test func endOfSongMatchesTheExactOccurrence() {
        let selected = occurrence()
        let newer = occurrence(entry: selected.entryID, session: selected.sessionID, generation: 2)
        var timer = SleepTimerState()
        timer.armAtEnd(of: selected)
        let stale = timer.consumeEnd(newer)
        let ending = timer.consumeEnd(selected)
        #expect(!stale && ending && timer.blocksAutoplay)
    }

    @Test func retryingTheSameEntryRebindsItsEndTimer() {
        let selected = occurrence()
        let retry = occurrence(entry: selected.entryID, session: selected.sessionID, generation: 2)
        var timer = SleepTimerState()
        timer.armAtEnd(of: selected)
        timer.bind(to: retry)
        let stale = timer.consumeEnd(selected)
        let ending = timer.consumeEnd(retry)
        #expect(!stale && ending)
    }

    @Test func switchingToADuplicateSongInAnotherEntryCancelsTheEndTimer() {
        let selected = occurrence()
        let duplicate = occurrence(session: selected.sessionID, generation: 2)
        var timer = SleepTimerState()
        timer.armAtEnd(of: selected)
        timer.bind(to: duplicate)
        let ending = timer.consumeEnd(duplicate)
        #expect(!ending && timer.schedule == .off && !timer.blocksAutoplay)
    }

    @Test func trackChangesDoNotDisarmATimedDeadline() {
        let now = ContinuousClock.now
        var timer = SleepTimerState()
        timer.arm(after: .seconds(60), now: now)
        timer.bind(to: occurrence())
        let ending = timer.consumeEnd(occurrence())
        let expired = timer.expireIfNeeded(at: now.advanced(by: .seconds(60)))
        #expect(!ending && expired)
    }
}

@MainActor private final class TimerClock {
    var instant = ContinuousClock.now
    var date = Date(timeIntervalSince1970: 1_000)
}

@MainActor @Suite("Sleep timer scheduling", .serialized)
struct SleepTimerTests {
    private func makeTimer(_ clock: TimerClock) -> SleepTimer {
        SleepTimer(now: { clock.instant }, wallNow: { clock.date }, sleepUntil: { _ in
            try await Task.sleep(for: .seconds(3_600))
        })
    }

    @Test func wallClockAdjustmentsCannotMoveThePlaybackDeadline() {
        let clock = TimerClock()
        let timer = makeTimer(clock)
        defer { timer.cancel() }
        var pauses = 0
        timer.onExpired = { pauses += 1 }
        timer.start(minutes: 1)
        #expect(timer.displayDeadline == Date(timeIntervalSince1970: 1_060))
        clock.date = clock.date.addingTimeInterval(3_600)
        clock.instant = clock.instant.advanced(by: .seconds(30))
        #expect(!timer.expireIfNeeded())
        clock.date = clock.date.addingTimeInterval(-7_200)
        clock.instant = clock.instant.advanced(by: .seconds(31))
        #expect(timer.expireIfNeeded())
        #expect(!timer.expireIfNeeded())
        #expect(pauses == 1 && timer.blocksAutoplay && !timer.isArmed)
    }

    @Test func replacingAndCancellingTimersCannotExpireAnOlderDeadline() {
        let clock = TimerClock()
        let timer = makeTimer(clock)
        defer { timer.cancel() }
        var pauses = 0
        timer.onExpired = { pauses += 1 }
        timer.start(minutes: 15)
        clock.instant = clock.instant.advanced(by: .seconds(60))
        timer.start(minutes: 30)
        clock.instant = clock.instant.advanced(by: .seconds(900))
        #expect(!timer.expireIfNeeded())
        timer.cancel()
        clock.instant = clock.instant.advanced(by: .seconds(7_200))
        #expect(!timer.expireIfNeeded() && pauses == 0)
    }

    @Test func repeatedEndReportsPauseOnlyOnce() {
        let clock = TimerClock()
        let timer = makeTimer(clock)
        defer { timer.cancel() }
        var pauses = 0
        timer.onExpired = { pauses += 1 }
        let current = occurrence()
        timer.stopAtEnd(of: current)
        #expect(timer.consumeEnd(current))
        #expect(timer.consumeEnd(current))
        #expect(pauses == 1 && timer.blocksAutoplay)
        timer.allowPlayback()
        #expect(!timer.consumeEnd(current))
    }

    @Test(arguments: [RepeatMode.off, .all, .one])
    func endOfSongStopsBeforeQueueAdvanceRepeatOrAutoplay(_ mode: RepeatMode) async throws {
        let preferences = SceneCheckPreferences()
        defer { preferences.remove() }
        let transport = SceneCheckTransport()
        let session = AppSession(configuration: .sceneCheck(preferences: preferences.defaults, transport: transport))
        session.queue.repeatMode = mode
        let selected = session.queue.replace(with: SceneCheckFixture.tracks, startAt: 0)
        let current = try #require(selected)
        session.sleepTimer.stopAtEnd(of: current)
        session.player.onEnded?(current)
        #expect(session.queue.currentIndex == 0)
        #expect(session.queue.currentEntryID == current.entryID)
        #expect(session.queue.currentOccurrence == nil)
        #expect(session.sleepTimer.blocksAutoplay)
        #expect(!session.wantsPlayback && !session.player.playbackIntent)
        #expect(session.radio.status == nil)
        #expect(await transport.attempts == 0)
        let replay = session.queue.beginPlayback()
        #expect(replay?.entryID == current.entryID && replay != current)
        await session.shutdown()
    }

    @Test func armingATimerNeverStartsAPausedSession() async {
        let preferences = SceneCheckPreferences()
        defer { preferences.remove() }
        let transport = SceneCheckTransport()
        let session = AppSession(configuration: .sceneCheck(preferences: preferences.defaults, transport: transport))
        session.sleepTimer.start(minutes: 15)
        #expect(session.sleepTimer.isArmed)
        #expect(!session.wantsPlayback && !session.player.playbackIntent)
        #expect(await transport.attempts == 0)
        await session.shutdown()
        #expect(!session.sleepTimer.isArmed)
        #expect(!session.wantsPlayback && !session.player.playbackIntent)
    }
}
