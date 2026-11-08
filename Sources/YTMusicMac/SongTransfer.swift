import CoreTransferable
import Foundation
import MusicCore
import UniformTypeIdentifiers

extension UTType {
    static let ytMusicSongs = UTType(exportedAs: "io.github.z11r.ytmusicmac.songs", conformingTo: .data)
}

/// An in-app drag, bound to the account generation that supplied its rows.
/// It carries no artwork URLs, account identity, credentials, or audio.
struct SongTransfer: Transferable, Sendable {
    static let maximumSongs = 128
    static let maximumBytes = 256 * 1024
    let tracks: [Track]
    let scope: UUID

    private struct Envelope: Codable {
        let version: Int
        let scope: UUID
        let tracks: [Track]
    }
    enum TransferError: Error { case invalidPayload }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .ytMusicSongs) { value in
            try value.encoded()
        } importing: { data in
            try decode(data)
        }
    }

    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(Envelope(version: 1, scope: scope, tracks: Self.validated(tracks)))
        guard data.count <= Self.maximumBytes else { throw TransferError.invalidPayload }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw TransferError.invalidPayload }
        let payload = try JSONDecoder().decode(Envelope.self, from: data)
        guard payload.version == 1 else { throw TransferError.invalidPayload }
        return SongTransfer(tracks: try validated(payload.tracks), scope: payload.scope)
    }

    static func acceptedTracks(_ items: [Self], expectedScope: UUID) -> [Track]? {
        guard !items.isEmpty, items.count <= maximumSongs else { return nil }
        var tracks: [Track] = []
        for item in items {
            guard item.scope == expectedScope, let validated = try? validated(item.tracks),
                  validated.count <= maximumSongs - tracks.count else { return nil }
            tracks.append(contentsOf: validated)
        }
        return tracks
    }

    private static func validated(_ tracks: [Track]) throws -> [Track] {
        guard !tracks.isEmpty, tracks.count <= maximumSongs else { throw TransferError.invalidPayload }
        return try tracks.map { original in
            guard original.isServiceTrack, ScriptingInput.videoID(original.id) == original.id,
                  original.title.utf8.count <= 4_096, original.artist.utf8.count <= 4_096,
                  (original.album?.utf8.count ?? 0) <= 4_096,
                  original.duration.map({ $0.isFinite && (0...604_800).contains($0) }) ?? true,
                  (original.artistReferences?.count ?? 0) <= 16 else { throw TransferError.invalidPayload }
            let references = (original.artistReferences ?? []) + (original.albumReference.map { [$0] } ?? [])
            guard references.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 1_024 && $0.title.utf8.count <= 4_096 }) else {
                throw TransferError.invalidPayload
            }
            var track = original
            track.artworkURL = nil
            return track
        }
    }
}
