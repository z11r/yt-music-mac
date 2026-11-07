import AppKit
import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

@Suite("Queue scripting")
struct QueueScriptingTests {
    @Test func inputKeepsDuplicatesAndRejectsUnboundedOrMalformedQueues() {
        let id = "abcDEF12_-3"
        #expect(QueueScriptingInput.videoIDs([id, id]) == [id, id])
        #expect(QueueScriptingInput.videoIDs(Array(repeating: id, count: 100))?.count == 100)
        for value: Any in [[], [id, "invalid"], [id, 1], Array(repeating: id, count: 101), id] {
            #expect(QueueScriptingInput.videoIDs(value) == nil)
        }
        let tooMany = (0..<11).map { String(format: "video%06d", $0) }
        #expect(QueueScriptingInput.videoIDs(tooMany) == nil)
    }

    @Test func seekAndRepeatInputsRejectCoercionsAndNonfiniteValues() {
        #expect(QueueScriptingInput.position(30.5) == 30.5)
        #expect(QueueScriptingInput.position(0) == 0)
        for value: Any in [true, "30", -1, Double.nan, Double.infinity, 604_801] {
            #expect(QueueScriptingInput.position(value) == nil)
        }
        #expect(QueueScriptingInput.repeatMode("off") == .off)
        #expect(QueueScriptingInput.repeatMode("all") == .all)
        #expect(QueueScriptingInput.repeatMode("one") == .one)
        #expect(QueueScriptingInput.repeatMode("ON") == nil)
    }

    @Test func repeatedIDsAreResolvedOnceAndKeepTheirRequestedOrder() async throws {
        actor Queries {
            var counts: [String: Int] = [:]
            func search(_ id: String) -> MusicPage {
                counts[id, default: 0] += 1
                return MusicPage(title: "Search", sections: [], items: [
                    .track(Track(id: "wrong123456", title: "Other", artist: "Artist")),
                    .track(Track(id: id, title: "Song", artist: "Artist")),
                ])
            }
        }
        let queries = Queries()
        let ids = ["abcDEF12_-3", "second12345", "abcDEF12_-3"]
        let tracks = try await ScriptedQueueResolver.resolve(videoIDs: ids) { await queries.search($0) }
        #expect(tracks.map(\.id) == ids)
        #expect(await queries.counts == ["abcDEF12_-3": 1, "second12345": 1])
    }

    @Test func missingTrackFailsTheWholeQueueAndInvalidInputMakesNoRequests() async {
        await #expect(throws: AppScriptingError.trackNotFound) {
            try await ScriptedQueueResolver.resolve(videoIDs: ["abcDEF12_-3", "second12345"]) { id in
                MusicPage(title: "Search", sections: [], items: id == "abcDEF12_-3" ? [
                    .track(Track(id: id, title: "Song", artist: "Artist")),
                ] : [])
            }
        }
        await #expect(throws: AppScriptingError.invalidVideoID) {
            try await ScriptedQueueResolver.resolve(videoIDs: ["invalid"]) { _ in
                Issue.record("Invalid queue must not reach the service")
                return MusicPage(title: "Search", sections: [], items: [])
            }
        }
    }

    @Test func queueLookupHasOneDeadlineForTheWholeRequest() async {
        await #expect(throws: AppScriptingError.lookupTimedOut) {
            try await ScriptedQueueResolver.resolve(videoIDs: ["abcDEF12_-3"], timeout: .milliseconds(5)) { _ in
                try await Task.sleep(for: .seconds(30))
                return MusicPage(title: "Search", sections: [], items: [])
            }
        }
    }

    @MainActor @Test func commandsDoNotStartPlaybackWithoutAnAppSession() {
        AppScripting.session = nil
        let play = PlayVideosScriptCommand()
        play.directParameter = ["abcDEF12_-3"]
        let seek = SeekScriptCommand()
        seek.directParameter = 30
        let repeated = SetRepeatScriptCommand()
        repeated.directParameter = "all"
        let commands: [NSScriptCommand] = [play, seek, repeated, NextScriptCommand(),
            PreviousScriptCommand(), PlaybackSnapshotScriptCommand()]
        for command in commands {
            #expect(command.performDefaultImplementation() == nil)
            #expect(command.scriptErrorNumber == -1728)
        }
    }
}

struct VolumeStateTests {
    @Test func muteUsesTheSharedLastAudibleValueAcrossControls() {
        var state = VolumeState()
        state.record(0.2)
        #expect(state.toggledVolume(from: 0.2) == 0)
        state.record(0)
        #expect(state.toggledVolume(from: 0) == 0.2)
        state.record(0.9)
        state.record(.nan)
        state.record(-1)
        #expect(state.toggledVolume(from: 0) == 0.9)
    }
}
