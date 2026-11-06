import Foundation

struct VolumeState {
    private(set) var lastAudibleVolume: Double = 0.7

    mutating func record(_ value: Double) {
        if value.isFinite, value > 0 { lastAudibleVolume = min(1, value) }
    }

    func toggledVolume(from current: Double) -> Double {
        current > 0 ? 0 : lastAudibleVolume
    }
}
