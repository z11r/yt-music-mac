import Foundation
import Testing
@testable import YouTubeMusic

@Suite("Bounded current-artist About text")
struct MusicArtistAboutTests {
    @Test func directDescriptionShelfPreservesAllTextCreditsAndActualSourceAddresses() throws {
        let runs = creditedAboutRuns()
        let about = try #require(parse(artistRoot(runs: runs, headerRuns: [["text": "Short header"]])))
        #expect(about.text == runs.compactMap { $0["text"] as? String }.joined())
        #expect(about.text.hasSuffix(" under the supplied license)."))
        #expect(about.sourceURLs == ["https://source.example/artist?revision=123", "http://license.example/terms"])
        #expect(about.text.contains("%@ العربية\u{200f}"))
    }
    @Test func immersiveHeaderTextIsUsableOnlyWhenNoDescriptionShelfIsAdvertised() throws {
        let root = artistRoot(runs: nil, headerRuns: creditedAboutRuns())
        #expect(parse(root)?.sourceURLs.count == 2)
        var headerOnly = root; headerOnly.removeValue(forKey: "contents")
        #expect(parse(headerOnly)?.text == parse(root)?.text)
        let description = [["text": "his fourth "], ["text": "#1Example", "navigationEndpoint": ["searchEndpoint": ["query": "#1Example"]]], ["text": " release"]]
        let value = try #require(parse(artistRoot(runs: description)))
        #expect(value.text == "his fourth #1Example release" && value.sourceURLs.isEmpty)
    }
    @Test func selectedPrimarySingleAndTwoColumnTabsSupplyOnlyTheirOwnDescription() throws {
        for columns in ["singleColumnBrowseResultsRenderer", "twoColumnBrowseResultsRenderer"] {
            for selected in [true, nil] as [Bool?] {
                #expect(parse(artistRoot(runs: [["text": "Current"]], columns: columns, selected: selected))?.text == "Current")
            }
            var root = artistRoot(runs: nil, columns: columns)
            let tabs = [aboutTab([["musicDescriptionShelfRenderer": ["description": ["runs": [["text": "Other"]]]]]], selected: false),
                        aboutTab([["musicDescriptionShelfRenderer": ["description": ["runs": [["text": "Current"]]]]]], selected: true)]
            root["contents"] = [columns: ["tabs": tabs]]
            #expect(parse(root)?.text == "Current")
        }
    }
    @Test func unselectedAmbiguousMalformedAndNullTabAuthorityIsNeverAbsence() throws {
        for flag in [false, NSNull(), "true"] as [Any] {
            #expect(parse(artistRoot(runs: [["text": "Wrong"]], headerRuns: [["text": "Do not bypass"]], selected: flag)) == nil)
        }
        let tab = aboutTab([["musicDescriptionShelfRenderer": ["description": ["runs": [["text": "Ambiguous"]]]]]], selected: true)
        for count in [2, 9] {
            var root = artistRoot(runs: nil, headerRuns: [["text": "Do not bypass"]])
            root["contents"] = ["singleColumnBrowseResultsRenderer": ["tabs": Array(repeating: tab, count: count)]]
            #expect(parse(root) == nil)
        }
        for key in ["disabled", "unselectable"] {
            for flag in [true, NSNull(), "false"] as [Any] {
                var renderer = tab["tabRenderer"] as! [String: Any]; renderer[key] = flag
                var root = artistRoot(runs: nil, headerRuns: [["text": "Do not bypass"]])
                root["contents"] = ["singleColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": renderer]]]]
                #expect(parse(root) == nil)
            }
        }
        var root = artistRoot(runs: nil, headerRuns: [["text": "Do not bypass"]])
        root["contents"] = ["singleColumnBrowseResultsRenderer": ["tabs": [tab]], "twoColumnBrowseResultsRenderer": NSNull()]
        #expect(parse(root) == nil)
        root["contents"] = NSNull(); #expect(parse(root) == nil)
    }
    @Test func unrelatedNestedSecondaryAndMenuDescriptionsAreNeverArtistAbout() throws {
        let wrong: [String: Any] = ["musicDescriptionShelfRenderer": ["description": ["runs": [["text": "Unrelated"]]]]]
        var root = artistRoot(runs: nil)
        root["menu"] = wrong
        root["contents"] = ["twoColumnBrowseResultsRenderer": ["tabs": [aboutTab([["musicShelfRenderer": ["contents": [wrong]]]], selected: true)],
            "secondaryContents": ["sectionListRenderer": ["contents": [wrong]]]]]
        #expect(parse(root) == nil)
        root["header"] = ["musicDetailHeaderRenderer": ["description": ["runs": [["text": "Playlist"]]]]]
        #expect(parse(root) == nil)
        root["header"] = ["musicImmersiveHeaderRenderer": ["description": ["runs": [["text": "A"]]]], "musicVisualHeaderRenderer": NSNull()]
        #expect(parse(root) == nil)
    }
    @Test func advertisedMalformedShelfOrAttributionCannotFallBackToHeaderText() throws {
        let malformed: [Any] = [NSNull(), ["description": NSNull()], ["description": ["runs": NSNull()]],
            ["description": ["runs": [["text": NSNull()]]]],
            ["description": ["runs": [["text": "Source", "navigationEndpoint": NSNull()]]]],
            ["description": ["runs": [["text": "Source", "navigationEndpoint": ["urlEndpoint": NSNull()]]]]],
            ["description": ["runs": [["text": "Source", "navigationEndpoint": ["urlEndpoint": ["url": NSNull()]]]]]],
            ["description": ["runs": [["text": "Body"]]], "footer": NSNull()]]
        for shelf in malformed {
            var root = artistRoot(runs: nil, headerRuns: [["text": "Do not bypass attribution"]])
            root["contents"] = ["singleColumnBrowseResultsRenderer": ["tabs": [aboutTab([["musicDescriptionShelfRenderer": shelf]], selected: true)]]]
            #expect(parse(root) == nil)
        }
        var root = artistRoot(runs: nil, headerRuns: [["text": "Do not bypass"]])
        let shelf = ["musicDescriptionShelfRenderer": ["description": ["runs": [["text": "A"]]]]]
        root["contents"] = ["singleColumnBrowseResultsRenderer": ["tabs": [aboutTab([shelf, shelf], selected: true)]]]
        #expect(parse(root) == nil)
    }
    @Test func oversizeFieldsAreRejectedWithoutTruncatingTheirCredits() {
        for runs in [[["text": String(repeating: "x", count: 16_385) + "\nLicense at end"]], Array(repeating: ["text": "x"], count: 257),
                     [["text": "Bad\u{0}text"]], [["text": "  \n "]]] {
            #expect(parse(artistRoot(runs: runs)) == nil)
        }
        let manyURLs = (0..<9).map { ["text": "Source \($0)", "navigationEndpoint": ["urlEndpoint": ["url": "https://source.example/\($0)"]]] as [String: Any] }
        #expect(parse(artistRoot(runs: manyURLs)) == nil)
        #expect(MusicArtistAbout(text: "Full source", sourceURLs: ["https://source.example/" + String(repeating: "a", count: 2_049)]) == nil)
        #expect(parse(artistRoot(runs: [["text": String(repeating: "x", count: 16_384)]]))?.text.utf8.count == 16_384)
    }
    @Test func sourceURLsAreActualBoundedAddressesAndNeverGuessedFromVisibleLabels() throws {
        for url in ["javascript:alert(1)", "file:///private/fixture", "data:text/plain,fixture", "https://user:secret@source.example/a", "https://source.example:444/a", "https://source.example/%00", "https://source.example/a b"] {
            #expect(parse(artistRoot(runs: [["text": "Source…", "navigationEndpoint": ["urlEndpoint": ["url": url]]]])) == nil)
        }
        let about = try #require(parse(artistRoot(runs: [["text": "https://source.example/truncated…"],
            ["text": "Literal percent", "navigationEndpoint": ["urlEndpoint": ["url": "https://source.example/%2500"]]]])))
        #expect(about.sourceURLs == ["https://source.example/%2500"])
        #expect(about.text.contains("truncated…"))
    }
    @Test func existingArtistPageCarriesAboutWithOneRequestAndHeaderlessPagingDoesNotReplaceIt() async throws {
        var first = artistRoot(runs: creditedAboutRuns())
        var contents = first["contents"] as! [String: Any]
        var renderer = contents["singleColumnBrowseResultsRenderer"] as! [String: Any]
        var tabs = renderer["tabs"] as! [[String: Any]], tab = tabs[0]["tabRenderer"] as! [String: Any]
        var content = tab["content"] as! [String: Any], sections = content["sectionListRenderer"] as! [String: Any]
        var items = sections["contents"] as! [[String: Any]]
        items.insert(["musicShelfRenderer": ["contents": [["musicTwoRowItemRenderer": [
            "title": ["runs": [["text": "Synthetic collection"]]],
            "navigationEndpoint": ["browseEndpoint": ["browseId": "PLfixture",
                "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_PLAYLIST"]]]]
        ]]]]], at: 0)
        sections["contents"] = items
        sections["continuations"] = [["nextContinuationData": ["continuation": "next"]]]
        content["sectionListRenderer"] = sections; tab["content"] = content; tabs[0]["tabRenderer"] = tab
        renderer["tabs"] = tabs; contents["singleColumnBrowseResultsRenderer"] = renderer; first["contents"] = contents
        let second: [String: Any] = ["continuationContents": ["sectionListContinuation": ["contents": []]]]
        let transport = ArtistAboutHTTP([try bytes(first), try bytes(second)])
        let client = YouTubeMusicClient(transport: transport, sessions: ArtistAboutSession())
        let page = try await client.artist(id: "UCfixture")
        let about = try #require(page.collectionHeader?.artistAbout)
        #expect(page.items.count == 1)
        #expect(await transport.requests.count == 1)
        let cursor = try #require(page.continuation), next = try await client.nextPage(cursor)
        #expect(page.collectionHeader?.artistAbout == about && next.collectionHeader == nil)
        let requests = await transport.requests
        #expect(requests.count == 2 && requests.allSatisfy { $0.url?.path == "/youtubei/v1/browse" })
    }
    private func parse(_ root: [String: Any]) -> MusicArtistAbout? {
        guard let value = try? JSONDecoder().decode(JSONNode.self, from: bytes(root)) else { return nil }
        return MusicCollectionHeaderParser.parse(value)?.artistAbout
    }
}

private func creditedAboutRuns() -> [[String: Any]] {
    [["text": "Synthetic biography %@ العربية\u{200f}\n\nFrom Example Source ("],
     ["text": "https://source.example/…", "navigationEndpoint": ["urlEndpoint": ["url": "https://source.example/artist?revision=123"]]],
     ["text": ") under Example License ("],
     ["text": "http://license.example/…", "navigationEndpoint": ["urlEndpoint": ["url": "http://license.example/terms"]]],
     ["text": " under the supplied license)."]]
}
private func aboutTab(_ items: [[String: Any]], selected: Any?) -> [String: Any] {
    var renderer: [String: Any] = ["content": ["sectionListRenderer": ["contents": items]]]
    if let selected { renderer["selected"] = selected }
    return ["tabRenderer": renderer]
}
private func artistRoot(runs: [[String: Any]]?, headerRuns: [[String: Any]]? = nil, columns: String = "singleColumnBrowseResultsRenderer", selected: Any? = true) -> [String: Any] {
    var header: [String: Any] = ["title": ["runs": [["text": "Synthetic artist"]]]]
    if let headerRuns { header["description"] = ["runs": headerRuns] }
    let items = runs.map { [["musicDescriptionShelfRenderer": ["description": ["runs": $0]]]] } ?? []
    return ["header": ["musicImmersiveHeaderRenderer": header], "contents": [columns: ["tabs": [aboutTab(items, selected: selected)]]]]
}
private func bytes(_ root: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: root) }
private struct ArtistAboutSession: MusicSessionProviding {
    let value = MusicSession(scope: UUID(), configuration: .init(apiKey: "fixture", clientVersion: "fixture"))
    func snapshot() async -> MusicSession { value }
}
private actor ArtistAboutHTTP: MusicHTTPTransport {
    var payloads: [Data]
    private(set) var requests: [URLRequest] = []
    init(_ payloads: [Data]) { self.payloads = payloads }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request); guard !payloads.isEmpty else { throw URLError(.badServerResponse) }
        return .init(data: payloads.removeFirst(), statusCode: 200)
    }
}
