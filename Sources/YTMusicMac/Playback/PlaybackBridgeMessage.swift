import Foundation
import MusicCore

struct PlaybackBridgeIdentity: Codable, Equatable {
    let sessionID: UUID
    let entryID: UUID
    let trackID: String
    let generation: String

    init(_ occurrence: PlaybackOccurrence) {
        self.sessionID = occurrence.sessionID
        self.entryID = occurrence.entryID
        self.trackID = occurrence.trackID
        self.generation = String(occurrence.generation)
    }
}

struct PlaybackBridgeMessage: Decodable {
    enum Kind: String, Decodable {
        case ready, state, progress, ended, error
    }
    enum IntentSource: String, Decodable { case native, page }

    let kind: Kind
    let loadID: UUID
    let identity: PlaybackBridgeIdentity
    let documentID: UUID
    let mediaGeneration: Int
    let sequence: Int
    let commandRevision: Int
    let playbackIntent: Bool
    let intentSource: IntentSource
    let videoID: String
    let position: Double
    let duration: Double
    let volume: Double
    let isPlaying: Bool
    let isBuffering: Bool
    let isAd: Bool
    let mediaReady: Bool
    let errorCode: String?
    let videoPresentation: VideoPresentationSnapshot?
    let episodeRateMedia: EpisodeRateMedia?

    static func decode(_ body: Any) -> Self? {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              data.count <= 16_384,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.mediaGeneration >= 0, value.sequence > 0, value.commandRevision >= 0,
              value.position.isFinite, value.position >= 0,
              value.duration.isFinite, value.duration >= 0,
              value.volume.isFinite, (0...1).contains(value.volume)
        else { return nil }
        return value
    }

    /// The song itself, not an advertisement or a loading state, is advancing.
    var confirmsContentPlayback: Bool {
        self.kind != .error && self.kind != .ended && self.isPlaying && !self.isBuffering
            && self.mediaReady && !self.isAd
    }

    var confirmsEpisodeProgress: Bool {
        !isAd && mediaReady && !isBuffering && position > 0 && duration > 0 &&
            (confirmsContentPlayback || kind == .ended)
    }

    /// Valid playing state updates (such as volume) keep public metadata active.
    /// Missing content, ads, pause and buffering must clear it immediately.
    var interruptsPlaybackOutput: Bool { !confirmsEpisodeProgress }

    func acceptsPagePause(latestCommandRevision: Int) -> Bool {
        (self.kind == .state || self.kind == .progress) && self.intentSource == .page
            && !self.playbackIntent && !self.isPlaying && self.mediaReady && !self.isAd
            && self.commandRevision == latestCommandRevision
    }
}

struct PlaybackEventGate {
    private(set) var loadID: UUID?
    private(set) var identity: PlaybackBridgeIdentity?
    private(set) var documentID: UUID?
    private var sequence = 0
    private(set) var mediaGeneration = 0
    private var consumedEnd = false

    mutating func activate(loadID: UUID, occurrence: PlaybackOccurrence) {
        self = Self()
        self.loadID = loadID
        self.identity = PlaybackBridgeIdentity(occurrence)
    }

    mutating func bind(documentID: UUID) {
        self.documentID = documentID
        self.sequence = 0
        self.mediaGeneration = 0
        self.consumedEnd = false
    }

    mutating func accept(_ message: PlaybackBridgeMessage) -> Bool {
        guard message.loadID == self.loadID,
              message.identity == self.identity,
              message.documentID == self.documentID,
              message.sequence > self.sequence,
              message.mediaGeneration >= self.mediaGeneration,
              !self.consumedEnd
        else { return false }
        if message.kind != .error, message.videoID != self.identity?.trackID { return false }
        if message.kind == .ended {
            guard message.mediaGeneration > 0, message.mediaReady, !message.isAd else { return false }
            self.consumedEnd = true
        }
        self.sequence = message.sequence
        self.mediaGeneration = message.mediaGeneration
        return true
    }
}

enum PlaybackNavigation {
    static func permits(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "music.youtube.com"
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }

    static func watchURL(trackID: String) -> URL? {
        guard !trackID.isEmpty else { return nil }
        var components = URLComponents(string: "https://music.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: trackID)]
        return components.url
    }
}
