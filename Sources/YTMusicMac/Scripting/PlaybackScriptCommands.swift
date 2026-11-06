import AppKit

private func fail(_ command: NSScriptCommand, _ error: AppScriptingError) {
    command.scriptErrorNumber = error.scriptErrorNumber
    command.scriptErrorString = error.localizedDescription
}

private final class PendingQueueReply: @unchecked Sendable {
    private let command: NSScriptCommand
    init(_ command: NSScriptCommand) {
        precondition(Thread.isMainThread)
        self.command = command
    }
    @MainActor func finish(count: Int?, error: AppScriptingError?) {
        if let error { fail(command, error) }
        command.resumeExecution(withResult: count)
    }
}

@objc(YTMusicPlayVideosCommand)
final class PlayVideosScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let ids = QueueScriptingInput.videoIDs(directParameter) else {
            scriptErrorNumber = -1700
            scriptErrorString = "Use 1 to 100 video IDs, with at most 10 different songs."
            return nil
        }
        let request = MainActor.assumeIsolated { () -> Result<(AppSession, UUID), AppScriptingError> in
            guard let session = AppScripting.session else { return .failure(.unavailable) }
            guard session.account.isSignedIn else { return .failure(.signInRequired) }
            return .success((session, session.beginScriptedPlaybackRequest()))
        }
        guard case let .success((session, generation)) = request else {
            if case let .failure(error) = request { fail(self, error) }
            return nil
        }
        suspendExecution()
        let reply = PendingQueueReply(self)
        Task { @MainActor in
            do {
                let count = try await session.playScriptedVideos(ids, requestGeneration: generation)
                reply.finish(count: count, error: nil)
            } catch let error as AppScriptingError { reply.finish(count: nil, error: error) }
            catch is CancellationError { reply.finish(count: nil, error: .superseded) }
            catch { reply.finish(count: nil, error: .lookupFailed) }
        }
        return nil
    }
}

@objc(YTMusicSeekCommand)
final class SeekScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let position = QueueScriptingInput.position(directParameter) else {
            scriptErrorNumber = -1700
            scriptErrorString = "Use a finite position in seconds from 0 to 604800."
            return nil
        }
        let error = MainActor.assumeIsolated { () -> AppScriptingError? in
            guard let session = AppScripting.session else { return .unavailable }
            guard session.queue.currentOccurrence != nil, session.player.clock.duration > 0 else { return .noSelection }
            session.seek(to: min(position, session.player.clock.duration))
            return nil
        }
        if let error { fail(self, error); return nil }
        return true
    }
}

@objc(YTMusicNextCommand)
final class NextScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let error = MainActor.assumeIsolated { () -> AppScriptingError? in
            guard let session = AppScripting.session else { return .unavailable }
            guard session.queue.hasNext else { return .noSelection }
            session.next()
            return nil
        }
        if let error { fail(self, error); return nil }
        return true
    }
}

@objc(YTMusicPreviousCommand)
final class PreviousScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let error = MainActor.assumeIsolated { () -> AppScriptingError? in
            guard let session = AppScripting.session else { return .unavailable }
            guard session.currentTrack != nil else { return .noSelection }
            session.previous()
            return nil
        }
        if let error { fail(self, error); return nil }
        return true
    }
}

@objc(YTMusicSetRepeatCommand)
final class SetRepeatScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let mode = QueueScriptingInput.repeatMode(directParameter) else {
            scriptErrorNumber = -1700
            scriptErrorString = "Use off, all, or one for repeat."
            return nil
        }
        let error = MainActor.assumeIsolated { () -> AppScriptingError? in
            guard let session = AppScripting.session else { return .unavailable }
            session.setRepeatMode(mode)
            return nil
        }
        if let error { fail(self, error); return nil }
        return true
    }
}

@objc(YTMusicPlaybackSnapshotCommand)
final class PlaybackSnapshotScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let result = MainActor.assumeIsolated { () -> Result<String, AppScriptingError> in
            guard let session = AppScripting.session else { return .failure(.unavailable) }
            guard let json = try? ScriptingPlaybackSnapshot(session: session).json() else { return .failure(.unavailable) }
            return .success(json)
        }
        switch result {
        case let .success(json): return json
        case let .failure(error): fail(self, error); return nil
        }
    }
}
