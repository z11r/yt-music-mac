import Foundation

public enum MusicContentKind: String, Codable, Hashable, Sendable { case song, podcastEpisode }

/// Canonical service episode identity, distinct from its current playback video
/// and from each local queue occurrence. Show metadata does not change its key.
public struct EpisodeIdentity: Codable, Hashable, Sendable {
    public enum Provider: String, Codable, Sendable { case youtubeMusic }
    public let provider: Provider
    public let browseID: String
    public let showBrowseID: String?
    public var key: String { provider.rawValue + ":" + browseID }

    public init(provider: Provider = .youtubeMusic, browseID: String, showBrowseID: String? = nil) {
        self.provider = provider; self.browseID = browseID; self.showBrowseID = showBrowseID
    }
}

public struct EpisodeMetadata: Codable, Hashable, Sendable {
    public let identity: EpisodeIdentity
    public let description: String?
    public let publishedText: String?
    public let durationText: String?
    /// Service metadata only; never converted to a fabricated local resume time.
    public let serviceProgressFraction: Double?
    public init(identity: EpisodeIdentity, description: String? = nil, publishedText: String? = nil,
                durationText: String? = nil, serviceProgressFraction: Double? = nil) {
        self.identity = identity; self.description = description; self.publishedText = publishedText; self.durationText = durationText
        self.serviceProgressFraction = serviceProgressFraction.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
    }
}
