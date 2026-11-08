import Foundation
import MusicCore

/// Decides how a queue continues past its end and where radio results go.
///
/// The session performs the network requests and playback; this type owns the
/// decisions and the queue edits, so they can be tested without either. Every
/// request records the queue revision and account it was made for. A result is
/// used only while both still match: a queue that was replaced or edited in the
/// meantime never receives songs chosen for an earlier arrangement.
struct RadioQueueState<Continuation: Sendable> {
    /// How many of the queue's last entries count as recently queued.
    static var recentLimit: Int { 200 }

    enum Source: Sendable {
        /// The radio of a song.
        case related(Track)
        /// The next page of the radio whose songs end the queue.
        case continuation(Continuation)
        /// A radio the service offered for an album, playlist, or artist.
        case collection(playlistID: String)
    }

    enum Purpose: Equatable, Sendable {
        /// Loaded before the last entry ends and kept until it does.
        case autoplay
        /// Start Radio from a song: appended as soon as it arrives.
        case songRadio
        /// Start Radio from a collection: replaces the queue.
        case collectionRadio
    }

    struct Request: Sendable {
        let id = UUID()
        let source: Source
        fileprivate(set) var purpose: Purpose
        let revision: QueueRevision
        let seedEntryID: UUID?
        let account: UUID
    }

    struct Batch: Sendable {
        let tracks: [Track]
        let continuation: Continuation?
    }

    enum StopReason {
        case failed(any Error)
        case nothingFound
    }

    enum Outcome {
        /// Nothing for the session to do: a stale or repeated event, or a result kept for later.
        case none
        /// Play this occurrence.
        case play(PlaybackOccurrence)
        /// The queue ended and related songs are loading. Start `fetch` when one is given.
        case wait(fetch: Request?)
        /// Songs were added without changing what plays.
        case appended
        /// Start Radio from a collection finished: replace the queue with these songs.
        case replace([Track], continuation: Continuation?)
        /// Stop at the end of the queue. Without a reason this is an ordinary end.
        case stop(StopReason?)
        /// Start Radio from a collection did not produce songs. The current queue is unchanged.
        case startFailed(StopReason)
    }

    private(set) var inFlight: Request?
    private var prefetched: (request: Request, batch: Batch)?
    private var failedPrefetch: Request?
    private var waiting = false
    /// The radio whose page ends the queue, so the next request continues it instead of starting over.
    private var tail: (entryID: UUID, continuation: Continuation)?

    var isWaitingAtQueueEnd: Bool { waiting && inFlight != nil }
    var isStartingCollectionRadio: Bool { inFlight?.purpose == .collectionRadio }

    /// A request to load related songs while the last entry plays. Never for a restored, unplayed queue.
    mutating func prefetch(for queue: PlaybackQueue, account: UUID, autoplay: Bool) -> Request? {
        if waiting, queue.currentOccurrence != nil { waiting = false }
        guard autoplay, queue.repeatMode == .off, queue.currentOccurrence != nil,
              let last = queue.entries.last, queue.currentEntryID == last.id else { return nil }
        if let inFlight, inFlight.purpose == .collectionRadio || isCurrent(inFlight, queue: queue, account: account) { return nil }
        if let prefetched, isCurrent(prefetched.request, queue: queue, account: account) { return nil }
        if let failedPrefetch, isCurrent(failedPrefetch, queue: queue, account: account) { return nil }
        prefetched = nil
        let request = makeRequest(.autoplay, after: last, queue: queue, account: account)
        inFlight = request
        return request
    }

    /// Applies the end of `occurrence`: the queue's own next entry, related songs, or a stop.
    mutating func handleEnd(of occurrence: PlaybackOccurrence, in queue: inout PlaybackQueue,
                            account: UUID, autoplay: Bool) -> Outcome {
        guard queue.accepts(occurrence) else { return .none }
        if let next = queue.handleEnd(occurrence: occurrence) { return .play(next) }
        return continueAtEnd(of: &queue, account: account, autoplay: autoplay)
    }

    /// Tries once more after the queue stopped at its end, for an explicit retry.
    mutating func retryAtEnd(of queue: inout PlaybackQueue, account: UUID, autoplay: Bool) -> Outcome {
        guard queue.currentOccurrence == nil else { return .none }
        return continueAtEnd(of: &queue, account: account, autoplay: autoplay)
    }

    /// Start Radio from the song the queue now plays. Reuses a matching request already loading.
    mutating func startSongRadio(in queue: PlaybackQueue, account: UUID) -> Request? {
        guard queue.currentOccurrence != nil, let seed = queue.currentEntry else { return nil }
        if var pending = inFlight, isCurrent(pending, queue: queue, account: account), pending.seedEntryID == seed.id,
           case let .related(track) = pending.source, track.id == seed.track.id {
            pending.purpose = .songRadio
            inFlight = pending
            return nil
        }
        let request = Request(source: .related(seed.track), purpose: .songRadio, revision: queue.revision,
                              seedEntryID: seed.id, account: account)
        inFlight = request
        waiting = false
        return request
    }

    /// Start Radio from a collection. Its songs replace the queue if the queue is unchanged when they arrive.
    mutating func startCollectionRadio(playlistID: String, queue: PlaybackQueue, account: UUID) -> Request {
        let request = Request(source: .collection(playlistID: playlistID), purpose: .collectionRadio,
                              revision: queue.revision, seedEntryID: nil, account: account)
        inFlight = request
        waiting = false
        return request
    }

    /// Applies a finished request. `continuesPlayback` is false when the listener paused while it loaded.
    mutating func complete(_ request: Request, with result: Result<Batch, any Error>, queue: inout PlaybackQueue,
                           account: UUID, continuesPlayback: Bool) -> Outcome {
        guard let current = inFlight, current.id == request.id else { return .none }
        inFlight = nil
        let wasWaiting = waiting
        waiting = false
        guard isCurrent(current, queue: queue, account: account) else { return .none }
        let atEnd = wasWaiting && queue.currentOccurrence == nil && queue.currentEntryID == current.seedEntryID
        switch (current.purpose, result) {
        case let (.collectionRadio, .failure(error)):
            return .startFailed(.failed(error))
        case let (.collectionRadio, .success(batch)):
            let tracks = Self.newTracks(batch.tracks, for: PlaybackQueue())
            return tracks.isEmpty ? .startFailed(.nothingFound) : .replace(tracks, continuation: batch.continuation)
        case let (_, .failure(error)):
            if atEnd { return .stop(.failed(error)) }
            failedPrefetch = current
            return .none
        case let (_, .success(batch)):
            if atEnd {
                guard !append(batch, to: &queue).isEmpty else { return .stop(.nothingFound) }
                guard continuesPlayback, let next = queue.next() else { return .appended }
                return .play(next)
            }
            if current.purpose == .songRadio { return append(batch, to: &queue).isEmpty ? .none : .appended }
            prefetched = (current, batch)
            return .none
        }
    }

    /// Records the radio continuation after the session replaced the queue with a collection radio.
    mutating func didReplaceQueue(_ queue: PlaybackQueue, continuation: Continuation?) {
        tail = pair(queue.entries.last?.id, continuation)
    }

    /// Drops loaded and loading related songs, keeping a Start Radio request. Returns whether the queue was waiting.
    mutating func cancelAutoplay() -> Bool {
        let wasWaiting = isWaitingAtQueueEnd
        if inFlight?.purpose == .autoplay { inFlight = nil }
        prefetched = nil
        failedPrefetch = nil
        waiting = false
        return wasWaiting
    }

    mutating func reset() { self = Self() }

    /// Songs not among the queue's recent entries, without repeats.
    static func newTracks(_ tracks: [Track], for queue: PlaybackQueue) -> [Track] {
        var seen = Set(queue.entries.suffix(recentLimit).map(\.track.id))
        return tracks.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    private mutating func continueAtEnd(of queue: inout PlaybackQueue, account: UUID, autoplay: Bool) -> Outcome {
        guard autoplay, queue.repeatMode == .off, queue.currentOccurrence == nil,
              let last = queue.entries.last, queue.currentEntryID == last.id else { return .stop(nil) }
        if let stored = prefetched, isCurrent(stored.request, queue: queue, account: account) {
            prefetched = nil
            guard !append(stored.batch, to: &queue).isEmpty, let next = queue.next() else { return .stop(.nothingFound) }
            return .play(next)
        }
        // A collection radio is about to replace this queue.
        if inFlight?.purpose == .collectionRadio { return .stop(nil) }
        waiting = true
        if let inFlight, isCurrent(inFlight, queue: queue, account: account) { return .wait(fetch: nil) }
        failedPrefetch = nil
        let request = makeRequest(.autoplay, after: last, queue: queue, account: account)
        inFlight = request
        return .wait(fetch: request)
    }

    private mutating func append(_ batch: Batch, to queue: inout PlaybackQueue) -> [QueueEntry] {
        let added = queue.append(Self.newTracks(batch.tracks, for: queue))
        if let last = added.last { tail = batch.continuation.map { (last.id, $0) } }
        return added
    }

    private func makeRequest(_ purpose: Purpose, after last: QueueEntry, queue: PlaybackQueue, account: UUID) -> Request {
        let source: Source = if let tail, tail.entryID == last.id { .continuation(tail.continuation) } else { .related(last.track) }
        return Request(source: source, purpose: purpose, revision: queue.revision, seedEntryID: last.id, account: account)
    }

    private func isCurrent(_ request: Request, queue: PlaybackQueue, account: UUID) -> Bool {
        request.revision == queue.revision && request.account == account
    }
}

private func pair<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
    guard let first, let second else { return nil }
    return (first, second)
}
