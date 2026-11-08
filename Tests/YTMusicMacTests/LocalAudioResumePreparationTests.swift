import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@Suite("Verified local audio resume bounds") @MainActor
struct LocalAudioResumePreparationTests {
    @Test func shortenedSameIdentityFileClampsOnlyAfterAssetVerification() async throws {
        let fixture = LocalAudioEngineFixture(), target = UUID()
        let scope = fixture.scope(itemID: target); fixture.owner.scope = scope
        let original = try await fixture.prepared(scope)
        #expect(original.track.duration == 120)
        let access = ResumeRecordingAccess(lease: original.source.lease)
        let assets = ResumeVerifiedAssets(duration: 20, held: true)
        let preparer = LocalAudioItemPreparer(access: access, assets: assets)
        var finished = false
        let work = Task {
            let result = await preparer.prepare(track: original.track, scope: scope, expectedLibraryID: fixture.reference.libraryID,
                authorization: original.authorization, resumePosition: 90)
            finished = true; return result
        }
        await assets.waitStarted()
        #expect(!finished && assets.calls == 1)
        #expect(await access.calls == 1)
        assets.release()
        let result = try await work.value.get()
        #expect(result.resumePosition == 20 && result.source.duration == 20)
        #expect(result.track == original.track && result.scope == original.scope)
        #expect(result.source.lease.identity == original.source.lease.identity)
        #expect(result.source.lease.libraryAccess?.revision == original.source.lease.libraryAccess?.revision)
        #expect(throws: LocalAudioPlaybackIssue.stale) {
            try LocalAudioPreparedItem(scope: scope, track: original.track, source: result.source,
                authorization: original.authorization, resumePosition: 90)
        }
        #expect(fixture.factory.drivers.isEmpty)
        result.cancelIfUnconsumed()
    }

    @Test func invalidRequestedPositionsRejectBeforeAccessOrAssetWork() async throws {
        for position in [Double.nan, .infinity, -.infinity, -1, -Double.leastNonzeroMagnitude] {
            let fixture = LocalAudioEngineFixture()
            let target = fixture.scope(); fixture.owner.scope = target
            let authorization = LocalAudioIOAuthorization(profileStorageID: fixture.profileID, isCurrent: { true })
            let metadata = LocalAudioMetadata(title: "Fixture", artist: "Artist", duration: 120, byteCount: 512)
            let access = ResumeRecordingAccess(lease: nil), assets = ResumeVerifiedAssets(duration: 20)
            let preparer = LocalAudioItemPreparer(access: access, assets: assets)
            let track = try metadata.track(reference: fixture.reference)
            let result = await preparer.prepare(track: track, scope: target, expectedLibraryID: fixture.reference.libraryID,
                authorization: authorization, resumePosition: position)
            #expect(testLocalIssue(result) == .seekFailed)
            #expect(await access.calls == 0)
            #expect(assets.calls == 0 && fixture.factory.drivers.isEmpty)
        }
    }

    @Test func verifiedDurationPreservesInRangePositionsAndBoundsHugeFiniteResume() async throws {
        for requested in [0, 10, 20, Double.greatestFiniteMagnitude] {
            let fixture = LocalAudioEngineFixture()
            let scope = fixture.scope(); fixture.owner.scope = scope
            let original = try await fixture.prepared(scope)
            let access = ResumeRecordingAccess(lease: original.source.lease), assets = ResumeVerifiedAssets(duration: 20)
            let preparer = LocalAudioItemPreparer(access: access, assets: assets)
            let result = try await preparer.prepare(track: original.track, scope: scope, expectedLibraryID: fixture.reference.libraryID,
                authorization: original.authorization, resumePosition: requested).get()
            #expect(result.resumePosition == (requested > 20 ? 20 : requested))
            #expect(result.source.lease.reference == fixture.reference && fixture.factory.drivers.isEmpty)
            result.cancelIfUnconsumed()
        }
    }
}

private actor ResumeRecordingAccess: LocalAudioAccessProviding {
    let lease: LocalAudioResourceLease?
    private(set) var calls = 0
    init(lease: LocalAudioResourceLease?) { self.lease = lease }
    func acquire(_ reference: LocalAudioReference, expectedLibraryID: UUID, authorization: LocalAudioIOAuthorization) async throws -> LocalAudioResourceLease {
        calls += 1
        guard let lease else { throw LocalAudioPlaybackIssue.unavailable }
        return lease
    }
}
@MainActor private final class ResumeVerifiedAssets: LocalAudioAssetPreparing {
    let duration: TimeInterval
    private(set) var calls = 0
    private var held: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    init(duration: TimeInterval, held: Bool = false) { self.duration = duration; self.held = held }
    func prepare(_ lease: LocalAudioResourceLease) async throws -> any LocalAudioPreparedSource {
        calls += 1
        let waiting = observers; observers = []; waiting.forEach { $0.resume() }
        if held { await withCheckedContinuation { continuation = $0 } }
        return FakeLocalPreparedSource(lease: lease, duration: duration)
    }
    func waitStarted() async { if calls == 0 { await withCheckedContinuation { observers.append($0) } } }
    func release() { held = false; let work = continuation; continuation = nil; work?.resume() }
}
