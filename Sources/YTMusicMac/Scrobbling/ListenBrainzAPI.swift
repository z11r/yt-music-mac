import Foundation
import MusicCore

enum ListenBrainzSubmissionOutcome: Sendable, Equatable { case confirmed, rejected, authenticationRejected, uncertain }
enum ListenBrainzAPIError: Error { case invalidToken, unavailable }

struct ListenBrainzAPI: Sendable {
    let transport: any ScrobbleHTTPTransport
    static func validToken(_ value: String) -> Bool {
        (1...256).contains(value.utf8.count) && value.utf8.allSatisfy { $0 >= 33 && $0 <= 126 }
    }
    func validateToken(_ token: String) async throws -> String {
        try Task.checkCancellation()
        var request = try request(path: "validate-token", method: "GET", token: token)
        request.httpBody = nil
        let response = try await transport.send(request)
        struct Validation: Decodable { let valid: Bool; let user_name: String }
        guard response.statusCode == 200, response.data.count <= 65_536,
              let validation = try? JSONDecoder().decode(Validation.self, from: response.data), validation.valid else {
            throw ListenBrainzAPIError.invalidToken
        }
        let name = validation.user_name
        guard
              !name.isEmpty, name.utf8.count <= 256, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ListenBrainzAPIError.invalidToken
        }
        return name
    }

    /// Exactly one POST. A transport error or ambiguous reply remains uncertain.
    func submit(_ listen: EarnedListen, token: String, authorized: @Sendable () -> Bool = { true }) async -> ListenBrainzSubmissionOutcome {
        do {
            try Task.checkCancellation()
            guard listen.metadata.isValid, listen.duration.isFinite, (30...2_073_600).contains(listen.duration),
                  listen.listenedAt >= 1_033_430_400 else { return .rejected }
            var request = try request(path: "submit-listens", method: "POST", token: token)
            var metadata: [String: Any] = ["artist_name": listen.metadata.artist, "track_name": listen.metadata.title,
                "additional_info": ["duration_ms": Int(listen.duration * 1_000), "music_service_name": "YouTube Music", "submission_client": "YT Music for Mac"]]
            if let album = listen.metadata.album { metadata["release_name"] = album }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["listen_type": "import", "payload": [
                ["listened_at": listen.listenedAt, "track_metadata": metadata],
            ]])
            guard request.httpBody!.count <= 10_240 else { return .rejected }
            try Task.checkCancellation()
            guard authorized() else { return .uncertain }
            let response = try await transport.send(request)
            if response.statusCode == 401 { return .authenticationRejected }
            if response.statusCode == 400 { return .rejected }
            guard response.statusCode == 200, response.data.count <= 65_536,
                  let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  object["status"] as? String == "ok" else { return .uncertain }
            return .confirmed
        } catch { return .uncertain }
    }

    private func request(path: String, method: String, token: String) throws -> URLRequest {
        guard Self.validToken(token) else { throw ListenBrainzAPIError.invalidToken }
        var request = URLRequest(url: URL(string: "https://api.listenbrainz.org/1/" + path)!)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("Token " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("YTMusicMac (https://github.com/z11r/yt-music-mac)", forHTTPHeaderField: "User-Agent")
        return request
    }
}
