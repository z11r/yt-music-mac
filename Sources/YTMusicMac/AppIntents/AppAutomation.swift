import Foundation
import YouTubeMusic

enum MusicAutomationAction: Equatable, Sendable {
    case resume, pause, next, previous
    case volume(Double)
    case playVideo(String)
    case openLink(URL)
    case search(String)

    var replacesPendingPlayback: Bool {
        if case .volume = self { false } else { true }
    }
}

enum MusicAutomationError: Error, Equatable, LocalizedError, CustomLocalizedStringResourceConvertible {
    case unavailable, notReady, signInRequired, noSelection, noNextSong
    case invalidVolume, invalidVideoID, invalidLink, invalidSearch, superseded, lookupFailed

    var errorDescription: String? { String(localized: localizedStringResource) }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unavailable: "Open YT Music for Mac before running this action."
        case .notReady: "YT Music for Mac is still opening or checking its account. Try again when it is ready."
        case .signInRequired: "Sign in to YouTube Music in the app, then run this action again."
        case .noSelection: "Choose a song in the app before resuming playback."
        case .noNextSong: "There is no next song in the queue."
        case .invalidVolume: "Use a volume from 0 to 100 percent."
        case .invalidVideoID: "Use an exact 11-character YouTube video ID."
        case .invalidLink: "Use a YouTube Music song, album, artist, or playlist link."
        case .invalidSearch: "Enter a search of up to 500 characters without control characters."
        case .superseded: "A newer playback, navigation, or account action replaced this request."
        case .lookupFailed: "The requested song could not be opened. Your existing queue has been kept."
        }
    }
}

struct MusicAutomationState: Sendable {
    var isReady: Bool
    var isSignedIn: Bool
    var hasSelection: Bool
    var hasNextSong: Bool
}

/// An injected boundary keeps intent testing independent of account stores,
/// network transports, WebKit playback, and the system Shortcuts runtime.
@MainActor
protocol MusicAutomationSession: AnyObject {
    var automationState: MusicAutomationState { get }
    func prepareForAutomation() async
    func beginScriptedPlaybackRequest() -> UUID
    func acceptsScriptedPlaybackRequest(_ request: UUID) -> Bool
    func playScriptedVideo(_ videoID: String, requestGeneration: UUID) async throws -> String
    func performAutomationTransport(_ action: MusicAutomationAction)
    func setVolume(_ value: Double)
    func navigate(to target: MusicDestination, recordHistory: Bool)
    func searchForAutomation(_ query: String)
}

/// Resolves the installed app's existing owner at invocation time. Constructing
/// intents, publishing shortcut phrases, or listing actions performs no work.
@MainActor
final class MusicAutomation {
    static let shared = MusicAutomation { AppScripting.session }
    private let sessionProvider: () -> (any MusicAutomationSession)?
    private var playbackRevision = UUID()

    init(sessionProvider: @escaping () -> (any MusicAutomationSession)?) {
        self.sessionProvider = sessionProvider
    }

    func perform(_ action: MusicAutomationAction) async throws {
        let validated = try validate(action)
        if validated.replacesPendingPlayback { playbackRevision = UUID() }
        let revision = playbackRevision
        guard let session = sessionProvider() else { throw MusicAutomationError.unavailable }
        // Mark the request before any startup suspension, so a later native
        // pause/play action also fences this request through AppSession.
        let request = validated.replacesPendingPlayback ? session.beginScriptedPlaybackRequest() : nil
        await session.prepareForAutomation()
        try Task.checkCancellation()
        guard let current = sessionProvider(), current === session,
              !validated.replacesPendingPlayback || playbackRevision == revision else {
            throw MusicAutomationError.superseded
        }
        if let request, !session.acceptsScriptedPlaybackRequest(request) { throw MusicAutomationError.superseded }
        let state = session.automationState
        guard state.isReady else { throw MusicAutomationError.notReady }
        switch validated {
        case .pause:
            session.performAutomationTransport(.pause)
        case let .volume(percent):
            session.setVolume(percent / 100)
        case .resume, .next, .previous:
            guard state.isSignedIn else { throw MusicAutomationError.signInRequired }
            guard state.hasSelection else { throw MusicAutomationError.noSelection }
            if validated == .next, !state.hasNextSong { throw MusicAutomationError.noNextSong }
            session.performAutomationTransport(validated)
        case let .playVideo(id):
            guard state.isSignedIn else { throw MusicAutomationError.signInRequired }
            guard let request else { throw MusicAutomationError.superseded }
            do { _ = try await session.playScriptedVideo(id, requestGeneration: request) }
            catch is CancellationError { throw CancellationError() }
            catch AppScriptingError.superseded { throw MusicAutomationError.superseded }
            catch AppScriptingError.signInRequired { throw MusicAutomationError.signInRequired }
            catch { throw MusicAutomationError.lookupFailed }
        case let .openLink(url):
            guard let link = MusicLink(url: url) else { throw MusicAutomationError.invalidLink }
            switch link {
            case let .track(id):
                // Use the exact same request token and validated resolver. Calling
                // the UI link receiver here would open a sign-in window.
                guard state.isSignedIn else { throw MusicAutomationError.signInRequired }
                guard let request else { throw MusicAutomationError.superseded }
                do { _ = try await session.playScriptedVideo(id, requestGeneration: request) }
                catch is CancellationError { throw CancellationError() }
                catch AppScriptingError.superseded { throw MusicAutomationError.superseded }
                catch AppScriptingError.signInRequired { throw MusicAutomationError.signInRequired }
                catch { throw MusicAutomationError.lookupFailed }
            case let .album(id): session.navigate(to: .collection(MusicCollection(id: id, kind: .album, title: AppLocalization.text("Album"))), recordHistory: true)
            case let .artist(id): session.navigate(to: .collection(MusicCollection(id: id, kind: .artist, title: AppLocalization.text("Artist"))), recordHistory: true)
            case let .playlist(id): session.navigate(to: .collection(MusicCollection(id: id, kind: .playlist, title: AppLocalization.text("Playlist"))), recordHistory: true)
            }
        case let .search(query):
            session.searchForAutomation(query)
        }
    }

    private func validate(_ action: MusicAutomationAction) throws -> MusicAutomationAction {
        switch action {
        case let .volume(value):
            guard value.isFinite, (0...100).contains(value) else { throw MusicAutomationError.invalidVolume }
        case let .playVideo(id):
            guard ScriptingInput.videoID(id) == id else { throw MusicAutomationError.invalidVideoID }
        case let .openLink(url):
            guard MusicLink(url: url) != nil else { throw MusicAutomationError.invalidLink }
        case let .search(query):
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 500,
                  !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw MusicAutomationError.invalidSearch
            }
            return .search(trimmed)
        default: break
        }
        return action
    }
}

extension AppSession: MusicAutomationSession {
    var automationState: MusicAutomationState {
        MusicAutomationState(isReady: hasFinishedStartup && !isShuttingDown && !account.isWorking && !showsAccount,
                             isSignedIn: account.isSignedIn, hasSelection: currentTrack != nil, hasNextSong: queue.hasNext)
    }

    func prepareForAutomation() async { await start() }

    func performAutomationTransport(_ action: MusicAutomationAction) {
        switch action {
        case .resume: play()
        case .pause: pause()
        case .next: next()
        case .previous: previous()
        default: break
        }
    }

    func searchForAutomation(_ query: String) {
        searchSuggestions.close(ignoringNextChangeTo: query)
        searchText = query
        search()
    }
}
