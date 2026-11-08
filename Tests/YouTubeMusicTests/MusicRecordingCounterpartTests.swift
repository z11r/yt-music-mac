import Foundation
import MusicCore
import Testing
@testable import YouTubeMusic

@Suite("Exact service recording counterparts")
struct MusicRecordingCounterpartTests {
    @Test func oppositeTypesAreEstablishedByTheSameWrapperWithoutTitleOrTimelineMatching() throws {
        for reverse in [false, true] {
            let primary = recordingRow("abcDEF12_-3", type: reverse ? "MUSIC_VIDEO_TYPE_OMV" : "MUSIC_VIDEO_TYPE_ATV")
            let other = recordingRow("xyzABC98_-7", type: reverse ? "MUSIC_VIDEO_TYPE_ATV" : "MUSIC_VIDEO_TYPE_OMV", title: "Different version %@ العربية", duration: "4:10")
            let result = try MusicRecordingCounterpartParser.parse(recordingPage([recordingWrapper(primary, other)]), videoID: "abcDEF12_-3")
            guard case let .available(pair) = result else { Issue.record("Expected explicit pair"); continue }
            #expect(pair.primaryVideoID == "abcDEF12_-3" && pair.track.id == "xyzABC98_-7")
            #expect(pair.primaryKind == (reverse ? .video : .song) && pair.kind == (reverse ? .song : .video))
            #expect(pair.track.title == "Different version %@ العربية" && pair.track.artist == "Supplied Artist")
            #expect(pair.track.duration == 250 && pair.track.origin == .catalog && pair.track.contentKind == .song)
            #expect(pair.track.artworkURL == nil && pair.track.episode == nil)
        }
    }
    @Test func adjacentMatchingTitlesUnwrappedRowsAndCounterpartOnlyIdentityAreNotAPair() throws {
        let primary = recordingRow("abcDEF12_-3", type: "MUSIC_VIDEO_TYPE_ATV")
        let other = recordingRow("xyzABC98_-7", type: "MUSIC_VIDEO_TYPE_OMV")
        for rows in [[], [["playlistPanelVideoRenderer": primary]],
                     [["playlistPanelVideoRenderer": primary], ["playlistPanelVideoRenderer": other]],
                     [recordingWrapper(other, primary)], [recordingWrapper(recordingRow("otherID12_3", type: "MUSIC_VIDEO_TYPE_ATV"), other)]] {
            #expect(try MusicRecordingCounterpartParser.parse(recordingPage(rows), videoID: "abcDEF12_-3") == .unavailable)
        }
    }
    @Test func sameUnknownPodcastUploadOrUnplayableTypesRemainUnavailable() throws {
        let primary = recordingRow("abcDEF12_-3", type: "MUSIC_VIDEO_TYPE_ATV")
        for type in ["MUSIC_VIDEO_TYPE_ATV", "MUSIC_VIDEO_TYPE_UGC", "MUSIC_VIDEO_TYPE_PODCAST_EPISODE", "MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK", ""] {
            #expect(try parse(primary, recordingRow("xyzABC98_-7", type: type)) == .unavailable)
        }
        for key in ["unplayableText", "isPlayable"] {
            var other = recordingRow("xyzABC98_-7", type: "MUSIC_VIDEO_TYPE_OMV")
            other[key] = key == "isPlayable" ? false : ["simpleText": "Unavailable"] as Any
            #expect(try parse(primary, other) == .unavailable)
            #expect(try parse(other, primary, videoID: "xyzABC98_-7") == .unavailable)
        }
        var malformed = recordingRow("xyzABC98_-7", type: "MUSIC_VIDEO_TYPE_OMV"); malformed["isPlayable"] = "true"
        #expect(try parse(primary, malformed) == .unavailable)
        #expect(try parse(primary, recordingRow("abcDEF12_-3", type: "MUSIC_VIDEO_TYPE_OMV")) == .unavailable)
        #expect(try parse(primary, recordingRow("invalid", type: "MUSIC_VIDEO_TYPE_OMV")) == .unavailable)
    }
    @Test func contradictoryEndpointAndRootIdentitiesAreRejected() throws {
        let primary = recordingRow("abcDEF12_-3", type: "MUSIC_VIDEO_TYPE_ATV")
        var other = recordingRow("xyzABC98_-7", type: "MUSIC_VIDEO_TYPE_OMV")
        var endpoint = other["navigationEndpoint"] as! [String: Any], watch = endpoint["watchEndpoint"] as! [String: Any]
        watch["videoId"] = "otherID12_3"; endpoint["watchEndpoint"] = watch; other["navigationEndpoint"] = endpoint
        #expect(try parse(primary, other) == .unavailable)
        #expect(throws: MusicServiceError.unsupportedResponse) {
            _ = try MusicRecordingCounterpartParser.parse(recordingPage([recordingWrapper(primary, recordingRow("xyzABC98_-7", type: "MUSIC_VIDEO_TYPE_OMV"))], current: "otherID12_3"), videoID: "abcDEF12_-3")
        }
    }
    @Test func ambiguousCounterpartsQueuesDuplicatePrimariesAndUnselectedTabsFailClosed() throws {
        let primary = recordingRow("abcDEF12_-3", type: "MUSIC_VIDEO_TYPE_ATV"), other = recordingRow("xyzABC98_-7", type: "MUSIC_VIDEO_TYPE_OMV")
        let wrapper = recordingWrapper(primary, other)
        var duplicate = wrapper["playlistPanelVideoWrapperRenderer"] as! [String: Any]
        let counterpart = duplicate["counterpart"] as! [[String: Any]]; duplicate["counterpart"] = counterpart + counterpart
        #expect(throws: MusicServiceError.unsupportedResponse) { _ = try MusicRecordingCounterpartParser.parse(recordingPage([["playlistPanelVideoWrapperRenderer": duplicate]]), videoID: "abcDEF12_-3") }
        for rows in [[wrapper, wrapper], Array(repeating: wrapper, count: 201)] {
            #expect(throws: MusicServiceError.unsupportedResponse) { _ = try MusicRecordingCounterpartParser.parse(recordingPage(rows), videoID: "abcDEF12_-3") }
        }
        for tabs in [2, 9] {
            #expect(throws: MusicServiceError.unsupportedResponse) { _ = try MusicRecordingCounterpartParser.parse(recordingPage([wrapper], tabCount: tabs), videoID: "abcDEF12_-3") }
        }
        #expect(throws: MusicServiceError.unsupportedResponse) { _ = try MusicRecordingCounterpartParser.parse(recordingPage([wrapper], selected: false), videoID: "abcDEF12_-3") }
    }
    @Test func malformedAndOversizedMetadataAndResponsesCannotEnterTheReview() throws {
        let primary = recordingRow("abcDEF12_-3", type: "MUSIC_VIDEO_TYPE_ATV")
        for title in ["bad\u{0}text", String(repeating: "x", count: 1_025)] {
            #expect(throws: MusicServiceError.unsupportedResponse) { _ = try parse(primary, recordingRow("xyzABC98_-7", type: "MUSIC_VIDEO_TYPE_OMV", title: title)) }
        }
        var other = recordingRow("xyzABC98_-7", type: "MUSIC_VIDEO_TYPE_OMV")
        other.removeValue(forKey: "longBylineText")
        #expect(try parse(primary, other) == .unavailable)
        #expect(throws: MusicServiceError.invalidResponse) { _ = try MusicRecordingCounterpartParser.parse(Data(repeating: 32, count: 4 * 1_024 * 1_024 + 1), videoID: "abcDEF12_-3") }
        #expect(throws: MusicServiceError.invalidResponse) { _ = try MusicRecordingCounterpartParser.parse(Data("{".utf8), videoID: "abcDEF12_-3") }
    }
    @Test func clientReadsOnlyTheExactNextTargetAndDoesNotFollowTheQueue() async throws {
        let store = MusicSessionStore(); await authenticateRecordingStore(store)
        let transport = RecordingHTTP(try recordingPage([recordingWrapper(recordingRow("abcDEF12_-3", type: "MUSIC_VIDEO_TYPE_ATV"), recordingRow("xyzABC98_-7", type: "MUSIC_VIDEO_TYPE_OMV"))]))
        let client = YouTubeMusicClient(transport: transport, sessions: store)
        let scope = await store.snapshot().scope
        guard case .available = try await client.recordingCounterpart(videoID: "abcDEF12_-3", expectedScope: scope) else { Issue.record("Expected pair"); return }
        let requests = await transport.requests
        #expect(requests.count == 1 && requests[0].url?.path == "/youtubei/v1/next")
        let requestBody = try #require(requests[0].httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(body["videoId"] as? String == "abcDEF12_-3" && body["isAudioOnly"] as? Bool == true)
        #expect(body["playlistId"] == nil && body["continuation"] == nil && body["racyCheckOk"] == nil && body["contentCheckOk"] == nil)
    }
    @Test func invalidInputSignedOutAndStaleScopePerformZeroBootstrapOrHTTP() async throws {
        let store = MusicSessionStore(), transport = RecordingHTTP(Data())
        let client = YouTubeMusicClient(transport: transport, sessions: store)
        let oldScope = await store.snapshot().scope
        await #expect(throws: MusicServiceError.signInRequired) { _ = try await client.recordingCounterpart(videoID: "abcDEF12_-3", expectedScope: oldScope) }
        await #expect(throws: MusicServiceError.invalidInput) { _ = try await client.recordingCounterpart(videoID: "invalid", expectedScope: oldScope) }
        await authenticateRecordingStore(store)
        await #expect(throws: MusicServiceError.sessionChanged) { _ = try await client.recordingCounterpart(videoID: "abcDEF12_-3", expectedScope: oldScope) }
        #expect(await transport.requests.isEmpty)
    }
    @Test func changedCredentialsAfterTheResponseRevokeThePair() async throws {
        let store = MusicSessionStore(); await authenticateRecordingStore(store)
        let payload = try recordingPage([recordingWrapper(recordingRow("abcDEF12_-3", type: "MUSIC_VIDEO_TYPE_ATV"), recordingRow("xyzABC98_-7", type: "MUSIC_VIDEO_TYPE_OMV"))])
        let transport = RecordingHTTP(payload, beforeReply: { await store.clear() })
        let client = YouTubeMusicClient(transport: transport, sessions: store), scope = await store.snapshot().scope
        await #expect(throws: MusicServiceError.sessionChanged) { _ = try await client.recordingCounterpart(videoID: "abcDEF12_-3", expectedScope: scope) }
        #expect(await transport.requests.count == 1)
    }

    @Test func explicitNullIdentityPlayabilityAndTabFlagsCannotBecomeAbsentProof() throws {
        let data = try recordingPage([recordingWrapper(recordingRow("abcDEF12_-3", type: "MUSIC_VIDEO_TYPE_ATV"), recordingRow("xyzABC98_-7", type: "MUSIC_VIDEO_TYPE_OMV"))], current: "abcDEF12_-3")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tab = ["contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs", "0", "tabRenderer"]
        let wrapper = tab + ["content", "musicQueueRenderer", "content", "playlistPanelRenderer", "contents", "0", "playlistPanelVideoWrapperRenderer"]
        let primary = wrapper + ["primaryRenderer", "playlistPanelVideoRenderer"]
        let counterpart = wrapper + ["counterpart", "0", "counterpartRenderer", "playlistPanelVideoRenderer"]
        let paths = [["currentVideoEndpoint"], ["currentVideoEndpoint", "watchEndpoint"], ["currentVideoEndpoint", "watchEndpoint", "videoId"],
            primary + ["navigationEndpoint", "watchEndpoint", "videoId"], counterpart + ["navigationEndpoint", "watchEndpoint", "videoId"],
            primary + ["isPlayable"], counterpart + ["isPlayable"], primary + ["unplayableText"], counterpart + ["unplayableText"],
            tab + ["selected"], tab + ["disabled"], tab + ["unselectable"]]
        for path in paths {
            let modified = replacingRecordingValue(root, path: path[...], value: NSNull())
            #expect(!offersRecordingPair(try JSONSerialization.data(withJSONObject: modified)), "Explicit null must not be optional absence")
        }
        for flag in ["disabled", "unselectable"] {
            let modified = replacingRecordingValue(root, path: (tab + [flag])[...], value: "false")
            #expect(!offersRecordingPair(try JSONSerialization.data(withJSONObject: modified)), "Malformed flag must not be optional absence")
        }
    }

    @Test func documentedAbsentOptionalIdentifiersAndFlagsRemainSupported() throws {
        let data = try recordingPage([recordingWrapper(recordingRow("abcDEF12_-3", type: "MUSIC_VIDEO_TYPE_ATV"), recordingRow("xyzABC98_-7", type: "MUSIC_VIDEO_TYPE_OMV"))])
        var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tab = ["contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs", "0", "tabRenderer"]
        let wrapper = tab + ["content", "musicQueueRenderer", "content", "playlistPanelRenderer", "contents", "0", "playlistPanelVideoWrapperRenderer"]
        for path in [tab + ["selected"], wrapper + ["primaryRenderer", "playlistPanelVideoRenderer", "navigationEndpoint", "watchEndpoint", "videoId"],
                     wrapper + ["counterpart", "0", "counterpartRenderer", "playlistPanelVideoRenderer", "navigationEndpoint", "watchEndpoint", "videoId"]] {
            root = replacingRecordingValue(root, path: path[...], value: nil) as! [String: Any]
        }
        #expect(offersRecordingPair(try JSONSerialization.data(withJSONObject: root)))
    }
    private func parse(_ primary: [String: Any], _ other: [String: Any], videoID: String = "abcDEF12_-3") throws -> MusicRecordingCounterpartResult {
        try MusicRecordingCounterpartParser.parse(recordingPage([recordingWrapper(primary, other)]), videoID: videoID)
    }
}

private func offersRecordingPair(_ data: Data) -> Bool {
    guard let result = try? MusicRecordingCounterpartParser.parse(data, videoID: "abcDEF12_-3"), case .available = result else { return false }
    return true
}
private func replacingRecordingValue(_ original: Any, path: ArraySlice<String>, value: Any?) -> Any {
    guard let key = path.first else { return value ?? NSNull() }
    if let index = Int(key), var array = original as? [Any], array.indices.contains(index) {
        array[index] = replacingRecordingValue(array[index], path: path.dropFirst(), value: value); return array
    }
    var object = original as! [String: Any]
    if path.count == 1 { object[key] = value }
    else { object[key] = replacingRecordingValue(object[key] ?? [String: Any](), path: path.dropFirst(), value: value) }
    return object
}

private func recordingRow(_ id: String, type: String, title: String = "Source title", duration: String = "3:00") -> [String: Any] {
    ["videoId": id, "title": ["runs": [["text": title]]], "lengthText": ["runs": [["text": duration]]],
     "longBylineText": ["runs": [["text": "Supplied Artist"], ["text": " • "], ["text": "Album"]]],
     "navigationEndpoint": ["watchEndpoint": ["videoId": id, "watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": type]]]]]
}
private func recordingWrapper(_ primary: [String: Any], _ other: [String: Any]) -> [String: Any] {
    ["playlistPanelVideoWrapperRenderer": ["primaryRenderer": ["playlistPanelVideoRenderer": primary],
        "counterpart": [["counterpartRenderer": ["playlistPanelVideoRenderer": other]]]]]
}
private func recordingPage(_ rows: [[String: Any]], current: String? = nil, tabCount: Int = 1, selected: Bool = true) throws -> Data {
    let tab: [String: Any] = ["tabRenderer": ["selected": selected, "content": ["musicQueueRenderer": ["content": ["playlistPanelRenderer": [
        "contents": rows, "continuations": [["nextRadioContinuationData": ["continuation": "never-follow"]]]]]]]]]
    var root: [String: Any] = ["contents": ["singleColumnMusicWatchNextResultsRenderer": ["tabbedRenderer": ["watchNextTabbedResultsRenderer": ["tabs": Array(repeating: tab, count: tabCount)]]]]]
    if let current { root["currentVideoEndpoint"] = ["watchEndpoint": ["videoId": current]] }
    return try JSONSerialization.data(withJSONObject: root)
}
private func authenticateRecordingStore(_ store: MusicSessionStore) async {
    await store.replaceSession(accountID: "fixture", cookieHeader: "fixture=value", sapisid: "fixture", configuration: .init(apiKey: "fixture", clientVersion: "fixture"))
}
private actor RecordingHTTP: MusicHTTPTransport {
    let data: Data
    let beforeReply: @Sendable () async -> Void
    private(set) var requests: [URLRequest] = []
    init(_ data: Data, beforeReply: @escaping @Sendable () async -> Void = {}) { self.data = data; self.beforeReply = beforeReply }
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        requests.append(request); await beforeReply(); return .init(data: data, statusCode: 200)
    }
}
