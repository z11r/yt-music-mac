// Request shapes adapted from Kaset, copyright (c) 2025 sozercan, under the MIT License.
// See THIRD_PARTY_NOTICES.md for the license and upstream source paths.
import CryptoKit
import Foundation

public enum PlaylistPrivacy: String, Sendable {
    case `private` = "PRIVATE"
    case unlisted = "UNLISTED"
    case `public` = "PUBLIC"
}

/// A service-assigned playlist occurrence, separate from a song or local queue entry.
public struct PlaylistItemReference: Hashable, Sendable {
    public let videoID: String
    public let setVideoID: String

    public init(videoID: String, setVideoID: String) {
        self.videoID = videoID
        self.setVideoID = setVideoID
    }
}

/// Returned only when the response explicitly confirms the requested change.
public enum MusicLibraryEditResult: Equatable, Sendable {
    case liked(videoID: String, isLiked: Bool)
    case playlistCreated(id: String)
    case playlistRenamed(id: String, title: String)
    case playlistDeleted(id: String)
    case itemsAdded(playlistID: String, items: [PlaylistItemReference])
    case itemsRemoved(playlistID: String, items: [PlaylistItemReference])
}

public enum MusicLibraryEditError: Error, Equatable, LocalizedError, Sendable {
    case invalidTitle
    case invalidPlaylistItems
    case serviceRejected
    case interactionRequired
    case unconfirmedOutcome

    public var errorDescription: String? {
        switch self {
        case .invalidTitle: "Enter a playlist title of 1–150 characters, without angle brackets or control characters."
        case .invalidPlaylistItems: "The playlist selection is missing valid song or occurrence identifiers. Reload the playlist and try again."
        case .serviceRejected: "YouTube Music declined this change. Check that you can edit this playlist."
        case .interactionRequired: "YouTube Music requires an account action before making this change. Open YouTube Music to continue."
        case .unconfirmedOutcome: "YouTube Music did not confirm the change. Check your library before trying again."
        }
    }
}

extension YouTubeMusicClient {
    public func setLiked(_ liked: Bool, videoID: String) async throws -> MusicLibraryEditResult {
        try validateIdentifier(videoID)
        let response = try await libraryMutation(endpoint: liked ? "like/like" : "like/removelike",
                                                 body: ["target": ["videoId": videoID]])
        try Self.requireMutationConfirmation(response)
        return .liked(videoID: videoID, isLiked: liked)
    }

    public func createPlaylist(title: String, description: String? = nil,
                               privacy: PlaylistPrivacy = .private, videoIDs: [String] = []) async throws -> MusicLibraryEditResult {
        let title = try Self.playlistTitle(title)
        try validateVideos(videoIDs, allowEmpty: true)
        guard (description?.count ?? 0) <= 5_000 else { throw MusicServiceError.invalidInput }
        var body: [String: Any] = ["title": title, "privacyStatus": privacy.rawValue]
        if let description, !description.isEmpty { body["description"] = description }
        if !videoIDs.isEmpty { body["videoIds"] = videoIDs }
        let response = try await libraryMutation(endpoint: "playlist/create", body: body)
        guard let id = response["playlistId"] as? String else { throw MusicLibraryEditError.unconfirmedOutcome }
        do { try validateIdentifier(id) } catch { throw MusicLibraryEditError.unconfirmedOutcome }
        return .playlistCreated(id: id)
    }

    public func renamePlaylist(id: String, title: String) async throws -> MusicLibraryEditResult {
        let id = try editablePlaylistID(id)
        let title = try Self.playlistTitle(title)
        let response = try await libraryMutation(endpoint: "browse/edit_playlist", body: [
            "playlistId": id,
            "actions": [["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title]],
        ])
        try Self.requireMutationConfirmation(response)
        return .playlistRenamed(id: id, title: title)
    }

    public func deletePlaylist(id: String) async throws -> MusicLibraryEditResult {
        let id = try editablePlaylistID(id)
        let response = try await libraryMutation(endpoint: "playlist/delete", body: ["playlistId": id])
        try Self.requireMutationConfirmation(response)
        return .playlistDeleted(id: id)
    }

    public func addPlaylistItems(playlistID: String, videoIDs: [String],
                                 allowDuplicates: Bool = false) async throws -> MusicLibraryEditResult {
        let playlistID = try editablePlaylistID(playlistID)
        try validateVideos(videoIDs)
        guard allowDuplicates || Set(videoIDs).count == videoIDs.count else {
            throw MusicLibraryEditError.invalidPlaylistItems
        }
        let actions: [[String: String]] = videoIDs.map { videoID in
            var action = ["action": "ACTION_ADD_VIDEO", "addedVideoId": videoID]
            if allowDuplicates { action["dedupeOption"] = "DEDUPE_OPTION_SKIP" }
            return action
        }
        let response = try await libraryMutation(endpoint: "browse/edit_playlist", body: [
            "playlistId": playlistID, "actions": actions,
        ])
        try Self.requireMutationConfirmation(response)
        guard let results = response["playlistEditResults"] as? [[String: Any]] else {
            throw MusicLibraryEditError.unconfirmedOutcome
        }
        let added = try results.map { result -> PlaylistItemReference in
            guard let item = result["playlistEditVideoAddedResultData"] as? [String: Any],
                  let videoID = item["videoId"] as? String, let setVideoID = item["setVideoId"] as? String
            else { throw MusicLibraryEditError.unconfirmedOutcome }
            let reference = PlaylistItemReference(videoID: videoID, setVideoID: setVideoID)
            do { try validateReferences([reference]) } catch { throw MusicLibraryEditError.unconfirmedOutcome }
            return reference
        }
        guard added.map(\.videoID).sorted() == videoIDs.sorted(),
              Set(added.map(\.setVideoID)).count == added.count else {
            throw MusicLibraryEditError.unconfirmedOutcome
        }
        return .itemsAdded(playlistID: playlistID, items: added)
    }

    public func removePlaylistItems(playlistID: String, items: [PlaylistItemReference]) async throws -> MusicLibraryEditResult {
        let playlistID = try editablePlaylistID(playlistID)
        try validateReferences(items)
        let response = try await libraryMutation(endpoint: "browse/edit_playlist", body: [
            "playlistId": playlistID,
            "actions": items.map { ["action": "ACTION_REMOVE_VIDEO", "removedVideoId": $0.videoID, "setVideoId": $0.setVideoID] },
        ])
        try Self.requireMutationConfirmation(response)
        return .itemsRemoved(playlistID: playlistID, items: items)
    }

    private func editablePlaylistID(_ id: String) throws -> String {
        let normalized = id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
        try validateIdentifier(normalized)
        return normalized
    }

    private static func playlistTitle(_ value: String) throws -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 150, !title.contains("<"), !title.contains(">"),
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MusicLibraryEditError.invalidTitle
        }
        return title
    }

    private func validateVideos(_ ids: [String], allowEmpty: Bool = false) throws {
        guard (allowEmpty || !ids.isEmpty), ids.count <= 100 else { throw MusicLibraryEditError.invalidPlaylistItems }
        for id in ids { try validateIdentifier(id) }
    }

    private func validateReferences(_ references: [PlaylistItemReference]) throws {
        guard !references.isEmpty, references.count <= 100,
              Set(references.map(\.setVideoID)).count == references.count else {
            throw MusicLibraryEditError.invalidPlaylistItems
        }
        for reference in references {
            try validateIdentifier(reference.videoID)
            // Occurrence identifiers are opaque and can include punctuation such as '='.
            guard !reference.setVideoID.isEmpty, reference.setVideoID.utf8.count <= 2_048,
                  !reference.setVideoID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                throw MusicLibraryEditError.invalidPlaylistItems
            }
        }
    }

    private static func requireMutationConfirmation(_ response: [String: Any]) throws {
        guard response["status"] as? String == "STATUS_SUCCEEDED" else {
            throw MusicLibraryEditError.unconfirmedOutcome
        }
    }

    /// Writes are sent once. A lost response cannot establish whether the server applied the change.
    private func libraryMutation(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        let session = await sessions.snapshot()
        guard session.isAuthenticated, let cookie = session.cookieHeader, let sapisid = session.sapisid else {
            throw MusicServiceError.signInRequired
        }
        let configuration: MusicClientConfiguration
        if let supplied = session.configuration { configuration = supplied }
        else { configuration = try await bootstrapConfiguration() }
        try await validateScope(session.scope)
        guard !configuration.apiKey.isEmpty, !configuration.clientVersion.isEmpty,
              !configuration.clientVersion.contains(where: { $0 == "\r" || $0 == "\n" }),
              !cookie.contains(where: { $0 == "\r" || $0 == "\n" }), (0...99).contains(session.authUser) else {
            throw MusicServiceError.invalidInput
        }
        var url = URLComponents(url: Self.origin.appendingPathComponent("youtubei/v1/" + endpoint), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey), URLQueryItem(name: "prettyPrint", value: "false")]
        var request = URLRequest(url: url.url!)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.origin.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue("67", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(configuration.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(Self.origin.absoluteString, forHTTPHeaderField: "X-Origin")
        request.setValue(String(session.authUser), forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let timestamp = Int(now().timeIntervalSince1970)
        let input = "\(timestamp) \(sapisid) \(Self.origin.absoluteString)"
        let hash = Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        request.setValue("SAPISIDHASH \(timestamp)_\(hash)", forHTTPHeaderField: "Authorization")
        var client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": configuration.clientVersion,
                                   "hl": configuration.language, "gl": configuration.region, "platform": "DESKTOP",
                                   "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60]
        if let visitor = configuration.visitorData { client["visitorData"] = visitor }
        var user: [String: Any] = ["lockedSafetyMode": false]
        if let delegated = session.delegatedSessionID { user["onBehalfOfUser"] = delegated }
        var fullBody = body
        fullBody["context"] = ["client": client, "user": user]
        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)
        try await validateScope(session.scope)
        let response: MusicHTTPResponse
        do { response = try await transport.send(request) }
        catch {
            try await validateScope(session.scope)
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw MusicLibraryEditError.unconfirmedOutcome
        }
        try await validateScope(session.scope)
        if response.statusCode == 401 { throw MusicServiceError.authenticationRejected }
        if response.statusCode == 403 { throw MusicServiceError.accessDenied }
        if response.statusCode == 429 { throw MusicServiceError.rateLimited }
        if (400..<500).contains(response.statusCode) { throw MusicLibraryEditError.serviceRejected }
        guard (200..<300).contains(response.statusCode), response.data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw MusicLibraryEditError.unconfirmedOutcome
        }
        if object["error"] != nil { throw MusicLibraryEditError.serviceRejected }
        if let actions = object["actions"] as? [[String: Any]], actions.contains(where: { $0["showEngagementPanelEndpoint"] != nil }) {
            throw MusicLibraryEditError.interactionRequired
        }
        if let alerts = object["alerts"] as? [[String: Any]], alerts.contains(where: {
            ($0["alertRenderer"] as? [String: Any])?["type"] as? String == "ERROR"
        }) { throw MusicLibraryEditError.serviceRejected }
        if let rawStatus = object["status"] {
            guard let status = rawStatus as? String else { throw MusicLibraryEditError.unconfirmedOutcome }
            if status != "STATUS_SUCCEEDED" { throw MusicLibraryEditError.serviceRejected }
        }
        return object
    }
}
