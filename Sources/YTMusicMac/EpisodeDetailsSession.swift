import Foundation
import MusicCore
import Observation
import YouTubeMusic

/// Shared across profile controllers: a canceled read keeps its only slot until
/// the underlying fetch actually settles. No background worker exists while idle.
@MainActor @Observable final class EpisodeDetailsReadAdmission {
    static let shared = EpisodeDetailsReadAdmission()
    private(set) var isBusy = false
    @ObservationIgnored private var ticket: UUID?
    func reserve() -> UUID? {
        guard !isBusy else { return nil }
        let value = UUID(); ticket = value; isBusy = true; return value
    }
    func release(_ value: UUID) {
        guard ticket == value else { return }
        ticket = nil; isBusy = false
    }
}

struct EpisodeTimestampSource: Equatable {
    let requestID: UUID
    let reference: MusicEpisodeDetailsReference
    let sourceIndex: Int
    let seconds: Int
}

@MainActor @Observable final class EpisodeDetailsSession {
    enum State: Equatable { case idle, loading, unavailable, failed, canceled, available(MusicEpisodeDetails) }
    private var selectedTrack: Track?
    private var storedState: State = .idle
    @ObservationIgnored private let snapshot: @Sendable () async -> UUID
    @ObservationIgnored private let fetch: @Sendable (MusicEpisodeDetailsReference, UUID) async throws -> MusicEpisodeDetailsResult
    @ObservationIgnored private let admission: EpisodeDetailsReadAdmission
    @ObservationIgnored private var ownerIsCurrent: (@MainActor () -> Bool)?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var workerID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    var isBusy: Bool { admission.isBusy }
    var isPresented: Bool { selectedTrack != nil && ownerIsCurrent?() == true }
    var track: Track? { isPresented ? selectedTrack : nil }
    var state: State { isPresented ? storedState : .idle }

    init(admission: EpisodeDetailsReadAdmission? = nil, snapshot: @escaping @Sendable () async -> UUID,
         fetch: @escaping @Sendable (MusicEpisodeDetailsReference, UUID) async throws -> MusicEpisodeDetailsResult) {
        self.admission = admission ?? .shared; self.snapshot = snapshot; self.fetch = fetch
    }
    static func reference(for track: Track) -> MusicEpisodeDetailsReference? {
        guard track.isServiceTrack, track.origin != .upload, track.contentKind == .podcastEpisode,
              let episode = track.episode else { return nil }
        return .init(identity: episode.identity, videoID: track.id)
    }
    @discardableResult func open(track: Track, isCurrent: @escaping @MainActor () -> Bool) -> Bool {
        guard isCurrent(), let reference = Self.reference(for: track), let ticket = admission.reserve() else { return false }
        requestID = UUID(); let id = requestID
        selectedTrack = track; ownerIsCurrent = isCurrent; storedState = .loading; workerID = ticket
        task = Task { [weak self, snapshot, fetch, admission] in
            defer {
                if let self, self.workerID == ticket { self.workerID = nil; self.task = nil }
                admission.release(ticket)
            }
            guard let self, self.accepts(id) else { return }
            let scope = await snapshot()
            guard self.accepts(id) else { return }
            do {
                let result = try await fetch(reference, scope)
                guard self.accepts(id) else { return }
                let confirmed = await snapshot()
                guard self.accepts(id) else { return }
                guard scope == confirmed else { self.clear(); return }
                switch result {
                case .unavailable: self.storedState = .unavailable
                case let .available(details):
                    guard details.reference == reference else { self.storedState = .failed; return }
                    self.storedState = .available(details)
                }
            } catch {
                guard self.accepts(id) else { return }
                let confirmed = await snapshot()
                guard self.accepts(id) else { return }
                guard scope == confirmed else { self.clear(); return }
                self.storedState = .failed
            }
        }
        return true
    }
    func timestampSource(at index: Int) -> EpisodeTimestampSource? {
        guard isPresented, case let .available(details) = storedState,
              let value = details.timestamps.first(where: { $0.sourceIndex == index }) else { return nil }
        return .init(requestID: requestID, reference: details.reference, sourceIndex: value.sourceIndex, seconds: value.seconds)
    }
    func acceptsTimestamp(_ source: EpisodeTimestampSource) -> Bool { timestampSource(at: source.sourceIndex) == source }
    func retry() {
        guard let track, let ownerIsCurrent, ownerIsCurrent() else { clear(); return }
        _ = open(track: track, isCurrent: ownerIsCurrent)
    }
    func cancel() { requestID = UUID(); task?.cancel(); storedState = .canceled }
    func clear() {
        requestID = UUID(); task?.cancel()
        // Do not drop the active worker or its admission before actual settlement.
        selectedTrack = nil; ownerIsCurrent = nil; storedState = .idle
    }
    func discardIfStale() { if ownerIsCurrent?() == false { clear() } }
    func waitForIdle() async { await task?.value }
    private func accepts(_ id: UUID) -> Bool { !Task.isCancelled && requestID == id && ownerIsCurrent?() == true }
}

enum EpisodeDetailsText {
    static func text(_ key: StaticString) -> String {
        AppLocalization.bundle.localizedString(forKey: String(describing: key), value: nil, table: "EpisodeDetails")
    }
}

/// Source positions are whole seconds bounded by the episode-details parser.
/// Formatting preserves the full admitted range instead of clamping transport time.
enum EpisodeDetailsTimestampFormatter {
    static func text(_ seconds: Int) -> String? {
        guard (0...604_800).contains(seconds) else { return nil }
        func twoDigits(_ value: Int) -> String { value < 10 ? "0" + String(value) : String(value) }
        let tail = twoDigits(seconds / 60 % 60) + ":" + twoDigits(seconds % 60)
        return seconds >= 3_600 ? String(seconds / 3_600) + ":" + tail : String(seconds / 60) + ":" + twoDigits(seconds % 60)
    }
}
