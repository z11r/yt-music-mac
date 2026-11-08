import Foundation

/// Volume changes made by keyboard commands, in whole percent.
enum VolumeStep {
    static let percent = 10

    static func adjusted(_ volume: Double, by steps: Int) -> Double {
        guard volume.isFinite else { return 0 }
        let current = Int((min(1, max(0, volume)) * 100).rounded())
        return Double(min(100, max(0, current + steps * percent))) / 100
    }
}

extension AppSession {
    func increaseVolume() { setVolume(VolumeStep.adjusted(player.volume, by: 1)) }
    func decreaseVolume() { setVolume(VolumeStep.adjusted(player.volume, by: -1)) }

    var canSeek: Bool { currentTrack != nil && player.clock.duration > 0 }

    func seekBy(_ seconds: TimeInterval) {
        guard acceptsProfileActions else { return }
        guard canSeek, seconds.isFinite else { return }
        let duration = player.clock.duration
        let target = min(duration, max(0, player.clock.position + seconds))
        // Repeated presses build on the requested position while the page
        // catches up. Save that position through the normal seek action.
        player.clock.update(position: target, duration: duration)
        seek(to: target)
    }

    /// Opens a sidebar destination from a menu command. Choosing the page that
    /// is already shown keeps it, as the sidebar does.
    func show(_ target: MusicDestination) {
        guard target != destination else { return }
        navigate(to: target)
    }
}
