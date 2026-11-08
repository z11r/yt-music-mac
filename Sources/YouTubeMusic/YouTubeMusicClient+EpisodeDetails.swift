// The read route follows ytmusicapi's get_episode (MIT License).
// See THIRD_PARTY_NOTICES.md and docs/EPISODE_DETAILS.md.
import Foundation

extension YouTubeMusicClient {
    public func episodeDetails(_ reference: MusicEpisodeDetailsReference, expectedScope: UUID) async throws -> MusicEpisodeDetailsResult {
        try Task.checkCancellation()
        let session = await sessions.snapshot()
        try Task.checkCancellation()
        guard session.scope == expectedScope else { throw MusicServiceError.sessionChanged }
        try Task.checkCancellation()
        let data = try await request(endpoint: .browse, body: ["browseId": reference.identity.browseID],
            session: session, requiresAuthentication: false, checksScopeBeforeBootstrap: true)
        try await validateScope(expectedScope)
        let result = try MusicEpisodeDetailsParser.parse(data, reference: reference)
        try await validateScope(expectedScope)
        return result
    }
}
