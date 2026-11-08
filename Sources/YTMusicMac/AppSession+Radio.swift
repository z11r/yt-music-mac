import Foundation
import MusicCore
import Observation
import YouTubeMusic

/// What the player shows about radio work: loading, or why the queue stopped.
struct RadioStatus: Equatable {
    enum Retry: Equatable {
        case autoplay
        case collection(MusicCollection)
    }

    let message: String
    let isLoading: Bool
    let retry: Retry?
    /// A message stops applying once the queue or what it plays changes.
    let revision: QueueRevision
    let occurrence: PlaybackOccurrence?
}

/// Radio state owned by the session. Views read `status` and `autoplayEnabled`.
@MainActor @Observable
final class RadioSession {
    static let autoplayKey = "autoplay"

    private(set) var autoplayEnabled: Bool
    fileprivate(set) var status: RadioStatus?
    @ObservationIgnored fileprivate var state = RadioQueueState<MusicRadioContinuation>()
    @ObservationIgnored fileprivate var task: Task<Void, Never>?
    @ObservationIgnored fileprivate var startingCollection: MusicCollection?
    @ObservationIgnored private let preferences: UserDefaults
    var isStartingCollectionRadio: Bool { state.isStartingCollectionRadio }

    init(preferences: UserDefaults) {
        self.preferences = preferences
        autoplayEnabled = preferences.object(forKey: Self.autoplayKey) as? Bool ?? true
    }

    fileprivate func setAutoplay(_ value: Bool) {
        guard value != autoplayEnabled else { return }
        autoplayEnabled = value
        preferences.set(value, forKey: Self.autoplayKey)
    }

    fileprivate func show(_ value: RadioStatus?) {
        if status != value { status = value }
    }
}

extension AppSession {
    typealias RadioQueue = RadioQueueState<MusicRadioContinuation>

    // MARK: Start Radio

    /// Replaces the queue with the song and plays it, then appends its radio when it arrives.
    func startRadio(from track: Track) {
        guard acceptsProfileActions else { return }
        guard track.origin != .upload, track.contentKind != .podcastEpisode else { return }
        guard account.isSignedIn else { openAccount(); return }
        playTracks([track])
        guard queue.currentTrack?.id == track.id,
              let request = radio.state.startSongRadio(in: queue, account: accountGeneration) else {
            updateRadioStatus()
            return
        }
        loadRadio(request)
    }

    /// Replaces the queue with the radio the service offered for the collection, once it loads.
    func startRadio(from collection: MusicCollection) {
        guard acceptsProfileActions else { return }
        guard !collection.isUploaded, collection.kind != .podcast, let playlistID = collection.radioPlaylistID else { return }
        guard account.isSignedIn else { openAccount(); return }
        collectionPlayback.cancel()
        sleepTimer.allowPlayback()
        radio.startingCollection = collection
        loadRadio(radio.state.startCollectionRadio(playlistID: playlistID, queue: queue, account: accountGeneration))
    }

    // MARK: Autoplay

    func setAutoplayEnabled(_ value: Bool) {
        guard acceptsProfileActions else { return }
        radio.setAutoplay(value)
        if value {
            prepareQueueContinuation()
            return
        }
        if radio.status?.retry == .autoplay { radio.show(nil) }
        if radio.state.cancelAutoplay() {
            wantsPlayback = false
            player.stop()
            saveQueue()
        }
        updateRadioStatus()
    }

    /// Continues after the accepted ending of `occurrence`: the next entry, related songs, or a stop.
    func continueQueue(after occurrence: PlaybackOccurrence) {
        guard acceptsProfileActions else { return }
        apply(radio.state.handleEnd(of: occurrence, in: &queue, account: accountGeneration, autoplay: autoplayAllowed))
    }

    /// Loads related songs ahead of the queue end. Called whenever the queue or playback state is saved.
    func prepareQueueContinuation() {
        guard acceptsProfileActions else { return }
        if let request = radio.state.prefetch(for: queue, account: accountGeneration, autoplay: autoplayAllowed) {
            loadRadio(request)
        } else {
            updateRadioStatus()
        }
    }

    func retryRadio() {
        guard acceptsProfileActions else { return }
        collectionPlayback.cancel()
        guard let retry = radio.status?.retry else { return }
        radio.show(nil)
        switch retry {
        case .autoplay:
            guard account.isSignedIn else { openAccount(); return }
            let outcome = radio.state.retryAtEnd(of: &queue, account: accountGeneration, autoplay: autoplayAllowed)
            switch outcome {
            case .play, .wait: wantsPlayback = true
            default: break
            }
            apply(outcome)
        case let .collection(collection):
            startRadio(from: collection)
        }
    }

    /// Forgets all radio work, for sign-out and account changes.
    func cancelRadio() {
        radio.task?.cancel()
        radio.task = nil
        radio.state.reset()
        radio.startingCollection = nil
        radio.show(nil)
    }

    /// A radio requested for a collection must not replace a later transport choice.
    func cancelPendingCollectionRadio() {
        guard radio.state.cancelCollectionRadio() else { return }
        radio.task?.cancel()
        radio.task = nil
        radio.startingCollection = nil
        radio.show(nil)
    }

    // MARK: Requests

    private var autoplayAllowed: Bool {
        currentTrack?.origin != .upload && currentTrack?.contentKind != .podcastEpisode && radio.autoplayEnabled && wantsPlayback && account.isSignedIn && !isSceneCheck &&
            !sleepTimer.blocksAutoplay && !collectionPlayback.isLoading && !collectionPlayback.canRetry
    }

    private func loadRadio(_ request: RadioQueue.Request) {
        radio.task?.cancel()
        radio.task = Task { [weak self, client] in
            let result: Result<RadioQueue.Batch, any Error>
            do {
                let page: MusicRadioPage
                switch request.source {
                case let .related(track): page = try await client.radio(videoID: track.id)
                case let .continuation(next): page = try await client.nextRadioPage(next)
                case let .collection(playlistID): page = try await client.radio(playlistID: playlistID)
                }
                result = .success(RadioQueue.Batch(tracks: page.tracks, continuation: page.continuation))
            } catch { result = .failure(error) }
            self?.radioRequestFinished(request, result: result)
        }
        updateRadioStatus()
    }

    private func radioRequestFinished(_ request: RadioQueue.Request, result: Result<RadioQueue.Batch, any Error>) {
        apply(radio.state.complete(request, with: result, queue: &queue, account: accountGeneration,
                                   continuesPlayback: wantsPlayback))
    }

    private func apply(_ outcome: RadioQueue.Outcome) {
        switch outcome {
        case .none, .wait(fetch: nil):
            break
        case let .wait(fetch: request?):
            loadRadio(request)
        case let .play(occurrence):
            request(occurrence)
        case .appended:
            saveQueue()
        case let .replace(tracks, continuation):
            radio.startingCollection = nil
            playTracks(tracks, origin: .radio)
            radio.state.didReplaceQueue(queue, continuation: continuation)
        case let .stop(reason):
            episodePlayback.clearPlayback()
            wantsPlayback = false
            player.stop()
            saveQueue()
            if let reason { radio.show(failure(reason, retry: .autoplay)) }
        case let .startFailed(reason):
            radio.show(failure(reason, retry: radio.startingCollection.map { .collection($0) }))
            radio.startingCollection = nil
        }
        updateRadioStatus()
    }

    private func failure(_ reason: RadioQueue.StopReason, retry: RadioStatus.Retry?) -> RadioStatus {
        let isAutoplay = retry == .autoplay
        let message: String
        let offersRetry: Bool
        switch reason {
        case let .failed(error):
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            message = isAutoplay ? AppLocalization.format("Autoplay could not load related songs. %@", detail)
                                 : AppLocalization.format("This radio could not start. %@", detail)
            offersRetry = true
        case .nothingFound:
            message = isAutoplay ? AppLocalization.text("Autoplay found no new related songs, so playback stopped.")
                                 : AppLocalization.text("YouTube Music offered no songs for this radio.")
            offersRetry = false
        }
        return RadioStatus(message: message, isLoading: false, retry: offersRetry ? retry : nil,
                           revision: queue.revision, occurrence: queue.currentOccurrence)
    }

    private func updateRadioStatus() {
        let loading: String? = if radio.state.isWaitingAtQueueEnd { AppLocalization.text("Finding related songs…") }
            else if radio.state.isStartingCollectionRadio { AppLocalization.text("Starting radio…") } else { nil }
        if let loading {
            radio.show(RadioStatus(message: loading, isLoading: true, retry: nil,
                                   revision: queue.revision, occurrence: queue.currentOccurrence))
        } else if let status = radio.status,
                  status.isLoading || status.revision != queue.revision || status.occurrence != queue.currentOccurrence {
            radio.show(nil)
        }
    }
}
