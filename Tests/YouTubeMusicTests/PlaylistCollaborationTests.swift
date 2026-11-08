import Foundation
import Testing
@testable import YouTubeMusic

@Suite("Read-only playlist contributors")
struct PlaylistCollaborationTests {
    @Test func exactPrimaryMarkerKeepsOpaqueAttributionWithoutInferringRolesOrCounts() throws {
        let label = "بواسطة مؤلف و١١ آخرين\u{200f} %@"
        let page = try parse(header: header(label: label))
        #expect(page.collectionHeader?.collaboration?.label == label)
        #expect(page.collectionHeader?.collaboration?.avatarURLs.map(\.host) == ["yt3.ggpht.com"])
        #expect(!page.playlistCapabilities.canAddItems && !page.playlistCapabilities.canRemoveItems && !page.playlistCapabilities.canReorder)
    }

    @Test func ordinaryAuthorFacesEnglishLabelsAndUnselectedHeadersEstablishNoCollaboration() throws {
        for tag in ["ordinary_author", "PAplaylist_collaborate ", ""] {
            #expect(try parse(header: header(label: "Collaborators", tag: tag)).collectionHeader?.collaboration == nil)
        }
        let current: [String: Any] = ["tabRenderer": ["selected": false, "content": ["sectionListRenderer": ["contents": [
            ["musicResponsiveHeaderRenderer": header(label: "Wrong tab")]
        ]]]]]
        let root: [String: Any] = ["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [current]]],
            "menu": ["musicResponsiveHeaderRenderer": header(label: "Wrong menu")]]
        #expect(MusicCollectionHeaderParser.parse(try JSONDecoder().decode(JSONNode.self, from: bytes(root))) == nil)
    }

    @Test func avatarURLsAreBoundedDeduplicatedAndLimitedToCredentialFreeImageHosts() {
        let bad = ["http://yt3.ggpht.com/a", "file:///private/a", "https://yt3.ggpht.com.evil.example/a",
                   "https://user:secret@yt3.ggpht.com/a", "https://yt3.ggpht.com:444/a", "https://yt3.ggpht.com/a#fragment",
                   "https://img.youtube.com/fallback.jpg", "https://yt3.ggpht.com/" + String(repeating: "a", count: 2_049)]
        let valid = (0..<12).map { URL(string: "https://yt3.ggpht.com/portrait\($0)")! }
        let value = MusicPlaylistCollaboration(label: "Opaque service attribution", avatarURLs: bad.compactMap(URL.init(string:)) + valid + valid)
        #expect(value?.avatarURLs == Array(valid.prefix(8)))
        #expect(MusicPlaylistCollaboration(label: "Too many sources", avatarURLs: Array(repeating: valid[0], count: 33))?.avatarURLs.isEmpty == true)
    }

    @Test func malformedOrOversizedAttributionDoesNotEraseOtherCollectionMetadata() throws {
        for label in ["", " \n ", "bad\u{0}label", String(repeating: "a", count: 1_025)] {
            var value = header(label: label); value["secondSubtitle"] = ["simpleText": "7 songs"]
            let parsed = try parse(header: value).collectionHeader
            #expect(parsed?.collaboration == nil && parsed?.summary == "7 songs")
        }
        let value = try parse(header: header(label: "Only collaborator data"))
        #expect(value.collectionHeader?.collaboration != nil && value.collectionHeader?.summary == nil)
    }

    @Test func userChannelAttributionCannotBecomeASongArtistWhenMusicArtistMetadataExists() throws {
        func column(_ text: String, id: String? = nil, pageType: String? = nil) -> [String: Any] {
            var run: [String: Any] = ["text": text]
            if let id, let pageType { run["navigationEndpoint"] = ["browseEndpoint": ["browseId": id,
                "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": pageType]]]] }
            return ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [run]]]]
        }
        let row: [String: Any] = ["musicResponsiveListItemRenderer": [
            "playlistItemData": ["videoId": "abcDEF12_-3"],
            "flexColumns": [column("Song"), column("Music Artist", id: "UCmusic", pageType: "MUSIC_PAGE_TYPE_ARTIST"),
                column("3:00"), column("Album", id: "MPREfixture", pageType: "MUSIC_PAGE_TYPE_ALBUM"),
                column("Private contributor", id: "UCcontributor", pageType: "MUSIC_PAGE_TYPE_USER_CHANNEL")]
        ]]
        let page = try parse(header: header(label: "by Private contributor"), rows: [row])
        let track = try #require(page.items.compactMap { if case let .track(value) = $0 { value } else { nil } }.first)
        #expect(track.artist == "Music Artist")
        #expect(track.artistReferences?.map(\.id) == ["UCmusic"])
    }

    @Test func aContributorChannelCannotReplacePlainSongArtistText() throws {
        let contributor: [String: Any] = ["text": "Private contributor", "navigationEndpoint": ["browseEndpoint": [
            "browseId": "UCcontributor", "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_USER_CHANNEL"]]]]]
        func column(_ runs: [[String: Any]]) -> [String: Any] {
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": runs]]]
        }
        let row: [String: Any] = ["musicResponsiveListItemRenderer": [
            "navigationEndpoint": ["watchEndpoint": ["videoId": "abcDEF12_-3", "watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": "MUSIC_VIDEO_TYPE_ATV"]]]],
            "flexColumns": [column([["text": "Song"]]), column([["text": "Plain Music Artist"]]), column([contributor])]
        ]]
        let page = try parse(header: header(label: "by Private contributor"), rows: [row])
        let track = try #require(page.items.compactMap { if case let .track(value) = $0 { value } else { nil } }.first)
        #expect(track.artist == "Plain Music Artist" && track.artistReferences == nil)
    }

    @Test func currentCollaborativePlaylistDoesNotExportAnUnhintedContributorAsArtist() throws {
        for type in [nil, "MUSIC_VIDEO_TYPE_ATV"] as [String?] {
            for artist in ["Plain Music Artist", "", "  ", "3:00"] {
                let page = try parse(header: header(label: "Shared playlist"), rows: [attributedRow(artist: artist, videoType: type)])
                let track = try #require(page.items.compactMap { if case let .track(value) = $0 { value } else { nil } }.first)
                #expect(track.artist == (artist == "Plain Music Artist" ? artist : ServiceLocalization.text("Unknown artist")))
                #expect(track.artistReferences == nil)
                if type == nil { #expect(track.contentKind == nil) }
            }
        }
    }

    @Test func exactCurrentHeaderMarkerProtectsRowsEvenWhenItsDisplayLabelIsMalformed() throws {
        for label in ["", "bad\u{0}label", String(repeating: "a", count: 1_025)] {
            let page = try parse(header: header(label: label), rows: [attributedRow(artist: "Plain Music Artist")])
            let track = try #require(page.items.compactMap { if case let .track(value) = $0 { value } else { nil } }.first)
            #expect(page.collectionHeader?.collaboration == nil)
            #expect(track.artist == "Plain Music Artist" && track.artistReferences == nil)
        }
    }

    @Test func ordinaryUploaderAndUserChannelCardsRetainTheirExistingMeaning() throws {
        for marker in ["ordinary_author", "PAplaylist_collaborate "] {
            for type in [nil, "MUSIC_VIDEO_TYPE_ATV"] as [String?] {
                let page = try parse(header: header(label: "Author", tag: marker), rows: [attributedRow(artist: "Plain Music Artist", videoType: type)])
                let track = try #require(page.items.compactMap { if case let .track(value) = $0 { value } else { nil } }.first)
                #expect(track.artist == "Private contributor" && track.artistReferences?.map(\.id) == ["UCcontributor"])
            }
        }
        let card: [String: Any] = ["musicTwoRowItemRenderer": ["title": ["simpleText": "Video creator"],
            "navigationEndpoint": ["browseEndpoint": ["browseId": "UCcreator",
                "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_USER_CHANNEL"]]]]]]
        let page = try parse(header: header(label: "Shared playlist"), rows: [card])
        guard case let .collection(creator) = try #require(page.items.first) else { Issue.record("Expected a user-channel card"); return }
        #expect(creator.id == "UCcreator" && creator.kind == .artist && creator.title == "Video creator")
    }

    @Test func unrelatedAndAmbiguousHeadersCannotChangeUploaderParsing() throws {
        let rows = [attributedRow(artist: "Plain Music Artist")]
        let shelf: [String: Any] = ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": ["contents": rows]]]]]
        let marker = header(label: "Not the current header")
        func tab(_ selected: Any) -> [String: Any] {
            ["tabRenderer": ["selected": selected, "content": ["sectionListRenderer": ["contents": [["musicResponsiveHeaderRenderer": marker]]]]]]
        }
        let roots: [[String: Any]] = [
            ["menu": ["musicResponsiveHeaderRenderer": marker], "contents": shelf],
            ["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [tab(false)], "secondaryContents": shelf]]],
            ["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [tab(true), tab(true)], "secondaryContents": shelf]]],
            ["header": ["musicResponsiveHeaderRenderer": marker, "musicDetailHeaderRenderer": marker], "contents": shelf]
        ]
        for root in roots {
            let page = try MusicResponseParser.parse(bytes(root), preservesOccurrences: true)
            let track = try #require(page.items.compactMap { if case let .track(value) = $0 { value } else { nil } }.first)
            #expect(track.artist == "Private contributor" && track.artistReferences?.map(\.id) == ["UCcontributor"])
        }
    }

    @Test func exactMarkerContextSurvivesHeaderlessContinuationsWithoutPersistingPersonMetadata() async throws {
        let transport = PlaylistContributorHTTP([
            try pageData(header: header(label: "bad\u{0}label"), rows: [attributedRow(artist: "First artist")], token: "second"),
            try pageData(rows: [attributedRow(artist: "Second artist")], token: "third", continuation: true),
            try pageData(rows: [attributedRow(artist: "3:00")], continuation: true)
        ])
        let client = YouTubeMusicClient(transport: transport, sessions: PlaylistContributorSession())
        let first = try await client.playlist(id: "PLfixture")
        let next = try await client.nextPage(#require(first.continuation))
        let last = try await client.nextPage(#require(next.continuation))
        #expect([first, next, last].map { $0.tracks.first?.artist } == ["First artist", "Second artist", ServiceLocalization.text("Unknown artist")])
        #expect([first, next, last].allSatisfy { $0.tracks.first?.artistReferences == nil && $0.collectionHeader?.collaboration == nil })
        #expect(next.collectionHeader == nil && last.collectionHeader == nil && last.continuation == nil)
        #expect(String(describing: try #require(first.continuation)) == "MusicContinuation")
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(try requests.dropFirst().map { request in
            (try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any])?["continuation"] as? String
        } == ["second", "third"])
    }

    @Test func attributionContextBelongsOnlyToItsOriginalCursorAndAccountScope() async throws {
        let transport = PlaylistContributorHTTP([
            try pageData(header: header(label: "Shared playlist"), rows: [attributedRow(artist: "Shared artist")], token: "shared-next"),
            try pageData(rows: [attributedRow(artist: "Ordinary artist", videoType: "MUSIC_VIDEO_TYPE_ATV")]),
            try pageData(rows: [attributedRow(artist: "Shared next artist")], token: "old-account-next", continuation: true)
        ])
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: "fixture", cookieHeader: "fixture=value", sapisid: "fixture",
            configuration: .init(apiKey: "fixture", clientVersion: "fixture"))
        let client = YouTubeMusicClient(transport: transport, sessions: sessions)
        let shared = try await client.playlist(id: "PLshared")
        let ordinary = try await client.playlist(id: "PLordinary")
        #expect(ordinary.tracks.first?.artist == "Private contributor" && ordinary.tracks.first?.artistReferences?.map(\.id) == ["UCcontributor"])
        let next = try await client.nextPage(#require(shared.continuation))
        #expect(next.tracks.first?.artist == "Shared next artist" && next.tracks.first?.artistReferences == nil)
        await sessions.clear()
        await #expect(throws: MusicServiceError.sessionChanged) {
            _ = try await client.nextPage(#require(next.continuation))
        }
        #expect(await transport.requests.count == 3)
    }

    private func attributedRow(artist: String, videoType: String? = nil) -> [String: Any] {
        func column(_ run: [String: Any]) -> [String: Any] {
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [run]]]]
        }
        let contributor: [String: Any] = ["text": "Private contributor", "navigationEndpoint": ["browseEndpoint": [
            "browseId": "UCcontributor", "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_USER_CHANNEL"]]]]]
        var row: [String: Any] = ["playlistItemData": ["videoId": "abcDEF12_-3"],
            "flexColumns": [column(["text": "Song"]), column(["text": artist]), column(contributor)]]
        if let videoType {
            row["navigationEndpoint"] = ["watchEndpoint": ["videoId": "abcDEF12_-3", "watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": videoType]]]]
        }
        return ["musicResponsiveListItemRenderer": row]
    }

    private func pageData(header: [String: Any]? = nil, rows: [[String: Any]], token: String? = nil, continuation: Bool = false) throws -> Data {
        var shelf: [String: Any] = ["contents": rows]
        if let token { shelf["continuations"] = [["nextContinuationData": ["continuation": token]]] }
        if continuation { return try bytes(["continuationContents": ["musicPlaylistShelfContinuation": shelf]]) }
        var root: [String: Any] = ["contents": ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": shelf]]]]]
        if let header { root["header"] = ["musicResponsiveHeaderRenderer": header] }
        return try bytes(root)
    }

    private func header(label: String, tag: String = "PAplaylist_collaborate") -> [String: Any] {
        ["facepile": ["avatarStackViewModel": [
            "rendererContext": ["accessibilityContext": ["label": label],
                "commandContext": ["onTap": ["innertubeCommand": ["showEngagementPanelEndpoint": ["identifier": ["tag": tag]]]]]],
            "avatars": [["avatarViewModel": ["image": ["sources": [["url": "https://yt3.ggpht.com/fixture"]]]]]]
        ]]]
    }
    private func parse(header: [String: Any], rows: [[String: Any]] = []) throws -> ParsedMusicPage {
        try MusicResponseParser.parse(bytes(["header": ["musicResponsiveHeaderRenderer": header],
            "contents": ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": ["contents": rows]]]]]]), preservesOccurrences: true)
    }
    private func bytes(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}

private actor PlaylistContributorHTTP: MusicHTTPTransport {
    private var payloads: [Data]
    private(set) var requests: [URLRequest] = []
    init(_ payloads: [Data]) { self.payloads = payloads }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        guard !payloads.isEmpty else { throw URLError(.badServerResponse) }
        return .init(data: payloads.removeFirst(), statusCode: 200)
    }
}
private struct PlaylistContributorSession: MusicSessionProviding {
    let value = MusicSession(scope: UUID(), configuration: .init(apiKey: "fixture", clientVersion: "fixture"))
    func snapshot() async -> MusicSession { value }
}
