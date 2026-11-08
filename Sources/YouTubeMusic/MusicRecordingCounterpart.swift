// Request and wrapper paths follow ytmusicapi's watch implementation (MIT License).
// See THIRD_PARTY_NOTICES.md and docs/VIDEO_PRESENTATION.md.
import Foundation
import MusicCore

/// A service-supplied pair, without a timeline mapping or entitlement claim.
public struct MusicRecordingCounterpart: Equatable, Sendable {
    public enum Kind: String, Sendable { case song, video }
    public let primaryVideoID: String
    public let primaryKind: Kind
    public let kind: Kind
    public let track: Track
}

public enum MusicRecordingCounterpartResult: Equatable, Sendable {
    case unavailable
    case available(MusicRecordingCounterpart)
}

enum MusicRecordingCounterpartParser {
    static func isVideoID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func parse(_ data: Data, videoID: String) throws -> MusicRecordingCounterpartResult {
        guard isVideoID(videoID), data.count <= 4 * 1_024 * 1_024 else { throw MusicServiceError.invalidResponse }
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
        if hasKey("currentVideoEndpoint", in: root) {
            guard root["currentVideoEndpoint"]["watchEndpoint"]["videoId"].string == videoID else { throw MusicServiceError.unsupportedResponse }
        }
        let watch = root["contents"]["singleColumnMusicWatchNextResultsRenderer"]["tabbedRenderer"]["watchNextTabbedResultsRenderer"]
        guard case let .array(tabs) = watch["tabs"], !tabs.isEmpty, tabs.count <= 8,
              tabs.allSatisfy({ tab in
                  let renderer = tab["tabRenderer"]
                  guard case .object = renderer else { return false }
                  return ["selected", "disabled", "unselectable"].allSatisfy {
                      !hasKey($0, in: renderer) || renderer[$0].bool != nil
                  }
              }),
              tabs.filter({ $0["tabRenderer"]["selected"].bool == true }).count <= 1 else { throw MusicServiceError.unsupportedResponse }
        let queues = tabs.compactMap { tab -> JSONNode? in
            let renderer = tab["tabRenderer"]
            guard renderer["selected"].bool != false, renderer["unselectable"].bool != true,
                  renderer["disabled"].bool != true else { return nil }
            let value = renderer["content"]["musicQueueRenderer"]["content"]["playlistPanelRenderer"]
            return value.exists ? value : nil
        }
        guard queues.count == 1, let panel = queues.first,
              case let .array(rows) = panel["contents"], rows.count <= 200 else { throw MusicServiceError.unsupportedResponse }
        var matches: [JSONNode] = []
        for row in rows {
            let wrapper = row["playlistPanelVideoWrapperRenderer"]
            let primary = wrapper.exists ? wrapper["primaryRenderer"]["playlistPanelVideoRenderer"] : row["playlistPanelVideoRenderer"]
            if primary["videoId"].string == videoID { matches.append(wrapper) }
        }
        guard matches.count <= 1 else { throw MusicServiceError.unsupportedResponse }
        guard let wrapper = matches.first, wrapper.exists else { return .unavailable }
        let primary = wrapper["primaryRenderer"]["playlistPanelVideoRenderer"]
        guard playable(primary), let primaryKind = kind(primary), coherentID(primary, videoID: videoID) else { return .unavailable }
        guard case let .array(counterparts) = wrapper["counterpart"] else { return .unavailable }
        guard counterparts.count <= 1 else { throw MusicServiceError.unsupportedResponse }
        guard let entry = counterparts.first else { return .unavailable }
        let other = entry["counterpartRenderer"]["playlistPanelVideoRenderer"]
        guard playable(other), let otherID = other["videoId"].string, isVideoID(otherID), otherID != videoID,
              coherentID(other, videoID: otherID), let otherKind = kind(other), otherKind != primaryKind,
              let title = try text(other["title"]), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let artist = try artist(other), !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unavailable }
        let duration = try text(other["lengthText"]).flatMap(MusicResponseParser.parseDuration)
        let track = Track(id: otherID, title: title, artist: artist, duration: duration, origin: .catalog, contentKind: .song)
        return .available(.init(primaryVideoID: videoID, primaryKind: primaryKind, kind: otherKind, track: track))
    }

    private static func coherentID(_ renderer: JSONNode, videoID: String) -> Bool {
        let endpoint = renderer["navigationEndpoint"]["watchEndpoint"]
        return !hasKey("videoId", in: endpoint) || endpoint["videoId"].string == videoID
    }
    private static func playable(_ renderer: JSONNode) -> Bool {
        renderer.exists && !hasKey("unplayableText", in: renderer) &&
        (!hasKey("isPlayable", in: renderer) || renderer["isPlayable"].bool == true)
    }
    /// Explicit null is unknown evidence, not an absent optional field.
    private static func hasKey(_ key: String, in node: JSONNode) -> Bool {
        guard case let .object(values) = node else { return false }
        return values[key] != nil
    }
    private static func kind(_ renderer: JSONNode) -> MusicRecordingCounterpart.Kind? {
        switch renderer["navigationEndpoint"]["watchEndpoint"]["watchEndpointMusicSupportedConfigs"]["watchEndpointMusicConfig"]["musicVideoType"].string {
        case "MUSIC_VIDEO_TYPE_ATV": .song
        case "MUSIC_VIDEO_TYPE_OMV": .video
        default: nil
        }
    }
    private static func artist(_ renderer: JSONNode) throws -> String? {
        let byline = renderer["longBylineText"]
        if case let .array(runs) = byline["runs"] {
            guard runs.count <= 32 else { throw MusicServiceError.unsupportedResponse }
            let credits = runs.prefix { !["•", "·"].contains($0["text"].string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") }
            let value = try text(.object(["runs": .array(Array(credits))]))
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return try text(renderer["shortBylineText"])
    }
    private static func text(_ node: JSONNode) throws -> String? {
        guard node.exists else { return nil }
        let value: String
        if let simple = node["simpleText"].string { value = simple }
        else {
            guard case let .array(runs) = node["runs"], runs.count <= 32 else { throw MusicServiceError.unsupportedResponse }
            var joined = ""
            for run in runs {
                guard let text = run["text"].string, text.utf8.count <= 1_024 else { throw MusicServiceError.unsupportedResponse }
                joined += text
                guard joined.utf8.count <= 1_024 else { throw MusicServiceError.unsupportedResponse }
            }
            value = joined
        }
        guard value.utf8.count <= 1_024, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw MusicServiceError.unsupportedResponse
        }
        return value.isEmpty ? nil : value
    }
}
