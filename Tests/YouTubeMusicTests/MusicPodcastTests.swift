import Foundation
import MusicCore
import XCTest
@testable import YouTubeMusic

@MainActor
final class MusicPodcastTests: XCTestCase {
    func testDiscoveryShowAndLibraryRoutesRemainReadOnlyAndAccountFenced() async throws {
        let transport = PodcastTransport(Array(repeating: shelf([]), count: 4))
        let client = YouTubeMusicClient(transport: transport, sessions: await session())
        _ = try await client.podcasts()
        _ = try await client.podcast(id: "PLfixture")
        _ = try await client.libraryPodcasts()
        _ = try await client.savedEpisodes()
        let requests = await transport.requests
        XCTAssertEqual(try requests.map { try body($0)["browseId"] as? String },
                       ["FEmusic_podcasts", "MPSPPLfixture", "FEmusic_library_non_music_audio_list", "VLSE"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/youtubei/v1/browse" })
        XCTAssertFalse(client.supportsRemoteLibraryEdits)
    }

    func testPersonalPodcastRoutesNeverReadAnAnonymousAccount() async throws {
        let transport = PodcastTransport([])
        let client = YouTubeMusicClient(transport: transport)
        for operation in 0...2 {
            do {
                switch operation {
                case 0: _ = try await client.libraryPodcasts()
                case 1: _ = try await client.savedEpisodes()
                default: _ = try await client.playlist(id: "SE")
                }
                XCTFail("Expected signed-in requirement")
            } catch { XCTAssertEqual(error as? MusicServiceError, .signInRequired) }
        }
        do { _ = try await client.podcast(id: "UCnot-a-show"); XCTFail("Expected show ID") }
        catch { XCTAssertEqual(error as? MusicServiceError, .invalidInput) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testShowCardsAndEpisodeMetadataAreExplicitAndSeparateFromVideoID() async throws {
        let show: [String: Any] = ["musicTwoRowItemRenderer": ["title": ["runs": [["text": "Fixture show"]]],
            "navigationEndpoint": ["browseEndpoint": ["browseId": "MPSPPLfixture"]]]]
        let transport = PodcastTransport([shelf([show, episode()])])
        let page = try await YouTubeMusicClient(transport: transport, sessions: await session()).podcasts()
        guard case let .collection(collection) = page.items.first else { return XCTFail("Expected show") }
        XCTAssertEqual(collection.kind, .podcast)
        let track = try XCTUnwrap(page.tracks.first)
        XCTAssertEqual(track.id, "abcDEF12_-3")
        XCTAssertEqual(track.artist, "Fixture show")
        XCTAssertEqual(track.contentKind, .podcastEpisode)
        XCTAssertEqual(track.episode?.identity.browseID, "MPEDcanonical-episode")
        XCTAssertEqual(track.episode?.identity.showBrowseID, "MPSPPLfixture")
        XCTAssertEqual(track.episode?.publishedText, "Published fixture date")
        XCTAssertEqual(track.episode?.serviceProgressFraction, 0.25)
        XCTAssertEqual(track.duration, 1_800)
        XCTAssertNotEqual(MusicItem.track(track).id, "track:" + track.id)
    }

    func testExplicitEpisodeVideoTypeCanEstablishTheDocumentedEpisodeBrowseRoute() async throws {
        var row = episode()
        var renderer = try XCTUnwrap(row["musicMultiRowListItemRenderer"] as? [String: Any])
        renderer["title"] = ["runs": [["text": "Episode without direct browse link"]]]
        row["musicMultiRowListItemRenderer"] = renderer
        let parsed = try MusicResponseParser.parse(shelf([row]).data, preservesOccurrences: true)
        guard case let .track(track) = parsed.items.first else { return XCTFail("Expected episode") }
        XCTAssertEqual(track.contentKind, .podcastEpisode)
        XCTAssertEqual(track.episode?.identity.browseID, "MPEDabcDEF12_-3")
    }

    func testSongAndEpisodeWithTheSameVideoKeepDistinctContentIdentity() throws {
        let song: [String: Any] = ["musicResponsiveListItemRenderer": [
            "playlistItemData": ["videoId": "abcDEF12_-3"],
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Song"]]]]]],
        ]]
        let parsed = try MusicResponseParser.parse(shelf([song, episode()]).data, preservesOccurrences: false)
        XCTAssertEqual(parsed.items.count, 2)
        XCTAssertEqual(Set(parsed.items.map(\.id)).count, 2)
        guard case let .track(track) = parsed.items.first else { return XCTFail("Expected song") }
        XCTAssertNil(track.contentKind)
        XCTAssertNil(track.episode)
    }

    func testOnlyExplicitSongVideoTypesEstablishScrobblingEligibility() throws {
        for type in ["MUSIC_VIDEO_TYPE_ATV", "MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC", ""] {
            let row: [String: Any] = ["musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": "abcDEF12_-3"],
                "onTap": ["watchEndpoint": ["videoId": "abcDEF12_-3", "watchEndpointMusicSupportedConfigs": [
                    "watchEndpointMusicConfig": ["musicVideoType": type]]]],
                "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Song"]]]]]],
            ]]
            let parsed = try MusicResponseParser.parse(shelf([row]).data, preservesOccurrences: true)
            guard case let .track(track) = parsed.items.first else { return XCTFail("Expected track") }
            XCTAssertEqual(track.contentKind, ["MUSIC_VIDEO_TYPE_ATV", "MUSIC_VIDEO_TYPE_OMV"].contains(type) ? .song : nil)
            XCTAssertNil(track.episode)
        }
    }

    func testEpisodeContinuationPreservesMetadataAndRejectsOldAccount() async throws {
        let store = await session()
        let transport = PodcastTransport([shelf([episode()], token: "episode-next"), continuation([episode(videoID: "xyzABC98_-7", browseID: "MPEDsecond")])])
        let client = YouTubeMusicClient(transport: transport, sessions: store)
        let first = try await client.podcast(id: "MPSPPLfixture")
        let cursor = try XCTUnwrap(first.continuation)
        let next = try await client.nextPage(cursor)
        XCTAssertEqual(next.tracks.first?.episode?.identity.browseID, "MPEDsecond")
        XCTAssertEqual(next.tracks.first?.contentKind, .podcastEpisode)
        await store.clear()
        do { _ = try await client.nextPage(cursor); XCTFail("Expected account fence") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testServiceProgressMissingInvalidAndZeroStayDistinct() throws {
        for value in [Double?.none, -1, 0, 101] {
            let parsed = try MusicResponseParser.parse(shelf([episode(progress: value)]).data, preservesOccurrences: true)
            guard case let .track(track) = parsed.items.first else { return XCTFail("Expected episode") }
            XCTAssertEqual(track.episode?.serviceProgressFraction, value == 0 ? 0 : nil)
        }
    }

    func testShowSubtitleIsNeverMislabeledAsPublicationDate() throws {
        var row = episode()
        var renderer = try XCTUnwrap(row["musicMultiRowListItemRenderer"] as? [String: Any])
        renderer.removeValue(forKey: "publishedTimeText")
        renderer.removeValue(forKey: "secondTitle")
        renderer["subtitle"] = ["runs": [["text": "Fixture show", "navigationEndpoint": ["browseEndpoint": ["browseId": "MPSPPLfixture"]]]]]
        row["musicMultiRowListItemRenderer"] = renderer
        let parsed = try MusicResponseParser.parse(shelf([row]).data, preservesOccurrences: true)
        guard case let .track(track) = parsed.items.first else { return XCTFail("Expected episode") }
        XCTAssertEqual(track.artist, "Fixture show")
        XCTAssertNil(track.episode?.publishedText)
    }

    private func session() async -> MusicSessionStore {
        let store = MusicSessionStore()
        await store.replaceSession(accountID: "fixture", cookieHeader: "fixture=value", sapisid: "fixture",
            configuration: MusicClientConfiguration(apiKey: "fixture", clientVersion: "fixture"))
        return store
    }
}

private actor PodcastTransport: MusicHTTPTransport {
    private var responses: [MusicHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [MusicHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}
private func body(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
}
private func object(_ value: [String: Any]) -> MusicHTTPResponse { .init(data: try! JSONSerialization.data(withJSONObject: value), statusCode: 200) }
private func shelf(_ rows: [[String: Any]], token: String? = nil) -> MusicHTTPResponse {
    var shelf: [String: Any] = ["contents": rows]
    if let token { shelf["continuations"] = [["nextContinuationData": ["continuation": token]]] }
    return object(["contents": ["sectionListRenderer": ["contents": [["musicShelfRenderer": shelf]]]]])
}
private func continuation(_ rows: [[String: Any]]) -> MusicHTTPResponse {
    object(["continuationContents": ["musicShelfContinuation": ["contents": rows]]])
}
private func episode(videoID: String = "abcDEF12_-3", browseID: String = "MPEDcanonical-episode", progress: Double? = 25) -> [String: Any] {
    var renderer: [String: Any] = ["title": ["runs": [["text": "Fixture episode", "navigationEndpoint": ["browseEndpoint": ["browseId": browseID]]]]],
        "onTap": ["watchEndpoint": ["videoId": videoID, "watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"]]]],
        "secondTitle": ["runs": [["text": "Fixture show", "navigationEndpoint": ["browseEndpoint": ["browseId": "MPSPPLfixture"]]]]],
        "publishedTimeText": ["runs": [["text": "Published fixture date"]]], "durationText": ["runs": [["text": "30:00"]]],
        "description": ["runs": [["text": "Fixture episode description"]]],
    ]
    if let progress { renderer["playbackProgress"] = ["musicPlaybackProgressRenderer": ["playbackProgressPercentage": progress]] }
    return ["musicMultiRowListItemRenderer": renderer]
}
