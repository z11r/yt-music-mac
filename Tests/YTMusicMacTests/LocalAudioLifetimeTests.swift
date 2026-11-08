import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@Suite("Local audio resource ownership") @MainActor
struct LocalAudioLifetimeTests {
    @Test func membershipProofCannotBeReusedForADifferentFileIdentity() async throws {
        let fixture = LocalAudioEngineFixture()
        let target = fixture.scope(); fixture.owner.scope = target
        let prepared = try await fixture.prepared(target)
        let lease = prepared.source.lease
        let mismatched = LocalAudioResourceLease(reference: lease.reference, fileURL: lease.fileURL,
            identity: .init(volumeID: "different", fileID: 99), profileLifetime: lease.profileLifetime,
            referenceUse: lease.referenceUse, libraryAccess: lease.libraryAccess, endAccess: {})
        #expect(!mismatched.hasValidReferenceOwnership)
        #expect(throws: LocalAudioPlaybackIssue.permission) { try mismatched.retainUse() }
        #expect(fixture.factory.drivers.isEmpty)
    }

    @Test func canceledUnderlyingReadRetainsProfileAndRemovalUseUntilItActuallySettles() async throws {
        let id = UUID(), reference = LocalAudioReference(libraryID: UUID(), fileID: UUID())
        let references = LocalAudioReferenceUseRegistry(profileStorageID: id), holds = LocalAudioTestHolds()
        let owner = LocalAudioTestOwner()
        let authorization = LocalAudioIOAuthorization(profileStorageID: id, isCurrent: { owner.current })
        let gate = LocalAudioHeldLookup(), io = TestLocalAudioIO()
        let document = LocalAudioLibraryDocument(profileID: id, libraryID: reference.libraryID)
        let access = LocalAudioAccessController(load: { await gate.wait(); return document }, bookmarks: io, files: io,
            profiles: TestLocalAudioProfiles(storageID: id, hold: { holds.hold() }), references: references, admission: LocalAudioReadAdmission())
        let work = Task { try await access.acquire(reference, expectedLibraryID: reference.libraryID, authorization: authorization) }
        await gate.started(); work.cancel(); owner.current = false
        #expect(holds.count == 1 && references.useCount(reference) == 1)
        #expect(throws: LocalAudioPlaybackIssue.busy) { try references.reserveRemoval(reference) }
        await gate.release()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(holds.count == 0 && references.useCount(reference) == 0)
    }

    @Test func closeWaitsForActualNativeUsesAndRetainsProfileUntilAllOwnersDrop() throws {
        let id = UUID(), reference = LocalAudioReference(libraryID: UUID(), fileID: UUID())
        let registry = LocalAudioReferenceUseRegistry(profileStorageID: id)
        let holds = LocalAudioTestHolds(), ends = LocalAudioTestEnds()
        let authorization = LocalAudioIOAuthorization(profileStorageID: id, isCurrent: { true })
        var lease: LocalAudioResourceLease? = try .init(reference: reference, fileURL: URL(fileURLWithPath: "/synthetic/a.wav"),
            identity: .init(volumeID: "fixture", fileID: 1),
            profileLifetime: .init(profileStorageID: id, authorization: authorization, retaining: holds.hold()),
            referenceUse: registry.acquireUse(reference), endAccess: { ends.end() })
        var first: LocalAudioResourceUse? = try lease?.retainUse()
        var second: LocalAudioResourceUse? = try lease?.retainUse()
        lease?.release(); lease?.release()
        #expect(lease?.isReleased == false && registry.useCount(reference) == 1 && holds.count == 1 && ends.count == 0)
        #expect(throws: LocalAudioPlaybackIssue.permission) { try lease?.retainUse() }
        first = nil; #expect(second != nil && lease?.isReleased == false)
        second = nil; #expect(lease?.isReleased == true && first == nil && ends.count == 1)
        lease = nil; #expect(holds.count == 0 && registry.useCount(reference) == 0 && ends.count == 1)
    }

    @Test func poolReusesReactivatedProfileAndReviewReservationCannotForgetRetainedUses() throws {
        var extra = try AppProfile.additional(name: "Fixture"); extra.isInitialized = true
        let context = try AppProfileContext(profile: extra, appIdentifier: "fixture.app", legacyDirectory: URL(fileURLWithPath: "/synthetic"),
            legacyWebsiteDataIdentifier: UUID())
        let pool = LocalAudioReferenceUseRegistryPool()
        var first: LocalAudioReferenceUseRegistry? = try pool.registry(for: context)
        let reference = LocalAudioReference(libraryID: UUID(), fileID: UUID())
        var use: LocalAudioReferenceUse? = try first?.acquireUse(reference)
        let old = ObjectIdentifier(try #require(first)); first = nil
        let resumed = try pool.registry(for: context)
        #expect(ObjectIdentifier(resumed) == old)
        #expect(throws: LocalAudioPlaybackIssue.busy) { try resumed.reserveRemoval(reference) }
        use = nil; #expect(use == nil)
        let reservation = try resumed.reserveRemoval(reference)
        var review: LocalAudioReferenceUse? = try reservation.acquireReviewUse()
        #expect(throws: LocalAudioPlaybackIssue.busy) { try resumed.acquireUse(reference) }
        reservation.release(); reservation.release()
        #expect(resumed.useCount(reference) == 1)
        #expect(throws: LocalAudioPlaybackIssue.busy) { try resumed.reserveRemoval(reference) }
        #expect(throws: LocalAudioPlaybackIssue.stale) { try reservation.acquireReviewUse() }
        review = nil; #expect(review == nil && resumed.useCount(reference) == 0)
        let next = try resumed.reserveRemoval(reference); next.release()
    }

    @Test func nativeProviderRejectsQuarantineAndStaleOwnerWithoutNativeLeaseCallsAndProtectsDefault() async throws {
        var extra = try AppProfile.additional(name: "Fixture"); extra.isInitialized = true
        let context = try AppProfileContext(profile: extra, appIdentifier: "fixture.app", legacyDirectory: URL(fileURLWithPath: "/synthetic"),
            legacyWebsiteDataIdentifier: UUID())
        var archive = AppProfileArchive(version: 2, selectedID: AppProfile.defaultID, profiles: [.original, extra])
        archive.deletions = [.init(target: extra)]
        let registry = LocalAudioTestRegistry(archive)
        let provider = NativeLocalAudioProfileLifetimeProvider(context: context, registry: registry, acquireShared: { _ in
            Issue.record("Quarantined profile must not acquire native ownership"); return UUID()
        })
        let current = LocalAudioIOAuthorization(profileStorageID: context.websiteDataIdentifier, isCurrent: { true })
        await #expect(throws: LocalAudioPlaybackIssue.stale) { try await provider.acquire(authorization: current) }
        let before = await registry.loads
        let stale = LocalAudioIOAuthorization(profileStorageID: context.websiteDataIdentifier, isCurrent: { false })
        await #expect(throws: LocalAudioPlaybackIssue.stale) { try await provider.acquire(authorization: stale) }
        #expect(await registry.loads == before)
        let original = try AppProfileContext(profile: .original, appIdentifier: "fixture.app", legacyDirectory: URL(fileURLWithPath: "/synthetic"),
            legacyWebsiteDataIdentifier: UUID())
        let defaults = NativeLocalAudioProfileLifetimeProvider(context: original, registry: LocalAudioTestRegistry(.original), acquireShared: { _ in
            Issue.record("Protected default never acquires an extra-profile lock"); return UUID()
        })
        let authorization = LocalAudioIOAuthorization(profileStorageID: original.websiteDataIdentifier, isCurrent: { true })
        let hold = try await defaults.acquire(authorization: authorization)
        #expect(hold.profileStorageID == original.websiteDataIdentifier)
    }

    @Test func genericIssuesNeverReadPrivateErrorDescriptionsAndShipBothLocales() throws {
        struct PrivateError: LocalizedError { var errorDescription: String? { Issue.record("Private error text must never be read"); return "file:///private/secret.wav" } }
        #expect(LocalAudioPlaybackIssue.sanitizing(PrivateError()) == .unavailable)
        for locale in ["en", "fr"] {
            let url = try #require(AppIdentity.resourceBundle.url(forResource: "LocalAudio", withExtension: "strings", subdirectory: nil, localization: locale))
            let copy = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            #expect(copy.count == LocalAudioPlaybackIssue.allCases.count)
            #expect(copy.values.allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("file:") })
        }
    }
}

private actor LocalAudioHeldLookup {
    private var began = false
    private var work: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func wait() async { began = true; arrival?.resume(); arrival = nil; await withCheckedContinuation { work = $0 } }
    func started() async { if !began { await withCheckedContinuation { arrival = $0 } } }
    func release() { work?.resume(); work = nil }
}

private final class LocalAudioTestEnds: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func end() { lock.withLock { value += 1 } }
}

actor LocalAudioTestRegistry: AppProfileRegistry {
    var archive: AppProfileArchive
    private(set) var loads = 0
    init(_ archive: AppProfileArchive) { self.archive = archive }
    func load() -> AppProfileRegistrySnapshot { loads += 1; return .init(archive: archive, revision: nil) }
    func save(_ archive: AppProfileArchive, replacing revision: Data?) -> AppProfileRegistrySnapshot {
        self.archive = archive; return .init(archive: archive, revision: nil)
    }
}
