// Request shapes adapted from Kaset, copyright (c) 2025 sozercan, under the MIT License.
// See THIRD_PARTY_NOTICES.md for the license and upstream source paths.
// Additional playlist actions follow ytmusicapi, copyright (c) 2026 sigma67, MIT License.
import CryptoKit
import Foundation

public enum PlaylistPrivacy: String, Hashable, Sendable {
    case `private` = "PRIVATE"
    case unlisted = "UNLISTED"
    case `public` = "PUBLIC"
}

public enum MusicLibraryEditAction: Equatable, Sendable {
    case setLiked(videoID: String, liked: Bool)
    case setRating(videoID: String, rating: MusicRating)
    case createPlaylist(title: String, description: String?, privacy: PlaylistPrivacy, videoIDs: [String])
    case renamePlaylist(id: String, title: String)
    case deletePlaylist(id: String)
    case addItems(playlistID: String, videoIDs: [String], allowDuplicates: Bool)
    case removeItems(playlistID: String, items: [PlaylistItemReference])
    case setPlaylistDescription(id: String, description: String)
    case setPlaylistPrivacy(id: String, privacy: PlaylistPrivacy)
    case movePlaylistItem(playlistID: String, item: PlaylistItemReference, before: PlaylistItemReference?)
    case setAlbumSaved(browseID: String, playlistID: String, saved: Bool)
    case setArtistSubscribed(browseID: String, channelID: String, subscribed: Bool)
}

/// Enabled separately only after the corresponding signed-in operations have been verified.
public struct MusicLibraryEditCapabilities: Hashable, Sendable {
    public let likes: Bool
    public let dislikes: Bool
    public let playlists: Bool
    public let playlistDescription: Bool
    public let playlistPrivacy: Bool
    public let playlistReorder: Bool
    public let albumLibrary: Bool
    public let artistSubscriptions: Bool

    public init(likes: Bool = false, dislikes: Bool = false, playlists: Bool = false,
                playlistDescription: Bool = false, playlistPrivacy: Bool = false, playlistReorder: Bool = false,
                albumLibrary: Bool = false, artistSubscriptions: Bool = false) {
        self.likes = likes
        self.dislikes = dislikes
        self.playlists = playlists
        self.playlistDescription = playlistDescription
        self.playlistPrivacy = playlistPrivacy
        self.playlistReorder = playlistReorder
        self.albumLibrary = albumLibrary
        self.artistSubscriptions = artistSubscriptions
    }

    public var hasAny: Bool {
        likes || dislikes || playlists || playlistDescription || playlistPrivacy || playlistReorder || albumLibrary || artistSubscriptions
    }

    public func allows(_ action: MusicLibraryEditAction) -> Bool {
        switch action {
        case .setLiked: likes
        case let .setRating(_, rating):
            switch rating {
            case .liked: likes
            case .disliked: dislikes
            case .neutral: likes || dislikes
            }
        case .setPlaylistDescription: playlistDescription
        case .setPlaylistPrivacy: playlistPrivacy
        case .movePlaylistItem: playlistReorder
        case .setAlbumSaved: albumLibrary
        case .setArtistSubscribed: artistSubscriptions
        default: playlists
        }
    }
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
    case rated(videoID: String, rating: MusicRating)
    case playlistCreated(id: String)
    case playlistRenamed(id: String, title: String)
    case playlistDeleted(id: String)
    case itemsAdded(playlistID: String, items: [PlaylistItemReference])
    case itemsRemoved(playlistID: String, items: [PlaylistItemReference])
    case playlistDescriptionChanged(id: String)
    case playlistPrivacyChanged(id: String, privacy: PlaylistPrivacy)
    case playlistItemMoved(playlistID: String, item: PlaylistItemReference, before: PlaylistItemReference?)
    case albumSaved(browseID: String, saved: Bool)
    case artistSubscribed(browseID: String, subscribed: Bool)
}

public enum MusicLibraryEditError: Error, Equatable, LocalizedError, Sendable {
    case featureUnavailable
    case operationInProgress
    case invalidTitle
    case invalidPlaylistItems
    case serviceRejected
    case interactionRequired
    case unconfirmedOutcome
    case verificationCleanupRequired
    case collectionStateUnavailable

    public var errorDescription: String? {
        switch self {
        case .featureUnavailable: "Library editing is not available in this version."
        case .operationInProgress: "Wait for the current library change to finish."
        case .invalidTitle: "Enter a playlist title of 1–150 characters, without angle brackets or control characters."
        case .invalidPlaylistItems: "The playlist selection is missing valid song or occurrence identifiers. Reload the playlist and try again."
        case .serviceRejected: "YouTube Music declined this change. Check that you can edit this playlist."
        case .interactionRequired: "YouTube Music requires an account action before making this change. Open YouTube Music to continue."
        case .unconfirmedOutcome: "YouTube Music did not confirm the change. Check your library before trying again."
        case .verificationCleanupRequired: "A previous verification playlist still needs cleanup before another check can start."
        case .collectionStateUnavailable: "Reload this collection to confirm its current permissions, occurrences, and library state before editing."
        }
    }
}

extension YouTubeMusicClient {
    /// Account fence only; no credentials or account identity leave the client.
    public func libraryEditScope() async throws -> UUID {
        let session = await sessions.snapshot()
        guard session.isAuthenticated else { throw MusicServiceError.signInRequired }
        return session.scope
    }

    /// UI entry point. An uncertain response never triggers an automatic repeat submission.
    public func performLibraryEdit(_ action: MusicLibraryEditAction, expectedScope: UUID? = nil) async throws -> MusicLibraryEditResult {
        guard libraryEditCapabilities.allows(action) else { throw MusicLibraryEditError.featureUnavailable }
        return try await executeLibraryEdit(action, expectedScope: expectedScope)
    }

    func executeLibraryEdit(_ action: MusicLibraryEditAction, expectedScope: UUID? = nil) async throws -> MusicLibraryEditResult {
        try Task.checkCancellation()
        guard !libraryEditInProgress else { throw MusicLibraryEditError.operationInProgress }
        libraryEditInProgress = true
        defer { libraryEditInProgress = false }
        let scope: UUID
        if let expectedScope { scope = expectedScope }
        else { scope = await sessions.snapshot().scope }
        try await validateScope(scope)
        try await validateExtendedEdit(action, scope: scope)
        switch action {
        case let .setLiked(videoID, liked): return try await setLiked(liked, videoID: videoID, expectedScope: scope)
        case let .setRating(videoID, rating): return try await setRating(rating, videoID: videoID, expectedScope: scope)
        case let .createPlaylist(title, description, privacy, videoIDs):
            return try await createPlaylist(title: title, description: description, privacy: privacy, videoIDs: videoIDs, expectedScope: scope)
        case let .renamePlaylist(id, title): return try await renamePlaylist(id: id, title: title, expectedScope: scope)
        case let .deletePlaylist(id): return try await deletePlaylist(id: id, expectedScope: scope)
        case let .addItems(playlistID, videoIDs, allowDuplicates):
            return try await addPlaylistItems(playlistID: playlistID, videoIDs: videoIDs, allowDuplicates: allowDuplicates, expectedScope: scope)
        case let .removeItems(playlistID, items): return try await removePlaylistItems(playlistID: playlistID, items: items, expectedScope: scope)
        case let .setPlaylistDescription(id, description):
            return try await setPlaylistDescription(id: id, description: description, expectedScope: scope)
        case let .setPlaylistPrivacy(id, privacy):
            return try await setPlaylistPrivacy(id: id, privacy: privacy, expectedScope: scope)
        case let .movePlaylistItem(id, item, before):
            return try await movePlaylistItem(playlistID: id, item: item, before: before, expectedScope: scope)
        case let .setAlbumSaved(browseID, playlistID, saved):
            return try await setAlbumSaved(browseID: browseID, playlistID: playlistID, saved: saved, expectedScope: scope)
        case let .setArtistSubscribed(browseID, channelID, subscribed):
            return try await setArtistSubscribed(browseID: browseID, channelID: channelID, subscribed: subscribed, expectedScope: scope)
        }
    }

    func setLiked(_ liked: Bool, videoID: String, expectedScope: UUID? = nil) async throws -> MusicLibraryEditResult {
        _ = try await setRating(liked ? .liked : .neutral, videoID: videoID, expectedScope: expectedScope)
        return .liked(videoID: videoID, isLiked: liked)
    }

    func setRating(_ rating: MusicRating, videoID: String, expectedScope: UUID? = nil) async throws -> MusicLibraryEditResult {
        try validateIdentifier(videoID)
        let endpoint: String
        switch rating {
        case .liked: endpoint = "like/like"
        case .neutral: endpoint = "like/removelike"
        case .disliked: endpoint = "like/dislike"
        }
        let response = try await libraryMutation(endpoint: endpoint,
                                                 body: ["target": ["videoId": videoID]], expectedScope: expectedScope)
        try Self.requireMutationConfirmation(response)
        return .rated(videoID: videoID, rating: rating)
    }

    func createPlaylist(title: String, description: String? = nil,
                               privacy: PlaylistPrivacy = .private, videoIDs: [String] = [],
                               expectedScope: UUID? = nil) async throws -> MusicLibraryEditResult {
        let title = try Self.playlistTitle(title)
        try validateVideos(videoIDs, allowEmpty: true)
        guard (description?.count ?? 0) <= 5_000 else { throw MusicServiceError.invalidInput }
        var body: [String: Any] = ["title": title, "privacyStatus": privacy.rawValue]
        if let description, !description.isEmpty { body["description"] = description }
        if !videoIDs.isEmpty { body["videoIds"] = videoIDs }
        let response = try await libraryMutation(endpoint: "playlist/create", body: body, expectedScope: expectedScope)
        guard let id = response["playlistId"] as? String else { throw MusicLibraryEditError.unconfirmedOutcome }
        do { try validateIdentifier(id) } catch { throw MusicLibraryEditError.unconfirmedOutcome }
        return .playlistCreated(id: id)
    }

    func renamePlaylist(id: String, title: String, expectedScope: UUID? = nil) async throws -> MusicLibraryEditResult {
        let id = try editablePlaylistID(id)
        let title = try Self.playlistTitle(title)
        let response = try await libraryMutation(endpoint: "browse/edit_playlist", body: [
            "playlistId": id,
            "actions": [["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title]],
        ], expectedScope: expectedScope)
        try Self.requireMutationConfirmation(response)
        return .playlistRenamed(id: id, title: title)
    }

    func deletePlaylist(id: String, expectedScope: UUID? = nil) async throws -> MusicLibraryEditResult {
        let id = try editablePlaylistID(id)
        let response = try await libraryMutation(endpoint: "playlist/delete", body: ["playlistId": id], expectedScope: expectedScope)
        try Self.requireMutationConfirmation(response)
        return .playlistDeleted(id: id)
    }

    func addPlaylistItems(playlistID: String, videoIDs: [String],
                                 allowDuplicates: Bool = false, expectedScope: UUID? = nil) async throws -> MusicLibraryEditResult {
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
        ], expectedScope: expectedScope)
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

    func removePlaylistItems(playlistID: String, items: [PlaylistItemReference], expectedScope: UUID? = nil) async throws -> MusicLibraryEditResult {
        let playlistID = try editablePlaylistID(playlistID)
        try validateReferences(items)
        let response = try await libraryMutation(endpoint: "browse/edit_playlist", body: [
            "playlistId": playlistID,
            "actions": items.map { ["action": "ACTION_REMOVE_VIDEO", "removedVideoId": $0.videoID, "setVideoId": $0.setVideoID] },
        ], expectedScope: expectedScope)
        try Self.requireMutationConfirmation(response)
        return .itemsRemoved(playlistID: playlistID, items: items)
    }

    func setPlaylistDescription(id: String, description: String, expectedScope: UUID) async throws -> MusicLibraryEditResult {
        let id = try editablePlaylistID(id)
        guard description.count <= 5_000,
              !description.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else {
            throw MusicServiceError.invalidInput
        }
        let response = try await libraryMutation(endpoint: "browse/edit_playlist", body: [
            "playlistId": id, "actions": [["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": description]],
        ], expectedScope: expectedScope)
        try Self.requireMutationConfirmation(response)
        try await verifyExtendedEdit(.setPlaylistDescription(id: id, description: description), scope: expectedScope)
        return .playlistDescriptionChanged(id: id)
    }

    func setPlaylistPrivacy(id: String, privacy: PlaylistPrivacy, expectedScope: UUID) async throws -> MusicLibraryEditResult {
        let id = try editablePlaylistID(id)
        let response = try await libraryMutation(endpoint: "browse/edit_playlist", body: [
            "playlistId": id, "actions": [["action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": privacy.rawValue]],
        ], expectedScope: expectedScope)
        try Self.requireMutationConfirmation(response)
        try await verifyExtendedEdit(.setPlaylistPrivacy(id: id, privacy: privacy), scope: expectedScope)
        return .playlistPrivacyChanged(id: id, privacy: privacy)
    }

    func movePlaylistItem(playlistID: String, item: PlaylistItemReference, before: PlaylistItemReference?,
                          expectedScope: UUID) async throws -> MusicLibraryEditResult {
        let id = try editablePlaylistID(playlistID)
        try validateReferences([item] + (before.map { [$0] } ?? []))
        var action = ["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": item.setVideoID]
        if let before { action["movedSetVideoIdSuccessor"] = before.setVideoID }
        let response = try await libraryMutation(endpoint: "browse/edit_playlist", body: ["playlistId": id, "actions": [action]],
                                                 expectedScope: expectedScope)
        try Self.requireMutationConfirmation(response)
        try await verifyExtendedEdit(.movePlaylistItem(playlistID: id, item: item, before: before), scope: expectedScope)
        return .playlistItemMoved(playlistID: id, item: item, before: before)
    }

    func setAlbumSaved(browseID: String, playlistID: String, saved: Bool,
                       expectedScope: UUID) async throws -> MusicLibraryEditResult {
        try validateIdentifier(browseID)
        let target = try editablePlaylistID(playlistID)
        guard (browseID.hasPrefix("MPRE") || browseID.hasPrefix("OLAK") || browseID.hasPrefix("VLOLAK")),
              target.hasPrefix("OLAK") else { throw MusicServiceError.invalidInput }
        let response = try await libraryMutation(endpoint: saved ? "like/like" : "like/removelike",
                                                 body: ["target": ["playlistId": target]], expectedScope: expectedScope)
        try Self.requireMutationConfirmation(response)
        try await verifyExtendedEdit(.setAlbumSaved(browseID: browseID, playlistID: target, saved: saved), scope: expectedScope)
        return .albumSaved(browseID: browseID, saved: saved)
    }

    func setArtistSubscribed(browseID: String, channelID: String, subscribed: Bool,
                             expectedScope: UUID) async throws -> MusicLibraryEditResult {
        try validateIdentifier(browseID)
        try validateIdentifier(channelID)
        guard channelID.hasPrefix("UC") else { throw MusicServiceError.invalidInput }
        let response = try await libraryMutation(endpoint: subscribed ? "subscription/subscribe" : "subscription/unsubscribe",
                                                 body: ["channelIds": [channelID]], expectedScope: expectedScope)
        try Self.requireMutationConfirmation(response)
        try await verifyExtendedEdit(.setArtistSubscribed(browseID: browseID, channelID: channelID, subscribed: subscribed), scope: expectedScope)
        return .artistSubscribed(browseID: browseID, subscribed: subscribed)
    }

    /// Acknowledgement plus a fresh authoritative read is required for these
    /// separately enabled operations. Readback failure never repeats the write.
    private func verifyExtendedEdit(_ action: MusicLibraryEditAction, scope: UUID) async throws {
        do {
            try await validateScope(scope)
            let matches: Bool
            switch action {
            case let .setPlaylistDescription(id, description):
                matches = try await playlist(id: id).playlistDetails?.description == description
            case let .setPlaylistPrivacy(id, privacy):
                matches = try await playlist(id: id).playlistDetails?.privacy == privacy
            case let .movePlaylistItem(id, item, before):
                let first = try await playlist(id: id)
                let references = try await reorderReferences(startingWith: first)
                if let index = references.firstIndex(of: item) {
                    matches = before.map { index + 1 < references.count && references[index + 1] == $0 } ?? (index == references.count - 1)
                } else { matches = false }
            case let .setAlbumSaved(browseID, target, saved):
                let state = try await album(id: browseID).albumLibraryState
                matches = state?.playlistID == target && state?.rating == (saved ? .liked : .neutral)
            case let .setArtistSubscribed(browseID, channelID, subscribed):
                let state = try await artist(id: browseID).artistSubscription
                matches = state?.channelID == channelID && state?.isSubscribed == subscribed
            default: matches = false
            }
            try await validateScope(scope)
            guard matches else { throw MusicLibraryEditError.unconfirmedOutcome }
        } catch is CancellationError { throw CancellationError() }
        catch MusicServiceError.sessionChanged { throw MusicServiceError.sessionChanged }
        catch { throw MusicLibraryEditError.unconfirmedOutcome }
    }

    private func validateExtendedEdit(_ action: MusicLibraryEditAction, scope: UUID) async throws {
        let permitted: Bool
        switch action {
        case let .setPlaylistDescription(id, description):
            guard description.count <= 5_000 else { throw MusicServiceError.invalidInput }
            let page = try await playlist(id: id)
            permitted = page.playlistCapabilities.canEditDescription && page.playlistDetails?.description != nil
        case let .setPlaylistPrivacy(id, _):
            let page = try await playlist(id: id)
            permitted = page.playlistCapabilities.canEditPrivacy && page.playlistDetails?.privacy != nil
        case let .movePlaylistItem(id, item, before):
            try validateReferences([item] + (before.map { [$0] } ?? []))
            let first = try await playlist(id: id)
            guard first.playlistCapabilities.canReorder else { throw MusicLibraryEditError.collectionStateUnavailable }
            let references = try await reorderReferences(startingWith: first)
            permitted = references.contains(item) &&
                (before.map { references.contains($0) } ?? true)
        case let .setAlbumSaved(browseID, target, saved):
            let state = try await album(id: browseID).albumLibraryState
            permitted = state?.playlistID == (target.hasPrefix("VL") ? String(target.dropFirst(2)) : target) &&
                state?.isSaved != nil && state?.isSaved != saved
        case let .setArtistSubscribed(browseID, channelID, subscribed):
            let state = try await artist(id: browseID).artistSubscription
            permitted = state?.channelID == channelID && state?.isSubscribed != nil && state?.isSubscribed != subscribed
        default: return
        }
        try Task.checkCancellation()
        try await validateScope(scope)
        guard permitted else { throw MusicLibraryEditError.collectionStateUnavailable }
    }

    private func reorderReferences(startingWith first: MusicPage) async throws -> [PlaylistItemReference] {
        var page = first
        var pageCount = 0
        var references: [PlaylistItemReference] = []
        var seen = Set<String>()
        while true {
            try Task.checkCancellation()
            pageCount += 1
            let current = page.playlistItems.compactMap(\.removalReference)
            guard current.count == page.tracks.count else { throw MusicLibraryEditError.invalidPlaylistItems }
            guard references.count + current.count <= 10_000 else { throw MusicServiceError.pageLimitReached }
            for reference in current {
                guard seen.insert(reference.setVideoID).inserted else { throw MusicLibraryEditError.invalidPlaylistItems }
            }
            references.append(contentsOf: current)
            guard let next = page.continuation else { return references }
            guard pageCount < 100 else { throw MusicServiceError.pageLimitReached }
            page = try await nextPage(next)
        }
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
    private func libraryMutation(endpoint: String, body: [String: Any], expectedScope: UUID? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        let session = await sessions.snapshot()
        guard expectedScope == nil || session.scope == expectedScope else { throw MusicServiceError.sessionChanged }
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
