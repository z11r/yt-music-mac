import Foundation
import Testing
import YouTubeMusic
@testable import YTMusicMac

@MainActor @Suite("Native service-library search admission")
struct LibrarySearchTests {
    @Test func heldCredentialSnapshotCannotStartIOAfterOwnerRevocation() async throws {
        let owner = LibrarySearchOwner(generation: UUID(), account: String(repeating: "a", count: 64))
        let gate = LibrarySnapshotGate(), original = libraryNativeCredentials(owner.account)
        var current = true, reads = 0
        let pending = Task {
            try await LibrarySearchRead.perform(owner: owner, operations: ProfileOperationFence(), snapshot: { await gate.snapshot() }, isCurrent: { current }, load: { _ in
                reads += 1; return .init(title: "Never", sections: [], items: [])
            })
        }
        await gate.waitUntilHeld(); current = false; await gate.release(original)
        await #expect(throws: MusicServiceError.sessionChanged) { try await pending.value }
        #expect(reads == 0)
    }
    @Test(arguments: [false, true])
    func heldHTTPKeepsItsOriginalScopeAndRejectsLateOrCanceledReplies(_ cancel: Bool) async throws {
        let key = String(repeating: "a", count: 64), owner = LibrarySearchOwner(generation: UUID(), account: String(repeating: "a", count: 64))
        let credentials = MusicSessionStore(), transport = LibraryNativeHTTP(holding: true)
        await credentials.replaceSession(accountID: key, cookieHeader: "fixture=1", sapisid: "fixture", configuration: .init(apiKey: "fixture", clientVersion: "fixture"))
        let client = YouTubeMusicClient(transport: transport, sessions: credentials)
        var current = true
        let operations = ProfileOperationFence()
        let pending = Task {
            try await LibrarySearchRead.perform(owner: owner, operations: operations, snapshot: { await credentials.snapshot() }, isCurrent: { current },
                load: { try await client.searchLibrary(query: "held", filter: .songs, expectedScope: $0) })
        }
        await transport.waitUntilHeld()
        operations.quiesce()
        var settled = false
        let settling = Task { await operations.waitForIdle(); settled = true }
        for _ in 0..<50 { await Task.yield() }
        #expect(!settled)
        if cancel { pending.cancel() } else { current = false }
        await #expect(throws: MusicServiceError.sessionChanged) {
            try await LibrarySearchRead.perform(owner: owner, operations: operations, snapshot: { await credentials.snapshot() }, isCurrent: { true },
                load: { try await client.searchLibrary(query: "never", filter: .songs, expectedScope: $0) })
        }
        #expect(await transport.paths.count == 1)
        await transport.release()
        if cancel { await #expect(throws: CancellationError.self) { try await pending.value } }
        else { await #expect(throws: MusicServiceError.sessionChanged) { try await pending.value } }
        await settling.value
        #expect(settled)
    }
    @Test func aChangedCredentialScopeAfterTheReadCannotReturnAPage() async throws {
        let owner = LibrarySearchOwner(generation: UUID(), account: String(repeating: "a", count: 64))
        var value = libraryNativeCredentials(owner.account)
        await #expect(throws: MusicServiceError.sessionChanged) {
            try await LibrarySearchRead.perform(owner: owner, operations: ProfileOperationFence(), snapshot: { value }, isCurrent: { true }, load: { _ in
                value = libraryNativeCredentials(owner.account)
                return .init(title: "Old", sections: [], items: [])
            })
        }
    }
    @Test func wrongOrAnonymousCredentialsCannotReachTheLoader() async throws {
        let owner = LibrarySearchOwner(generation: UUID(), account: String(repeating: "a", count: 64))
        for value in [MusicSession(scope: UUID()), libraryNativeCredentials(String(repeating: "b", count: 64))] {
            var reads = 0
            await #expect(throws: MusicServiceError.signInRequired) {
                try await LibrarySearchRead.perform(owner: owner, operations: ProfileOperationFence(), snapshot: { value }, isCurrent: { true }, load: { _ in
                    reads += 1; return .init(title: "Never", sections: [], items: [])
                })
            }
            #expect(reads == 0)
        }
    }
    @Test func nativeUnconfirmedLibrarySearchAndTypingPerformZeroHTTP() async throws {
        let fixture = try await LibraryNativeFixture(); defer { fixture.remove() }
        let session = fixture.session
        session.setSearchScope(.library)
        session.searchText = "A private library query"; session.searchTextChanged()
        #expect(session.searchSuggestions.task == nil && session.searchSuggestions.items.isEmpty)
        session.submitSearch()
        while session.isLoading { await Task.yield() }
        #expect(session.librarySearchOwner == nil && session.page == nil && session.pageError != nil)
        #expect(await fixture.transport.paths.isEmpty)
        #expect(!session.account.isSignedIn && !session.wantsPlayback)
        await session.shutdown()
    }
    @Test func switchingToLibraryCancelsAnAlreadyHeldCatalogSuggestionAndNeverDisplaysIt() async throws {
        let fixture = try await LibraryNativeFixture(holding: true); defer { fixture.remove() }
        let session = fixture.session
        session.searchText = "catalog draft"; session.searchTextChanged()
        let old = session.searchSuggestions.task
        await fixture.transport.waitUntilHeld()
        session.setSearchScope(.library)
        session.searchText = "library draft"; session.searchTextChanged()
        #expect(session.searchSuggestions.task == nil)
        await fixture.transport.release(); await old?.value
        #expect(session.searchSuggestions.items.isEmpty)
        #expect(await fixture.transport.paths == ["/youtubei/v1/music/get_search_suggestions"])
        await session.shutdown()
    }
    @Test func recentAndNavigationEntriesRetainSourceFilterAndRevokeWithAccountOrProfile() async throws {
        let fixture = try await LibraryNativeFixture(); defer { fixture.remove() }
        let session = fixture.session
        let catalog = RecentSearch(query: "same", source: .catalog(.albums))
        let library = RecentSearch(query: "same", source: .library(.artists))
        session.repeatSearch(catalog); session.repeatSearch(library)
        #expect(session.destination == .librarySearch("same", .artists))
        #expect(session.searchScope == .library && session.searchHistory.entries.count == 2)
        session.goBack()
        #expect(session.destination == .search("same", filter: .albums) && session.searchScope == .catalog)
        session.goForward()
        #expect(session.destination == .librarySearch("same", .artists))
        session.accountGeneration = UUID()
        #expect(session.searchHistory.entries.isEmpty && !session.canGoBack && !session.canGoForward)
        #expect(session.searchScope == .catalog && session.searchText.isEmpty)
        session.quiesceForProfileSwitch()
        session.submitSearch(); session.repeatSearch(library)
        #expect(session.searchHistory.entries.isEmpty)
        await session.shutdown()
    }
    @Test func publicSearchEntryRemainsCatalogAfterALibraryChoice() async throws {
        let fixture = try await LibraryNativeFixture(); defer { fixture.remove() }
        let session = fixture.session
        session.setSearchScope(.library); session.searchText = "explicit catalog"; session.search()
        #expect(session.destination == .search("explicit catalog", filter: .all))
        #expect(session.searchScope == .catalog)
        session.quiesceForProfileSwitch(); await session.shutdown()
    }
}

private func libraryNativeCredentials(_ key: String) -> MusicSession {
    .init(scope: UUID(), accountID: key, cookieHeader: "fixture=1", sapisid: "fixture", configuration: .init(apiKey: "fixture", clientVersion: "fixture"))
}
private actor LibrarySnapshotGate {
    private var reply: CheckedContinuation<MusicSession, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func snapshot() async -> MusicSession { await withCheckedContinuation { reply = $0; arrival?.resume(); arrival = nil } }
    func waitUntilHeld() async { if reply == nil { await withCheckedContinuation { arrival = $0 } } }
    func release(_ value: MusicSession) { reply?.resume(returning: value); reply = nil }
}
private actor LibraryNativeHTTP: MusicHTTPTransport {
    let holding: Bool
    private var reply: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private(set) var paths: [String] = []
    init(holding: Bool) { self.holding = holding }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        paths.append(request.url!.path)
        if holding { await withCheckedContinuation { reply = $0; arrival?.resume(); arrival = nil } }
        if request.url?.path == "/youtubei/v1/music/get_search_suggestions" {
            return .init(data: Data(#"{"contents":[{"searchSuggestionsSectionRenderer":{"contents":[{"searchSuggestionRenderer":{"suggestion":{"runs":[{"text":"old catalog suggestion"}]}}}]}}]}"#.utf8), statusCode: 200)
        }
        return .init(data: Data(#"{"contents":{"sectionListRenderer":{"contents":[]}}}"#.utf8), statusCode: 200)
    }
    func waitUntilHeld() async { if reply == nil { await withCheckedContinuation { arrival = $0 } } }
    func release() { reply?.resume(); reply = nil }
}
@MainActor private struct LibraryNativeFixture {
    let domain = "LibrarySearchTests." + UUID().uuidString
    let preferences: UserDefaults
    let transport: LibraryNativeHTTP
    let session: AppSession
    init(holding: Bool = false) async throws {
        preferences = try #require(UserDefaults(suiteName: domain))
        transport = LibraryNativeHTTP(holding: holding)
        let credentials = MusicSessionStore()
        await credentials.replaceSession(accountID: String(repeating: "a", count: 64), cookieHeader: "fixture=1", sapisid: "fixture", configuration: .init(apiKey: "fixture", clientVersion: "fixture"))
        session = AppSession(configuration: .init(preferences: preferences, dataStore: .nonPersistent(), credentials: credentials,
            client: YouTubeMusicClient(transport: transport, sessions: credentials), queueStore: nil, queueStorageError: nil,
            installsSystemMedia: false, isSceneCheck: true))
    }
    func remove() { preferences.removePersistentDomain(forName: domain) }
}
