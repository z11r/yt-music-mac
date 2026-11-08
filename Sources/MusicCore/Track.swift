import Foundation

public struct Track: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var artist: String
    public var album: String?
    public var artworkURL: URL?
    public var duration: TimeInterval?
    public var albumReference: TrackMetadataReference?
    public var artistReferences: [TrackMetadataReference]?
    /// True when a service badge establishes explicit content; nil means unknown.
    public var isExplicit: Bool?

    public init(
        id: String,
        title: String,
        artist: String,
        album: String? = nil,
        artworkURL: URL? = nil,
        duration: TimeInterval? = nil,
        albumReference: TrackMetadataReference? = nil,
        artistReferences: [TrackMetadataReference]? = nil,
        isExplicit: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.duration = duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.albumReference = albumReference
        self.artistReferences = artistReferences
        self.isExplicit = isExplicit
    }
}

public struct QueueEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var track: Track

    public init(id: UUID = UUID(), track: Track) {
        self.id = id
        self.track = track
    }
}

public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off
    case all
    case one
}

/// Identifies one arrangement of a queue's entries. Work started for one revision must not apply to another.
public struct QueueRevision: Hashable, Sendable {
    let queueID: UUID
    let edit: UInt64

    init(queueID: UUID, edit: UInt64) {
        self.queueID = queueID
        self.edit = edit
    }
}

/// Identifies one requested play of a queue entry, including repeated plays.
public struct PlaybackOccurrence: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let entryID: UUID
    public let trackID: String
    public let generation: UInt64

    public init(sessionID: UUID, entryID: UUID, trackID: String, generation: UInt64) {
        self.sessionID = sessionID
        self.entryID = entryID
        self.trackID = trackID
        self.generation = generation
    }
}
