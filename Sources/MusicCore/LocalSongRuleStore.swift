import Foundation

public enum LocalSongRuleError: Error, Equatable, LocalizedError, Sendable {
    case invalidArchive, invalidRule, invalidSnapshot, invalidName, duplicateName, notFound, capacityReached, fileTooLarge
    case unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidArchive: "The local song-rule file could not be read. Its contents have been kept."
        case .invalidRule: "Choose 1–12 supported conditions with valid text or duration values."
        case .invalidSnapshot: "This loaded-song snapshot contains invalid metadata. The previous file has been kept."
        case .invalidName: "Use a name of 1–100 characters without control characters."
        case .duplicateName: "A local song rule already uses this name."
        case .notFound: "This local song rule no longer exists. Refresh the list."
        case .capacityReached: "The local song-rule limit was reached. Remove an unused rule first."
        case .fileTooLarge: "The local song-rule file exceeds its storage limit."
        case let .unsupportedVersion(version): "Local song-rule version \(version) is not supported. Its file has been kept."
        }
    }
}

public struct LocalSongRuleArchive: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public var rules: [LocalSongRule]
    public var snapshot: LocalSongRuleSnapshot?
    public init(version: Int = currentVersion, rules: [LocalSongRule] = [], snapshot: LocalSongRuleSnapshot? = nil) {
        self.version = version; self.rules = rules; self.snapshot = snapshot
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case version, rules, snapshot }
    public init(from decoder: any Decoder) throws {
        try SongRuleSchema.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw LocalSongRuleError.unsupportedVersion(version) }
        rules = try SongRuleSchema.array(LocalSongRule.self, values: values, key: .rules, limit: 50)
        snapshot = try values.decodeIfPresent(LocalSongRuleSnapshot.self, forKey: .snapshot)
    }
}

/// Rules and one explicit source snapshot for the app's existing confirmed account namespace.
public actor LocalSongRuleStore {
    public static let byteLimit = 8 * 1024 * 1024
    public static let songLimit = 5_000
    private let directoryURL: URL
    private let maximumBytes: Int
    private let maximumRules: Int
    private let maximumSongs: Int
    private let now: @Sendable () -> Date

    public init(directoryURL: URL, maximumBytes: Int = byteLimit, maximumRules: Int = 50, maximumSongs: Int = songLimit,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.directoryURL = directoryURL; self.maximumBytes = min(Self.byteLimit, max(1, maximumBytes))
        self.maximumRules = min(50, max(1, maximumRules)); self.maximumSongs = min(Self.songLimit, max(1, maximumSongs)); self.now = now
    }

    public func load(accountKey: String) throws -> LocalSongRuleArchive {
        let url = try fileURL(accountKey)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LocalSongRuleError.invalidArchive }
            if let size = attributes[.size] as? NSNumber, size.intValue > maximumBytes { throw LocalSongRuleError.fileTooLarge }
            guard let stream = InputStream(url: url) else { throw LocalSongRuleError.invalidArchive }
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                try Task.checkCancellation()
                let count = stream.read(&buffer, maxLength: min(buffer.count, maximumBytes + 1 - data.count))
                guard count >= 0 else { throw LocalSongRuleError.invalidArchive }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= maximumBytes else { throw LocalSongRuleError.fileTooLarge }
            }
            let archive: LocalSongRuleArchive
            do { archive = try JSONDecoder().decode(LocalSongRuleArchive.self, from: data) }
            catch let error as LocalSongRuleError { throw error }
            catch { throw LocalSongRuleError.invalidArchive }
            try validate(archive)
            return archive
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return LocalSongRuleArchive() }
    }

    @discardableResult public func save(_ rule: LocalSongRule, accountKey: String) throws -> LocalSongRuleArchive {
        var archive = try load(accountKey: accountKey)
        var rule = rule
        rule.name = try name(rule.name)
        guard !archive.rules.contains(where: { $0.id != rule.id && $0.name.caseInsensitiveCompare(rule.name) == .orderedSame }) else { throw LocalSongRuleError.duplicateName }
        if let index = archive.rules.firstIndex(where: { $0.id == rule.id }) { archive.rules[index] = rule }
        else {
            guard archive.rules.count < maximumRules else { throw LocalSongRuleError.capacityReached }
            archive.rules.append(rule)
        }
        return try write(archive, accountKey: accountKey)
    }

    @discardableResult public func remove(id: UUID, accountKey: String) throws -> LocalSongRuleArchive {
        var archive = try load(accountKey: accountKey)
        guard archive.rules.contains(where: { $0.id == id }) else { throw LocalSongRuleError.notFound }
        archive.rules.removeAll { $0.id == id }
        return try write(archive, accountKey: accountKey)
    }

    @discardableResult public func capture(tracks: [Track], sourceName: String, hasMorePages: Bool, wasLoading: Bool,
                                          unavailableCount: Int = 0, hasUnsupportedContent: Bool = false,
                                          accountKey: String) throws -> LocalSongRuleArchive {
        var archive = try load(accountKey: accountKey)
        var songs: [LocalSongRuleSong] = []
        var skipped = 0
        for track in tracks.prefix(maximumSongs) {
            if Self.validVideoID(track.id) { songs.append(LocalSongRuleSong(track: track)) }
            else { skipped += 1 }
        }
        archive.snapshot = LocalSongRuleSnapshot(capturedAt: now(), sourceName: sourceName, songs: songs,
            hasMorePages: hasMorePages, wasLoading: wasLoading, unavailableCount: unavailableCount,
            hasUnsupportedContent: hasUnsupportedContent, isTruncated: tracks.count > maximumSongs, skippedCount: skipped)
        return try write(archive, accountKey: accountKey)
    }

    @discardableResult public func clearSnapshot(accountKey: String) throws -> LocalSongRuleArchive {
        var archive = try load(accountKey: accountKey)
        archive.snapshot = nil
        return try write(archive, accountKey: accountKey)
    }

    public static func validVideoID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }

    private func name(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(trimmed.count), validText(trimmed, maximum: 1_024) else { throw LocalSongRuleError.invalidName }
        return trimmed
    }
    private func validText(_ value: String, maximum: Int = 4_096) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximum &&
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private func validate(_ archive: LocalSongRuleArchive) throws {
        guard archive.version == LocalSongRuleArchive.currentVersion else { throw LocalSongRuleError.unsupportedVersion(archive.version) }
        guard archive.rules.count <= maximumRules else { throw LocalSongRuleError.capacityReached }
        guard Set(archive.rules.map(\.id)).count == archive.rules.count else { throw LocalSongRuleError.invalidArchive }
        var names = Set<String>()
        for rule in archive.rules {
            guard try name(rule.name) == rule.name, names.insert(rule.name.lowercased()).inserted else { throw LocalSongRuleError.invalidName }
            guard (1...12).contains(rule.clauses.count), Set(rule.clauses.map(\.id)).count == rule.clauses.count else { throw LocalSongRuleError.invalidRule }
            for clause in rule.clauses {
                guard clause.allowedOperators.contains(clause.operation) else { throw LocalSongRuleError.invalidRule }
                if clause.usesText {
                    guard let text = clause.text, text.count <= 200, validText(text, maximum: 2_048), clause.number == nil else { throw LocalSongRuleError.invalidRule }
                } else if clause.usesNumber {
                    guard let number = clause.number, number.isFinite, (0...604_800).contains(number), clause.text == nil else { throw LocalSongRuleError.invalidRule }
                } else if clause.text != nil || clause.number != nil { throw LocalSongRuleError.invalidRule }
            }
        }
        if let snapshot = archive.snapshot {
            guard snapshot.capturedAt.timeIntervalSinceReferenceDate.isFinite, validText(snapshot.sourceName, maximum: 1_024), snapshot.sourceName.count <= 200,
                  snapshot.songs.count <= maximumSongs, Set(snapshot.songs.map(\.id)).count == snapshot.songs.count,
                  (0...1_000_000).contains(snapshot.unavailableCount), snapshot.skippedCount >= 0,
                  snapshot.skippedCount <= maximumSongs - snapshot.songs.count else { throw LocalSongRuleError.invalidSnapshot }
            for song in snapshot.songs {
                guard Self.validVideoID(song.videoID), [song.title, song.artist, song.album].allSatisfy({ $0.map { validText($0) } ?? true }),
                      song.duration.map({ $0.isFinite && (0...604_800).contains($0) }) ?? true else { throw LocalSongRuleError.invalidSnapshot }
            }
        }
    }
    private func write(_ archive: LocalSongRuleArchive, accountKey: String) throws -> LocalSongRuleArchive {
        try validate(archive)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= maximumBytes else { throw LocalSongRuleError.fileTooLarge }
        let url = try fileURL(accountKey)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return archive
    }
    private func fileURL(_ key: String) throws -> URL {
        guard directoryURL.isFileURL else { throw QueuePersistenceError.invalidStorageURL }
        guard NamedQueueStore.acceptsAccountKey(key) else { throw NamedQueueError.invalidAccount }
        return directoryURL.appendingPathComponent(key).appendingPathComponent("song-rules.json")
    }
}
