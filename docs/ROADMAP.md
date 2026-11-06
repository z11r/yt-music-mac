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

## Later

Consider folders, pinned favorites, lyrics, a sleep timer, saved queues, and
Shortcuts integration. Label organization that stays on the Mac as local.
Downloads, crossfade, loudness normalization, and device handoff need separate
playback and service checks before being added to the roadmap.
