// Portions adapted from Kaset, copyright (c) 2025 sozercan, under the MIT License.
// See THIRD_PARTY_NOTICES.md for the license and upstream source paths.
import Foundation

public struct MusicLyricLine: Equatable, Sendable {
    public let startTime: TimeInterval
    public let duration: TimeInterval?
    public let text: String

    public init(startTime: TimeInterval, duration: TimeInterval? = nil, text: String) {
        self.startTime = startTime
        self.duration = duration
        self.text = text
    }
}

/// Lyrics supplied by YouTube Music for an exact video request. Plain text does
/// not imply synchronization; only validated service timestamps enable timing.
public enum MusicLyrics: Equatable, Sendable {
    case plain(text: String, source: String?)
    case timed(lines: [MusicLyricLine], source: String?)
    case unavailable

    public var source: String? {
        switch self {
        case let .plain(_, source), let .timed(_, source): source
        case .unavailable: nil
        }
    }

    public var text: String {
        switch self {
        case let .plain(text, _): text
        case let .timed(lines, _): lines.map(\.text).joined(separator: "\n")
        case .unavailable: ""
        }
    }

    public func activeLineIndex(at position: TimeInterval) -> Int? {
        guard case let .timed(lines, _) = self, position.isFinite, position >= 0,
              let index = lines.lastIndex(where: { $0.startTime <= position }) else { return nil }
        let line = lines[index]
        if let duration = line.duration, duration > 0, position >= line.startTime + duration { return nil }
        return index
    }
}

public enum MusicLyricsError: Error, Equatable, Sendable, LocalizedError {
    case timedOut

    public var errorDescription: String? { "Loading lyrics timed out. Try again." }
}

struct MusicLyricsReference {
    var lyrics: MusicLyrics?
    var browseID: String?
}

enum MusicLyricsParser {
    static let maximumTextCount = 100_000
    static let maximumLineCount = 2_000

    static func nextReference(_ data: Data) throws -> MusicLyricsReference {
        let root = try decode(data)
        let inline = try timedLyrics(in: root)
        let watch = root["contents"]["singleColumnMusicWatchNextResultsRenderer"]["tabbedRenderer"]["watchNextTabbedResultsRenderer"]
        guard case let .array(tabs) = watch["tabs"] else {
            if let inline { return MusicLyricsReference(lyrics: inline) }
            throw MusicServiceError.unsupportedResponse
        }
        var identifiers: [String] = []
        for tab in tabs {
            let renderer = tab["tabRenderer"]
            guard renderer["disabled"].bool != true,
                  let id = renderer["endpoint"]["browseEndpoint"]["browseId"].string,
                  id.hasPrefix("MPLYt") else { continue }
            guard id.count <= 2_048, !id.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
            }) else { throw MusicServiceError.unsupportedResponse }
            if !identifiers.contains(id) { identifiers.append(id) }
        }
        guard identifiers.count <= 1 else { throw MusicServiceError.unsupportedResponse }
        return MusicLyricsReference(lyrics: inline, browseID: identifiers.first)
    }

    static func browseLyrics(_ data: Data) throws -> MusicLyrics {
        let root = try decode(data)
        if let timed = try timedLyrics(in: root) { return timed }
        let container = root["contents"]["sectionListRenderer"]
        guard case let .array(sections) = container["contents"] else { throw MusicServiceError.unsupportedResponse }
        for section in sections {
            let shelf = section["musicDescriptionShelfRenderer"]
            guard shelf.exists else { continue }
            guard let text = shelf["description"].text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unavailable }
            try validateText(text)
            let source = shelf["footer"].text?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (source?.count ?? 0) <= 4_096 else { throw MusicServiceError.unsupportedResponse }
            return .plain(text: text, source: source?.isEmpty == false ? source : nil)
        }
        if sections.isEmpty || sections.contains(where: { $0["messageRenderer"].exists }) { return .unavailable }
        throw MusicServiceError.unsupportedResponse
    }

    private static func decode(_ data: Data) throws -> JSONNode {
        guard data.count <= 12 * 1_024 * 1_024 else { throw MusicServiceError.invalidResponse }
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
        return root
    }

    /// Traversal is limited to lyrics/content containers, not menus, related
    /// track renderers, or arbitrary navigation payloads.
    private static func timedLyrics(in root: JSONNode) throws -> MusicLyrics? {
        let keys: Set<String> = ["contents", "content", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer",
                                 "watchNextTabbedResultsRenderer", "tabs", "tabRenderer", "musicQueueRenderer",
                                 "sectionListRenderer", "timedLyricsRenderer"]
        var models: [JSONNode] = []
        var budget = 2_048
        func visit(_ node: JSONNode, depth: Int = 0) throws {
            guard budget > 0, depth <= 16 else { throw MusicServiceError.unsupportedResponse }
            budget -= 1
            if node["disabled"].bool == true { return }
            if node["timedLyricsModel"].exists {
                models.append(node["timedLyricsModel"])
                guard models.count <= 1 else { throw MusicServiceError.unsupportedResponse }
            }
            switch node {
            case let .object(values):
                for key in values.keys.sorted() where keys.contains(key) {
                    if let child = values[key] { try visit(child, depth: depth + 1) }
                }
            case let .array(values):
                for child in values { try visit(child, depth: depth + 1) }
            default: break
            }
        }
        try visit(root)
        guard let model = models.first else { return nil }
        guard case let .array(entries) = model["lyricsData"], entries.count <= maximumLineCount else {
            throw MusicServiceError.unsupportedResponse
        }
        guard !entries.isEmpty else { return nil }
        var lines: [MusicLyricLine] = []
        var texts: [String] = []
        var timingIsValid = true
        var previousStart: Int?
        for entry in entries {
            guard case let .string(text) = entry["lyricLine"] else { timingIsValid = false; continue }
            texts.append(text)
            guard let rawStart = entry["startTimeMs"].string, let start = Int(rawStart),
                  (0...604_800_000).contains(start), previousStart.map({ start > $0 }) ?? true else {
                timingIsValid = false
                continue
            }
            var duration: Int?
            if entry["durationMs"].exists {
                guard let raw = entry["durationMs"].string, let value = Int(raw), (0...604_800_000).contains(value) else {
                    timingIsValid = false
                    continue
                }
                duration = value
            }
            previousStart = start
            lines.append(MusicLyricLine(startTime: Double(start) / 1_000,
                duration: duration.map { Double($0) / 1_000 }, text: text))
        }
        let text = texts.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        try validateText(text)
        if timingIsValid, lines.count == entries.count { return .timed(lines: lines, source: nil) }
        return .plain(text: text, source: nil)
    }

    private static func validateText(_ text: String) throws {
        guard text.count <= maximumTextCount, !text.contains("\0") else { throw MusicServiceError.unsupportedResponse }
    }
}
