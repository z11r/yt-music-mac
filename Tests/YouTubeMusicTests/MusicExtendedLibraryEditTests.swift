import Foundation
import XCTest
@testable import YouTubeMusic

@MainActor
final class MusicExtendedLibraryEditTests: XCTestCase {
    private let first = PlaylistItemReference(videoID: "same-song", setVideoID: "first=")
    private let second = PlaylistItemReference(videoID: "same-song", setVideoID: "second=")
    private let third = PlaylistItemReference(videoID: "other-song", setVideoID: "third=")
    private let all = MusicLibraryEditCapabilities()

    func testHeaderStatesPreserveUnknownEmptyDislikedAndContradictoryValues() throws {
        let empty = try MusicResponseParser.parse(playlist(description: "", privacy: "PRIVATE").data, preservesOccurrences: true)
        XCTAssertEqual(empty.playlistDetails, .init(description: "", privacy: .private))
        XCTAssertTrue(empty.playlistCapabilities.canEditDescription)
        XCTAssertTrue(empty.playlistCapabilities.canEditPrivacy)
        XCTAssertTrue(empty.playlistCapabilities.canReorder)
        let missing = try MusicResponseParser.parse(playlist(description: nil, privacy: nil).data, preservesOccurrences: true)
        XCTAssertNil(missing.playlistDetails)
        let disliked = try MusicResponseParser.parse(page(header: ["musicDetailHeaderRenderer": ["menu": [
            "likeButtonRenderer": ["target": ["playlistId": "OLAKtarget"], "likeStatus": "DISLIKE"],
        ]]]).data, preservesOccurrences: true)
        XCTAssertEqual(disliked.albumLibraryState?.rating, .disliked)
        XCTAssertEqual(disliked.albumLibraryState?.isSaved, false)
        let conflicting = try MusicResponseParser.parse(page(header: ["musicDetailHeaderRenderer": ["buttons": [
            ["likeButtonRenderer": ["target": ["playlistId": "OLAKtarget"], "likeStatus": "LIKE"]],
            ["likeButtonRenderer": ["target": ["playlistId": "OLAKtarget"], "likeStatus": "INDIFFERENT"]],
        ]]]).data, preservesOccurrences: true)
        XCTAssertNil(conflicting.albumLibraryState)
    }

    func testDisabledButtonsAndContradictoryArtistHeadersRemainUnknown() throws {
        let disabled = try MusicResponseParser.parse(page(header: ["musicResponsiveHeaderRenderer": ["buttons": [
            ["toggleButtonRenderer": ["isDisabled": true, "defaultServiceEndpoint": ["likeEndpoint": [
                "status": "LIKE", "target": ["playlistId": "OLAKtarget"],
            ]]]],
        ]], "musicImmersiveHeaderRenderer": ["subscriptionButton": ["subscribeButtonRenderer": [
            "channelId": "UCtarget", "subscribed": false, "enabled": false,
        ]]]]).data, preservesOccurrences: true)
        XCTAssertNil(disabled.albumLibraryState)
        XCTAssertNil(disabled.artistSubscription)
        let conflicting = try MusicResponseParser.parse(page(header: [
            "musicImmersiveHeaderRenderer": ["subscriptionButton": ["subscribeButtonRenderer": ["channelId": "UCone", "subscribed": false]]],
            "musicVisualHeaderRenderer": ["subscriptionButton": ["subscribeButtonRenderer": ["channelId": "UCtwo", "subscribed": true]]],
        ]).data, preservesOccurrences: true)
        XCTAssertNil(conflicting.artistSubscription)
    }

    func testShelvesCannotGrantAnotherCollectionsControls() throws {
        let data = response(["contents": ["sectionListRenderer": ["contents": [["musicShelfRenderer": [
            "contents": [["musicImmersiveHeaderRenderer": ["subscriptionButton": ["subscribeButtonRenderer": [
                "channelId": "UCtarget", "subscribed": true,
            ]]], "likeButtonRenderer": ["target": ["playlistId": "OLAKtarget"], "likeStatus": "LIKE"]]],
        ]]]]]]).data
        let parsed = try MusicResponseParser.parse(data, preservesOccurrences: false)
        XCTAssertNil(parsed.albumLibraryState)
        XCTAssertNil(parsed.artistSubscription)
    }

    func testWrappedResponsiveEditableHeaderRetainsDetailsAndDenial() throws {
        let header: [String: Any] = ["musicEditablePlaylistDetailHeaderRenderer": [
            "header": ["musicResponsiveHeaderRenderer": ["title": ["runs": [["text": "Current playlist"]]]]],
            "editHeader": ["musicPlaylistEditHeaderRenderer": ["privacy": "UNLISTED", "description": "Details"]],
            "isEditable": false,
        ]]
        let data = response(["contents": ["sectionListRenderer": ["contents": [header,
            ["musicPlaylistShelfRenderer": ["contents": []]],
        ]]]]).data
        let parsed = try MusicResponseParser.parse(data, preservesOccurrences: true)
        XCTAssertEqual(parsed.title, "Current playlist")
        XCTAssertEqual(parsed.playlistDetails, .init(description: "Details", privacy: .unlisted))
        XCTAssertFalse(parsed.playlistCapabilities.canReorder)
        XCTAssertFalse(parsed.playlistCapabilities.canEditPrivacy)
    }

    private func client(_ transport: ExtendedEditTransport, capabilities: MusicLibraryEditCapabilities? = nil,
                        store: MusicSessionStore? = nil) async -> YouTubeMusicClient {
        let store = if let store { store } else { await session() }
        return YouTubeMusicClient(transport: transport, sessions: store, libraryEditCapabilities: capabilities ?? all)
    }

    private func session() async -> MusicSessionStore {
        let store = MusicSessionStore()
        await store.replaceSession(accountID: "fixture-account", cookieHeader: "fixture=value", sapisid: "fixture",
            configuration: MusicClientConfiguration(apiKey: "fixture", clientVersion: "fixture"))
        return store
    }
}

private actor ExtendedEditTransport: MusicHTTPTransport {
    enum Step: Sendable { case response(MusicHTTPResponse), failure }
    private var steps: [Step]
    private let store: MusicSessionStore?
    private let clearAt: Int?
    private(set) var requests: [URLRequest] = []
    init(_ steps: [Step], store: MusicSessionStore? = nil, clearAt: Int? = nil) {
        self.steps = steps; self.store = store; self.clearAt = clearAt
    }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request)
        if requests.count == clearAt { await store?.clear() }
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        switch steps.removeFirst() {
        case let .response(value): return value
        case .failure: throw URLError(.networkConnectionLost)
        }
    }
}

private func body(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
}
private func response(_ object: [String: Any]) -> MusicHTTPResponse {
    .init(data: try! JSONSerialization.data(withJSONObject: object), statusCode: 200)
}
private func confirmed() -> MusicHTTPResponse { response(["status": "STATUS_SUCCEEDED"]) }
private func row(_ item: PlaylistItemReference) -> [String: Any] {
    ["musicResponsiveListItemRenderer": ["playlistItemData": ["videoId": item.videoID, "playlistSetVideoId": item.setVideoID],
        "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Fixture song"]]]]]]]]
}
private func page(header: [String: Any]) -> MusicHTTPResponse {
    response(["header": header, "contents": ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": ["contents": []]]]]]])
}
private func playlist(description: String? = "Original", privacy: String? = "PRIVATE", items: [PlaylistItemReference] = [],
                      editable: Bool = true, continuation: String? = nil) -> MusicHTTPResponse {
    var edit: [String: Any] = [:]
    if let description { edit["description"] = description }
    if let privacy { edit["privacy"] = privacy }
    var shelf: [String: Any] = ["contents": items.map(row)]
    if let continuation { shelf["continuations"] = [["nextContinuationData": ["continuation": continuation]]] }
    return response(["header": ["musicEditablePlaylistDetailHeaderRenderer": ["isEditable": editable,
        "editHeader": ["musicPlaylistEditHeaderRenderer": edit]]],
        "contents": ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": shelf]]]]])
}
private func continuation(_ items: [PlaylistItemReference]) -> MusicHTTPResponse {
    response(["continuationContents": ["musicPlaylistShelfContinuation": ["contents": items.map(row)]]])
}
private func album(saved: Bool) -> MusicHTTPResponse {
    page(header: ["musicResponsiveHeaderRenderer": ["buttons": [["toggleButtonRenderer": [
        "defaultServiceEndpoint": ["likeEndpoint": ["status": saved ? "INDIFFERENT" : "LIKE", "target": ["playlistId": "OLAKtarget"]]],
    ]]]]])
}
private func artist(subscribed: Bool) -> MusicHTTPResponse {
    page(header: ["musicImmersiveHeaderRenderer": ["subscriptionButton": ["subscribeButtonRenderer": [
        "channelId": "UCtarget", "subscribed": subscribed,
    ]]]])
}
