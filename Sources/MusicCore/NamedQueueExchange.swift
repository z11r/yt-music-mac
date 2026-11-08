import Foundation

public enum NamedQueueExchangeError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(Int), invalidDocument, invalidSong, invalidLink, tooManySongs, protectedDestination, uploadedMusicUnsupported, localAudioUnsupported

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version): CoreLocalization.format("Saved queue exchange version %lld is not supported.", version)
        case .invalidDocument: CoreLocalization.text("This file is not valid saved queue metadata.")
        case .invalidSong: CoreLocalization.text("The file contains invalid song identifiers, text, or durations.")
        case .invalidLink: CoreLocalization.text("Song links must identify the matching song on YouTube Music.")
        case .tooManySongs: CoreLocalization.text("This file contains too many songs to import.")
        case .uploadedMusicUnsupported: CoreLocalization.text("Uploaded music has no verified portable service link. Save this queue locally instead.")
        case .localAudioUnsupported: CoreLocalization.text("Local audio files cannot be exported as service links. Save this queue locally instead.")
        case .protectedDestination: CoreLocalization.text("Choose an export location outside the app's saved queue storage.")
        }
    }
}

public struct ImportedNamedQueue: Sendable {
    public let name: String
    public let snapshot: QueueSnapshot
}

/// A portable metadata-and-link document. Account identity, local occurrence IDs,
/// credentials, artwork URLs, playback position, and audio are never exported.
public enum NamedQueueExchange {
    public static let currentVersion = 1
    public static let maximumSongs = 10_000
    public static let maximumBytes = 8 * 1024 * 1024

    private struct Song: Codable {
        let videoID: String
        let title: String
        let artist: String
        let album: String?
        let duration: TimeInterval?
        let link: String?
    }

    private struct Document: Codable {
        let version: Int
        let name: String
        let songs: [Song]
        private enum CodingKeys: String, CodingKey { case version, name, songs }

        init(name: String, songs: [Song]) {
            version = currentVersion
            self.name = name
            self.songs = songs
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            guard version == currentVersion else { throw NamedQueueExchangeError.unsupportedVersion(version) }
            name = try container.decode(String.self, forKey: .name)
            try validateName(name)
            var values = try container.nestedUnkeyedContainer(forKey: .songs)
            if let count = values.count, count > maximumSongs { throw NamedQueueExchangeError.tooManySongs }
            var parsed: [Song] = []
            while !values.isAtEnd {
                guard parsed.count < maximumSongs else { throw NamedQueueExchangeError.tooManySongs }
                let song = try values.decode(Song.self)
                try validate(song)
                parsed.append(song)
            }
            songs = parsed
        }
    }

    public static func encode(name: String, snapshot: QueueSnapshot) throws -> Data {
        try validateName(name)
        try snapshot.validate()
        guard snapshot.entries.count <= maximumSongs else { throw NamedQueueExchangeError.tooManySongs }
        let songs = try snapshot.entries.map { entry -> Song in
            let track = entry.track
            guard !track.hasLocalAudioSource else { throw NamedQueueExchangeError.localAudioUnsupported }
            guard track.origin != .upload else { throw NamedQueueExchangeError.uploadedMusicUnsupported }
            let song = Song(videoID: track.id, title: track.title, artist: track.artist,
                            album: track.album, duration: track.duration,
                            link: "https://music.youtube.com/watch?v=" + track.id)
            try validate(song)
            return song
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Document(name: name, songs: songs))
        guard data.count <= maximumBytes else { throw QueuePersistenceError.fileTooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> ImportedNamedQueue {
        guard data.count <= maximumBytes else { throw QueuePersistenceError.fileTooLarge }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch let error as NamedQueueExchangeError { throw error }
        catch { throw NamedQueueExchangeError.invalidDocument }
        let entries = document.songs.map { song in
            QueueEntry(track: Track(id: song.videoID, title: song.title, artist: song.artist,
                                    album: song.album, duration: song.duration))
        }
        // Every import receives fresh local entry identities, including repeated songs.
        let snapshot = QueueSnapshot(entries: entries, currentEntryID: entries.first?.id)
        try snapshot.validate()
        return ImportedNamedQueue(name: document.name, snapshot: snapshot)
    }

    /// Check size before reading and stream at most maximumBytes + 1 bytes, even
    /// if another process grows the selected file after its attributes were read.
    public static func read(from url: URL) throws -> ImportedNamedQueue {
        guard url.isFileURL else { throw QueuePersistenceError.invalidStorageURL }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw NamedQueueExchangeError.invalidDocument }
        if let size = attributes[.size] as? NSNumber, size.intValue > maximumBytes {
            throw QueuePersistenceError.fileTooLarge
        }
        guard let stream = InputStream(url: url) else { throw NamedQueueExchangeError.invalidDocument }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let capacity = min(buffer.count, maximumBytes + 1 - data.count)
            guard capacity > 0 else { throw QueuePersistenceError.fileTooLarge }
            let count = stream.read(&buffer, maxLength: capacity)
            guard count >= 0 else { throw NamedQueueExchangeError.invalidDocument }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw QueuePersistenceError.fileTooLarge }
        }
        return try decode(data)
    }

    public static func write(name: String, snapshot: QueueSnapshot, to url: URL) throws {
        guard url.isFileURL else { throw QueuePersistenceError.invalidStorageURL }
        let data = try encode(name: name, snapshot: snapshot)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func validateName(_ name: String) throws {
        guard (1...100).contains(name.count), name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw NamedQueueError.invalidName
        }
    }

    private static func validate(_ song: Song) throws {
        let allowed = song.videoID.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
        guard song.videoID.utf8.count == 11, allowed,
              validText(song.title, allowsEmpty: false), validText(song.artist, allowsEmpty: true),
              song.album.map({ validText($0, allowsEmpty: true) }) ?? true,
              song.duration.map({ $0.isFinite && (0...604_800).contains($0) }) ?? true else {
            throw NamedQueueExchangeError.invalidSong
        }
        if let link = song.link {
            guard let url = URLComponents(string: link), url.scheme == "https", url.host == "music.youtube.com",
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443,
                  url.path == "/watch", url.fragment == nil,
                  let query = url.queryItems, query.count == 1, query[0].name == "v", query[0].value == song.videoID else {
                throw NamedQueueExchangeError.invalidLink
            }
        }
    }

    private static func validText(_ text: String, allowsEmpty: Bool) -> Bool {
        (allowsEmpty || !text.isEmpty) && text.utf8.count <= 4_096 &&
            !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
