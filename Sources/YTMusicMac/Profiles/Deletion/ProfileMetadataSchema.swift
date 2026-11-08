import Foundation
import MusicCore

/// Fixed relative metadata names only. No component is a display name or file location.
enum ProfileMetadataFormat: String, Codable, Sendable {
    case queue, namedQueues, organization, cache, rules, episodes, listenBrainz, lastFM, pendingPlaylist, localAudio, storeLock
    static func identify(_ path: String) -> Self? {
        let p = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if p == ["queue.json"] { return .queue }
        if p == ["LocalAudio", "library.json"] { return .localAudio }
        if p == ["LocalAudio", "library.json.lock"] { return .storeLock }
        if p.count == 2, p[1].hasSuffix(".json"), EpisodeProgressAccountKey.accepts(String(p[1].dropLast(5))) {
            return ["episode-progress": .episodes, "listenbrainz": .listenBrainz, "lastfm": .lastFM][p[0]]
        }
        guard p.count == 3, EpisodeProgressAccountKey.accepts(p[1]) else { return nil }
        switch (p[0], p[2]) {
        case ("SavedQueues", "queues.json"): return .namedQueues
        case ("LocalCollections", "organization.json"): return .organization
        case ("MetadataCache", "library.json"): return .cache
        case ("LocalSongRules", "song-rules.json"): return .rules
        case ("PendingQueuePlaylists", "pending.json"): return .pendingPlaylist
        case ("PendingQueuePlaylists", "operation.lock"): return .storeLock
        default: return nil
        }
    }
    var byteLimit: Int {
        switch self {
        case .queue: 4 << 20
        case .namedQueues, .rules: 8 << 20
        case .organization, .episodes: 1 << 20
        case .cache: 2 << 20
        case .listenBrainz, .lastFM: 524_288
        case .pendingPlaylist: 32 << 20
        case .localAudio: 16 << 20
        case .storeLock: 0
        }
    }
}
struct ProfileMetadataSchemaProof: Codable, Equatable, Sendable {
    let version: Int
    let revision: UUID?
}
enum ProfileMetadataSchema {
    static func validate(_ data: Data, path: String, profileID: UUID) throws -> ProfileMetadataSchemaProof {
        guard let format = ProfileMetadataFormat.identify(path), data.count <= format.byteLimit else { throw ProfileCleanupProblem.savedData }
        if format == .storeLock {
            guard data.isEmpty else { throw ProfileCleanupProblem.savedData }
            return .init(version: 0, revision: nil)
        }
        try ProfileMetadataJSON.check(data)
        let source = try JSONSerialization.jsonObject(with: data)
        guard let object = source as? [String: Any], let version = object["version"] as? Int else { throw ProfileCleanupProblem.savedData }
        let account = path.split(separator: "/").dropFirst().first.map(String.init)?.replacingOccurrences(of: ".json", with: "")
        var revision: UUID?
        let canonical: Data
        switch format {
        case .queue:
            guard version == QueueSnapshot.currentVersion else { throw ProfileCleanupProblem.savedData }
            let value = try JSONDecoder().decode(QueueSnapshot.self, from: data); try value.validate()
            guard value.entries.count <= 10_000 else { throw ProfileCleanupProblem.savedData }
            canonical = try JSONEncoder().encode(value)
        case .namedQueues: canonical = try NamedQueueStore.validatedCleanupMetadata(data)
        case .organization:
            guard version == LocalCollectionOrganization.currentVersion else { throw ProfileCleanupProblem.savedData }
            canonical = try LocalCollectionStore.validatedCleanupMetadata(data)
        case .cache: canonical = try LibraryMetadataCache.validatedCleanupMetadata(data)
        case .rules: canonical = try LocalSongRuleStore.validatedCleanupMetadata(data)
        case .episodes:
            let value = try JSONDecoder().decode(EpisodeProgressSnapshot.self, from: data); try value.validate()
            guard value.accountHash == account else { throw ProfileCleanupProblem.savedData }
            canonical = try JSONEncoder().encode(value)
        case .listenBrainz:
            let value = try JSONDecoder().decode(ListenBrainzDocument.self, from: data); try value.validate()
            guard value.profile == account else { throw ProfileCleanupProblem.savedData }
            canonical = try JSONEncoder().encode(value)
        case .lastFM:
            let value = try JSONDecoder().decode(LastFMDocument.self, from: data); try value.validate()
            guard value.profile == account else { throw ProfileCleanupProblem.savedData }
            canonical = try JSONEncoder().encode(value)
        case .pendingPlaylist:
            let value = try JSONDecoder().decode(QueuePlaylistPending.self, from: data); try value.validate()
            // Retain evidence of an admitted external write, including known targets.
            guard value.phase == .prepared || value.phase == .completed else { throw ProfileCleanupProblem.savedData }
            revision = value.revision; canonical = try JSONEncoder().encode(value)
        case .localAudio:
            let value = try JSONDecoder().decode(LocalAudioLibraryDocument.self, from: data); try value.validate()
            guard value.profileID == profileID else { throw ProfileCleanupProblem.savedData }
            revision = value.revision; canonical = try JSONEncoder().encode(value)
        case .storeLock: throw ProfileCleanupProblem.savedData
        }
        // Decoding alone silently ignores future nested fields. Require every
        // input key to survive the supported model's encoder, without rewriting.
        guard keysRecognized(source, by: try JSONSerialization.jsonObject(with: canonical)) else { throw ProfileCleanupProblem.savedData }
        return .init(version: version, revision: revision)
    }
    private static func keysRecognized(_ input: Any, by encoded: Any) -> Bool {
        if let input = input as? [String: Any], let encoded = encoded as? [String: Any] {
            return input.allSatisfy { key, value in encoded[key].map { keysRecognized(value, by: $0) } == true }
        }
        if let input = input as? [Any], let encoded = encoded as? [Any] {
            return input.count == encoded.count && zip(input, encoded).allSatisfy { keysRecognized($0, by: $1) }
        }
        return !(input is [String: Any]) && !(input is [Any])
    }
}

/// Reject duplicate keys (including escaped equivalents) and excessive depth
/// before Foundation decoding can discard unknown input. Syntax is decoded next.
struct ProfileMetadataJSON {
    let bytes: [UInt8]
    var offset = 0, nodes = 0
    static func check(_ data: Data) throws {
        var parser = Self(bytes: Array(data)); try parser.value(depth: 0); parser.space()
        guard parser.offset == parser.bytes.count else { throw ProfileCleanupProblem.savedData }
    }
    mutating func space() { while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
    mutating func quoted() throws -> String {
        let start = offset
        guard offset < bytes.count, bytes[offset] == 34 else { throw ProfileCleanupProblem.savedData }
        offset += 1
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if byte == 92 { guard offset < bytes.count else { break }; offset += 1 }
            else if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
        }
        throw ProfileCleanupProblem.savedData
    }
    mutating func value(depth: Int) throws {
        nodes += 1; space()
        guard depth <= 32, nodes <= 1_000_000, offset < bytes.count else { throw ProfileCleanupProblem.savedData }
        switch bytes[offset] {
        case 123:
            offset += 1; space(); var keys = Set<String>()
            if offset < bytes.count, bytes[offset] == 125 { offset += 1; return }
            while true {
                space(); let key = try quoted()
                guard keys.insert(key).inserted else { throw ProfileCleanupProblem.savedData }
                space(); guard offset < bytes.count, bytes[offset] == 58 else { throw ProfileCleanupProblem.savedData }
                offset += 1; try value(depth: depth + 1); space()
                guard offset < bytes.count else { throw ProfileCleanupProblem.savedData }
                let end = bytes[offset]; offset += 1
                if end == 125 { return }; guard end == 44 else { throw ProfileCleanupProblem.savedData }
            }
        case 91:
            offset += 1; space()
            if offset < bytes.count, bytes[offset] == 93 { offset += 1; return }
            while true {
                try value(depth: depth + 1); space(); guard offset < bytes.count else { throw ProfileCleanupProblem.savedData }
                let end = bytes[offset]; offset += 1
                if end == 93 { return }; guard end == 44 else { throw ProfileCleanupProblem.savedData }
            }
        case 34: _ = try quoted()
        default:
            let start = offset
            while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            guard offset > start else { throw ProfileCleanupProblem.savedData }
        }
    }
}
