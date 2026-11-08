// Portions adapted from Kaset, copyright (c) 2025 sozercan, under the MIT License.
// See THIRD_PARTY_NOTICES.md for the license and upstream source paths.
import Foundation
import MusicCore

/// One page of a radio or mix from the service's watch playlist.
public struct MusicRadioPage: Sendable {
    /// The service's name for the radio, such as "Song Name Mix", when it supplies one.
    public let title: String?
    public let playlistID: String?
    /// Songs in service order without repeats. The first page of a song radio usually starts with the seed song.
    public let tracks: [Track]
    /// The song the service marked as current: the seed of a song radio, or the first song of a mix.
    public let selectedTrackID: String?
    public let continuation: MusicRadioContinuation?

    public init(title: String? = nil, playlistID: String? = nil, tracks: [Track], selectedTrackID: String? = nil,
                continuation: MusicRadioContinuation? = nil) {
        self.title = title
        self.playlistID = playlistID
        self.tracks = tracks
        self.selectedTrackID = selectedTrackID
        self.continuation = continuation
    }

    /// The radio's songs without the given song, for a queue that already holds it.
    public func tracks(excluding videoID: String) -> [Track] { tracks.filter { $0.id != videoID } }
}

/// Opaque, account-bound radio pagination state. Retain it after a failed request to retry the same page.
public struct MusicRadioContinuation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let token: String
    let scope: UUID
    let playlistID: String?
    let previousTokens: Set<String>
    let previousTrackIDs: Set<String>
    public var description: String { "MusicRadioContinuation" }
    public var debugDescription: String { description }
}

extension YouTubeMusicClient {
    /// Songs related to a seed song. Without a playlist ID this requests the song's radio (`RDAMVM` and the video ID).
    public func radio(videoID: String, playlistID: String? = nil) async throws -> MusicRadioPage {
        try validateIdentifier(videoID)
        let playlist = playlistID ?? "RDAMVM" + videoID
        try validateIdentifier(playlist)
        return try await firstRadioPage(["videoId": videoID, "playlistId": playlist])
    }

    /// A radio or mix the service offered for a collection, from `MusicCollection.radioPlaylistID`.
    public func radio(playlistID: String) async throws -> MusicRadioPage {
        try validateIdentifier(playlistID)
        return try await firstRadioPage(["playlistId": playlistID])
    }

    public func nextRadioPage(_ continuation: MusicRadioContinuation) async throws -> MusicRadioPage {
        let session = await sessions.snapshot()
        guard session.scope == continuation.scope else { throw MusicServiceError.sessionChanged }
        guard !continuation.previousTokens.contains(continuation.token) else { throw MusicServiceError.paginationLoop }
        let data = try await request(endpoint: .next, body: Self.radioOptions.merging(["continuation": continuation.token]) { $1 },
                                     session: session, requiresAuthentication: false)
        let parsed = try MusicRadioParser.parse(data)
        var tokens = continuation.previousTokens
        tokens.insert(continuation.token)
        if let token = parsed.token, tokens.contains(token) { throw MusicServiceError.paginationLoop }
        return makeRadioPage(parsed, session: session, playlistID: continuation.playlistID,
                             previousTokens: tokens, previousTrackIDs: continuation.previousTrackIDs)
    }

    private static var radioOptions: [String: Any] { ["enablePersistentPlaylistPanel": true, "isAudioOnly": true] }

    private func firstRadioPage(_ body: [String: String]) async throws -> MusicRadioPage {
        let session = await sessions.snapshot()
        var fullBody = Self.radioOptions.merging(body) { $1 }
        fullBody["tunerSettingValue"] = "AUTOMIX_SETTING_NORMAL"
        let data = try await request(endpoint: .next, body: fullBody, session: session, requiresAuthentication: false)
        let parsed = try MusicRadioParser.parse(data)
        return makeRadioPage(parsed, session: session, playlistID: body["playlistId"], previousTokens: [], previousTrackIDs: [])
    }

    private func makeRadioPage(_ parsed: ParsedRadioPage, session: MusicSession, playlistID: String?,
                               previousTokens: Set<String>, previousTrackIDs: Set<String>) -> MusicRadioPage {
        var seen = previousTrackIDs
        let tracks = parsed.tracks.filter { seen.insert($0.id).inserted }
        let playlist = parsed.playlistID ?? playlistID
        let next = parsed.token.map {
            MusicRadioContinuation(token: $0, scope: session.scope, playlistID: playlist,
                                   previousTokens: previousTokens, previousTrackIDs: seen)
        }
        return MusicRadioPage(title: parsed.title, playlistID: playlist, tracks: tracks,
                              selectedTrackID: parsed.selectedTrackID, continuation: next)
    }
}
