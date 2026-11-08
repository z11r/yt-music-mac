import Darwin
import Foundation
import Testing
@testable import YTMusicMac

@MainActor @Suite("Journaled inactive profile deletion")
struct ProfileDeletionTests {
    @Test func queuedReviewIsRejectedBeforeAdapterAccessAfterAdmissionRevocation() async throws {
        let f = try DeletionFixture()
        let queued = Task { await f.prepare() }
        f.current = false; await queued.value
        #expect(f.adapter.calls == 0 && f.io.writes == 0 && f.session.effects.isEmpty)
    }
    @Test func reviewHasNoDeletionOrRegistryWriteAndCancellationReleasesTheLease() async throws {
        let f = try DeletionFixture()
        await f.prepare()
        #expect(f.controller.review != nil)
        #expect(f.io.writes == 0 && f.session.effects.isEmpty)
        f.controller.cancelReview()
        #expect(f.controller.review == nil && f.session.closed)
    }
    @Test func defaultCurrentAndSelectedProfilesAreProtectedBeforeAdapterAccess() async throws {
        for (id, active, selected) in [(AppProfile.defaultID, AppProfile.defaultID, AppProfile.defaultID),
                                       (deletionID, deletionID, AppProfile.defaultID),
                                       (deletionID, AppProfile.defaultID, deletionID)] {
            let f = try DeletionFixture(selected: selected)
            await f.controller.prepare(id: id, activeID: active, isCurrent: { true })
            #expect(f.controller.review == nil && f.adapter.calls == 0 && f.io.writes == 0)
        }
    }
    @Test func blockedPrerequisiteStagesOnlyAndQuarantinesTheTarget() async throws {
        for reason in [ProfileCleanupProblem.savedData, .unsafePath, .otherInstance, .releaseRequired, .unknownPreferences, .credentialsUnavailable] {
            let f = try DeletionFixture()
            f.session.blocked = (.directory, reason)
            await f.prepare(); await f.confirm()
            let saved = try await f.registry.load()
            #expect(saved.archive.version == 2 && saved.archive.deletions.count == 1)
            #expect(saved.archive.profiles.contains(f.target))
            #expect(f.session.effects.isEmpty && f.io.durableWrites == 1)
        }
    }
    @Test func anotherAppInstancePreventsEvenCleanupInspectionButAllowsExplicitQuarantine() async throws {
        let f = try DeletionFixture(); f.adapter.failure = .otherInstance
        await f.prepare(); await f.confirm()
        #expect(f.session.probes.isEmpty && f.session.effects.isEmpty)
        #expect(try await f.registry.load().archive.deletions.count == 1)
    }
    @Test func newlyBlockedPrerequisitesAfterReadyReviewStageWithoutCleanup() async throws {
        for (step, reason) in [(ProfileCleanupStep.directory, ProfileCleanupProblem.savedData), (.preferences, .unknownPreferences)] {
            let f = try DeletionFixture()
            await f.prepare()
            #expect(f.controller.review?.problem == nil)
            f.session.blocked = (step, reason)
            await f.confirm()
            #expect(f.session.effects.isEmpty)
            let journal = try #require(try await f.registry.load().archive.deletions.first)
            #expect(journal.states.allSatisfy { $0 == .pending })
        }
    }
    @Test func newlyBlockedPrerequisiteDuringWriteAheadPreventsNativeAdmission() async throws {
        let f = try DeletionFixture(), changed = DeletionAdmission()
        await f.prepare()
        f.session.blockWhenRevoked = changed
        f.io.afterDurableWrite = { count in if count == 2 { changed.current = false } }
        await f.confirm()
        #expect(f.session.effects.isEmpty)
        let journal = try #require(try await f.registry.load().archive.deletions.first)
        #expect(journal.states.allSatisfy { $0 == .pending })
        #expect(journal.problem == .savedData)
    }
    @Test func eachMutationRequiresADurableRunningMarkerAndCompletionRemovesOnlyTarget() async throws {
        let f = try DeletionFixture()
        f.session.beforeEffect = { step in
            let current = try await f.registry.load()
            #expect(current.archive.deletions.first?.states[step.index] == .running)
            #expect(current.archive.profiles.contains(f.target))
        }
        await f.prepare(); await f.confirm()
        let saved = try await f.registry.load()
        #expect(saved.archive.profiles == [.original] && saved.archive.deletions.isEmpty)
        #expect(saved.archive.selectedID == AppProfile.defaultID)
        #expect(f.session.effects == ProfileCleanupStep.allCases)
        #expect(f.io.durableWrites > f.session.effects.count)
    }
    @Test func changedRegistryOrRevokedAccountPreventsConfirmationMutations() async throws {
        let f = try DeletionFixture()
        await f.prepare()
        let old = try await f.registry.load()
        var changed = old.archive; changed.profiles[1].name = "Changed elsewhere"
        _ = try await f.registry.save(changed, replacing: old.revision)
        let count = f.io.writes
        await f.confirm()
        #expect(f.io.writes == count && f.session.effects.isEmpty)
        let revoked = try DeletionFixture()
        await revoked.prepare(); revoked.current = false; await revoked.confirm()
        #expect(revoked.io.writes == 0 && revoked.session.effects.isEmpty)
    }
    @Test func revocationDuringAcceptedStepRecordsItsOutcomeButStartsNoNextStep() async throws {
        let f = try DeletionFixture(), gate = DeletionTestGate()
        f.session.beforeEffect = { _ in await gate.wait() }
        await f.prepare()
        let review = try #require(f.controller.review)
        let running = Task { await f.controller.confirm(reviewID: review.id) }
        while !gate.waiting { await Task.yield() }
        f.current = false; gate.open(); await running.value
        let journal = try #require(try await f.registry.load().archive.deletions.first)
        #expect(journal.states[0] == .complete && journal.states[1] == .pending)
        #expect(f.session.effects == [.website])
    }
    @Test func admissionRevokedDuringWriteAheadNeverStartsTheNativeStep() async throws {
        let f = try DeletionFixture(), admission = DeletionAdmission()
        await f.controller.prepare(id: deletionID, activeID: AppProfile.defaultID, isCurrent: { admission.current })
        f.io.afterDurableWrite = { count in if count == 2 { admission.current = false } }
        await f.confirm()
        #expect(f.session.effects.isEmpty)
        #expect(try await f.registry.load().archive.deletions.first?.states[0] == .running)
    }
    @Test func failedDurabilityAcknowledgementStartsNoCleanupAndRetainsTombstone() async throws {
        let f = try DeletionFixture(); f.io.failDurableAfterReplace = true
        await f.prepare(); await f.confirm()
        #expect(f.session.effects.isEmpty)
        #expect(try await f.registry.load().archive.deletions.count == 1)
        #expect(f.controller.message != nil)
    }
    @Test func lostWebsiteReceiptIsReconciledByAbsenceWithoutRepeatingRemoval() async throws {
        let f = try DeletionFixture(); f.session.loseReceipt = .website
        await f.prepare(); await f.confirm()
        let interrupted = try #require(try await f.registry.load().archive.deletions.first)
        #expect(interrupted.states[0] == .uncertain)
        f.session.loseReceipt = nil
        await f.prepare(); await f.confirm()
        #expect(f.session.effects.filter { $0 == .website }.count == 1)
        #expect(try await f.registry.load().archive.profiles == [.original])
    }
    @Test func uncertainSpotlightIsNeverBlindlyRetried() async throws {
        let f = try DeletionFixture(); f.session.loseReceipt = .spotlight
        await f.prepare(); await f.confirm()
        let previousEffects = f.session.effects
        await f.prepare(); await f.confirm()
        #expect(f.session.effects == previousEffects)
        #expect(try await f.registry.load().archive.deletions.first?.problem == .uncertainIndex)
    }
    @Test func reappearingCompletedDataBlocksFurtherCleanup() async throws {
        let f = try DeletionFixture(); f.session.loseReceipt = .credentials
        await f.prepare(); await f.confirm()
        f.session.present.insert(.website)
        let count = f.session.effects.count
        await f.prepare(); await f.confirm()
        #expect(f.session.effects.count == count)
        #expect(try await f.registry.load().archive.profiles.contains(f.target))
    }
    @Test func malformedFutureAndOversizeRegistryAreRetainedWithoutAdapterCalls() async throws {
        for value in [Data("malformed".utf8), Data(#"{"version":99}"#.utf8), Data(repeating: 32, count: 65_537)] {
            let f = try DeletionFixture(); f.io.force(value)
            await f.prepare()
            #expect(f.controller.review == nil && f.adapter.calls == 0 && f.io.writes == 0)
            #expect(f.io.bytes == value)
        }
    }
    @Test func journalSchemaIsStrictBoundedAndCannotTargetSelectedOrDefault() throws {
        let target = try deletionProfile()
        let valid = AppProfileArchive(version: 2, selectedID: AppProfile.defaultID,
            profiles: [.original, target], deletions: [.init(target: target)])
        let encoder = JSONEncoder(); let bytes = try encoder.encode(valid)
        #expect(try JSONDecoder().decode(AppProfileArchive.self, from: bytes) == valid)
        let v1 = try JSONSerialization.jsonObject(with: encoder.encode(AppProfileArchive.original)) as! [String: Any]
        #expect(v1["deletions"] == nil)
        var bad = valid; bad.selectedID = target.id
        #expect(throws: AppProfileError.invalidRegistry) { try bad.validate() }
        var duplicate = valid; duplicate.deletions.append(.init(target: target))
        #expect(throws: AppProfileError.invalidRegistry) { try duplicate.validate() }
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var journals = object["deletions"] as! [[String: Any]]
        journals[0]["future"] = true; object["deletions"] = journals
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AppProfileArchive.self, from: JSONSerialization.data(withJSONObject: object)) }
        journals[0].removeValue(forKey: "future"); journals[0]["states"] = Array(repeating: "pending", count: 1_000); object["deletions"] = journals
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AppProfileArchive.self, from: JSONSerialization.data(withJSONObject: object)) }
    }
    @Test func quarantinedTargetCannotBeRenamedOrPreparedByOwner() async throws {
        let f = try DeletionFixture()
        await f.prepare(); await f.confirmStaging()
        var prepared = 0
        let runtime = DeletionFakeRuntime()
        let owner = AppProfileOwner(initial: runtime, registry: f.registry, prepare: { _, _ in
            prepared += 1; return PreparedAppProfile { DeletionFakeRuntime() }
        }, bind: { _, _ in })
        await owner.start()
        await owner.switchTo(deletionID)
        await owner.rename(deletionID, name: "Must not change")
        #expect(prepared == 0 && owner.current === runtime)
        #expect(owner.isPendingDeletion(deletionID))
        #expect(try await f.registry.load().archive.profiles.contains(f.target))
    }
    @Test func cancelingUnstartedStagingRestoresAvailabilityButCannotUndoAcceptedCleanup() async throws {
        let f = try DeletionFixture()
        await f.confirmStaging()
        await f.prepare()
        let review = try #require(f.controller.review)
        await f.controller.cancelStagedDeletion(reviewID: review.id)
        #expect(try await f.registry.load().archive.deletions.isEmpty)
        #expect(try await f.registry.load().archive.profiles.contains(f.target))
        #expect(f.session.effects.isEmpty)
        let partial = try DeletionFixture(); partial.session.loseReceipt = .website
        await partial.prepare(); await partial.confirm(); await partial.prepare()
        let blocked = try #require(partial.controller.review)
        await partial.controller.cancelStagedDeletion(reviewID: blocked.id)
        #expect(try await partial.registry.load().archive.deletions.count == 1)
    }
    @Test func ownershipModesAndReplacementIdentitiesAreCheckedWithoutFilesystemCalls() {
        #expect(ProfileFilesystemAdmission.allows(owner: 501, mode: 0o040755, expectedOwner: 501, kind: .directory))
        #expect(!ProfileFilesystemAdmission.allows(owner: 502, mode: 0o040700, expectedOwner: 501, kind: .directory))
        #expect(!ProfileFilesystemAdmission.allows(owner: 501, mode: 0o040775, expectedOwner: 501, kind: .directory))
        #expect(!ProfileFilesystemAdmission.allows(owner: 501, mode: 0o042700, expectedOwner: 501, kind: .directory))
        #expect(ProfileFilesystemAdmission.allows(owner: 501, mode: 0o040700, expectedOwner: 501, kind: .privateDirectory))
        #expect(!ProfileFilesystemAdmission.allows(owner: 501, mode: 0o040755, expectedOwner: 501, kind: .privateDirectory))
        #expect(ProfileFilesystemAdmission.allows(owner: 501, mode: 0o100600, expectedOwner: 501, kind: .lockFile))
        #expect(!ProfileFilesystemAdmission.allows(owner: 501, mode: 0o100644, expectedOwner: 501, kind: .lockFile))
        #expect(!ProfileFilesystemAdmission.allows(owner: 501, mode: 0o100600, expectedOwner: 501, kind: .lockFile, links: 2))
        #expect(!ProfileFilesystemAdmission.allows(owner: 501, mode: 0o100600, expectedOwner: 501, kind: .lockFile, size: 1))
        #expect(ProfileFilesystemAdmission.sameIdentity(device: 1, inode: 2, generation: 3, expectedDevice: 1, expectedInode: 2, expectedGeneration: 3))
        #expect(!ProfileFilesystemAdmission.sameIdentity(device: 1, inode: 9, generation: 3, expectedDevice: 1, expectedInode: 2, expectedGeneration: 3))
        #expect(!ProfileFilesystemAdmission.sameIdentity(device: 1, inode: 2, generation: 4, expectedDevice: 1, expectedInode: 2, expectedGeneration: 3))
    }
    @Test func activationDirectoryAdmissionUsesOnlyDisposableFixturesAndRejectsSymlinkedTargets() throws {
        let files = FileManager.default
        let fixture = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("profile-admission-fixture-" + UUID().uuidString)
        try files.createDirectory(at: fixture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: fixture) }
        // Foundation can preserve the /var spelling even after resolving it.
        // Resolve only this newly-created trusted fixture, never a profile path.
        let physicalPath = try #require(fixture.path.withCString { realpath($0, nil) })
        defer { free(physicalPath) }
        let physicalFixture = URL(fileURLWithPath: String(cString: physicalPath))
        let root = physicalFixture.appendingPathComponent("app"), outside = physicalFixture.appendingPathComponent("unrelated")
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try files.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(throws: AppProfileError.missingStore) { try ProfileSafeDirectories.admitProfile(root: root, id: deletionID, creating: false) }
        try ProfileSafeDirectories.admitProfile(root: root, id: deletionID, creating: true)
        let target = root.appendingPathComponent("Profiles/" + deletionID)
        let opaque = target.appendingPathComponent("future.data")
        try Data([1, 2, 3]).write(to: opaque)
        try ProfileSafeDirectories.admitProfile(root: root, id: deletionID, creating: false)
        #expect(try Data(contentsOf: opaque) == Data([1, 2, 3]))
        // Fixture removal only; neither helper invokes production cleanup.
        try files.removeItem(at: target)
        try files.createSymbolicLink(at: target, withDestinationURL: outside)
        #expect(throws: ProfileCleanupProblem.unsafePath) { try ProfileSafeDirectories.admitProfile(root: root, id: deletionID, creating: false) }
        #expect(throws: ProfileCleanupProblem.unsafePath) { try ProfileSafeDirectories.admitProfile(root: root, id: deletionID, creating: true) }
        #expect(try files.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    @Test func rootURLScopeRejectsRemoteAndEncodedNulButKeepsLiteralPercentNames() {
        #expect(!ProfileSafeDirectories.isSafeRoot(URL(string: "file://remote.invalid/root")!))
        #expect(!ProfileSafeDirectories.isSafeRoot(URL(string: "file:///root/%00bad")!))
        #expect(!ProfileSafeDirectories.isSafeRoot(URL(string: "https://example.invalid/root")!))
        #expect(ProfileSafeDirectories.isSafeRoot(URL(fileURLWithPath: "/fixture/literal%00root")))
    }
    @Test func processInventoryAdmissionBlocksOlderSameBundleOrUnbundledExecutableWithoutEnumeratingProcesses() {
        let own = ProfileProcessEntry(pid: 1, bundle: "example.app", executable: "Player")
        #expect(ProfileProcessAdmission.allows([own], ownPID: 1, bundle: "example.app", executable: "Player"))
        #expect(!ProfileProcessAdmission.allows([own, .init(pid: 2, bundle: "example.app", executable: "Older")], ownPID: 1, bundle: "example.app", executable: "Player"))
        #expect(!ProfileProcessAdmission.allows([own, .init(pid: 2, bundle: nil, executable: "Player")], ownPID: 1, bundle: "example.app", executable: "Player"))
        #expect(ProfileProcessAdmission.allows([own, .init(pid: 2, bundle: "different.app", executable: "Player")], ownPID: 1, bundle: "example.app", executable: "Player"))
    }
    @Test func stoppingAnAcceptedStepWaitsForReceiptAndLeavesRemainingStepsPending() async throws {
        let f = try DeletionFixture(), gate = DeletionTestGate()
        f.session.beforeEffect = { _ in await gate.wait() }
        await f.prepare()
        let review = try #require(f.controller.review)
        let operation = Task { await f.controller.confirm(reviewID: review.id) }
        while !gate.waiting { await Task.yield() }
        var stopped = false
        let stopping = Task { await f.controller.stopAndWait(); stopped = true }
        for _ in 0..<10 { await Task.yield() }
        #expect(!stopped)
        gate.open(); await operation.value; await stopping.value
        #expect(stopped && f.session.closed)
        #expect(f.session.effects == [.website])
        #expect(try await f.registry.load().archive.deletions.first?.states[1] == .pending)
    }
    @Test func ownerQuitRevokesCurrentRuntimeBeforeWaitingForAcceptedCleanupReceipt() async throws {
        let f = try DeletionFixture(), gate = DeletionTestGate(), runtime = DeletionFakeRuntime()
        let owner = AppProfileOwner(initial: runtime, registry: f.registry, prepare: { _, _ in
            PreparedAppProfile { DeletionFakeRuntime() }
        }, bind: { _, _ in })
        await owner.start(); owner.installDeletionAdapter(f.adapter)
        let deletion = try #require(owner.deletion), activation = owner.activationID
        await deletion.prepare(id: deletionID, activeID: AppProfile.defaultID) { owner.accepts(activation) }
        f.session.beforeEffect = { _ in await gate.wait() }
        let review = try #require(deletion.review)
        let cleaning = Task { await deletion.confirm(reviewID: review.id) }
        while !gate.waiting { await Task.yield() }
        var stopped = false
        let quitting = Task { await owner.shutdown(); stopped = true }
        while !runtime.quiesced { await Task.yield() }
        #expect(!stopped && !runtime.shutDown)
        #expect(!owner.accepts(activation))
        gate.open(); await cleaning.value; await quitting.value
        #expect(stopped && runtime.shutDown && f.session.closed)
        #expect(f.session.effects == [.website])
    }
    @Test func scalarPreferenceReviewPreservesUnknownVersionedAndWrongTypedData() {
        #expect(ProfilePreferenceCleanup.accepts(["volume": 0.7, "autoplay": false, "appearance": "system", "nativeControlAccent": "teal"]))
        #expect(!ProfilePreferenceCleanup.accepts(["futureVersion": 99]))
        #expect(!ProfilePreferenceCleanup.accepts(["volume": true]))
        #expect(!ProfilePreferenceCleanup.accepts(["autoplay": 1]))
        #expect(!ProfilePreferenceCleanup.accepts(["appearance": "future"]))
        #expect(!ProfilePreferenceCleanup.accepts(["nativeControlAccent": "future"]))
        #expect(!ProfilePreferenceCleanup.accepts(["opaque": Data([0])]))
        #expect(ProfilePreferenceCleanup.accepts(["onDeviceCommandInterpretationEnabled": true]))
        #expect(!ProfilePreferenceCleanup.accepts(["onDeviceCommandInterpretationEnabled": 1]))
    }
    @Test func populatedFilesHaveDurableRunningMarkersAndIndependentOutcomes() async throws {
        let f = try DeletionFixture(); f.session.manifest = metadataManifestFixture()
        f.session.existingMetadata = ["queue.json", "LocalAudio/library.json"]
        f.session.verifyMetadataMarker = {
            guard let data = f.io.bytes, let archive = try? JSONDecoder().decode(AppProfileArchive.self, from: data),
                  let manifest = archive.deletions.first?.metadata else { return false }
            return manifest.files.contains { $0.state == .running }
        }
        await f.prepare(); await f.confirm()
        #expect(f.session.metadataEffects == ["queue.json", "LocalAudio/library.json"])
        #expect(try await f.registry.load().archive.profiles == [.original])
    }
    @Test func uncertainMetadataRemovalReconcilesAbsenceWithoutRepeatingUnlink() async throws {
        let f = try DeletionFixture(); f.session.manifest = metadataManifestFixture()
        f.session.existingMetadata = ["queue.json", "LocalAudio/library.json"]
        f.session.verifyMetadataMarker = { true }; f.session.loseMetadataReceipt = true
        await f.prepare(); await f.confirm()
        let pending = try #require(try await f.registry.load().archive.deletions.first)
        #expect(pending.version == 2 && pending.metadata?.files[0].state == .uncertain)
        f.session.loseMetadataReceipt = false
        await f.prepare(); await f.confirm()
        #expect(f.session.metadataEffects.filter { $0 == "queue.json" }.count == 1)
        #expect(try await f.registry.load().archive.profiles == [.original])
    }
    @Test func unknownAdditionAfterRunningCheckpointBlocksAllFurtherMetadataEffects() async throws {
        let f = try DeletionFixture(); f.session.manifest = metadataManifestFixture()
        f.session.existingMetadata = ["queue.json", "LocalAudio/library.json"]
        f.session.verifyMetadataMarker = { true }
        f.session.blocksRunningMetadata = true
        await f.prepare(); await f.confirm()
        #expect(f.session.metadataEffects.isEmpty)
        #expect(try await f.registry.load().archive.profiles.contains(f.target))
    }
    @Test func completedMetadataReappearingCannotBeAcceptedByARepeatedReview() async throws {
        let f = try DeletionFixture(); var manifest = metadataManifestFixture()
        manifest.files[0].state = .complete; f.session.manifest = manifest
        f.session.existingMetadata = ["queue.json"]
        await f.prepare(); await f.confirm()
        #expect(f.session.effects.isEmpty && f.session.metadataEffects.isEmpty)
    }
    @Test func duplicateRegistryVersionCannotHideFutureDataOrStartCleanup() async throws {
        let f = try DeletionFixture()
        let encoded = try JSONEncoder().encode(AppProfileArchive.original)
        let text = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":99,\"version\":1")
        let duplicate = Data(text.utf8); f.io.force(duplicate)
        await f.prepare()
        #expect(f.adapter.calls == 0 && f.io.writes == 0 && f.io.bytes == duplicate)
    }
    @Test func futureProofForAnAlreadyAbsentFilePreventsEveryCleanupEffect() async throws {
        let f = try DeletionFixture(); var manifest = metadataManifestFixture()
        let old = manifest.files[0]
        manifest.files[0] = .init(path: old.path, identity: old.identity, digest: old.digest, schema: .init(version: 99, revision: nil))
        let journal = ProfileDeletionJournal(target: f.target).withMetadata(manifest)
        let bytes = try JSONEncoder().encode(AppProfileArchive(version: 2, selectedID: AppProfile.defaultID, profiles: [.original, f.target], deletions: [journal]))
        f.io.force(bytes); f.session.manifest = manifest; f.session.existingMetadata = []
        await f.prepare(); await f.confirm()
        #expect(f.adapter.calls == 0 && f.session.effects.isEmpty && f.session.metadataEffects.isEmpty)
        #expect(f.io.writes == 0 && f.io.bytes == bytes)
    }
    @Test func futureNestedProofForAnAbsentNamedQueuePreventsEveryCleanupEffect() async throws {
        let f = try DeletionFixture(); var manifest = metadataManifestFixture()
        let old = manifest.files[0]
        manifest.files[0] = .init(path: "SavedQueues/" + String(repeating: "a", count: 64) + "/queues.json", identity: old.identity, digest: old.digest,
            schema: .init(version: 1, revision: nil, versionTags: ["version": 1, "queues[].snapshot.version": 3]))
        let journal = ProfileDeletionJournal(target: f.target).withMetadata(manifest)
        let bytes = try JSONEncoder().encode(AppProfileArchive(version: 2, selectedID: AppProfile.defaultID, profiles: [.original, f.target], deletions: [journal]))
        f.io.force(bytes); f.session.manifest = manifest; f.session.existingMetadata = []
        await f.prepare(); await f.confirm()
        #expect(f.adapter.calls == 0 && f.session.effects.isEmpty && f.session.metadataEffects.isEmpty)
        #expect(f.io.writes == 0 && f.io.bytes == bytes)
    }
    @Test func metadataManifestAndOldJournalsRejectFutureNestedFieldsWithoutRewriting() throws {
        let target = try deletionProfile(), legacy = ProfileDeletionJournal(target: target)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        #expect(try decoder.decode(ProfileDeletionJournal.self, from: encoder.encode(legacy)) == legacy)
        var legacyObject = try JSONSerialization.jsonObject(with: encoder.encode(legacy)) as! [String: Any]
        legacyObject["metadata"] = NSNull()
        #expect(throws: (any Error).self) { try decoder.decode(ProfileDeletionJournal.self, from: JSONSerialization.data(withJSONObject: legacyObject)) }
        let modern = legacy.withMetadata(metadataManifestFixture())
        #expect(try decoder.decode(ProfileDeletionJournal.self, from: encoder.encode(modern)) == modern)
        var object = try JSONSerialization.jsonObject(with: encoder.encode(modern)) as! [String: Any]
        var manifest = object["metadata"] as! [String: Any]
        var files = manifest["files"] as! [[String: Any]]
        files[0]["future"] = true; manifest["files"] = files; object["metadata"] = manifest
        #expect(throws: (any Error).self) { try decoder.decode(ProfileDeletionJournal.self, from: JSONSerialization.data(withJSONObject: object)) }
        object["version"] = 99
        #expect(throws: (any Error).self) { try decoder.decode(ProfileDeletionJournal.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

}

private let deletionID = "11111111-1111-4111-8111-111111111111"
private func deletionProfile() throws -> AppProfile {
    var target = try AppProfile.additional(name: "Additional", identifier: UUID(uuidString: deletionID)!)
    target.isInitialized = true; return target
}
private final class DeletionMemoryIO: AppProfileRegistryIO, @unchecked Sendable {
    let lock = NSLock()
    private var data: Data?
    private var count = 0, durable = 0, fails = false
    private var callback: (@Sendable (Int) -> Void)?
    init(_ data: Data) { self.data = data }
    var bytes: Data? { lock.withLock { data } }
    var writes: Int { lock.withLock { count } }
    var durableWrites: Int { lock.withLock { durable } }
    var failDurableAfterReplace: Bool { get { lock.withLock { fails } } set { lock.withLock { fails = newValue } } }
    var afterDurableWrite: (@Sendable (Int) -> Void)? { get { lock.withLock { callback } } set { lock.withLock { callback = newValue } } }
    func force(_ bytes: Data) { lock.withLock { data = bytes } }
    func read() throws -> Data? { bytes }
    func replace(_ data: Data, expected: Data?) throws {
        try lock.withLock { guard self.data == expected else { throw AppProfileError.stale }; self.data = data; count += 1 }
    }
    func replaceDurably(_ data: Data, expected: Data?) throws {
        try replace(data, expected: expected)
        let (number, callback) = try lock.withLock {
            durable += 1
            if fails { throw AppProfileError.unavailable }
            return (durable, self.callback)
        }
        callback?(number)
    }
}
@MainActor private final class DeletionFakeCleanup: ProfileMetadataCleaning {
    var present = Set(ProfileCleanupStep.allCases)
    var manifest: ProfileMetadataManifest?
    var existingMetadata = Set<String>()
    var metadataEffects: [String] = []
    var loseMetadataReceipt = false
    var unknownMetadata = false
    var blocksRunningMetadata = false
    var verifyMetadataMarker: (() -> Bool)?
    func reviewMetadata(recovering: ProfileMetadataManifest?) async throws -> ProfileMetadataManifest? {
        if let recovering { manifest = recovering }
        if let manifest { try await validateMetadata(manifest) }
        return manifest
    }
    func validateMetadata(_ manifest: ProfileMetadataManifest) async throws {
        guard !unknownMetadata, !(blocksRunningMetadata && manifest.files.contains(where: { $0.state == .running })), !manifest.files.contains(where: { $0.state == .complete && existingMetadata.contains($0.path) }) else { throw ProfileCleanupProblem.savedData }
        self.manifest = manifest
    }
    func metadataFileIsPresent(_ file: ProfileMetadataFile, manifest: ProfileMetadataManifest) async throws -> Bool {
        try await validateMetadata(manifest); return existingMetadata.contains(file.path)
    }
    func removeMetadataFile(_ file: ProfileMetadataFile, manifest: ProfileMetadataManifest) async throws {
        try await validateMetadata(manifest)
        #expect(verifyMetadataMarker?() == true)
        metadataEffects.append(file.path); existingMetadata.remove(file.path)
        if loseMetadataReceipt { throw ProfileCleanupProblem.unavailable }
    }
    func finishMetadata(_ manifest: ProfileMetadataManifest) async throws {
        try await validateMetadata(manifest)
        guard existingMetadata.isEmpty else { throw ProfileCleanupProblem.savedData }
        present.remove(.directory)
    }
    var blocked: (ProfileCleanupStep, ProfileCleanupProblem)?
    var loseReceipt: ProfileCleanupStep?
    var effects: [ProfileCleanupStep] = [], probes: [ProfileCleanupStep] = []
    var closed = false
    var blockWhenRevoked: DeletionAdmission?
    var beforeEffect: ((ProfileCleanupStep) async throws -> Void)?
    func probe(_ step: ProfileCleanupStep, state: ProfileCleanupState) async -> ProfileCleanupProbe {
        probes.append(step)
        if step == .directory, let manifest {
            do { try await validateMetadata(manifest) } catch { return .blocked(.savedData) }
        }
        if step == .directory, blockWhenRevoked?.current == false { return .blocked(.savedData) }
        if let blocked, blocked.0 == step { return .blocked(blocked.1) }
        if step == .spotlight, state == .running || state == .uncertain { return .blocked(.uncertainIndex) }
        return present.contains(step) ? .ready : .absent
    }
    func remove(_ step: ProfileCleanupStep) async throws {
        try await beforeEffect?(step)
        effects.append(step); present.remove(step)
        if loseReceipt == step { throw ProfileCleanupProblem.unavailable }
    }
    func close() { closed = true }
}
@MainActor private final class DeletionFakeAdapter: ProfileCleanupPreparing {
    let session: DeletionFakeCleanup
    var calls = 0
    var failure: ProfileCleanupProblem?
    init(_ session: DeletionFakeCleanup) { self.session = session }
    func prepare(_ target: AppProfile) async throws -> any ProfileCleanupSession {
        calls += 1
        if let failure { throw failure }
        session.closed = false; return session
    }
}
@MainActor private final class DeletionFixture {
    let target: AppProfile
    let io: DeletionMemoryIO
    let registry: AppProfileRegistryStore
    let session = DeletionFakeCleanup()
    let adapter: DeletionFakeAdapter
    var controller: AppProfileDeletionController!
    var current = true
    init(selected: String = AppProfile.defaultID) throws {
        target = try deletionProfile()
        io = DeletionMemoryIO(try JSONEncoder().encode(AppProfileArchive(version: 1, selectedID: selected, profiles: [.original, target])))
        registry = AppProfileRegistryStore(io: io)
        adapter = DeletionFakeAdapter(session)
        controller = AppProfileDeletionController(registry: registry, adapter: adapter, changed: { _ in })
    }
    func prepare() async { await controller.prepare(id: deletionID, activeID: AppProfile.defaultID) { [weak self] in self?.current == true } }
    func confirm() async { if let review = controller.review { await controller.confirm(reviewID: review.id) } }
    func confirmStaging() async { session.blocked = (.directory, .savedData); await prepare(); await confirm() }
}
@MainActor private final class DeletionFakeRuntime: AppProfileRuntime {
    var profile: AppProfile = .original
    var quiesced = false, shutDown = false
    func quiesce() { quiesced = true }
    func settle() async -> PlaybackOutputSettlement { .quiet }
    func resumePausedOwnership() {}
    func shutdown() async { shutDown = true }
    func startPaused() async {}
}
@MainActor private final class DeletionTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { let old = continuation; continuation = nil; old?.resume() }
}

private final class DeletionAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var current: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

private func metadataManifestFixture() -> ProfileMetadataManifest {
    func identity(_ mode: UInt16, inode: UInt64) -> ProfileMetadataIdentity {
        .init(device: 1, inode: inode, generation: 1, owner: 501, mode: mode, links: 1, size: mode == 0o100600 ? 10 : 0,
              modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0)
    }
    return .init(files: ["queue.json", "LocalAudio/library.json"].enumerated().map { index, path in
        .init(path: path, identity: identity(0o100600, inode: UInt64(index + 1)), digest: Data(repeating: 1, count: 32), schema: .init(version: path == "queue.json" ? 2 : 1, revision: path == "queue.json" ? nil : UUID()))
    }, folders: [.init(path: "", identity: identity(0o040700, inode: 3)), .init(path: "LocalAudio", identity: identity(0o040700, inode: 4))])
}
