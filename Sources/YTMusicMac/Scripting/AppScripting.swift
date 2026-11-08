import AppKit
import CoreFoundation
import MusicCore
import YouTubeMusic

@MainActor
enum AppScripting {
    static weak var session: AppSession?
}

enum ScriptingInput {
    static func videoID(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.utf8.count == 11, id.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
        }) else { return nil }
        return id
    }

    static func volume(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let volume = number.doubleValue
        guard volume.isFinite, (0...1).contains(volume) else { return nil }
        return volume
    }
}

enum AppScriptingError: Error, Equatable, LocalizedError {
    case unavailable, invalidVideoID, signInRequired, noSelection, trackNotFound, superseded, lookupTimedOut, lookupFailed
    case libraryCheckTimedOut, libraryCheckFailed, playlistCheckFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: AppLocalization.text("The player is not ready. Wait for the app to finish opening.")
        case .invalidVideoID: AppLocalization.text("Use an 11-character YouTube video ID containing letters, digits, - or _.")
        case .signInRequired: AppLocalization.text("Sign in to YouTube Music in the app to continue.")
        case .noSelection: AppLocalization.text("Choose a song before starting playback.")
        case .trackNotFound: AppLocalization.text("The requested video ID was not found in YouTube Music.")
        case .superseded: AppLocalization.text("A newer playback or account action replaced this request.")
        case .lookupTimedOut: AppLocalization.text("The song lookup timed out.")
        case .lookupFailed: AppLocalization.text("YouTube Music could not look up the requested song.")
        case .libraryCheckTimedOut: AppLocalization.text("The library check timed out.")
        case .libraryCheckFailed: AppLocalization.text("YouTube Music could not complete the library check.")
        case .playlistCheckFailed: AppLocalization.text("The disposable playlist check could not complete. Check its cleanup status before trying again.")
        }
    }

    var scriptErrorNumber: Int {
        switch self {
        case .invalidVideoID: -1700
        case .unavailable, .noSelection, .trackNotFound: -1728
        case .superseded: -128
        case .lookupTimedOut, .libraryCheckTimedOut: -1712
        default: -10000
        }
    }
}

enum ScriptedTrackResolver {
    static func resolve(videoID: String, timeout: Duration = .seconds(20),
                        search: @escaping @Sendable (String) async throws -> MusicPage) async throws -> Track {
        guard ScriptingInput.videoID(videoID) == videoID else { throw AppScriptingError.invalidVideoID }
        return try await withThrowingTaskGroup(of: Track.self) { group in
            group.addTask {
                let page = try await search(videoID)
                try Task.checkCancellation()
                guard let track = page.tracks.first(where: { $0.id == videoID }) else { throw AppScriptingError.trackNotFound }
                return track
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AppScriptingError.lookupTimedOut
            }
            defer { group.cancelAll() }
            guard let track = try await group.next() else { throw AppScriptingError.lookupFailed }
            return track
        }
    }
}

/// A small status response for local automation. It contains no account identity or queue history.
struct ScriptingPlayerInfo: Encodable {
    let playing: Bool
    let buffering: Bool
    let signedIn: Bool
    let currentTrackID: String?
    let position: Double
    let duration: Double
    let volume: Double
    let queueCount: Int
    let error: String?

    init(playing: Bool, buffering: Bool, signedIn: Bool, currentTrackID: String?,
         position: Double, duration: Double, volume: Double, queueCount: Int, hasError: Bool,
         failureReason: PlaybackFailureReason? = nil) {
        self.playing = playing
        self.buffering = buffering
        self.signedIn = signedIn
        self.currentTrackID = currentTrackID
        self.position = position.isFinite ? max(0, position) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 0
        self.queueCount = max(0, queueCount)
        self.error = hasError ? (failureReason?.rawValue ?? "playbackUnavailable") : nil
    }

    @MainActor init(session: AppSession) {
        self.init(playing: session.player.isPlaying, buffering: session.player.isBuffering,
                  signedIn: session.account.isSignedIn, currentTrackID: session.currentTrack?.id,
                  position: session.player.clock.position, duration: session.player.clock.duration,
                  volume: session.player.volume, queueCount: session.queue.entries.count,
                  hasError: session.player.errorMessage != nil, failureReason: session.player.failureReason)
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
