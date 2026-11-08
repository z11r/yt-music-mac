// Request and response paths follow Kaset and ytmusicapi. See THIRD_PARTY_NOTICES.md.
import Foundation
import MusicCore

extension YouTubeMusicClient {
    public func podcasts() async throws -> MusicPage {
        try await firstPage(endpoint: .browse, body: ["browseId": "FEmusic_podcasts"], title: ServiceLocalization.text("Podcasts"),
                            requiresAuthentication: false, preservesOccurrences: false)
    }

    public func podcast(id: String) async throws -> MusicPage {
        try validateIdentifier(id)
        let id = id.hasPrefix("PL") ? "MPSP" + id : id
        guard id.hasPrefix("MPSP"), id.count > 4 else { throw MusicServiceError.invalidInput }
        return try await firstPage(endpoint: .browse, body: ["browseId": id], title: ServiceLocalization.text("Podcast"),
                                   requiresAuthentication: false, preservesOccurrences: true)
    }

    public func libraryPodcasts() async throws -> MusicPage {
        try await firstPage(endpoint: .browse, body: ["browseId": "FEmusic_library_non_music_audio_list"], title: ServiceLocalization.text("Your Podcasts"),
                            requiresAuthentication: true, preservesOccurrences: false)
    }

    public func savedEpisodes() async throws -> MusicPage {
        try await firstPage(endpoint: .browse, body: ["browseId": "VLSE"], title: ServiceLocalization.text("Saved Episodes"),
                            requiresAuthentication: true, preservesOccurrences: true)
    }
}

enum MusicPodcastParser {
    static func metadata(_ node: JSONNode, videoID: String, endpoints: [JSONNode]) -> EpisodeMetadata? {
        let browseIDs = endpoints.compactMap { $0["browseEndpoint"]["browseId"].string }
        let explicitEpisode = endpoints.contains {
            $0["watchEndpoint"]["watchEndpointMusicSupportedConfigs"]["watchEndpointMusicConfig"]["musicVideoType"].string == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"
        }
        guard let browseID = browseIDs.first(where: { $0.hasPrefix("MPED") && $0.count > 4 }) ??
                (explicitEpisode ? "MPED" + videoID : nil), MusicUploadRoutes.isVideoID(videoID) else { return nil }
        let references = node["secondTitle"]["runs"].array + node["subtitle"]["runs"].array +
            node["flexColumns"].array.flatMap { $0["musicResponsiveListItemFlexColumnRenderer"]["text"]["runs"].array }
        let showID = references.compactMap { $0["navigationEndpoint"]["browseEndpoint"]["browseId"].string }
            .first { $0.hasPrefix("MPSP") && $0.count > 4 }
        let progress = node["playbackProgress"]["musicPlaybackProgressRenderer"]
        let percentage = progress["playbackProgressPercentage"].double ?? node["playbackProgress"]["playbackProgressPercentage"].double
        let duration = node["durationText"].text ?? progress["durationText"].text
        let subtitleIsShow = node["subtitle"]["runs"].array.contains {
            $0["navigationEndpoint"]["browseEndpoint"]["browseId"].string?.hasPrefix("MPSP") == true
        }
        return EpisodeMetadata(identity: .init(browseID: browseID, showBrowseID: showID), description: node["description"].text,
                               publishedText: node["publishedTimeText"].text ?? (subtitleIsShow ? nil : node["subtitle"].text),
                               durationText: duration, serviceProgressFraction: percentage.map { $0 / 100 })
    }

    static func showTitle(_ node: JSONNode) -> String? {
        if let title = node["secondTitle"].text { return title }
        let runs = node["subtitle"]["runs"].array + node["flexColumns"].array.flatMap { $0["musicResponsiveListItemFlexColumnRenderer"]["text"]["runs"].array }
        return runs.first { $0["navigationEndpoint"]["browseEndpoint"]["browseId"].string?.hasPrefix("MPSP") == true }?["text"].string
    }
}
