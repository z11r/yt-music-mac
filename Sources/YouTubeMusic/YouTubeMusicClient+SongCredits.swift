// Request path adapted from ytmusicapi, copyright (c) 2026 sigma67, under the
// MIT License. See THIRD_PARTY_NOTICES.md for the license and source paths.
import Foundation
import MusicCore

extension YouTubeMusicClient {
    /// A read-only detail request for a destination offered by this song's menu.
    /// This endpoint also supports the existing public, anonymous session.
    public func songCredits(_ reference: SongCreditsReference, expectedScope: UUID,
                            timeout: Duration = .seconds(15)) async throws -> MusicSongCredits {
        guard timeout > .zero, timeout <= .seconds(25) else { throw MusicServiceError.invalidInput }
        return try await withThrowingTaskGroup(of: MusicSongCredits.self) { group in
            group.addTask {
                let session = await self.sessions.snapshot()
                guard session.scope == expectedScope else { throw MusicServiceError.sessionChanged }
                let data = try await self.request(endpoint: .browse, body: ["browseId": reference.browseID],
                                                  session: session, requiresAuthentication: false)
                let credits = try MusicSongCreditsParser.parse(data)
                try await self.validateScope(expectedScope)
                return credits
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MusicSongCreditsError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return result
        }
    }
}
