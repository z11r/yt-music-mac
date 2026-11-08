(() => {
    "use strict";
    if (globalThis.YTMusicNativeEpisodeRateV1) return;
    const markerName = "data-ytm-native-episode-rate-v1";
    let rateRevision = 0;
    const number = value => typeof value === "number" && Number.isFinite(value) && value >= 0.25 && value <= 4;
    const uuid = value => typeof value === "string" ? value.toLowerCase() : null;
    function sameIdentity(a, b) {
        return !!a && !!b && uuid(a.sessionID) === uuid(b.sessionID) && uuid(a.entryID) === uuid(b.entryID)
            && typeof a.trackID === "string" && a.trackID === b.trackID && typeof a.generation === "string" && a.generation === b.generation;
    }
    function scope(value) {
        const player = document.querySelector("#movie_player");
        const media = document.querySelector("#movie_player video");
        if (!value || !player || !media || !media.isConnected || !player.contains(media) || media.readyState < 1
            || player.classList.contains("ad-showing") || player.classList.contains("ad-interrupting")) return null;
        let marker;
        try { marker = JSON.parse(media.getAttribute(markerName)); } catch (_) { return null; }
        if (!marker || marker.version !== 1 || marker.ready !== true || marker.content !== value.content
            || !["episode", "song"].includes(marker.content) || !sameIdentity(marker.identity, value.identity)
            || uuid(marker.loadID) !== uuid(value.loadID) || uuid(marker.documentID) !== uuid(value.documentID)
            || marker.mediaGeneration !== value.mediaGeneration || !Number.isInteger(marker.mediaGeneration) || marker.mediaGeneration <= 0
            || !Number.isSafeInteger(marker.changes) || marker.changes < 0 || marker.changes > 2147483647) return null;
        const page = new URL(location.href);
        if (page.protocol !== "https:" || page.hostname !== "music.youtube.com" || page.username || page.password
            || (page.port && page.port !== "443") || page.searchParams.get("v") !== marker.identity.trackID) return null;
        return {player, media, marker};
    }
    function inspect(value) {
        const target = scope(value);
        if (!target) return {reason: "stale"};
        try {
            const {player, media, marker} = target;
            if (!["getAvailablePlaybackRates", "getPlaybackRate", "setPlaybackRate", "getVideoUrl"].every(name => typeof player[name] === "function")) {
                return {reason: "unsupported"};
            }
            const url = new URL(player.getVideoUrl());
            if (url.protocol !== "https:" || url.username || url.password || (url.port && url.port !== "443")
                || !["www.youtube.com", "youtube.com", "music.youtube.com"].includes(url.hostname)
                || url.searchParams.get("v") !== value.identity.trackID) return {reason: "stale"};
            const rates = player.getAvailablePlaybackRates();
            const current = player.getPlaybackRate();
            const mediaRate = media.playbackRate;
            if (!Array.isArray(rates) || rates.length === 0 || rates.length > 16 || !rates.every(number)
                || !number(current) || current !== mediaRate || !rates.includes(current)) return {reason: "unsupported"};
            return {reason: "supported", target, snapshot: {rates: [...new Set(rates)].sort((a, b) => a - b), current, mediaRate, changes: marker.changes}};
        } catch (_) { return {reason: "unsupported"}; }
    }
    function reply(value, inspected, accepted = false, changed = false) {
        return {accepted, reason: inspected.reason, changed, snapshot: inspected.snapshot || null,
                loadID: value && value.loadID, documentID: value && value.documentID, identity: value && value.identity,
                mediaGeneration: value && value.mediaGeneration, content: value && value.content};
    }
    function snapshot(value) {
        return reply(value, inspect(value));
    }
    function change(value, content) {
        const before = inspect(value);
        if (before.reason !== "supported") return Promise.resolve(reply(value, before));
        if (value.content !== content || !Number.isInteger(value.revision) || value.revision <= rateRevision
            || !number(value.rate) || !before.snapshot.rates.includes(value.rate)
            || value.expectedRate !== before.snapshot.current || value.expectedChanges !== before.snapshot.changes
            || (content === "song" && value.rate !== 1)) return Promise.resolve(reply(value, {reason: "stale"}));
        rateRevision = value.revision;
        if (value.rate === before.snapshot.current) return Promise.resolve(reply(value, {reason: "confirmed", snapshot: before.snapshot}, true, false));
        const {media, player} = before.target;
        return new Promise(resolve => {
            let finished = false;
            let observedRateChange = false;
            let timer;
            const events = ["ratechange", "loadstart", "emptied"];
            const finish = (inspected, accepted = false) => {
                if (finished) return;
                finished = true;
                if (timer !== undefined) clearTimeout(timer);
                events.forEach(name => media.removeEventListener(name, changed));
                resolve(reply(value, inspected, accepted, accepted));
            };
            const changed = event => {
                if (event && event.type === "ratechange") observedRateChange = true;
                const actual = inspect(value);
                if (!actual.target || actual.target.media !== media || actual.target.player !== player || rateRevision !== value.revision) {
                    finish({reason: "stale"}); return;
                }
                if (observedRateChange && actual.reason === "supported" && actual.snapshot.current === value.rate
                    && actual.snapshot.changes > before.snapshot.changes) finish({reason: "confirmed", snapshot: actual.snapshot}, true);
            };
            events.forEach(name => media.addEventListener(name, changed));
            timer = setTimeout(() => {
                changed();
                if (!finished) finish({reason: scope(value) ? "rejected" : "stale"});
            }, 1500);
            try {
                const transition = player.setPlaybackRate(value.rate);
                if (transition && typeof transition.then === "function") transition.then(() => changed(), () => finish({reason: "rejected"}));
                changed();
            } catch (_) { finish({reason: "rejected"}); }
        });
    }
    globalThis.YTMusicNativeEpisodeRateV1 = Object.freeze({snapshot,
        setEpisodeRate(value) { return change(value, "episode"); },
        resetOwnedSongRate(value) { return change(value, "song"); }});
})();
