import Foundation
import Testing
@testable import MusicCore

private struct SongRuleStoreFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SongRuleStoreTests-" + UUID().uuidString)
    let first = String(repeating: "a", count: 64)
    let second = String(repeating: "b", count: 64)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    var rule: LocalSongRule { LocalSongRule(name: "Songs", clauses: [LocalSongRuleClause(text: "Song")]) }
    var tracks: [Track] { [Track(id: "abcDEF12_-3", title: "Song", artist: "Artist"), Track(id: "abcDEF12_-3", title: "Song", artist: "Artist")] }
    func file(_ key: String) -> URL { directory.appendingPathComponent(key).appendingPathComponent("song-rules.json") }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: file(first).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file(first))
    }
}

@Suite("Account-scoped local song-rule storage")
struct LocalSongRuleStoreTests {
    @Test func rulesAndDatedIncompleteSourceSnapshotsRoundTripWithoutCollapsingSongs() async throws {
        let fixture = SongRuleStoreFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory, now: { fixture.date })
        let rule = fixture.rule
        try await store.save(rule, accountKey: fixture.first)
        let archive = try await store.capture(tracks: fixture.tracks, sourceName: "Loaded playlist", hasMorePages: true, wasLoading: true,
            unavailableCount: 3, hasUnsupportedContent: true, accountKey: fixture.first)
        let snapshot = try #require(archive.snapshot)
        #expect(snapshot.capturedAt == fixture.date && snapshot.hasMorePages && snapshot.wasLoading)
        #expect(snapshot.unavailableCount == 3 && snapshot.hasUnsupportedContent && snapshot.scope == .capturedLoadedSongs)
        #expect(snapshot.songs.count == 2 && Set(snapshot.songs.map(\.id)).count == 2)
        #expect(snapshot.songs.map(\.videoID) == fixture.tracks.map(\.id))
        #expect(try await store.load(accountKey: fixture.first) == archive)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file(fixture.first).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!String(decoding: try Data(contentsOf: fixture.file(fixture.first)), as: UTF8.self).contains(fixture.first))
    }

    @Test func accountsCannotListOrDeleteAnotherAccountsRulesAndInvalidKeysCreateNothing() async throws {
        let fixture = SongRuleStoreFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        let rule = fixture.rule
        try await store.save(rule, accountKey: fixture.first)
        #expect(try await store.load(accountKey: fixture.second).rules.isEmpty)
        await #expect(throws: LocalSongRuleError.notFound) { try await store.remove(id: rule.id, accountKey: fixture.second) }
        #expect(try await store.load(accountKey: fixture.first).rules == [rule])
        await #expect(throws: NamedQueueError.invalidAccount) { try await store.load(accountKey: "../other") }
    }

    @Test func editsAndDeletionPreserveTheSharedSourceUntilExplicitlyCleared() async throws {
        let fixture = SongRuleStoreFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        var rule = fixture.rule
        try await store.save(rule, accountKey: fixture.first)
        let captured = try await store.capture(tracks: fixture.tracks, sourceName: "Loaded songs", hasMorePages: false, wasLoading: false, accountKey: fixture.first)
        rule.name = " Renamed "
        let updated = try await store.save(rule, accountKey: fixture.first)
        #expect(updated.rules[0].name == "Renamed" && updated.rules[0].id == rule.id)
        #expect(updated.snapshot == captured.snapshot)
        let removed = try await store.remove(id: rule.id, accountKey: fixture.first)
        #expect(removed.rules.isEmpty && removed.snapshot == captured.snapshot)
        try await store.save(rule, accountKey: fixture.first)
        let cleared = try await store.clearSnapshot(accountKey: fixture.first)
        #expect(cleared.rules.count == 1 && cleared.snapshot == nil)
    }

    @Test func songRulesExcludeEpisodesAndPreserveKnownSongClassification() async throws {
        let fixture = SongRuleStoreFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        let song = Track(id: "abcDEF12_-3", title: "Song", artist: "Artist", contentKind: .song)
        let episode = Track(id: "xyzABC34_-5", title: "Episode", artist: "Show", contentKind: .podcastEpisode,
            episode: .init(identity: .init(browseID: "MPEDfixture")))
        let archive = try await store.capture(tracks: [episode, song], sourceName: "Mixed loaded page",
            hasMorePages: false, wasLoading: false, accountKey: fixture.first)
        #expect(archive.snapshot?.skippedCount == 1)
        #expect(archive.snapshot?.songs.map(\.track.contentKind) == [.song])
        let loaded = try await store.load(accountKey: fixture.first)
        #expect(loaded.snapshot?.songs.map(\.track.contentKind) == [.song])
    }

    @Test func captureBoundsLoadedRowsAndReportsSkippedUnplayableIdentities() async throws {
        let fixture = SongRuleStoreFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory, maximumSongs: 2)
        let archive = try await store.capture(tracks: fixture.tracks + [Track(id: "xyzABC34_-5", title: "Later", artist: "Artist")],
            sourceName: "Loaded songs", hasMorePages: false, wasLoading: false, accountKey: fixture.first)
        #expect(archive.snapshot?.songs.count == 2 && archive.snapshot?.isTruncated == true)
        let invalid = Track(id: "file:///private", title: "Invalid", artist: "Artist")
        let skipped = try await store.capture(tracks: [invalid, fixture.tracks[0]], sourceName: "Loaded songs",
            hasMorePages: false, wasLoading: false, accountKey: fixture.first)
        #expect(skipped.snapshot?.skippedCount == 1 && skipped.snapshot?.songs.count == 1)
        #expect(skipped.snapshot?.songs.first?.videoID == fixture.tracks[0].id)
    }

    @Test func malformedFutureAndOversizedFilesCannotBeOverwrittenByAnyEdit() async throws {
        let fixture = SongRuleStoreFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory, maximumBytes: 1_024)
        for bytes in [Data("broken".utf8), Data("{\"version\":99}".utf8), Data(repeating: 32, count: 1_025)] {
            try fixture.write(bytes)
            await #expect(throws: (any Error).self) { try await store.save(fixture.rule, accountKey: fixture.first) }
            await #expect(throws: (any Error).self) { try await store.capture(tracks: fixture.tracks, sourceName: "Loaded songs", hasMorePages: false, wasLoading: false, accountKey: fixture.first) }
            await #expect(throws: (any Error).self) { try await store.clearSnapshot(accountKey: fixture.first) }
            #expect(try Data(contentsOf: fixture.file(fixture.first)) == bytes)
        }
    }

    @Test func unsupportedFieldsOperatorsAndSnapshotScopesKeepTheOriginalArchive() async throws {
        let fixture = SongRuleStoreFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        let valid = try await store.save(fixture.rule, accountKey: fixture.first)
        let base = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        var documents: [[String: Any]] = []
        var extra = base; extra["futureFeature"] = true; documents.append(extra)
        for (key, value) in [("field", "genre"), ("operation", "playCountAtLeast"), ("futureCondition", "unsupported")] {
            var document = base
            var rules = try #require(document["rules"] as? [[String: Any]])
            var clauses = try #require(rules[0]["clauses"] as? [[String: Any]])
            clauses[0][key] = value; rules[0]["clauses"] = clauses; document["rules"] = rules; documents.append(document)
        }
        let snapshot = LocalSongRuleSnapshot(capturedAt: fixture.date, sourceName: "Loaded", songs: [LocalSongRuleSong(track: fixture.tracks[0])])
        var scoped = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalSongRuleArchive(snapshot: snapshot))) as? [String: Any])
        var source = try #require(scoped["snapshot"] as? [String: Any]); source["scope"] = "entireServiceLibrary"; scoped["snapshot"] = source; documents.append(scoped)
        for document in documents {
            let bytes = try JSONSerialization.data(withJSONObject: document)
            try fixture.write(bytes)
            await #expect(throws: (any Error).self) { try await store.save(fixture.rule, accountKey: fixture.first) }
            #expect(try Data(contentsOf: fixture.file(fixture.first)) == bytes)
        }
    }

    @Test func invalidRuleValuesAndCapacityFailuresPreserveThePreviousFile() async throws {
        let fixture = SongRuleStoreFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory, maximumRules: 1)
        let rule = fixture.rule
        try await store.save(rule, accountKey: fixture.first)
        let original = try Data(contentsOf: fixture.file(fixture.first))
        await #expect(throws: LocalSongRuleError.capacityReached) {
            try await store.save(LocalSongRule(name: "Another", clauses: rule.clauses), accountKey: fixture.first)
        }
        let roomy = LocalSongRuleStore(directoryURL: fixture.directory)
        await #expect(throws: LocalSongRuleError.duplicateName) { try await roomy.save(LocalSongRule(name: "songs", clauses: rule.clauses), accountKey: fixture.first) }
        var badRules = [LocalSongRule(id: rule.id, name: " ", clauses: rule.clauses),
                        LocalSongRule(id: rule.id, name: "Rule", clauses: []),
                        LocalSongRule(id: rule.id, name: "Rule", clauses: [LocalSongRuleClause(field: .duration, operation: .contains, text: "x")]),
                        LocalSongRule(id: rule.id, name: "Rule", clauses: [LocalSongRuleClause(field: .explicit, operation: .isFalse, text: "ignored")]),
                        LocalSongRule(id: rule.id, name: "Rule", clauses: Array(repeating: rule.clauses[0], count: 13))]
        for number in [-1.0, Double.infinity, 604_801] {
            badRules.append(LocalSongRule(id: rule.id, name: "Rule", clauses: [LocalSongRuleClause(field: .duration, operation: .atLeast, number: number)]))
        }
        for bad in badRules { await #expect(throws: (any Error).self) { try await store.save(bad, accountKey: fixture.first) } }
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == original)
    }

    @Test func invalidOccurrencesAndNestedFutureMetadataAreNeverSilentlyRewritten() async throws {
        let fixture = SongRuleStoreFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        let song = LocalSongRuleSong(track: fixture.tracks[0])
        let duplicate = LocalSongRuleArchive(snapshot: LocalSongRuleSnapshot(capturedAt: fixture.date, sourceName: "Loaded", songs: [song, song]))
        let bytes = try JSONEncoder().encode(duplicate)
        try fixture.write(bytes)
        await #expect(throws: LocalSongRuleError.invalidSnapshot) { try await store.load(accountKey: fixture.first) }
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == bytes)
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalSongRuleArchive(snapshot: LocalSongRuleSnapshot(capturedAt: fixture.date, sourceName: "Loaded", songs: [song])))) as? [String: Any])
        var snapshot = try #require(document["snapshot"] as? [String: Any])
        var songs = try #require(snapshot["songs"] as? [[String: Any]])
        songs[0]["futureGenre"] = "Unknown"; snapshot["songs"] = songs; document["snapshot"] = snapshot
        let future = try JSONSerialization.data(withJSONObject: document)
        try fixture.write(future)
        await #expect(throws: LocalSongRuleError.invalidArchive) { try await store.clearSnapshot(accountKey: fixture.first) }
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == future)
    }

    @Test func serializedConcurrentEditsKeepAllRulesAndWriteLimitsKeepTheOldFile() async throws {
        let fixture = SongRuleStoreFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask { _ = try await store.save(LocalSongRule(name: "Rule \(index)", clauses: [LocalSongRuleClause(field: .title, operation: .isKnown)]), accountKey: fixture.first) }
            }
            try await group.waitForAll()
        }
        #expect(try await store.load(accountKey: fixture.first).rules.count == 12)
        try FileManager.default.removeItem(at: fixture.file(fixture.first))
        let bounded = LocalSongRuleStore(directoryURL: fixture.directory, maximumBytes: 600)
        try await bounded.save(fixture.rule, accountKey: fixture.first)
        let original = try Data(contentsOf: fixture.file(fixture.first))
        await #expect(throws: LocalSongRuleError.fileTooLarge) {
            try await bounded.capture(tracks: [Track(id: "abcDEF12_-3", title: String(repeating: "x", count: 4_096), artist: "Artist")],
                sourceName: "Loaded", hasMorePages: false, wasLoading: false, accountKey: fixture.first)
        }
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == original)
    }

    @Test func nonRegularFilesAndExcessArrayCountsAreRejectedBeforeDecodingTheirRows() async throws {
        let fixture = SongRuleStoreFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        try FileManager.default.createDirectory(at: fixture.file(fixture.first), withIntermediateDirectories: true)
        await #expect(throws: LocalSongRuleError.invalidArchive) { try await store.load(accountKey: fixture.first) }
        try FileManager.default.removeItem(at: fixture.file(fixture.first))
        let document: [String: Any] = ["version": 1, "rules": Array(repeating: [String: Any](), count: 51)]
        let bytes = try JSONSerialization.data(withJSONObject: document)
        try fixture.write(bytes)
        await #expect(throws: LocalSongRuleError.capacityReached) { try await store.load(accountKey: fixture.first) }
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == bytes)
    }
}
