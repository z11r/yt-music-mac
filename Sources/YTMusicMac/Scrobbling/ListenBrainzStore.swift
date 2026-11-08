import Foundation
import MusicCore

enum ListenBrainzDeliveryState: String, Codable, Sendable { case ready, sending, confirmed, uncertain, rejected }
struct ListenBrainzPending: Codable, Equatable, Identifiable, Sendable {
    let listen: EarnedListen
    let username: String
    var state: ListenBrainzDeliveryState
    var id: UUID { listen.id }
}
struct ListenBrainzDocument: Codable, Equatable, Sendable {
    var version = 1
    let profile: String
    var enabled = false
    var username: String?
    var paused = false
    var ledger = ListeningLedgerState()
    var outbox: [ListenBrainzPending] = []
    init(profile: String) { self.profile = profile }
    func validate() throws {
        guard version == 1 else { throw ListenBrainzStoreError.unsupportedVersion }
        guard EpisodeProgressSnapshot.validAccountHash(profile), ledger.validate(), outbox.count <= 150,
              outbox.filter({ $0.state != .confirmed }).count <= 100, Set(outbox.map(\.id)).count == outbox.count,
              (username.map(Self.validUsername) ?? !enabled), outbox.allSatisfy({ item in
                Self.validUsername(item.username) && item.listen.metadata.isValid && item.listen.duration.isFinite &&
                (30...2_073_600).contains(item.listen.duration) && item.listen.listenedAt >= 1_033_430_400
              }) else { throw ListenBrainzStoreError.invalidData }
    }
    static func validUsername(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 256 && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
enum ListenBrainzStoreError: Error, Equatable, LocalizedError {
    case invalidData, unsupportedVersion, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidData: AppLocalization.text("The local ListenBrainz data could not be read. Its file has been kept.")
        case .unsupportedVersion: AppLocalization.text("This version of the local ListenBrainz data is not supported. Its file has been kept.")
        case .tooLarge: AppLocalization.text("The local ListenBrainz data exceeds its storage limit.")
        }
    }
}

/// The coordinator actor owns this store; no shared preferences contain tokens
/// or listening metadata. Corrupt and newer files are never silently replaced.
struct ListenBrainzStore: Sendable {
    let directory: URL
    var maximumBytes = 524_288
    func load(profile: String) throws -> ListenBrainzDocument {
        let url = try file(profile)
        do {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard (size?.intValue ?? maximumBytes + 1) <= maximumBytes else { throw ListenBrainzStoreError.tooLarge }
            let data = try Data(contentsOf: url)
            guard data.count <= maximumBytes else { throw ListenBrainzStoreError.tooLarge }
            let value = try JSONDecoder().decode(ListenBrainzDocument.self, from: data)
            try value.validate()
            guard value.profile == profile else { throw ListenBrainzStoreError.invalidData }
            return value
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return .init(profile: profile) }
    }
    func save(_ value: ListenBrainzDocument) throws {
        try value.validate()
        _ = try load(profile: value.profile)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw ListenBrainzStoreError.tooLarge }
        let url = try file(value.profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func clear(profile: String) throws {
        do { try FileManager.default.removeItem(at: file(profile)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { }
    }
    private func file(_ profile: String) throws -> URL {
        guard directory.isFileURL, EpisodeProgressSnapshot.validAccountHash(profile) else { throw ListenBrainzStoreError.invalidData }
        return directory.appendingPathComponent(profile + ".json")
    }
}
