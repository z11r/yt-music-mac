import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@Suite("Song drag payloads")
struct SongTransferTests {
    @Test func roundTripKeepsSelectedOrderDuplicatesAndUploadIdentityWithoutArtworkURLs() throws {
        let scope = UUID()
        let upload = Track(id: "abcDEF12_-3", title: "Upload", artist: "Artist",
                           artworkURL: URL(string: "https://private.example/art"), origin: .upload)
        let other = Track(id: "otherID12_3", title: "Other", artist: "Artist")
        let data = try SongTransfer(tracks: [upload, other, upload], scope: scope).encoded()
        #expect(!String(decoding: data, as: UTF8.self).contains("private.example"))
        let decoded = try SongTransfer.decode(data)
        let tracks = try #require(SongTransfer.acceptedTracks([decoded], expectedScope: scope))
        #expect(tracks.map(\.id) == [upload.id, other.id, upload.id])
        #expect(tracks.map(\.origin) == [.upload, nil, .upload])
        #expect(tracks.allSatisfy { $0.artworkURL == nil })
    }

    @Test func staleOrMixedAccountDragsCannotPartiallyAddSongs() {
        let scope = UUID()
        let current = SongTransfer(tracks: [track], scope: scope)
        let old = SongTransfer(tracks: [track], scope: UUID())
        #expect(SongTransfer.acceptedTracks([old], expectedScope: scope) == nil)
        #expect(SongTransfer.acceptedTracks([current, old], expectedScope: scope) == nil)
        #expect(SongTransfer.acceptedTracks([], expectedScope: scope) == nil)
    }

    @Test func aggregateAndIndividualSongLimitsRejectTheWholeDrag() throws {
        let scope = UUID()
        let half = SongTransfer(tracks: Array(repeating: track, count: 64), scope: scope)
        #expect(SongTransfer.acceptedTracks([half, half], expectedScope: scope)?.count == 128)
        #expect(SongTransfer.acceptedTracks([half, half, half], expectedScope: scope) == nil)
        #expect(throws: SongTransfer.TransferError.invalidPayload) {
            try SongTransfer(tracks: Array(repeating: track, count: 129), scope: scope).encoded()
        }
    }

    @Test func oversizedFutureAndMalformedDataAreRejectedBeforePublication() throws {
        #expect(throws: SongTransfer.TransferError.invalidPayload) {
            try SongTransfer.decode(Data(repeating: 0, count: SongTransfer.maximumBytes + 1))
        }
        let data = try SongTransfer(tracks: [track], scope: UUID()).encoded()
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 2
        #expect(throws: SongTransfer.TransferError.invalidPayload) {
            try SongTransfer.decode(JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: (any Error).self) { try SongTransfer.decode(Data("broken".utf8)) }
    }

    @Test func invalidVideoIdentifiersTextDurationsAndReferencesAreRejected() throws {
        var bad = track
        bad.duration = -1
        var long = track
        long.title = String(repeating: "x", count: 4_097)
        var references = track
        references.artistReferences = Array(repeating: .init(id: "UCfixture", title: "Artist"), count: 17)
        for invalid in [Track(id: "entity-id", title: "Song", artist: "Artist"), bad, long, references] {
            #expect(throws: SongTransfer.TransferError.invalidPayload) {
                try SongTransfer(tracks: [invalid], scope: UUID()).encoded()
            }
        }
    }

    private var track: Track { Track(id: "abcDEF12_-3", title: "Song", artist: "Artist") }
}
