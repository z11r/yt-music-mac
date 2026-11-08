import Foundation
import MediaPlayer

@MainActor
final class SystemMediaControls {
    private weak var session: AppSession?
    private var registrations: [(MPRemoteCommand, Any)] = []

    init(session: AppSession) {
        self.session = session
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { $0.play() }
        register(center.pauseCommand) { $0.pause() }
        register(center.togglePlayPauseCommand) { $0.togglePlayback() }
        register(center.nextTrackCommand) { $0.next() }
        register(center.previousTrackCommand) { $0.previous() }
        let token = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  event.positionTime.isFinite, event.positionTime >= 0 else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor [weak self] in self?.session?.seek(to: position) }
            return .success
        }
        registrations.append((center.changePlaybackPositionCommand, token))
        refresh()
    }

    func stop() {
        guard session != nil else { return }
        // Remove precisely this owner's tokens, never another owner's targets.
        for (command, token) in registrations { command.removeTarget(token) }
        registrations.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        session = nil
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor (AppSession) -> Void) {
        let token = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let session = self?.session else { return }
                action(session)
            }
            return .success
        }
        registrations.append((command, token))
    }

    func refresh() {
        guard let session else { return }
        let center = MPRemoteCommandCenter.shared()
        let hasTrack = session.currentTrack != nil
        center.playCommand.isEnabled = hasTrack
        center.pauseCommand.isEnabled = hasTrack
        center.togglePlayPauseCommand.isEnabled = hasTrack
        center.nextTrackCommand.isEnabled = session.queue.hasNext
        center.previousTrackCommand.isEnabled = hasTrack
        center.changePlaybackPositionCommand.isEnabled = session.player.clock.duration > 0
        guard let track = session.currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: session.player.clock.position,
            MPNowPlayingInfoPropertyPlaybackRate: session.player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.id,
        ]
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        let duration = session.player.clock.duration > 0 ? session.player.clock.duration : track.duration ?? 0
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = session.player.isPlaying ? .playing : .paused
    }
}
