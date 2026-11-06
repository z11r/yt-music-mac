import Foundation
import JavaScriptCore
import MusicCore
import Testing
@testable import YTMusicMac

private func occurrence(generation: UInt64 = 1) -> PlaybackOccurrence {
    PlaybackOccurrence(sessionID: UUID(), entryID: UUID(), trackID: "song", generation: generation)
}

private func payload(
    loadID: UUID,
    occurrence: PlaybackOccurrence,
    documentID: UUID,
    kind: String = "state",
    media: Int = 1,
    sequence: Int = 1,
    isAd: Bool = false
) -> [String: Any] {
    [
        "kind": kind, "loadID": loadID.uuidString,
        "identity": ["sessionID": occurrence.sessionID.uuidString, "entryID": occurrence.entryID.uuidString,
                     "trackID": occurrence.trackID, "generation": String(occurrence.generation)],
        "documentID": documentID.uuidString, "mediaGeneration": media, "sequence": sequence,
        "videoID": "song", "position": 10, "duration": 180, "volume": 0.75,
        "isPlaying": kind != "ended", "isBuffering": false, "isAd": isAd, "mediaReady": true,
    ]
}

@Suite("Playback event validation")
struct PlaybackEventValidationTests {
    @Test func onlySecureMusicNavigationIsAllowed() throws {
        let allowed = try #require(URL(string: "https://music.youtube.com/watch?v=song"))
        #expect(PlaybackNavigation.permits(allowed))
        for candidate in ["http://music.youtube.com", "https://music.youtube.com.example.org",
                          "https://user:password@music.youtube.com", "https://music.youtube.com:444",
                          "https://accounts.google.com", "javascript:alert(1)"] {
            #expect(!PlaybackNavigation.permits(try #require(URL(string: candidate))))
        }
        let target = try #require(PlaybackNavigation.watchURL(trackID: "song&other=value"))
        let components = try #require(URLComponents(url: target, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [URLQueryItem(name: "v", value: "song&other=value")])
    }

    @Test func eventsNeedMatchingLoadDocumentAndQueueOccurrence() throws {
        let loadID = UUID(), documentID = UUID(), request = occurrence()
        var gate = PlaybackEventGate()
        gate.activate(loadID: loadID, occurrence: request)
        gate.bind(documentID: documentID)
        let wrongLoad = try #require(PlaybackBridgeMessage.decode(payload(loadID: UUID(), occurrence: request, documentID: documentID)))
        let wrongDocument = try #require(PlaybackBridgeMessage.decode(payload(loadID: loadID, occurrence: request, documentID: UUID())))
        let wrongEntry = try #require(PlaybackBridgeMessage.decode(payload(loadID: loadID, occurrence: occurrence(), documentID: documentID)))
        let rejectedLoad = gate.accept(wrongLoad)
        let rejectedDocument = gate.accept(wrongDocument)
        let rejectedEntry = gate.accept(wrongEntry)
        #expect(!rejectedLoad && !rejectedDocument && !rejectedEntry)
        let valid = try #require(PlaybackBridgeMessage.decode(payload(loadID: loadID, occurrence: request, documentID: documentID)))
        let accepted = gate.accept(valid)
        #expect(accepted)
    }

    @Test func oldSequencesAndMediaCannotOverwriteCurrentState() throws {
        let loadID = UUID(), documentID = UUID(), request = occurrence()
        var gate = PlaybackEventGate()
        gate.activate(loadID: loadID, occurrence: request)
        gate.bind(documentID: documentID)
        let current = try #require(PlaybackBridgeMessage.decode(payload(loadID: loadID, occurrence: request, documentID: documentID, media: 3, sequence: 9)))
        let accepted = gate.accept(current)
        let duplicate = gate.accept(current)
        let stale = try #require(PlaybackBridgeMessage.decode(payload(loadID: loadID, occurrence: request, documentID: documentID, media: 2, sequence: 10)))
        let acceptedStale = gate.accept(stale)
        #expect(accepted && !duplicate && !acceptedStale)
    }

    @Test func anEndIsConsumedOnceAndAnAdvertisementCannotEndTheSong() throws {
        let loadID = UUID(), documentID = UUID(), request = occurrence()
        var gate = PlaybackEventGate()
        gate.activate(loadID: loadID, occurrence: request)
        gate.bind(documentID: documentID)
        let ad = try #require(PlaybackBridgeMessage.decode(payload(loadID: loadID, occurrence: request, documentID: documentID, kind: "ended", isAd: true)))
        let rejectedAd = gate.accept(ad)
        let end = try #require(PlaybackBridgeMessage.decode(payload(loadID: loadID, occurrence: request, documentID: documentID, kind: "ended", sequence: 2)))
        let acceptedEnd = gate.accept(end)
        let laterEnd = try #require(PlaybackBridgeMessage.decode(payload(loadID: loadID, occurrence: request, documentID: documentID, kind: "ended", sequence: 3)))
        let duplicate = gate.accept(laterEnd)
        #expect(!rejectedAd && acceptedEnd && !duplicate)
    }

    @Test func malformedMessagesAndLargeBodiesAreRejected() {
        var body = payload(loadID: UUID(), occurrence: occurrence(), documentID: UUID())
        body["position"] = -1
        #expect(PlaybackBridgeMessage.decode(body) == nil)
        body["position"] = true
        #expect(PlaybackBridgeMessage.decode(body) == nil)
        body["position"] = 0
        body["videoID"] = String(repeating: "x", count: 17_000)
        #expect(PlaybackBridgeMessage.decode(body) == nil)
    }

    @Test func aRetryRejectsThePreviousLoadEvenForTheSameQueueOccurrence() throws {
        let oldLoad = UUID(), newLoad = UUID(), documentID = UUID(), request = occurrence()
        var gate = PlaybackEventGate()
        gate.activate(loadID: newLoad, occurrence: request)
        gate.bind(documentID: documentID)
        let oldEnd = try #require(PlaybackBridgeMessage.decode(payload(loadID: oldLoad, occurrence: request, documentID: documentID, kind: "ended")))
        let accepted = gate.accept(oldEnd)
        #expect(!accepted)
    }

    @Test func repeatedPlaysOfTheSameEntryUseTheFullGenerationValue() throws {
        let loadID = UUID(), documentID = UUID()
        let previous = occurrence(generation: UInt64.max - 1)
        let current = PlaybackOccurrence(sessionID: previous.sessionID, entryID: previous.entryID,
                                         trackID: previous.trackID, generation: UInt64.max)
        var gate = PlaybackEventGate()
        gate.activate(loadID: loadID, occurrence: current)
        gate.bind(documentID: documentID)
        let stale = try #require(PlaybackBridgeMessage.decode(payload(loadID: loadID, occurrence: previous, documentID: documentID, kind: "ended")))
        let rejected = gate.accept(stale)
        #expect(!rejected)
        let fresh = try #require(PlaybackBridgeMessage.decode(payload(loadID: loadID, occurrence: current, documentID: documentID, kind: "ended", sequence: 2)))
        let accepted = gate.accept(fresh)
        #expect(accepted)
    }
}

@MainActor
private final class BridgeFixture {
    let context: JSContext

    init() throws {
        self.context = try #require(JSContext())
        self.context.evaluateScript(Self.environment)
        let url = try #require(AppIdentity.resourceBundle.url(forResource: "PlayerBridge", withExtension: "js"))
        self.context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        #expect(self.context.exception == nil)
    }

    @discardableResult
    func run(_ script: String) -> JSValue {
        let value = self.context.evaluateScript(script)!
        #expect(self.context.exception == nil)
        return value
    }

    static let environment = """
    const messages = [];
    globalThis.window = globalThis;
    const navigations = [];
    globalThis.location = {href: 'https://music.youtube.com/watch?v=song', replace(value) {navigations.push(value);}};
    globalThis.crypto = {randomUUID: () => '00000000-0000-4000-8000-000000000001'};
    globalThis.URL = function(value) {this.searchParams = {get: () => value.split('v=')[1] || ''};};
    globalThis.webkit = {messageHandlers: {playerBridge: {postMessage: value => messages.push(value)}}};
    globalThis.addEventListener = () => {};
    globalThis.MutationObserver = class {observe() {}};
    let ad = false;
    const media = {
        tagName: 'VIDEO', isConnected: true, currentTime: 0, duration: 180,
        paused: true, ended: false, readyState: 1, volume: 1, listeners: {},
        addEventListener(name, action) {this.listeners[name] = action;},
        removeEventListener(name) {delete this.listeners[name];},
        pause() {this.paused = true;},
        play() {this.paused = false; return {catch() {}};},
        emit(name) {if (this.listeners[name]) this.listeners[name]({type: name, target: this});}
    };
    globalThis.document = {
        querySelector(selector) {return selector === '#movie_player' ? {classList: {contains: () => ad}} : media;},
        addEventListener() {}
    };
    const binding = {
        loadID: '00000000-0000-4000-8000-000000000002', autoplay: true, volume: 0.5,
        identity: {sessionID: '00000000-0000-4000-8000-000000000003',
                   entryID: '00000000-0000-4000-8000-000000000004', trackID: 'song', generation: '1'}
    };
    """
}

@MainActor
@Suite("Player script")
struct PlaybackScriptTests {
    @Test func replacementNavigationRejectsCallsFromAnOlderDocument() throws {
        let fixture = try BridgeFixture()
        fixture.run("YTMusicNativePlayer.bind(binding)")
        let stale = fixture.run("YTMusicNativePlayer.replaceNavigation({documentID: 'old-document', revision: 99, targetURL: 'https://music.youtube.com/watch?v=old'})")
        #expect(!stale.toBool())
        #expect(fixture.run("navigations.length").toInt32() == 0)
        #expect(!fixture.run("media.paused").toBool())
        let fresh = fixture.run("YTMusicNativePlayer.replaceNavigation({documentID: messages[0].documentID, revision: 2, targetURL: 'https://music.youtube.com/watch?v=next'})")
        #expect(fresh.toBool())
        #expect(fixture.run("media.paused").toBool())
        let older = fixture.run("YTMusicNativePlayer.replaceNavigation({documentID: messages[0].documentID, revision: 1, targetURL: 'https://music.youtube.com/watch?v=old'})")
        #expect(!older.toBool())
        #expect(fixture.run("navigations.length").toInt32() == 1)
    }

    @Test func playbackRequiresNativeBinding() throws {
        let fixture = try BridgeFixture()
        #expect(fixture.run("media.paused").toBool())
        fixture.run("YTMusicNativePlayer.bind(binding)")
        #expect(!fixture.run("media.paused").toBool())
        #expect(fixture.run("media.volume").toDouble() == 0.5)
    }

    @Test func olderCommandsCannotOverrideNewerPauseIntent() throws {
        let fixture = try BridgeFixture()
        fixture.run("YTMusicNativePlayer.bind(binding)")
        fixture.run("YTMusicNativePlayer.command({loadID: binding.loadID, revision: 2, name: 'pause'})")
        let accepted = fixture.run("YTMusicNativePlayer.command({loadID: binding.loadID, revision: 1, name: 'play'})").toBool()
        #expect(!accepted)
        #expect(fixture.run("media.paused").toBool())
        let wrongLoad = fixture.run("YTMusicNativePlayer.command({loadID: 'old-load', revision: 3, name: 'play'})").toBool()
        #expect(!wrongLoad)
    }

    @Test func duplicateMediaEndEventsAreReportedOnce() throws {
        let fixture = try BridgeFixture()
        fixture.run("YTMusicNativePlayer.bind(binding); media.ended = true; media.emit('ended'); media.emit('ended')")
        #expect(fixture.run("messages.filter(value => value.kind === 'ended').length").toInt32() == 1)
    }

    @Test func adEndWaitsForNewContentMetadata() throws {
        let fixture = try BridgeFixture()
        fixture.run("YTMusicNativePlayer.bind(binding); ad = true; media.emit('loadstart'); media.emit('loadedmetadata'); media.ended = true; media.emit('ended')")
        fixture.run("ad = false; media.emit('ended')")
        #expect(fixture.run("messages.filter(value => value.kind === 'ended').length").toInt32() == 0)
        fixture.run("media.ended = false; media.emit('loadstart'); media.emit('loadedmetadata'); media.ended = true; media.emit('ended')")
        #expect(fixture.run("messages.filter(value => value.kind === 'ended').length").toInt32() == 1)
    }

    @Test func staleMediaEventsDoNotReportPlayback() throws {
        let fixture = try BridgeFixture()
        fixture.run("YTMusicNativePlayer.bind(binding)")
        let count = fixture.run("messages.length").toInt32()
        fixture.run("media.listeners.ended({type: 'ended', target: {ended: true}})")
        #expect(fixture.run("messages.length").toInt32() == count)
    }

    @Test func anUnexpectedTrackDoesNotContinuePlaying() throws {
        let fixture = try BridgeFixture()
        fixture.run("YTMusicNativePlayer.bind(binding); location.href = 'https://music.youtube.com/watch?v=other'")
        fixture.run("YTMusicNativePlayer.command({loadID: binding.loadID, revision: 1, name: 'play'})")
        #expect(fixture.run("media.paused").toBool())
        #expect(fixture.run("messages[messages.length - 2].errorCode").toString() == "target_changed")
    }
}
