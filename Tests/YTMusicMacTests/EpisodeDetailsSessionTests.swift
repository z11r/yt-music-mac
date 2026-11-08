import Foundation
import MusicCore
import Testing
@testable import YouTubeMusic
@testable import YTMusicMac

@MainActor @Suite("Explicit scoped episode details")
struct EpisodeDetailsSessionTests {
    @Test func constructionAndIneligibleOrStaleSelectionsNeverFetch() async {
        let gate = EpisodeDetailsFixtureGate(), admission = EpisodeDetailsReadAdmission()
        let session = detailsSession(gate, admission: admission)
        var missing = detailsTrack(); missing.episode = nil
        var song = detailsTrack(); song.contentKind = .song
        var unknown = detailsTrack(); unknown.contentKind = nil
        var upload = detailsTrack(); upload.origin = .upload
        var local = detailsTrack(); local.origin = .localFile
        let invalid = Track(id: "invalid", title: "Invalid", artist: "Show", contentKind: .podcastEpisode,
            episode: .init(identity: detailsReferenceValue().identity))
        for track in [missing, song, unknown, upload, local, invalid] {
            let opened = session.open(track: track, isCurrent: { true })
            #expect(!opened)
        }
        let staleOpened = session.open(track: detailsTrack(), isCurrent: { false })
        #expect(!staleOpened)
        #expect(session.state == .idle && !session.isBusy)
        #expect(await gate.requestCount == 0)
    }
    @Test func revocationBeforeTheWorkerStartsPerformsNoCredentialSnapshotOrFetch() async {
        for close in [true, false] {
            let gate = EpisodeDetailsFixtureGate(), owner = EpisodeDetailsOwner(), session = detailsSession(gate)
            let captured = owner.target
            session.open(track: detailsTrack(), isCurrent: { owner.target == captured })
            if close { session.clear() } else { owner.target = changedDetailsTarget(captured, field: 0) }
            await session.waitForIdle()
            #expect(await gate.snapshotCount == 0)
            #expect(await gate.requestCount == 0)
            #expect(session.state == .idle && !session.isBusy)
        }
    }
    @Test func aReadPublishesOnlyAfterTheSameCredentialScopeIsConfirmedAgain() async {
        let gate = EpisodeDetailsFixtureGate(), session = detailsSession(gate)
        let opened = session.open(track: detailsTrack(), isCurrent: { true })
        #expect(opened)
        await gate.waitForRead()
        #expect(session.state == .loading && session.isBusy)
        await gate.reply(.available(detailsValue()))
        await session.waitForIdle()
        #expect(session.state == .available(detailsValue()) && !session.isBusy)
        #expect(await gate.snapshotCount == 2)
        session.clear(); #expect(session.state == .idle && session.track == nil)
    }
    @Test func canceledUnsettledReadRetainsTheSharedSlotAcrossAnotherProfileController() async {
        let gate = EpisodeDetailsFixtureGate(), admission = EpisodeDetailsReadAdmission()
        let old = detailsSession(gate, admission: admission), other = detailsSession(gate, admission: admission)
        old.open(track: detailsTrack(), isCurrent: { true }); await gate.waitForRead()
        old.cancel()
        #expect(old.state == .canceled && old.isBusy && other.isBusy)
        let blocked = other.open(track: detailsTrack(), isCurrent: { true })
        #expect(!blocked)
        old.retry(); #expect(await gate.requestCount == 1)
        await gate.reply(.available(detailsValue())); await old.waitForIdle()
        #expect(old.state == .canceled && !other.isBusy)
        let reopened = other.open(track: detailsTrack(), isCurrent: { true })
        #expect(reopened)
        await gate.waitForRead(count: 2); await gate.reply(.unavailable); await other.waitForIdle()
        #expect(other.state == .unavailable)
    }
    @Test func closeImmediatelyHidesAllMetadataButDoesNotReleaseAnUnsettledRead() async {
        let gate = EpisodeDetailsFixtureGate(), session = detailsSession(gate)
        session.open(track: detailsTrack(), isCurrent: { true }); await gate.waitForRead()
        session.clear()
        #expect(session.track == nil && session.state == .idle && !session.isPresented && session.isBusy)
        await gate.reply(.available(detailsValue())); await session.waitForIdle()
        #expect(session.state == .idle && session.track == nil && !session.isBusy)
    }
    @Test func everyProfileAccountQueueEntryOccurrenceAndEpisodeChangeRevokesAnOldReply() async {
        for field in 0..<7 {
            let gate = EpisodeDetailsFixtureGate(), owner = EpisodeDetailsOwner(), session = detailsSession(gate)
            let captured = owner.target
            session.open(track: detailsTrack(), isCurrent: { owner.target == captured })
            await gate.waitForRead()
            owner.target = changedDetailsTarget(captured, field: field)
            #expect(!session.isPresented && session.track == nil && session.state == .idle)
            await gate.reply(.available(detailsValue())); await session.waitForIdle()
            #expect(session.state == .idle && !session.isBusy)
        }
    }
    @Test func anAlreadyAvailableDescriptionDisappearsImmediatelyWhenItsOwnerChanges() async {
        let gate = EpisodeDetailsFixtureGate(), owner = EpisodeDetailsOwner(), session = detailsSession(gate)
        let captured = owner.target
        session.open(track: detailsTrack(), isCurrent: { owner.target == captured }); await gate.waitForRead()
        await gate.reply(.available(detailsValue())); await session.waitForIdle()
        #expect(session.state == .available(detailsValue()))
        owner.target = changedDetailsTarget(captured, field: 1)
        #expect(session.state == .idle && session.track == nil && !session.isPresented)
        session.discardIfStale()
        #expect(await gate.requestCount == 1)
    }
    @Test func changedOwnerWhileSnapshotIsHeldPreventsAnyFetch() async {
        let gate = EpisodeDetailsFixtureGate(holdSnapshot: 1), owner = EpisodeDetailsOwner()
        let session = detailsSession(gate), captured = owner.target
        session.open(track: detailsTrack(), isCurrent: { owner.target == captured })
        await gate.waitForSnapshot(1)
        owner.target = changedDetailsTarget(captured, field: 0)
        await gate.releaseSnapshot(); await session.waitForIdle()
        #expect(await gate.requestCount == 0)
        #expect(!session.isBusy && session.state == .idle)
    }
    @Test func changedOwnerDuringTheFinalSnapshotCannotPublish() async {
        let gate = EpisodeDetailsFixtureGate(holdSnapshot: 2), owner = EpisodeDetailsOwner()
        let session = detailsSession(gate), captured = owner.target
        session.open(track: detailsTrack(), isCurrent: { owner.target == captured }); await gate.waitForRead()
        await gate.reply(.available(detailsValue())); await gate.waitForSnapshot(2)
        owner.target = changedDetailsTarget(captured, field: 1)
        await gate.releaseSnapshot(); await session.waitForIdle()
        #expect(session.state == .idle && session.track == nil)
    }
    @Test func changedActualCredentialScopeAndContradictoryResultCannotPublish() async {
        for credentialChange in [true, false] {
            let gate = EpisodeDetailsFixtureGate(), session = detailsSession(gate)
            session.open(track: detailsTrack(), isCurrent: { true }); await gate.waitForRead()
            if credentialChange { await gate.rotateScope() }
            let value = credentialChange ? detailsValue() : detailsValue(reference: .init(identity: .init(browseID: "MPEDother"), videoID: "xyzABC98_-7")!)
            await gate.reply(.available(value)); await session.waitForIdle()
            #expect(session.state == (credentialChange ? .idle : .failed))
        }
    }
    @Test func errorsStayOpaqueAndRetryIsExplicitForTheSameCurrentReference() async {
        let gate = EpisodeDetailsFixtureGate(), session = detailsSession(gate)
        session.open(track: detailsTrack(), isCurrent: { true }); await gate.waitForRead()
        await gate.fail(); await session.waitForIdle()
        #expect(session.state == .failed)
        #expect(await gate.requestCount == 1)
        session.retry(); await gate.waitForRead(count: 2)
        await gate.reply(.unavailable); await session.waitForIdle()
        #expect(session.state == .unavailable && !session.isBusy)
        #expect(await gate.references.allSatisfy { $0 == detailsReferenceValue() })
    }
    @Test func aStaleReadTicketCannotReleaseAnotherOwnersAdmission() {
        let admission = EpisodeDetailsReadAdmission()
        let old = admission.reserve()!; admission.release(old)
        let current = admission.reserve()!
        admission.release(old); #expect(admission.isBusy)
        admission.release(current); #expect(!admission.isBusy)
    }
    @Test func nativeCopyHasMatchingEnglishAndFrenchResources() throws {
        var allKeys: [Set<String>] = []
        for language in ["en", "fr"] {
            let url = try #require(AppLocalization.bundle.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: url))
            let table = try #require(bundle.url(forResource: "EpisodeDetails", withExtension: "strings"))
            let values = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: table), format: nil) as? [String: String])
            #expect(values.count == 14 && values.values.allSatisfy { !$0.isEmpty })
            #expect(values["Source Timestamp References"] != nil)
            allKeys.append(Set(values.keys))
        }
        #expect(allKeys[0] == allKeys[1])
    }
}
@MainActor private func detailsSession(_ gate: EpisodeDetailsFixtureGate, admission: EpisodeDetailsReadAdmission? = nil) -> EpisodeDetailsSession {
    EpisodeDetailsSession(admission: admission ?? EpisodeDetailsReadAdmission(), snapshot: { await gate.snapshot() },
        fetch: { reference, scope in try await gate.fetch(reference, scope: scope) })
}
private func detailsReferenceValue() -> MusicEpisodeDetailsReference { .init(identity: .init(browseID: "MPEDcanonical"), videoID: "abcDEF12_-3")! }
private func detailsTrack() -> Track {
    .init(id: "abcDEF12_-3", title: "Synthetic episode", artist: "Show", contentKind: .podcastEpisode,
        episode: .init(identity: detailsReferenceValue().identity))
}
private func detailsValue(reference: MusicEpisodeDetailsReference = detailsReferenceValue()) -> MusicEpisodeDetails {
    .init(reference: reference, title: "Episode", show: "Show", publishedText: nil, durationText: nil, description: "Opaque description", timestamps: [])
}
@MainActor private final class EpisodeDetailsOwner {
    var target = EpisodeDetailsTarget(profile: UUID(), account: UUID(), queueRevision: PlaybackQueue().revision,
        entry: UUID(), occurrence: .init(sessionID: UUID(), entryID: UUID(), trackID: "abcDEF12_-3", generation: 1), reference: detailsReferenceValue())
}
private func changedDetailsTarget(_ old: EpisodeDetailsTarget, field: Int) -> EpisodeDetailsTarget {
    .init(profile: field == 0 ? UUID() : old.profile, account: field == 1 ? UUID() : old.account,
        queueRevision: field == 2 ? PlaybackQueue().revision : old.queueRevision,
        entry: field == 3 ? UUID() : old.entry,
        occurrence: field == 4 ? nil : field == 5 ? .init(sessionID: UUID(), entryID: old.entry, trackID: old.reference.videoID, generation: 2) : old.occurrence,
        reference: field == 6 ? .init(identity: .init(browseID: "MPEDother"), videoID: "xyzABC98_-7")! : old.reference)
}
private actor EpisodeDetailsFixtureGate {
    private var scope = UUID()
    private let heldSnapshot: Int?
    private(set) var snapshotCount = 0
    private(set) var references: [MusicEpisodeDetailsReference] = []
    var requestCount: Int { references.count }
    private var result: CheckedContinuation<MusicEpisodeDetailsResult, any Error>?
    private var snapshotWait: CheckedContinuation<Void, Never>?
    private var readObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var snapshotObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    init(holdSnapshot: Int? = nil) { heldSnapshot = holdSnapshot }
    func snapshot() async -> UUID {
        snapshotCount += 1
        if snapshotCount == heldSnapshot {
            await withCheckedContinuation { snapshotWait = $0; let callbacks = snapshotObservers; snapshotObservers = []; callbacks.forEach { $0.1.resume() } }
        }
        return scope
    }
    func fetch(_ reference: MusicEpisodeDetailsReference, scope: UUID) async throws -> MusicEpisodeDetailsResult {
        references.append(reference)
        return try await withCheckedThrowingContinuation { result = $0; let ready = readObservers.filter { $0.0 <= references.count }; readObservers.removeAll { $0.0 <= references.count }; ready.forEach { $0.1.resume() } }
    }
    func waitForRead(count: Int = 1) async {
        if references.count < count { await withCheckedContinuation { readObservers.append((count, $0)) } }
    }
    func waitForSnapshot(_ count: Int) async {
        if snapshotWait == nil || snapshotCount < count { await withCheckedContinuation { snapshotObservers.append((count, $0)) } }
    }
    func releaseSnapshot() { let value = snapshotWait; snapshotWait = nil; value?.resume() }
    func rotateScope() { scope = UUID() }
    func reply(_ value: MusicEpisodeDetailsResult) { let pending = result; result = nil; pending?.resume(returning: value) }
    func fail() { struct PrivateError: Error {}; let pending = result; result = nil; pending?.resume(throwing: PrivateError()) }
}
