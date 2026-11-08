import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

private typealias Radio = RadioQueueState<String>
private struct ServiceFailure: Error {}

private func song(_ id: String) -> Track { Track(id: id, title: "Song \(id)", artist: "Artist", duration: 180) }

/// A queue and its radio state, driven the way the session drives them.
private final class Harness {
    var radio = Radio()
    var queue = PlaybackQueue()
    var account = UUID()

    /// Plays the last of these songs, as after choosing one song.
    @discardableResult
    func start(_ ids: [String]) throws -> PlaybackOccurrence {
        queue = PlaybackQueue()
        let occurrence = queue.replace(with: ids.map(song), startAt: ids.count - 1)
        return try #require(occurrence)
    }

    func prefetch(autoplay: Bool = true) -> Radio.Request? {
        radio.prefetch(for: queue, account: account, autoplay: autoplay)
    }

    func end(_ occurrence: PlaybackOccurrence, autoplay: Bool = true) -> Radio.Outcome {
        radio.handleEnd(of: occurrence, in: &queue, account: account, autoplay: autoplay)
    }

    func retry() -> Radio.Outcome { radio.retryAtEnd(of: &queue, account: account, autoplay: true) }

    func finish(_ request: Radio.Request, _ ids: [String], continuation: String? = nil, playing: Bool = true,
                account: UUID? = nil) -> Radio.Outcome {
        radio.complete(request, with: .success(Radio.Batch(tracks: ids.map(song), continuation: continuation)),
                       queue: &queue, account: account ?? self.account, continuesPlayback: playing)
    }

    func fail(_ request: Radio.Request) -> Radio.Outcome {
        radio.complete(request, with: .failure(ServiceFailure()), queue: &queue, account: account, continuesPlayback: true)
    }

    var ids: [String] { queue.entries.map(\.track.id) }
}

private func played(_ outcome: Radio.Outcome) -> PlaybackOccurrence? {
    if case let .play(occurrence) = outcome { occurrence } else { nil }
}
private func fetched(_ outcome: Radio.Outcome) -> Radio.Request? {
    if case let .wait(request) = outcome { request } else { nil }
}
private func relatedSeed(_ request: Radio.Request?) -> String? {
    if case let .related(track)? = request?.source { track.id } else { nil }
}
private func isNone(_ outcome: Radio.Outcome) -> Bool { if case .none = outcome { true } else { false } }
private func isAppended(_ outcome: Radio.Outcome) -> Bool { if case .appended = outcome { true } else { false } }
private func isOrdinaryStop(_ outcome: Radio.Outcome) -> Bool { if case .stop(nil) = outcome { true } else { false } }
private func isFailureStop(_ outcome: Radio.Outcome) -> Bool { if case .stop(.failed?) = outcome { true } else { false } }
private func isEmptyStop(_ outcome: Radio.Outcome) -> Bool { if case .stop(.nothingFound?) = outcome { true } else { false } }

@Suite("Radio and autoplay")
struct RadioQueueStateTests {
    @Test func theQueueContinuesPastItsEndWithPrefetchedSongs() throws {
        let test = Harness()
        let started = test.queue.replace(with: [song("a"), song("b")], startAt: 0)
        let first = try #require(started)
        #expect(test.prefetch() == nil, "Only the last entry prefetches.")

        let last = try #require(played(test.end(first)))
        let request = try #require(test.prefetch())
        #expect(relatedSeed(request) == "b")
        #expect(test.prefetch() == nil, "One request per queue arrangement.")
        #expect(isNone(test.finish(request, ["b", "c", "a", "d", "c"])))
        #expect(test.ids == ["a", "b"], "Prefetched songs wait for the end of the queue.")

        let next = try #require(played(test.end(last)))
        // The seed, songs already queued, and repeats within the result are skipped.
        #expect(test.ids == ["a", "b", "c", "d"])
        #expect(next.trackID == "c")
        #expect(next.entryID == test.queue.entries[2].id)
        #expect(test.queue.accepts(next))
        #expect(!test.queue.accepts(last))
    }

    @Test func anEndWithoutPrefetchWaitsAndThenContinues() throws {
        let test = Harness()
        let occurrence = try test.start(["a"])
        let request = try #require(fetched(test.end(occurrence)))
        #expect(relatedSeed(request) == "a")
        #expect(test.radio.isWaitingAtQueueEnd)
        #expect(isNone(test.end(occurrence)), "A repeated ending report changes nothing.")

        let next = try #require(played(test.finish(request, ["a", "x", "y"])))
        #expect(next.trackID == "x")
        #expect(test.ids == ["a", "x", "y"])
        #expect(!test.radio.isWaitingAtQueueEnd)
    }

    @Test func aPauseWhileWaitingAddsSongsWithoutPlaying() throws {
        let test = Harness()
        let request = try #require(fetched(test.end(try test.start(["a"]))))
        #expect(isAppended(test.finish(request, ["x"], playing: false)))
        #expect(test.ids == ["a", "x"])
        #expect(test.queue.currentOccurrence == nil)
        #expect(test.queue.currentTrack?.id == "a")
    }

    @Test func replayingTheLastSongWhileWaitingKeepsTheResultForItsEnd() throws {
        let test = Harness()
        let request = try #require(fetched(test.end(try test.start(["a"]))))
        let replayed = test.queue.beginPlayback()
        let replay = try #require(replayed)
        #expect(test.prefetch() == nil, "The pending request still applies.")
        #expect(!test.radio.isWaitingAtQueueEnd)
        #expect(isNone(test.finish(request, ["x"])))
        #expect(test.queue.currentOccurrence == replay, "The replay is not interrupted.")
        #expect(test.ids == ["a"])

        let next = try #require(played(test.end(replay)))
        #expect(next.trackID == "x")
    }

    @Test func resultsForAnEditedQueueAreDiscarded() throws {
        let test = Harness()
        try test.start(["a"])
        let request = try #require(test.prefetch())
        test.queue.append([song("z")])
        #expect(isNone(test.finish(request, ["x"])))
        #expect(test.ids == ["a", "z"])
    }

    @Test func resultsForAReplacedQueueAreDiscardedEvenForTheSameSong() throws {
        let test = Harness()
        try test.start(["a"])
        let request = try #require(test.prefetch())
        _ = test.queue.replace(with: [song("a")], startAt: 0)
        #expect(isNone(test.finish(request, ["x"])))
        #expect(test.ids == ["a"])
        let fresh = try #require(test.prefetch(), "The new queue gets its own request.")
        #expect(fresh.revision == test.queue.revision)
    }

    @Test func resultsAfterAnAccountChangeAreDiscarded() throws {
        let test = Harness()
        let request = try #require(fetched(test.end(try test.start(["a"]))))
        #expect(isNone(test.finish(request, ["x"], account: UUID())))
        #expect(test.ids == ["a"])
    }

    @Test func anEditWhileWaitingDiscardsTheSongsAndStaysStopped() throws {
        let test = Harness()
        let request = try #require(fetched(test.end(try test.start(["a"]))))
        test.queue.append([song("z")])
        #expect(isNone(test.finish(request, ["x"])))
        #expect(test.ids == ["a", "z"])
        #expect(test.queue.currentOccurrence == nil)
    }

    @Test func aSupersededRequestIsIgnored() throws {
        let test = Harness()
        try test.start(["a"])
        let old = try #require(test.prefetch())
        let collection = test.radio.startCollectionRadio(playlistID: "RDAMPLexample", queue: test.queue, account: test.account)
        #expect(isNone(test.finish(old, ["x"])))
        #expect(test.radio.inFlight == collection)
        #expect(test.ids == ["a"])
    }

    @Test func repeatOneAndRepeatAllNeverReachAutoplay() throws {
        let test = Harness()
        let occurrence = try test.start(["a", "b"])
        test.queue.repeatMode = .one
        #expect(test.prefetch() == nil)
        let again = try #require(played(test.end(occurrence)))
        #expect(again.entryID == occurrence.entryID)
        #expect(again != occurrence)

        test.queue.repeatMode = .all
        #expect(test.prefetch() == nil)
        let wrapped = try #require(played(test.end(again)))
        #expect(wrapped.entryID == test.queue.entries[0].id)
        #expect(test.ids == ["a", "b"])
        #expect(test.radio.inFlight == nil)
    }

    @Test func withAutoplayOffTheQueueStopsAtItsEnd() throws {
        let test = Harness()
        let occurrence = try test.start(["a"])
        #expect(test.prefetch(autoplay: false) == nil)
        #expect(isOrdinaryStop(test.end(occurrence, autoplay: false)))
        #expect(test.radio.inFlight == nil)
        #expect(test.ids == ["a"])
    }

    @Test func aRestoredQueueNeitherPrefetchesNorContinues() throws {
        let test = Harness()
        let occurrence = try test.start(["a", "b"])
        let saved = test.queue.snapshot(resumePosition: 30)
        #expect(isNone(test.retry()), "A playing queue has nothing to retry.")

        test.queue = try PlaybackQueue(snapshot: saved)
        #expect(test.queue.currentTrack?.id == "b")
        #expect(test.prefetch() == nil)
        #expect(isNone(test.end(occurrence)), "An ending from before the restore is stale.")
        #expect(test.queue.currentOccurrence == nil)
        #expect(test.radio.inFlight == nil)

        test.queue = PlaybackQueue()
        test.queue.replace(with: [song("a")])
        #expect(test.prefetch() == nil, "Loading a queue without playing it requests nothing.")
    }

    @Test func aFailureAtTheEndStopsWithARetryAndNeverLoops() throws {
        let test = Harness()
        let request = try #require(fetched(test.end(try test.start(["a"]))))
        #expect(isFailureStop(test.fail(request)))
        #expect(test.radio.inFlight == nil)
        #expect(!test.radio.isWaitingAtQueueEnd)
        // Nothing requests again on its own, however often the state is checked.
        for _ in 0..<5 { #expect(test.prefetch() == nil) }

        let retry = try #require(fetched(test.retry()))
        #expect(retry != request)
        #expect(isFailureStop(test.fail(retry)))
        #expect(test.radio.inFlight == nil)
        #expect(test.ids == ["a"])
    }

    @Test func aFailedPrefetchIsTriedOnceMoreAtTheEnd() throws {
        let test = Harness()
        let occurrence = try test.start(["a"])
        let prefetch = try #require(test.prefetch())
        #expect(isNone(test.fail(prefetch)))
        #expect(test.prefetch() == nil, "A failed prefetch is not repeated.")
        let atEnd = try #require(fetched(test.end(occurrence)))
        let next = try #require(played(test.finish(atEnd, ["x"])))
        #expect(next.trackID == "x")
    }

    @Test func songsOnlyFromTheRecentQueueStopInsteadOfRepeating() throws {
        let test = Harness()
        let last = try test.start((0..<250).map { "s\($0)" })
        let request = try #require(fetched(test.end(last)))
        #expect(isEmptyStop(test.finish(request, ["s249", "s100", "s100"])))
        #expect(test.queue.entries.count == 250)

        // Songs older than the recent window may return.
        let restarted = test.queue.beginPlayback()
        let again = try #require(restarted)
        let second = try #require(fetched(test.end(again)))
        let next = try #require(played(test.finish(second, ["s10", "s200"])))
        #expect(next.trackID == "s10")
        #expect(test.queue.entries.count == 251)
    }

    @Test func aRadioContinuesWithItsNextPageUntilTheQueueChanges() throws {
        let test = Harness()
        let first = try #require(fetched(test.end(try test.start(["a"]))))
        let x = try #require(played(test.finish(first, ["x", "y"], continuation: "page-2")))
        let y = try #require(played(test.end(x)))
        #expect(y.trackID == "y")
        let next = try #require(test.prefetch())
        guard case let .continuation(token) = next.source else { Issue.record("Expected the radio's next page"); return }
        #expect(token == "page-2")

        test.queue.append([song("mine")])
        _ = test.queue.next()
        #expect(relatedSeed(test.prefetch()) == "mine", "A song the listener added seeds its own radio.")
    }

    @Test func startRadioFromASongAddsItsRadioAfterTheSeed() throws {
        let test = Harness()
        try test.start(["seed"])
        let prefetch = try #require(test.prefetch())
        let separate = test.radio.startSongRadio(in: test.queue, account: test.account)
        #expect(separate == nil, "The autoplay request is reused.")
        #expect(isAppended(test.finish(prefetch, ["seed", "r1", "r2"])))
        #expect(test.ids == ["seed", "r1", "r2"])
        #expect(test.queue.currentTrack?.id == "seed")
        #expect(test.queue.currentOccurrence != nil)
    }

    @Test func startRadioFromASongWorksWithAutoplayOff() throws {
        let test = Harness()
        try test.start(["seed"])
        #expect(test.prefetch(autoplay: false) == nil)
        let started = test.radio.startSongRadio(in: test.queue, account: test.account)
        let request = try #require(started)
        #expect(relatedSeed(request) == "seed")
        #expect(isAppended(test.finish(request, ["seed", "r1"])))
        #expect(test.ids == ["seed", "r1"])
    }

    @Test func startRadioFromACollectionReplacesOnlyAnUnchangedQueue() throws {
        let test = Harness()
        try test.start(["a"])
        let request = test.radio.startCollectionRadio(playlistID: "RDEMexample", queue: test.queue, account: test.account)
        #expect(test.radio.isStartingCollectionRadio)
        #expect(test.prefetch() == nil, "Autoplay waits for the new radio.")
        guard case let .replace(tracks, continuation) = test.finish(request, ["m1", "m2", "m1"], continuation: "next")
        else { Issue.record("Expected a replacement"); return }
        #expect(tracks.map(\.id) == ["m1", "m2"])
        #expect(continuation == "next")

        let edited = test.radio.startCollectionRadio(playlistID: "RDEMexample", queue: test.queue, account: test.account)
        test.queue.append([song("z")])
        #expect(isNone(test.finish(edited, ["m1"])))

        let failing = test.radio.startCollectionRadio(playlistID: "RDEMexample", queue: test.queue, account: test.account)
        guard case .startFailed(.failed) = test.fail(failing) else { Issue.record("Expected a failed start"); return }
        #expect(test.ids == ["a", "z"])
    }

    @Test func turningAutoplayOffWhileWaitingCancelsTheWait() throws {
        let test = Harness()
        let request = try #require(fetched(test.end(try test.start(["a"]))))
        let wasWaiting = test.radio.cancelAutoplay()
        #expect(wasWaiting)
        #expect(!test.radio.isWaitingAtQueueEnd)
        #expect(isNone(test.finish(request, ["x"])))
        #expect(test.ids == ["a"])
    }

    @Test func anExplicitTransportChoiceCancelsAPendingCollectionReplacement() throws {
        let test = Harness()
        let original = try test.start(["a", "b"])
        let request = test.radio.startCollectionRadio(playlistID: "RDEMexample", queue: test.queue, account: test.account)
        let cancelled = test.radio.cancelCollectionRadio()
        #expect(cancelled)
        #expect(!test.radio.isStartingCollectionRadio)
        #expect(isNone(test.finish(request, ["new-radio"], playing: false)))
        #expect(test.ids == ["a", "b"])
        #expect(test.queue.currentOccurrence == original)
    }

    @Test func cancellingACollectionReplacementDoesNotCancelAutoplayPrefetch() throws {
        let test = Harness()
        let original = try test.start(["a"])
        let request = try #require(test.prefetch())
        let cancelled = test.radio.cancelCollectionRadio()
        #expect(!cancelled)
        #expect(isNone(test.finish(request, ["b"])))
        #expect(played(test.end(original))?.trackID == "b")
    }
}
