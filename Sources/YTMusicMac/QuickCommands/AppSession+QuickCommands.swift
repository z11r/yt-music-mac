import Foundation
import MusicCore

extension AppSession {
    var quickCommandEnvironment: QuickCommandEnvironment {
        .init(scope: .init(accountGeneration: accountGeneration, profile: account.isSignedIn ? quickCommandProfile : nil,
                           startupIntent: links.generation),
              ready: hasFinishedStartup && (isSceneCheck || links.isReady) && !account.isWorking && (!account.isSignedIn || quickCommandProfile != nil),
              shuttingDown: isShuttingDown, signedIn: account.isSignedIn, hasQueue: !queue.isEmpty,
              canPause: currentTrack != nil || player.isPlaying || player.isBuffering || wantsPlayback,
              hasNext: queue.hasNext, occurrence: queue.currentOccurrence, duration: player.clock.duration)
    }
    func executeQuickCommand(_ command: QuickCommand, environment: QuickCommandEnvironment) {
        guard quickCommandEnvironment.scope == environment.scope, !isShuttingDown,
              QuickCommandPalette.unavailable(command, in: quickCommandEnvironment) == nil else { return }
        switch command {
        case .play: play()
        case .pause: pause()
        case .next: next()
        case .previous: previous()
        case let .open(destination):
            if destination == .queue { showsQueue = true }
            else { show(destination.musicDestination) }
        case let .search(query):
            searchSuggestions.close(ignoringNextChangeTo: query)
            searchText = query
            navigate(to: .search(query))
        case let .timerMinutes(minutes): sleepTimer.start(minutes: minutes)
        case .timerOff: sleepTimer.cancel()
        case .timerEnd:
            if let occurrence = environment.occurrence, queue.accepts(occurrence) { sleepTimer.stopAtEnd(of: occurrence) }
        case let .volume(percent): setVolume(Double(percent) / 100)
        case let .seek(seconds): seek(to: Double(seconds))
        case let .shuffle(enabled): if queue.isShuffled != enabled { toggleShuffle() }
        case let .repeatMode(mode): setRepeatMode(mode)
        }
    }
}
private extension QuickCommand.Destination {
    var musicDestination: MusicDestination {
        switch self {
        case .home, .queue: .home
        case .explore: .explore
        case .library: .library
        case .songs: .libraryCategory(.songs)
        case .albums: .libraryCategory(.albums)
        case .artists: .libraryCategory(.songArtists)
        case .followedArtists: .libraryCategory(.artists)
        case .playlists: .libraryCategory(.playlists)
        case .liked: .likedSongs
        case .history: .history
        case .uploads: .uploads(.songs)
        case .podcasts: .podcasts
        case .yourPodcasts: .podcastLibrary
        case .savedEpisodes: .savedEpisodes
        }
    }
}
