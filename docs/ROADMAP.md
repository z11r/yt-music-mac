# Roadmap

Start with a player that can be used for a full listening session. Add library
editing and compact controls after playback is reliable. There is no release
date yet.

## 1. App foundation

Create the Swift package, app bundle, and core test target. Use Swift 6.2 or
later, target macOS 14, and compile for arm64 and x86_64. Give development builds
their own bundle identifier and storage.

Start from the music components in Kaset revision
`6a20e60c5dfd552a22e84f36daeef53f94f1ee41`. Check the dependency boundaries before
importing code, preserve its MIT notices, and record the imported files and
revision. Leave video browsing, extensions, and the equalizer out of the first
prototype.

Done when a clean checkout builds a launchable app for both architectures, core
tests run in CI, and the app opens without touching an existing Kaset installation.

## 2. Playback prototype

Add Google sign-in, session restoration, a basic search screen, and playback.
Keep one playback owner alive while browsing or closing the main window. Add
play/pause, next/previous, seek, volume, and a visible queue.

Separate the requested track from the track confirmed by the player. Handle
repeated songs, rapid skipping, natural endings, and stale events. Restore a
saved queue on launch without automatically playing it.

Done when sign-in, search, playback, queue changes, and relaunch work in the
packaged app. Test network loss, session expiry, and sleep/wake. Record which
account types and macOS versions were actually used.

## 3. Library and playlists

Add playlists, liked songs, albums, and artist pages. Load every page of a large
collection and keep scrolling responsive while artwork loads. Show errors and
retry controls without discarding the rest of the library.

Then add playlist search, multi-selection, Play Next, Add to End, and queue
reordering. Add remote likes and playlist edits once read-only browsing is
stable; show whether each edit succeeded and recover from failed requests.

Done when a collection larger than one API page is complete, duplicate tracks
remain distinct, and paging or navigation does not interrupt playback.

## 4. Mac controls

Add media keys, Control Center, Dock commands, a mini-player, and menu bar
controls. All controls must use the same playback state. Preserve standard
window and text-editing shortcuts. Make menus and controls usable with the
keyboard and VoiceOver.

Done when controls stay in sync across windows, typing in search does not change
tracks, and the app behaves correctly with Reduce Motion and Reduce Transparency.

## 5. Reliability and performance

Run the [test plan](TESTING.md) on Intel and Apple silicon. Fix reproduced
playback, session, pagination, and memory problems before adding more features.
Compare optimized builds against the pinned Kaset baseline on the same hardware.

Done when the two-hour listening test and 100-transition test pass, older-OS
fallbacks have been checked, and resource measurements include the app and its
WebKit processes. Set resource budgets from those results.

## 6. First beta

Create a universal app bundle, sign and notarize it, and test installation and
updates on the supported systems. Publish build instructions, third-party
notices, tested OS versions, and known issues. Add the update framework here,
once the app identity and release process are settled.

Developer ID signing requires a developer account and certificate. Local
prototype builds can use ad-hoc signing until those are available.

## Work packages and order

Each row is a reviewable change. A feature is complete only after its acceptance
check passes. Unit tests, live service checks, packaged-app checks, and hardware
checks provide different evidence; record them separately.

| ID | Work | Depends on | Acceptance check |
| --- | --- | --- | --- |
| F1 | Package, isolated app identity, developer tools | — | Clean checkout builds without changing the machine's Xcode selection. |
| F2 | Track, queue entry, and occurrence models | F1 | Duplicate songs remain distinct; old endings cannot advance a newer request. |
| F3 | Queue editing, shuffle, repeat, undo | F2 | Deterministic tests cover navigation, multi-remove, reorder, and repeat. |
| F4 | Versioned queue storage | F2 | Atomic writes, corrupt/future files, and restore without autoplay are tested with temporary stores. |
| S1 | Request transport and current web configuration | F1 | Anonymous requests work through the native client; retries are bounded and cancellable. |
| S2 | Response parsing and collection paging | S1 | Fixtures cover response variants, duplicates, continuation loops, and partial failures. |
| A1 | Dedicated WebKit session and Google sign-in | F1 | No browser-profile access; debug and release sessions stay separate. |
| A2 | Account changes and sign-out | A1, S1 | Delayed work cannot restore an old account; sign-out clears only this app's data. |
| P1 | Persistent player and typed bridge | A1, F2 | A message needs the current document, media, and native occurrence identities. |
| P2 | Transport and recovery | P1, F3 | Play, pause, seek, volume, repeats, rapid skips, errors, and retry work in the packaged app. |
| P3 | Queue/session restoration | P2, F4, A2 | Relaunch preserves the queue; playback starts only after an explicit action. |
| B1 | Search, discovery, album, and artist navigation | S2 | Native parsed results match live anonymous pages; obsolete searches cannot replace newer results. |
| B2 | Signed-in library and liked songs | A2, S2 | Premium account results are complete across multiple pages and survive retry. |
| B3 | Playlist filtering and multi-selection | B1, F3 | Play Next/Add to End and filtering preserve occurrence order. |
| B4 | Remote likes and playlist edits | B2 | Each operation confirms service success; failed edits retain local context and retry safely. |
| U1 | Sidebar, toolbar, shelves, and persistent player | P2, B1 | Main window works from 860 × 600 upwards in light and dark appearances. |
| U2 | Queue inspector and collection controls | U1, B3 | Reorder/remove work with keyboard alternatives and duplicate entries. |
| U3 | Account, empty, loading, and recovery screens | U1, A2 | Every visible action works; errors retain useful context. |
| M1 | Media keys, Control Center, and Dock commands | P2 | Native commands address the same player and expose the actual playback state. |
| M2 | Mini-player and menu bar controls | U1, M1 | Opening or closing windows creates no additional playback engine. |
| M3 | Keyboard and accessibility pass | U2, U3, M2 | Text editing, VoiceOver, Full Keyboard Access, and system accessibility preferences pass. |
| R1 | Host and universal app packaging | F1, P1 | Both slices have the same deployment target, bundled resources, and a valid local signature. |
| R2 | CI tests and host bundles | R1, S2, F4 | Intel and Apple silicon jobs test the actual app, including relocated resource loading. |
| R3 | Long-session and failure testing | P3, B2, M2 | Two hours of listening and 100 track transitions pass; sleep/wake and network recovery are recorded. |
| R4 | Resource measurements against Kaset | R3 | Same hardware, account, queue, and build configuration; include app and WebKit processes. |
| R5 | Minimum-OS and hardware checks | R1, M3 | macOS 14 and current supported systems pass the runtime matrix on both processor families. |
| R6 | Public beta signing and distribution | R2–R5 | Developer ID, notarization, fresh install, and update checks pass. |

F2–F4 and S1–S2 have automated coverage. Anonymous live checks for B1 pass.
The native interface and local packaging are implemented. Initial Premium
playback works, Intel and Apple silicon CI checks pass, and a short Kaset
comparison is recorded in [performance](PERFORMANCE.md). Extended signed-in
checks, accessibility, long sessions, and older-system runtime checks remain open; see
[testing](TESTING.md) and [compatibility](COMPATIBILITY.md) for evidence.

The first local build uses ad-hoc signing. R6 requires an Apple Developer
membership and certificate. It does not block local development. The test
account selected for the first signed-in pass is YouTube Music Premium; other
account types need their own verification.

## Follow-up features

After the beta gates pass, consider local folders and pinned favorites, lyrics
when supplied by the service, a sleep timer, named saved queues, and Shortcuts
actions. Add these as separate changes with storage and keyboard checks. Label
organization that stays on the Mac as local.

Downloads, crossfade, loudness normalization, and device handoff need separate
playback, entitlement, and service checks. Do not promise these features before
those checks establish a supported implementation. Automatic updates also need
a distribution identity, signing keys, and a tested recovery path.
