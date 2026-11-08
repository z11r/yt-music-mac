import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

private struct SongRuleLibraryFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SongRuleLibraryTests-" + UUID().uuidString)
    let first = String(repeating: "a", count: 64)
    let second = String(repeating: "b", count: 64)
    var tracks: [Track] {
        [Track(id: "abcDEF12_-3", title: "Repeated first", artist: "Artist", isExplicit: nil),
         Track(id: "xyzABC34_-5", title: "Middle", artist: "Artist", duration: 180, isExplicit: false),
         Track(id: "abcDEF12_-3", title: "Repeated last", artist: "Artist", origin: .upload)]
    }
    var rule: LocalSongRule { LocalSongRule(name: "Known titles", clauses: [LocalSongRuleClause(field: .title, operation: .isKnown)]) }
    func file(_ key: String) -> URL { directory.appendingPathComponent(key).appendingPathComponent("song-rules.json") }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor ChangingSongRuleSessions: MusicSessionProviding {
    let first: MusicSession
    let second: MusicSession
    private var read = false
    init(first: MusicSession, second: MusicSession) { self.first = first; self.second = second }
    func snapshot() -> MusicSession { defer { read = true }; return read ? second : first }
}

private actor GatedSongRuleSessions: MusicSessionProviding {
    let session: MusicSession
    private var pausesNext = false
    private var paused: CheckedContinuation<MusicSession, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(session: MusicSession) { self.session = session }
    func pauseNext() { pausesNext = true }
    func snapshot() async -> MusicSession {
        if pausesNext {
            pausesNext = false
            return await withCheckedContinuation {
                paused = $0; observer?.resume(); observer = nil
            }
        }
        return session
    }
    func waitForPause() async {
        if paused != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { paused?.resume(returning: session); paused = nil }
}

@MainActor @Suite("Account-fenced local song-rule library", .serialized)
struct LocalSongRuleLibraryTests {
    @Test func explicitCaptureAndSelectedActionsPreserveOrderAndDuplicateOccurrences() async throws {
        let fixture = SongRuleLibraryFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalSongRuleLibrary(store: store, sessions: sessions)
        await library.save(fixture.rule, expectedScope: library.scope)
        #expect(library.archive.snapshot == nil && library.evaluation.matches.isEmpty)
        let source = try #require(await library.beginSource())
        await library.capture(tracks: fixture.tracks, sourceName: "Loaded playlist", hasMorePages: true, wasLoading: true,
            unavailableCount: 2, hasUnsupportedContent: false, source: source, expectedScope: library.scope)
        let matches = library.evaluation.matches
        #expect(matches.map(\.title) == fixture.tracks.map { Optional($0.title) })
        #expect(matches.count == 3 && library.archive.snapshot?.hasMorePages == true && library.archive.snapshot?.wasLoading == true)
        let chosen: Set<UUID> = [matches[2].id, matches[0].id]
        let tracks = try #require(await library.actionTracks(selectedIDs: chosen, expectedScope: library.scope, expectedRevision: library.revision))
        #expect(tracks.map(\.title) == ["Repeated first", "Repeated last"])
        #expect(tracks.map(\.id) == ["abcDEF12_-3", "abcDEF12_-3"] && tracks.last?.origin == .upload)
        #expect(tracks.first?.duration == nil && tracks.first?.isExplicit == nil)
        var queue = PlaybackQueue(); queue.append(tracks)
        #expect(Set(queue.entries.map(\.id)).count == 2 && queue.entries.map(\.track.id) == tracks.map(\.id))
        #expect(await library.actionTracks(selectedIDs: [], expectedScope: library.scope, expectedRevision: library.revision)?.isEmpty == true)
    }

    @Test func staleAccountUIActionsCannotWriteOrBorrowAnotherAccountsRules() async throws {
        let fixture = SongRuleLibraryFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalSongRuleLibrary(store: store, sessions: sessions)
        let rule = fixture.rule
        await library.save(rule, expectedScope: library.scope)
        let oldScope = library.scope
        let oldRevision = library.revision
        let source = try #require(await library.beginSource())
        library.invalidate()
        await sessions.replaceSession(accountID: fixture.second, cookieHeader: "fixture=1", sapisid: "fixture")
        await library.refresh(expectedScope: library.scope)
        await library.save(rule, expectedScope: oldScope)
        await library.remove(id: rule.id, expectedScope: oldScope)
        await library.clearSnapshot(expectedScope: oldScope)
        await library.capture(tracks: fixture.tracks, sourceName: "Stale page", hasMorePages: false, wasLoading: false,
            unavailableCount: 0, hasUnsupportedContent: false, source: source, expectedScope: oldScope)
        #expect(await library.actionTracks(selectedIDs: nil, expectedScope: oldScope, expectedRevision: oldRevision) == nil)
        #expect(try await store.load(accountKey: fixture.second).rules.isEmpty)
        #expect(try await store.load(accountKey: fixture.second).snapshot == nil)
        library.invalidate()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        await library.refresh(expectedScope: library.scope)
        #expect(library.archive.rules == [rule])
    }

    @Test func anOldLoadedPageCannotAcquireANewAccountsIdentityWithoutAUIChange() async throws {
        let fixture = SongRuleLibraryFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalSongRuleLibrary(store: store, sessions: sessions)
        await library.save(fixture.rule, expectedScope: library.scope)
        let original = try Data(contentsOf: fixture.file(fixture.first))
        let source = try #require(await library.beginSource())
        await sessions.replaceSession(accountID: fixture.second, cookieHeader: "fixture=2", sapisid: "fixture")
        await library.capture(tracks: fixture.tracks, sourceName: "Old page", hasMorePages: false, wasLoading: false,
            unavailableCount: 0, hasUnsupportedContent: false, source: source, expectedScope: library.scope)
        #expect(library.archive.rules.isEmpty && library.errorMessage != nil)
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(fixture.second).path))
    }

    @Test func sameAccountCredentialChangesAlsoInvalidateAnOldPageSource() async throws {
        let fixture = SongRuleLibraryFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalSongRuleLibrary(store: store, sessions: sessions)
        let source = try #require(await library.beginSource())
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=2", sapisid: "fixture")
        await library.capture(tracks: fixture.tracks, sourceName: "Old credentials", hasMorePages: false, wasLoading: false,
            unavailableCount: 0, hasUnsupportedContent: false, source: source, expectedScope: library.scope)
        #expect(library.archive.snapshot == nil && library.errorMessage != nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(fixture.first).path))
    }

    @Test func signOutHidesRulesAndBlocksPlaybackPayloadsWhileKeepingTheOwnersFile() async throws {
        let fixture = SongRuleLibraryFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalSongRuleLibrary(store: store, sessions: sessions)
        let rule = fixture.rule
        await library.save(rule, expectedScope: library.scope)
        let revision = library.revision
        await sessions.clear()
        #expect(await library.actionTracks(selectedIDs: nil, expectedScope: library.scope, expectedRevision: revision) == nil)
        await library.refresh(expectedScope: library.scope)
        #expect(library.archive.rules.isEmpty && library.archive.snapshot == nil && library.evaluation.matches.isEmpty)
        #expect(try await store.load(accountKey: fixture.first).rules == [rule])
    }

    @Test func accountChangesDuringReadRejectThePrivateResult() async throws {
        let fixture = SongRuleLibraryFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        try await store.save(fixture.rule, accountKey: fixture.first)
        let first = MusicSession(scope: UUID(), accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let second = MusicSession(scope: UUID(), accountID: fixture.second, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalSongRuleLibrary(store: store, sessions: ChangingSongRuleSessions(first: first, second: second))
        await library.refresh(expectedScope: library.scope)
        #expect(library.archive.rules.isEmpty && library.errorMessage != nil && !library.isWorking)
    }

    @Test func resultChangesWhileAnActionAwaitsCredentialsRejectTheOldSelection() async throws {
        let fixture = SongRuleLibraryFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        let session = MusicSession(scope: UUID(), accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let sessions = GatedSongRuleSessions(session: session)
        let library = LocalSongRuleLibrary(store: store, sessions: sessions)
        await library.save(fixture.rule, expectedScope: library.scope)
        let source = try #require(await library.beginSource())
        await library.capture(tracks: fixture.tracks, sourceName: "Loaded songs", hasMorePages: false, wasLoading: false,
            unavailableCount: 0, hasUnsupportedContent: false, source: source, expectedScope: library.scope)
        let revision = library.revision
        await sessions.pauseNext()
        let action = Task { await library.actionTracks(selectedIDs: nil, expectedScope: library.scope, expectedRevision: revision) }
        await sessions.waitForPause()
        library.select(nil, expectedScope: library.scope)
        await sessions.release()
        #expect(await action.value == nil)
    }

    @Test func clearAndRuleEditsUpdateCachedResultsAndInvalidateOldRevisions() async throws {
        let fixture = SongRuleLibraryFixture()
        defer { fixture.remove() }
        let store = LocalSongRuleStore(directoryURL: fixture.directory)
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalSongRuleLibrary(store: store, sessions: sessions)
        var rule = fixture.rule
        await library.save(rule, expectedScope: library.scope)
        let source = try #require(await library.beginSource())
        await library.capture(tracks: fixture.tracks, sourceName: "Loaded songs", hasMorePages: false, wasLoading: false,
            unavailableCount: 0, hasUnsupportedContent: false, source: source, expectedScope: library.scope)
        #expect(library.evaluation.matches.count == 3)
        let old = library.revision
        rule.clauses = [LocalSongRuleClause(field: .explicit, operation: .isFalse)]
        await library.save(rule, expectedScope: library.scope)
        #expect(library.evaluation.matches.count == 1 && library.evaluation.unknownCount == 2)
        #expect(await library.actionTracks(selectedIDs: nil, expectedScope: library.scope, expectedRevision: old) == nil)
        await library.clearSnapshot(expectedScope: library.scope)
        #expect(library.evaluation.matches.isEmpty && library.archive.rules.count == 1)
    }

    @Test func unconfirmedAccountNamesCannotCreateAStorageNamespace() async {
        let fixture = SongRuleLibraryFixture()
        defer { fixture.remove() }
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: "display-name", cookieHeader: "fixture=1", sapisid: "fixture")
        let library = LocalSongRuleLibrary(store: LocalSongRuleStore(directoryURL: fixture.directory), sessions: sessions)
        #expect(await library.beginSource() == nil)
        await library.save(fixture.rule, expectedScope: library.scope)
        #expect(library.archive.rules.isEmpty && library.errorMessage != nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test func nativeActionsFailClosedWithoutSignedInUIStateAndUnverifiedPagesCannotReplaceTheSnapshot() async throws {
        let fixture = SongRuleLibraryFixture()
        defer { fixture.remove() }
        let preferences = SceneCheckPreferences()
        defer { preferences.remove() }
        let transport = SceneCheckTransport()
        var configuration = AppSessionConfiguration.sceneCheck(preferences: preferences.defaults, transport: transport)
        configuration.localSongRuleStore = LocalSongRuleStore(directoryURL: fixture.directory)
        await configuration.credentials.replaceSession(accountID: fixture.first, cookieHeader: "fixture=1", sapisid: "fixture")
        let session = AppSession(configuration: configuration)
        await session.songRules.save(fixture.rule, expectedScope: session.songRules.scope)
        let source = try #require(await session.songRules.beginSource())
        await session.songRules.capture(tracks: fixture.tracks, sourceName: "Fixture page", hasMorePages: false, wasLoading: false,
            unavailableCount: 0, hasUnsupportedContent: false, source: source, expectedScope: session.songRules.scope)
        session.queue.append([fixture.tracks[0]])
        let before = session.queue.snapshot()
        let original = try Data(contentsOf: fixture.file(fixture.first))
        await session.captureLoadedSongsForRules(expectedScope: session.songRules.scope)
        await session.performSongRuleAction(play: true, selectedIDs: nil, expectedScope: session.songRules.scope, expectedRevision: session.songRules.revision)
        await session.performSongRuleAction(play: false, selectedIDs: nil, expectedScope: session.songRules.scope, expectedRevision: session.songRules.revision)
        #expect(session.queue.snapshot() == before && !session.showsAccount && !session.player.playbackIntent)
        #expect(try Data(contentsOf: fixture.file(fixture.first)) == original)
        #expect(await transport.attempts == 0)
        await session.shutdown()
    }
}
