import AppKit
import MusicCore
import Observation
import WebKit
import YouTubeMusic

enum MusicDestination: Hashable {
    case home, explore, library, likedSongs
    case search(String)
    case collection(MusicCollection)

    var title: String {
        switch self {
        case .home: "Home"
        case .explore: "Explore"
        case .library: "Library"
        case .likedSongs: "Liked Songs"
        case .search: "Search"
        case let .collection(value): value.title
        }
    }
}

@MainActor @Observable
final class AppSession {
    let account: WebSession
    let player: WebPlayer
    private(set) var queue = PlaybackQueue()
    private(set) var destination: MusicDestination = .home
    private(set) var page: MusicPage?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var pageError: String?
    private(set) var queueError: String?
    var searchText = ""
    var collectionFilter = ""
    var showsQueue = false
    var showsAccount = false
    var showsWebPlayer = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    @ObservationIgnored private let client: YouTubeMusicClient
    @ObservationIgnored private let queueStore: QueueStore?
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var started = false
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pageGeneration = UUID()
    @ObservationIgnored private var accountGeneration = UUID()
    @ObservationIgnored private var backHistory: [MusicDestination] = []
    @ObservationIgnored private var forwardHistory: [MusicDestination] = []
    @ObservationIgnored private var resumePosition: TimeInterval = 0
    @ObservationIgnored private var systemMedia: SystemMediaControls?
    @ObservationIgnored private var scriptingPlayGeneration = UUID()

    init() {
        let preferences = AppIdentity.preferences
        self.preferences = preferences
        let store = WKWebsiteDataStore(forIdentifier: AppIdentity.websiteDataIdentifier)
        let credentials = MusicSessionStore()
        account = WebSession(dataStore: store, credentials: credentials, preferences: preferences)
        client = YouTubeMusicClient(sessions: credentials)
        player = WebPlayer(dataStore: store)
        if let directory = try? AppIdentity.applicationSupportDirectory() {
            queueStore = QueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        } else {
            queueStore = nil
            queueError = "The queue cannot be saved because application storage is unavailable."
        }
        player.onEnded = { [weak self] occurrence in self?.ended(occurrence) }
        player.onStateChanged = { [weak self] in
            self?.systemMedia?.refresh()
            self?.saveQueue()
        }
        player.onPageReady = { [weak self] view in
            Task { [weak self, weak view] in
                guard let self, let view else { return }
                await self.account.synchronize(from: view)
            }
        }
        account.onAccountChanged = { [weak self] changed in self?.accountChanged(replacedAccount: changed) }
        account.onSignInCompleted = { [weak self] in
            guard let self, self.showsAccount else { return }
            self.closeAccount()
        }
        systemMedia = SystemMediaControls(session: self)
    }

    var currentTrack: Track? { queue.currentTrack }
    var visibleTracks: [Track] {
        guard let page else { return [] }
        let tracks = page.tracks.isEmpty ? page.sections.flatMap(\.items).compactMap {
            if case let .track(track) = $0 { track } else { nil }
        } : page.tracks
        let query = collectionFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? tracks : tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        let restoreGeneration = accountGeneration
        if let queueStore, !preferences.bool(forKey: "sessionRestoreBlocked") {
            do {
                if let saved = try await queueStore.load(),
                   accountGeneration == restoreGeneration, queue.isEmpty,
                   !preferences.bool(forKey: "sessionRestoreBlocked") {
                    queue = try PlaybackQueue(snapshot: saved)
                    resumePosition = saved.resumePosition
                }
            } catch { queueError = "The saved queue could not be restored. You can start a new queue." }
        }
        let volume = preferences.object(forKey: "volume") as? Double ?? 0.7
        player.setVolume(volume)
        systemMedia?.refresh()
        navigate(to: .home, recordHistory: false)
        await account.restore()
    }

    func navigate(to target: MusicDestination, recordHistory: Bool = true) {
        if recordHistory, target != destination {
            backHistory.append(destination)
            if backHistory.count > 50 { backHistory.removeFirst() }
            forwardHistory.removeAll()
        }
        destination = target
        canGoBack = !backHistory.isEmpty
        canGoForward = !forwardHistory.isEmpty
        collectionFilter = ""
        page = nil
        pageError = nil
        isLoading = true
        isLoadingMore = false
        pageTask?.cancel()
        let generation = UUID()
        pageGeneration = generation
        pageTask = Task { [weak self, client] in
            do {
                let result: MusicPage
                switch target {
                case .home: result = try await client.home()
                case .explore: result = try await client.explore()
                case .library: result = try await client.library()
                case .likedSongs: result = try await client.likedSongs()
                case let .search(query): result = try await client.search(query: query)
                case let .collection(value):
                    switch value.kind {
                    case .album: result = try await client.album(id: value.id)
                    case .artist: result = try await client.artist(id: value.id)
                    case .playlist: result = try await client.playlist(id: value.id)
                    }
                }
                guard let self, !Task.isCancelled, self.pageGeneration == generation else { return }
                self.page = result
                self.isLoading = false
            } catch {
                guard let self, !Task.isCancelled, self.pageGeneration == generation else { return }
                self.pageError = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        navigate(to: .search(query))
    }

    func goBack() {
        guard let target = backHistory.popLast() else { return }
        forwardHistory.append(destination)
        navigate(to: target, recordHistory: false)
    }

    func goForward() {
        guard let target = forwardHistory.popLast() else { return }
        backHistory.append(destination)
        navigate(to: target, recordHistory: false)
    }

    func reload() { navigate(to: destination, recordHistory: false) }

    func loadMore() {
        guard let initial = page, let continuation = initial.continuation, !isLoadingMore else { return }
        isLoadingMore = true
        pageError = nil
        let generation = pageGeneration
        pageTask = Task { [weak self, client] in
            do {
                let next = try await client.nextPage(continuation)
                guard let self, !Task.isCancelled, self.pageGeneration == generation else { return }
                self.page = MusicPage(title: initial.title, sections: initial.sections + next.sections,
                    items: initial.items + next.items, continuation: next.continuation,
                    playlistItems: initial.playlistItems + next.playlistItems)
                self.isLoadingMore = false
            } catch {
                guard let self, !Task.isCancelled, self.pageGeneration == generation else { return }
                self.pageError = error.localizedDescription
                self.isLoadingMore = false
            }
        }
    }

    func activate(_ item: MusicItem) {
        switch item {
        case let .track(track): play(track)
        case let .collection(value): navigate(to: .collection(value))
        }
    }

    func play(_ track: Track) { playTracks([track], startingAt: 0) }

    func beginScriptedPlaybackRequest() -> UUID {
        scriptingPlayGeneration = UUID()
        return scriptingPlayGeneration
    }

    func playScriptedVideo(_ videoID: String, requestGeneration: UUID) async throws -> String {
        guard ScriptingInput.videoID(videoID) == videoID else { throw AppScriptingError.invalidVideoID }
        guard scriptingPlayGeneration == requestGeneration else { throw AppScriptingError.superseded }
        guard account.isSignedIn else { throw AppScriptingError.signInRequired }
        let accountScope = accountGeneration
        let track = try await ScriptedTrackResolver.resolve(videoID: videoID) { [client] query in
            try await client.search(query: query)
        }
        guard scriptingPlayGeneration == requestGeneration, accountGeneration == accountScope,
              account.isSignedIn else { throw AppScriptingError.superseded }
        play(track)
        return track.id
    }

    func playTracks(_ tracks: [Track], startingAt index: Int = 0) {
        scriptingPlayGeneration = UUID()
        guard !tracks.isEmpty, tracks.indices.contains(index) else { return }
        guard account.isSignedIn else { openAccount(); return }
        wantsPlayback = true
        resumePosition = 0
        request(queue.replace(with: tracks, startAt: index))
    }

    func togglePlayback() {
        if player.isPlaying || player.isBuffering { pause() } else { play() }
    }

    func play() {
        scriptingPlayGeneration = UUID()
        guard !queue.isEmpty else { return }
        guard account.isSignedIn else { openAccount(); return }
        wantsPlayback = true
        if queue.currentOccurrence == nil {
            let position = resumePosition
            resumePosition = 0
            request(queue.beginPlayback())
            if position > 0 { player.seek(to: position) }
        }
        else { player.play() }
        systemMedia?.refresh()
    }

    func pause() {
        scriptingPlayGeneration = UUID()
        wantsPlayback = false
        player.pause()
        saveQueue()
        systemMedia?.refresh()
    }

    func next() {
        scriptingPlayGeneration = UUID()
        resumePosition = 0
        request(queue.next())
    }

    func previous() {
        scriptingPlayGeneration = UUID()
        resumePosition = 0
        if player.clock.position > 3 { seek(to: 0) }
        else { request(queue.previous()) }
    }

    func seek(to value: TimeInterval) { player.seek(to: value) }
    func setVolume(_ value: Double) {
        player.setVolume(value)
        preferences.set(player.volume, forKey: "volume")
    }
    func retryPlayback() {
        scriptingPlayGeneration = UUID()
        guard account.isSignedIn else { openAccount(); return }
        wantsPlayback = true
        request(queue.beginPlayback())
    }

    func selectQueueEntry(_ id: UUID) {
        scriptingPlayGeneration = UUID()
        guard account.isSignedIn else { openAccount(); return }
        wantsPlayback = true
        resumePosition = 0
        request(queue.select(entryID: id))
    }
    func playNext(_ tracks: [Track]) { queue.playNext(tracks); saveQueue() }
    func addToQueue(_ tracks: [Track]) { queue.append(tracks); saveQueue() }
    func removeQueueEntries(_ ids: Set<UUID>) {
        scriptingPlayGeneration = UUID()
        let previous = queue.currentOccurrence
        if let selected = queue.currentEntryID, ids.contains(selected) { resumePosition = 0 }
        wantsPlayback = player.playbackIntent
        queue.remove(entryIDs: ids)
        reconcileQueue(previous: previous)
    }
    func moveQueueEntries(from offsets: IndexSet, to destination: Int) {
        queue.move(fromOffsets: offsets, toOffset: destination)
        saveQueue()
    }
    func undoQueueEdit() {
        scriptingPlayGeneration = UUID()
        let previous = queue.currentOccurrence
        wantsPlayback = player.playbackIntent
        queue.undo()
        reconcileQueue(previous: previous)
    }
    func toggleShuffle() { queue.setShuffle(!queue.isShuffled); saveQueue() }
    func cycleRepeat() {
        switch queue.repeatMode {
        case .off: queue.repeatMode = .all
        case .all: queue.repeatMode = .one
        case .one: queue.repeatMode = .off
        }
        saveQueue()
    }

    private func reconcileQueue(previous: PlaybackOccurrence?) {
        if queue.currentOccurrence != previous {
            if let occurrence = queue.currentOccurrence { request(occurrence) }
            else { player.stop(); wantsPlayback = false }
        }
        saveQueue()
    }

    private func request(_ occurrence: PlaybackOccurrence?) {
        guard let occurrence, let track = queue.currentTrack else { return }
        player.load(track: track, occurrence: occurrence, autoplay: wantsPlayback)
        saveQueue()
        systemMedia?.refresh()
    }

    private func ended(_ occurrence: PlaybackOccurrence) {
        guard queue.accepts(occurrence) else { return }
        if let next = queue.handleEnd(occurrence: occurrence) { request(next) }
        else { wantsPlayback = false; player.stop(); saveQueue() }
        systemMedia?.refresh()
    }

    func openAccount() {
        account.openLogin()
        showsAccount = true
    }

    func closeAccount() {
        account.closeLogin()
        showsAccount = false
    }

    func signOut() async {
        accountGeneration = UUID()
        pageGeneration = UUID()
        pageTask?.cancel()
        wantsPlayback = false
        player.stop()
        queue = PlaybackQueue()
        page = nil
        resumePosition = 0
        saveTask?.cancel()
        await saveTask?.value
        await account.signOut()
        do { try await queueStore?.clear() }
        catch { queueError = "The saved queue could not be removed. Try signing out again." }
        showsAccount = false
        backHistory.removeAll()
        forwardHistory.removeAll()
        searchText = ""
        navigate(to: .home, recordHistory: false)
        systemMedia?.refresh()
    }

    private func accountChanged(replacedAccount: Bool) {
        accountGeneration = UUID()
        pageTask?.cancel()
        if replacedAccount {
            player.stop()
            wantsPlayback = false
            queue = PlaybackQueue()
            resumePosition = 0
            backHistory.removeAll()
            forwardHistory.removeAll()
            searchText = ""
            destination = .home
            saveQueue()
        }
        reload()
    }

    private func saveQueue() {
        guard let queueStore else { return }
        let previousTask = saveTask
        previousTask?.cancel()
        let snapshot = queue.snapshot(resumePosition: queue.currentOccurrence == nil ? resumePosition : player.clock.position)
        let generation = accountGeneration
        saveTask = Task { [weak self] in
            await previousTask?.value
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                try await queueStore.save(snapshot)
                if let self, self.accountGeneration == generation { self.queueError = nil }
            } catch is CancellationError { }
            catch {
                guard let self, self.accountGeneration == generation else { return }
                self.queueError = "The queue could not be saved. Playback can continue."
            }
        }
    }

    func shutdown() async {
        scriptingPlayGeneration = UUID()
        wantsPlayback = false
        player.pause()
        saveQueue()
        await saveTask?.value
        player.onStateChanged = nil
        player.stop()
        systemMedia?.refresh()
    }
}
