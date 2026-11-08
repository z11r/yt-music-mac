// Portions adapted from Kaset, copyright (c) 2025 sozercan, under the MIT License.
// See THIRD_PARTY_NOTICES.md for the license and upstream source paths.
import Foundation

extension YouTubeMusicClient {
    /// Fetches only from YouTube Music, by exact video ID. No third-party lyrics
    /// provider receives the song's title, artist, or listening activity.
    public func lyrics(videoID: String, timeout: Duration = .seconds(15)) async throws -> MusicLyrics {
        guard videoID.utf8.count == 11, videoID.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }), timeout > .zero, timeout <= .seconds(25) else { throw MusicServiceError.invalidInput }
        return try await withThrowingTaskGroup(of: MusicLyrics.self) { group in
            group.addTask { try await self.readLyrics(videoID: videoID) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MusicLyricsError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return result
        }
    }

    private func readLyrics(videoID: String) async throws -> MusicLyrics {
        let session = await sessions.snapshot()
        let data = try await request(endpoint: .next, body: [
            "videoId": videoID, "enablePersistentPlaylistPanel": true, "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ], session: session, requiresAuthentication: false)
        let reference = try MusicLyricsParser.nextReference(data)
        if let inline = reference.lyrics {
            try await validateScope(session.scope)
            return inline
        }
        guard let browseID = reference.browseID else {
            try await validateScope(session.scope)
            return .unavailable
        }
        try await validateScope(session.scope)
        let lyrics = try await request(endpoint: .browse, body: ["browseId": browseID],
                                       session: session, requiresAuthentication: false)
        let parsed = try MusicLyricsParser.browseLyrics(lyrics)
        try Task.checkCancellation()
        try await validateScope(session.scope)
        return parsed
    }
}
