import Foundation
import MusicCore

enum LastFMDeliveryState: String, Codable, Sendable { case ready, sending, confirmed, ignored, uncertain, rejected, retryable, needsAuthorization }
extension LastFMDeliveryState { var isFinal: Bool { self == .confirmed || self == .ignored } }
struct LastFMPending: Codable, Equatable, Identifiable, Sendable {
    let listen: EarnedListen
    let username: String
    var state: LastFMDeliveryState
    var chosenByUser: Bool? = nil
    var id: UUID { listen.id }
}
struct LastFMPlayProvenance: Codable, Equatable, Sendable {
    let listenID: UUID
    let chosenByUser: Bool?
}
struct LastFMDocument: Codable, Equatable, Sendable {
    var version = 1
    let profile: String
    var enabled = false
    var configured = false
    var sessionRejected = false
    var appFingerprint: String?
    var credentialRevision: UUID?
    var username: String?
    var paused = false
    var ledger = ListeningLedgerState()
    var currentProvenance: LastFMPlayProvenance?
    var outbox: [LastFMPending] = []
    init(profile: String) { self.profile = profile }
    func validate() throws {
        guard version == 1 else { throw LastFMStoreError.unsupportedVersion }
        guard EpisodeProgressSnapshot.validAccountHash(profile),
              (appFingerprint.map(EpisodeProgressSnapshot.validAccountHash) ?? !configured),
              !configured || credentialRevision != nil, !enabled || configured, ledger.validate(),
              currentProvenance.map({ $0.listenID == ledger.current?.id }) ?? true, outbox.count <= 150,
              outbox.filter({ !$0.state.isFinal }).count <= 100, Set(outbox.map(\.id)).count == outbox.count,
              (username.map(Self.validUsername) ?? !enabled), outbox.allSatisfy({ item in
                Self.validUsername(item.username) && item.listen.metadata.isValid && item.listen.duration.isFinite &&
                (30...2_073_600).contains(item.listen.duration) && item.listen.listenedAt >= 1_033_430_400
              }) else { throw LastFMStoreError.invalidData }
    }
    static func validUsername(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 256 && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
enum LastFMStoreError: Error, Equatable { case invalidData, unsupportedVersion, tooLarge }

/// The coordinator actor owns this store; no shared preferences contain tokens
/// or listening metadata. Corrupt and newer files are never silently replaced.
struct LastFMStore: Sendable {
    let directory: URL
    var maximumBytes = 524_288
    func load(profile: String) throws -> LastFMDocument {
        let url = try file(profile)
        do {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard (size?.intValue ?? maximumBytes + 1) <= maximumBytes else { throw LastFMStoreError.tooLarge }
            let data = try Data(contentsOf: url)
            guard data.count <= maximumBytes else { throw LastFMStoreError.tooLarge }
            let value = try JSONDecoder().decode(LastFMDocument.self, from: data)
            try value.validate()
            guard value.profile == profile else { throw LastFMStoreError.invalidData }
            return value
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return .init(profile: profile) }
    }
    func save(_ value: LastFMDocument) throws {
        try value.validate()
        _ = try load(profile: value.profile)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw LastFMStoreError.tooLarge }
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
        guard directory.isFileURL, EpisodeProgressSnapshot.validAccountHash(profile) else { throw LastFMStoreError.invalidData }
        return directory.appendingPathComponent(profile + ".json")
    }
}
