# Compatibility

The development target is macOS 14 or later on Intel and Apple silicon. There
is no supported-version claim for a public release yet. Compilation, bundle
checks, playback, and performance are separate checks.

## Current evidence

| Check | Status |
| --- | --- |
| 198 queue, service, session, playback bridge, scripting, recovery, library, and scene-check tests on Apple silicon, macOS 26.6, Xcode 27.2 | Passed locally |
| Anonymous home, explore, search, album, artist, and playlist requests through the native service client | Passed locally |
| Debug arm64 bundle and release universal bundle | Built locally; arm64 and x86_64 slices declare macOS 14 |
| Relocated debug and release bundle diagnostics on Apple silicon/macOS 26.6 | Passed identity, resources, runtime paths, and ad-hoc signature checks |
| CI tests and host app builds on Intel/macOS 15 and Apple silicon/macOS 26 | Checkpoint [6a6572f](https://github.com/z11r/yt-music-mac/actions/runs/42271840586) passed; newer checks pending |
| Release window and menu scenes with isolated synthetic data | Passed 100 rendered queue-state changes locally |
| Packaged app on macOS 14, physical Intel and Apple silicon | Pending |
| Initial Premium sign-in and playback on the development Mac | Manually reported working; extended cases pending |
| Packaged release: retained sign-in, queue restore without autoplay, saved-position playback, pause, and resume | Verified through native commands on the development Mac |
| Premium liked-song pagination | Completed a collection larger than one page locally; extended library and playlist pagination still fail |
| Signed-in playback, session restoration, and library browsing across the OS matrix | Pending |
| Short background playback and paused resource comparison with Kaset on the development Mac | [Measured](PERFORMANCE.md#november-6-2026-comparison); battery and AC results kept separate |
| Long listening sessions and memory growth | Pending |

The local checks above were run on November 6, 2026. They do not establish
runtime compatibility on older systems or a performance improvement over
another player.

## Older systems

Core playback, browsing, and queue controls must work without newer visual
effects. Newer APIs need availability checks and usable fallbacks. The package,
app metadata, and executable deployment target must agree on macOS 14.

A universal bundle contains arm64 and x86_64 code. Both slices must compile,
include matching dependencies, and pass signature and resource checks. Rosetta
checks are supplementary; physical Intel testing remains part of release
validation.

## Before release

- Run the packaged app on the oldest supported macOS version and the latest
  stable version available for each processor family.
- Check sign-in, session restoration, track changes, seeking, queue edits,
  large playlists, media keys, and closing and reopening the window.
- Test sleep and wake, network loss, Bluetooth reconnects, and audio output
  changes. Measure energy use while playing and paused.
- Check keyboard navigation, VoiceOver, Reduce Motion, Reduce Transparency,
  light and dark appearances, and a non-English locale.
- Record the hardware, memory, OS build, app revision, account tier, and result.

List patched systems separately from officially supported hardware. Keep
untested combinations marked as pending rather than treating a successful
build as runtime evidence.
