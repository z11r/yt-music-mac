import Foundation
import MusicCore

public struct QueuePlaylistReadback: Equatable, Sendable {
    public let targetID: String
    public let title: String
    public let isPrivate: Bool
    public let canAddItems: Bool
    public let occurrences: [QueuePlaylistOccurrence]
    public init(targetID: String, title: String, isPrivate: Bool, canAddItems: Bool, occurrences: [QueuePlaylistOccurrence]) {
        self.targetID = targetID; self.title = title; self.isPrivate = isPrivate; self.canAddItems = canAddItems; self.occurrences = occurrences
    }
}

struct QueuePlaylistWriteLease: Sendable { let token: UUID; let scope: UUID }

extension YouTubeMusicClient {
    /// Reserves the ordinary mutation lock across review-committed create, batches and readback.
    public func beginQueuePlaylistSave(expectedScope: UUID) async throws -> UUID {
        guard libraryEditCapabilities.playlists else { throw MusicLibraryEditError.featureUnavailable }
        guard !libraryEditInProgress else { throw MusicLibraryEditError.operationInProgress }
        let token = UUID()
        libraryEditInProgress = true
        queuePlaylistWriteLease = QueuePlaylistWriteLease(token: token, scope: expectedScope)
        do { try await validateScope(expectedScope); return token }
        catch { endQueuePlaylistSave(token: token); throw error }
    }
    public func endQueuePlaylistSave(token: UUID) {
        guard queuePlaylistWriteLease?.token == token else { return }
        queuePlaylistWriteLease = nil; libraryEditInProgress = false
    }
    public func createQueuePlaylist(title: String, token: UUID, expectedScope: UUID) async throws -> String {
        try await requireQueuePlaylistLease(token, scope: expectedScope)
        let result = try await createPlaylist(title: title, privacy: .private, videoIDs: [], expectedScope: expectedScope)
        guard case let .playlistCreated(raw) = result else { throw MusicLibraryEditError.unconfirmedOutcome }
        let id = raw.hasPrefix("VL") ? String(raw.dropFirst(2)) : raw
        guard QueuePlaylistPlan.validPlaylistID(id) else { throw MusicLibraryEditError.unconfirmedOutcome }
        return id
    }
    public func appendQueuePlaylist(id: String, videoIDs: [String], token: UUID, expectedScope: UUID) async throws -> [QueuePlaylistOccurrence] {
        try await requireQueuePlaylistLease(token, scope: expectedScope)
        guard QueuePlaylistPlan.validPlaylistID(id), (1...100).contains(videoIDs.count), videoIDs.allSatisfy(QueuePlaylistPlan.validVideoID) else {
            throw MusicLibraryEditError.invalidPlaylistItems
        }
        let result = try await addPlaylistItems(playlistID: id, videoIDs: videoIDs, allowDuplicates: true, expectedScope: expectedScope)
        guard case let .itemsAdded(target, items) = result, target == id else { throw MusicLibraryEditError.unconfirmedOutcome }
        return items.map { QueuePlaylistOccurrence(videoID: $0.videoID, setVideoID: $0.setVideoID) }
    }
    public func readQueuePlaylist(id: String, token: UUID, expectedScope: UUID) async throws -> QueuePlaylistReadback {
        try await requireQueuePlaylistLease(token, scope: expectedScope)
        guard QueuePlaylistPlan.validPlaylistID(id) else { throw MusicLibraryEditError.invalidPlaylistItems }
        let session = await sessions.snapshot()
        guard session.scope == expectedScope else { throw MusicServiceError.sessionChanged }
        let data = try await request(endpoint: .browse, body: ["browseId": "VL" + id], session: session, requiresAuthentication: true)
        let parsed = try MusicResponseParser.parse(data, preservesOccurrences: true)
        guard let title = parsed.title, !title.isEmpty else { throw MusicLibraryEditError.unconfirmedOutcome }
        var page = makePage(parsed, title: title, endpoint: .browse, session: session, requiresAuthentication: true, preservesOccurrences: true)
        let privacy = page.playlistDetails?.privacy == .private
        let canAdd = page.playlistCapabilities.canAddItems
        var references: [QueuePlaylistOccurrence] = []
        var identifiers = Set<String>()
        var pages = 0
        while true {
            try await requireQueuePlaylistLease(token, scope: expectedScope)
            pages += 1
            guard page.unavailableItemCount == 0, !page.hasUnsupportedContent, page.items.count == page.tracks.count,
                  page.playlistItems.count == page.tracks.count else { throw MusicLibraryEditError.invalidPlaylistItems }
            let current = page.playlistItems.compactMap(\.removalReference).map { QueuePlaylistOccurrence(videoID: $0.videoID, setVideoID: $0.setVideoID) }
            guard current.count == page.tracks.count, references.count + current.count <= 10_000,
                  current.allSatisfy(QueuePlaylistPlan.validOccurrence) else { throw MusicLibraryEditError.invalidPlaylistItems }
            for item in current {
                guard identifiers.insert(item.setVideoID).inserted else { throw MusicLibraryEditError.invalidPlaylistItems }
            }
            references.append(contentsOf: current)
            guard let continuation = page.continuation else { break }
            guard pages < 200 else { throw MusicServiceError.pageLimitReached }
            page = try await nextPage(continuation)
        }
        try await requireQueuePlaylistLease(token, scope: expectedScope)
        return QueuePlaylistReadback(targetID: id, title: title, isPrivate: privacy, canAddItems: canAdd, occurrences: references)
    }
    private func requireQueuePlaylistLease(_ token: UUID, scope: UUID) async throws {
        guard libraryEditCapabilities.playlists else { throw MusicLibraryEditError.featureUnavailable }
        guard libraryEditInProgress, queuePlaylistWriteLease?.token == token, queuePlaylistWriteLease?.scope == scope else {
            throw MusicLibraryEditError.operationInProgress
        }
        try Task.checkCancellation()
        try await validateScope(scope)
    }
}
