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
Recovery tests save and reopen isolated queue files after failed loads, and check
that retries, new occurrences, explicit seeks, and account changes handle saved
positions correctly. Keyboard tests cover text and web focus, sheets, focused
controls, shortcut routing, bounded seek steps, and volume/mute actions using
isolated preferences without network requests. Combined checkpoint `267784d`
passed 1,533 deterministic checks locally on Apple silicon; four opt-in live
checks were skipped. See [compatibility evidence](COMPATIBILITY.md) for its
universal package and hosted Intel/Apple silicon results.

Local audio checks use fake bookmark/file/profile adapters and fake native output.
The integrated transport also uses controlled Web acknowledgments and retirement
receipts. Tests cover preparation-time Play/Pause/Mute, stale progress/end events,
retained resource lifetimes, seek preservation, source changes, blocked profile
activation, sign-out admission and wholly local versus unverified mixed startup
queues. They establish control and storage behavior without playing local files
or invoking real chooser/bookmark/AV output operations. Native format, permission,
device and accessibility acceptance remains separate.

[Optional Apple lyrics translation](LYRICS_TRANSLATION.md) uses injected language
and translation providers in tests. Checks cover explicit admission, frozen
source and credit, stale owners, view-host cancellation, held native-call
settlement and bounded output. Tests and bundle diagnostics do not query Apple's
language list, create a translation session, prepare models or translate text.
Actual model consent/download, language availability and native accessibility
acceptance remain separate.

Check scripts and workflow syntax separately:

```sh
shellcheck Scripts/*.sh
actionlint .github/workflows/checks.yml
python3 -B -m unittest discover -s Scripts/tests
```

CI runs tests and packages the host architecture on Intel/macOS 15 and Apple
silicon/macOS 26. It does not sign in, modify a library, or run network probes.

## Bundle checks

```sh
app_path="$(Scripts/build-app.sh --configuration release --universal)"
Scripts/check-app.sh "$app_path" --configuration release --universal --smoke-test --ui-smoke-test
```

The static check verifies bundle metadata, executable architectures, macOS 14
deployment targets, packaged playback resources, license files, library paths, and the code
signature. Each linked thin executable and each requested packaged slice must
keep Translation, its SwiftUI overlay and FoundationModels absent or weakly
linked, with weak optional imports. Parser fixtures reject strong loads/imports,
truncated metadata and failed tools; CI runs those fixtures separately.
The smoke check copies the app outside the checkout, clears package
resource overrides, and runs the bundle's diagnostic mode. That mode verifies
its own identity, resource location, and registration of the native playback
commands before creating a playback session or contacting the music service.
It does not establish playback or accessibility behavior.

The UI smoke check opens the relocated release app with synthetic music and
requires 100 rendered queue-state changes in its real window and menu scenes.
It uses disposable preferences, nonpersistent WebKit storage, a transport that
rejects requests, and no saved queue or system media registration. It checks
that no request, sign-in, or playback occurred, then removes its preferences.
The app stops itself after 18 seconds and reports how far it got: launch steps,
rendered changes, and the windows it had open. This check does not replace
visual, keyboard, VoiceOver, or live playback testing.

Run the UI smoke check on a Mac with a logged-in desktop session. CI runs the
static and smoke checks but not the UI check. On November 7, 2026, the hosted
macOS 15 Intel and macOS 26 Apple silicon runners finished launching the app
and kept its main thread responsive, but never created its main window. Only the
menu bar item appeared, whether the app was started directly or through Launch
Services. On an Apple silicon Mac running macOS 26, the same check completed
100 changes in 5.4 to 8.5 seconds.

## Anonymous service checks

This opt-in test makes read-only requests using a client with no credentials:

```sh
YTM_RUN_NETWORK_TESTS=1 Scripts/with-xcode.sh swift test --filter MusicLiveTests --jobs 2
```

It checks home, explore, search, and discovered album, artist, and playlist
pages. The native client passed these checks locally on November 6, 2026.
Service responses vary over time and by region, so a failure needs inspection.
No response bodies, configuration keys, or account data should be saved in logs.

A separate opt-in test checks search filters and suggestions:

```sh
YTM_RUN_NETWORK_TESTS=1 Scripts/with-xcode.sh swift test --filter MusicSearchLiveTests --jobs 2
```

It searches for “Mozart” with each filter and checks that every result has the
expected kind: songs and videos are playable tracks, albums are albums, artists
are artists, and both playlist filters return playlists. It also loads a second
page of songs, checks that the videos differ from the songs, and requests
suggestions for partly typed text. It passed locally on November 7, 2026.

On November 6, 2026, a Premium account check completed a liked-song collection
larger than one page, but library and playlist paging failed. On November 7, a
release build of commit `fdc2b32` loaded the library and liked songs across two
pages each, with no pages remaining. The checked playlist fit on one page.
A later local release build completed another playlist with 618 playable song
occurrences across seven pages. Its per-page counts were 97, 99, 100, 100, 99,
100, and 23, with no continuation remaining and no reported errors. In the same
check, the library returned 44 collections across two pages and liked songs
returned 124 occurrences across two pages. Playback stayed paused.
Recovery after a failed live page and agreement with the counts shown by the
service still need checking. Remote likes and playlist edits remain unavailable while
service validation is pending. Do not run automatic account mutations as part
of CI.

Pagination tests now cover cursor selection with synthetic responses:

- A grid or track cursor takes precedence over the cursor of the enclosing
  section list.
- On a playlist page, the section list cursor is not followed, because it loads
  suggestions instead of more tracks.
- A refresh cursor is not treated as the next page.
- A cursor wrapped in a command list is found.
- An advertised next-page cursor with no readable token reports an error.
  Retrying the page keeps the previously loaded playlist occurrences.
- A rejected request is reported with its HTTP status instead of as an outage.

These rules match the library and playlist parsers in Kaset at the pinned
revision and in ytmusicapi.

Search tests read trimmed anonymous responses for each filter, for a second page
of songs, and for suggestions. Names, identifiers, artwork addresses, and
continuation tokens in these files are synthetic. Other tests hold a response
until a newer search, filter, page, or suggestion request has finished, then
check that the older response changes nothing.

Local recent-search checks cover ordering, deduplication, bounds, clearing, and
account changes. A delayed suggestion from the old account must not reappear
after the account changes. Recent searches are kept only for the app session;
these checks do not read or modify the service's search history.

Library-category and listening-history tests use synthetic account sessions.
They check dedicated browse routes, required authentication, history day groups,
repeated plays across pages, account fences, stale navigation, and retry while
keeping visible results. These routes match the pinned Kaset client; live
category/history response shapes and totals still need verification.
Loaded-library display-sort checks cover service order, natural numeric title
sorting, stable order for identical titles, and preservation of repeated items.
The source page remains unchanged when a display sort is chosen.

Lyrics tests use synthetic text and the response shapes documented in Kaset's
pinned parser. They cover exact video requests, source attribution, plain versus
timed results, invalid timing fallback, missing/disabled lyrics, parsing bounds,
account changes, cancellation, deadlines, retry, and stale-track replies. No
external lyrics provider is requested. The timed path is conditional on actual
service timestamps; live plain/timed availability, source matching, panel
layout, and VoiceOver still need verification.

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


## Populated additional-profile cleanup

Run the focused profile cleanup fixtures without accessing an actual profile:

```sh
Scripts/with-xcode.sh swift test --jobs 1 --filter 'ProfileMetadataCleanupTests|ProfileDeletionTests|AppProfileTests'
```

The fixtures cover recognized metadata schemas, unsupported and future fields,
write-ahead file checkpoints, lost acknowledgments, digest and revision changes,
reappearing files, descriptor identities, symlinks, hard links, store-lock
contention and retained shared profile leases. Filesystem cases create disposable
metadata only. Local-audio grants contain synthetic opaque bytes, never native
bookmarks. Provider, preference, Spotlight and website removal use fakes.

Actual inactive-profile cleanup remains a separate runtime acceptance check.
Verify the selected-profile protection and retained native-resource lease gates,
then inspect the explicit review and each confirmed outcome in a disposable
profile. Local audio files and external exports must remain intact.

## Startup, episode details and playlist contributors

Run the focused deterministic checks with isolated preferences, service fixtures
and injected lifecycle controls:

```sh
Scripts/with-xcode.sh swift test --jobs 1 --filter 'StartupWindow|AppAutomation|EpisodeDetails|PlaylistCollaboration|CustomControlAccent|NativeControlAccent|MusicDiscovery|RecordingCounterpart|ArtistAbout'
```

[Custom accent checks](APPEARANCE.md) use memory preferences and pure sRGB
values. They cover draft cancellation, retained picker callbacks, stale owners,
unknown stored values, reference contrast and narrow profile-cleanup admission.
They never open the native picker or establish visual control contrast.

[Startup checks](STARTUP_WINDOWS.md) cover launch ownership, presentation
requests, stale profile/account requests and shutdown. Packaged scene checks use
disposable preferences and synthetic queue changes with playback output disabled.
They do not establish login approval, system restoration or foreground focus.

[Episode details](EPISODE_DETAILS.md) use bounded service text and exact current
queue, occurrence, profile and account targets. Fixtures hold credential and
fetch work across cancellation and owner changes. Timestamp references retain
their numeric source position. Explicit actions use fresh native content proof,
actual duration and exact document/media/command guards; they never queue a seek
through an advertisement. Synthetic bridge checks cover clock and identity
changes, refusal, bounded receipts and real-call admission across cancellation.
Actual WebKit playback, advertisement timing and sleep behavior remain pending.

[Paired recording checks](VIDEO_PRESENTATION.md) verify the service's exact
primary/counterpart relationship, bounded metadata, actual credential scope,
review expiry and current queue ownership. Confirmation inserts and selects the
returned new entry UUID; it preserves the original queue and starts at zero.
These fixtures do not establish playback entitlement or timeline equivalence.

[Playlist contributors](COLLABORATIVE_PLAYLISTS.md) come only from a recognized
current header. Fixtures cover bounded labels and portraits, unrelated headers,
and keeping contributor channels out of track artist metadata across pages.
They do not establish membership or edit permission.

[Artist About checks](COLLECTION_DETAILS.md#artist-about-text) cover current
primary descriptions, supplied credit text and addresses, header-only fallback,
strict bounds and immutable presentation scopes. Both ordinary and scoped artist
destinations are covered. No biography request or URL action is introduced.

In a packaged app, verify these panels with keyboard navigation, VoiceOver,
long text and right-to-left text. Change accounts, profiles and the selected
track or playlist while a read is pending; the previous owner's content must
stop displaying. Signed-in response coverage and image delivery remain separate
from synthetic parsing and lifecycle checks.
