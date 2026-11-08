import AppKit
import YouTubeMusic

private func setScriptError(_ command: NSScriptCommand, _ error: AppScriptingError) {
    command.scriptErrorNumber = error.scriptErrorNumber
    command.scriptErrorString = error.localizedDescription
}

private struct ScriptedPlaybackOperation: Sendable {
    let session: AppSession
    let videoID: String
    let requestGeneration: UUID

    @MainActor func execute() async throws -> String {
        try await session.playScriptedVideo(videoID, requestGeneration: requestGeneration)
    }
}

/// Cocoa creates commands on the main thread. Only the main actor accesses the retained command after suspension.
private final class SuspendedScriptReply: @unchecked Sendable {
    private let command: NSScriptCommand

    init(_ command: NSScriptCommand) {
        precondition(Thread.isMainThread)
        self.command = command
    }

    @MainActor func resume(result: String?, error: AppScriptingError?) {
        if let error { setScriptError(command, error) }
        command.resumeExecution(withResult: result)
    }
}

@objc(YTMusicPlayVideoCommand)
final class PlayVideoScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let videoID = ScriptingInput.videoID(directParameter) else {
            setScriptError(self, .invalidVideoID)
            return nil
        }
        let preparation = MainActor.assumeIsolated { () -> Result<ScriptedPlaybackOperation, AppScriptingError> in
            guard let session = AppScripting.session else { return .failure(.unavailable) }
            guard session.account.isSignedIn else { return .failure(.signInRequired) }
            return .success(ScriptedPlaybackOperation(session: session, videoID: videoID,
                requestGeneration: session.beginScriptedPlaybackRequest()))
        }
        guard case let .success(operation) = preparation else {
            if case let .failure(error) = preparation { setScriptError(self, error) }
            return nil
        }
        suspendExecution()
        let reply = SuspendedScriptReply(self)
        Task { @MainActor in
            do { reply.resume(result: try await operation.execute(), error: nil) }
            catch let error as AppScriptingError { reply.resume(result: nil, error: error) }
            catch is CancellationError { reply.resume(result: nil, error: .superseded) }
            catch { reply.resume(result: nil, error: .lookupFailed) }
        }
        return nil
    }
}

@objc(YTMusicPlayCommand)
final class PlayScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let failure = MainActor.assumeIsolated { () -> AppScriptingError? in
            guard let session = AppScripting.session else { return .unavailable }
            guard session.account.isSignedIn else { return .signInRequired }
            guard session.currentTrack != nil else { return .noSelection }
            session.play()
            return nil
        }
        if let failure { setScriptError(self, failure); return nil }
        return true
    }
}

@objc(YTMusicPauseCommand)
final class PauseScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let failure = MainActor.assumeIsolated { () -> AppScriptingError? in
            guard let session = AppScripting.session else { return .unavailable }
            session.pause()
            return nil
        }
        if let failure { setScriptError(self, failure); return nil }
        return true
    }
}

@objc(YTMusicSetVolumeCommand)
final class SetVolumeScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let volume = ScriptingInput.volume(directParameter) else {
            scriptErrorNumber = -1700
            scriptErrorString = AppLocalization.text("Use a volume between 0.0 and 1.0.")
            return nil
        }
        let failure = MainActor.assumeIsolated { () -> AppScriptingError? in
            guard let session = AppScripting.session else { return .unavailable }
            session.setVolume(volume)
            return nil
        }
        if let failure { setScriptError(self, failure); return nil }
        return true
    }
}

@objc(YTMusicGetPlayerInfoCommand)
final class GetPlayerInfoScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let result = MainActor.assumeIsolated { () -> Result<String, AppScriptingError> in
            guard let session = AppScripting.session else { return .failure(.unavailable) }
            do { return .success(try ScriptingPlayerInfo(session: session).json()) }
            catch { return .failure(.unavailable) }
        }
        switch result {
        case let .success(json): return json
        case let .failure(error): setScriptError(self, error); return nil
        }
    }
}

@objc(YTMusicCheckLibraryCommand)
final class CheckLibraryScriptCommand: LibraryReadScriptCommand {}

@objc(YTMusicCheckLibraryNavigationCommand)
final class CheckLibraryNavigationScriptCommand: LibraryReadScriptCommand {
    override var checksNavigation: Bool { true }
}

class LibraryReadScriptCommand: NSScriptCommand {
    var checksNavigation: Bool { false }

    override func performDefaultImplementation() -> Any? {
        let session = MainActor.assumeIsolated { AppScripting.session }
        guard let session else { setScriptError(self, .unavailable); return nil }
        guard MainActor.assumeIsolated({ session.account.isSignedIn }) else {
            setScriptError(self, .signInRequired)
            return nil
        }
        suspendExecution()
        let reply = SuspendedScriptReply(self)
        let navigation = checksNavigation
        Task { @MainActor in
            do {
                let report = try await navigation ? session.checkLibraryNavigation() : session.checkLibrary()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                reply.resume(result: String(decoding: try encoder.encode(report), as: UTF8.self), error: nil)
            } catch let error as AppScriptingError {
                reply.resume(result: nil, error: error)
            } catch MusicLibraryCheckError.timedOut {
                reply.resume(result: nil, error: .libraryCheckTimedOut)
            } catch MusicServiceError.sessionChanged {
                reply.resume(result: nil, error: .superseded)
            } catch MusicServiceError.signInRequired {
                reply.resume(result: nil, error: .signInRequired)
            } catch is CancellationError {
                reply.resume(result: nil, error: .superseded)
            } catch {
                reply.resume(result: nil, error: .libraryCheckFailed)
            }
        }
        return nil
    }
}

/// Explicitly creates and deletes a new private playlist. Never runs on launch.
@objc(YTMusicCheckPlaylistEditsCommand)
final class CheckPlaylistEditsScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let videoID = ScriptingInput.videoID(directParameter) else {
            setScriptError(self, .invalidVideoID)
            return nil
        }
        return beginPlaylistVerificationReply(self, videoID: videoID)
    }
}

@objc(YTMusicRetryPlaylistCleanupCommand)
final class RetryPlaylistCleanupScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        beginPlaylistVerificationReply(self, videoID: nil)
    }
}

private func beginPlaylistVerificationReply(_ command: NSScriptCommand, videoID: String?) -> Any? {
    let session = MainActor.assumeIsolated { AppScripting.session }
    guard let session else { setScriptError(command, .unavailable); return nil }
    guard MainActor.assumeIsolated({ session.account.isSignedIn }) else {
        setScriptError(command, .signInRequired)
        return nil
    }
    command.suspendExecution()
    let reply = SuspendedScriptReply(command)
    Task { @MainActor in
        do {
            let client = session.playlistVerificationClient
            let scope = try await client.libraryEditScope()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data: Data
            if let videoID {
                data = try encoder.encode(await client.checkPlaylistEdits(videoID: videoID, expectedScope: scope))
            } else {
                data = try encoder.encode(await client.retryPlaylistEditCleanup(expectedScope: scope))
            }
            reply.resume(result: String(decoding: data, as: UTF8.self), error: nil)
        } catch MusicServiceError.sessionChanged {
            reply.resume(result: nil, error: .superseded)
        } catch MusicServiceError.signInRequired {
            reply.resume(result: nil, error: .signInRequired)
        } catch {
            reply.resume(result: nil, error: .playlistCheckFailed)
        }
    }
    return nil
}
