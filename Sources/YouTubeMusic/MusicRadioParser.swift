// Portions adapted from Kaset, copyright (c) 2025 sozercan, under the MIT License.
// See THIRD_PARTY_NOTICES.md for the license and upstream source paths.
import Foundation
import MusicCore

struct ParsedRadioPage {
    var title: String?
    var playlistID: String?
    var tracks: [Track] = []
    var selectedTrackID: String?
    var token: String?
}

/// Reads the queue panel of a `next` (watch playlist) response.
///
/// The first page holds the panel under the watch-next tabs; later pages arrive as
/// `continuationContents.playlistPanelContinuation`. A queue without a panel means
/// the service offered no songs for the request.
enum MusicRadioParser {
    static func parse(_ data: Data) throws -> ParsedRadioPage {
        let root: JSONNode
        do { root = try JSONDecoder().decode(JSONNode.self, from: data) }
        catch { throw MusicServiceError.invalidResponse }
        if root["error"].exists {
            switch root["error"]["status"].string {
            case "UNAUTHENTICATED": throw MusicServiceError.authenticationRejected
            case "PERMISSION_DENIED": throw MusicServiceError.accessDenied
            default: throw MusicServiceError.invalidResponse
            }
        }
        var result = ParsedRadioPage()
        let panel: JSONNode
        let continuation = root["continuationContents"]["playlistPanelContinuation"]
        if continuation.exists {
            panel = continuation
        } else {
            let watchNext = root["contents"]["singleColumnMusicWatchNextResultsRenderer"]["tabbedRenderer"]
            let queues = watchNext["watchNextTabbedResultsRenderer"]["tabs"].array.map { $0["tabRenderer"]["content"]["musicQueueRenderer"] }
            guard let queue = queues.first(where: { $0.exists }) else { throw MusicServiceError.unsupportedResponse }
            result.title = queue["header"]["musicQueueHeaderRenderer"]["subtitle"].text
            panel = queue["content"]["playlistPanelRenderer"]
        }
        result.playlistID = panel["playlistId"].string
        var seen = Set<String>()
        for item in panel["contents"].array {
            let renderer = item["playlistPanelVideoRenderer"].exists
                ? item["playlistPanelVideoRenderer"]
                : item["playlistPanelVideoWrapperRenderer"]["primaryRenderer"]["playlistPanelVideoRenderer"]
            guard let track = track(renderer) else { continue }
            if renderer["selected"].bool == true, result.selectedTrackID == nil { result.selectedTrackID = track.id }
            guard seen.insert(track.id).inserted else { continue }
            result.tracks.append(track)
        }
        for value in panel["continuations"].array {
            if let token = value["nextRadioContinuationData"]["continuation"].string
                ?? value["nextContinuationData"]["continuation"].string {
                result.token = token
                break
            }
        }
        return result
    }

    /// The item's own "Start mix" or "Start radio" command, identified by its menu icon.
    static func offeredRadioPlaylistID(_ menu: JSONNode) -> String? {
        for entry in menu["menuRenderer"]["items"].array {
            let item = entry["menuNavigationItemRenderer"]
            guard item["icon"]["iconType"].string == "MIX" else { continue }
            let endpoint = item["navigationEndpoint"]
            if let id = endpoint["watchPlaylistEndpoint"]["playlistId"].string ?? endpoint["watchEndpoint"]["playlistId"].string {
                return id
            }
        }
        return nil
    }

    private static func track(_ renderer: JSONNode) -> Track? {
        guard renderer.exists, !renderer["unplayableText"].exists,
              let id = renderer["videoId"].string ?? renderer["navigationEndpoint"]["watchEndpoint"]["videoId"].string,
              isVideoID(id), let title = renderer["title"].text else { return nil }
        let runs = renderer["longBylineText"]["runs"].array
        // The byline reads "Artist • Album • Year" for songs and "Artist • views • likes" for videos.
        let credits = runs.prefix { !isSeparator($0["text"].string) }
        let artistText = credits.compactMap { $0["text"].string }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artistText.isEmpty ? (renderer["shortBylineText"].text ?? ServiceLocalization.text("Unknown artist")) : artistText
        let album = runs.first { MusicResponseParser.collectionKind($0["navigationEndpoint"]["browseEndpoint"]) == .album }?["text"].string
        let duration = renderer["lengthText"].text.flatMap(MusicResponseParser.parseDuration)
        let endpoint = renderer["navigationEndpoint"]
        let episode = MusicPodcastParser.metadata(renderer, videoID: id, endpoints: [endpoint])
        let type = endpoint["watchEndpoint"]["watchEndpointMusicSupportedConfigs"]["watchEndpointMusicConfig"]["musicVideoType"].string
        let song = type.map { ["MUSIC_VIDEO_TYPE_ATV", "MUSIC_VIDEO_TYPE_OMV"].contains($0) } ?? false
        return Track(id: id, title: title, artist: artist, album: album,
                     artworkURL: MusicResponseParser.thumbnail(renderer), duration: duration,
                     contentKind: episode != nil ? .podcastEpisode : song ? .song : nil, episode: episode)
    }

    private static func isSeparator(_ text: String?) -> Bool {
        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "•" || trimmed == "·"
    }

    private static func isVideoID(_ id: String) -> Bool {
        id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
