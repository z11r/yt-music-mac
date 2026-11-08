import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@Suite("Reviewed local library", .serialized) @MainActor
struct LocalAudioLibraryControllerTests {
    @Test func reviewNeverCreatesBookmarksOrSavesAndConfirmationReprobes() async throws {
        let h = await LibraryHarness.open()
        await h.choose()
        let review = try #require(h.controller.review)
        #expect(review.rows.count == 1 && review.rows[0].reviewed == h.probe.value)
        #expect(h.probe.bookmarks == 0 && h.probe.reviews == 1)
        #expect(await h.store.saves == 0)
        await h.controller.confirm(reviewID: review.id, selectedIDs: Set(review.rows.map(\.id)), expected: review.scope)?.value
        #expect(h.probe.reviews == 2 && h.probe.bookmarks == 1)
        #expect(await h.store.saves == 1)
        #expect(h.controller.records.count == 1 && h.controller.review == nil)
        #expect(h.controller.records.first?.metadata.title == "Private title")
    }

    @Test func closingBeforeQueuedActionMakesZeroNewIO() async {
        let h = await LibraryHarness.open()
        let task = h.controller.chooseFiles(expected: h.controller.scope)
        h.current = false
        await task?.value
        #expect(h.picker.choices == 0 && h.probe.reviews == 0 && h.probe.bookmarks == 0)
        #expect(await h.store.loads == 1)
        #expect(await h.store.saves == 0)
    }

    @Test func lateChooserAndOldScopeAreRevokedWithoutInspection() async {
        let h = await LibraryHarness.open()
        h.picker.hold = true
        let task = h.controller.chooseFiles(expected: h.controller.scope)
        await h.picker.waitUntilHeld()
        let old = h.controller.scope
        h.controller.quiesce()
        var drained = false
        let drain = Task { await h.controller.waitForIdle(); drained = true }
        await Task.yield()
        #expect(!drained)
        #expect(h.controller.chooseFiles(expected: old) == nil)
        h.picker.finish()
        await task?.value; await drain.value
        #expect(h.probe.reviews == 0 && h.probe.bookmarks == 0 && h.controller.review == nil)
        #expect(await h.store.saves == 0)
    }

    @Test func ownerRevokedDuringProfileAdmissionNeverOpensPickerOrReadsLibrary() async {
        let h = await LibraryHarness.open()
        h.profiles.hold = true
        let task = h.controller.chooseFiles(expected: h.controller.scope)
        await h.profiles.waitUntilHeld()
        h.current = false
        h.profiles.finish()
        await task?.value
        #expect(h.picker.choices == 0 && h.probe.reviews == 0)
        #expect(await h.store.loads == 1)
        #expect(await h.store.saves == 0)
    }

    @Test func accountGenerationChangeDropsDraftButKeepsSameProfileLibraryAvailable() async throws {
        let h = await LibraryHarness.openWithRecord()
        let oldOwner = h.owner, old = try #require(h.controller.records.first)
        await h.controller.chooseFiles(expected: h.controller.scope, reauthorizing: old.reference)?.value
        let review = try #require(h.controller.review)
        h.controller.quiesce(); await h.controller.waitForIdle()
        h.owner = .init(profileStorageID: oldOwner.profileStorageID, activationID: oldOwner.activationID, accountGeneration: UUID())
        h.controller.resume(owner: h.owner)
        await h.controller.open(expectedOwner: h.owner)
        #expect(h.controller.review == nil && h.controller.records == [old])
        #expect(h.controller.confirm(reviewID: review.id, selectedIDs: Set(review.rows.map(\.id)), expected: review.scope) == nil)
        #expect(h.controller.canWrite && h.probe.bookmarks == 0)
        #expect(await h.store.saves == 0)
    }

    @Test func canceledProbeHoldsSharedAdmissionAndOriginalResourcesUntilSettled() async throws {
        let preparations = LocalAudioPreparationAdmission()
        let h = await LibraryHarness.open(preparations: preparations)
        h.probe.hold = true
        let task = h.controller.chooseFiles(expected: h.controller.scope)
        await h.probe.waitUntilHeld()
        #expect(preparations.isBusy)
        h.controller.quiesce()
        #expect(preparations.isBusy)
        #expect(h.references.useCount(try #require(h.probe.context?.reference)) == 1)
        await #expect(throws: LocalAudioAccessError.busy) { try await preparations.perform { true } }
        h.probe.finish()
        await task?.value
        #expect(!preparations.isBusy && h.controller.review == nil)
        #expect(h.probe.bookmarks == 0 && h.controller.records.isEmpty)
    }

    @Test func fileChangesAfterReviewNeverCreateABookmarkOrWrite() async throws {
        let h = await LibraryHarness.open()
        await h.choose()
        let review = try #require(h.controller.review)
        h.probe.value = .init(identity: .init(volumeID: "volume", fileID: 99), metadata: h.probe.value.metadata)
        await h.controller.confirm(reviewID: review.id, selectedIDs: Set(review.rows.map(\.id)), expected: review.scope)?.value
        #expect(h.probe.bookmarks == 0 && h.controller.records.isEmpty)
        #expect(await h.store.saves == 0)
        #expect(h.controller.message == LocalAudioLibraryIssue.changedFile.message)
    }

    @Test func staleAndUnsupportedLibrariesNeverBecomeEmptyWritableLibraries() async {
        for failure in [LocalAudioLibraryError.unsupportedVersion(9), .wrongProfile, .invalidLibrary] {
            let store = LibraryMemoryStore(failure: failure)
            let h = await LibraryHarness.open(store: store)
            #expect(!h.controller.canWrite && h.controller.document == nil)
            #expect(h.controller.chooseFiles(expected: h.controller.scope) == nil)
            #expect(h.picker.choices == 0)
            #expect(await store.saves == 0)
        }
    }

    @Test func remoteEncodedNulAndExcessSelectionsNeverReachProbe() async throws {
        let h = await LibraryHarness.open()
        h.picker.urls = [try #require(URL(string: "https://example.test/private.wav")),
                         try #require(URL(string: "file:///fixture/bad%00name.wav"))]
        await h.choose()
        #expect(h.probe.reviews == 0 && h.probe.bookmarks == 0)
        #expect(h.controller.review?.rows.allSatisfy { $0.reviewed == nil } == true)
        h.picker.urls = Array(repeating: URL(fileURLWithPath: "/fixture/private.wav"), count: 101)
        await h.choose()
        #expect(h.controller.review == nil && h.probe.reviews == 0)
        #expect(h.controller.message == LocalAudioLibraryIssue.fileLimit.message)
    }

    @Test func duplicateIdentitiesAreNotSavedTwiceAndUnknownSelectionCannotConfirm() async throws {
        let h = await LibraryHarness.open()
        h.picker.urls = [URL(fileURLWithPath: "/fixture/a.wav"), URL(fileURLWithPath: "/fixture/b.wav")]
        await h.choose()
        let review = try #require(h.controller.review)
        #expect(review.rows.filter { $0.reviewed != nil }.count == 1)
        #expect(h.controller.confirm(reviewID: review.id, selectedIDs: [UUID()], expected: review.scope) == nil)
        #expect(h.probe.bookmarks == 0)
        #expect(await h.store.saves == 0)
    }

    @Test func concurrentRevisionChangeBeforeConfirmationRequiresNewReview() async throws {
        let h = await LibraryHarness.open()
        await h.choose()
        let review = try #require(h.controller.review)
        await h.store.replace(.init(profileID: h.owner.profileStorageID, libraryID: review.libraryID))
        await h.controller.confirm(reviewID: review.id, selectedIDs: Set(review.rows.map(\.id)), expected: review.scope)?.value
        #expect(h.probe.bookmarks == 0)
        #expect(await h.store.saves == 0)
        #expect(h.controller.message == LocalAudioLibraryIssue.conflict.message)
    }

    @Test func singleSubmissionAndLostReceiptReconcileWithoutRetryOrFalseRollback() async throws {
        let gate = LibraryGate()
        let h = await LibraryHarness.open(store: LibraryMemoryStore(saveGate: gate, loseReceipt: true))
        await h.choose()
        let review = try #require(h.controller.review), ids = Set(review.rows.map(\.id))
        let task = h.controller.confirm(reviewID: review.id, selectedIDs: ids, expected: review.scope)
        await gate.waitUntilEntered()
        #expect(h.controller.confirm(reviewID: review.id, selectedIDs: ids, expected: review.scope) == nil)
        await gate.release(); await task?.value
        #expect(await h.store.saves == 1)
        #expect(h.controller.records.count == 1 && !h.controller.canWrite)
        #expect(h.controller.message == LocalAudioLibraryCopy.text("The reviewed records are present, but saving was not confirmed. Reload before another submission."))
    }

    @Test func closeRevokesQueuedSaveButDrainsItsOriginalReceipt() async throws {
        let gate = LibraryGate()
        let h = await LibraryHarness.open(store: LibraryMemoryStore(saveGate: gate))
        await h.choose()
        let review = try #require(h.controller.review)
        let task = h.controller.confirm(reviewID: review.id, selectedIDs: Set(review.rows.map(\.id)), expected: review.scope)
        await gate.waitUntilEntered()
        h.controller.quiesce()
        var drained = false
        let drain = Task { await h.controller.waitForIdle(); drained = true }
        await Task.yield(); #expect(!drained)
        await gate.release(); await task?.value; await drain.value
        #expect(await h.store.document == nil)
        #expect(h.controller.document == nil && h.controller.message == nil)
    }

    @Test func committedOldOwnerWriteSettlesWithoutRepaintingOrClaimingRollback() async throws {
        let receipt = LibraryGate()
        let h = await LibraryHarness.open(store: LibraryMemoryStore(receiptGate: receipt))
        await h.choose()
        let review = try #require(h.controller.review)
        let task = h.controller.confirm(reviewID: review.id, selectedIDs: Set(review.rows.map(\.id)), expected: review.scope)
        await receipt.waitUntilEntered()
        #expect(await h.store.document?.profileID == h.owner.profileStorageID)
        h.controller.quiesce()
        var drained = false
        let drain = Task { await h.controller.waitForIdle(); drained = true }
        await Task.yield(); #expect(!drained)
        await receipt.release(); await task?.value; await drain.value
        #expect(await h.store.document?.records.count == 1)
        #expect(h.controller.document == nil && h.controller.message == nil)
    }

    @Test func inUseRemovalAndReauthorizationAreBlockedBeforeDialogOrWrite() async throws {
        let h = await LibraryHarness.openWithRecord()
        let doc = try #require(h.controller.document), record = try #require(doc.records.first)
        let use = try h.references.acquireUse(record.reference)
        await h.controller.remove(record.reference, revision: doc.revision, expected: h.controller.scope)?.value
        #expect(h.controller.message == LocalAudioLibraryIssue.inUse.message)
        await h.controller.chooseFiles(expected: h.controller.scope, reauthorizing: record.reference)?.value
        #expect(h.picker.choices == 0)
        #expect(await h.store.saves == 0)
        withExtendedLifetime(use) {}
    }

    @Test func removalReservationBlocksNewUsesUntilCASSettlesAndNeverDeletesAudio() async throws {
        let gate = LibraryGate()
        let h = await LibraryHarness.openWithRecord(saveGate: gate)
        let doc = try #require(h.controller.document), record = try #require(doc.records.first)
        let task = h.controller.remove(record.reference, revision: doc.revision, expected: h.controller.scope)
        await gate.waitUntilEntered()
        #expect(throws: (any Error).self) { try h.references.acquireUse(record.reference) }
        await gate.release(); await task?.value
        #expect(h.controller.records.isEmpty && h.probe.reviews == 0 && h.probe.bookmarks == 0)
        let use = try h.references.acquireUse(record.reference)
        withExtendedLifetime(use) {}
    }

    @Test func reauthorizationPreservesOnlySameIdentityAndReferenceWithoutPlayback() async throws {
        let h = await LibraryHarness.openWithRecord()
        let old = try #require(h.controller.records.first)
        await h.controller.chooseFiles(expected: h.controller.scope, reauthorizing: old.reference)?.value
        let review = try #require(h.controller.review)
        #expect(h.picker.multiple == false && h.probe.bookmarks == 0)
        #expect(throws: (any Error).self) { try h.references.acquireUse(old.reference) }
        await h.controller.confirm(reviewID: review.id, selectedIDs: Set(review.rows.map(\.id)), expected: review.scope)?.value
        #expect(h.controller.records.first?.reference == old.reference)
        #expect(h.controller.records.first?.identity == old.identity)
        #expect(h.controller.records.first?.bookmark.data == Data([2]))
        #expect(h.acceptedTracks.isEmpty)
    }

    @Test func differentReauthorizationResourceCannotReplaceAnOldQueueReference() async throws {
        let h = await LibraryHarness.openWithRecord()
        let old = try #require(h.controller.records.first)
        h.probe.value = .init(identity: .init(volumeID: "volume", fileID: 42), metadata: h.probe.value.metadata)
        await h.controller.chooseFiles(expected: h.controller.scope, reauthorizing: old.reference)?.value
        let review = try #require(h.controller.review)
        #expect(review.rows.allSatisfy { $0.reviewed == nil })
        #expect(review.rows.first?.status == .issue(.differentFile))
        #expect(h.controller.confirm(reviewID: review.id, selectedIDs: Set(review.rows.map(\.id)), expected: review.scope) == nil)
        #expect(h.controller.records == [old] && h.probe.bookmarks == 0)
        #expect(await h.store.saves == 0)
        h.controller.cancelReview()
        await h.choose()
        let newReview = try #require(h.controller.review)
        await h.controller.confirm(reviewID: newReview.id, selectedIDs: Set(newReview.rows.map(\.id)), expected: newReview.scope)?.value
        #expect(h.controller.records.count == 2 && h.controller.records.contains(old))
        #expect(h.controller.records.last?.reference != old.reference)
    }

    @Test func signedOutQueueCallbacksReceiveOnlyValidatedTracksAndCapturedTarget() async throws {
        let h = await LibraryHarness.openWithRecord(actions: true)
        let record = try #require(h.controller.records.first), target = try #require(h.controller.queueTarget)
        await h.controller.requestQueueAction(play: true, selectedIDs: [record.id], target: target, expected: h.controller.scope)?.value
        let track = try #require(h.acceptedTracks.first)
        #expect(h.acceptedTracks.count == 1 && track.localAudioReference == record.reference)
        #expect(track.artworkURL == nil && track.origin == .localFile)
        #expect(h.controller.message == LocalAudioLibraryCopy.text("The queue request was accepted."))
        // The accepted callback advanced the queue target. Reusing the old action is refused.
        #expect(h.controller.requestQueueAction(play: false, selectedIDs: [record.id], target: target, expected: h.controller.scope) == nil)
        #expect(h.acceptedTracks.count == 1 && h.picker.choices == 0)
    }

    @Test func staleViewActionsCannotClearCurrentReviewAndForeignProviderCannotRead() async throws {
        let h = await LibraryHarness.open()
        await h.choose()
        let review = try #require(h.controller.review)
        let stale = LocalAudioLibraryUIScope(owner: h.owner, presentation: UUID())
        #expect(h.controller.refresh(expected: stale) == nil)
        #expect(h.controller.chooseFiles(expected: stale) == nil)
        #expect(h.controller.review?.id == review.id && h.controller.canWrite)
        h.controller.cancelReview()
        h.profiles.wrongProfile = true
        await h.controller.refresh(expected: h.controller.scope)?.value
        #expect(!h.controller.canWrite)
        #expect(await h.store.loads == 2)
    }

    @Test func errorsNeverPublishPrivatePathsOrUnboundedProviderMessages() async {
        let h = await LibraryHarness.open()
        h.probe.error = NSError(domain: "/Users/private/secret.wav", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: String(repeating: "private file path", count: 5_000)])
        await h.choose()
        #expect(h.controller.review?.rows.first?.status == .issue(.unsupportedAudio))
        #expect(h.controller.review?.rows.first?.reviewed == nil)
    }
}

private actor LibraryGate {
    var entered = false
    private var released = false
    private var receipt: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; if !released { await withCheckedContinuation { receipt = $0 } } }
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !entered && ContinuousClock.now < deadline { await Task.yield() }
        #expect(entered)
    }
    func release() { released = true; receipt?.resume(); receipt = nil }
}

private actor LibraryMemoryStore: LocalAudioLibraryStoring {
    var document: LocalAudioLibraryDocument?
    var loads = 0, saves = 0
    let failure: LocalAudioLibraryError?
    let saveGate: LibraryGate?
    let receiptGate: LibraryGate?
    let loseReceipt: Bool
    init(document: LocalAudioLibraryDocument? = nil, failure: LocalAudioLibraryError? = nil,
         saveGate: LibraryGate? = nil, receiptGate: LibraryGate? = nil, loseReceipt: Bool = false) {
        self.document = document; self.failure = failure; self.saveGate = saveGate; self.receiptGate = receiptGate; self.loseReceipt = loseReceipt
    }
    func load() throws -> LocalAudioLibraryDocument? { loads += 1; if let failure { throw failure }; return document }
    func save(_ value: LocalAudioLibraryDocument, replacing revision: UUID?, if permitted: @Sendable () -> Bool) async throws {
        saves += 1
        if let saveGate { await saveGate.hold() }
        guard permitted() else { throw CancellationError() }
        guard document?.revision == revision else { throw LocalAudioLibraryError.staleRevision }
        document = value
        if let receiptGate { await receiptGate.hold() }
        if loseReceipt { throw LocalAudioLibraryError.invalidStorageURL }
    }
    func replace(_ document: LocalAudioLibraryDocument?) { self.document = document }
}

@MainActor private final class LibraryProfiles: LocalAudioProfileLifetimeProviding {
    struct Token: Sendable {}
    var wrongProfile = false
    var hold = false
    private var pending: CheckedContinuation<Void, Never>?
    func acquire(authorization: LocalAudioIOAuthorization) async throws -> LocalAudioProfileLifetime {
        try authorization.check()
        if hold { await withCheckedContinuation { pending = $0 } }
        return .init(profileStorageID: wrongProfile ? UUID() : authorization.profileStorageID,
                     authorization: authorization, retaining: Token())
    }
    func waitUntilHeld() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while pending == nil && ContinuousClock.now < deadline { await Task.yield() }
        #expect(pending != nil)
    }
    func finish() { hold = false; pending?.resume(); pending = nil }
}

@MainActor private final class LibraryPicker: LocalAudioLibraryFilePicking {
    var urls = [URL(fileURLWithPath: "/fixture/private.wav")]
    var choices = 0, cancellations = 0
    var multiple = true, hold = false
    private var pending: CheckedContinuation<[URL]?, Never>?
    func chooseFiles(multiple: Bool) async -> [URL]? {
        choices += 1; self.multiple = multiple
        if hold { return await withCheckedContinuation { pending = $0 } }
        return urls
    }
    func cancel() { cancellations += 1 }
    func waitUntilHeld() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while pending == nil && ContinuousClock.now < deadline { await Task.yield() }
        #expect(pending != nil)
    }
    func finish() { hold = false; pending?.resume(returning: urls); pending = nil }
}

@MainActor private final class LibraryProbe: LocalAudioImportProbing {
    static var standard: LocalAudioReviewedFile { .init(identity: .init(volumeID: "volume", fileID: 1),
        metadata: .init(title: "Private title", artist: "Private artist", duration: 60, byteCount: 100)) }
    var value = standard
    var reviews = 0, bookmarks = 0
    var hold = false
    var error: (any Error)?
    var context: LocalAudioImportProbeContext?
    private var pending: CheckedContinuation<Void, Never>?
    func review(_ url: URL, context: LocalAudioImportProbeContext) async throws -> LocalAudioReviewedFile {
        reviews += 1
        if hold {
            self.context = context
            await withCheckedContinuation { pending = $0 }
            self.context = nil
        }
        if let error { throw error }
        return value
    }
    func confirmedBookmark(_ url: URL, expected: LocalAudioReviewedFile, context: LocalAudioImportProbeContext) async throws -> LocalAudioBookmark {
        bookmarks += 1
        return .init(mode: .ordinary, data: Data([2]))
    }
    func waitUntilHeld() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while pending == nil && ContinuousClock.now < deadline { await Task.yield() }
        #expect(pending != nil)
    }
    func finish() { hold = false; pending?.resume(); pending = nil }
}

@MainActor private final class LibraryHarness {
    var owner: LocalAudioLibraryOwner
    let store: LibraryMemoryStore
    let profiles = LibraryProfiles(), picker = LibraryPicker(), probe = LibraryProbe()
    let references: LocalAudioReferenceUseRegistry
    var current = true, target = 1
    var acceptedTracks: [Track] = []
    var controller: LocalAudioLibraryController<Int>!
    init(owner: LocalAudioLibraryOwner, store: LibraryMemoryStore, preparations: LocalAudioPreparationAdmission, actions: Bool) {
        self.owner = owner; self.store = store; references = .init(profileStorageID: owner.profileStorageID)
        let callbacks = LocalAudioLibraryQueueActions<Int>(capture: { [weak self] _ in self?.target },
            isCurrent: { [weak self] target, _ in self?.target == target },
            add: { [weak self] tracks, _ in self?.acceptedTracks += tracks; self?.target += 1; return true },
            play: { [weak self] tracks, _ in self?.acceptedTracks += tracks; self?.target += 1; return true })
        controller = .init(owner: owner, store: store, profiles: profiles, references: references, picker: picker, probe: probe,
                           reads: .init(), preparations: preparations, actions: actions ? callbacks : nil,
                           isCurrent: { [weak self] in self?.current == true && self?.owner == $0 })
    }
    static func open(store: LibraryMemoryStore = .init(), preparations: LocalAudioPreparationAdmission = .init(), actions: Bool = false) async -> LibraryHarness {
        let h = LibraryHarness(owner: .init(profileStorageID: UUID(), activationID: UUID(), accountGeneration: UUID()),
                               store: store, preparations: preparations, actions: actions)
        await h.controller.open(expectedOwner: h.owner); return h
    }
    static func openWithRecord(saveGate: LibraryGate? = nil, actions: Bool = false) async -> LibraryHarness {
        let owner = LocalAudioLibraryOwner(profileStorageID: UUID(), activationID: UUID(), accountGeneration: UUID())
        let libraryID = UUID(), ref = LocalAudioReference(libraryID: libraryID, fileID: UUID())
        let record = LocalAudioLibraryRecord(reference: ref, metadata: LibraryProbe.standard.metadata,
            identity: LibraryProbe.standard.identity, bookmark: .init(mode: .ordinary, data: Data([1])))
        let store = LibraryMemoryStore(document: .init(profileID: owner.profileStorageID, libraryID: libraryID, records: [record]), saveGate: saveGate)
        let h = LibraryHarness(owner: owner, store: store, preparations: .init(), actions: actions)
        await h.controller.open(expectedOwner: owner); return h
    }
    func choose() async { await controller.chooseFiles(expected: controller.scope)?.value }
}
