import Foundation

/// Fixed statuses and counts from an explicitly requested disposable-playlist
/// check. Song, playlist, account, title, and occurrence identifiers stay private.
public struct MusicPlaylistEditCheck: Codable, Equatable, Sendable {
    public enum Step: String, Codable, Sendable, CaseIterable {
        case create, rename, addDuplicates, readAdded, removeOccurrence, readRemoved, delete
    }
    public enum Status: String, Codable, Sendable {
        case confirmed, unconfirmed, rejected, accessDenied, authenticationRejected
        case accountChanged, cancelled, timedOut, unexpectedResponse, permissionUnavailable, rateLimited
    }
    public enum Cleanup: String, Codable, Sendable {
        case notNeeded, deleted, unconfirmed, accountChanged, timedOut, unavailable
    }
    public struct StepResult: Codable, Equatable, Sendable {
        public let step: Step
        public let status: Status
        public let occurrenceCount: Int?
    }

    public let schemaVersion: Int
    public let status: Status
    public let steps: [StepResult]
    public let cleanup: Cleanup
    public let passed: Bool
    public let cleanupNeeded: Bool
    public let uncertainOutcome: Bool

    init(status: Status, steps: [StepResult], cleanup: Cleanup) {
        schemaVersion = 1
        self.status = status
        self.steps = steps
        self.cleanup = cleanup
        cleanupNeeded = cleanup != .notNeeded && cleanup != .deleted
        uncertainOutcome = cleanupNeeded || [.unconfirmed, .cancelled, .timedOut].contains(status)
        passed = status == .confirmed && steps.map(\.step) == Step.allCases &&
            steps.allSatisfy { $0.status == .confirmed } && cleanup == .deleted
    }
}

private enum PlaylistEditCheckError: Error {
    case unexpectedResponse, permissionUnavailable, timedOut
}

struct PendingPlaylistEditCleanup: Sendable {
    let playlistID: String?
    let scope: UUID
}

private actor PlaylistEditProbe {
    private(set) var playlistID: String?
    private(set) var deleteAttempted = false
    private(set) var deleted = false
    private var steps: [MusicPlaylistEditCheck.StepResult] = []

    func begin(_ step: MusicPlaylistEditCheck.Step) {
        steps.append(.init(step: step, status: .unconfirmed, occurrenceCount: nil))
        if step == .delete { deleteAttempted = true }
    }

    func created(_ id: String) { playlistID = id }
    func didDelete() { deleted = true }

    func finish(_ status: MusicPlaylistEditCheck.Status = .confirmed, count: Int? = nil) {
        guard let last = steps.last else { return }
        steps[steps.count - 1] = .init(step: last.step, status: status, occurrenceCount: count ?? last.occurrenceCount)
    }

    func fail(_ status: MusicPlaylistEditCheck.Status) {
        if steps.last?.status == .unconfirmed { finish(status) }
    }

    func couldHaveCreatedAnUnknownPlaylist() -> Bool {
        guard playlistID == nil, let first = steps.first else { return false }
        return first.step == .create && [.unconfirmed, .cancelled, .timedOut, .accountChanged].contains(first.status)
    }

    func report(status: MusicPlaylistEditCheck.Status, cleanup: MusicPlaylistEditCheck.Cleanup) -> MusicPlaylistEditCheck {
        MusicPlaylistEditCheck(status: status, steps: steps, cleanup: cleanup)
    }
}

extension YouTubeMusicClient {
    /// Explicit mutation diagnostic. Never call from launch, background work, or CI.
    /// The normal playlist-edit capability must be enabled for the verification client.
    /// A 15-second workload and at most five seconds of cleanup bound the operation.
    public func checkPlaylistEdits(videoID: String, expectedScope: UUID? = nil,
                                   timeout: Duration = .seconds(15)) async throws -> MusicPlaylistEditCheck {
        guard libraryEditCapabilities.playlists else { throw MusicLibraryEditError.featureUnavailable }
        guard timeout > .zero, timeout <= .seconds(15), videoID.utf8.count == 11 else {
            throw MusicServiceError.invalidInput
        }
        try validateIdentifier(videoID)
        guard pendingPlaylistEditCleanup == nil else { throw MusicLibraryEditError.verificationCleanupRequired }
        guard !libraryEditInProgress else { throw MusicLibraryEditError.operationInProgress }
        libraryEditInProgress = true
        defer { libraryEditInProgress = false }
        let scope = try await libraryEditScope()
        guard expectedScope == nil || expectedScope == scope else { throw MusicServiceError.sessionChanged }
        let probe = PlaylistEditProbe()
        let status: MusicPlaylistEditCheck.Status
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.performPlaylistEditCheck(videoID: videoID, scope: scope, probe: probe) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw PlaylistEditCheckError.timedOut
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            status = .confirmed
        } catch {
            status = Self.playlistEditCheckStatus(error)
            await probe.fail(status)
        }
        // Use a fresh task so a cancelled caller does not prevent cleanup. Only
        // the confirmed new playlist and original account scope can be used.
        let cleanup = Task { await self.cleanupPlaylistEditCheck(scope: scope, probe: probe) }
        let cleanupStatus = await cleanup.value
        if cleanupStatus == .deleted { pendingPlaylistEditCleanup = nil }
        else if cleanupStatus == .unavailable, pendingPlaylistEditCleanup == nil {
            pendingPlaylistEditCleanup = PendingPlaylistEditCleanup(playlistID: nil, scope: scope)
        }
        return await probe.report(status: status, cleanup: cleanupStatus)
    }

    /// Counts-only availability for an explicitly requested recovery action.
    /// The verification client must be retained until its cleanup is confirmed.
    public func hasPendingPlaylistEditCleanup() -> Bool { pendingPlaylistEditCleanup != nil }

    /// Explicit recovery, never an automatic replay. Re-read the known created
    /// playlist and its delete permission before one more bounded delete attempt.
    public func retryPlaylistEditCleanup(expectedScope: UUID) async throws -> MusicPlaylistEditCheck.Cleanup {
        guard libraryEditCapabilities.playlists else { throw MusicLibraryEditError.featureUnavailable }
        guard !libraryEditInProgress else { throw MusicLibraryEditError.operationInProgress }
        guard let target = pendingPlaylistEditCleanup else { return .notNeeded }
        guard target.scope == expectedScope else { throw MusicServiceError.sessionChanged }
        guard target.playlistID != nil else { return .unavailable }
        libraryEditInProgress = true
        defer { libraryEditInProgress = false }
        let result = await attemptPlaylistEditCleanup(target, verifyPermission: true)
        if result == .deleted { pendingPlaylistEditCleanup = nil }
        return result
    }

    private func performPlaylistEditCheck(videoID: String, scope: UUID, probe: PlaylistEditProbe) async throws {
        let suffix = String(UUID().uuidString.prefix(8))
        let title = "Playback verification \(suffix)"
        let renamedTitle = "Playback verification renamed \(suffix)"

        await probe.begin(.create)
        try await validateScope(scope)
        let creation = try await createPlaylist(title: title, privacy: .private, expectedScope: scope)
        guard case let .playlistCreated(id) = creation else { throw MusicLibraryEditError.unconfirmedOutcome }
        pendingPlaylistEditCleanup = PendingPlaylistEditCleanup(playlistID: id, scope: scope)
        await probe.created(id)
        await probe.finish()

        await probe.begin(.rename)
        _ = try await renamePlaylist(id: id, title: renamedTitle, expectedScope: scope)
        await probe.finish()

        await probe.begin(.addDuplicates)
        let addition = try await addPlaylistItems(playlistID: id, videoIDs: [videoID, videoID],
                                                 allowDuplicates: true, expectedScope: scope)
        guard case let .itemsAdded(_, references) = addition else { throw MusicLibraryEditError.unconfirmedOutcome }
        await probe.finish(count: references.count)

        await probe.begin(.readAdded)
        try await validateScope(scope)
        let added = try await playlist(id: id)
        try await validateScope(scope)
        await probe.finish(.unconfirmed, count: added.playlistItems.count)
        guard added.title == renamedTitle, added.continuation == nil, added.tracks.count == 2,
              added.playlistItems.map(\.track.id) == [videoID, videoID],
              Set(added.playlistItems.compactMap(\.removalReference)) == Set(references) else {
            throw PlaylistEditCheckError.unexpectedResponse
        }
        let capabilities = added.playlistCapabilities
        guard capabilities.canRename && capabilities.canAddItems && capabilities.canRemoveItems && capabilities.canDelete else {
            throw PlaylistEditCheckError.permissionUnavailable
        }
        await probe.finish()

        await probe.begin(.removeOccurrence)
        guard let removal = added.playlistItems.last?.removalReference,
              let remaining = added.playlistItems.first?.removalReference, remaining != removal else {
            throw PlaylistEditCheckError.unexpectedResponse
        }
        _ = try await removePlaylistItems(playlistID: id, items: [removal], expectedScope: scope)
        await probe.finish(count: 1)

        await probe.begin(.readRemoved)
        try await validateScope(scope)
        let removed = try await playlist(id: id)
        try await validateScope(scope)
        await probe.finish(.unconfirmed, count: removed.playlistItems.count)
        guard removed.continuation == nil, removed.tracks.count == 1,
              removed.playlistItems.map(\.track.id) == [videoID],
              removed.playlistItems.first?.removalReference == remaining else {
            throw PlaylistEditCheckError.unexpectedResponse
        }
        await probe.finish()

        await probe.begin(.delete)
        _ = try await deletePlaylist(id: id, expectedScope: scope)
        await probe.didDelete()
        await probe.finish()
    }

    private func cleanupPlaylistEditCheck(scope: UUID, probe: PlaylistEditProbe) async -> MusicPlaylistEditCheck.Cleanup {
        if await probe.deleted { return .deleted }
        guard let id = await probe.playlistID else {
            return await probe.couldHaveCreatedAnUnknownPlaylist() ? .unavailable : .notNeeded
        }
        if await probe.deleteAttempted { return .unconfirmed }
        return await attemptPlaylistEditCleanup(PendingPlaylistEditCleanup(playlistID: id, scope: scope), verifyPermission: false)
    }

    private func attemptPlaylistEditCleanup(_ target: PendingPlaylistEditCleanup,
                                            verifyPermission: Bool) async -> MusicPlaylistEditCheck.Cleanup {
        guard let id = target.playlistID else { return .unavailable }
        return await withTaskGroup(of: MusicPlaylistEditCheck.Cleanup.self) { group in
            group.addTask {
                do {
                    try await self.validateScope(target.scope)
                    if verifyPermission {
                        let page = try await self.playlist(id: id)
                        try await self.validateScope(target.scope)
                        guard page.playlistCapabilities.canDelete else { return .unconfirmed }
                    }
                    _ = try await self.deletePlaylist(id: id, expectedScope: target.scope)
                    return .deleted
                } catch MusicServiceError.sessionChanged { return .accountChanged }
                catch { return .unconfirmed }
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(5)); return .timedOut }
                catch { return .unconfirmed }
            }
            defer { group.cancelAll() }
            return await group.next() ?? .unconfirmed
        }
    }

    private static func playlistEditCheckStatus(_ error: any Error) -> MusicPlaylistEditCheck.Status {
        if error is CancellationError { return .cancelled }
        switch error {
        case PlaylistEditCheckError.timedOut: return .timedOut
        case PlaylistEditCheckError.permissionUnavailable: return .permissionUnavailable
        case PlaylistEditCheckError.unexpectedResponse: return .unexpectedResponse
        case MusicLibraryEditError.serviceRejected, MusicLibraryEditError.interactionRequired: return .rejected
        case MusicServiceError.sessionChanged: return .accountChanged
        case MusicServiceError.accessDenied: return .accessDenied
        case MusicServiceError.authenticationRejected: return .authenticationRejected
        case MusicServiceError.rateLimited: return .rateLimited
        case MusicServiceError.invalidResponse, MusicServiceError.unsupportedResponse: return .unexpectedResponse
        default: return .unconfirmed
        }
    }
}
