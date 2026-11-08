import AVFoundation
import Foundation
import MusicCore

struct LocalAudioImportProbeContext: Sendable {
    let reference: LocalAudioReference
    let lifetime: LocalAudioProfileLifetime
    let use: LocalAudioReferenceUse
}

@MainActor protocol LocalAudioImportProbing: AnyObject {
    func review(_ url: URL, context: LocalAudioImportProbeContext) async throws -> LocalAudioReviewedFile
    func confirmedBookmark(_ url: URL, expected: LocalAudioReviewedFile, context: LocalAudioImportProbeContext) async throws -> LocalAudioBookmark
}

/// The controller holds the shared preparation admission across this entire
/// probe, including metadata. The nested native preparer uses a private slot.
/// Construction and tests never open a selected file or instantiate an asset.
@MainActor final class NativeLocalAudioImportProbe: LocalAudioImportProbing {
    private let bookmarks: any LocalAudioBookmarkAccessing
    private let files: any LocalAudioFileInspecting
    private let reads: LocalAudioReadAdmission
    private let preparer: NativeLocalAudioAssetPreparer
    private let mode: LocalAudioBookmarkMode

    init(mode: LocalAudioBookmarkMode, bookmarks: any LocalAudioBookmarkAccessing,
         files: any LocalAudioFileInspecting = NativeLocalAudioFileInspector(), reads: LocalAudioReadAdmission = .shared) {
        self.mode = mode; self.bookmarks = bookmarks; self.files = files; self.reads = reads
        preparer = NativeLocalAudioAssetPreparer(admission: LocalAudioPreparationAdmission(), files: files, reads: reads)
    }

    func review(_ url: URL, context: LocalAudioImportProbeContext) async throws -> LocalAudioReviewedFile {
        try check(url, context)
        let bookmarks = bookmarks, files = files, mode = mode
        let acquired = try await reads.perform {
            try await context.lifetime.checkCurrent()
            let access = bookmarks.beginAccess(to: url)
            guard mode != .securityScopedReadOnly || access else { throw LocalAudioAccessError.accessDenied }
            do {
                let facts = try files.inspect(url)
                try LocalAudioFilePolicy.validate(facts)
                let lease = LocalAudioResourceLease(reference: context.reference, fileURL: url, identity: facts.identity,
                    profileLifetime: context.lifetime, referenceUse: context.use) { if access { bookmarks.endAccess(to: url) } }
                return (facts, lease)
            } catch { if access { bookmarks.endAccess(to: url) }; throw error }
        }
        let (facts, lease) = acquired
        defer { lease.release(); withExtendedLifetime(context) {} }
        try check(url, context)
        let source = try await preparer.prepare(lease)
        defer { source.release() }
        try check(url, context)
        guard let prepared = source as? PreparedLocalAudioAsset else { throw LocalAudioLibraryIssue.unsupportedAudio }
        let items = try await prepared.asset.load(.commonMetadata)
        try check(url, context)
        guard items.count <= 64 else { throw LocalAudioLibraryIssue.unsupportedAudio }
        func text(_ id: AVMetadataIdentifier) async throws -> String? {
            let matches = items.filter { $0.identifier == id }
            guard matches.count <= 1 else { return nil }
            guard let item = matches.first else { return nil }
            let value = try await item.load(.stringValue)
            try check(url, context)
            guard let value, value.utf8.count <= 1_024,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            return value.isEmpty ? nil : value
        }
        let title = try await text(.commonIdentifierTitle) ?? url.deletingPathExtension().lastPathComponent
        let artist = try await text(.commonIdentifierArtist) ?? ""
        let album = try await text(.commonIdentifierAlbumName)
        let current = try await reads.perform {
            try await context.lifetime.checkCurrent()
            return try files.inspect(url)
        }
        try check(url, context); try LocalAudioFilePolicy.validate(current)
        guard current.identity == facts.identity, current.byteCount == facts.byteCount else { throw LocalAudioLibraryIssue.changedFile }
        let metadata = LocalAudioMetadata(title: title, artist: artist, album: album, duration: source.duration, byteCount: facts.byteCount)
        try metadata.validate()
        return .init(identity: facts.identity, metadata: metadata)
    }

    func confirmedBookmark(_ url: URL, expected: LocalAudioReviewedFile, context: LocalAudioImportProbeContext) async throws -> LocalAudioBookmark {
        try check(url, context)
        let bookmarks = bookmarks, files = files, mode = mode
        let value = try await reads.perform {
            defer { withExtendedLifetime(context) {} }
            try await context.lifetime.checkCurrent()
            let access = bookmarks.beginAccess(to: url)
            guard mode != .securityScopedReadOnly || access else { throw LocalAudioAccessError.accessDenied }
            defer { if access { bookmarks.endAccess(to: url) } }
            let facts = try files.inspect(url)
            try LocalAudioFilePolicy.validate(facts)
            guard facts.identity == expected.identity, facts.byteCount == expected.metadata.byteCount else { throw LocalAudioLibraryIssue.changedFile }
            try await context.lifetime.checkCurrent()
            let bookmark = try bookmarks.create(for: url, mode: mode)
            try Task.checkCancellation(); try bookmark.validate()
            let resolved = try bookmarks.resolve(bookmark)
            guard !resolved.isStale else { throw LocalAudioAccessError.staleBookmark }
            try LocalAudioFilePolicy.validateURL(resolved.url)
            guard resolved.url.absoluteString.utf8.count <= 8_192 else { throw LocalAudioLibraryIssue.invalidFile }
            let resolvedAccess = bookmarks.beginAccess(to: resolved.url)
            guard mode != .securityScopedReadOnly || resolvedAccess else { throw LocalAudioAccessError.accessDenied }
            defer { if resolvedAccess { bookmarks.endAccess(to: resolved.url) } }
            let actual = try files.inspect(resolved.url)
            try LocalAudioFilePolicy.validate(actual)
            guard actual.identity == expected.identity, actual.byteCount == expected.metadata.byteCount else {
                throw LocalAudioLibraryIssue.changedFile
            }
            try Task.checkCancellation()
            return bookmark
        }
        try check(url, context)
        return value
    }

    private func check(_ url: URL, _ context: LocalAudioImportProbeContext) throws {
        try context.lifetime.authorization.check()
        guard context.use.reference == context.reference,
              context.use.registry.profileStorageID == context.lifetime.profileStorageID else { throw LocalAudioLibraryIssue.stale }
        try LocalAudioFilePolicy.validateURL(url)
        guard url.absoluteString.utf8.count <= 8_192 else { throw LocalAudioLibraryIssue.invalidFile }
    }
}
