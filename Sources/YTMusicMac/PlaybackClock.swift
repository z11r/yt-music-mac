import Foundation
import Observation

@MainActor
@Observable
final class PlaybackClock {
    var position: TimeInterval = 0
    var duration: TimeInterval = 0

    func update(position: TimeInterval, duration: TimeInterval) {
        self.position = position.isFinite ? max(0, position) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
    }

    func reset() {
        position = 0
        duration = 0
    }
}
