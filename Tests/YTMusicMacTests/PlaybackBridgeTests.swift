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
        "commandRevision": 0, "playbackIntent": true, "intentSource": "native",
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

    @Test func publicOutputSurvivesPlayingStateUpdatesButClearsForUnavailableContent() throws {
        let valid = payload(loadID: UUID(), occurrence: occurrence(), documentID: UUID())
        #expect(!(try #require(PlaybackBridgeMessage.decode(valid))).interruptsPlaybackOutput)
        for (field, value) in [("isAd", true), ("isPlaying", false), ("isBuffering", true), ("mediaReady", false)] {
            var interrupted = valid; interrupted[field] = value
            #expect((try #require(PlaybackBridgeMessage.decode(interrupted))).interruptsPlaybackOutput)
        }
        var loading = valid; loading["position"] = 0
        #expect((try #require(PlaybackBridgeMessage.decode(loading))).interruptsPlaybackOutput)
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

    @Test func pagePauseCannotOverrideANewerNativeCommand() throws {
        var body = payload(loadID: UUID(), occurrence: occurrence(), documentID: UUID())
        body["intentSource"] = "page"
        body["playbackIntent"] = false
        body["isPlaying"] = false
        body["commandRevision"] = 3
        let pause = try #require(PlaybackBridgeMessage.decode(body))
        #expect(pause.acceptsPagePause(latestCommandRevision: 3))
        #expect(!pause.acceptsPagePause(latestCommandRevision: 4))
        for (key, value): (String, Any) in [
            ("intentSource", "native"), ("isAd", true), ("mediaReady", false),
            ("isPlaying", true), ("kind", "ended"), ("kind", "error"),
        ] {
            var excluded = body
            excluded[key] = value
            let message = try #require(PlaybackBridgeMessage.decode(excluded))
            #expect(!message.acceptsPagePause(latestCommandRevision: 3))
        }
    }

    @Test func onlyAdvancingSongContentEndsAPlaybackStart() throws {
        let body = payload(loadID: UUID(), occurrence: occurrence(), documentID: UUID())
        let playing = try #require(PlaybackBridgeMessage.decode(body))
        #expect(playing.confirmsContentPlayback)
        for (key, value): (String, Any) in [
            ("isPlaying", false), ("isBuffering", true), ("isAd", true), ("mediaReady", false),
            ("kind", "ended"), ("kind", "error"),
        ] {
            var excluded = body
            excluded[key] = value
            let message = try #require(PlaybackBridgeMessage.decode(excluded))
            #expect(!message.confirmsContentPlayback)
        }
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
    globalThis.crypto = {randomUUID: () => 'abcdefab-cdef-4000-8000-abcdefabcdef'};
    globalThis.URL = function(value) {this.searchParams = {get: () => value.split('v=')[1] || ''};};
    globalThis.webkit = {messageHandlers: {playerBridge: {postMessage: value => messages.push(value)}}};
    globalThis.addEventListener = () => {};
    globalThis.MutationObserver = class {observe() {}};
    let ad = false;
    let blockPlay = false;
    let blockError = 'NotAllowedError';
    const timers = [];
    globalThis.setTimeout = action => timers.push(action);
    globalThis.clearTimeout = id => {timers[id - 1] = null;};
    const media = {
        tagName: 'VIDEO', isConnected: true, currentTime: 0, duration: 180,
        paused: true, ended: false, readyState: 1, volume: 1, listeners: {},
        extraListeners: {},
        addEventListener(name, action) {
            if (!this.listeners[name]) this.listeners[name] = action;
            else (this.extraListeners[name] = this.extraListeners[name] || []).push(action);
        },
        removeEventListener(name, action) {
            if (this.listeners[name] === action) delete this.listeners[name];
            this.extraListeners[name] = (this.extraListeners[name] || []).filter(value => value !== action);
        },
        pause() {this.paused = true;},
        play() {
            if (blockPlay) return {catch(handler) {handler(Object.assign(new Error(blockError), {name: blockError}));}};
            this.paused = false;
            return {catch() {}};
        },
        emit(name) {
            const event = {type: name, target: this};
            if (this.listeners[name]) this.listeners[name](event);
            (this.extraListeners[name] || []).slice().forEach(action => action(event));
        }
    };
    globalThis.document = {
        visibilityState: 'visible', listeners: {},
        querySelector(selector) {return selector === '#movie_player' ? {classList: {contains: () => ad}} : media;},
        addEventListener(name, action) {(this.listeners[name] = this.listeners[name] || []).push(action);},
        emit(name) {(this.listeners[name] || []).forEach(action => action({type: name}));}
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

    @Test func pagePauseSurvivesLaterMediaReadyAndVolumeEvents() throws {
        let fixture = try BridgeFixture()
        fixture.run("media.readyState = 4; YTMusicNativePlayer.bind(binding); media.emit('playing')")
        fixture.run("media.pause(); media.emit('pause'); media.emit('canplay')")
        #expect(fixture.run("media.paused").toBool())
        fixture.run("YTMusicNativePlayer.command({loadID: binding.loadID, revision: 1, name: 'volume', value: 0.2})")
        #expect(fixture.run("media.paused").toBool())
        #expect(fixture.run("messages[messages.length - 1].intentSource").toString() == "page")
        #expect(!fixture.run("messages[messages.length - 1].playbackIntent").toBool())
        #expect(fixture.run("messages[messages.length - 1].commandRevision").toInt32() == 1)
        fixture.run("YTMusicNativePlayer.command({loadID: binding.loadID, revision: 2, name: 'play'})")
        #expect(!fixture.run("media.paused").toBool())
        #expect(fixture.run("messages[messages.length - 1].intentSource").toString() == "native")
    }

    @Test func delayedPauseEventDoesNotUndoANewerNativePlay() throws {
        let fixture = try BridgeFixture()
        fixture.run("media.readyState = 4; YTMusicNativePlayer.bind(binding); media.emit('playing')")
        fixture.run("YTMusicNativePlayer.command({loadID: binding.loadID, revision: 1, name: 'pause'})")
        fixture.run("YTMusicNativePlayer.command({loadID: binding.loadID, revision: 2, name: 'play'}); media.emit('pause'); media.emit('canplay')")
        #expect(!fixture.run("media.paused").toBool())
        #expect(fixture.run("messages[messages.length - 1].intentSource").toString() == "native")
    }

    @Test func endedAdsAndLoadingDoNotBecomePagePauseIntent() throws {
        let sequences = [
            "media.ended = true",
            "ad = true",
            "media.emit('loadstart'); media.readyState = 0",
            "media.readyState = 2; media.emit('waiting')",
            "media.seeking = true",
            "media.emit('emptied'); media.readyState = 4; media.emit('loadedmetadata')",
        ]
        for setup in sequences {
            let fixture = try BridgeFixture()
            fixture.run("media.readyState = 4; YTMusicNativePlayer.bind(binding); media.emit('playing'); \(setup); media.pause(); media.emit('pause')")
            #expect(fixture.run("messages[messages.length - 1].intentSource").toString() == "native")
        }
    }

    @Test func retrySeekWaitsForMetadataAndKeepsTheRequestedPosition() throws {
        let fixture = try BridgeFixture()
        fixture.run("media.readyState = 0; YTMusicNativePlayer.bind(binding)")
        fixture.run("YTMusicNativePlayer.command({loadID: binding.loadID, revision: 1, name: 'seek', value: 120})")
        #expect(fixture.run("media.currentTime").toDouble() == 0)
        fixture.run("media.readyState = 1; media.emit('loadedmetadata')")
        #expect(fixture.run("media.currentTime").toDouble() == 120)
    }

    @Test func serviceVolumeChangesRestoreTheNativeVolumeWithoutRepeatedWrites() throws {
        let fixture = try BridgeFixture()
        fixture.run("YTMusicNativePlayer.bind(binding)")
        fixture.run("""
        let actualVolume = media.volume, volumeWrites = 0;
        Object.defineProperty(media, 'volume', {
            get() {return actualVolume;},
            set(value) {volumeWrites += 1; actualVolume = value; media.emit('volumechange');}
        });
        media.volume = 1;
        """)
        #expect(fixture.run("media.volume").toDouble() == 0.5)
        #expect(fixture.run("volumeWrites").toInt32() == 2)
        fixture.run("YTMusicNativePlayer.command({loadID: binding.loadID, revision: 1, name: 'volume', value: 0.2})")
        #expect(fixture.run("media.volume").toDouble() == 0.2)
        #expect(fixture.run("volumeWrites").toInt32() == 3)
    }

    @Test func networkStallDoesNotBufferPlayableAudio() throws {
        let fixture = try BridgeFixture()
        fixture.run("media.readyState = 4; YTMusicNativePlayer.bind(binding); media.emit('playing'); media.emit('stalled')")
        #expect(!fixture.run("messages[messages.length - 1].isBuffering").toBool())
    }

    @Test func advancingClockAndCanPlayClearABufferingState() throws {
        let fixture = try BridgeFixture()
        fixture.run("media.readyState = 2; YTMusicNativePlayer.bind(binding); media.emit('waiting')")
        #expect(fixture.run("messages[messages.length - 1].isBuffering").toBool())
        fixture.run("media.currentTime = 1; media.emit('timeupdate')")
        #expect(!fixture.run("messages[messages.length - 1].isBuffering").toBool())
        fixture.run("media.emit('stalled')")
        #expect(fixture.run("messages[messages.length - 1].isBuffering").toBool())
        fixture.run("media.readyState = 3; media.emit('canplay')")
        #expect(!fixture.run("messages[messages.length - 1].isBuffering").toBool())
    }

    @Test func stationaryClockDoesNotHideARealStall() throws {
        let fixture = try BridgeFixture()
        fixture.run("media.readyState = 2; YTMusicNativePlayer.bind(binding); media.emit('waiting'); media.emit('timeupdate')")
        #expect(fixture.run("messages[messages.length - 1].isBuffering").toBool())
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

    @Test func playBlockedInAHiddenPageRetriesOnceVisible() throws {
        let fixture = try BridgeFixture()
        fixture.run("document.visibilityState = 'hidden'; blockPlay = true; media.readyState = 4")
        fixture.run("YTMusicNativePlayer.bind(binding)")
        #expect(fixture.run("media.paused").toBool())
        #expect(fixture.run("messages.every(message => message.errorCode === null)").toBool())
        fixture.run("blockPlay = false; document.visibilityState = 'visible'; document.emit('visibilitychange')")
        #expect(!fixture.run("media.paused").toBool())
        #expect(fixture.run("messages.every(message => message.errorCode === null)").toBool())
    }

    @Test func anInterruptedStartIsRetriedInsteadOfReported() throws {
        let fixture = try BridgeFixture()
        fixture.run("blockPlay = true; blockError = 'AbortError'; media.readyState = 4")
        fixture.run("YTMusicNativePlayer.bind(binding)")
        #expect(fixture.run("media.paused").toBool())
        #expect(fixture.run("messages.every(message => message.errorCode === null)").toBool())
        fixture.run("blockPlay = false; timers.splice(0).forEach(action => action())")
        #expect(!fixture.run("media.paused").toBool())
        #expect(fixture.run("messages.every(message => message.errorCode === null)").toBool())
    }

    @Test func anInterruptedStartIsNotRetriedAfterPause() throws {
        let fixture = try BridgeFixture()
        fixture.run("blockPlay = true; blockError = 'AbortError'; media.readyState = 4")
        fixture.run("YTMusicNativePlayer.bind(binding)")
        fixture.run("YTMusicNativePlayer.command({loadID: binding.loadID, revision: 1, name: 'pause'})")
        fixture.run("blockPlay = false; timers.splice(0).forEach(action => action())")
        #expect(fixture.run("media.paused").toBool())
    }

    @Test func playBlockedInAVisiblePageIsReported() throws {
        let fixture = try BridgeFixture()
        fixture.run("blockPlay = true; media.readyState = 4; YTMusicNativePlayer.bind(binding)")
        #expect(fixture.run("messages.some(message => message.errorCode === 'playback_blocked')").toBool())
    }

    @Test func becomingVisibleDoesNotRestartAPausedSong() throws {
        let fixture = try BridgeFixture()
        fixture.run("document.visibilityState = 'hidden'; blockPlay = true; media.readyState = 4")
        fixture.run("YTMusicNativePlayer.bind(binding)")
        fixture.run("YTMusicNativePlayer.command({loadID: binding.loadID, revision: 1, name: 'pause'})")
        fixture.run("blockPlay = false; document.visibilityState = 'visible'; document.emit('visibilitychange')")
        #expect(fixture.run("media.paused").toBool())
    }
}

@MainActor @Suite("Fenced video presentation bridge")
struct VideoPresentationBridgeTests {
    private func fixture(supported: Bool = true, delayed: Bool = false) throws -> BridgeFixture {
        let fixture = try BridgeFixture()
        fixture.run("""
        const presentationCalls = [];
        let pipSupported = \(supported ? "true" : "false");
        let delayedPresentation = \(delayed ? "true" : "false");
        media.videoWidth = 1280; media.videoHeight = 720; media.currentTime = 42;
        media.webkitPresentationMode = 'inline';
        media.webkitSupportsPresentationMode = () => pipSupported;
        media.webkitSetPresentationMode = mode => {
            presentationCalls.push(mode);
            if (!delayedPresentation) {media.webkitPresentationMode = mode; media.emit('webkitpresentationmodechanged');}
        };
        function presentationRequest(active, revision = 1) {
            const state = messages[messages.length - 1];
            return {loadID: binding.loadID, identity: binding.identity, documentID: state.documentID,
                    mediaGeneration: state.mediaGeneration, revision, active};
        }
        YTMusicNativePlayer.bind(binding);
        """)
        return fixture
    }

    @Test func nativeUUIDCapitalizationDoesNotRejectTheCurrentPresentationDocument() throws {
        let fixture = try fixture()
        fixture.run("""
        const request = presentationRequest(true);
        request.documentID = request.documentID.toUpperCase();
        YTMusicNativePlayer.presentation(request).then(value => globalThis.reply = value);
        """)
        #expect(fixture.run("reply.accepted && reply.active").toBool())
        #expect(fixture.run("media.currentTime === 42 && !media.paused").toBool())
        #expect(fixture.run("messages[messages.length - 1].commandRevision === 0").toBool())
    }

    @Test func entryAndExitKeepTheExactRecordingClockAndTransportRevision() throws {
        let fixture = try fixture()
        fixture.run("YTMusicNativePlayer.presentation(presentationRequest(true)).then(value => globalThis.reply = value)")
        #expect(fixture.run("reply.accepted && reply.active").toBool())
        #expect(fixture.run("messages[messages.length - 1].videoPresentation.isPictureInPictureActive").toBool())
        fixture.run("YTMusicNativePlayer.presentation(presentationRequest(false, 2)).then(value => globalThis.reply = value)")
        #expect(fixture.run("reply.accepted && !reply.active").toBool())
        #expect(fixture.run("presentationCalls.join(',')").toString() == "picture-in-picture,inline")
        #expect(fixture.run("media.currentTime").toDouble() == 42)
        #expect(!fixture.run("media.paused").toBool())
        #expect(fixture.run("messages[messages.length - 1].commandRevision").toInt32() == 0)
        #expect(fixture.run("YTMusicNativePlayer.command({loadID: binding.loadID, revision: 1, name: 'pause'})").toBool())
    }

    @Test func unsupportedVideoNeverCallsPresentationOrReportsAudioFailure() throws {
        let fixture = try fixture(supported: false)
        fixture.run("YTMusicNativePlayer.presentation(presentationRequest(true)).then(value => globalThis.reply = value)")
        #expect(fixture.run("!reply.accepted && reply.reason === 'unsupported'").toBool())
        #expect(fixture.run("presentationCalls.length").toInt32() == 0)
        #expect(fixture.run("messages.every(value => value.errorCode === null)").toBool())
    }

    @Test func staleLoadDocumentOccurrenceMediaAndWrongTrackCannotPresent() throws {
        let fixture = try fixture()
        fixture.run("""
        const invalid = [
            {...presentationRequest(true), loadID: 'old-load'},
            {...presentationRequest(true), documentID: 'old-document'},
            {...presentationRequest(true), identity: {...binding.identity, entryID: 'other-occurrence'}},
            {...presentationRequest(true), mediaGeneration: -1}
        ];
        const replies = [];
        invalid.forEach(value => YTMusicNativePlayer.presentation(value).then(reply => replies.push(reply)));
        """)
        #expect(fixture.run("replies.length === 4 && replies.every(reply => !reply.accepted && reply.reason === 'stale')").toBool())
        fixture.run("location.href = 'https://music.youtube.com/watch?v=other'; YTMusicNativePlayer.presentation(presentationRequest(true)).then(value => globalThis.reply = value)")
        #expect(fixture.run("reply.reason === 'stale' && presentationCalls.length === 0").toBool())
    }

    @Test func advertisementsAndAudioOnlyMediaDoNotGrantVideoCapability() throws {
        let fixture = try fixture()
        fixture.run("media.videoWidth = 0; media.videoHeight = 0; media.emit('resize')")
        #expect(!fixture.run("messages[messages.length - 1].videoPresentation.hasVideo").toBool())
        fixture.run("YTMusicNativePlayer.presentation(presentationRequest(true)).then(value => globalThis.reply = value)")
        #expect(fixture.run("reply.reason === 'unsupported'").toBool())
        fixture.run("media.videoWidth = 1280; media.videoHeight = 720; ad = true; media.emit('loadstart'); media.emit('loadedmetadata')")
        fixture.run("YTMusicNativePlayer.presentation(presentationRequest(true)).then(value => globalThis.reply = value)")
        #expect(fixture.run("reply.reason === 'stale' && presentationCalls.length === 0").toBool())
    }

    @Test func successRequiresAnObservedTransitionAndTheSameMediaGeneration() throws {
        let fixture = try fixture(delayed: true)
        fixture.run("YTMusicNativePlayer.presentation(presentationRequest(true)).then(value => globalThis.reply = value)")
        #expect(fixture.run("typeof reply === 'undefined'").toBool())
        fixture.run("media.webkitPresentationMode = 'picture-in-picture'; media.emit('webkitpresentationmodechanged')")
        #expect(fixture.run("reply.accepted && reply.active").toBool())
        fixture.run("YTMusicNativePlayer.presentation(presentationRequest(false, 2)).then(value => globalThis.reply2 = value)")
        fixture.run("media.emit('loadstart'); media.webkitPresentationMode = 'inline'; media.emit('webkitpresentationmodechanged')")
        #expect(fixture.run("!reply2.accepted && reply2.reason === 'stale'").toBool())
    }

    @Test func aRefusedOrTimedOutPresentationDoesNotStopAudioOrAdvanceTheQueue() throws {
        let fixture = try fixture(delayed: true)
        fixture.run("YTMusicNativePlayer.presentation(presentationRequest(true)).then(value => globalThis.reply = value)")
        fixture.run("timers.filter(Boolean).forEach(action => action())")
        #expect(fixture.run("!reply.accepted && reply.reason === 'rejected'").toBool())
        #expect(!fixture.run("media.paused").toBool())
        #expect(fixture.run("messages.every(value => value.kind !== 'ended' && value.errorCode === null)").toBool())
        fixture.run("media.webkitSetPresentationMode = () => {throw new Error('NotAllowedError')}; YTMusicNativePlayer.presentation(presentationRequest(true, 2)).then(value => globalThis.reply2 = value)")
        #expect(fixture.run("!reply2.accepted && reply2.reason === 'rejected'").toBool())
        #expect(!fixture.run("media.paused").toBool())
    }

    @Test func replayedPresentationRequestsCannotOverrideAUserTransportCommand() throws {
        let fixture = try fixture()
        fixture.run("YTMusicNativePlayer.presentation(presentationRequest(true, 100)).then(value => globalThis.reply = value)")
        fixture.run("YTMusicNativePlayer.presentation(presentationRequest(false, 99)).then(value => globalThis.reply2 = value)")
        #expect(fixture.run("reply.accepted && !reply2.accepted && reply2.reason === 'stale'").toBool())
        #expect(fixture.run("YTMusicNativePlayer.command({loadID: binding.loadID, revision: 1, name: 'pause'})").toBool())
        #expect(fixture.run("media.paused").toBool())
        #expect(fixture.run("presentationCalls.length").toInt32() == 1)
    }
}
