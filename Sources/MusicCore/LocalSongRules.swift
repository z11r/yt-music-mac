import Foundation

public enum LocalSongRuleField: String, Codable, CaseIterable, Hashable, Sendable { case title, artist, album, duration, explicit }
public enum LocalSongRuleOperator: String, Codable, CaseIterable, Hashable, Sendable {
    case contains, doesNotContain, equals, doesNotEqual, lessThan, atMost, greaterThan, atLeast, isTrue, isFalse, isUnknown, isKnown
}
public enum LocalSongRuleMatch: String, Codable, CaseIterable, Hashable, Sendable { case all, any }
public enum LocalSongRuleTruth: Equatable, Sendable { case matches, doesNotMatch, unknown }

public struct LocalSongRuleClause: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var field: LocalSongRuleField
    public var operation: LocalSongRuleOperator
    public var text: String?
    public var number: TimeInterval?
    public init(id: UUID = UUID(), field: LocalSongRuleField = .title, operation: LocalSongRuleOperator = .contains,
                text: String? = nil, number: TimeInterval? = nil) {
        self.id = id; self.field = field; self.operation = operation; self.text = text; self.number = number
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case id, field, operation, text, number }
    public init(from decoder: any Decoder) throws {
        try SongRuleSchema.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        field = try values.decode(LocalSongRuleField.self, forKey: .field)
        operation = try values.decode(LocalSongRuleOperator.self, forKey: .operation)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        number = try values.decodeIfPresent(TimeInterval.self, forKey: .number)
    }
    public var allowedOperators: [LocalSongRuleOperator] {
        switch field {
        case .title, .artist, .album: [.contains, .doesNotContain, .equals, .doesNotEqual, .isUnknown, .isKnown]
        case .duration: [.lessThan, .atMost, .greaterThan, .atLeast, .isUnknown, .isKnown]
        case .explicit: [.isTrue, .isFalse, .isUnknown, .isKnown]
        }
    }
    public var usesText: Bool { [.contains, .doesNotContain, .equals, .doesNotEqual].contains(operation) }
    public var usesNumber: Bool { [.lessThan, .atMost, .greaterThan, .atLeast].contains(operation) }

    public func evaluate(_ song: LocalSongRuleSong) -> LocalSongRuleTruth {
        guard allowedOperators.contains(operation) else { return .unknown }
        let known: Bool
        let value: String?
        switch field {
        case .title: value = song.title; known = value != nil
        case .artist: value = song.artist; known = value != nil
        case .album: value = song.album; known = value != nil
        case .duration: value = nil; known = song.duration != nil
        case .explicit: value = nil; known = song.isExplicit != nil
        }
        if operation == .isUnknown { return known ? .doesNotMatch : .matches }
        if operation == .isKnown { return known ? .matches : .doesNotMatch }
        guard known else { return .unknown }
        let matches: Bool
        if let value, let text {
            let locale = Locale(identifier: "en_US_POSIX")
            let lhs = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            let rhs = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            switch operation {
            case .contains: matches = lhs.contains(rhs)
            case .doesNotContain: matches = !lhs.contains(rhs)
            case .equals: matches = lhs == rhs
            case .doesNotEqual: matches = lhs != rhs
            default: return .unknown
            }
        } else if field == .duration, let duration = song.duration, let number, number.isFinite {
            switch operation {
            case .lessThan: matches = duration < number
            case .atMost: matches = duration <= number
            case .greaterThan: matches = duration > number
            case .atLeast: matches = duration >= number
            default: return .unknown
            }
        } else if field == .explicit, let explicit = song.isExplicit {
            matches = operation == .isTrue ? explicit : !explicit
        } else { return .unknown }
        return matches ? .matches : .doesNotMatch
    }
}

public struct LocalSongRule: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var match: LocalSongRuleMatch
    public var clauses: [LocalSongRuleClause]
    public init(id: UUID = UUID(), name: String, match: LocalSongRuleMatch = .all, clauses: [LocalSongRuleClause]) {
        self.id = id; self.name = name; self.match = match; self.clauses = clauses
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case id, name, match, clauses }
    public init(from decoder: any Decoder) throws {
        try SongRuleSchema.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        match = try values.decode(LocalSongRuleMatch.self, forKey: .match)
        clauses = try SongRuleSchema.array(LocalSongRuleClause.self, values: values, key: .clauses, limit: 12)
    }
    public func evaluate(_ song: LocalSongRuleSong) -> LocalSongRuleTruth {
        guard !clauses.isEmpty else { return .unknown }
        var unknown = false
        for clause in clauses {
            let result = clause.evaluate(song)
            if match == .all && result == .doesNotMatch { return .doesNotMatch }
            if match == .any && result == .matches { return .matches }
            unknown = unknown || result == .unknown
        }
        return unknown ? .unknown : match == .all ? .matches : .doesNotMatch
    }
}

/// One captured occurrence. Its UUID is independent of the playable video ID.
public struct LocalSongRuleSong: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let videoID: String
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: TimeInterval?
    public let isExplicit: Bool?
    public let origin: MusicContentOrigin?
    public let contentKind: MusicContentKind?
    public init(id: UUID = UUID(), videoID: String, title: String? = nil, artist: String? = nil, album: String? = nil,
                duration: TimeInterval? = nil, isExplicit: Bool? = nil, origin: MusicContentOrigin? = nil, contentKind: MusicContentKind? = nil) {
        self.id = id; self.videoID = videoID; self.title = title; self.artist = artist; self.album = album
        self.duration = duration; self.isExplicit = isExplicit; self.origin = origin; self.contentKind = contentKind
    }
    public init(track: Track) {
        id = UUID(); videoID = track.id
        title = Self.knownText(track.title)
        let artistIsPlaceholder = track.artistReferences?.isEmpty != false && track.artist.lowercased() == "unknown artist"
        artist = artistIsPlaceholder ? nil : Self.knownText(track.artist)
        album = Self.knownText(track.album)
        duration = track.duration.flatMap { $0.isFinite && (0...604_800).contains($0) ? $0 : nil }
        isExplicit = track.isExplicit
        origin = track.hasLocalAudioSource ? .localFile : track.origin
        contentKind = track.contentKind
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case id, videoID, title, artist, album, duration, isExplicit, origin, contentKind }
    public init(from decoder: any Decoder) throws {
        try SongRuleSchema.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        videoID = try values.decode(String.self, forKey: .videoID)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        artist = try values.decodeIfPresent(String.self, forKey: .artist)
        album = try values.decodeIfPresent(String.self, forKey: .album)
        duration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration)
        isExplicit = try values.decodeIfPresent(Bool.self, forKey: .isExplicit)
        origin = try values.decodeIfPresent(MusicContentOrigin.self, forKey: .origin)
        contentKind = try values.decodeIfPresent(MusicContentKind.self, forKey: .contentKind)
    }
    public var track: Track {
        Track(id: videoID, title: title ?? "Untitled song", artist: artist ?? "Unknown artist", album: album,
              duration: duration, isExplicit: isExplicit, origin: origin, contentKind: contentKind)
    }
    private static func knownText(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 4_096, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }
}

public struct LocalSongRuleSnapshot: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable { case capturedLoadedSongs }
    public let scope: Scope
    public let capturedAt: Date
    public let sourceName: String
    public let songs: [LocalSongRuleSong]
    public let hasMorePages: Bool
    public let wasLoading: Bool
    public let unavailableCount: Int
    public let hasUnsupportedContent: Bool
    public let isTruncated: Bool
    public let skippedCount: Int
    public init(capturedAt: Date, sourceName: String, songs: [LocalSongRuleSong], hasMorePages: Bool = false,
                wasLoading: Bool = false, unavailableCount: Int = 0, hasUnsupportedContent: Bool = false,
                isTruncated: Bool = false, skippedCount: Int = 0) {
        scope = .capturedLoadedSongs; self.capturedAt = capturedAt; self.sourceName = sourceName; self.songs = songs
        self.hasMorePages = hasMorePages; self.wasLoading = wasLoading; self.unavailableCount = unavailableCount
        self.hasUnsupportedContent = hasUnsupportedContent; self.isTruncated = isTruncated; self.skippedCount = skippedCount
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case scope, capturedAt, sourceName, songs, hasMorePages, wasLoading, unavailableCount, hasUnsupportedContent, isTruncated, skippedCount
    }
    public init(from decoder: any Decoder) throws {
        try SongRuleSchema.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scope = try values.decode(Scope.self, forKey: .scope)
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        sourceName = try values.decode(String.self, forKey: .sourceName)
        songs = try SongRuleSchema.array(LocalSongRuleSong.self, values: values, key: .songs, limit: 5_000)
        hasMorePages = try values.decode(Bool.self, forKey: .hasMorePages)
        wasLoading = try values.decode(Bool.self, forKey: .wasLoading)
        unavailableCount = try values.decode(Int.self, forKey: .unavailableCount)
        hasUnsupportedContent = try values.decode(Bool.self, forKey: .hasUnsupportedContent)
        isTruncated = try values.decode(Bool.self, forKey: .isTruncated)
        skippedCount = try values.decode(Int.self, forKey: .skippedCount)
    }
}

public struct LocalSongRuleEvaluation: Equatable, Sendable {
    public let matches: [LocalSongRuleSong]
    public let unknownCount: Int
    public init(rule: LocalSongRule?, snapshot: LocalSongRuleSnapshot?) {
        var matched: [LocalSongRuleSong] = []
        var unknown = 0
        if let rule, let snapshot {
            for song in snapshot.songs {
                switch rule.evaluate(song) {
                case .matches: matched.append(song)
                case .unknown: unknown += 1
                case .doesNotMatch: break
                }
            }
        }
        matches = matched; unknownCount = unknown
    }
}

enum SongRuleSchema {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func keys(_ decoder: any Decoder, allowed: [String]) throws {
        let raw = try decoder.container(keyedBy: Key.self)
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: Set(allowed)) else { throw LocalSongRuleError.invalidArchive }
    }
    static func array<Value: Decodable, Key: CodingKey>(_ type: Value.Type, values: KeyedDecodingContainer<Key>,
                                                       key: Key, limit: Int) throws -> [Value] {
        var array = try values.nestedUnkeyedContainer(forKey: key)
        guard array.count.map({ $0 <= limit }) ?? true else { throw LocalSongRuleError.capacityReached }
        var result: [Value] = []
        while !array.isAtEnd {
            guard result.count < limit else { throw LocalSongRuleError.capacityReached }
            result.append(try array.decode(Value.self))
        }
        return result
    }
}
