import Foundation
import JavaScriptCore
import MusicCore
import Testing
@testable import YTMusicMac

@MainActor private final class RateScriptFixture {
    let context: JSContext
    init() throws {
        context = try #require(JSContext())
        context.evaluateScript(Self.environment)
        for name in ["PlayerBridge", "EpisodeRateBridge"] {
            let url = try #require(AppIdentity.resourceBundle.url(forResource: name, withExtension: "js"))
            context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
            #expect(context.exception == nil)
        }
        run("YTMusicNativePlayer.bind(binding)")
    }
    @discardableResult func run(_ script: String) -> JSValue {
        let value = context.evaluateScript(script)!
        #expect(context.exception == nil)
        return value
    }
    static let environment = """
    globalThis.window = globalThis;
    const messages = [], rateCalls = [], timers = [];
    let ad = false, actualRate = 1, reportedRate = null, setterMode = 'normal';
    let offered = [0.75, 1, 1.5, 2], serviceURL = 'https://music.youtube.com/watch?v=song';
    let plays = 0, pauses = 0, pendingRate;
    globalThis.location = {href: 'https://music.youtube.com/watch?v=song', replace() {}};
    globalThis.crypto = {randomUUID: () => 'abcdefab-cdef-4abc-8abc-abcdefabcdef'};
    globalThis.URL = function(value) {
        const match = String(value).match(/^(https?:)\\/\\/([^/?]+)(.*)$/);
        if (!match) throw Error('invalid URL');
        this.protocol = match[1]; this.hostname = match[2];
        this.searchParams = {get(key) {
            const pair = (String(value).split('?')[1] || '').split('&').map(part => part.split('='))
                .find(part => part[0] === key);
            return pair ? decodeURIComponent(pair[1] || '') : null;
        }};
    };
    globalThis.webkit = {messageHandlers: {playerBridge: {postMessage: value => messages.push(value)}}};
    globalThis.addEventListener = () => {};
    globalThis.MutationObserver = class {observe() {}};
    globalThis.setTimeout = action => {timers.push(action); return timers.length;};
    globalThis.clearTimeout = id => {timers[id - 1] = null;};
    const media = {
        tagName: 'VIDEO', isConnected: true, currentTime: 42, duration: 180, readyState: 4,
        paused: true, ended: false, volume: 1, listeners: {}, attributes: {},
        get playbackRate() {return actualRate;},
        addEventListener(name, action) {(this.listeners[name] = this.listeners[name] || []).push(action);},
        removeEventListener(name, action) {this.listeners[name] = (this.listeners[name] || []).filter(item => item !== action);},
        emit(name) {(this.listeners[name] || []).slice().forEach(action => action({type: name, target: this}));},
        getAttribute(name) {return this.attributes[name] || null;},
        hasAttribute(name) {return name in this.attributes;},
        setAttribute(name, value) {this.attributes[name] = value;},
        removeAttribute(name) {delete this.attributes[name];},
        play() {plays++; this.paused = false; return {catch() {}};}, pause() {pauses++; this.paused = true;}
    };
    const player = {
        classList: {contains: () => ad}, contains: value => value === media,
        getAvailablePlaybackRates: () => offered, getPlaybackRate: () => reportedRate === null ? actualRate : reportedRate,
        getVideoUrl: () => serviceURL,
        setPlaybackRate(value) {
            rateCalls.push(value);
            if (setterMode === 'throw') throw Error('refused');
            if (setterMode === 'ignore') return;
            const apply = () => {actualRate = setterMode === 'clamp' ? 1 : value; media.emit('ratechange');};
            if (setterMode === 'delayed') pendingRate = apply; else apply();
        }
    };
    globalThis.document = {
        visibilityState: 'visible', addEventListener() {},
        querySelector(selector) {return selector === '#movie_player' ? player : media;}
    };
    const binding = {loadID: 'ABCDEFAB-CDEF-4ABC-8ABC-ABCDEFABCDE1', autoplay: true, volume: 0.5, rateContent: 'episode',
        identity: {sessionID: 'ABCDEFAB-CDEF-4ABC-8ABC-ABCDEFABCDE2', entryID: 'ABCDEFAB-CDEF-4ABC-8ABC-ABCDEFABCDE3',
                   trackID: 'song', generation: '18446744073709551615'}};
    function request(rate = 1.5, revision = 1) {
        const state = messages[messages.length - 1];
        return {loadID: binding.loadID.toLowerCase(), documentID: state.documentID.toUpperCase(),
            identity: {...binding.identity, sessionID: binding.identity.sessionID.toLowerCase(), entryID: binding.identity.entryID.toLowerCase()},
            mediaGeneration: state.mediaGeneration, content: binding.rateContent, revision, rate,
            expectedRate: actualRate, expectedChanges: state.episodeRateMedia.changes};
    }
    """
}

@MainActor @Suite("Conditional episode rate script")
struct EpisodeRateBridgeTests {
    @Test func capabilityRequiresConsistentServiceListCurrentRateAndMediaReadback() throws {
        let f = try RateScriptFixture()
        #expect(f.run("YTMusicNativeEpisodeRateV1.snapshot(request()).reason").toString() == "supported")
        #expect(f.run("YTMusicNativeEpisodeRateV1.snapshot(request()).snapshot.rates.join(',')").toString() == "0.75,1,1.5,2")
        for setup in ["offered = []", "offered = [1, '1.5']", "offered = Array(17).fill(1)",
                      "reportedRate = 2", "offered = [0.75, 2]", "player.getPlaybackRate = undefined"] {
            let f = try RateScriptFixture(); f.run(setup)
            #expect(f.run("YTMusicNativeEpisodeRateV1.snapshot(request()).reason").toString() == "unsupported")
            #expect(f.run("rateCalls.length").toInt32() == 0)
        }
    }
    @Test func anObservedExactChangePreservesClockIntentAndOtherCommandRevisions() throws {
        let f = try RateScriptFixture()
        f.run("const originalPlays = plays, originalPauses = pauses; YTMusicNativeEpisodeRateV1.setEpisodeRate(request(1.5, 100)).then(value => globalThis.reply = value)")
        #expect(f.run("reply.accepted && reply.reason === 'confirmed' && reply.changed && reply.snapshot.current === 1.5 && reply.snapshot.mediaRate === 1.5").toBool())
        #expect(f.run("plays === originalPlays && pauses === originalPauses && media.currentTime === 42 && !media.paused").toBool())
        #expect(f.run("messages[messages.length - 1].commandRevision").toInt32() == 0)
        f.run("""
        media.videoWidth = 1280; media.videoHeight = 720; media.webkitPresentationMode = 'inline';
        media.webkitSupportsPresentationMode = () => true;
        media.webkitSetPresentationMode = value => {media.webkitPresentationMode = value; media.emit('webkitpresentationmodechanged');};
        let pip = {...request(), loadID: binding.loadID, identity: binding.identity,
                   documentID: messages[messages.length - 1].documentID, revision: 1, active: true};
        YTMusicNativePlayer.presentation(pip).then(value => globalThis.pipReply = value);
        """)
        #expect(f.run("pipReply.accepted && pipReply.active && actualRate === 1.5 && rateCalls.length === 1").toBool())
        #expect(f.run("YTMusicNativePlayer.command({loadID: binding.loadID, revision: 1, name: 'pause'})").toBool())
        #expect(f.run("media.paused").toBool())
    }
    @Test func staleScopeWrongVideoAdsAndLoadingNeverCallTheServiceSetter() throws {
        for change in ["value.loadID = 'old'", "value.documentID = 'old'", "value.mediaGeneration++",
                       "value.identity.entryID = 'other'", "value.identity.sessionID = 'other'", "value.identity.generation = '1'",
                       "serviceURL = 'https://music.youtube.com/watch?v=other'", "serviceURL = 'https://example.invalid/watch?v=song'",
                       "location.href = 'https://music.youtube.com/watch?v=other'", "location.href = 'https://example.invalid/watch?v=song'", "location.href = 'http://music.youtube.com/watch?v=song'", "ad = true", "media.emit('loadstart')", "media.isConnected = false"] {
            let f = try RateScriptFixture()
            f.run("let value = request(); \(change); YTMusicNativeEpisodeRateV1.setEpisodeRate(value).then(value => globalThis.reply = value)")
            #expect(f.run("!reply.accepted && reply.reason === 'stale' && rateCalls.length === 0").toBool())
        }
    }
    @Test func replayAndPageRateChangesCannotOverrideANewerObservedChoice() throws {
        let f = try RateScriptFixture()
        f.run("YTMusicNativeEpisodeRateV1.setEpisodeRate(request(1.5, 5)).then(value => globalThis.first = value)")
        f.run("YTMusicNativeEpisodeRateV1.setEpisodeRate(request(1, 4)).then(value => globalThis.old = value)")
        #expect(f.run("first.accepted && !old.accepted && actualRate === 1.5 && rateCalls.length === 1").toBool())
        f.run("let stale = request(1, 6); actualRate = 2; media.emit('ratechange'); YTMusicNativeEpisodeRateV1.setEpisodeRate(stale).then(value => globalThis.page = value)")
        #expect(f.run("!page.accepted && actualRate === 2 && rateCalls.length === 1").toBool())
    }
    @Test func unobservedRefusedAndClampedChangesNeverReportSuccessOrStopAudio() throws {
        for mode in ["ignore", "throw", "clamp"] {
            let f = try RateScriptFixture()
            f.run("setterMode = '\(mode)'; YTMusicNativeEpisodeRateV1.setEpisodeRate(request()).then(value => globalThis.reply = value); timers.filter(Boolean).forEach(action => action())")
            #expect(f.run("!reply.accepted && reply.reason === 'rejected'").toBool())
            #expect(f.run("!media.paused && media.currentTime === 42 && messages.every(value => value.errorCode === null && value.kind !== 'ended')").toBool())
        }
    }
    @Test func aDelayedChangeCannotConfirmAfterItsMediaGenerationIsReplaced() throws {
        let f = try RateScriptFixture()
        f.run("setterMode = 'delayed'; YTMusicNativeEpisodeRateV1.setEpisodeRate(request()).then(value => globalThis.reply = value)")
        #expect(f.run("typeof reply === 'undefined'").toBool())
        f.run("media.emit('loadstart'); pendingRate()")
        #expect(f.run("!reply.accepted && reply.reason === 'stale' && messages.every(value => value.errorCode === null)").toBool())
    }
    @Test func knownSongResetOnlyAllowsNormalRateAndRetiresTheMinimalScope() throws {
        let f = try RateScriptFixture()
        f.run("binding.rateContent = 'song'; actualRate = 1.5; YTMusicNativePlayer.bind(binding)")
        f.run("YTMusicNativeEpisodeRateV1.setEpisodeRate(request(2)).then(value => globalThis.wrong = value)")
        #expect(f.run("!wrong.accepted && rateCalls.length === 0").toBool())
        f.run("YTMusicNativeEpisodeRateV1.resetOwnedSongRate(request(1)).then(value => globalThis.reply = value)")
        #expect(f.run("reply.accepted && actualRate === 1 && rateCalls.length === 1").toBool())
        f.run("ad = true; media.emit('loadstart'); let done = request(1, 2); done.loadID = binding.loadID; done.documentID = messages[messages.length - 1].documentID; done.identity = binding.identity; YTMusicNativePlayer.retireEpisodeRateScope(done); media.emit('timeupdate')")
        #expect(f.run("!media.hasAttribute('data-ytm-native-episode-rate-v1') && messages[messages.length - 1].episodeRateMedia === null").toBool())
        #expect(f.run("Object.keys(media.attributes).length").toInt32() == 0)
    }
}
