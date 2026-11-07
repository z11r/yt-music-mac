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
            errorCode: errorCode || null
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
            "emptied", "loadstart", "error", "ended", "volumechange"];
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
            pendingSeek = null;
            endedGeneration = -1;
            attach();
            applyIntent();
            return report("ready");
        },
        command(value) {
            if (!context || value.loadID !== context.loadID
                || !Number.isInteger(value.revision) || value.revision <= commandRevision) return false;
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
