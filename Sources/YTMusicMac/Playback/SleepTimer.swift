import Foundation
import MusicCore
import Observation

/// A sleep timer uses a continuous deadline, including time the Mac spends asleep.
/// No task or wall clock is needed to test its expiry and occurrence decisions.
struct SleepTimerState: Equatable {
    enum Schedule: Equatable {
        case off
        case deadline(ContinuousClock.Instant)
        case endOfTrack(PlaybackOccurrence)
    }

    private(set) var schedule: Schedule = .off
    /// An expiry holds queue-end autoplay until another explicit playback request.
    private(set) var blocksAutoplay = false

    @discardableResult mutating func arm(after duration: Duration, now: ContinuousClock.Instant) -> Bool {
        guard duration > .zero, duration <= .seconds(86_400) else { return false }
        schedule = .deadline(now.advanced(by: duration))
        blocksAutoplay = false
        return true
    }

    mutating func armAtEnd(of occurrence: PlaybackOccurrence) {
        schedule = .endOfTrack(occurrence)
        blocksAutoplay = false
    }

    mutating func cancel() {
        schedule = .off
        blocksAutoplay = false
    }

    mutating func allowPlayback() { blocksAutoplay = false }

    /// A retry of the same queue entry keeps its end timer; another entry cancels it.
    mutating func bind(to occurrence: PlaybackOccurrence) {
        guard case let .endOfTrack(previous) = schedule else { return }
        if previous.sessionID == occurrence.sessionID, previous.entryID == occurrence.entryID,
           previous.trackID == occurrence.trackID {
            schedule = .endOfTrack(occurrence)
        } else {
            cancel()
        }
    }

    @discardableResult mutating func expireIfNeeded(at now: ContinuousClock.Instant) -> Bool {
        guard case let .deadline(deadline) = schedule, now >= deadline else { return false }
        expire()
        return true
    }

    /// Returns whether the ending must stop instead of advancing or repeating.
    mutating func consumeEnd(_ occurrence: PlaybackOccurrence) -> Bool {
        if blocksAutoplay { return true }
        guard case let .endOfTrack(target) = schedule, target == occurrence else { return false }
        expire()
        return true
    }

    private mutating func expire() {
        schedule = .off
        blocksAutoplay = true
    }
}

@MainActor @Observable
final class SleepTimer {
    private(set) var state = SleepTimerState()
    private(set) var displayDeadline: Date?
    @ObservationIgnored var onExpired: (() -> Void)?
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let wallNow: () -> Date
    @ObservationIgnored private let sleepUntil: (ContinuousClock.Instant) async throws -> Void
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(now: @escaping () -> ContinuousClock.Instant = { .now },
         wallNow: @escaping () -> Date = Date.init,
         sleepUntil: @escaping (ContinuousClock.Instant) async throws -> Void = {
             try await ContinuousClock().sleep(until: $0)
         }) {
        self.now = now
        self.wallNow = wallNow
        self.sleepUntil = sleepUntil
    }

    deinit { timerTask?.cancel() }

    var blocksAutoplay: Bool { state.blocksAutoplay }
    var isArmed: Bool { state.schedule != .off }
    var label: String {
        if blocksAutoplay { return AppLocalization.text("Finished") }
        switch state.schedule {
        case .off: return AppLocalization.text("Off")
        case .endOfTrack: return AppLocalization.text("End of Current Song")
        case .deadline:
            return displayDeadline.map { AppLocalization.format("Until %@", $0.formatted(date: .omitted, time: .shortened)) }
                ?? AppLocalization.text("Timer On")
        }
    }

    func start(minutes: Int) {
        guard (1...1_440).contains(minutes) else { return }
        let duration = Duration.seconds(minutes * 60)
        guard state.arm(after: duration, now: now()), case let .deadline(deadline) = state.schedule else { return }
        invalidateTask()
        displayDeadline = wallNow().addingTimeInterval(Double(minutes * 60))
        let request = generation
        let wait = sleepUntil
        timerTask = Task { [weak self] in
            do { try await wait(deadline) }
            catch { return }
            guard !Task.isCancelled, let self, self.generation == request else { return }
            self.expireIfNeeded()
        }
    }

    func stopAtEnd(of occurrence: PlaybackOccurrence) {
        invalidateTask()
        displayDeadline = nil
        state.armAtEnd(of: occurrence)
    }

    func cancel() {
        invalidateTask()
        displayDeadline = nil
        state.cancel()
    }

    func allowPlayback() { state.allowPlayback() }
    func bind(to occurrence: PlaybackOccurrence) { state.bind(to: occurrence) }

    @discardableResult func expireIfNeeded() -> Bool {
        guard state.expireIfNeeded(at: now()) else { return false }
        didExpire()
        return true
    }

    func consumeEnd(_ occurrence: PlaybackOccurrence) -> Bool {
        let alreadyExpired = blocksAutoplay
        guard state.consumeEnd(occurrence) else { return false }
        if !alreadyExpired { didExpire() }
        return true
    }

    private func didExpire() {
        invalidateTask()
        displayDeadline = nil
        onExpired?()
    }

    private func invalidateTask() {
        generation = UUID()
        timerTask?.cancel()
        timerTask = nil
    }
}
