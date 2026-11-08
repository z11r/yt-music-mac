import Foundation

public enum ListeningStartIntent: Sendable, Equatable { case newListen, continuation }

public struct ListenMetadata: Codable, Equatable, Sendable {
    public let trackID: String
    public let title: String
    public let artist: String
    public let album: String?
    public var isValid: Bool {
        func valid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
        return !LocalAudioReference.isReservedTrackID(trackID) && !trackID.isEmpty && trackID.utf8.count <= 256 && valid(title) && valid(artist) &&
            !Self.isUnknownArtist(artist) && (album.map(valid) ?? true)
    }

    // Native fallback labels are metadata absence, in every shipped locale.
    private static func isUnknownArtist(_ value: String) -> Bool {
        ["unknown artist", "artiste inconnu"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public init?(track: Track) {
        func field(_ value: String) -> String? {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? value : nil
        }
        guard track.isExplicitCatalogSong,
              !track.id.isEmpty, track.id.utf8.count <= 256,
              let title = field(track.title), let artist = field(track.artist), !Self.isUnknownArtist(artist) else { return nil }
        self.trackID = track.id; self.title = title; self.artist = artist; self.album = track.album.flatMap(field)
    }
}

public struct EarnedListen: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let entryID: UUID
    public let metadata: ListenMetadata
    public let listenedAt: Int
    public let duration: TimeInterval
    public init(id: UUID = UUID(), entryID: UUID, metadata: ListenMetadata, listenedAt: Int, duration: TimeInterval) {
        self.id = id; self.entryID = entryID; self.metadata = metadata; self.listenedAt = listenedAt; self.duration = duration
    }
}

public struct ListeningReceipt: Codable, Equatable, Sendable {
    public let entryID: UUID
    public let trackID: String
    public let listenID: UUID
}

public struct ListeningPlay: Codable, Equatable, Sendable {
    public let id: UUID
    public let entryID: UUID
    public let metadata: ListenMetadata
    public var listenedAt: Int?
    public var heardSeconds: TimeInterval = 0
    public var duration: TimeInterval = 0
    public var queued = false
    public var suppressed = false
    public var ended = false
}

public struct ListeningLedgerState: Codable, Equatable, Sendable {
    public var current: ListeningPlay?
    public var receipts: [ListeningReceipt] = []
    public init() { }

    public func validate() -> Bool {
        guard receipts.count <= 400, Set(receipts.map(\.entryID)).count == receipts.count,
              receipts.allSatisfy({ !LocalAudioReference.isReservedTrackID($0.trackID) && !$0.trackID.isEmpty && $0.trackID.utf8.count <= 256 }) else { return false }
        guard let current else { return true }
        return current.metadata.isValid && current.heardSeconds.isFinite && current.heardSeconds >= 0 && current.heardSeconds <= 2_073_600 &&
            current.duration.isFinite && (0...2_073_600).contains(current.duration) &&
            (current.listenedAt.map { $0 >= 1_033_430_400 } ?? true)
    }
}

/// Counts adjacent, verified media/wall-clock intervals. Position jumps, pause,
/// buffering, ads, document replacement and seeks break the transient anchor.
public struct ListeningLedger: Sendable {
    public private(set) var state: ListeningLedgerState
    private var occurrence: PlaybackOccurrence?
    private var anchor: (position: Double, time: Double)?

    public init(state: ListeningLedgerState = .init()) { self.state = state }

    public mutating func begin(track: Track, occurrence: PlaybackOccurrence, intent: ListeningStartIntent) {
        anchor = nil; self.occurrence = occurrence
        guard let metadata = ListenMetadata(track: track), occurrence.trackID == track.id else { state.current = nil; return }
        if intent == .continuation, let current = state.current,
           current.entryID == occurrence.entryID, current.metadata.trackID == track.id { return }
        var play = ListeningPlay(id: UUID(), entryID: occurrence.entryID, metadata: metadata)
        // A recovered selection without its original ledger cannot establish a
        // second listen. An explicit new play or natural repeat starts afresh.
        if intent == .continuation { play.suppressed = true }
        state.current = play
    }

    public mutating func interrupt() { anchor = nil }

    /// A consent change cannot resume collecting a partially heard old play.
    /// A later explicit new play creates a new logical listen as usual.
    public mutating func suspendCurrent() {
        anchor = nil
        state.current?.suppressed = true
    }

    public mutating func sample(occurrence: PlaybackOccurrence, position: Double, duration: Double,
                                monotonicTime: Double, wallTime: Date, ended: Bool = false) -> EarnedListen? {
        guard self.occurrence == occurrence, var play = state.current, !play.ended,
              position.isFinite, position > 0, duration.isFinite, (30.000_001...2_073_600).contains(duration),
              position <= duration + 2, monotonicTime.isFinite, monotonicTime >= 0, wallTime.timeIntervalSince1970 >= 1_033_430_400,
              wallTime.timeIntervalSince1970 < Double(Int.max) else { anchor = nil; return nil }
        if play.listenedAt == nil { play.listenedAt = Int(wallTime.timeIntervalSince1970) }
        play.duration = duration
        if let anchor {
            let elapsed = monotonicTime - anchor.time
            guard elapsed > 0 else { return nil }
            let advanced = position - anchor.position
            if elapsed > 0, elapsed <= 2.5, advanced > 0, advanced <= elapsed * 1.1 + 0.2 {
                play.heardSeconds = min(2_073_600, play.heardSeconds + min(elapsed, advanced))
            }
        }
        anchor = ended ? nil : (position, monotonicTime)
        play.ended = ended
        state.current = play
        guard !play.suppressed, !play.queued, play.heardSeconds >= min(duration / 2, 240), let listenedAt = play.listenedAt else { return nil }
        return EarnedListen(id: play.id, entryID: play.entryID, metadata: play.metadata, listenedAt: listenedAt, duration: duration)
    }

    public mutating func markQueued(_ listen: EarnedListen) {
        guard state.current?.id == listen.id else { return }
        state.current?.queued = true
        state.receipts.removeAll { $0.entryID == listen.entryID }
        state.receipts.append(.init(entryID: listen.entryID, trackID: listen.metadata.trackID, listenID: listen.id))
        if state.receipts.count > 400 { state.receipts.removeFirst(state.receipts.count - 400) }
    }
}
