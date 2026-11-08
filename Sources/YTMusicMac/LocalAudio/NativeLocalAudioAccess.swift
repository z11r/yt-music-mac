import Darwin
import Foundation
import MusicCore

/// Construction is inert. Production callers choose a mode explicitly; this adapter never opens a chooser.
struct NativeLocalAudioBookmarkAccess: LocalAudioBookmarkAccessing {
    let mode: LocalAudioBookmarkMode
    var resolutionOptions: URL.BookmarkResolutionOptions {
        var options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing]
        if mode == .securityScopedReadOnly { options.insert(.withSecurityScope) }
        return options
    }

    func create(for url: URL, mode: LocalAudioBookmarkMode) throws -> LocalAudioBookmark {
        try LocalAudioFilePolicy.validateURL(url)
        guard mode == self.mode else { throw LocalAudioAccessError.unsupportedAccessMode }
        let options: URL.BookmarkCreationOptions = mode == .ordinary ? [.withoutImplicitSecurityScope] :
            [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        let bookmark = LocalAudioBookmark(mode: mode, data: try url.bookmarkData(options: options,
            includingResourceValuesForKeys: nil, relativeTo: nil))
        try bookmark.validate()
        return bookmark
    }
    func resolve(_ bookmark: LocalAudioBookmark) throws -> LocalAudioResolvedBookmark {
        try bookmark.validate()
        guard bookmark.mode == mode else { throw LocalAudioAccessError.unsupportedAccessMode }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark.data, options: resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
        return LocalAudioResolvedBookmark(url: url, isStale: stale)
    }
    func beginAccess(to url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func endAccess(to url: URL) { url.stopAccessingSecurityScopedResource() }
}

struct NativeLocalAudioFileInspector: LocalAudioFileInspecting {
    func inspect(_ url: URL) throws -> LocalAudioFileFacts {
        try LocalAudioFilePolicy.validateURL(url)
        try Task.checkCancellation()
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &info)
        }
        guard result == 0 else { throw LocalAudioAccessError.unavailableFile }
        let kind = info.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) else { throw LocalAudioAccessError.unsafeFile }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey,
            .isPackageKey, .volumeIsLocalKey, .volumeUUIDStringKey, .isReadableKey])
        guard values.volumeIsLocal == true,
              url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
            throw LocalAudioAccessError.unsafeFile
        }
        guard let volumeID = values.volumeUUIDString else { throw LocalAudioAccessError.unsafeFile }
        let readable: Bool = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return Darwin.access(path, R_OK) == 0
        }
        try Task.checkCancellation()
        return LocalAudioFileFacts(identity: LocalAudioFileIdentity(volumeID: volumeID, fileID: UInt64(info.st_ino)),
            byteCount: info.st_size, isRegularFile: values.isRegularFile == true && values.isPackage != true,
            isSymbolicLink: values.isSymbolicLink != false, isAliasFile: values.isAliasFile != false,
            isLocalVolume: values.volumeIsLocal == true, isLocallyAvailable: info.st_flags & UInt32(SF_DATALESS) == 0,
            isReadable: readable && values.isReadable == true)
    }
}
