import Foundation
import MusicCore

/// Only the explicitly disclosed public text, never a service identifier or URL.
struct PublicPlaybackMetadata: Encodable, Equatable, Sendable {
    let title: String
    let artist: String

    init?(track: Track) {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard track.isExplicitCatalogSong,
              track.id.utf8.count == 11, track.id.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
              }), title != track.id, !["unknown artist", "artiste inconnu"].contains(artist.lowercased()),
              [title, artist].allSatisfy({ value in
                  !value.isEmpty && value.count <= 128 && value.utf8.count <= 512 && !value.contains("://") &&
                  !["file:", "data:", "javascript:"].contains(where: value.lowercased().hasPrefix) &&
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }) else { return nil }
        self.title = title; self.artist = artist
    }
}

enum StreamingMetadataFormat: String, Codable, CaseIterable, Sendable { case json, text }

struct StreamingMetadataDocument: Encodable, Sendable {
    let version = 1
    let state: String
    let title: String?
    let artist: String?
    let updatedAt: Date
    let expiresAt: Date
    init(metadata: PublicPlaybackMetadata?, now: Date) {
        state = metadata == nil ? "stopped" : "playing"
        title = metadata?.title; artist = metadata?.artist
        updatedAt = now; expiresAt = metadata == nil ? now : now.addingTimeInterval(15)
    }
    func encoded(format: StreamingMetadataFormat) throws -> Data {
        if format == .text {
            guard let title, let artist else { return Data() }
            return Data("\(title) — \(artist)".utf8)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

enum PlaybackOutputTime {
    private static let origin = ContinuousClock.now
    static func monotonic() -> TimeInterval {
        let value = origin.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}

/// Revocation is synchronous. An admitted bounded file commit completes before revoke returns.
final class PlaybackOutputGate: @unchecked Sendable {
    struct Permit: Sendable { let revision: UInt64; let target: UUID }
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var active: Permit?
    func activate(target: UUID) -> Permit {
        lock.withLock { revision &+= 1; let permit = Permit(revision: revision, target: target); active = permit; return permit }
    }
    func revoke() -> UInt64 { lock.withLock { revision &+= 1; active = nil; return revision } }
    func configuring<T>(through revision: UInt64, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard self.revision == revision, active == nil else { throw StreamingExportError.revoked }
            return try body()
        }
    }
    func publishing<T>(_ permit: Permit, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard active?.revision == permit.revision, active?.target == permit.target else { throw StreamingExportError.revoked }
            return try body()
        }
    }
    func clearing<T>(target: UUID, through revision: UInt64, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard !(active?.target == target && (active?.revision ?? 0) > revision) else { throw StreamingExportError.revoked }
            return try body()
        }
    }
}
