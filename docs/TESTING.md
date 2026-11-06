# Testing

## Automated checks

Run the suite with full Xcode:

```sh
Scripts/with-xcode.sh swift test --jobs 2
```

The wrapper avoids accidentally using Command Line Tools, which may lack the
test frameworks. Tests use temporary storage, injected sessions, and mock
transports. They do not read a browser profile or use a real account.

Queue tests cover repeated songs, rapid navigation, shuffle, repeat modes,
stale playback events, duplicate endings, removal, reordering, undo, and
versioned persistence. Service tests cover renderer variants, pagination,
deduplication, cancellation, retry limits, account changes, and distinct
network, authentication, and access failures. The parser fixtures adapted from
Kaset are listed in [Third-party notices](../THIRD_PARTY_NOTICES.md).

The queue stress test runs 10,000 seeded mixed operations and checks entry
identity, stale endings, and restorable snapshots after each change. These are
in-memory queue operations, not 10,000 live song transitions. Network tests use
isolated URL protocols to check transfer limits, cancellation, and redirects.
Mutation tests cover service confirmations and account fences without modifying
a real library. Playback script tests run in JavaScriptCore with controlled
media events, including stale document navigation and repeated endings.

Check scripts and workflow syntax separately:

```sh
shellcheck Scripts/*.sh
actionlint .github/workflows/checks.yml
```

CI runs tests and packages the host architecture on Intel/macOS 15 and Apple
silicon/macOS 26. It does not sign in, modify a library, or run network probes.

## Bundle checks

```sh
app_path="$(Scripts/build-app.sh --configuration release --universal)"
Scripts/check-app.sh "$app_path" --configuration release --universal --smoke-test
```

The static check verifies bundle metadata, executable architectures, macOS 14
deployment targets, packaged playback resources, license files, library paths, and the code
signature. The smoke check copies the app outside the checkout, clears package
resource overrides, and runs the bundle's diagnostic mode. That mode verifies
its own identity and resource location before creating app or account state.
It does not establish playback or accessibility behavior.

## Anonymous service checks

This opt-in test makes read-only requests using a client with no credentials:

```sh
YTM_RUN_NETWORK_TESTS=1 Scripts/with-xcode.sh swift test --filter MusicLiveTests --jobs 2
```

It checks home, explore, search, and discovered album, artist, and playlist
pages. The native client passed these checks locally on November 6, 2026.
Service responses vary over time and by region, so a failure needs inspection.
No response bodies, configuration keys, or account data should be saved in logs.

Signed-in library and liked-song requests still need account testing. Remote
likes and playlist edits remain unavailable while that work is pending. Do not
run automatic account mutations as part of CI.

## Manual playback

Use the packaged app and record the commit, macOS build, processor, account
tier, audio output, and result. Cover sign-in, search, seek, volume, natural
endings, queue changes, closing and reopening windows, quit and relaunch, and
sleep and wake.

Run at least 100 manual and natural track transitions, including repeated songs
and edits near the playing entry. There should be no wrong-track changes or
double advances. Then run a two-hour listening session and inspect memory
growth, stalls, and recovery behavior.

Check Bluetooth reconnects, built-in speakers, and an external audio device
where available. Repeat basic playback in a non-English locale. Test keyboard
focus, VoiceOver, display scaling, and reduced motion and transparency.

## Compatibility and performance

Test the oldest supported macOS release and the newest stable OS supported by
each machine. Include a physical Intel Mac and an Apple silicon Mac with modest
memory. Record results in [Compatibility](COMPATIBILITY.md).

Compare release builds using the same Mac, OS, account, content, output device,
and window state. Use a fixed Kaset revision and a Safari session for comparison.
Alternate runs and separate cold and warm caches.

Measure launch to usable content, time to audio, skip latency, CPU, energy,
scrolling, and memory over time. Report the app and related WebKit processes
separately. Note shared-process attribution limits and whether memory figures
are RSS or physical footprint. Use repeated measurements and report variation.
Do not claim a resource-use improvement before collecting those results.
The [resource measurement guide](PERFORMANCE.md) describes the sampler, process
selection, and matched comparison procedure.
