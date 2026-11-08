import Foundation

/// Content provenance, separate from a playback video ID or queue occurrence.
public enum MusicContentOrigin: String, Codable, Hashable, Sendable { case catalog, upload, localFile }

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
    public var origin: MusicContentOrigin?
    public var contentKind: MusicContentKind?
    public var episode: EpisodeMetadata?
    public var creditsReference: SongCreditsReference?
    /// Opaque profile-library identity only. File locations and grants live in the local library.
    public var localAudioReference: LocalAudioReference?

    public init(
        id: String,
        title: String,
        artist: String,
        album: String? = nil,
        artworkURL: URL? = nil,
        duration: TimeInterval? = nil,
        albumReference: TrackMetadataReference? = nil,
        artistReferences: [TrackMetadataReference]? = nil,
        isExplicit: Bool? = nil,
        origin: MusicContentOrigin? = nil,
        contentKind: MusicContentKind? = nil,
        episode: EpisodeMetadata? = nil,
        creditsReference: SongCreditsReference? = nil,
        localAudioReference: LocalAudioReference? = nil
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
        self.origin = origin
        self.contentKind = contentKind
        self.episode = episode
        self.creditsReference = creditsReference
        self.localAudioReference = localAudioReference
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, album, artworkURL, duration, albumReference, artistReferences, isExplicit
        case origin, contentKind, episode, creditsReference, localAudioReference
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        artist = try values.decode(String.self, forKey: .artist)
        album = try values.decodeIfPresent(String.self, forKey: .album)
        artworkURL = try values.decodeIfPresent(URL.self, forKey: .artworkURL)
        duration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration)
        albumReference = try values.decodeIfPresent(TrackMetadataReference.self, forKey: .albumReference)
        artistReferences = try values.decodeIfPresent([TrackMetadataReference].self, forKey: .artistReferences)
        isExplicit = try values.decodeIfPresent(Bool.self, forKey: .isExplicit)
        origin = try values.decodeIfPresent(MusicContentOrigin.self, forKey: .origin)
        contentKind = try values.decodeIfPresent(MusicContentKind.self, forKey: .contentKind)
        episode = try values.decodeIfPresent(EpisodeMetadata.self, forKey: .episode)
        creditsReference = try values.decodeIfPresent(SongCreditsReference.self, forKey: .creditsReference)
        localAudioReference = try values.decodeIfPresent(LocalAudioReference.self, forKey: .localAudioReference)
        try validateLocalAudioSource()
    }
}

public struct QueueEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var track: Track
    public let origin: QueueEntryOrigin

    public init(id: UUID = UUID(), track: Track, origin: QueueEntryOrigin = .manual) {
        self.id = id
        self.track = track
        self.origin = origin
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        track = try container.decode(Track.self, forKey: .track)
        origin = try container.decodeIfPresent(QueueEntryOrigin.self, forKey: .origin) ?? .unknown
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
