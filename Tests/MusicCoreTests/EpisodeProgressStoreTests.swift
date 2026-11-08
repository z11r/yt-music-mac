import Foundation
import Testing
@testable import MusicCore

struct EpisodeProgressStoreTests {
    private let firstHash = String(repeating: "a", count: 64)
    private let secondHash = String(repeating: "b", count: 64)

    @Test func accountFilesRoundTripAtomicallyAndStayIndependent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpisodeProgressStore(directory: directory)
        let first = snapshot(firstHash, position: 10)
        let second = snapshot(secondHash, position: 20)
        try await store.save(first)
        try await store.save(second)
        try await store.save(snapshot(firstHash, position: 30))
        #expect(try await store.load(accountHash: firstHash)?.records.first?.position == 30)
        #expect(try await store.load(accountHash: secondHash) == second)
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(contents.count == 2)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(firstHash + ".json").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try await store.clear(accountHash: firstHash)
        #expect(try await store.load(accountHash: firstHash) == nil)
        #expect(try await store.load(accountHash: secondHash) == second)
    }

    @Test func malformedNewerAndWrongAccountDocumentsAreRetained() async throws {
        for data in [Data("{malformed".utf8), try JSONEncoder().encode(EpisodeProgressSnapshot(version: 2, accountHash: firstHash, records: [])),
                     try JSONEncoder().encode(snapshot(secondHash, position: 10))] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(firstHash + ".json")
            try data.write(to: file)
            let store = EpisodeProgressStore(directory: directory)
            await #expect(throws: (any Error).self) { _ = try await store.load(accountHash: firstHash) }
            await #expect(throws: (any Error).self) { try await store.save(snapshot(firstHash, position: 50)) }
            #expect(try Data(contentsOf: file) == data)
        }
    }

    @Test func invalidRecordsNeverReplaceConfirmedProgress() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpisodeProgressStore(directory: directory)
        let original = snapshot(firstHash, position: 100)
        try await store.save(original)
        let episode = EpisodeIdentity(browseID: "MPEDcanonical")
        let invalid: [EpisodeProgressSnapshot] = [
            snapshot(firstHash, position: 0), snapshot(firstHash, position: -.infinity), snapshot(firstHash, position: 4_000),
            EpisodeProgressSnapshot(accountHash: firstHash, records: [record(episode, position: 10), record(episode, position: 20)]),
            EpisodeProgressSnapshot(accountHash: firstHash, records: [record(.init(browseID: "video-only"), position: 10)]),
            EpisodeProgressSnapshot(accountHash: firstHash, records: [], settings: .init(skipBackward: .nan)),
        ]
        for value in invalid { await #expect(throws: EpisodeProgressError.invalidSnapshot) { try await store.save(value) } }
        #expect(try await store.load(accountHash: firstHash) == original)
    }

    @Test func storageAndRecordCountsAreBoundedBeforeWriting() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tiny = EpisodeProgressStore(directory: directory, maximumFileSize: 8)
        await #expect(throws: EpisodeProgressError.fileTooLarge) { try await tiny.save(snapshot(firstHash, position: 10)) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let records = (0...2_000).map { record(.init(browseID: "MPEDepisode-\($0)"), position: 10) }
        let store = EpisodeProgressStore(directory: directory)
        await #expect(throws: EpisodeProgressError.invalidSnapshot) { try await store.save(.init(accountHash: firstHash, records: records)) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 9).write(to: directory.appendingPathComponent(firstHash + ".json"))
        await #expect(throws: EpisodeProgressError.fileTooLarge) { _ = try await tiny.load(accountHash: firstHash) }
    }

    @Test func invalidScopeAndRemoteStorageNeverTouchFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpisodeProgressStore(directory: directory)
        await #expect(throws: EpisodeProgressError.invalidSnapshot) { _ = try await store.load(accountHash: "../account") }
        let remote = EpisodeProgressStore(directory: URL(string: "https://example.com/progress")!)
        await #expect(throws: EpisodeProgressError.invalidStorageURL) { _ = try await remote.load(accountHash: firstHash) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("EpisodeProgressStore-\(UUID().uuidString)", isDirectory: true) }
    private func snapshot(_ hash: String, position: TimeInterval) -> EpisodeProgressSnapshot {
        EpisodeProgressSnapshot(accountHash: hash, records: [record(.init(browseID: "MPEDcanonical", showBrowseID: "MPSPPLshow"), position: position)])
    }
    private func record(_ identity: EpisodeIdentity, position: TimeInterval) -> EpisodeProgressRecord {
        .init(episode: identity, position: position, duration: 3_600, completed: false, updatedAt: Date(timeIntervalSince1970: 1_000))
    }
}
