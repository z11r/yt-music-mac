import Darwin
import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@MainActor struct ProfileMetadataCleanupTests {
    @Test func cleanupScopeAndPendingRecoveryCopyHaveEnglishAndFrenchResources() throws {
        for language in ["en", "fr"] {
            let url = try #require(AppLocalization.bundle.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: url))
            for key in ["Recognized Metadata Files", "Confirmed Metadata Removals", "Only validated app metadata is removed. Local audio files and bookmark targets remain untouched.", "Unrecognized, changed, or unresolved saved data is retained. Review the supported formats before trying cleanup again."] {
                let value = bundle.localizedString(forKey: key, value: "MISSING", table: "Localizable")
                #expect(value != "MISSING" && !value.isEmpty)
                if language == "fr" { #expect(value != key) }
            }
        }
    }
    @Test func malformedOversizeAndExplicitUnsupportedLegacyArchivesAreRetained() throws {
        for value in [Data("malformed".utf8), Data(repeating: 32, count: (4 << 20) + 1), Data(#"{"version":1,"entries":[],"repeatMode":"off","isShuffled":false,"unshuffledOrder":[],"resumePosition":0}"#.utf8)] {
            #expect(throws: (any Error).self) { try ProfileMetadataSchema.validate(value, path: "queue.json", profileID: metadataProfile) }
        }
        let tooDeep = Data((String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34)).utf8)
        #expect(throws: (any Error).self) { try ProfileMetadataSchema.validate(tooDeep, path: "queue.json", profileID: metadataProfile) }
    }
    @Test func manifestBoundsAndIndependentDigestRevisionChecksArePure() throws {
        let identity = ProfileMetadataIdentity(device: 1, inode: 1, generation: 1, owner: 501, mode: 0o100600,
            links: 1, size: 0, modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0)
        let folder = ProfileMetadataIdentity(device: 1, inode: 2, generation: 1, owner: 501, mode: 0o040700,
            links: 1, size: 0, modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0)
        let file = ProfileMetadataFile(path: "LocalAudio/library.json", identity: identity, digest: Data(repeating: 1, count: 32), schema: .init(version: 1, revision: UUID()))
        let manifest = ProfileMetadataManifest(files: [file], folders: [.init(path: "", identity: folder), .init(path: "LocalAudio", identity: folder)])
        try manifest.validate()
        let changedDigest = ProfileMetadataFile(path: file.path, identity: identity, digest: Data(repeating: 2, count: 32), schema: file.schema)
        #expect(!manifest.accepts(.init(files: [changedDigest], folders: manifest.folders)))
        let changedRevision = ProfileMetadataFile(path: file.path, identity: identity, digest: file.digest, schema: .init(version: 1, revision: UUID()))
        #expect(!manifest.accepts(.init(files: [changedRevision], folders: manifest.folders)))
        let tooMany = ProfileMetadataManifest(files: (0..<65).map { value in
            .init(path: "episode-progress/" + String(format: "%064x", value) + ".json", identity: identity, digest: file.digest, schema: .init(version: 1, revision: nil))
        }, folders: manifest.folders)
        #expect(throws: (any Error).self) { try tooMany.validate() }
    }
    @Test func nestedQueueLegacyVersionCannotBeNormalizedIntoCleanupAdmission() throws {
        let snapshot = QueueSnapshot(entries: [])
        let queue = NamedQueue(name: "Fixture", createdAt: Date(timeIntervalSinceReferenceDate: 1), updatedAt: Date(timeIntervalSinceReferenceDate: 1), snapshot: snapshot)
        var row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as! [String: Any]
        var nested = row["snapshot"] as! [String: Any]; nested["version"] = 1; row["snapshot"] = nested
        let raw = try JSONSerialization.data(withJSONObject: ["version": 1, "queues": [row]])
        let retained = raw
        #expect(throws: (any Error).self) { try ProfileMetadataSchema.validate(raw, path: "SavedQueues/" + metadataAccount + "/queues.json", profileID: metadataProfile) }
        #expect(raw == retained)
    }
    @Test func explicitDiscriminatorCannotNormalizeButOmittedDefaultsAndUUIDCaseRemainSupported() throws {
        let value = QueueSnapshot(entries: [.init(track: .init(id: "fixture", title: "Fixture", artist: "Artist"))])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        var entries = object["entries"] as! [[String: Any]]
        entries[0]["origin"] = NSNull(); object["entries"] = entries
        #expect(throws: (any Error).self) { try ProfileMetadataSchema.validate(JSONSerialization.data(withJSONObject: object), path: "queue.json", profileID: metadataProfile) }
        entries[0].removeValue(forKey: "origin")
        entries[0]["id"] = (entries[0]["id"] as! String).lowercased(); object["entries"] = entries
        _ = try ProfileMetadataSchema.validate(JSONSerialization.data(withJSONObject: object), path: "queue.json", profileID: metadataProfile)
    }
    @Test func absentFileProofsRequireTheExactSupportedVersionAndRevisionContract() throws {
        let folder = ProfileMetadataIdentity(device: 1, inode: 2, generation: 1, owner: 501, mode: 0o040700,
            links: 1, size: 0, modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0)
        for (path, bytes) in try metadataArchives() {
            let proof = try ProfileMetadataSchema.validate(bytes, path: path, profileID: metadataProfile)
            let identity = ProfileMetadataIdentity(device: 1, inode: 1, generation: 1, owner: 501, mode: 0o100600,
                links: 1, size: Int64(bytes.count), modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0)
            func manifest(_ proof: ProfileMetadataSchemaProof) -> ProfileMetadataManifest {
                .init(files: [.init(path: path, identity: identity, digest: Data(repeating: 1, count: 32), schema: proof)], folders: [.init(path: "", identity: folder)])
            }
            try manifest(proof).validate()
            let future = manifest(.init(version: 99, revision: proof.revision))
            #expect(throws: (any Error).self) { try future.validate() }
            let unexpectedRevision = manifest(.init(version: proof.version, revision: proof.revision == nil ? UUID() : nil))
            #expect(throws: (any Error).self) { try unexpectedRevision.validate() }
        }
    }
    @Test func observedNestedVersionTagsArePersistedWithoutPerRowGrowth() throws {
        let libraryBytes = try metadataArchives()["LocalAudio/library.json"]!
        let library = try JSONDecoder().decode(LocalAudioLibraryDocument.self, from: libraryBytes)
        let record = try #require(library.records.first)
        let track = try record.metadata.track(reference: record.reference)
        let snapshot = QueueSnapshot(entries: [.init(track: track)])
        let direct = try ProfileMetadataSchema.validate(JSONEncoder().encode(snapshot), path: "queue.json", profileID: metadataProfile)
        #expect(direct.versionTags == ["version": 2, "entries[].track.localAudioReference.version": 1])
        let local = try ProfileMetadataSchema.validate(libraryBytes, path: "LocalAudio/library.json", profileID: metadataProfile)
        #expect(local.versionTags == ["version": 1, "records[].reference.version": 1])
        let queues = (0..<50).map { value in NamedQueue(name: "Fixture " + String(value), createdAt: Date(timeIntervalSinceReferenceDate: 1), updatedAt: Date(timeIntervalSinceReferenceDate: 1), snapshot: snapshot) }
        let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode(queues))
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "queues": rows])
        let proof = try ProfileMetadataSchema.validate(bytes, path: "SavedQueues/" + metadataAccount + "/queues.json", profileID: metadataProfile)
        #expect(proof.versionTags == ["version": 1, "queues[].snapshot.version": 2, "queues[].snapshot.entries[].track.localAudioReference.version": 1])
        #expect(try JSONDecoder().decode(ProfileMetadataSchemaProof.self, from: JSONEncoder().encode(proof)) == proof)
        #expect(ProfileMetadataFormat.namedQueues.accepts(.init(version: 1, revision: nil, versionTags: ["version": 1, "queues[].snapshot.version": 3])) == false)
        #expect(ProfileMetadataFormat.namedQueues.accepts(.init(version: 1, revision: nil, versionTags: ["queues[].snapshot.version": 2])) == false)
        #expect(ProfileMetadataFormat.namedQueues.accepts(.init(version: 1, revision: nil, versionTags: ["version": 1, "unknown[].version": 1])) == false)
    }
    @Test func everyRecognizedCurrentFormatHasPureBoundedAdmission() throws {
        for (path, bytes) in try metadataArchives() {
            _ = try ProfileMetadataSchema.validate(bytes, path: path, profileID: metadataProfile)
            if !bytes.isEmpty {
                var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                object["future"] = true
                #expect(throws: (any Error).self) { try ProfileMetadataSchema.validate(JSONSerialization.data(withJSONObject: object), path: path, profileID: metadataProfile) }
                object.removeValue(forKey: "future"); object["version"] = 99
                #expect(throws: (any Error).self) { try ProfileMetadataSchema.validate(JSONSerialization.data(withJSONObject: object), path: path, profileID: metadataProfile) }
            }
        }
    }
    @Test func unknownNestedAndDuplicateKeysAndWrongNamespacesRemainUnsupported() throws {
        let queue = QueueSnapshot(entries: [.init(track: Track(id: "fixture", title: "Fixture", artist: "Artist"))])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as! [String: Any]
        var entries = object["entries"] as! [[String: Any]], track = entries[0]["track"] as! [String: Any]
        track["futureLocalLocation"] = "opaque"; entries[0]["track"] = track; object["entries"] = entries
        #expect(throws: (any Error).self) { try ProfileMetadataSchema.validate(JSONSerialization.data(withJSONObject: object), path: "queue.json", profileID: metadataProfile) }
        let duplicate = Data(#"{"version":2,"version":2,"entries":[]}"#.utf8)
        #expect(throws: (any Error).self) { try ProfileMetadataSchema.validate(duplicate, path: "queue.json", profileID: metadataProfile) }
        let local = try JSONEncoder().encode(LocalAudioLibraryDocument(profileID: UUID(), libraryID: UUID()))
        #expect(throws: (any Error).self) { try ProfileMetadataSchema.validate(local, path: "LocalAudio/library.json", profileID: metadataProfile) }
        let episode = try JSONEncoder().encode(EpisodeProgressSnapshot(accountHash: String(repeating: "b", count: 64), records: []))
        #expect(throws: (any Error).self) { try ProfileMetadataSchema.validate(episode, path: "episode-progress/" + metadataAccount + ".json", profileID: metadataProfile) }
        #expect(ProfileMetadataFormat.identify("../queue.json") == nil)
        #expect(ProfileMetadataFormat.identify("LocalAudio/audio.mp3") == nil)
        #expect(ProfileMetadataFormat.identify("SavedQueues/not-an-account/queues.json") == nil)
        #expect(throws: (any Error).self) { try ProfileMetadataSchema.validate(Data([1]), path: "LocalAudio/library.json.lock", profileID: metadataProfile) }
    }
    @Test func unresolvedExternalWriteRecoveryIsAlwaysRetained() throws {
        let plan = try QueuePlaylistPlan(title: "Fixture", createdAt: Date(timeIntervalSinceReferenceDate: 1), songs: [.init(id: UUID(), videoID: "abcDEF12_-3", title: "Song", artist: "Artist")])
        var value = QueuePlaylistPending(plan: plan, now: Date(timeIntervalSinceReferenceDate: 2))
        for phase in [QueuePlaylistPending.Phase.creating, .targetKnown, .batchPending] {
            value.phase = phase
            value.targetID = phase == .creating ? nil : "PLfixture"
            value.attemptedEnd = phase == .batchPending ? 1 : nil
            try value.validate()
            #expect(throws: (any Error).self) { try ProfileMetadataSchema.validate(JSONEncoder().encode(value), path: "PendingQueuePlaylists/" + metadataAccount + "/pending.json", profileID: metadataProfile) }
        }
    }
    @Test func disposableMetadataIsRemovedWithLockLastAndExternalAudioUntouched() async throws {
        let f = try MetadataDirectoryFixture(); defer { f.dispose() }
        let archives = try metadataArchives()
        try f.write(archives["queue.json"]!, path: "queue.json")
        try f.write(archives["LocalAudio/library.json"]!, path: "LocalAudio/library.json")
        try f.write(Data(), path: "LocalAudio/library.json.lock")
        let outside = f.base.appendingPathComponent("unrelated-audio.fixture")
        try Data([8, 9, 10]).write(to: outside)
        let directory = ProfileMetadataDirectory(root: f.root, profileID: metadataProfile.uuidString.lowercased())
        var manifest = try #require(try await directory.review(recovering: nil))
        #expect(manifest.files.last?.path == "LocalAudio/library.json.lock")
        for index in manifest.files.indices {
            manifest.files[index].state = .running
            try await directory.remove(manifest.files[index], manifest: manifest)
            manifest.files[index].state = .complete
        }
        try await directory.finish(manifest)
        #expect(try await !directory.exists())
        #expect(try Data(contentsOf: outside) == Data([8, 9, 10]))
    }
    @Test func replacementDigestUnknownAdditionAndReappearanceAreNotRemoved() async throws {
        let f = try MetadataDirectoryFixture(); defer { f.dispose() }
        let bytes = try metadataArchives()["queue.json"]!
        try f.write(bytes, path: "queue.json")
        let directory = ProfileMetadataDirectory(root: f.root, profileID: metadataProfile.uuidString.lowercased())
        var manifest = try #require(try await directory.review(recovering: nil))
        try f.write(Data([1]), path: "unknown.data")
        await #expect(throws: (any Error).self) { try await directory.validate(manifest) }
        try FileManager.default.removeItem(at: f.target.appendingPathComponent("unknown.data"))
        try bytes.write(to: f.target.appendingPathComponent("queue.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.target.appendingPathComponent("queue.json").path)
        await #expect(throws: (any Error).self) { try await directory.validate(manifest) }
        manifest = try #require(try await directory.review(recovering: nil))
        manifest.files[0].state = .running; try await directory.remove(manifest.files[0], manifest: manifest)
        manifest.files[0].state = .complete
        try f.write(bytes, path: "queue.json")
        await #expect(throws: (any Error).self) { try await directory.validate(manifest) }
        #expect(try Data(contentsOf: f.target.appendingPathComponent("queue.json")) == bytes)
    }
    @Test func replacedNestedDirectoryIsRejectedEvenWhenAllFilesAreAbsent() async throws {
        let f = try MetadataDirectoryFixture(); defer { f.dispose() }
        let original = f.target.appendingPathComponent("LocalAudio")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let directory = ProfileMetadataDirectory(root: f.root, profileID: metadataProfile.uuidString.lowercased())
        let manifest = try #require(try await directory.review(recovering: nil))
        try FileManager.default.moveItem(at: original, to: f.base.appendingPathComponent("old-metadata-folder"))
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        await #expect(throws: (any Error).self) { try await directory.finish(manifest) }
        #expect(FileManager.default.fileExists(atPath: original.path))
    }
    @Test func symlinkHardlinkAndHeldStoreLockBlockWithoutFollowingTargets() async throws {
        let f = try MetadataDirectoryFixture(); defer { f.dispose() }
        let bytes = try metadataArchives()["queue.json"]!, sentinel = f.base.appendingPathComponent("sentinel")
        try bytes.write(to: sentinel)
        let queue = f.target.appendingPathComponent("queue.json")
        try FileManager.default.createSymbolicLink(at: queue, withDestinationURL: sentinel)
        let directory = ProfileMetadataDirectory(root: f.root, profileID: metadataProfile.uuidString.lowercased())
        await #expect(throws: (any Error).self) { try await directory.review(recovering: nil) }
        try FileManager.default.removeItem(at: queue)
        try FileManager.default.linkItem(at: sentinel, to: queue)
        await #expect(throws: (any Error).self) { try await directory.review(recovering: nil) }
        try FileManager.default.removeItem(at: queue)
        try f.write(Data(), path: "LocalAudio/library.json.lock")
        let lock = Darwin.open(f.target.appendingPathComponent("LocalAudio/library.json.lock").path, O_RDWR | O_NOFOLLOW)
        #expect(lock >= 0); defer { _ = flock(lock, LOCK_UN); Darwin.close(lock) }
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: ProfileCleanupProblem.releaseRequired) { try await directory.review(recovering: nil) }
        #expect(try Data(contentsOf: sentinel) == bytes)
    }
    @Test func profileSharedLifetimeExcludesCleanupUntilSyntheticReaderEnds() throws {
        let f = try MetadataDirectoryFixture(); defer { f.dispose() }
        var reader: ProfileLifecycleLease? = try .init(root: f.root, profileID: metadataProfile.uuidString.lowercased(), exclusive: false)
        #expect(reader != nil)
        #expect(throws: ProfileCleanupProblem.releaseRequired) { _ = try ProfileLifecycleLease(root: f.root, profileID: metadataProfile.uuidString.lowercased(), exclusive: true) }
        reader = nil
        let cleanup = try ProfileLifecycleLease(root: f.root, profileID: metadataProfile.uuidString.lowercased(), exclusive: true)
        withExtendedLifetime(cleanup) { }
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("ProfileLocks/" + metadataProfile.uuidString.lowercased() + ".lock").path))
    }
}

private let metadataProfile = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let metadataAccount = String(repeating: "a", count: 64)
private func metadataArchives() throws -> [String: Data] {
    let e = JSONEncoder()
    let plan = try QueuePlaylistPlan(title: "Fixture", createdAt: Date(timeIntervalSinceReferenceDate: 1), songs: [.init(id: UUID(), videoID: "abcDEF12_-3", title: "Song", artist: "Artist")])
    let libraryID = UUID()
    let owned = LocalAudioReference(libraryID: libraryID, fileID: UUID())
    let record = LocalAudioLibraryRecord(reference: owned, metadata: .init(title: "Fixture", artist: "", duration: 10, byteCount: 1),
        identity: .init(volumeID: "synthetic", fileID: 1), bookmark: .init(mode: .ordinary, data: Data([1, 2, 3])))
    let populatedLibrary = LocalAudioLibraryDocument(profileID: metadataProfile, libraryID: libraryID, records: [record])
    return ["queue.json": try e.encode(QueueSnapshot(entries: [])),
            "SavedQueues/" + metadataAccount + "/queues.json": Data(#"{"version":1,"queues":[]}"#.utf8),
            "LocalCollections/" + metadataAccount + "/organization.json": try e.encode(LocalCollectionOrganization()),
            "MetadataCache/" + metadataAccount + "/library.json": try e.encode(LibraryMetadataSnapshot(capturedAt: Date(timeIntervalSinceReferenceDate: 1), collections: [])),
            "LocalSongRules/" + metadataAccount + "/song-rules.json": try e.encode(LocalSongRuleArchive()),
            "episode-progress/" + metadataAccount + ".json": try e.encode(EpisodeProgressSnapshot(accountHash: metadataAccount, records: [])),
            "listenbrainz/" + metadataAccount + ".json": try e.encode(ListenBrainzDocument(profile: metadataAccount)),
            "lastfm/" + metadataAccount + ".json": try e.encode(LastFMDocument(profile: metadataAccount)),
            "PendingQueuePlaylists/" + metadataAccount + "/pending.json": try e.encode(QueuePlaylistPending(plan: plan, now: Date(timeIntervalSinceReferenceDate: 2))),
            "PendingQueuePlaylists/" + metadataAccount + "/operation.lock": Data(),
            "LocalAudio/library.json": try e.encode(populatedLibrary),
            "LocalAudio/library.json.lock": Data()]
}
private struct MetadataDirectoryFixture {
    let base: URL
    let root: URL
    let target: URL
    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-cleanup-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Resolve only this newly created disposable fixture, never a user/profile path.
        let physical = try #require(temporary.path.withCString { realpath($0, nil) }); defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical)); root = base.appendingPathComponent("app")
        target = root.appendingPathComponent("Profiles/" + metadataProfile.uuidString.lowercased())
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func write(_ bytes: Data, path: String) throws {
        let destination = target.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    func dispose() { try? FileManager.default.removeItem(at: base) }
}
