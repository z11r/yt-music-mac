import Foundation
import Testing
@testable import YTMusicMac

@MainActor @Suite("Local upload file review")
struct UploadFileReviewTests {
    @Test func metadataReaderAdmitsOneWorkerUntilCanceledNativeWorkActuallySettles() async throws {
        let held = HeldUploadMetadata()
        let reader = NativeUploadFileMetadataReader(readMetadata: { await held.inspect($0) })
        let first = Task { try await reader.inspect(file("first.mp3")) }
        await held.waitForCall()
        await #expect(throws: UploadReviewIssue.metadataBusy) { try await reader.inspect(file("second.mp3")) }
        first.cancel()
        await #expect(throws: UploadReviewIssue.metadataBusy) { try await reader.inspect(file("third.mp3")) }
        #expect(await held.calls == 1)
        await held.finish()
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    @Test func reviewCountsHaveIndependentSingularPluralAndFrenchGrammar() throws {
        let key = "%1$lld files: %2$lld format matches, %3$lld with issues"
        for language in ["en", "fr"] {
            let directory = try #require(AppLocalization.bundle.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: directory))
            let format = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            let value = String(format: format, locale: Locale(identifier: language), arguments: [Int64(1), Int64(1), Int64(2)])
            #expect(value == (language == "fr" ? "1 fichier : 1 format correspondant, 2 avec des problèmes" : "1 file: 1 format match, 2 with issues"))
            #expect(bundle.localizedString(forKey: "Cancel Review", value: nil, table: "Localizable") == (language == "fr" ? "Annuler l’examen" : "Cancel Review"))
        }
    }

    @Test func productionTransferAndServiceDeletionRemainUnavailable() {
        #expect(!UploadManagementCapability.nativeTransfer)
        #expect(!UploadManagementCapability.deleteServiceUpload)
    }
    @Test func knownExtensionsAreCaseInsensitiveButNeverAContentOrAccountGuarantee() async throws {
        let metadata = FakeUploadMetadata()
        let f = ReviewFixture(inspect: { try await metadata.inspect($0) })
        let paths = ["song.MP3", "song.FlAc", "song.m4a", "song.ogg", "song.WMA"]
        #expect(f.review.review(paths.map(file), expectedContext: f.context))
        await f.review.task?.value
        #expect(f.review.matchingCount == 5)
        #expect(f.review.issueCount == 0)
        #expect(await metadata.calls.count == 5)
        #expect(f.review.rows.map(\.name) == paths)
        #expect(f.opened.isEmpty)
        #expect(!UploadManagementCapability.nativeTransfer)
    }
    @Test func unknownAndRemoteReferencesNeverReachTheFileInspector() async {
        let metadata = FakeUploadMetadata()
        let f = ReviewFixture(inspect: { try await metadata.inspect($0) })
        let urls = [file("image.png"), file("audio.wav"), URL(string: "https://example.invalid/track.mp3")!, URL(string: "file://remote.invalid/a.mp3")!, URL(string: "file:///tmp/file%00suffix.mp3")!]
        f.review.review(urls, expectedContext: f.context); await f.review.task?.value
        #expect(await metadata.calls.isEmpty)
        #expect(f.review.rows.count == 5)
        #expect(f.review.rows[0].status == .issue(.unsupportedFormat))
        #expect(f.review.rows[2].status == .issue(.notLocalFile))
        #expect(f.review.rows[2].name == AppLocalization.text("Unsupported File Reference"))
    }
    @Test func literalPercentEncodedNamesRemainValidWithoutAcceptingEncodedNul() async {
        let metadata = FakeUploadMetadata()
        let f = ReviewFixture(inspect: { try await metadata.inspect($0) })
        let genuine = file("literal%00name.mp3")
        #expect(genuine.absoluteString.contains("%2500"))
        #expect(UploadReviewPolicy.initialIssue(genuine) == nil)
        #expect(UploadReviewPolicy.initialIssue(URL(string: "file:///tmp/literal%00name.mp3")!) == .notLocalFile)
        f.review.review([genuine], expectedContext: f.context); await f.review.task?.value
        #expect(f.review.matchingCount == 1)
        #expect(f.review.rows.first?.name == "literal%00name.mp3")
        #expect(await metadata.calls == [genuine])
    }

    @Test func metadataFindingsAreSpecificAndDoNotGuessFileContents() async {
        let cases: [(UploadFileMetadata, UploadReviewIssue)] = [
            (.init(isRegularFile: false, isSymbolicLink: false, isReadable: true, isLocallyAvailable: true, byteCount: 10), .notRegularFile),
            (.init(isRegularFile: true, isSymbolicLink: true, isReadable: true, isLocallyAvailable: true, byteCount: 10), .notRegularFile),
            (.init(isRegularFile: true, isSymbolicLink: false, isReadable: false, isLocallyAvailable: true, byteCount: 10), .unreadable),
            (.init(isRegularFile: true, isSymbolicLink: false, isReadable: true, isLocallyAvailable: false, byteCount: 10), .notDownloaded),
            (.init(isRegularFile: true, isSymbolicLink: false, isReadable: true, isLocallyAvailable: true, byteCount: 0), .emptyFile),
            (.init(isRegularFile: true, isSymbolicLink: false, isReadable: true, isLocallyAvailable: true, byteCount: nil), .metadataUnavailable),
            (.init(isRegularFile: true, isSymbolicLink: false, isReadable: true, isLocallyAvailable: true, byteCount: -1), .metadataUnavailable),
        ]
        for (value, issue) in cases {
            let f = ReviewFixture(inspect: { _ in value })
            f.review.review([file("opaque.mp3")], expectedContext: f.context); await f.review.task?.value
            #expect(f.review.rows.first?.status == .issue(issue))
            #expect(f.review.matchingCount == 0)
        }
    }
    @Test func excessiveBatchOrReferenceLengthPreservesThePreviousReviewAndDoesNoWork() async {
        let metadata = FakeUploadMetadata()
        let f = ReviewFixture(inspect: { try await metadata.inspect($0) })
        f.review.review([file("first.mp3")], expectedContext: f.context); await f.review.task?.value
        let rows = f.review.rows
        #expect(!f.review.review((0..<101).map { file("\($0).mp3") }, expectedContext: f.context))
        #expect(!f.review.review([file(String(repeating: "a", count: 8_193) + ".mp3")], expectedContext: f.context))
        #expect(!f.review.review([], expectedContext: f.context))
        #expect(f.review.rows == rows)
        #expect(await metadata.calls.count == 1)
        #expect(f.review.message != nil)
    }
    @Test func repeatedURLsAreReviewedOnceWithoutCollapsingDistinctSameNamedFiles() async {
        let metadata = FakeUploadMetadata()
        let f = ReviewFixture(inspect: { try await metadata.inspect($0) })
        f.review.review([file("same.mp3"), file("same.mp3"), URL(fileURLWithPath: "/other-fixture/same.mp3")], expectedContext: f.context)
        await f.review.task?.value
        #expect(f.review.rows.count == 2)
        #expect(await metadata.calls.count == 2)
        #expect(Set(f.review.rows.map(\.id)).count == 2)
    }
    @Test func replacementReviewCannotBeOverwrittenByAnOlderMetadataReply() async {
        let held = HeldUploadMetadata()
        let f = ReviewFixture(inspect: { url in
            if url.lastPathComponent == "old.mp3" { return await held.inspect(url) }
            return UploadFileMetadata(isRegularFile: true, isSymbolicLink: false, isReadable: true, isLocallyAvailable: true, byteCount: 2_048)
        })
        f.review.review([file("old.mp3")], expectedContext: f.context)
        let old = f.review.task
        await held.waitForCall()
        f.review.review([file("replacement.mp3")], expectedContext: f.context)
        await f.review.task?.value
        await held.finish(); await old?.value
        #expect(f.review.rows.map(\.name) == ["replacement.mp3"])
        #expect(f.review.rows.first?.byteCount == 2_048)
        #expect(f.review.matchingCount == 1)
    }

    @Test func cancelFencesLateMetadataAndOnlyCancelsLocalReview() async {
        let metadata = HeldUploadMetadata()
        let f = ReviewFixture(inspect: { await metadata.inspect($0) })
        f.review.review([file("first.mp3"), file("second.mp3")], expectedContext: f.context)
        let task = f.review.task
        await metadata.waitForCall()
        f.review.cancel()
        #expect(!f.review.isReviewing)
        #expect(f.review.rows.allSatisfy { $0.status == .issue(.canceled) })
        await metadata.finish(); await task?.value
        #expect(f.review.matchingCount == 0)
        #expect(await metadata.calls == 1)
        #expect(f.opened.isEmpty)
    }
    @Test func contextChangeClearsNamesAndRejectsOldReadsAndBrowserActions() async {
        let metadata = HeldUploadMetadata()
        let f = ReviewFixture(inspect: { await metadata.inspect($0) })
        f.review.review([file("private-name.mp3")], expectedContext: f.context)
        let task = f.review.task
        await metadata.waitForCall()
        let next = UUID(); f.review.clear(context: next)
        await metadata.finish(); await task?.value
        #expect(f.review.rows.isEmpty && f.review.message == nil)
        #expect(!f.review.review([file("late.mp3")], expectedContext: f.context))
        f.review.openService(expectedContext: f.context)
        #expect(f.opened.isEmpty)
        f.review.openService(expectedContext: next)
        #expect(f.opened == [UploadFileReview.serviceURL])
        #expect(f.review.message != nil)
    }
    @Test func browserHandoffContainsOnlyTheFixedServiceURLAndNoFileOrAccountData() async {
        let f = ReviewFixture(inspect: { _ in goodUploadMetadata })
        f.review.review([file("secret title %@.mp3")], expectedContext: f.context); await f.review.task?.value
        f.review.openService(expectedContext: f.context)
        #expect(f.opened == [URL(string: "https://music.youtube.com/")!])
        #expect(f.opened.first?.query == nil && f.opened.first?.fragment == nil)
        #expect(f.review.rows.first?.name == "secret title %@.mp3")
        f.review.openHelp(expectedContext: f.context)
        #expect(f.opened.last == UploadFileReview.helpURL)
        f.allowOpen = false
        f.review.openService(expectedContext: f.context)
        #expect(f.review.message == AppLocalization.text("The browser could not be opened. Your review has been kept."))
        #expect(f.review.rows.count == 1)
    }
    @Test func revokingAdmissionBeforeQueuedChooserPreventsAllNewNativeWork() async {
        let metadata = FakeUploadMetadata(), picker = FakeUploadPicker()
        let f = ReviewFixture(inspect: { try await metadata.inspect($0) }, picker: picker)
        f.review.chooseFiles(expectedContext: f.context)
        let selection = f.review.selectionTask
        f.isAdmitted = false
        await selection?.value
        #expect(picker.calls == 0 && !f.review.isChoosing)
        #expect(!f.review.review([file("blocked.mp3")], expectedContext: f.context))
        f.review.chooseFiles(expectedContext: f.context)
        f.review.openService(expectedContext: f.context); f.review.openHelp(expectedContext: f.context)
        #expect(picker.calls == 0 && f.opened.isEmpty)
        #expect(await metadata.calls.isEmpty)
    }

    @Test func admissionRevocationRejectsLatePickerAndInspectorRepliesWithoutContextChange() async {
        let metadata = FakeUploadMetadata(), picker = FakeUploadPicker()
        let f = ReviewFixture(inspect: { try await metadata.inspect($0) }, picker: picker)
        f.review.chooseFiles(expectedContext: f.context)
        let selection = f.review.selectionTask
        while !picker.isWaiting { await Task.yield() }
        f.isAdmitted = false
        picker.finish([file("blocked.mp3")]); await selection?.value
        #expect(f.review.rows.isEmpty && f.review.context == f.context && !f.review.isChoosing)
        #expect(await metadata.calls.isEmpty)
        #expect(f.opened.isEmpty)

        let held = HeldUploadMetadata()
        let active = ReviewFixture(inspect: { await held.inspect($0) })
        active.review.review([file("old.mp3"), file("never-read.mp3")], expectedContext: active.context)
        let pending = active.review.task
        await held.waitForCall()
        active.isAdmitted = false
        await held.finish(); await pending?.value
        #expect(active.review.matchingCount == 0)
        #expect(await held.calls == 1)
        active.review.openService(expectedContext: active.context)
        #expect(active.opened.isEmpty)
    }

    @Test func canceledPickerKeepsThePreviousReviewAndStartsNoInspection() async {
        let metadata = FakeUploadMetadata(), picker = FakeUploadPicker()
        let f = ReviewFixture(inspect: { try await metadata.inspect($0) }, picker: picker)
        f.review.review([file("kept.mp3")], expectedContext: f.context); await f.review.task?.value
        let before = f.review.rows
        f.review.chooseFiles(expectedContext: f.context)
        let selection = f.review.selectionTask
        while !picker.isWaiting { await Task.yield() }
        picker.finish(nil); await selection?.value
        #expect(f.review.rows == before && !f.review.isChoosing)
        #expect(await metadata.calls.count == 1)
    }

    @Test func stalePickerReplyCannotReviewFilesOrReopenAfterContextChange() async {
        let metadata = FakeUploadMetadata()
        let picker = FakeUploadPicker()
        let f = ReviewFixture(inspect: { try await metadata.inspect($0) }, picker: picker)
        f.review.chooseFiles(expectedContext: f.context)
        let task = f.review.selectionTask
        while !picker.isWaiting { await Task.yield() }
        let next = UUID(); f.review.clear(context: next)
        picker.finish([file("late.mp3")]); await task?.value
        #expect(picker.cancelCount == 1)
        #expect(f.review.rows.isEmpty && !f.review.isChoosing)
        #expect(await metadata.calls.isEmpty)
        #expect(f.opened.isEmpty)
    }
    @Test func pickerIsLazyAndOneExplicitSelectionStartsOnlyOneLocalReview() async {
        let picker = FakeUploadPicker()
        let f = ReviewFixture(inspect: { _ in goodUploadMetadata }, picker: picker)
        #expect(picker.calls == 0)
        f.review.chooseFiles(expectedContext: UUID()); #expect(picker.calls == 0)
        f.review.chooseFiles(expectedContext: f.context)
        let selection = f.review.selectionTask
        while !picker.isWaiting { await Task.yield() }
        f.review.chooseFiles(expectedContext: f.context)
        #expect(picker.calls == 1)
        picker.finish([file("selected.mp3")]); await selection?.value; await f.review.task?.value
        #expect(!f.review.isChoosing && f.review.matchingCount == 1)
        #expect(f.opened.isEmpty)
    }
}

private func file(_ name: String) -> URL { URL(fileURLWithPath: "/upload-review-fixture/" + name) }
private let goodUploadMetadata = UploadFileMetadata(isRegularFile: true, isSymbolicLink: false, isReadable: true, isLocallyAvailable: true, byteCount: 1_024)
private actor FakeUploadMetadata {
    private(set) var calls: [URL] = []
    func inspect(_ url: URL) throws -> UploadFileMetadata { calls.append(url); return goodUploadMetadata }
}
private actor HeldUploadMetadata {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<UploadFileMetadata, Never>?
    func inspect(_ url: URL) async -> UploadFileMetadata { calls += 1; return await withCheckedContinuation { continuation = $0 } }
    func waitForCall() async { while continuation == nil { await Task.yield() } }
    func finish() { let pending = continuation; continuation = nil; pending?.resume(returning: goodUploadMetadata) }
}
@MainActor private final class FakeUploadPicker: UploadReviewFilePicking {
    var calls = 0, cancelCount = 0
    private var continuation: CheckedContinuation<[URL]?, Never>?
    var isWaiting: Bool { continuation != nil }
    func chooseFiles() async -> [URL]? { calls += 1; return await withCheckedContinuation { continuation = $0 } }
    func cancel() { cancelCount += 1 /* Keep reply suspended to exercise a late response. */ }
    func finish(_ urls: [URL]?) { let pending = continuation; continuation = nil; pending?.resume(returning: urls) }
}
@MainActor private final class ReviewFixture {
    let context = UUID()
    var opened: [URL] = []
    var allowOpen = true
    var isAdmitted = true
    var review: UploadFileReview!
    init(inspect: @escaping @Sendable (URL) async throws -> UploadFileMetadata, picker: (any UploadReviewFilePicking)? = nil) {
        review = UploadFileReview(context: context, inspect: inspect, openURL: { [unowned self] url in opened.append(url); return allowOpen }, picker: picker, isCurrent: { [unowned self] context in isAdmitted && context == review.context })
    }
}
