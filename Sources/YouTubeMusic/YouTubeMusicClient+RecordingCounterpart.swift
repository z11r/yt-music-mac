// Request fields follow the ytmusicapi watch implementation (MIT License).
// See THIRD_PARTY_NOTICES.md.
import Foundation

extension YouTubeMusicClient {
    /// One exact, authenticated metadata read. No continuation, stream URL or mode command.
    public func recordingCounterpart(videoID: String, expectedScope: UUID) async throws -> MusicRecordingCounterpartResult {
        guard MusicRecordingCounterpartParser.isVideoID(videoID) else { throw MusicServiceError.invalidInput }
        try Task.checkCancellation()
        let session = await sessions.snapshot()
        try Task.checkCancellation()
        guard session.scope == expectedScope else { throw MusicServiceError.sessionChanged }
        guard session.isAuthenticated else { throw MusicServiceError.signInRequired }
        let data = try await request(endpoint: .next, body: [
            "videoId": videoID, "enablePersistentPlaylistPanel": true, "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"
        ], session: session, requiresAuthentication: true, checksScopeBeforeBootstrap: true)
        try Task.checkCancellation()
        try await validateScope(expectedScope)
        let result = try MusicRecordingCounterpartParser.parse(data, videoID: videoID)
        try Task.checkCancellation()
        try await validateScope(expectedScope)
        return result
    }
}
