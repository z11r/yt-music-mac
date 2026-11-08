// Request and dialog paths adapted from ytmusicapi, copyright (c) 2026 sigma67,
// under the MIT License. See THIRD_PARTY_NOTICES.md for the license and source paths.
import Foundation
import MusicCore

/// Service text stays opaque: role titles can be localized or unfamiliar, and
/// attribution is a section in the same ordered response as the other credits.
public struct MusicSongCreditSection: Equatable, Sendable {
    public let title: String
    public let text: String

    public init(title: String, text: String) { self.title = title; self.text = text }
}

public enum MusicSongCredits: Equatable, Sendable {
    case unavailable
    case available([MusicSongCreditSection])
}

public enum MusicSongCreditsError: Error, Equatable, Sendable { case timedOut }

enum MusicSongCreditsParser {
    /// Reads only the exact row's own navigation menu. Headers, siblings,
    /// nested dialogs, labels and video identifiers cannot supply a reference.
    static func reference(in row: JSONNode) -> SongCreditsReference? {
        guard case let .array(items) = row["menu"]["menuRenderer"]["items"], items.count <= 256 else { return nil }
        var references: Set<SongCreditsReference> = []
        for item in items {
            let browse = item["menuNavigationItemRenderer"]["navigationEndpoint"]["browseEndpoint"]
            guard let id = browse["browseId"].string, id.hasPrefix("MPTC") else { continue }
            let pageType = browse["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"]
            guard let reference = SongCreditsReference(browseID: id), !browse["params"].exists,
                  !pageType.exists || pageType.string == "MUSIC_PAGE_TYPE_TRACK_CREDITS" else { return nil }
            references.insert(reference)
        }
        return references.count == 1 ? references.first : nil
    }

    static func parse(_ data: Data) throws -> MusicSongCredits {
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
        guard case let .array(actions) = root["onResponseReceivedActions"], let first = actions.first,
              case let .array(sections) = first["openPopupAction"]["popup"]["dismissableDialogRenderer"]["sections"],
              sections.count <= 64 else { throw MusicServiceError.unsupportedResponse }
        var result: [MusicSongCreditSection] = []
        var characterCount = 0
        for section in sections {
            let content = section["dismissableDialogContentSectionRenderer"]
            let title = try text(content["title"], permitsSimpleText: true)
            let subtitle = try text(content["subtitle"], permitsSimpleText: false)
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MusicServiceError.unsupportedResponse }
            characterCount += title.utf8.count + subtitle.utf8.count
            guard characterCount <= 100_000 else { throw MusicServiceError.unsupportedResponse }
            result.append(MusicSongCreditSection(title: title, text: subtitle))
        }
        return result.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ? .available(result) : .unavailable
    }

    private static func text(_ node: JSONNode, permitsSimpleText: Bool) throws -> String {
        let result: String
        if permitsSimpleText, case let .string(value) = node["simpleText"] { result = value }
        else {
            guard case let .array(runs) = node["runs"], runs.count <= 1_024 else { throw MusicServiceError.unsupportedResponse }
            result = try runs.map { run in
                guard case let .string(text) = run["text"], text.utf8.count <= 16_384 else { throw MusicServiceError.unsupportedResponse }
                return text
            }.joined()
        }
        guard result.utf8.count <= 100_000, !result.contains("\0") else { throw MusicServiceError.unsupportedResponse }
        return result
    }
}
