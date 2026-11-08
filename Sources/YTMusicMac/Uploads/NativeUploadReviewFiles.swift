import AppKit
import Darwin
import Foundation

/// At most one filesystem inspection is admitted process-wide. A slow volume
/// cannot accumulate detached readers when a view cancels and opens again.
actor NativeUploadFileMetadataReader {
    static let shared = NativeUploadFileMetadataReader()
    private let readMetadata: @Sendable (URL) async throws -> UploadFileMetadata
    private var worker: Task<UploadFileMetadata, any Error>?

    init(readMetadata: @escaping @Sendable (URL) async throws -> UploadFileMetadata = { try NativeUploadFileMetadataReader.read($0) }) {
        self.readMetadata = readMetadata
    }

    func inspect(_ url: URL) async throws -> UploadFileMetadata {
        if let issue = UploadReviewPolicy.initialIssue(url) { throw issue }
        guard worker == nil else { throw UploadReviewIssue.metadataBusy }
        let read = readMetadata
        let work = Task.detached(priority: .utility) { try await read(url) }
        worker = work
        defer { worker = nil }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: { work.cancel() }
    }

    private static func read(_ url: URL) throws -> UploadFileMetadata {
        try Task.checkCancellation()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var info = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &info)
        }
        guard result == 0 else { throw UploadReviewIssue.unreadable }
        try Task.checkCancellation()
        let kind = info.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) else {
            return UploadFileMetadata(isRegularFile: false, isSymbolicLink: kind == mode_t(S_IFLNK),
                isReadable: false, isLocallyAvailable: info.st_flags & UInt32(SF_DATALESS) == 0, byteCount: info.st_size)
        }
        let readable: Bool = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return Darwin.access(path, R_OK) == 0
        }
        return UploadFileMetadata(isRegularFile: kind == mode_t(S_IFREG), isSymbolicLink: kind == mode_t(S_IFLNK),
            isReadable: readable, isLocallyAvailable: info.st_flags & UInt32(SF_DATALESS) == 0, byteCount: info.st_size)
    }
}

@MainActor
protocol UploadReviewFilePicking: AnyObject {
    func chooseFiles() async -> [URL]?
    func cancel()
}

/// Lazily presents a chooser only after the user invokes the review action.
@MainActor
final class NativeUploadReviewFilePicker: UploadReviewFilePicking {
    private var panel: NSOpenPanel?
    private var completion: CheckedContinuation<[URL]?, Never>?
    private var request = UUID()

    func chooseFiles() async -> [URL]? {
        guard panel == nil else { return nil }
        let id = UUID(); request = id
        let panel = NSOpenPanel()
        panel.title = AppLocalization.text("Choose Files for Local Upload Review")
        panel.prompt = AppLocalization.text("Review")
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true; panel.resolvesAliases = false
        panel.canCreateDirectories = false; panel.treatsFilePackagesAsDirectories = false
        self.panel = panel
        return await withCheckedContinuation { continuation in
            completion = continuation
            panel.begin { [weak self, weak panel] result in
                guard let self, self.request == id else { return }
                let urls = result == .OK ? panel?.urls : nil
                self.finish(urls)
            }
        }
    }
    func cancel() {
        let old = panel
        finish(nil)
        old?.cancel(nil)
    }
    private func finish(_ urls: [URL]?) {
        request = UUID(); panel = nil
        let pending = completion; completion = nil; pending?.resume(returning: urls)
    }
}
