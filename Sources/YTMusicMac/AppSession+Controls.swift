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

    /// Opens a sidebar destination from a menu command. Choosing the page that
    /// is already shown keeps it, as the sidebar does.
    func show(_ target: MusicDestination) {
        guard target != destination else { return }
        navigate(to: target)
    }
}
