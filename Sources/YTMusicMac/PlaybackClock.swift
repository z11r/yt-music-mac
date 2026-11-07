import Foundation
import Observation

/// Playback position for logic and display.
///
/// The page reports progress about once a second. Views observe only values
/// that change what they show, so a progress report that stays within the same
/// second does not redraw anything.
@MainActor
@Observable
final class PlaybackClock {
    /// Exact position for playback logic. Not observed, so reading it does not
    /// make a view redraw on every progress report.
    @ObservationIgnored private(set) var position: TimeInterval = 0
    /// Whole elapsed seconds for display.
    private(set) var elapsedSeconds = 0
    private(set) var duration: TimeInterval = 0
    /// Previous restarts the song after three seconds.
    private(set) var isPastRestartThreshold = false

    func update(position: TimeInterval, duration: TimeInterval) {
        let position = position.isFinite ? max(0, position) : 0
        let duration = duration.isFinite ? max(0, duration) : 0
        self.position = position
        let seconds = Int(min(position, 359_999))
        if self.elapsedSeconds != seconds { self.elapsedSeconds = seconds }
        if self.duration != duration { self.duration = duration }
        let pastThreshold = position > 3
        if self.isPastRestartThreshold != pastThreshold { self.isPastRestartThreshold = pastThreshold }
    }

    func reset() {
        update(position: 0, duration: 0)
    }
}
