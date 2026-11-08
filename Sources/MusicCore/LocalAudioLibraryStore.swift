import Darwin
import Foundation

/// Private profile storage. Reading never resolves a bookmark or touches the referenced audio.
public actor LocalAudioLibraryStore {
    public static let maximumBytes = 16 * 1024 * 1024
    private static let commitLock = NSLock()
    public let profileID: UUID
    private let fileURL: URL
    private let maximumBytes: Int

    public init(fileURL: URL, profileID: UUID, maximumBytes: Int = LocalAudioLibraryStore.maximumBytes) {
        self.fileURL = fileURL; self.profileID = profileID
        self.maximumBytes = max(1, min(Self.maximumBytes, maximumBytes))
    }

    public func load() throws -> LocalAudioLibraryDocument? {
        try checkURL()
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LocalAudioLibraryError.invalidLibrary }
            if let bytes = attributes[.size] as? NSNumber, bytes.intValue > maximumBytes { throw LocalAudioLibraryError.fileTooLarge }
            guard let stream = InputStream(url: fileURL) else { throw LocalAudioLibraryError.invalidLibrary }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                try Task.checkCancellation()
                let capacity = min(buffer.count, maximumBytes + 1 - data.count)
                guard capacity > 0 else { throw LocalAudioLibraryError.fileTooLarge }
                let count = stream.read(&buffer, maxLength: capacity)
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
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                    (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return nil
        }
    }

    /// Compare-and-replace: no stale writer can replace a newer, unreadable, or future archive.
    public func save(_ document: LocalAudioLibraryDocument, replacing revision: UUID?,
                     if permitted: @Sendable () -> Bool = { true }) throws {
        try Self.commitLock.withLock { try saveLocked(document, replacing: revision, if: permitted) }
    }

    private func saveLocked(_ document: LocalAudioLibraryDocument, replacing revision: UUID?,
                            if permitted: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard permitted() else { throw CancellationError() }
        try checkURL(); try document.validate()
        guard document.profileID == profileID else { throw LocalAudioLibraryError.wrongProfile }
        let existing = try load()
        guard existing?.revision == revision else { throw LocalAudioLibraryError.staleRevision }
        guard existing == nil || document.revision != revision else { throw LocalAudioLibraryError.staleRevision }
        if let existing, existing.libraryID != document.libraryID { throw LocalAudioLibraryError.wrongLibrary }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw LocalAudioLibraryError.fileTooLarge }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = directory.appendingPathComponent(".local-audio-" + UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw LocalAudioLibraryError.invalidLibrary
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let handle = try FileHandle(forWritingTo: staging)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        try Task.checkCancellation()
        guard permitted() else { throw CancellationError() }
        let result = staging.withUnsafeFileSystemRepresentation { source in
            fileURL.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return Int32(-1) }
                return Darwin.rename(source, target)
            }
        }
        guard result == 0 else { throw LocalAudioLibraryError.invalidLibrary }
    }

    private func checkURL() throws {
        guard fileURL.isFileURL, fileURL.host == nil || fileURL.host == "",
              fileURL.query == nil, fileURL.fragment == nil else { throw LocalAudioLibraryError.invalidStorageURL }
    }
}
