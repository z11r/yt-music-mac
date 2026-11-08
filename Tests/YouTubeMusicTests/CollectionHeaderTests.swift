import Foundation
import Testing
@testable import YouTubeMusic

@Suite("Collection header metadata")
struct CollectionHeaderTests {
    @Test func editableHeaderRetainsLocalizedSummaryAndDescriptionWithoutNumericInference() throws {
        let header: [String: Any] = ["musicEditablePlaylistDetailHeaderRenderer": ["header": ["musicDetailHeaderRenderer": [
            "title": ["runs": [["text": "Collection"]]],
            "subtitle": ["runs": [["text": "Björk"], ["text": " • 2026"]]],
            "secondSubtitle": ["runs": [["text": "٦١٨ مقطوعة"], ["text": " • 26 heures"]]],
            "description": ["musicDescriptionShelfRenderer": ["description": ["runs": [["text": "First line\n"], ["text": "Second %@ line"]]]]]
        ]]]]
        let parsed = try MusicResponseParser.parse(data(["header": header,
            "contents": ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": ["contents": []]]]]]]), preservesOccurrences: true)
        #expect(parsed.collectionHeader == MusicCollectionHeader(subtitle: "Björk • 2026", summary: "٦١٨ مقطوعة • 26 heures", description: "First line\nSecond %@ line"))
        #expect(parsed.items.isEmpty)
    }

    @Test func onlyThePrimarySelectedHeaderCanSupplyMetadata() throws {
        func tab(_ selected: Bool, _ summary: String) -> [String: Any] {
            ["tabRenderer": ["selected": selected, "content": ["sectionListRenderer": ["contents": [
                ["musicResponsiveHeaderRenderer": ["secondSubtitle": ["simpleText": summary]]]
            ]]]]]
        }
        let root: [String: Any] = ["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [tab(false, "Unselected"), tab(true, "Current")]]],
            "menu": ["musicDetailHeaderRenderer": ["secondSubtitle": ["simpleText": "Not a header"]]]]
        #expect(try parse(root)?.summary == "Current")
        #expect(try parse(["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [tab(false, "Unselected")]]]]) == nil)
        var implicit = tab(false, "Implicit primary")
        var renderer = try #require(implicit["tabRenderer"] as? [String: Any])
        renderer.removeValue(forKey: "selected"); implicit["tabRenderer"] = renderer
        #expect(try parse(["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [implicit]]]])?.summary == "Implicit primary")
        renderer["selected"] = "true"; implicit["tabRenderer"] = renderer
        #expect(try parse(["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [implicit]]]]) == nil)
        #expect(try parse(["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [implicit, tab(true, "Current")]]]]) == nil)
        #expect(try parse(["contents": ["twoColumnBrowseResultsRenderer": ["tabs": Array(repeating: tab(true, "Oversized"), count: 9)]]]) == nil)
        #expect(try parse(["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [tab(true, "A"), tab(true, "B")]]]]) == nil)
        #expect(try parse(["menu": root["menu"]!]) == nil)
        #expect(try parse(["contents": ["sectionListRenderer": ["contents": [["musicResponsiveHeaderRenderer": ["secondSubtitle": ["simpleText": "Unscoped"]]]]]]]) == nil)
    }

    @Test func oversizedOrMalformedFieldsAreUnknownWithoutErasingOtherMetadata() throws {
        let value = try parse(["header": ["musicDetailHeaderRenderer": [
            "subtitle": ["simpleText": "bad\u{0}text"], "secondSubtitle": ["simpleText": "7 songs"],
            "description": ["simpleText": String(repeating: "a", count: 16_385)]
        ]]])
        #expect(value?.subtitle == nil && value?.description == nil && value?.summary == "7 songs")
        #expect(try parse(["header": ["musicDetailHeaderRenderer": ["secondSubtitle": ["simpleText": "A"]],
            "musicResponsiveHeaderRenderer": ["secondSubtitle": ["simpleText": "B"]]]]) == nil)
        #expect(MusicCollectionHeader(subtitle: "العربية\u{200f}", description: "line\n\tline").subtitle != nil)
    }

    @Test func nativeClientCarriesHeaderMetadataWithItsExactResponse() async throws {
        let payload = try data(["header": ["musicDetailHeaderRenderer": ["secondSubtitle": ["simpleText": "618 songs • 26 hours"]]],
            "contents": ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": ["contents": []]]]]]])
        let client = YouTubeMusicClient(transport: HeaderFixtureTransport(data: payload), sessions: HeaderFixtureSession())
        let page = try await client.playlist(id: "PLfixture")
        #expect(page.collectionHeader?.summary == "618 songs • 26 hours")
        #expect(page.tracks.isEmpty)
    }

    private func parse(_ object: [String: Any]) throws -> MusicCollectionHeader? {
        MusicCollectionHeaderParser.parse(try JSONDecoder().decode(JSONNode.self, from: data(object)))
    }
    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
}

private struct HeaderFixtureTransport: MusicHTTPTransport {
    let data: Data
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse { .init(data: data, statusCode: 200) }
}
private struct HeaderFixtureSession: MusicSessionProviding {
    let value = MusicSession(scope: UUID(), configuration: .init(apiKey: "fixture", clientVersion: "fixture"))
    func snapshot() async -> MusicSession { value }
}
