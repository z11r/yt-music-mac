import Darwin
import Foundation

/// Private profile storage. Reading never resolves a bookmark or touches the referenced audio.
public actor LocalAudioLibraryStore {
    public static let maximumBytes = 16 * 1024 * 1024
    public let profileID: UUID
    private let fileURL: URL
    private let maximumBytes: Int

    public init(fileURL: URL, profileID: UUID, maximumBytes: Int = LocalAudioLibraryStore.maximumBytes) {
        self.fileURL = fileURL; self.profileID = profileID
        self.maximumBytes = max(1, min(Self.maximumBytes, maximumBytes))
    }

    public func load() throws -> LocalAudioLibraryDocument? {
        try checkURL()
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw LocalAudioLibraryError.invalidLibrary }
        defer { Darwin.close(descriptor) }
        return try read(descriptor)
    }

    /// Compare-and-replace: no stale writer can replace a newer, unreadable, or future archive.
    public func save(_ document: LocalAudioLibraryDocument, replacing revision: UUID?,
                     if permitted: @Sendable () -> Bool = { true }) throws {
        try Task.checkCancellation()
        guard permitted() else { throw CancellationError() }
        try checkURL(); try document.validate()
        guard document.profileID == profileID else { throw LocalAudioLibraryError.wrongProfile }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw LocalAudioLibraryError.fileTooLarge }
        let lease = try LocalAudioArchiveLease(fileURL: fileURL)
        let existing: LocalAudioLibraryDocument?
        if let descriptor = try lease.openArchive() {
            defer { Darwin.close(descriptor) }
            existing = try read(descriptor)
        } else { existing = nil }
        guard existing?.revision == revision else { throw LocalAudioLibraryError.staleRevision }
        guard existing == nil || document.revision != revision else { throw LocalAudioLibraryError.staleRevision }
        if let existing, existing.libraryID != document.libraryID { throw LocalAudioLibraryError.wrongLibrary }
        let staging = try lease.createStaging()
        defer { lease.discardStaging(staging.name) }
        let handle = FileHandle(fileDescriptor: staging.descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        try Task.checkCancellation()
        guard permitted() else { throw CancellationError() }
        try lease.commit(staging.name)
    }

    private func read(_ descriptor: Int32) throws -> LocalAudioLibraryDocument {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw LocalAudioLibraryError.invalidLibrary
        }
        guard info.st_size >= 0, info.st_size <= maximumBytes else { throw LocalAudioLibraryError.fileTooLarge }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let capacity = min(buffer.count, maximumBytes + 1 - data.count)
            guard capacity > 0 else { throw LocalAudioLibraryError.fileTooLarge }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, capacity) }
            guard count >= 0 else { throw LocalAudioLibraryError.invalidLibrary }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw LocalAudioLibraryError.fileTooLarge }
        }
        let document: LocalAudioLibraryDocument
        do { document = try JSONDecoder().decode(LocalAudioLibraryDocument.self, from: data) }
        catch let error as LocalAudioLibraryError { throw error }
        catch { throw LocalAudioLibraryError.invalidLibrary }
        guard document.profileID == profileID else { throw LocalAudioLibraryError.wrongProfile }
        return document
    }

    private func checkURL() throws {
        guard fileURL.isFileURL, fileURL.host == nil || fileURL.host == "",
              fileURL.query == nil, fileURL.fragment == nil, !fileURL.absoluteString.lowercased().contains("%00"),
              !fileURL.path.contains("\0") else { throw LocalAudioLibraryError.invalidStorageURL }
    }
}
