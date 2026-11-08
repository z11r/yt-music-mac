import Foundation
import Observation

/// Production service writes remain unavailable until transfer/recovery and
/// account acceptance have been established independently of a local review.
enum UploadManagementCapability {
    static let nativeTransfer = false
    static let deleteServiceUpload = false
}

struct UploadFileMetadata: Equatable, Sendable {
    let isRegularFile: Bool
    let isSymbolicLink: Bool
    let isReadable: Bool
    let isLocallyAvailable: Bool
    let byteCount: Int64?
}

enum UploadReviewIssue: Error, Equatable, Sendable {
    case notLocalFile, unsupportedFormat, notRegularFile, unreadable, notDownloaded, emptyFile, metadataUnavailable, metadataBusy, canceled
    var title: String {
        switch self {
        case .notLocalFile: AppLocalization.text("Choose a local file")
        case .unsupportedFormat: AppLocalization.text("Format is not listed for uploads")
        case .notRegularFile: AppLocalization.text("Folders, packages and symbolic links are not reviewed")
        case .unreadable: AppLocalization.text("File is not readable")
        case .notDownloaded: AppLocalization.text("Download this file locally before reviewing")
        case .emptyFile: AppLocalization.text("File is empty")
        case .metadataUnavailable: AppLocalization.text("File size could not be checked")
        case .metadataBusy: AppLocalization.text("Another file inspection is finishing; try again")
        case .canceled: AppLocalization.text("Review canceled")
        }
    }
}

struct UploadReviewRow: Equatable, Identifiable, Sendable {
    enum Status: Equatable, Sendable { case checking, formatMatches, issue(UploadReviewIssue) }
    let id: UUID
    let name: String
    var byteCount: Int64?
    var status: Status
}

enum UploadReviewPolicy {
    static let maximumFiles = 100
    static let maximumURLBytes = 8_192
    static let supportedExtensions: Set<String> = ["flac", "m4a", "mp3", "ogg", "wma"]

    static func isLocalFile(_ url: URL) -> Bool {
        url.isFileURL && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil &&
            (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost") &&
            url.absoluteString.utf8.count <= maximumURLBytes && !url.absoluteString.lowercased().contains("%00") && !url.path.contains("\0")
    }
    static func initialIssue(_ url: URL) -> UploadReviewIssue? {
        guard isLocalFile(url) else { return .notLocalFile }
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return .unsupportedFormat }
        return nil
    }
    static func issue(_ metadata: UploadFileMetadata) -> UploadReviewIssue? {
        guard metadata.isRegularFile, !metadata.isSymbolicLink else { return .notRegularFile }
        guard metadata.isReadable else { return .unreadable }
        guard metadata.isLocallyAvailable else { return .notDownloaded }
        guard let size = metadata.byteCount, size >= 0 else { return .metadataUnavailable }
        return size == 0 ? .emptyFile : nil
    }
}

/// This session has no music client, credentials, content reader or transfer
/// method. Its inspection result cannot imply an upload or account permission.
@MainActor @Observable
final class UploadFileReview {
    static let serviceURL = URL(string: "https://music.youtube.com/")!
    static let helpURL = URL(string: "https://support.google.com/youtubemusic/answer/9716522")!
    private(set) var context: UUID
    private(set) var rows: [UploadReviewRow] = []
    private(set) var isReviewing = false
    private(set) var isChoosing = false
    private(set) var message: String?
    @ObservationIgnored private let isCurrent: @MainActor (UUID) -> Bool
    @ObservationIgnored private let picker: (any UploadReviewFilePicking)?
    @ObservationIgnored private(set) var selectionTask: Task<Void, Never>?
    @ObservationIgnored private let inspect: @Sendable (URL) async throws -> UploadFileMetadata
    @ObservationIgnored private let openURL: @MainActor (URL) -> Bool
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(context: UUID, inspect: @escaping @Sendable (URL) async throws -> UploadFileMetadata,
         openURL: @escaping @MainActor (URL) -> Bool, picker: (any UploadReviewFilePicking)? = nil,
         isCurrent: @escaping @MainActor (UUID) -> Bool = { _ in true }) {
        self.context = context; self.inspect = inspect; self.openURL = openURL; self.picker = picker; self.isCurrent = isCurrent
    }

    var matchingCount: Int { rows.filter { $0.status == .formatMatches }.count }
    var issueCount: Int { rows.filter { if case .issue = $0.status { true } else { false } }.count }
    var summary: String {
        AppLocalization.format("%1$lld files: %2$lld format matches, %3$lld with issues", Int64(rows.count), Int64(matchingCount), Int64(issueCount))
    }

    @discardableResult func review(_ urls: [URL], expectedContext: UUID) -> Bool {
        guard expectedContext == context, isCurrent(expectedContext) else { return false }
        guard !urls.isEmpty, urls.count <= UploadReviewPolicy.maximumFiles else {
            message = AppLocalization.text("Choose between 1 and 100 files for one local review.")
            return false
        }
        guard urls.allSatisfy({ $0.absoluteString.utf8.count <= UploadReviewPolicy.maximumURLBytes }) else {
            message = AppLocalization.text("A file reference exceeds this review's length limit.")
            return false
        }
        cancel()
        var seen: Set<String> = []
        let unique = urls.filter { seen.insert($0.standardized.absoluteString).inserted }
        rows = unique.map { url in
            let status = UploadReviewPolicy.initialIssue(url).map(UploadReviewRow.Status.issue) ?? .checking
            return UploadReviewRow(id: UUID(), name: UploadReviewPolicy.isLocalFile(url) ? url.lastPathComponent : AppLocalization.text("Unsupported File Reference"), status: status)
        }
        let request = revision, owner = context
        isReviewing = true; message = nil
        task = Task { [weak self, inspect] in
            defer {
                if let self, self.revision == request { self.isReviewing = false; self.task = nil }
            }
            for (index, url) in unique.enumerated() {
                guard let self, self.accepts(request, context: owner) else { return }
                guard self.rows[index].status == .checking else { continue }
                do {
                    let metadata = try await inspect(url)
                    guard self.accepts(request, context: owner) else { return }
                    self.rows[index].byteCount = metadata.byteCount
                    self.rows[index].status = UploadReviewPolicy.issue(metadata).map(UploadReviewRow.Status.issue) ?? .formatMatches
                } catch {
                    guard self.accepts(request, context: owner) else { return }
                    self.rows[index].status = .issue((error as? UploadReviewIssue) ?? .metadataUnavailable)
                }
            }
            guard let self, self.accepts(request, context: owner) else { return }
            self.isReviewing = false; self.task = nil
        }
        return true
    }

    func chooseFiles(expectedContext: UUID) {
        guard expectedContext == context, isCurrent(expectedContext), !isChoosing, !isReviewing, let picker else { return }
        isChoosing = true
        let request = revision, owner = context
        selectionTask = Task { [weak self] in
            defer {
                if let self, self.revision == request { self.isChoosing = false; self.selectionTask = nil }
            }
            guard let self else { return }
            guard self.accepts(request, context: owner) else {
                if self.revision == request { self.isChoosing = false; self.selectionTask = nil }
                return
            }
            let urls = await picker.chooseFiles()
            guard self.accepts(request, context: owner) else { return }
            self.isChoosing = false; self.selectionTask = nil
            if let urls { self.review(urls, expectedContext: owner) }
        }
    }

    func cancel() {
        selectionTask?.cancel(); selectionTask = nil; picker?.cancel(); isChoosing = false
        revision = UUID(); task?.cancel(); task = nil; isReviewing = false
        for index in rows.indices where rows[index].status == .checking { rows[index].status = .issue(.canceled) }
    }
    func clear(context: UUID) {
        cancel(); self.context = context; rows = []; message = nil
    }
    func openService(expectedContext: UUID) {
        guard expectedContext == context, isCurrent(expectedContext) else { return }
        message = openURL(Self.serviceURL)
            ? AppLocalization.text("Browser opened. Check its Google account, then choose files in YouTube Music. No files were sent by this app.")
            : AppLocalization.text("The browser could not be opened. Your review has been kept.")
    }
    func openHelp(expectedContext: UUID) {
        guard expectedContext == context, isCurrent(expectedContext) else { return }
        if !openURL(Self.helpURL) { message = AppLocalization.text("The browser could not be opened. Your review has been kept.") }
    }
    private func accepts(_ request: UUID, context: UUID) -> Bool {
        self.context == context && isCurrent(context) && revision == request && !Task.isCancelled
    }
}
