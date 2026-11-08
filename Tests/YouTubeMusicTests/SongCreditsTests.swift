import Foundation
import MusicCore
import Testing
@testable import YouTubeMusic

@Suite("Read-only service song credits")
struct SongCreditsTests {
    @Test func onlyTheSongsOwnUniqueUnscopedMenuReferenceIsAccepted() throws {
        let valid = creditMenu("MPTCopaque")
        #expect(reference([valid, valid])?.browseID == "MPTCopaque")
        #expect(reference([valid, creditMenu("MPTCother")]) == nil)
        #expect(reference([creditMenu("MPTCopaque", params: "filtered")]) == nil)
        #expect(reference([valid, creditMenu("MPTCopaque", params: "")]) == nil)
        #expect(reference([creditMenu("MPTCwrong/type")]) == nil)
        #expect(reference([creditMenu("MPTCopaque", pageType: "MUSIC_PAGE_TYPE_ALBUM")]) == nil)
        #expect(reference([creditMenu("MPREbalbum")]) == nil)
        let node = try JSONDecoder().decode(JSONNode.self, from: creditsJSON([
            "navigationEndpoint": ["browseEndpoint": ["browseId": "MPTCnotAMenu"]],
            "header": ["menu": ["menuRenderer": ["items": [valid]]]],
        ]))
        #expect(MusicSongCreditsParser.reference(in: node) == nil)
    }

    @Test func perRowParsingDoesNotLeakASiblingOrHeaderReference() throws {
        let rows: [[String: Any]] = [
            songRow("abcDEF12_-3", items: [creditMenu("MPTCfirst")]),
            songRow("otherID12_3", items: []),
        ]
        let data = creditsJSON(["contents": ["sectionListRenderer": ["contents": [["musicShelfRenderer": ["contents": rows]]]]],
                                "header": ["menu": ["menuRenderer": ["items": [creditMenu("MPTCheader")]]]]])
        let tracks = try MusicResponseParser.parse(data, preservesOccurrences: true).items.compactMap { if case let .track(track) = $0 { track } else { nil } }
        #expect(tracks.count == 2)
        #expect(tracks[0].creditsReference?.browseID == "MPTCfirst")
        #expect(tracks[1].creditsReference == nil)
    }

    @Test func localizedUnknownRolesNamesSeparatorsAndAttributionStayOrderedAndOpaque() throws {
        let data = dialog([
            section("Interprétation", ["First", " • ", "Second"]),
            section("Piano et sons", ["Unfamiliar name\n", "Another"]),
            section("Music metadata provided by", ["Fixture Distributor"]),
        ])
        #expect(try MusicSongCreditsParser.parse(data) == .available([
            .init(title: "Interprétation", text: "First • Second"),
            .init(title: "Piano et sons", text: "Unfamiliar name\nAnother"),
            .init(title: "Music metadata provided by", text: "Fixture Distributor"),
        ]))
    }

    @Test func emptyKnownDialogIsUnavailableButMalformedAndUnrelatedSchemasAreErrors() throws {
        #expect(try MusicSongCreditsParser.parse(dialog([])) == .unavailable)
        #expect(try MusicSongCreditsParser.parse(dialog([section("Role", [" \n"])])) == .unavailable)
        for data in [creditsJSON([:]), dialog([["otherRenderer": [:]]]), dialog([section("", ["Name"])]) ] {
            #expect(throws: MusicServiceError.unsupportedResponse) { try MusicSongCreditsParser.parse(data) }
        }
        #expect(throws: MusicServiceError.invalidResponse) { try MusicSongCreditsParser.parse(Data("broken".utf8)) }
        #expect(throws: MusicServiceError.accessDenied) {
            try MusicSongCreditsParser.parse(creditsJSON(["error": ["status": "PERMISSION_DENIED"]]))
        }
    }

    @Test func oversizedResponsesSectionsRunsAndTextAreRejectedWithoutPartialCredits() {
        #expect(throws: MusicServiceError.invalidResponse) { try MusicSongCreditsParser.parse(Data(repeating: 32, count: 1_048_577)) }
        for data in [dialog(Array(repeating: section("Role", ["Name"]), count: 65)),
                     dialog([section("Role", Array(repeating: "Name", count: 1_025))]),
                     dialog([section("Role", [String(repeating: "x", count: 16_385)])]),
                     dialog([section("Role", ["Name\0"])]),
                     dialog(Array(repeating: section("Role", [String(repeating: "x", count: 16_000)]), count: 7))] {
            #expect(throws: MusicServiceError.unsupportedResponse) { try MusicSongCreditsParser.parse(data) }
        }
    }

    @Test func anonymousRequestUsesOnlyExactIssuedDestinationAndCurrentPublicContext() async throws {
        let sessions = CreditsSessions()
        let scope = await sessions.snapshot().scope
        let transport = CreditsTransport(response: dialog([section("Role", ["Name"])]))
        let client = YouTubeMusicClient(transport: transport, sessions: sessions, pause: { _ in })
        let result = try await client.songCredits(try #require(SongCreditsReference(browseID: "MPTCissued")), expectedScope: scope)
        #expect(result == .available([.init(title: "Role", text: "Name")]))
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.path == "/youtubei/v1/browse")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["browseId"] as? String == "MPTCissued")
        #expect(body["videoId"] == nil)
        #expect(body["params"] == nil)
    }

    @Test func wrongScopeIsRejectedBeforeNetworkAndChangedScopeRejectsReply() async throws {
        let sessions = CreditsSessions()
        let scope = await sessions.snapshot().scope
        let transport = CreditsTransport(response: dialog([]), beforeResponse: { await sessions.rotate() })
        let client = YouTubeMusicClient(transport: transport, sessions: sessions, pause: { _ in })
        let ref = try #require(SongCreditsReference(browseID: "MPTCissued"))
        await #expect(throws: MusicServiceError.sessionChanged) { try await client.songCredits(ref, expectedScope: UUID()) }
        #expect(await transport.requests.isEmpty)
        await #expect(throws: MusicServiceError.sessionChanged) { try await client.songCredits(ref, expectedScope: scope) }
        #expect(await transport.requests.count == 1)
    }

    @Test func deadlineAndCancellationAreBoundedAndDoNotPublishCredits() async throws {
        let sessions = CreditsSessions()
        let scope = await sessions.snapshot().scope
        let transport = CreditsTransport(response: dialog([]), beforeResponse: { try await Task.sleep(for: .seconds(30)) })
        let client = YouTubeMusicClient(transport: transport, sessions: sessions, pause: { _ in })
        let ref = try #require(SongCreditsReference(browseID: "MPTCissued"))
        await #expect(throws: MusicServiceError.invalidInput) { try await client.songCredits(ref, expectedScope: scope, timeout: .zero) }
        #expect(await transport.requests.isEmpty)
        await #expect(throws: MusicSongCreditsError.timedOut) { try await client.songCredits(ref, expectedScope: scope, timeout: .milliseconds(5)) }
        let task = Task { try await client.songCredits(ref, expectedScope: scope) }
        await transport.waitForRequests(2)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.count == 2)
    }
}

private func creditsJSON(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
private func creditMenu(_ id: String, params: String? = nil, pageType: String? = nil) -> [String: Any] {
    var browse: [String: Any] = ["browseId": id]
    if let params { browse["params"] = params }
    if let pageType { browse["browseEndpointContextSupportedConfigs"] = ["browseEndpointContextMusicConfig": ["pageType": pageType]] }
    return ["menuNavigationItemRenderer": ["navigationEndpoint": ["browseEndpoint": browse]]]
}
private func reference(_ items: [[String: Any]]) -> SongCreditsReference? {
    MusicSongCreditsParser.reference(in: try! JSONDecoder().decode(JSONNode.self, from: creditsJSON(["menu": ["menuRenderer": ["items": items]]])))
}
private func songRow(_ id: String, items: [[String: Any]]) -> [String: Any] {
    ["musicResponsiveListItemRenderer": ["playlistItemData": ["videoId": id], "flexColumns": [
        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Song"]]]]],
    ], "menu": ["menuRenderer": ["items": items]]]]
}
private func section(_ title: String, _ texts: [String]) -> [String: Any] {
    ["dismissableDialogContentSectionRenderer": ["title": ["runs": [["text": title]]], "subtitle": ["runs": texts.map { ["text": $0] }]]]
}
private func dialog(_ sections: [[String: Any]]) -> Data {
    creditsJSON(["onResponseReceivedActions": [["openPopupAction": ["popup": ["dismissableDialogRenderer": ["sections": sections]]]]]])
}
private actor CreditsSessions: MusicSessionProviding {
    var scope = UUID()
    func snapshot() -> MusicSession { .init(scope: scope, configuration: .init(apiKey: "fixture", clientVersion: "fixture")) }
    func rotate() { scope = UUID() }
}
private actor CreditsTransport: MusicHTTPTransport {
    let response: Data
    let beforeResponse: @Sendable () async throws -> Void
    private(set) var requests: [URLRequest] = []
    private var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []
    init(response: Data, beforeResponse: @escaping @Sendable () async throws -> Void = {}) {
        self.response = response; self.beforeResponse = beforeResponse
    }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        let ready = arrivals.filter { $0.0 <= requests.count }
        arrivals.removeAll { $0.0 <= requests.count }
        ready.forEach { $0.1.resume() }
        try await beforeResponse()
        return .init(data: response, statusCode: 200)
    }
    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { arrivals.append((count, $0)) }
    }
}
