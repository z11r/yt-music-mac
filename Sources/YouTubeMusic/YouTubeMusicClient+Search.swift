// Portions adapted from Kaset, copyright (c) 2025 sozercan, under the MIT License.
// See THIRD_PARTY_NOTICES.md for the license and upstream source paths.
import Foundation

extension YouTubeMusicClient {
    /// Suggested queries for partly typed search text. The text is sent as typed,
    /// because a trailing space changes the suggestions.
    public func searchSuggestions(for input: String) async throws -> [MusicSearchSuggestion] {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.count <= 500,
              !input.contains(where: \.isNewline) else { throw MusicServiceError.invalidInput }
        let session = await sessions.snapshot()
        let data = try await request(endpoint: .searchSuggestions, body: ["input": input],
                                     session: session, requiresAuthentication: false)
        return try MusicSearchSuggestionParser.parse(data)
    }
}
