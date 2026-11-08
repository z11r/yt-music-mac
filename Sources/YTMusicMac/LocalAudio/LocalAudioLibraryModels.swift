import Foundation
import MusicCore

enum LocalAudioLibraryCopy {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "LocalAudioLibrary", bundle: AppIdentity.resourceBundle, value: key, comment: "")
    }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.autoupdatingCurrent, arguments: arguments)
    }
}

struct LocalAudioLibraryOwner: Equatable, Sendable {
    let profileStorageID: UUID
    let activationID: UUID
    let accountGeneration: UUID
}

struct LocalAudioLibraryUIScope: Equatable, Sendable {
    let owner: LocalAudioLibraryOwner
    let presentation: UUID
}

enum LocalAudioLibraryIssue: Error, Equatable, Sendable, CaseIterable {
    case stale, busy, fileLimit, invalidFile, unavailableFile, unsupportedAudio, changedFile, differentFile, duplicate
    case libraryUnavailable, conflict, unconfirmed, inUse, queueChanged, rejected, capacity
    var message: String {
        switch self {
        case .stale: LocalAudioLibraryCopy.text("This window or local profile changed. Open the local library again.")
        case .busy: LocalAudioLibraryCopy.text("The previous file operation is finishing. Try again when it stops.")
        case .fileLimit: LocalAudioLibraryCopy.text("Choose 1–100 audio files for one review.")
        case .invalidFile: LocalAudioLibraryCopy.text("Choose a regular local audio file, without aliases or symbolic links.")
        case .unavailableFile: LocalAudioLibraryCopy.text("This file is unavailable or unreadable. Locate it or grant access again.")
        case .unsupportedAudio: LocalAudioLibraryCopy.text("This file could not be verified as supported unprotected audio.")
        case .changedFile: LocalAudioLibraryCopy.text("The selected file changed since review. Review it again before saving.")
        case .differentFile: LocalAudioLibraryCopy.text("This is a different file. Import it as a new library record.")
        case .duplicate: LocalAudioLibraryCopy.text("This file is already included in this local library or review.")
        case .libraryUnavailable: LocalAudioLibraryCopy.text("The local library could not be read safely. Its existing data was kept.")
        case .conflict: LocalAudioLibraryCopy.text("The local library changed elsewhere. Reload it and review the selection again.")
        case .unconfirmed: LocalAudioLibraryCopy.text("Saving was not confirmed. Reload the local library before another submission.")
        case .inUse: LocalAudioLibraryCopy.text("This file is still in use. Stop playback before changing its library record.")
        case .queueChanged: LocalAudioLibraryCopy.text("The playback or queue target changed. Select the local files again.")
        case .rejected: LocalAudioLibraryCopy.text("The request was not accepted. The local library was kept.")
        case .capacity: LocalAudioLibraryCopy.text("The local library can contain at most 2,000 files.")
        }
    }
    static func mapped(_ error: any Error) -> Self {
        if let issue = error as? Self { return issue }
        if error is CancellationError { return .stale }
        if let value = error as? LocalAudioPlaybackIssue {
            switch value {
            case .busy: return .busy
            case .stale, .cancelled: return .stale
            case .permission, .unavailable: return .unavailableFile
            default: return .unsupportedAudio
            }
        }
        if let value = error as? LocalAudioLibraryError {
            switch value {
            case .busy: return .busy
            case .staleRevision: return .conflict
            case .capacityReached, .fileTooLarge: return .capacity
            default: return .libraryUnavailable
            }
        }
        if let value = error as? LocalAudioAccessError {
            switch value {
            case .busy: return .busy
            case .identityChanged: return .changedFile
            case .unavailableFile, .accessDenied, .staleBookmark: return .unavailableFile
            case .unsupportedAsset: return .unsupportedAudio
            default: return .invalidFile
            }
        }
        return .unsupportedAudio
    }
}

struct LocalAudioReviewedFile: Equatable, Sendable {
    let identity: LocalAudioFileIdentity
    let metadata: LocalAudioMetadata
}

struct LocalAudioImportRow: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable { case checking, ready(LocalAudioReviewedFile), issue(LocalAudioLibraryIssue) }
    let id: UUID
    let filename: String
    var status: Status
    var reviewed: LocalAudioReviewedFile? { if case let .ready(value) = status { value } else { nil } }
}

enum LocalAudioImportPurpose: Equatable, Sendable {
    case importFiles
    case reauthorize(LocalAudioReference, LocalAudioFileIdentity)
}

struct LocalAudioImportReview: Identifiable, Sendable {
    let id: UUID
    let scope: LocalAudioLibraryUIScope
    let purpose: LocalAudioImportPurpose
    let expectedRevision: UUID?
    let libraryID: UUID
    var rows: [LocalAudioImportRow]
}

protocol LocalAudioLibraryStoring: Sendable {
    func load() async throws -> LocalAudioLibraryDocument?
    func save(_ document: LocalAudioLibraryDocument, replacing revision: UUID?, if permitted: @Sendable () -> Bool) async throws
}
extension LocalAudioLibraryStore: LocalAudioLibraryStoring {}

@MainActor protocol LocalAudioLibraryFilePicking: AnyObject {
    func chooseFiles(multiple: Bool) async -> [URL]?
    func cancel()
}

/// Only the facade interprets a captured queue/intent target. The UI never prepares an engine.
@MainActor struct LocalAudioLibraryQueueActions<Target: Equatable & Sendable> {
    let capture: @MainActor (LocalAudioLibraryOwner) -> Target?
    let isCurrent: @MainActor (Target, LocalAudioLibraryOwner) -> Bool
    let add: @MainActor ([Track], Target) async -> Bool
    let play: @MainActor ([Track], Target) async -> Bool
}

final class LocalAudioLibraryWritePermission: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    var permits: Bool { lock.withLock { allowed } }
    func revoke() { lock.withLock { allowed = false } }
}
