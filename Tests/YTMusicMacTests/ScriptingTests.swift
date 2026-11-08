import AppKit
import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

@Suite("Scripting values")
struct ScriptingValueTests {
    @Test func videoIdentifiersAreExactAndURLSafe() {
        #expect(ScriptingInput.videoID("abcDEF12_-3") == "abcDEF12_-3")
        #expect(ScriptingInput.videoID("  abcDEF12_-3\n") == "abcDEF12_-3")
        for value: Any in ["", "short", "abcdefghijé", "abcdefghijkx", "https://youtu.be/abcDEF12_-3", "abcdefghi\"k", 12, true] {
            #expect(ScriptingInput.videoID(value) == nil)
        }
    }

    @Test func volumeAcceptsOnlyFiniteNumbersInRange() {
        #expect(ScriptingInput.volume(0) == 0)
        #expect(ScriptingInput.volume(0.75) == 0.75)
        #expect(ScriptingInput.volume(1) == 1)
        for value: Any in [-0.01, 1.01, Double.infinity, Double.nan, "0.5", true] {
            #expect(ScriptingInput.volume(value) == nil)
        }
    }

    @Test func statusContainsOnlyCurrentPlaybackFields() throws {
        let value = ScriptingPlayerInfo(playing: true, buffering: false, signedIn: true, currentTrackID: "abcDEF12_-3",
                                        position: 12.5, duration: 180, volume: 0.2, queueCount: 3, hasError: true)
        let data = try #require(value.json().data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["playing", "buffering", "signedIn", "currentTrackID", "position", "duration", "volume", "queueCount", "error"])
        #expect(object["error"] as? String == "playbackUnavailable")
        #expect(object["currentTrackID"] as? String == "abcDEF12_-3")
        #expect(object["position"] as? Double == 12.5)
    }

    @Test func invalidClockValuesCannotBreakStatusEncoding() throws {
        let value = ScriptingPlayerInfo(playing: false, buffering: false, signedIn: false, currentTrackID: nil,
                                        position: .nan, duration: -.infinity, volume: .infinity, queueCount: -1, hasError: false)
        let data = try #require(value.json().data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["position"] as? Double == 0)
        #expect(object["duration"] as? Double == 0)
        #expect(object["queueCount"] as? Int == 0)
        #expect(object["currentTrackID"] == nil)
        #expect(object["error"] == nil)
    }

    @Test func failureCodesDoNotIncludeUnrecognizedPageText() throws {
        for raw in ["private account value", "https://example.com/?token=secret", "", "media_error"] {
            let reason = PlaybackFailureReason.bridgeError(raw)
            #expect(reason == .mediaUnavailable)
            let value = ScriptingPlayerInfo(playing: false, buffering: false, signedIn: true,
                currentTrackID: nil, position: 0, duration: 0, volume: 0.5, queueCount: 1,
                hasError: true, failureReason: reason)
            let data = try #require(value.json().data(using: .utf8))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["error"] as? String == "mediaUnavailable")
        }
        #expect(PlaybackFailureReason.bridgeError("playback_blocked") == .playbackBlocked)
        #expect(PlaybackFailureReason.bridgeError("target_changed") == .targetChanged)
    }

    @Test func lookupSelectsTheExactVideoRatherThanTheFirstResult() async throws {
        let wanted = Track(id: "abcDEF12_-3", title: "Requested song", artist: "Artist")
        let result = try await ScriptedTrackResolver.resolve(videoID: wanted.id) { query in
            #expect(query == wanted.id)
            return MusicPage(title: "Search", sections: [], items: [
                .track(Track(id: "other123456", title: "Different song", artist: "Artist")), .track(wanted),
            ])
        }
        #expect(result == wanted)
    }

    @Test func lookupDoesNotSubstituteAnUnrelatedTrack() async {
        await #expect(throws: AppScriptingError.trackNotFound) {
            try await ScriptedTrackResolver.resolve(videoID: "abcDEF12_-3") { _ in
                MusicPage(title: "Search", sections: [], items: [
                    .track(Track(id: "other123456", title: "Different song", artist: "Artist")),
                ])
            }
        }
    }

    @Test func invalidLookupNeverCallsTheCatalog() async {
        await #expect(throws: AppScriptingError.invalidVideoID) {
            try await ScriptedTrackResolver.resolve(videoID: "https://example.com") { _ in
                Issue.record("Invalid identifiers must not reach the catalog.")
                return MusicPage(title: "Search", sections: [], items: [])
            }
        }
    }

    @Test func lookupHasABoundedDeadline() async {
        await #expect(throws: AppScriptingError.lookupTimedOut) {
            try await ScriptedTrackResolver.resolve(videoID: "abcDEF12_-3", timeout: .milliseconds(5)) { _ in
                try await Task.sleep(for: .seconds(60))
                return MusicPage(title: "Search", sections: [], items: [])
            }
        }
    }

    @Test func cancelledLookupDoesNotReturnAPlayableTrack() async {
        let task = Task {
            try await ScriptedTrackResolver.resolve(videoID: "abcDEF12_-3") { _ in
                try? await Task.sleep(for: .seconds(60))
                return MusicPage(title: "Search", sections: [], items: [
                    .track(Track(id: "abcDEF12_-3", title: "Song", artist: "Artist")),
                ])
            }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@MainActor
@Suite("Scripting commands", .serialized)
struct ScriptingCommandTests {
    @Test func commandsFailCleanlyWithoutAnAppSession() {
        AppScripting.session = nil
        let commands: [NSScriptCommand] = [PlayScriptCommand(), PauseScriptCommand(), GetPlayerInfoScriptCommand(), CheckLibraryScriptCommand(), CheckLibraryNavigationScriptCommand(), RetryPlaylistCleanupScriptCommand()]
        for command in commands {
            #expect(command.performDefaultImplementation() == nil)
            #expect(command.scriptErrorNumber == -1728)
        }
        let playVideo = PlayVideoScriptCommand()
        playVideo.directParameter = "abcDEF12_-3"
        #expect(playVideo.performDefaultImplementation() == nil)
        #expect(playVideo.scriptErrorNumber == -1728)
        let playlist = CheckPlaylistEditsScriptCommand()
        playlist.directParameter = "abcDEF12_-3"
        #expect(playlist.performDefaultImplementation() == nil)
        #expect(playlist.scriptErrorNumber == -1728)
        let volume = SetVolumeScriptCommand()
        volume.directParameter = 0.5
        #expect(volume.performDefaultImplementation() == nil)
        #expect(volume.scriptErrorNumber == -1728)
    }

    @Test func malformedDirectParametersUseAppleEventCoercionErrors() {
        let playVideo = PlayVideoScriptCommand()
        playVideo.directParameter = "https://example.com"
        #expect(playVideo.performDefaultImplementation() == nil)
        #expect(playVideo.scriptErrorNumber == -1700)
        let playlist = CheckPlaylistEditsScriptCommand()
        playlist.directParameter = "https://example.com"
        #expect(playlist.performDefaultImplementation() == nil)
        #expect(playlist.scriptErrorNumber == -1700)
        let volume = SetVolumeScriptCommand()
        volume.directParameter = 50
        #expect(volume.performDefaultImplementation() == nil)
        #expect(volume.scriptErrorNumber == -1700)
    }

    @Test func dictionaryCommandsResolveToNativeClasses() throws {
        let url = try #require(AppIdentity.resourceBundle.url(forResource: "YTMusicMac", withExtension: "sdef"))
        let document = try XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever])
        let commands = try document.nodes(forXPath: "/dictionary/suite/command")
        let queueResult = try document.nodes(forXPath: "/dictionary/suite/command[@code='YTMcpvds']/result/@type")
        #expect(queueResult.first?.stringValue == "integer")
        #expect(commands.count == 16)
        var codes = Set<String>()
        var names = Set<String>()
        for node in commands {
            let command = try #require(node as? XMLElement)
            let code = try #require(command.attribute(forName: "code")?.stringValue)
            #expect(code.utf8.count == 8)
            #expect(codes.insert(code).inserted)
            names.insert(try #require(command.attribute(forName: "name")?.stringValue))
            let cocoa = try #require(command.elements(forName: "cocoa").first)
            let className = try #require(cocoa.attribute(forName: "class")?.stringValue)
            #expect(NSClassFromString(className) != nil)
        }
        #expect(names == ["quit", "play", "play video", "pause", "set volume", "get player info", "check library",
                          "play videos", "check library navigation", "check playlist edits", "retry playlist check cleanup", "seek to", "next track", "previous track", "set repeat", "get playback snapshot"])
        #expect(codes.contains("YTMcpvid"))
        #expect(codes.contains("YTMcinfo"))
        #expect(codes.contains("YTMcclib"))
    }
}
