import Darwin
import Foundation

public enum QueuePlaylistJournalError: Error, Equatable, LocalizedError, Sendable {
    case invalidQueue, uploadedMusicUnsupported, localAudioUnsupported, podcastUnsupported, invalidTitle, invalidJournal, tooLarge, pendingExists, busy, stale, noPending
    case unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidQueue: CoreLocalization.text("Review a queue of 1–10,000 songs with valid, distinct queue entries.")
        case .uploadedMusicUnsupported: CoreLocalization.text("Saving uploaded music to a service playlist is not verified. Save this queue locally instead.")
        case .localAudioUnsupported: CoreLocalization.text("Local audio files cannot be added to a service playlist. Save this queue locally instead.")
        case .podcastUnsupported: CoreLocalization.text("Saving podcast episodes to a music playlist is not verified. Save this queue locally instead.")
        case .invalidTitle: CoreLocalization.text("Use a playlist title of 1–150 characters without angle brackets or control characters.")
        case .invalidJournal: CoreLocalization.text("The pending playlist-save record could not be read. Its file has been kept.")
        case .tooLarge: CoreLocalization.text("The pending playlist-save record exceeds its storage limit.")
        case .pendingExists: CoreLocalization.text("Review the pending playlist save before starting another.")
        case .busy: CoreLocalization.text("Another playlist-save operation is using this account's pending record.")
        case .stale: CoreLocalization.text("The pending playlist-save record changed. Reload it before continuing.")
        case .noPending: CoreLocalization.text("There is no pending playlist save for this account.")
        case let .unsupportedVersion(value): CoreLocalization.format("Pending playlist-save version %lld is unsupported. Its file has been kept.", value)
        }
    }
}

public struct QueuePlaylistOccurrence: Codable, Equatable, Sendable {
    public let videoID: String
    public let setVideoID: String
    public init(videoID: String, setVideoID: String) { self.videoID = videoID; self.setVideoID = setVideoID }
    private enum CodingKeys: String, CodingKey, CaseIterable { case videoID, setVideoID }
    public init(from decoder: any Decoder) throws {
        try QueuePlaylistCoding.keys(decoder, CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        videoID = try values.decode(String.self, forKey: .videoID); setVideoID = try values.decode(String.self, forKey: .setVideoID)
    }
}

public struct QueuePlaylistPlan: Codable, Equatable, Identifiable, Sendable {
    public struct Song: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let videoID: String
        public let title: String
        public let artist: String
        public init(id: UUID, videoID: String, title: String, artist: String) {
            self.id = id; self.videoID = videoID; self.title = title; self.artist = artist
        }
        private enum CodingKeys: String, CodingKey, CaseIterable { case id, videoID, title, artist }
        public init(from decoder: any Decoder) throws {
            try QueuePlaylistCoding.keys(decoder, CodingKeys.allCases.map(\.rawValue))
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id); videoID = try values.decode(String.self, forKey: .videoID)
            title = try values.decode(String.self, forKey: .title); artist = try values.decode(String.self, forKey: .artist)
        }
    }
    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let songs: [Song]
    public init(id: UUID = UUID(), title: String, createdAt: Date, songs: [Song]) throws {
        self.id = id; self.title = title.trimmingCharacters(in: .whitespacesAndNewlines); self.createdAt = createdAt; self.songs = songs
        try validate()
    }
    public static func reviewedSongs(_ snapshot: QueueSnapshot) throws -> [Song] {
        do { try snapshot.validate() } catch { throw QueuePlaylistJournalError.invalidQueue }
        guard (1...10_000).contains(snapshot.entries.count) else { throw QueuePlaylistJournalError.invalidQueue }
        return try snapshot.entries.map { entry in
            guard !entry.track.hasLocalAudioSource else { throw QueuePlaylistJournalError.localAudioUnsupported }
            guard entry.track.origin != .upload else { throw QueuePlaylistJournalError.uploadedMusicUnsupported }
            guard entry.track.contentKind != .podcastEpisode, entry.track.episode == nil else { throw QueuePlaylistJournalError.podcastUnsupported }
            guard validVideoID(entry.track.id) else { throw QueuePlaylistJournalError.invalidQueue }
            func label(_ value: String) -> String {
                let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
                var result = ""
                for character in cleaned.prefix(80) {
                    guard result.utf8.count + character.utf8.count <= 320 else { break }
                    result.append(character)
                }
                return result
            }
            return Song(id: entry.id, videoID: entry.track.id, title: label(entry.track.title), artist: label(entry.track.artist))
        }
    }
    public func validate() throws {
        guard (1...150).contains(title.count), title.utf8.count <= 1_024, !title.contains("<"), !title.contains(">"),
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw QueuePlaylistJournalError.invalidTitle }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite, (1...10_000).contains(songs.count),
              Set(songs.map(\.id)).count == songs.count else { throw QueuePlaylistJournalError.invalidQueue }
        for song in songs {
            guard Self.validVideoID(song.videoID), [song.title, song.artist].allSatisfy({ $0.count <= 80 && $0.utf8.count <= 320 &&
                !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw QueuePlaylistJournalError.invalidQueue }
        }
    }
    public static func validVideoID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    public static func validPlaylistID(_ value: String) -> Bool {
        value.hasPrefix("PL") && (3...256).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    public static func validOccurrence(_ value: QueuePlaylistOccurrence) -> Bool {
        validVideoID(value.videoID) && !value.setVideoID.isEmpty && value.setVideoID.utf8.count <= 2_048 &&
        !value.setVideoID.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case id, title, createdAt, songs }
    public init(from decoder: any Decoder) throws {
        try QueuePlaylistCoding.keys(decoder, CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        songs = try QueuePlaylistCoding.array(Song.self, values, .songs, limit: 10_000)
    }
}

public struct QueuePlaylistPending: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case prepared, creating, targetKnown, batchPending, completed }
    public let version: Int
    public let plan: QueuePlaylistPlan
    public var revision: UUID
    public var updatedAt: Date
    public var phase: Phase
    public var targetID: String?
    public var confirmed: [QueuePlaylistOccurrence]
    public var attemptedEnd: Int?
    public var acknowledged: [QueuePlaylistOccurrence]?
    public init(plan: QueuePlaylistPlan, now: Date) {
        version = 1; self.plan = plan; revision = UUID(); updatedAt = now; phase = .prepared
        targetID = nil; confirmed = []; attemptedEnd = nil; acknowledged = nil
    }
    public func validate() throws {
        guard version == 1 else { throw QueuePlaylistJournalError.unsupportedVersion(version) }
        try plan.validate()
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite, confirmed.count <= plan.songs.count,
              confirmed.allSatisfy(QueuePlaylistPlan.validOccurrence), Set(confirmed.map(\.setVideoID)).count == confirmed.count,
              confirmed.map(\.videoID) == plan.songs.prefix(confirmed.count).map(\.videoID) else { throw QueuePlaylistJournalError.invalidJournal }
        switch phase {
        case .prepared, .creating:
            guard targetID == nil, confirmed.isEmpty, attemptedEnd == nil, acknowledged == nil else { throw QueuePlaylistJournalError.invalidJournal }
        case .targetKnown, .completed:
            guard targetID.map(QueuePlaylistPlan.validPlaylistID) == true, attemptedEnd == nil, acknowledged == nil,
                  phase == .completed ? confirmed.count == plan.songs.count : confirmed.count < plan.songs.count else { throw QueuePlaylistJournalError.invalidJournal }
        case .batchPending:
            guard targetID.map(QueuePlaylistPlan.validPlaylistID) == true, let end = attemptedEnd,
                  confirmed.count < end, end <= plan.songs.count, end - confirmed.count <= 100 else { throw QueuePlaylistJournalError.invalidJournal }
            if let acknowledged {
                guard acknowledged.count == end - confirmed.count, acknowledged.allSatisfy(QueuePlaylistPlan.validOccurrence),
                      acknowledged.map(\.videoID).sorted() == plan.songs[confirmed.count..<end].map(\.videoID).sorted(),
                      Set((confirmed + acknowledged).map(\.setVideoID)).count == confirmed.count + acknowledged.count else {
                    throw QueuePlaylistJournalError.invalidJournal
                }
            }
        }
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case version, plan, revision, updatedAt, phase, targetID, confirmed, attemptedEnd, acknowledged }
    public init(from decoder: any Decoder) throws {
        try QueuePlaylistCoding.keys(decoder, CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == 1 else { throw QueuePlaylistJournalError.unsupportedVersion(version) }
        plan = try values.decode(QueuePlaylistPlan.self, forKey: .plan); revision = try values.decode(UUID.self, forKey: .revision)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt); phase = try values.decode(Phase.self, forKey: .phase)
        targetID = try values.decodeIfPresent(String.self, forKey: .targetID)
        confirmed = try QueuePlaylistCoding.array(QueuePlaylistOccurrence.self, values, .confirmed, limit: 10_000)
        attemptedEnd = try values.decodeIfPresent(Int.self, forKey: .attemptedEnd)
        if values.contains(.acknowledged), try !values.decodeNil(forKey: .acknowledged) {
            acknowledged = try QueuePlaylistCoding.array(QueuePlaylistOccurrence.self, values, .acknowledged, limit: 100)
        } else { acknowledged = nil }
    }
}

public struct QueuePlaylistJournalLease: Sendable {
    fileprivate let id: UUID
    fileprivate let accountKey: String
}

public actor QueuePlaylistJournalStore {
    public static let byteLimit = 32 * 1024 * 1024
    private let directoryURL: URL
    private let maximumBytes: Int
    private let now: @Sendable () -> Date
    private var lease: (token: QueuePlaylistJournalLease, descriptor: Int32)?
    public init(directoryURL: URL, maximumBytes: Int = byteLimit, now: @escaping @Sendable () -> Date = Date.init) {
        self.directoryURL = directoryURL; self.maximumBytes = min(Self.byteLimit, max(1, maximumBytes)); self.now = now
    }
    deinit { if let lease { _ = Darwin.close(lease.descriptor) } }

    public func acquire(accountKey: String) throws -> QueuePlaylistJournalLease {
        guard lease == nil else { throw QueuePlaylistJournalError.busy }
        let directory = try fileURL(accountKey).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("operation.lock").path
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw QueuePlaylistJournalError.busy }
        let token = QueuePlaylistJournalLease(id: UUID(), accountKey: accountKey)
        lease = (token, descriptor)
        return token
    }
    public func release(_ token: QueuePlaylistJournalLease) {
        guard lease?.token.id == token.id else { return }
        if let descriptor = lease?.descriptor { _ = Darwin.close(descriptor) }
        lease = nil
    }
    public func load(accountKey: String) throws -> QueuePlaylistPending? {
        let url = try fileURL(accountKey)
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { throw QueuePlaylistJournalError.invalidJournal }
            if let size = attrs[.size] as? NSNumber, size.intValue > maximumBytes { throw QueuePlaylistJournalError.tooLarge }
            guard let stream = InputStream(url: url) else { throw QueuePlaylistJournalError.invalidJournal }
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = stream.read(&buffer, maxLength: min(buffer.count, maximumBytes + 1 - data.count))
                guard count >= 0 else { throw QueuePlaylistJournalError.invalidJournal }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= maximumBytes else { throw QueuePlaylistJournalError.tooLarge }
            }
            let pending: QueuePlaylistPending
            do { pending = try JSONDecoder().decode(QueuePlaylistPending.self, from: data) }
            catch let error as QueuePlaylistJournalError { throw error }
            catch { throw QueuePlaylistJournalError.invalidJournal }
            try pending.validate()
            return pending
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return nil }
    }
    public func begin(_ plan: QueuePlaylistPlan, lease: QueuePlaylistJournalLease) throws -> QueuePlaylistPending {
        try require(lease)
        guard try load(accountKey: lease.accountKey) == nil else { throw QueuePlaylistJournalError.pendingExists }
        let pending = QueuePlaylistPending(plan: plan, now: now())
        try write(pending, accountKey: lease.accountKey)
        return pending
    }
    public func update(_ pending: QueuePlaylistPending, expectedRevision: UUID, lease: QueuePlaylistJournalLease) throws -> QueuePlaylistPending {
        try require(lease)
        guard let previous = try load(accountKey: lease.accountKey), previous.plan.id == pending.plan.id,
              previous.plan == pending.plan, previous.revision == expectedRevision else { throw QueuePlaylistJournalError.stale }
        try validateTransition(from: previous, to: pending)
        var next = pending; next.revision = UUID(); next.updatedAt = now()
        try write(next, accountKey: lease.accountKey)
        return next
    }
    public func forget(id: UUID, revision: UUID, lease: QueuePlaylistJournalLease) throws {
        try require(lease)
        guard let pending = try load(accountKey: lease.accountKey), pending.plan.id == id, pending.revision == revision else { throw QueuePlaylistJournalError.stale }
        let url = try fileURL(lease.accountKey)
        try FileManager.default.removeItem(at: url)
        try synchronize(url.deletingLastPathComponent())
    }
    private func require(_ token: QueuePlaylistJournalLease) throws {
        guard lease?.token.id == token.id, lease?.token.accountKey == token.accountKey else { throw QueuePlaylistJournalError.busy }
    }
    private func validateTransition(from previous: QueuePlaylistPending, to next: QueuePlaylistPending) throws {
        guard previous.targetID == nil || next.targetID == previous.targetID,
              next.confirmed.count >= previous.confirmed.count,
              Array(next.confirmed.prefix(previous.confirmed.count)) == previous.confirmed else { throw QueuePlaylistJournalError.invalidJournal }
        let allowed: Bool
        switch (previous.phase, next.phase) {
        case (.prepared, .creating), (.creating, .prepared): allowed = true
        case (.creating, .targetKnown): allowed = next.confirmed.isEmpty
        case (.targetKnown, .batchPending): allowed = next.confirmed == previous.confirmed && next.acknowledged == nil
        case (.batchPending, .batchPending):
            allowed = next.confirmed == previous.confirmed && next.attemptedEnd == previous.attemptedEnd &&
                (previous.acknowledged == nil || next.acknowledged == previous.acknowledged)
        case (.batchPending, .targetKnown), (.batchPending, .completed):
            allowed = next.confirmed.count == previous.attemptedEnd ||
                (next.phase == .targetKnown && next.confirmed == previous.confirmed && previous.acknowledged == nil)
        default: allowed = false
        }
        guard allowed else { throw QueuePlaylistJournalError.invalidJournal }
    }
    private func write(_ pending: QueuePlaylistPending, accountKey: String) throws {
        try pending.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(pending)
        guard data.count <= maximumBytes else { throw QueuePlaylistJournalError.tooLarge }
        let url = try fileURL(accountKey)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try synchronize(url)
        try synchronize(url.deletingLastPathComponent())
    }
    private func synchronize(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func fileURL(_ key: String) throws -> URL {
        guard directoryURL.isFileURL else { throw QueuePersistenceError.invalidStorageURL }
        guard NamedQueueStore.acceptsAccountKey(key) else { throw NamedQueueError.invalidAccount }
        return directoryURL.appendingPathComponent(key).appendingPathComponent("pending.json")
    }
}

private enum QueuePlaylistCoding {
    private struct Key: CodingKey {
        let stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func keys(_ decoder: any Decoder, _ allowed: [String]) throws {
        let raw = try decoder.container(keyedBy: Key.self)
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: Set(allowed)) else { throw QueuePlaylistJournalError.invalidJournal }
    }
    static func array<Value: Decodable, Key: CodingKey>(_ type: Value.Type, _ values: KeyedDecodingContainer<Key>, _ key: Key, limit: Int) throws -> [Value] {
        var list = try values.nestedUnkeyedContainer(forKey: key)
        guard list.count.map({ $0 <= limit }) ?? true else { throw QueuePlaylistJournalError.tooLarge }
        var result: [Value] = []
        while !list.isAtEnd {
            guard result.count < limit else { throw QueuePlaylistJournalError.tooLarge }
            result.append(try list.decode(Value.self))
        }
        return result
    }
}
