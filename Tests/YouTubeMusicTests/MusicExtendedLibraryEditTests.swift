import Foundation
import XCTest
@testable import YouTubeMusic

@MainActor
final class MusicExtendedLibraryEditTests: XCTestCase {
    private let first = PlaylistItemReference(videoID: "same-song", setVideoID: "first=")
    private let second = PlaylistItemReference(videoID: "same-song", setVideoID: "second=")
    private let third = PlaylistItemReference(videoID: "other-song", setVideoID: "third=")
    private let all = MusicLibraryEditCapabilities(playlistDescription: true, playlistPrivacy: true, playlistReorder: true,
                                                  albumLibrary: true, artistSubscriptions: true)

    func testNewCapabilitiesStayIndependentFromVerifiedBasicEdits() async throws {
        let actions: [MusicLibraryEditAction] = [
            .setPlaylistDescription(id: "PLtest", description: "Text"), .setPlaylistPrivacy(id: "PLtest", privacy: .unlisted),
            .movePlaylistItem(playlistID: "PLtest", item: first, before: second),
            .setAlbumSaved(browseID: "MPREbrowse", playlistID: "OLAKtarget", saved: true),
            .setArtistSubscribed(browseID: "UCbrowse", channelID: "UCtarget", subscribed: true),
        ]
        let flags: [MusicLibraryEditCapabilities] = [.init(playlistDescription: true), .init(playlistPrivacy: true),
            .init(playlistReorder: true), .init(albumLibrary: true), .init(artistSubscriptions: true)]
        let transport = ExtendedEditTransport([])
        let client = await client(transport, capabilities: .init(likes: true, dislikes: true, playlists: true))
        for (index, action) in actions.enumerated() {
            XCTAssertFalse(MusicLibraryEditCapabilities().allows(action))
            for (flagIndex, flag) in flags.enumerated() { XCTAssertEqual(flag.allows(action), index == flagIndex) }
            do { _ = try await client.performLibraryEdit(action); XCTFail("Expected separate capability") }
            catch { XCTAssertEqual(error as? MusicLibraryEditError, .featureUnavailable) }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testDescriptionCanBeClearedOnlyAfterKnownStateAndMatchingReadback() async throws {
        let transport = ExtendedEditTransport([.response(playlist(description: "Original")), .response(confirmed()),
                                               .response(playlist(description: ""))])
        let result = try await client(transport).performLibraryEdit(.setPlaylistDescription(id: "VLPLtest", description: ""))
        XCTAssertEqual(result, .playlistDescriptionChanged(id: "PLtest"))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(try body(requests[1])["actions"] as? [[String: String]],
                       [["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": ""]])
        XCTAssertEqual(try body(requests[1])["playlistId"] as? String, "PLtest")
    }

    func testPrivacyRequiresReadbackAndUsesTheExactEnumValue() async throws {
        let transport = ExtendedEditTransport([.response(playlist(privacy: "PRIVATE")), .response(confirmed()),
                                               .response(playlist(privacy: "UNLISTED"))])
        let result = try await client(transport).performLibraryEdit(.setPlaylistPrivacy(id: "PLtest", privacy: .unlisted))
        XCTAssertEqual(result, .playlistPrivacyChanged(id: "PLtest", privacy: .unlisted))
        let requests = await transport.requests
        XCTAssertEqual(try body(requests[1])["actions"] as? [[String: String]],
                       [["action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": "UNLISTED"]])
    }

    func testReorderUsesOccurrenceIdentityAndOmittedSuccessorMeansEnd() async throws {
        let transport = ExtendedEditTransport([.response(playlist(items: [first, second, third])), .response(confirmed()),
            .response(playlist(items: [second, first, third])), .response(playlist(items: [second, first, third])),
            .response(confirmed()), .response(playlist(items: [first, third, second]))])
        let client = await client(transport)
        let before = try await client.performLibraryEdit(.movePlaylistItem(playlistID: "PLtest", item: second, before: first))
        XCTAssertEqual(before, .playlistItemMoved(playlistID: "PLtest", item: second, before: first))
        let end = try await client.performLibraryEdit(.movePlaylistItem(playlistID: "PLtest", item: second, before: nil))
        XCTAssertEqual(end, .playlistItemMoved(playlistID: "PLtest", item: second, before: nil))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(try body(requests[1])["actions"] as? [[String: String]],
                       [["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": second.setVideoID, "movedSetVideoIdSuccessor": first.setVideoID]])
        XCTAssertEqual(try body(requests[4])["actions"] as? [[String: String]],
                       [["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": second.setVideoID]])
    }

    func testReorderFindsAndConfirmsOccurrencesAcrossContinuationPages() async throws {
        let transport = ExtendedEditTransport([.response(playlist(items: [first], continuation: "pre-next")),
            .response(continuation([second, third])), .response(confirmed()),
            .response(playlist(items: [second], continuation: "post-next")), .response(continuation([first, third]))])
        let result = try await client(transport).performLibraryEdit(.movePlaylistItem(playlistID: "PLtest", item: second, before: first))
        XCTAssertEqual(result, .playlistItemMoved(playlistID: "PLtest", item: second, before: first))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(try body(requests[1])["continuation"] as? String, "pre-next")
        XCTAssertEqual(try body(requests[4])["continuation"] as? String, "post-next")
    }

    func testMissingPermissionStateOrOccurrencePreventsTheWrite() async throws {
        let cases: [(MusicLibraryEditAction, MusicHTTPResponse)] = [
            (.setPlaylistDescription(id: "PLtest", description: "New"), playlist(description: nil)),
            (.setPlaylistPrivacy(id: "PLtest", privacy: .public), playlist(privacy: nil)),
            (.setPlaylistPrivacy(id: "PLtest", privacy: .public), playlist(editable: false)),
            (.movePlaylistItem(playlistID: "PLtest", item: second, before: first), playlist(items: [first])),
            (.movePlaylistItem(playlistID: "PLtest", item: second, before: first), playlist(items: [first, second], editable: false)),
            (.setAlbumSaved(browseID: "MPREbrowse", playlistID: "OLAKtarget", saved: true), page(header: [:])),
            (.setArtistSubscribed(browseID: "UCbrowse", channelID: "UCtarget", subscribed: true), page(header: [:])),
        ]
        for (action, response) in cases {
            let transport = ExtendedEditTransport([.response(response)])
            do { _ = try await client(transport).performLibraryEdit(action); XCTFail("Expected permission/state refusal") }
            catch { XCTAssertEqual(error as? MusicLibraryEditError, .collectionStateUnavailable) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/youtubei/v1/browse" })
        }
    }

    func testMismatchedReadbackIsUnconfirmedAndNeverRepeatsTheWrite() async throws {
        let cases: [(MusicLibraryEditAction, MusicHTTPResponse)] = [
            (.setPlaylistDescription(id: "PLtest", description: "New"), playlist(description: "Old")),
            (.setPlaylistPrivacy(id: "PLtest", privacy: .public), playlist(privacy: "PRIVATE")),
            (.movePlaylistItem(playlistID: "PLtest", item: second, before: first), playlist(items: [first, second])),
            (.setAlbumSaved(browseID: "MPREbrowse", playlistID: "OLAKtarget", saved: true), album(saved: false)),
            (.setArtistSubscribed(browseID: "UCbrowse", channelID: "UCtarget", subscribed: true), artist(subscribed: false)),
        ]
        for (action, original) in cases {
            let transport = ExtendedEditTransport([.response(original), .response(confirmed()), .response(original)])
            do { _ = try await client(transport).performLibraryEdit(action); XCTFail("Expected readback uncertainty") }
            catch { XCTAssertEqual(error as? MusicLibraryEditError, .unconfirmedOutcome) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 3)
            XCTAssertEqual(requests.filter { $0.url?.path != "/youtubei/v1/browse" }.count, 1)
        }
    }

    func testDifferentMutationTargetsNeverBorrowTheCurrentHeadersPermission() async throws {
        let cases: [(MusicLibraryEditAction, MusicHTTPResponse)] = [
            (.setAlbumSaved(browseID: "MPREbrowse", playlistID: "OLAKother", saved: true), album(saved: false)),
            (.setArtistSubscribed(browseID: "UCbrowse", channelID: "UCother", subscribed: true), artist(subscribed: false)),
        ]
        for (action, original) in cases {
            let transport = ExtendedEditTransport([.response(original)])
            do { _ = try await client(transport).performLibraryEdit(action); XCTFail("Expected exact target guard") }
            catch { XCTAssertEqual(error as? MusicLibraryEditError, .collectionStateUnavailable) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testOversizedAndAmbiguousReorderSnapshotsNeverWrite() async throws {
        let large = (0...10_000).map { PlaylistItemReference(videoID: "same-song", setVideoID: "occurrence-\($0)=") }
        for (items, expected) in [([first, second, first], MusicServiceError?.none), (large, .pageLimitReached)] {
            let transport = ExtendedEditTransport([.response(playlist(items: items))])
            do { _ = try await client(transport).performLibraryEdit(.movePlaylistItem(playlistID: "PLtest", item: first, before: second)); XCTFail("Expected bounded unambiguous occurrences") }
            catch {
                if let expected { XCTAssertEqual(error as? MusicServiceError, expected) }
                else { XCTAssertEqual(error as? MusicLibraryEditError, .invalidPlaylistItems) }
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testAlbumSaveAndUnsaveKeepBrowseAndMutationTargetsSeparate() async throws {
        let transport = ExtendedEditTransport([.response(album(saved: false)), .response(confirmed()), .response(album(saved: true)),
                                               .response(album(saved: true)), .response(confirmed()), .response(album(saved: false))])
        let client = await client(transport)
        let saved = try await client.performLibraryEdit(.setAlbumSaved(browseID: "MPREbrowse", playlistID: "OLAKtarget", saved: true))
        XCTAssertEqual(saved, .albumSaved(browseID: "MPREbrowse", saved: true))
        let removed = try await client.performLibraryEdit(.setAlbumSaved(browseID: "MPREbrowse", playlistID: "OLAKtarget", saved: false))
        XCTAssertEqual(removed, .albumSaved(browseID: "MPREbrowse", saved: false))
        let requests = await transport.requests
        XCTAssertEqual(requests[1].url?.path, "/youtubei/v1/like/like")
        XCTAssertEqual(requests[4].url?.path, "/youtubei/v1/like/removelike")
        XCTAssertEqual(try body(requests[1])["target"] as? [String: String], ["playlistId": "OLAKtarget"])
        XCTAssertEqual(try body(requests[0])["browseId"] as? String, "MPREbrowse")
    }

    func testArtistUsesHeaderChannelRatherThanBrowseIdentity() async throws {
        let transport = ExtendedEditTransport([.response(artist(subscribed: false)), .response(confirmed()), .response(artist(subscribed: true)),
                                               .response(artist(subscribed: true)), .response(confirmed()), .response(artist(subscribed: false))])
        let client = await client(transport)
        let followed = try await client.performLibraryEdit(.setArtistSubscribed(browseID: "UCbrowse", channelID: "UCtarget", subscribed: true))
        XCTAssertEqual(followed, .artistSubscribed(browseID: "UCbrowse", subscribed: true))
        let unfollowed = try await client.performLibraryEdit(.setArtistSubscribed(browseID: "UCbrowse", channelID: "UCtarget", subscribed: false))
        XCTAssertEqual(unfollowed, .artistSubscribed(browseID: "UCbrowse", subscribed: false))
        let requests = await transport.requests
        XCTAssertEqual(requests[1].url?.path, "/youtubei/v1/subscription/subscribe")
        XCTAssertEqual(requests[4].url?.path, "/youtubei/v1/subscription/unsubscribe")
        XCTAssertEqual(try body(requests[1])["channelIds"] as? [String], ["UCtarget"])
    }

    func testRefusedAndUncertainAcknowledgementsNeverTriggerReadbackOrRetry() async throws {
        let steps: [(ExtendedEditTransport.Step, MusicLibraryEditError?)] = [
            (.response(.init(data: Data(), statusCode: 403)), nil),
            (.response(response(["responseContext": [:]])), .unconfirmedOutcome), (.failure, .unconfirmedOutcome),
        ]
        for (step, expected) in steps {
            let transport = ExtendedEditTransport([.response(playlist()), step])
            do { _ = try await client(transport).performLibraryEdit(.setPlaylistPrivacy(id: "PLtest", privacy: .public)); XCTFail("Expected non-success") }
            catch {
                if let expected { XCTAssertEqual(error as? MusicLibraryEditError, expected) }
                else { XCTAssertEqual(error as? MusicServiceError, .accessDenied) }
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testAccountChangesFencePreflightWriteAndReadback() async throws {
        for boundary in 1...3 {
            let store = await session()
            let transport = ExtendedEditTransport([.response(playlist()), .response(confirmed()), .response(playlist(privacy: "PUBLIC"))],
                                                   store: store, clearAt: boundary)
            do { _ = try await client(transport, store: store).performLibraryEdit(.setPlaylistPrivacy(id: "PLtest", privacy: .public)); XCTFail("Expected account fence") }
            catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, boundary)
        }
    }

    func testOldExpectedScopeAndInvalidReorderNeverStartRequests() async throws {
        let transport = ExtendedEditTransport([])
        let client = await client(transport)
        do { _ = try await client.performLibraryEdit(.setPlaylistPrivacy(id: "PLtest", privacy: .public), expectedScope: UUID()); XCTFail("Expected account fence") }
        catch { XCTAssertEqual(error as? MusicServiceError, .sessionChanged) }
        do { _ = try await client.performLibraryEdit(.movePlaylistItem(playlistID: "PLtest", item: first, before: first)); XCTFail("Expected same occurrence refusal") }
        catch { XCTAssertEqual(error as? MusicLibraryEditError, .invalidPlaylistItems) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

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

    func testAlbumRemovalReadbackCannotConflateDislikeWithNeutral() async throws {
        let disliked = page(header: ["musicDetailHeaderRenderer": ["likeButtonRenderer": [
            "target": ["playlistId": "OLAKtarget"], "likeStatus": "DISLIKE",
        ]]])
        let transport = ExtendedEditTransport([.response(album(saved: true)), .response(confirmed()), .response(disliked)])
        do { _ = try await client(transport).performLibraryEdit(.setAlbumSaved(browseID: "MPREbrowse", playlistID: "OLAKtarget", saved: false)); XCTFail("Expected exact neutral readback") }
        catch { XCTAssertEqual(error as? MusicLibraryEditError, .unconfirmedOutcome) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testShelvesCannotGrantAnotherCollectionsControls() throws {
        let data = response(["contents": ["sectionListRenderer": ["contents": [["musicShelfRenderer": [
            "contents": [["musicTwoRowItemRenderer": ["title": ["runs": [["text": "Song"]]],
                "navigationEndpoint": ["watchEndpoint": ["videoId": "song"]]]],
                ["musicImmersiveHeaderRenderer": ["subscriptionButton": ["subscribeButtonRenderer": [
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
