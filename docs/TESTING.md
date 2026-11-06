# Testing

The current CI checks setup scripts, workflow syntax, and development tools on
Intel and Apple silicon. App builds and tests belong in the same workflow once
the app target exists.

## Automated tests

Keep queue and parser tests independent of WebKit and real accounts. Use a fresh
storage directory for each test. Run the suite in parallel once state is isolated.

Cover these cases first:

- Repeated songs, rapid next/previous commands, shuffle, and each repeat mode.
- A late event from the previous track, duplicate end events, and a failed load.
- Multiple library pages, empty pages, repeated continuation tokens, and retries.
- Relaunch with a saved queue, a cancelled login, sign-out, and account changes.
- Network failure without clearing credentials, followed by successful recovery.
- Artwork eviction and cancelled requests after navigation.

Use recorded, redacted response fixtures for parsing. Live service checks are
separate from routine CI. Do not run automatic library mutations against a real
account.

## Manual playback

Use the packaged app and record the commit, macOS build, processor, account tier,
audio output, and result. Cover sign-in, search, seek, volume, natural endings,
queue changes, closing and reopening windows, quit/relaunch, and sleep/wake.

Run at least 100 manual and natural track transitions, including repeated songs
and edits near the currently playing entry. There should be no wrong-track
changes or double advances. Then run a two-hour listening session and inspect
memory growth, stalls, and recovery behavior.

Check Bluetooth reconnects, built-in speakers, and an external audio device
where available. Repeat basic playback in a non-English locale. Test keyboard
focus, VoiceOver, display scaling, and reduced motion/transparency settings.

## Compatibility

The initial target is macOS 14 or later. Test the oldest supported release and
the newest stable OS supported by each machine. Include a physical Intel Mac and
an Apple silicon Mac with modest memory. Build success on a recent CI runner is
not a runtime test of the minimum OS.

Keep untested hardware and account combinations listed as untested. If a feature
uses a newer API, exercise its fallback on an older system before release.

## Performance

Compare release builds using the same Mac, OS, account, content, output device,
and window state. Use a fixed Kaset revision and a Safari session for comparison.
Alternate runs and separate cold and warm caches.

Measure launch to usable content, time to audio, skip latency, CPU, energy,
scrolling, and memory over time. Report the app and related WebKit processes
separately. Note shared-process attribution limits and whether memory figures
are RSS or physical footprint. Use repeated measurements and report variation.

Do not set a headline memory or CPU target before collecting the baseline.
