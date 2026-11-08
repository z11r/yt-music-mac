import CryptoKit
import Darwin
import Foundation

enum StreamingExportError: Error, LocalizedError, Sendable {
    case revoked, invalidTarget, changedTarget, unsupportedSettings, tooLarge
    var errorDescription: String? {
        switch self {
        case .revoked: StreamingExportText.text("This export request is no longer current.")
        case .invalidTarget: StreamingExportText.text("Choose a new JSON or TXT file on a local disk. Existing files, links, and shared targets are not replaced.")
        case .changedTarget: StreamingExportText.text("The export target changed or is no longer owned by this configuration. It has been kept. Choose a new file.")
        case .unsupportedSettings: StreamingExportText.text("The saved export configuration is unsupported or damaged. It has been kept. Forget it explicitly before choosing a new file.")
        case .tooLarge: StreamingExportText.text("The export data exceeds its size limit.")
        }
    }
}

struct StreamingFileIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
}

/// Private configuration only; this receipt is never included in either output format.
struct StreamingExportReceipt: Codable, Equatable, Sendable {
    let id: UUID
    let path: String
    let format: StreamingMetadataFormat
    let parent: StreamingFileIdentity
    let file: StreamingFileIdentity
    var digest: String
    var revision: UInt64
    func validate() throws {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096, !path.utf8.contains(0),
              path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              URL(fileURLWithPath: path).pathExtension.lowercased() == (format == .json ? "json" : "txt"),
              digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw StreamingExportError.unsupportedSettings }
    }
}

protocol StreamingMetadataWriting: Sendable {
    func create(url: URL, format: StreamingMetadataFormat, now: Date, gate: PlaybackOutputGate, revision: UInt64) async throws -> StreamingExportReceipt
    func write(_ document: StreamingMetadataDocument, receipt: StreamingExportReceipt, gate: PlaybackOutputGate,
               permit: PlaybackOutputGate.Permit) async throws -> StreamingExportReceipt
    func clear(receipt: StreamingExportReceipt, now: Date, gate: PlaybackOutputGate, through revision: UInt64) async throws -> StreamingExportReceipt
}

/// Uses exclusive new-file creation and pinned descriptors. It never replaces a pathname.
actor StreamingExportFile: StreamingMetadataWriting {
    private static let byteLimit = 4_096
    private var latest: [UUID: StreamingExportReceipt] = [:]

    func create(url: URL, format: StreamingMetadataFormat, now: Date, gate: PlaybackOutputGate, revision: UInt64) throws -> StreamingExportReceipt {
        let id = UUID()
        let saved = try gate.configuring(through: revision) {
            guard url.isFileURL, url.host == nil || url.host == "", url.query == nil, url.fragment == nil,
                  url.pathExtension.lowercased() == (format == .json ? "json" : "txt"), url.path.utf8.count <= 4_096,
                  !url.path.utf8.contains(0), (1...255).contains(url.lastPathComponent.utf8.count) else { throw StreamingExportError.invalidTarget }
            // Foundation can preserve macOS's /var alias when resolving file URLs.
            // Resolve the explicitly selected parent once, then reopen every canonical component without following links.
            guard let resolved = Darwin.realpath(url.deletingLastPathComponent().path, nil) else { throw StreamingExportError.invalidTarget }
            let parentURL = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            Darwin.free(resolved)
            guard (try parentURL.resourceValues(forKeys: [.volumeIsLocalKey])).volumeIsLocal == true else { throw StreamingExportError.invalidTarget }
            let fileURL = parentURL.appendingPathComponent(url.lastPathComponent)
            let directory = try openDirectory(parentURL.path); defer { _ = Darwin.close(directory) }
            let parent = try identity(directory, regular: false)
            let descriptor = Darwin.openat(directory, fileURL.lastPathComponent,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o600)
            guard descriptor >= 0 else { throw StreamingExportError.invalidTarget }
            defer { _ = Darwin.close(descriptor) }
            let file = try identity(descriptor, regular: true)
            let data = try StreamingMetadataDocument(metadata: nil, now: now).encoded(format: format)
            try put(data, descriptor: descriptor)
            let receipt = StreamingExportReceipt(id: id, path: fileURL.path, format: format, parent: parent, file: file,
                digest: Self.digest(data), revision: 0)
            try receipt.validate()
            return receipt
        }
        remember(saved)
        return saved
    }
    func write(_ document: StreamingMetadataDocument, receipt: StreamingExportReceipt, gate: PlaybackOutputGate,
               permit: PlaybackOutputGate.Permit) throws -> StreamingExportReceipt {
        guard permit.target == receipt.id else { throw StreamingExportError.revoked }
        let saved = try gate.publishing(permit) { try update(document, receipt: receipt) }
        remember(saved); return saved
    }
    func clear(receipt: StreamingExportReceipt, now: Date, gate: PlaybackOutputGate, through revision: UInt64) throws -> StreamingExportReceipt {
        let saved = try gate.clearing(target: receipt.id, through: revision) {
            try update(StreamingMetadataDocument(metadata: nil, now: now), receipt: receipt)
        }
        remember(saved); return saved
    }
    private func update(_ document: StreamingMetadataDocument, receipt supplied: StreamingExportReceipt) throws -> StreamingExportReceipt {
        try supplied.validate()
        var receipt = latest[supplied.id] ?? supplied
        guard receipt.path == supplied.path, receipt.format == supplied.format, receipt.file == supplied.file,
              receipt.parent == supplied.parent else { throw StreamingExportError.changedTarget }
        let url = URL(fileURLWithPath: receipt.path)
        let directory = try openDirectory(url.deletingLastPathComponent().path); defer { _ = Darwin.close(directory) }
        guard try identity(directory, regular: false) == receipt.parent else { throw StreamingExportError.changedTarget }
        guard try pathIdentity(directory, name: url.lastPathComponent) == receipt.file else { throw StreamingExportError.changedTarget }
        let descriptor = Darwin.openat(directory, url.lastPathComponent, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK)
        guard descriptor >= 0 else { throw StreamingExportError.changedTarget }
        defer { _ = Darwin.close(descriptor) }
        guard try identity(descriptor, regular: true) == receipt.file,
              try pathIdentity(directory, name: url.lastPathComponent) == receipt.file,
              Self.digest(try read(descriptor)) == receipt.digest else { throw StreamingExportError.changedTarget }
        let data = try document.encoded(format: receipt.format)
        try put(data, descriptor: descriptor)
        // A replacement path is foreign even if our old open inode was writable.
        guard try pathIdentity(directory, name: url.lastPathComponent) == receipt.file else { throw StreamingExportError.changedTarget }
        receipt.digest = Self.digest(data); receipt.revision &+= 1
        return receipt
    }
    private func remember(_ receipt: StreamingExportReceipt) {
        if latest[receipt.id] == nil, latest.count >= 4 { latest.removeAll() }
        latest[receipt.id] = receipt
    }
    private func openDirectory(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096, !path.utf8.contains(0) else { throw StreamingExportError.invalidTarget }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StreamingExportError.invalidTarget }
        for component in path.split(separator: "/") {
            guard component != ".", component != ".." else { _ = Darwin.close(descriptor); throw StreamingExportError.invalidTarget }
            let next = Darwin.openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            _ = Darwin.close(descriptor)
            guard next >= 0 else { throw StreamingExportError.changedTarget }
            descriptor = next
        }
        return descriptor
    }
    private func identity(_ descriptor: Int32, regular: Bool) throws -> StreamingFileIdentity {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0, value.st_uid == geteuid(),
              (value.st_mode & S_IFMT) == (regular ? S_IFREG : S_IFDIR),
              !regular || (value.st_nlink == 1 && value.st_mode & 0o077 == 0) else { throw StreamingExportError.changedTarget }
        return StreamingFileIdentity(value)
    }
    private func pathIdentity(_ directory: Int32, name: String) throws -> StreamingFileIdentity {
        var value = stat()
        guard Darwin.fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
              (value.st_mode & S_IFMT) == S_IFREG, value.st_nlink == 1, value.st_uid == geteuid(), value.st_mode & 0o077 == 0 else { throw StreamingExportError.changedTarget }
        return StreamingFileIdentity(value)
    }
    private func read(_ descriptor: Int32) throws -> Data {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0, value.st_size >= 0, value.st_size <= Self.byteLimit else { throw StreamingExportError.changedTarget }
        var data = Data(count: Int(value.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { throw StreamingExportError.changedTarget }
        return data
    }
    private func put(_ data: Data, descriptor: Int32) throws {
        guard data.count <= Self.byteLimit else { throw StreamingExportError.tooLarge }
        guard Darwin.ftruncate(descriptor, 0) == 0 else { throw StreamingExportError.changedTarget }
        let count = data.withUnsafeBytes { Darwin.pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { throw StreamingExportError.changedTarget }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
