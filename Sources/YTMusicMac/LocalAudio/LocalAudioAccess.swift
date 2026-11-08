import Foundation
import MusicCore

enum LocalAudioAccessError: Error, Equatable, Sendable {
    case invalidURL, unsupportedAccessMode, staleBookmark, accessDenied, unavailableFile, unsafeFile
    case identityChanged, busy, unsupportedAsset
}

struct LocalAudioResolvedBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

protocol LocalAudioBookmarkAccessing: Sendable {
    func create(for url: URL, mode: LocalAudioBookmarkMode) throws -> LocalAudioBookmark
    func resolve(_ bookmark: LocalAudioBookmark) throws -> LocalAudioResolvedBookmark
    func beginAccess(to url: URL) -> Bool
    func endAccess(to url: URL)
}

struct LocalAudioFileFacts: Sendable {
    let identity: LocalAudioFileIdentity
    let byteCount: Int64
    let isRegularFile: Bool
    let isSymbolicLink: Bool
    let isAliasFile: Bool
    let isLocalVolume: Bool
    let isLocallyAvailable: Bool
    let isReadable: Bool
}

protocol LocalAudioFileInspecting: Sendable {
    func inspect(_ url: URL) throws -> LocalAudioFileFacts
}

enum LocalAudioFilePolicy {
    static func validateURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil, url.path.hasPrefix("/"),
              !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LocalAudioAccessError.invalidURL
        }
    }
    static func validate(_ facts: LocalAudioFileFacts) throws {
        guard facts.isRegularFile, !facts.isSymbolicLink, !facts.isAliasFile, facts.isLocalVolume else {
            throw LocalAudioAccessError.unsafeFile
        }
        guard facts.isLocallyAvailable, facts.isReadable, facts.byteCount > 0 else { throw LocalAudioAccessError.unavailableFile }
        try facts.identity.validate()
    }
}

/// The asset/item owner retains this lease until all native users of the file have retired.
/// Explicit release and deallocation are idempotent, including late cancellation paths.
final class LocalAudioResourceLease: @unchecked Sendable {
    let reference: LocalAudioReference
    let fileURL: URL
    let identity: LocalAudioFileIdentity
    private let lock = NSLock()
    private var endAccess: (@Sendable () -> Void)?

    init(reference: LocalAudioReference, fileURL: URL, identity: LocalAudioFileIdentity,
         endAccess: @escaping @Sendable () -> Void) {
        self.reference = reference; self.fileURL = fileURL; self.identity = identity; self.endAccess = endAccess
    }
    var isReleased: Bool { lock.withLock { endAccess == nil } }
    func release() {
        let action = lock.withLock { let action = endAccess; endAccess = nil; return action }
        action?()
    }
    deinit { release() }
}

protocol LocalAudioAccessProviding: Sendable {
    func acquire(_ reference: LocalAudioReference, expectedLibraryID: UUID) async throws -> LocalAudioResourceLease
}

/// Process-wide native read admission; separate profile controllers share the same slot.
actor LocalAudioReadAdmission {
    static let shared = LocalAudioReadAdmission()
    private(set) var isBusy = false

    func perform<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !isBusy else { throw LocalAudioAccessError.busy }
        isBusy = true
        let worker = Task.detached(priority: .utility) { try await operation() }
        defer { isBusy = false }
        // The caller validates cancellation and disposes of any returned resource lease.
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

/// Admission stays occupied until the underlying bookmark/inspection work settles, even after cancellation.
actor LocalAudioAccessController: LocalAudioAccessProviding {
    private let load: @Sendable () async throws -> LocalAudioLibraryDocument?
    private let bookmarks: any LocalAudioBookmarkAccessing
    private let files: any LocalAudioFileInspecting
    private let admission: LocalAudioReadAdmission

    init(store: LocalAudioLibraryStore, bookmarks: any LocalAudioBookmarkAccessing, files: any LocalAudioFileInspecting,
         admission: LocalAudioReadAdmission = .shared) {
        self.load = { try await store.load() }; self.bookmarks = bookmarks; self.files = files; self.admission = admission
    }
    init(load: @escaping @Sendable () async throws -> LocalAudioLibraryDocument?,
         bookmarks: any LocalAudioBookmarkAccessing, files: any LocalAudioFileInspecting,
         admission: LocalAudioReadAdmission = .shared) {
        self.load = load; self.bookmarks = bookmarks; self.files = files; self.admission = admission
    }

    func acquire(_ reference: LocalAudioReference, expectedLibraryID: UUID) async throws -> LocalAudioResourceLease {
        try Task.checkCancellation()
        guard reference.libraryID == expectedLibraryID else { throw LocalAudioLibraryError.wrongLibrary }
        let lease = try await admission.perform { [load, bookmarks, files] in
            guard let library = try await load() else { throw LocalAudioLibraryError.missingFile }
            try Task.checkCancellation()
            try library.validate()
            guard library.libraryID == expectedLibraryID else { throw LocalAudioLibraryError.wrongLibrary }
            let record = try library.record(for: reference)
            let resolved = try bookmarks.resolve(record.bookmark)
            guard !resolved.isStale else { throw LocalAudioAccessError.staleBookmark }
            try LocalAudioFilePolicy.validateURL(resolved.url)
            try Task.checkCancellation()
            let access = bookmarks.beginAccess(to: resolved.url)
            guard record.bookmark.mode != .securityScopedReadOnly || access else { throw LocalAudioAccessError.accessDenied }
            let lease = LocalAudioResourceLease(reference: reference, fileURL: resolved.url, identity: record.identity) {
                if access { bookmarks.endAccess(to: resolved.url) }
            }
            do {
                let facts = try files.inspect(resolved.url)
                try LocalAudioFilePolicy.validate(facts)
                guard facts.identity == record.identity else { throw LocalAudioAccessError.identityChanged }
                try Task.checkCancellation()
                return lease
            } catch { lease.release(); throw error }
        }
        guard !Task.isCancelled else { lease.release(); throw CancellationError() }
        return lease
    }
}
