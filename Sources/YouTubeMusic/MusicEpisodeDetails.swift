// Response paths follow ytmusicapi's podcast implementation (MIT License).
// See THIRD_PARTY_NOTICES.md and docs/EPISODE_DETAILS.md.
import Foundation
import MusicCore

public struct MusicEpisodeDetailsReference: Hashable, Sendable {
    public let identity: EpisodeIdentity
    public let videoID: String
    public init?(identity: EpisodeIdentity, videoID: String) {
        guard EpisodeProgressSnapshot.validEpisode(identity), MusicUploadRoutes.isVideoID(videoID) else { return nil }
        self.identity = identity; self.videoID = videoID
    }
}
public struct MusicEpisodeTimestamp: Equatable, Sendable {
    public let sourceIndex: Int
    public let text: String
    public let seconds: Int
}
/// Ephemeral, read-only service text. No HTML, URLs, chapter titles or playback authority.
public struct MusicEpisodeDetails: Equatable, Sendable {
    public let reference: MusicEpisodeDetailsReference
    public let title: String
    public let show: String?
    public let publishedText: String?
    public let durationText: String?
    public let description: String?
    public let timestamps: [MusicEpisodeTimestamp]
}
public enum MusicEpisodeDetailsResult: Equatable, Sendable {
    case unavailable
    case available(MusicEpisodeDetails)
}

enum MusicEpisodeDetailsParser {
    static func parse(_ data: Data, reference: MusicEpisodeDetailsReference) throws -> MusicEpisodeDetailsResult {
        guard data.count <= 1_048_576 else { throw MusicServiceError.invalidResponse }
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
        let columns = root["contents"]["twoColumnBrowseResultsRenderer"]
        guard case let .array(tabs) = columns["tabs"], !tabs.isEmpty, tabs.count <= 8 else { return .unavailable }
        let selected = tabs.filter { $0["tabRenderer"]["selected"].bool == true }
        let tab: JSONNode
        if selected.count == 1 { tab = selected[0]["tabRenderer"] }
        else if selected.isEmpty, tabs.count == 1, tabs[0]["tabRenderer"]["selected"].bool != false { tab = tabs[0]["tabRenderer"] }
        else { throw MusicServiceError.unsupportedResponse }
        guard case let .array(sections) = tab["content"]["sectionListRenderer"]["contents"], sections.count <= 64,
              let first = sections.first, first["musicResponsiveHeaderRenderer"].exists else { return .unavailable }
        guard sections.filter({ $0["musicResponsiveHeaderRenderer"].exists }).count == 1 else { throw MusicServiceError.unsupportedResponse }
        let header = first["musicResponsiveHeaderRenderer"]
        try validateHeaderIdentity(header, reference: reference)
        guard let title = try text(header["title"], maximum: 2_048), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable
        }
        let show = try text(header["straplineTextOne"], maximum: 2_048)
        let published = try text(header["subtitle"], maximum: 512)
        // This exact second run is the documented service duration label; no localized parsing.
        let durationRuns = header["progress"]["musicPlaybackProgressRenderer"]["durationText"]["runs"].array
        let duration = durationRuns.count > 1 ? try boundedString(durationRuns[1]["text"], maximum: 256) : nil
        let secondary = columns["secondaryContents"]["sectionListRenderer"]["contents"]
        var description: String?, timestamps: [MusicEpisodeTimestamp] = []
        if case let .array(items) = secondary {
            guard items.count <= 64, items.filter({ $0["musicDescriptionShelfRenderer"].exists }).count <= 1 else {
                throw MusicServiceError.unsupportedResponse
            }
            if let first = items.first, first["musicDescriptionShelfRenderer"].exists {
                let parsed = try descriptionRuns(first["musicDescriptionShelfRenderer"]["description"], reference: reference)
                description = parsed.0; timestamps = parsed.1
            }
        } else if secondary.exists { throw MusicServiceError.unsupportedResponse }
        return .available(.init(reference: reference, title: title, show: show, publishedText: published,
            durationText: duration, description: description, timestamps: timestamps))
    }
    private static func descriptionRuns(_ node: JSONNode, reference: MusicEpisodeDetailsReference) throws -> (String?, [MusicEpisodeTimestamp]) {
        guard node.exists else { return (nil, []) }
        guard case let .array(runs) = node["runs"], runs.count <= 1_024 else { throw MusicServiceError.unsupportedResponse }
        var result = "", timestamps: [MusicEpisodeTimestamp] = [], bytes = 0
        for (index, run) in runs.enumerated() {
            guard let value = try boundedString(run["text"], maximum: 16_384, permitsEmpty: true) else { throw MusicServiceError.unsupportedResponse }
            bytes += value.utf8.count
            guard bytes <= 65_536 else { throw MusicServiceError.unsupportedResponse }
            result += value
            let endpoint = run["navigationEndpoint"]["watchEndpoint"]
            guard endpoint["videoId"].string == reference.videoID,
                  case let .number(seconds) = endpoint["startTimeSeconds"], seconds.isFinite,
                  seconds.rounded(.towardZero) == seconds, (0...604_800).contains(seconds), value.utf8.count <= 256 else { continue }
            guard timestamps.count < 128 else { throw MusicServiceError.unsupportedResponse }
            timestamps.append(.init(sourceIndex: index, text: value, seconds: Int(seconds)))
        }
        return (result.isEmpty ? nil : result, timestamps)
    }
    private static func text(_ node: JSONNode, maximum: Int) throws -> String? {
        guard node.exists else { return nil }
        if node["simpleText"].exists { return try boundedString(node["simpleText"], maximum: maximum, permitsEmpty: true) }
        guard case let .array(runs) = node["runs"], runs.count <= 64 else { throw MusicServiceError.unsupportedResponse }
        var result = "", bytes = 0
        for run in runs {
            guard let value = try boundedString(run["text"], maximum: maximum, permitsEmpty: true) else { throw MusicServiceError.unsupportedResponse }
            bytes += value.utf8.count
            guard bytes <= maximum else { throw MusicServiceError.unsupportedResponse }
            result += value
        }
        return result.isEmpty ? nil : result
    }
    private static func boundedString(_ node: JSONNode, maximum: Int, permitsEmpty: Bool = false) throws -> String? {
        guard node.exists else { return nil }
        guard case let .string(value) = node, value.utf8.count <= maximum, !value.contains("\0"), permitsEmpty || !value.isEmpty else {
            throw MusicServiceError.unsupportedResponse
        }
        return value
    }
    private static func validateHeaderIdentity(_ header: JSONNode, reference: MusicEpisodeDetailsReference) throws {
        var remaining = 2_048
        func visit(_ node: JSONNode, depth: Int) throws {
            remaining -= 1
            guard remaining >= 0, depth <= 16 else { throw MusicServiceError.unsupportedResponse }
            if let id = node["browseEndpoint"]["browseId"].string, id.hasPrefix("MPED"), id != reference.identity.browseID {
                throw MusicServiceError.unsupportedResponse
            }
            if node["watchEndpoint"]["videoId"].exists, node["watchEndpoint"]["videoId"].string != reference.videoID {
                throw MusicServiceError.unsupportedResponse
            }
            switch node {
            case let .object(values): for child in values.values { try visit(child, depth: depth + 1) }
            case let .array(values): for child in values { try visit(child, depth: depth + 1) }
            default: break
            }
        }
        try visit(header, depth: 0)
    }
}
