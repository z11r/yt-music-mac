(() => {
    "use strict";
    if (globalThis.YTMusicNativePlayer) return;

    const documentID = crypto.randomUUID();
    let context = null;
    let video = null;
    let mediaGeneration = 0;
    let sequence = 0;
    let commandRevision = 0;
    let navigationRevision = 0;
    let presentationRevision = 0;
    let episodeRateChanges = 0;
    let episodeRateScopeArmed = false;
    let wantsPlaying = false;
    let intentSource = "native";
    let desiredVolume = 1;
    let pendingSeek = null;
    let buffering = false;
    let contentReady = false;
    let hasPlayedCurrentMedia = false;
    let adInThisMedia = false;
    let endedGeneration = -1;
    let lastProgressAt = 0;
    let lastMediaPosition = 0;
    let blockedWhileHidden = false;
    let removers = [];

    function videoID() {
        return new URL(location.href).searchParams.get("v") || "";
    }

    function adShowing() {
        const player = document.querySelector("#movie_player");
        return !!player && (player.classList.contains("ad-showing")
            || player.classList.contains("ad-interrupting"));
    }

    function finite(value) {
        return Number.isFinite(value) && value >= 0 ? value : 0;
    }

    function pictureInPictureActive() {
        return !!video && (video.webkitPresentationMode === "picture-in-picture"
            || document.pictureInPictureElement === video);
    }

    function presentationSnapshot() {
        const hasVideo = !!video && matchesTarget() && contentReady && video.readyState >= 1
            && !adShowing() && !adInThisMedia && Number.isFinite(video.videoWidth) && video.videoWidth > 0
            && Number.isFinite(video.videoHeight) && video.videoHeight > 0;
        let supported = false;
        try {
            if (hasVideo && video.disablePictureInPicture !== true) {
                supported = typeof video.webkitSupportsPresentationMode === "function"
                    ? typeof video.webkitSetPresentationMode === "function" && video.webkitSupportsPresentationMode("picture-in-picture")
                    : document.pictureInPictureEnabled === true && typeof video.requestPictureInPicture === "function";
            }
        } catch (_) { supported = false; }
        return {hasVideo, supportsPictureInPicture: supported, isPictureInPictureActive: pictureInPictureActive()};
    }

    function samePresentationTarget(value, target) {
        const expected = context && context.identity;
        const identity = value && value.identity;
        return !!expected && !!identity && target === video && video.isConnected && matchesTarget()
            && value.loadID === context.loadID && typeof value.documentID === "string" && value.documentID.toLowerCase() === documentID
            && value.mediaGeneration === mediaGeneration && identity.sessionID === expected.sessionID
            && identity.entryID === expected.entryID && identity.trackID === expected.trackID
            && identity.generation === expected.generation && contentReady && video.readyState >= 1
            && !adShowing() && !adInThisMedia;
    }

    function requestPresentation(value) {
        const target = video;
        const response = (accepted, reason) => ({accepted, reason, active: pictureInPictureActive()});
        if (!value || !samePresentationTarget(value, target) || typeof value.active !== "boolean"
            || !Number.isInteger(value.revision) || value.revision <= presentationRevision) {
            return Promise.resolve(response(false, "stale"));
        }
        presentationRevision = value.revision;
        if (pictureInPictureActive() === value.active) return Promise.resolve(response(true, "confirmed"));
        if (value.active && !presentationSnapshot().supportsPictureInPicture) return Promise.resolve(response(false, "unsupported"));
        return new Promise(resolve => {
            let complete = false;
            let timer;
            const events = ["webkitpresentationmodechanged", "enterpictureinpicture", "leavepictureinpicture"];
            const finish = (accepted, reason) => {
                if (complete) return;
                complete = true;
                if (timer !== undefined) clearTimeout(timer);
                events.forEach(name => target.removeEventListener(name, changed));
                resolve(response(accepted, reason));
            };
            const changed = () => {
                if (!samePresentationTarget(value, target) || value.revision !== presentationRevision) { finish(false, "stale"); return; }
                if (pictureInPictureActive() === value.active) finish(true, "confirmed");
            };
            events.forEach(name => target.addEventListener(name, changed));
            timer = setTimeout(() => finish(false, samePresentationTarget(value, target) ? "rejected" : "stale"), 1500);
            try {
                let transition;
                if (typeof target.webkitSetPresentationMode === "function") {
                    target.webkitSetPresentationMode(value.active ? "picture-in-picture" : "inline");
                } else if (value.active && typeof target.requestPictureInPicture === "function") {
                    transition = target.requestPictureInPicture();
                } else if (!value.active && typeof document.exitPictureInPicture === "function") {
                    transition = document.exitPictureInPicture();
                } else { finish(false, "unsupported"); return; }
                if (transition && typeof transition.then === "function") {
                    transition.then(changed, () => finish(false, samePresentationTarget(value, target) ? "rejected" : "stale"));
                }
                changed();
            } catch (_) { finish(false, "rejected"); }
        });
    }

    function episodeRateMedia() {
        if (!video || typeof video.setAttribute !== "function") return null;
        const name = "data-ytm-native-episode-rate-v1";
        if (!context || !["episode", "song"].includes(context.rateContent)) {
            if (episodeRateScopeArmed) video.removeAttribute(name);
            episodeRateScopeArmed = false;
            return null;
        }
        const marker = JSON.stringify({version: 1, loadID: context.loadID, documentID, identity: context.identity,
            mediaGeneration, content: context.rateContent, changes: episodeRateChanges,
            ready: matchesTarget() && contentReady && video.readyState >= 1 && !adShowing() && !adInThisMedia});
        if (video.getAttribute(name) !== marker) video.setAttribute(name, marker);
        episodeRateScopeArmed = true;
        return Number.isFinite(video.playbackRate) ? {rate: video.playbackRate, changes: episodeRateChanges} : null;
    }

    function snapshot(kind, errorCode) {
        return {
            kind,
            loadID: context.loadID,
            identity: context.identity,
            documentID,
            mediaGeneration,
            sequence: ++sequence,
            commandRevision,
            playbackIntent: wantsPlaying,
            intentSource,
            videoID: videoID(),
            position: video ? finite(video.currentTime) : 0,
            duration: video ? finite(video.duration) : 0,
            volume: video ? video.volume : desiredVolume,
            isPlaying: !!video && !video.paused && !video.ended,
            isBuffering: buffering,
            isAd: adShowing() || adInThisMedia,
            mediaReady: !!video && video.readyState >= 1 && contentReady,
            errorCode: errorCode || null,
            videoPresentation: presentationSnapshot(),
            episodeRateMedia: episodeRateMedia()
        };
    }

    function report(kind, errorCode) {
        if (!context) return null;
        const value = snapshot(kind, errorCode);
        window.webkit.messageHandlers.playerBridge.postMessage(value);
        return value;
    }

    function matchesTarget() {
        return !!context && videoID() === context.identity.trackID;
    }

    function acceptsSectionSeek(value) {
        const scope = value.sectionGuard;
        const identity = scope && scope.identity;
        const expected = context && context.identity;
        if (!scope || !identity || !expected || value.name !== "seek" || !matchesTarget()
            || typeof scope.documentID !== "string" || scope.documentID.toLowerCase() !== documentID
            || scope.mediaGeneration !== mediaGeneration || scope.expectedRevision !== commandRevision
            || value.revision !== commandRevision + 1 || !video || !wantsPlaying || video.paused || video.ended
            || !contentReady || !hasPlayedCurrentMedia || video.readyState < 2 || buffering || video.seeking
            || adShowing() || adInThisMedia || pendingSeek !== null
            || typeof identity.sessionID !== "string" || identity.sessionID.toLowerCase() !== expected.sessionID.toLowerCase()
            || typeof identity.entryID !== "string" || identity.entryID.toLowerCase() !== expected.entryID.toLowerCase()
            || identity.trackID !== expected.trackID || identity.generation !== expected.generation) return false;
        return Number.isFinite(scope.start) && Number.isFinite(scope.end) && scope.start >= 0 && scope.start < scope.end
            && Number.isFinite(video.duration) && video.duration === scope.duration && scope.end < video.duration
            && value.value === scope.end && Number.isFinite(video.currentTime)
            && video.currentTime >= scope.start && video.currentTime < scope.end;
    }

    function applyIntent() {
        if (!video || !context) return;
        video.volume = desiredVolume;
        if (!matchesTarget()) {
            video.pause();
            report("error", "target_changed");
            return;
        }
        if (pendingSeek !== null && video.readyState >= 1 && !adShowing() && !adInThisMedia) {
            const duration = Number.isFinite(video.duration) ? video.duration : pendingSeek;
            video.currentTime = Math.min(pendingSeek, Math.max(0, duration));
            pendingSeek = null;
        }
        if (!wantsPlaying) {
            video.pause();
            return;
        }
        if (video.paused && !video.ended) {
            const revision = commandRevision;
            const target = video;
            const promise = video.play();
            if (promise && typeof promise.catch === "function") {
                promise.catch(error => {
                    if (video !== target || !wantsPlaying || revision !== commandRevision) return;
                    // A start interrupted by the page's own load or pause is not a
                    // refusal; try again once the player settles.
                    if (error && error.name === "AbortError") {
                        setTimeout(() => {
                            if (video === target && wantsPlaying && revision === commandRevision) applyIntent();
                        }, 300);
                        return;
                    }
                    // WebKit can refuse to start media in a hidden page. The app
                    // shows the page while a song starts, so retry once visible.
                    if (document.visibilityState === "hidden") {
                        blockedWhileHidden = true;
                        return;
                    }
                    report("error", "playback_blocked");
                });
            }
        }
    }

    function onMediaEvent(event) {
        if (event.target !== video) return;
        const kind = event.type;
        if (kind === "ratechange") {
            if (!context || !["episode", "song"].includes(context.rateContent)) return;
            episodeRateChanges += 1;
        }
        if (kind === "loadstart" || kind === "emptied") {
            mediaGeneration += 1;
            contentReady = false;
            hasPlayedCurrentMedia = false;
            adInThisMedia = adShowing();
            endedGeneration = -1;
            lastMediaPosition = 0;
        }
        if (adShowing()) adInThisMedia = true;
        if (kind === "loadedmetadata") {
            adInThisMedia = adShowing();
            contentReady = !adInThisMedia;
        }
        if (kind === "playing" && contentReady && !adShowing() && !adInThisMedia) {
            hasPlayedCurrentMedia = true;
        }
        if (kind === "pause" && wantsPlaying && hasPlayedCurrentMedia && video.paused && !video.ended
            && matchesTarget() && contentReady && video.readyState >= 2
            && !video.seeking && !buffering && !adShowing() && !adInThisMedia) {
            wantsPlaying = false;
            intentSource = "page";
        }
        if (kind === "waiting" || kind === "stalled") {
            buffering = wantsPlaying && !video.paused && !video.ended && video.readyState < 3;
        }
        if (["playing", "pause", "seeked", "ended", "canplay"].includes(kind)) buffering = false;
        if (kind === "timeupdate") {
            const position = finite(video.currentTime);
            if (!video.paused && !video.ended && position > lastMediaPosition) buffering = false;
            lastMediaPosition = position;
        }
        if (kind === "volumechange" && Math.abs(video.volume - desiredVolume) > 0.0001) {
            video.volume = desiredVolume;
        }
        if (kind === "play" && (!wantsPlaying || !matchesTarget())) video.pause();
        if (kind === "error") {
            report("error", "media_error");
            return;
        }
        if (kind === "ended") {
            if (!context || !matchesTarget() || !video.ended || !contentReady
                || adShowing() || adInThisMedia || endedGeneration === mediaGeneration) return;
            endedGeneration = mediaGeneration;
            wantsPlaying = false;
            report("ended");
            return;
        }
        if (kind === "loadedmetadata" || kind === "canplay") applyIntent();
        if (kind === "timeupdate") {
            const now = Date.now();
            if (now - lastProgressAt < 750) return;
            lastProgressAt = now;
            report("progress");
        } else {
            report("state");
        }
    }

    function attach() {
        const next = document.querySelector("#movie_player video") || document.querySelector("video");
        if (next === video) return;
        removers.forEach(remove => remove());
        removers = [];
        if (episodeRateScopeArmed && video && typeof video.removeAttribute === "function") video.removeAttribute("data-ytm-native-episode-rate-v1");
        episodeRateScopeArmed = false;
        video = next;
        mediaGeneration += 1;
        endedGeneration = -1;
        adInThisMedia = adShowing();
        contentReady = !!video && video.readyState >= 1 && !adInThisMedia;
        hasPlayedCurrentMedia = false;
        lastMediaPosition = video ? finite(video.currentTime) : 0;
        if (!video) return;
        const events = ["play", "pause", "playing", "waiting", "stalled", "canplay",
            "loadedmetadata", "durationchange", "timeupdate", "seeking", "seeked",
            "emptied", "loadstart", "error", "ended", "volumechange", "resize", "ratechange",
            "webkitpresentationmodechanged", "enterpictureinpicture", "leavepictureinpicture"];
        events.forEach(name => {
            const target = video;
            target.addEventListener(name, onMediaEvent);
            removers.push(() => target.removeEventListener(name, onMediaEvent));
        });
        if (!context || !wantsPlaying) video.pause();
        applyIntent();
        report("state");
    }

    const observer = new MutationObserver(() => {
        if (!video || !video.isConnected) attach();
    });
    observer.observe(document, { childList: true, subtree: true });
    document.addEventListener("DOMContentLoaded", attach, { once: true });
    document.addEventListener("play", event => {
        if (event.target && event.target.tagName === "VIDEO") {
            if (!context || !wantsPlaying) event.target.pause();
            attach();
        }
    }, true);
    const checkNavigation = () => {
        if (context && !matchesTarget()) {
            if (video) video.pause();
            report("error", "target_changed");
        }
        attach();
    };
    document.addEventListener("visibilitychange", () => {
        if (!blockedWhileHidden || document.visibilityState !== "visible") return;
        blockedWhileHidden = false;
        applyIntent();
    });
    document.addEventListener("yt-navigate-finish", checkNavigation);
    window.addEventListener("popstate", checkNavigation);

    globalThis.YTMusicNativePlayer = Object.freeze({
        replaceNavigation(value) {
            if (!value || value.documentID !== documentID
                || !Number.isInteger(value.revision) || value.revision <= navigationRevision
                || typeof value.targetURL !== "string"
                || !value.targetURL.startsWith("https://music.youtube.com/watch?")) return false;
            navigationRevision = value.revision;
            wantsPlaying = false;
            intentSource = "native";
            if (video) video.pause();
            window.location.replace(value.targetURL);
            return true;
        },
        bind(value) {
            if (!value || typeof value.loadID !== "string" || !value.identity
                || typeof value.identity.trackID !== "string") return null;
            context = value;
            wantsPlaying = value.autoplay === true;
            intentSource = "native";
            hasPlayedCurrentMedia = false;
            desiredVolume = Math.min(1, Math.max(0, value.volume));
            commandRevision = 0;
            presentationRevision = 0;
            episodeRateChanges = 0;
            pendingSeek = null;
            endedGeneration = -1;
            attach();
            applyIntent();
            return report("ready");
        },
        presentation(value) { return requestPresentation(value); },
        retireEpisodeRateScope(value) {
            const expected = context && context.identity;
            const identity = value && value.identity;
            if (!value || !expected || !identity || context.rateContent !== "song" || !matchesTarget()
                || value.loadID !== context.loadID || typeof value.documentID !== "string" || value.documentID.toLowerCase() !== documentID
                || value.mediaGeneration !== mediaGeneration || identity.sessionID !== expected.sessionID
                || identity.entryID !== expected.entryID || identity.trackID !== expected.trackID || identity.generation !== expected.generation) return false;
            context = {...context, rateContent: "unknown"};
            episodeRateMedia();
            return true;
        },
        command(value) {
            if (!context || value.loadID !== context.loadID
                || !Number.isInteger(value.revision) || value.revision <= commandRevision) return false;
            if (value.sectionGuard !== undefined && !acceptsSectionSeek(value)) {
                // Acknowledge this intent revision without queuing a seek or changing playback.
                commandRevision = value.revision;
                report("state");
                return false;
            }
            commandRevision = value.revision;
            if (value.name === "play" || value.name === "pause") {
                wantsPlaying = value.name === "play";
                intentSource = "native";
                if (wantsPlaying && video && video.paused) hasPlayedCurrentMedia = false;
            }
            else if (value.name === "seek" && Number.isFinite(value.value) && value.value >= 0) pendingSeek = value.value;
            else if (value.name === "volume" && Number.isFinite(value.value)) desiredVolume = Math.min(1, Math.max(0, value.value));
            else return false;
            applyIntent();
            report("state");
            return true;
        }
    });
    attach();
})();
