import AppKit
import MusicCore
import Observation
import WebKit
import YouTubeMusic

enum MusicDestination: Hashable {
    case home, explore, library, likedSongs, history
    case libraryCategory(YouTubeMusicClient.LibraryCategory)
    case search(String)
    case collection(MusicCollection)
    case discovery(MusicDiscoveryCategory)
    case browse(MusicBrowseReference)
    case uploads(MusicUploadCategory)
    case uploadSearch(String)
    case podcasts, podcastLibrary, savedEpisodes

    var isUploadDestination: Bool {
        switch self {
        case .uploads, .uploadSearch: true
        case let .collection(collection): collection.isUploaded
        default: false
        }
    }

    var title: String {
        switch self {
        case .home: AppLocalization.text("Home")
        case .explore: AppLocalization.text("Explore")
        case .library: AppLocalization.text("Library")
        case .likedSongs: AppLocalization.text("Liked Songs")
        case .history: AppLocalization.text("Listening History")
        case let .libraryCategory(category): category.title
        case .search: AppLocalization.text("Search")
        case let .uploads(category): AppLocalization.format("Uploaded %@", category.title)
        case .uploadSearch: AppLocalization.text("Search Uploads")
        case .podcasts: "Podcasts"
        case .podcastLibrary: "Your Podcasts"
        case .savedEpisodes: "Saved Episodes"
        case let .collection(value): value.title
        case let .discovery(category): category.title
        case let .browse(reference): reference.title
        }
    }

    var libraryCategory: YouTubeMusicClient.LibraryCategory? {
        switch self {
        case .library: .all
        case let .libraryCategory(category): category
        default: nil
        }
    }
}

/// Keeps a saved position through the zero clock used while a resume request loads.
struct PlaybackResumeState {
    private struct Point {
        let entryID: UUID
        let occurrence: PlaybackOccurrence?
        let position: TimeInterval
    }

    private var point: Point?

    mutating func restore(_ snapshot: QueueSnapshot) {
        clear()
        guard let entryID = snapshot.currentEntryID, snapshot.resumePosition > 0 else { return }
        point = Point(entryID: entryID, occurrence: nil, position: snapshot.resumePosition)
    }

    mutating func begin(_ occurrence: PlaybackOccurrence, recovering position: TimeInterval) {
        clear()
        guard position.isFinite, position > 0 else { return }
        point = Point(entryID: occurrence.entryID, occurrence: occurrence, position: position)
    }

    mutating func clear() { point = nil }

    mutating func recover(_ occurrence: PlaybackOccurrence, queue: PlaybackQueue,
                          playerPosition: TimeInterval) -> TimeInterval? {
        guard queue.accepts(occurrence) else { return nil }
        let position = position(for: queue, playerPosition: playerPosition)
        begin(occurrence, recovering: position)
        return position
    }

    func position(for queue: PlaybackQueue, playerPosition: TimeInterval) -> TimeInterval {
        guard queue.currentEntryID != nil else { return 0 }
        if let point, matches(point, queue: queue) { return point.position }
        return queue.currentOccurrence == nil ? 0 : playerPosition
    }

    mutating func snapshot(queue: PlaybackQueue, playerPosition: TimeInterval,
                           playerDuration: TimeInterval, positionConfirmed: Bool) -> QueueSnapshot {
        if let point {
            if !matches(point, queue: queue) {
                clear()
            } else if point.occurrence != nil, positionConfirmed {
                let target = playerDuration > 0 ? min(point.position, playerDuration) : point.position
                let tolerance = min(0.5, target * 0.05)
                if playerPosition >= target - tolerance { clear() }
            }
        }
        return queue.snapshot(resumePosition: position(for: queue, playerPosition: playerPosition))
    }

    private func matches(_ point: Point, queue: PlaybackQueue) -> Bool {
        point.entryID == queue.currentEntryID && point.occurrence == queue.currentOccurrence
    }
}

@MainActor @Observable
final class AppSession {
    let links = MusicLinkState()
    let account: WebSession
    let player: WebPlayer
    /// Radio requests and how the queue continues past its end. See AppSession+Radio.swift.
    let radio: RadioSession
    let sleepTimer = SleepTimer()
    let savedQueues: NamedQueueLibrary
    let localCollections: LocalCollectionsLibrary
    let storage: StorageController
    let spotlight: SpotlightLibraryController
    var queue = PlaybackQueue()
    let collectionPlayback: CollectionPlayback
    let songRatings = SongRatings()
    let episodePlayback: EpisodePlaybackSession
    private(set) var destination: MusicDestination = .home
    private(set) var page: MusicPage?
    private(set) var isLoading = false
    private(set) var hasFinishedStartup = false
    private(set) var isShuttingDown = false
    private(set) var isLoadingMore = false
    private(set) var pageError: String?
    private(set) var queueError: String?
    private(set) var isEditingLibrary = false
    private(set) var libraryEditError: String?
    private(set) var libraryEditMessage: String?
    private(set) var libraryEditingScope = UUID()
    private(set) var sceneCheckRevision = 0
    var searchText = ""
    /// Applies to the current search and every later one until changed.
    var searchFilter: MusicSearchFilter = .all {
        didSet { if searchFilter != oldValue { searchFilterChanged() } }
    }
    let searchSuggestions: SearchSuggestions
    let searchHistory = SearchHistory()
    let lyrics: LyricsSession
    var libraryDisplayOrder: LibraryDisplayOrder = .serviceOrder
    var collectionFilter = ""
    var libraryFilter = ""
    var collectionDisplayOrder: CollectionDisplayOrder = .serviceOrder
    var showsQueue = false
    var showsAccount = false
    var showsLocalFolders = false
    var showsWebPlayer = false {
        didSet { player.isPresented = showsWebPlayer }
    }
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    @ObservationIgnored let client: YouTubeMusicClient
    /// Separate, retained client for explicitly requested disposable checks only.
    @ObservationIgnored let playlistVerificationClient: YouTubeMusicClient
    @ObservationIgnored private let queueStore: QueueStore?
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored let isSceneCheck: Bool
    @ObservationIgnored private var started = false
    @ObservationIgnored var wantsPlayback = false
    @ObservationIgnored private(set) var pageTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pageGeneration = UUID()
    @ObservationIgnored var accountGeneration = UUID()
    @ObservationIgnored private var backHistory: [MusicDestination] = []
    @ObservationIgnored private var forwardHistory: [MusicDestination] = []
    @ObservationIgnored private var resumeState = PlaybackResumeState()
    @ObservationIgnored private var volumeState = VolumeState()
    @ObservationIgnored private var systemMedia: SystemMediaControls?
    @ObservationIgnored private var scriptingPlayGeneration = UUID()
    @ObservationIgnored private var libraryEditID: UUID?
    @ObservationIgnored private var spotlightPageSource: SpotlightLibrarySource?
    @ObservationIgnored private var pendingSpotlightResult: String?

    @ObservationIgnored private var episodeStartTask: Task<Void, Never>?
    @ObservationIgnored private var pendingEpisodeOccurrence: PlaybackOccurrence?

    init(configuration: AppSessionConfiguration = .live()) {
        preferences = configuration.preferences
        episodePlayback = EpisodePlaybackSession(store: configuration.episodeProgressStore)
        radio = RadioSession(preferences: configuration.preferences)
        savedQueues = NamedQueueLibrary(store: configuration.namedQueueStore, sessions: configuration.credentials)
        localCollections = LocalCollectionsLibrary(store: configuration.localCollectionStore, sessions: configuration.credentials)
        storage = StorageController(cache: configuration.metadataCache, inventory: configuration.storageInventory,
                                    sessions: configuration.credentials, preferences: configuration.preferences)
        spotlight = SpotlightLibraryController(index: configuration.spotlightIndex, sessions: configuration.credentials,
            preferences: configuration.preferences, namespace: AppIdentity.identifier)
        isSceneCheck = configuration.isSceneCheck
        account = WebSession(dataStore: configuration.dataStore, credentials: configuration.credentials,
                             preferences: configuration.preferences)
        client = configuration.client
        playlistVerificationClient = configuration.playlistVerificationClient ?? YouTubeMusicClient(
            sessions: configuration.credentials, libraryEditCapabilities: .init(playlists: true))
        searchSuggestions = SearchSuggestions { [client = configuration.client] text in
            try await client.searchSuggestions(for: text)
        }
        collectionPlayback = CollectionPlayback { [client = configuration.client] in try await client.nextPage($0) }
        lyrics = LyricsSession { [client = configuration.client] videoID in
            try await client.lyrics(videoID: videoID)
        }
        player = WebPlayer(dataStore: configuration.dataStore)
        queueStore = configuration.queueStore
        queueError = configuration.queueStorageError
        player.onEnded = { [weak self] occurrence in self?.ended(occurrence) }
        sleepTimer.onExpired = { [weak self] in
            self?.cancelRadio()
            self?.pause()
        }
        player.onVerifiedContentProgress = { [weak self] occurrence, position, duration, ended in
            guard let self, self.queue.accepts(occurrence), self.account.isSignedIn else { return }
            self.episodePlayback.record(occurrence: occurrence, position: position, duration: duration, confirmedContent: true, ended: ended)
        }
        player.onRecoveryRequested = { [weak self] occurrence, position in
            guard let self else { return nil }
            return self.resumeState.recover(occurrence, queue: self.queue, playerPosition: position)
        }
        player.onStateChanged = { [weak self] in
            if let self {
                if self.wantsPlayback && !self.player.playbackIntent {
                    self.cancelPendingCollectionRadio()
                    self.collectionPlayback.cancel()
                }
                self.wantsPlayback = self.player.playbackIntent
            }
            self?.systemMedia?.refresh()
            self?.saveQueue()
        }
        player.onPageReady = { [weak self] view in
            Task { [weak self, weak view] in
                guard let self, let view else { return }
                await self.account.synchronize(from: view)
            }
        }
        player.onSessionRestoreFailed = { [weak account] in account?.sessionRestoreFailed() }
        account.onAccountChanged = { [weak self] changed in self?.accountChanged(replacedAccount: changed) }
        account.onAccountConfirmed = { [weak self] hash in self?.episodePlayback.bindAccount(hash) }
        account.onSignInCompleted = { [weak self] in
            guard let self, self.showsAccount else { return }
            self.closeAccount()
        }
        if configuration.installsSystemMedia { systemMedia = SystemMediaControls(session: self) }
        if isSceneCheck {
            started = true
            hasFinishedStartup = true
            page = SceneCheckFixture.page
        }
    }

    /// Exercises observable queue state without issuing playback or account requests.
    func advanceSceneCheck(to revision: Int) -> Bool {
        guard isSceneCheck, revision == sceneCheckRevision + 1, revision <= SceneCheckProgress.target else { return false }
        let tracks = SceneCheckFixture.tracks
        queue.replace(with: revision.isMultiple(of: 2) ? tracks : Array(tracks.reversed()))
        if revision.isMultiple(of: 3) { _ = queue.next() }
        queue.setShuffle(revision.isMultiple(of: 2))
        queue.repeatMode = revision.isMultiple(of: 3) ? .all : .off
        showsQueue = revision % 10 < 5
        sceneCheckRevision = revision
        return true
    }

    var sceneCheckIsIsolated: Bool {
        isSceneCheck && queueStore == nil && systemMedia == nil && !account.dataStore.isPersistent &&
        !account.isSignedIn && account.loginWebView == nil && !player.playbackIntent &&
        !player.isPlaying && !player.isBuffering && player.webView.url == nil && !player.webView.isLoading
    }

    var currentTrack: Track? { queue.currentTrack }
    var remainingQueuePosition: TimeInterval {
        resumeState.position(for: queue, playerPosition: Double(player.clock.elapsedSeconds))
    }
    var remoteLibraryEditingEnabled: Bool { account.isSignedIn && client.libraryEditCapabilities.playlists }
    var libraryEditCapabilities: MusicLibraryEditCapabilities { client.libraryEditCapabilities }
    func canSubmitLibraryEdit(_ action: MusicLibraryEditAction) -> Bool {
        account.isSignedIn && client.libraryEditCapabilities.allows(action)
    }
    func submitLibraryEdit(_ action: MusicLibraryEditAction) {
        let scope = libraryEditingScope
        Task { @MainActor [weak self] in
            guard let self, self.libraryEditingScope == scope else { return }
            _ = await self.performLibraryEdit(action)
        }
    }
    var hasRatingControls: Bool {
        account.isSignedIn && (client.libraryEditCapabilities.likes || client.libraryEditCapabilities.dislikes)
    }
    func canEditRating(_ rating: MusicRating) -> Bool {
        account.isSignedIn && client.libraryEditCapabilities.allows(.setRating(videoID: "", rating: rating))
    }
    func rating(for track: Track) -> MusicRating? { songRatings.values[track.id] }
    var visibleTracks: [Track] {
        guard let page else { return [] }
        return CollectionPresentation.rows(in: page, matching: collectionFilter,
            order: collectionDisplayOrder).map(\.track)
    }

    func start() async {
        guard !started else { return }
        started = true
        defer { hasFinishedStartup = true }
        spotlight.start()
        let restoreGeneration = accountGeneration
        if let queueStore, !preferences.bool(forKey: "sessionRestoreBlocked") {
            do {
                if let saved = try await queueStore.load(),
                   accountGeneration == restoreGeneration, queue.isEmpty,
                   !preferences.bool(forKey: "sessionRestoreBlocked") {
                    queue = try PlaybackQueue(snapshot: saved)
                    resumeState.restore(saved)
                }
            } catch { queueError = AppLocalization.text("The saved queue could not be restored. You can start a new queue.") }
        }
        let volume = preferences.object(forKey: "volume") as? Double ?? 0.7
        setVolume(volume)
        systemMedia?.refresh()
        navigate(to: .home, recordHistory: false)
        await account.restore { [player, account] in
            player.restoreSessionPage { await account.synchronize(from: $0) }
        }
    }

    func navigate(to target: MusicDestination, recordHistory: Bool = true) {
        collectionPlayback.cancel()
        if recordHistory, target != destination {
            backHistory.append(destination)
            if backHistory.count > 50 { backHistory.removeFirst() }
            forwardHistory.removeAll()
        }
        destination = target
        canGoBack = !backHistory.isEmpty
        canGoForward = !forwardHistory.isEmpty
        collectionFilter = ""
        libraryFilter = ""
        collectionDisplayOrder = .serviceOrder
        page = nil
        spotlightPageSource = nil
        pageError = nil
        isLoading = true
        isLoadingMore = false
        pageTask?.cancel()
        let generation = UUID()
        pageGeneration = generation
        let filter = searchFilter
        let ratingsRead = songRatings.beginRead()
        pageTask = Task { [weak self, client] in
            do {
                let metadataContext: LibraryMetadataCaptureContext?
                let spotlightSource: SpotlightLibrarySource?
                if target == .library { metadataContext = await self?.storage.beginCapture() }
                else { metadataContext = nil }
                if target == .library { spotlightSource = await self?.spotlight.beginSource() }
                else { spotlightSource = nil }
                let result: MusicPage
                switch target {
                case .home: result = try await client.home()
                case .explore: result = try await client.explore()
                case let .discovery(category): result = try await client.discovery(category)
                case let .browse(reference): result = try await client.browse(reference)
                case .library: result = try await client.library()
                case let .libraryCategory(category): result = try await client.library(category: category)
                case .likedSongs: result = try await client.likedSongs()
                case .history: result = try await client.history()
                case let .search(query): result = try await client.search(query: query, filter: filter)
                case let .uploads(category): result = try await client.uploads(category: category)
                case let .uploadSearch(query): result = try await client.searchUploads(query: query)
                case .podcasts: result = try await client.podcasts()
                case .podcastLibrary: result = try await client.libraryPodcasts()
                case .savedEpisodes: result = try await client.savedEpisodes()
                case let .collection(value):
                    switch value.kind {
                    case .album: result = try await client.album(id: value.id)
                    case .artist: result = try await client.artist(id: value.id)
                    case .playlist: result = try await client.playlist(id: value.id)
                    case .podcast: result = try await client.podcast(id: value.id)
                    }
                }
                guard let self, !Task.isCancelled, self.pageGeneration == generation else { return }
                self.page = result
                self.songRatings.observe(result.ratings, from: ratingsRead)
                self.spotlightPageSource = spotlightSource
                self.isLoading = false
                if let metadataContext { await self.storage.capture(result, context: metadataContext) }
                if let spotlightSource { await self.spotlight.capture(result, source: spotlightSource) }
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
        searchHistory.record(query)
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

    /// Every collection action snapshots its scope and commits only while that
    /// account, destination, and queue are still current.
    @discardableResult
    func performCollectionAction(_ action: CollectionPlaybackAction) -> Task<Void, Never>? {
        guard let page, !isLoadingMore else { return nil }
        guard action == .append || account.isSignedIn else { openAccount(); return nil }
        scriptingPlayGeneration = UUID()
        cancelRadio()
        let pageScope = pageGeneration
        let accountScope = accountGeneration
        let ratingsRead = songRatings.beginRead()
        let queueState = queue.snapshot()
        return collectionPlayback.start(page: page, action: action, isCurrent: { [weak self] in
            guard let self else { return false }
            return self.pageGeneration == pageScope && self.accountGeneration == accountScope &&
                self.queue.entries == queueState.entries && self.queue.repeatMode == queueState.repeatMode &&
                self.queue.isShuffled == queueState.isShuffled
        }, commit: { [weak self] complete, action in
            guard let self else { return }
            self.page = complete
            self.songRatings.observe(complete.ratings, from: ratingsRead)
            self.pageError = nil
            switch action {
            case .append:
                self.addToQueue(complete.tracks)
            case .play, .shuffle:
                self.sleepTimer.allowPlayback()
                self.scriptingPlayGeneration = UUID()
                self.wantsPlayback = true
                self.request(self.queue.replaceForPlayback(with: complete.tracks, shuffled: action == .shuffle))
            }
        })
    }

    func loadMore() {
        collectionPlayback.cancel()
        guard let initial = page, let continuation = initial.continuation, !isLoadingMore else { return }
        isLoadingMore = true
        pageError = nil
        let generation = pageGeneration
        let ratingsRead = songRatings.beginRead()
        let cachesLibrary = destination == .library
        pageTask = Task { [weak self, client] in
            do {
                let metadataContext: LibraryMetadataCaptureContext?
                let spotlightSource: SpotlightLibrarySource?
                if cachesLibrary { metadataContext = await self?.storage.beginCapture() }
                else { metadataContext = nil }
                if cachesLibrary { spotlightSource = await self?.spotlight.beginSource() }
                else { spotlightSource = nil }
                let next = try await client.nextPage(continuation)
                guard let self, !Task.isCancelled, self.pageGeneration == generation else { return }
                let combined = MusicPage(title: initial.title, sections: initial.sections + next.sections,
                    items: initial.items + next.items, continuation: next.continuation,
                    playlistItems: initial.playlistItems + next.playlistItems,
                    playlistCapabilities: initial.playlistCapabilities,
                    likeStates: initial.likeStates.merging(next.likeStates) { _, new in new },
                    ratings: initial.ratings.merging(next.ratings) { _, new in new },
                    unavailableItemCount: initial.unavailableItemCount + next.unavailableItemCount,
                    hasUnsupportedContent: initial.hasUnsupportedContent || next.hasUnsupportedContent,
                    playlistDetails: initial.playlistDetails, albumLibraryState: initial.albumLibraryState,
                    artistSubscription: initial.artistSubscription)
                self.songRatings.observe(next.ratings, from: ratingsRead)
                self.page = combined
                self.spotlightPageSource = spotlightSource
                self.isLoadingMore = false
                if let metadataContext { await self.storage.capture(combined, context: metadataContext) }
                if let spotlightSource { await self.spotlight.capture(combined, source: spotlightSource) }
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
        case let .browse(reference): navigate(to: .browse(reference))
        }
    }

    func play(_ track: Track) { playTracks([track], startingAt: 0) }

    func beginScriptedPlaybackRequest() -> UUID {
        collectionPlayback.cancel()
        cancelPendingCollectionRadio()
        scriptingPlayGeneration = UUID()
        return scriptingPlayGeneration
    }

    func acceptsScriptedPlaybackRequest(_ request: UUID) -> Bool { scriptingPlayGeneration == request && !isShuttingDown }

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

    func playScriptedVideos(_ videoIDs: [String], requestGeneration: UUID) async throws -> Int {
        guard scriptingPlayGeneration == requestGeneration else { throw AppScriptingError.superseded }
        guard account.isSignedIn else { throw AppScriptingError.signInRequired }
        let accountScope = accountGeneration
        let tracks = try await ScriptedQueueResolver.resolve(videoIDs: videoIDs) { [client] query in
            try await client.search(query: query)
        }
        guard scriptingPlayGeneration == requestGeneration, accountGeneration == accountScope,
              account.isSignedIn else { throw AppScriptingError.superseded }
        playTracks(tracks)
        return tracks.count
    }

    func checkLibrary() async throws -> MusicLibraryCheck {
        guard account.isSignedIn else { throw AppScriptingError.signInRequired }
        let generation = accountGeneration
        let result = try await client.checkLibrary(maximumPlaylists: 50)
        guard accountGeneration == generation, account.isSignedIn else { throw AppScriptingError.superseded }
        return result
    }

    func checkLibraryNavigation() async throws -> MusicLibraryCheck {
        guard account.isSignedIn else { throw AppScriptingError.signInRequired }
        let generation = accountGeneration
        let result = try await client.checkLibraryNavigation()
        guard accountGeneration == generation, account.isSignedIn else { throw AppScriptingError.superseded }
        return result
    }

    func clearLibraryEditFeedback() {
        libraryEditError = nil
        libraryEditMessage = nil
    }

    func playlistsForEditing() async throws -> [MusicCollection] {
        guard account.isSignedIn else { throw MusicServiceError.signInRequired }
        let generation = accountGeneration
        let first = try await client.library(category: .playlists)
        let pages = try await client.allPages(startingWith: first)
        try Task.checkCancellation()
        guard accountGeneration == generation, account.isSignedIn else { throw MusicServiceError.sessionChanged }
        var seen = Set<String>()
        return pages.flatMap(\.items).compactMap { item in
            guard case let .collection(value) = item, value.kind == .playlist,
                  seen.insert(LibraryEditPolicy.normalizedID(value.id)).inserted else { return nil }
            return value
        }
    }

    func performLibraryEdit(_ action: MusicLibraryEditAction) async -> Bool {
        guard account.isSignedIn, client.libraryEditCapabilities.allows(action) else {
            libraryEditError = MusicLibraryEditError.featureUnavailable.localizedDescription
            return false
        }
        guard !isEditingLibrary else { return false }
        let id = UUID()
        let generation = accountGeneration
        let startingDestination = destination
        libraryEditID = id
        isEditingLibrary = true
        clearLibraryEditFeedback()
        defer {
            if libraryEditID == id { libraryEditID = nil; isEditingLibrary = false }
        }
        do {
            let expectedScope = try await client.libraryEditScope()
            if let target = LibraryEditPolicy.playlistID(for: action), !LibraryEditPolicy.usesClientPreflight(action) {
                let targetPage = try await client.playlist(id: target)
                guard LibraryEditPolicy.permits(action, capabilities: targetPage.playlistCapabilities) else {
                    throw MusicLibraryEditError.serviceRejected
                }
            }
            guard libraryEditID == id, accountGeneration == generation, account.isSignedIn else { return false }
            try Task.checkCancellation()
            let result = try await client.performLibraryEdit(action, expectedScope: expectedScope)
            guard libraryEditID == id, accountGeneration == generation, account.isSignedIn else { return false }
            switch result {
            case let .liked(videoID, isLiked):
                songRatings.confirm(isLiked ? .liked : .neutral, for: videoID)
                libraryEditMessage = AppLocalization.text("Your song rating was updated.")
                if destination == startingDestination { reload() }
            case let .rated(videoID, rating):
                songRatings.confirm(rating, for: videoID)
                libraryEditMessage = AppLocalization.text("Your song rating was updated.")
                if destination == startingDestination { reload() }
            case let .playlistCreated(playlistID):
                libraryEditMessage = AppLocalization.text("Playlist created.")
                if destination == startingDestination, case let .createPlaylist(title, _, _, _) = action {
                    navigate(to: .collection(MusicCollection(id: playlistID, kind: .playlist, title: title)))
                }
            case let .playlistRenamed(playlistID, title):
                libraryEditMessage = AppLocalization.text("Playlist renamed.")
                if isCurrentPlaylist(playlistID), case let .collection(collection) = destination {
                    navigate(to: .collection(MusicCollection(id: collection.id, kind: .playlist,
                        title: title, subtitle: collection.subtitle, artworkURL: collection.artworkURL)), recordHistory: false)
                } else if destination.libraryCategory != nil { reload() }
            case let .playlistDeleted(playlistID):
                libraryEditMessage = AppLocalization.text("Playlist deleted.")
                if isCurrentPlaylist(playlistID) { navigate(to: .library) }
                else if destination.libraryCategory != nil { reload() }
            case let .itemsAdded(playlistID, _):
                libraryEditMessage = AppLocalization.text("Songs added to the playlist.")
                if isCurrentPlaylist(playlistID) { reload() }
            case let .itemsRemoved(playlistID, _):
                libraryEditMessage = AppLocalization.text("Songs removed from the playlist.")
                if isCurrentPlaylist(playlistID) { reload() }
            case let .playlistDescriptionChanged(playlistID), let .playlistPrivacyChanged(playlistID, _):
                libraryEditMessage = AppLocalization.text("Playlist details updated. Reloading service details.")
                if isCurrentPlaylist(playlistID) { reload() }
            case let .playlistItemMoved(playlistID, _, _):
                libraryEditMessage = AppLocalization.text("Playlist order updated. Reloading service order.")
                if isCurrentPlaylist(playlistID) { reload() }
            case .albumSaved, .artistSubscribed:
                libraryEditMessage = AppLocalization.text("Library change confirmed. Reloading service state.")
                if destination == startingDestination { reload() }
            }
            return true
        } catch {
            guard libraryEditID == id, accountGeneration == generation else { return false }
            if error is CancellationError || error as? MusicLibraryEditError == .unconfirmedOutcome {
                switch action {
                case let .setLiked(videoID, _), let .setRating(videoID, _): songRatings.invalidate(videoID)
                case .setPlaylistDescription, .setPlaylistPrivacy, .movePlaylistItem, .setAlbumSaved, .setArtistSubscribed:
                    if destination == startingDestination { reload() }
                default: break
                }
            }
            libraryEditError = error is CancellationError
                ? AppLocalization.text("The change was interrupted. Check your library before trying again.")
                : error.localizedDescription
            return false
        }
    }

    private func isCurrentPlaylist(_ id: String) -> Bool {
        guard case let .collection(value) = destination, value.kind == .playlist else { return false }
        return LibraryEditPolicy.normalizedID(value.id) == LibraryEditPolicy.normalizedID(id)
    }

    private func resetLibraryEditing() {
        songRatings.clear()
        libraryEditingScope = UUID()
        libraryEditID = nil
        isEditingLibrary = false
        clearLibraryEditFeedback()
    }

    func playTracks(_ tracks: [Track], startingAt index: Int = 0, origin: QueueEntryOrigin = .manual) {
        collectionPlayback.cancel()
        scriptingPlayGeneration = UUID()
        guard !tracks.isEmpty, tracks.indices.contains(index) else { return }
        guard account.isSignedIn else { openAccount(); return }
        cancelPendingCollectionRadio()
        sleepTimer.allowPlayback()
        wantsPlayback = true
        request(queue.replace(with: tracks, startAt: index, origin: origin))
    }

    func togglePlayback() {
        if player.isPlaying || player.isBuffering { pause() } else { play() }
    }

    func play() {
        collectionPlayback.cancel()
        scriptingPlayGeneration = UUID()
        guard !queue.isEmpty else { return }
        guard account.isSignedIn else { openAccount(); return }
        cancelPendingCollectionRadio()
        sleepTimer.allowPlayback()
        wantsPlayback = true
        if let pendingEpisodeOccurrence, queue.accepts(pendingEpisodeOccurrence) {
            request(pendingEpisodeOccurrence)
            return
        }
        if queue.currentOccurrence == nil {
            let position = resumeState.position(for: queue, playerPosition: player.clock.position)
            request(queue.beginPlayback(), resumingAt: position)
        }
        else if player.errorMessage != nil { retryPlayback() }
        else { player.play() }
        systemMedia?.refresh()
    }

    func pause() {
        episodeStartTask?.cancel(); episodeStartTask = nil
        collectionPlayback.cancel()
        scriptingPlayGeneration = UUID()
        cancelPendingCollectionRadio()
        wantsPlayback = false
        player.pause()
        saveQueue()
        systemMedia?.refresh()
    }

    func next() {
        collectionPlayback.cancel()
        scriptingPlayGeneration = UUID()
        cancelPendingCollectionRadio()
        request(queue.next())
    }

    func previous() {
        collectionPlayback.cancel()
        scriptingPlayGeneration = UUID()
        cancelPendingCollectionRadio()
        if player.clock.position > 3 { seek(to: 0) }
        else { request(queue.previous()) }
    }

    func seek(to value: TimeInterval) {
        collectionPlayback.cancel()
        guard value.isFinite, value >= 0 else { return }
        cancelPendingCollectionRadio()
        episodePlayback.allowExplicitSeek()
        resumeState.clear()
        player.seek(to: value)
        saveQueue()
    }
    func skipEpisode(forward: Bool) {
        guard let track = currentTrack, let target = EpisodeSkip.target(track: track, position: player.clock.position,
            duration: player.clock.duration, offset: forward ? episodePlayback.settings.skipForward : -episodePlayback.settings.skipBackward,
            positionConfirmed: player.hasConfirmedPosition && !player.isBuffering && player.errorMessage == nil) else { return }
        seek(to: target)
    }
    func resumeEpisode() {
        guard let track = currentTrack, track.contentKind == .podcastEpisode, account.isSignedIn else { return }
        let position = episodePlayback.resumePosition(for: track)
        guard position > 0 else { return }
        collectionPlayback.cancel(); scriptingPlayGeneration = UUID()
        cancelPendingCollectionRadio(); sleepTimer.allowPlayback(); wantsPlayback = true
        request(queue.beginPlayback(), resumingAt: position)
    }
    func startEpisodeOver() {
        guard let track = currentTrack, track.contentKind == .podcastEpisode, account.isSignedIn else { return }
        episodePlayback.startOver(track)
        collectionPlayback.cancel(); scriptingPlayGeneration = UUID()
        cancelPendingCollectionRadio(); sleepTimer.allowPlayback(); wantsPlayback = true
        request(queue.beginPlayback())
    }
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        player.setVolume(value)
        volumeState.record(player.volume)
        preferences.set(player.volume, forKey: "volume")
    }

    func toggleMute() { setVolume(volumeState.toggledVolume(from: player.volume)) }
    func retryPlayback() {
        collectionPlayback.cancel()
        scriptingPlayGeneration = UUID()
        guard account.isSignedIn else { openAccount(); return }
        cancelPendingCollectionRadio()
        sleepTimer.allowPlayback()
        let position = resumeState.position(for: queue, playerPosition: player.clock.position)
        wantsPlayback = true
        request(queue.beginPlayback(), resumingAt: position)
    }

    func selectQueueEntry(_ id: UUID) {
        collectionPlayback.cancel()
        scriptingPlayGeneration = UUID()
        guard account.isSignedIn else { openAccount(); return }
        cancelPendingCollectionRadio()
        sleepTimer.allowPlayback()
        wantsPlayback = true
        request(queue.select(entryID: id))
    }
    func playNext(_ tracks: [Track]) { collectionPlayback.cancel(); queue.playNext(tracks); saveQueue() }
    func addToQueue(_ tracks: [Track]) { collectionPlayback.cancel(); queue.append(tracks); saveQueue() }
    func removeQueueEntries(_ ids: Set<UUID>) {
        collectionPlayback.cancel()
        scriptingPlayGeneration = UUID()
        let previous = queue.currentOccurrence
        wantsPlayback = player.playbackIntent
        queue.remove(entryIDs: ids)
        reconcileQueue(previous: previous)
    }
    func moveQueueEntries(from offsets: IndexSet, to destination: Int) {
        collectionPlayback.cancel()
        queue.move(fromOffsets: offsets, toOffset: destination)
        saveQueue()
    }
    func undoQueueEdit() {
        collectionPlayback.cancel()
        scriptingPlayGeneration = UUID()
        let previous = queue.currentOccurrence
        wantsPlayback = player.playbackIntent
        queue.undo()
        reconcileQueue(previous: previous)
    }

    /// Metadata snapshot for an explicitly named local queue; no listening starts on restore.
    func savedQueueSnapshot() -> QueueSnapshot {
        resumeState.snapshot(queue: queue, playerPosition: player.clock.position,
            playerDuration: player.clock.duration,
            positionConfirmed: player.hasConfirmedPosition && !player.isBuffering && player.errorMessage == nil)
    }

    func openSavedQueue(id: UUID, expectedScope: UUID) async -> Bool {
        guard account.isSignedIn, savedQueues.scope == expectedScope else { return false }
        collectionPlayback.cancel()
        cancelPendingCollectionRadio()
        let generation = accountGeneration
        let revision = queue.revision
        let request = UUID()
        scriptingPlayGeneration = request
        guard let snapshot = await savedQueues.snapshot(id: id, expectedScope: expectedScope),
              accountGeneration == generation, account.isSignedIn, savedQueues.scope == expectedScope,
              scriptingPlayGeneration == request, queue.revision == revision else { return false }
        do { try restoreSavedQueueSnapshot(snapshot); return true }
        catch { queueError = AppLocalization.text("This saved queue could not be opened. The current queue has been kept."); return false }
    }

    /// Validation precedes mutation, so a corrupt named snapshot cannot erase the current queue.
    func restoreSavedQueueSnapshot(_ snapshot: QueueSnapshot) throws {
        collectionPlayback.cancel()
        cancelMusicLink()
        let restored = try PlaybackQueue(snapshot: snapshot)
        scriptingPlayGeneration = UUID()
        cancelRadio()
        sleepTimer.cancel()
        wantsPlayback = false
        player.stop()
        queue = restored
        resumeState.restore(snapshot)
        saveQueue()
        systemMedia?.refresh()
    }
    func toggleShuffle() { collectionPlayback.cancel(); queue.setShuffle(!queue.isShuffled); saveQueue() }
    func cycleRepeat() {
        collectionPlayback.cancel()
        switch queue.repeatMode {
        case .off: queue.repeatMode = .all
        case .all: queue.repeatMode = .one
        case .one: queue.repeatMode = .off
        }
        saveQueue()
    }

    func setRepeatMode(_ mode: RepeatMode) {
        collectionPlayback.cancel()
        queue.repeatMode = mode
        saveQueue()
    }

    private func reconcileQueue(previous: PlaybackOccurrence?) {
        if queue.currentOccurrence != previous {
            if let occurrence = queue.currentOccurrence { request(occurrence) }
            else { player.stop(); wantsPlayback = false }
        }
        saveQueue()
    }

    func request(_ occurrence: PlaybackOccurrence?, resumingAt position: TimeInterval = 0) {
        guard !isSceneCheck else { return }
        episodeStartTask?.cancel(); episodeStartTask = nil; pendingEpisodeOccurrence = nil
        guard let occurrence, let track = queue.currentTrack else { episodePlayback.clearPlayback(); return }
        sleepTimer.bind(to: occurrence)
        if position > 0 { resumeState.begin(occurrence, recovering: position) }
        if track.contentKind == .podcastEpisode, episodePlayback.isLoading {
            let generation = accountGeneration
            let intent = wantsPlayback
            pendingEpisodeOccurrence = occurrence
            episodePlayback.clearPlayback()
            player.stop(); wantsPlayback = intent
            episodeStartTask = Task { [weak self] in
                guard let self else { return }
                await self.episodePlayback.waitUntilLoaded()
                guard !Task.isCancelled, self.accountGeneration == generation,
                      self.queue.accepts(occurrence), self.wantsPlayback == intent else { return }
                self.episodeStartTask = nil
                self.request(occurrence, resumingAt: position)
            }
            return
        }
        episodePlayback.begin(track: track, occurrence: occurrence)
        let position = position > 0 ? position : episodePlayback.resumePosition(for: track)
        resumeState.begin(occurrence, recovering: position)
        player.load(track: track, occurrence: occurrence, autoplay: wantsPlayback)
        if position > 0 { player.seek(to: position) }
        saveQueue()
        systemMedia?.refresh()
    }

    private func ended(_ occurrence: PlaybackOccurrence) {
        guard queue.accepts(occurrence) else { return }
        if sleepTimer.consumeEnd(occurrence) {
            // The bridge consumed this ending. A later Play needs a fresh occurrence,
            // while the selection stays on the song the sleep timer finished.
            queue.invalidatePlayback()
            resumeState.clear()
            saveQueue()
            systemMedia?.refresh()
            return
        }
        continueQueue(after: occurrence)
        systemMedia?.refresh()
    }

    func openAccount() {
        guard !isSceneCheck else { return }
        lyrics.clear()
        player.cancelSessionRestore()
        account.openLogin()
        showsAccount = true
    }

    func setSpotlightEnabled(_ enabled: Bool) {
        spotlight.setEnabled(enabled)
        if !enabled { pendingSpotlightResult = nil; return }
        guard destination == .library, let page, let source = spotlightPageSource else { return }
        Task { await spotlight.capture(page, source: source) }
    }

    func removeSpotlightEntries() {
        pendingSpotlightResult = nil
        spotlight.setEnabled(false)
        spotlight.removeIndexedMetadata()
    }

    /// Spotlight can open a native collection after automatic session restoration; it never opens Account or starts audio.
    @discardableResult func receiveSpotlightResult(_ identifier: String) -> Bool {
        guard !isSceneCheck, spotlight.isEnabled, spotlight.policy.accountKey(in: identifier) != nil else { return false }
        pendingSpotlightResult = identifier
        Task { await routePendingSpotlightResult() }
        return true
    }

    @discardableResult func openSpotlightResult(_ identifier: String) async -> Bool {
        guard !isSceneCheck, spotlight.isEnabled, spotlight.policy.accountKey(in: identifier) != nil else { return false }
        pendingSpotlightResult = identifier
        return await routePendingSpotlightResult()
    }

    @discardableResult private func routePendingSpotlightResult() async -> Bool {
        guard let identifier = pendingSpotlightResult else { return false }
        let generation = accountGeneration
        let reference = await spotlight.resolve(identifier)
        guard accountGeneration == generation, pendingSpotlightResult == identifier else { return false }
        if let reference {
            pendingSpotlightResult = nil
            navigate(to: .collection(reference.collection))
            return true
        } else if account.isSignedIn { pendingSpotlightResult = nil }
        return false
    }

    func closeAccount() {
        account.closeLogin()
        showsAccount = false
    }

    func signOut() async {
        cancelMusicLink()
        episodeStartTask?.cancel(); episodeStartTask = nil; pendingEpisodeOccurrence = nil
        let progressFlush = episodePlayback.detachAccount()
        collectionPlayback.cancel()
        accountGeneration = UUID()
        lyrics.clear()
        searchSuggestions.close()
        searchHistory.clear()
        pendingSpotlightResult = nil
        spotlightPageSource = nil
        spotlight.accountChanged(isSignedIn: false)
        savedQueues.invalidate()
        localCollections.invalidate()
        storage.invalidate()
        showsLocalFolders = false
        sleepTimer.cancel()
        cancelRadio()
        resetLibraryEditing()
        pageGeneration = UUID()
        pageTask?.cancel()
        wantsPlayback = false
        resumeState.clear()
        player.stop()
        queue = PlaybackQueue()
        page = nil
        saveTask?.cancel()
        await saveTask?.value
        await spotlight.waitForIdle()
        _ = await progressFlush?.value
        await account.signOut()
        do { try await queueStore?.clear() }
        catch { queueError = AppLocalization.text("The saved queue could not be removed. Try signing out again.") }
        showsAccount = false
        backHistory.removeAll()
        forwardHistory.removeAll()
        searchText = ""
        navigate(to: .home, recordHistory: false)
        systemMedia?.refresh()
    }

    private func accountChanged(replacedAccount: Bool) {
        cancelMusicLink(keepingPending: !links.isReady && !replacedAccount)
        spotlightPageSource = nil
        spotlight.accountChanged(isSignedIn: account.isSignedIn)
        if replacedAccount { pendingSpotlightResult = nil }
        savedQueues.invalidate()
        localCollections.invalidate()
        storage.invalidate()
        showsLocalFolders = false
        if account.isSignedIn {
            let library = localCollections
            let scope = library.scope
            Task { await library.refresh(expectedScope: scope) }
        }
        sleepTimer.cancel()
        episodeStartTask?.cancel(); episodeStartTask = nil; pendingEpisodeOccurrence = nil
        _ = episodePlayback.detachAccount()
        collectionPlayback.cancel()
        accountGeneration = UUID()
        lyrics.clear()
        searchSuggestions.close()
        searchHistory.clear()
        cancelRadio()
        resetLibraryEditing()
        pageTask?.cancel()
        if replacedAccount {
            resumeState.clear()
            player.stop()
            wantsPlayback = false
            queue = PlaybackQueue()
            backHistory.removeAll()
            forwardHistory.removeAll()
            searchText = ""
            destination = .home
            saveQueue()
        }
        reload()
        if account.isSignedIn { Task { await routePendingSpotlightResult() } }
    }

    func saveQueue() {
        prepareQueueContinuation()
        guard let queueStore else { return }
        let previousTask = saveTask
        previousTask?.cancel()
        let snapshot = resumeState.snapshot(queue: queue, playerPosition: player.clock.position,
            playerDuration: player.clock.duration,
            positionConfirmed: player.hasConfirmedPosition && !player.isBuffering && player.errorMessage == nil)
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
                self.queueError = AppLocalization.text("The queue could not be saved. Playback can continue.")
            }
        }
    }

    func shutdown() async {
        isShuttingDown = true
        cancelMusicLink()
        episodeStartTask?.cancel(); episodeStartTask = nil; pendingEpisodeOccurrence = nil
        collectionPlayback.cancel()
        lyrics.clear()
        scriptingPlayGeneration = UUID()
        sleepTimer.cancel()
        cancelRadio()
        wantsPlayback = false
        player.pause()
        _ = await episodePlayback.flush()
        saveQueue()
        await saveTask?.value
        await spotlight.waitForIdle()
        player.onStateChanged = nil
        player.onVerifiedContentProgress = nil
        player.stop()
        systemMedia?.refresh()
    }
}
