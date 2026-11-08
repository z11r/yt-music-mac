# Compatibility

The development target is macOS 14 or later on Intel and Apple silicon. There
is no supported-version claim for a public release yet. Compilation, bundle
checks, playback, and performance are separate checks.

## Current evidence

Checks name the exact source checkpoint; later feature work can follow it.

| Check | Status |
| --- | --- |
| Local automated suite on Apple silicon, macOS 26.6, Xcode 27.2 | Checkpoint `1e1ad01` passed 1,420 deterministic checks; four opt-in live checks skipped. The earlier `378d938` checkpoint passed full compiler-key localization coverage. An earlier intermittent TXT-export error remains under investigation; see [export verification](STREAMING_METADATA_EXPORT.md#verification). |
| Anonymous home, explore, search, album, artist, and playlist requests through the native service client | Passed locally |
| Local release universal bundle | Checkpoint `378d938` built locally; arm64 and x86_64 slices declare macOS 14 |
| Relocated release bundle diagnostics on Apple silicon/macOS 26.6 | Checkpoint `378d938` passed identity, resources, runtime paths, shortcut metadata and ad-hoc signature checks |
| CI tests and host app builds on Intel/macOS 15 and Apple silicon/macOS 26 | Feature checkpoint [62b6457](https://github.com/z11r/yt-music-mac/actions/runs/42519020381) passed tests, release packaging and relocated-bundle checks on both architectures with Xcode 26.2 |
| Release window and menu scenes with isolated synthetic data | Checkpoint `378d938` passed 100 synthetic rendered queue-state changes locally. The report recorded `windowVisible=false`; this does not establish visible layout, focus or VoiceOver behavior |
| Packaged app on macOS 14, physical Intel and Apple silicon | Pending |
| Initial Premium sign-in and playback on the development Mac | Manually reported working; extended cases pending |
| Packaged release: retained sign-in, queue restore without autoplay, saved-position playback, pause, and resume | Verified through native commands on the development Mac |
| Premium library and playlist pagination | Earlier local release `68ee772` completed 44 library collections across two pages, 124 liked songs across two pages, and another playlist with 618 playable occurrences across seven pages; live failed-page recovery and count reconciliation pending |
| Signed-in playback, session restoration, and library browsing across the OS matrix | Pending |
| Short background playback and paused resource comparison with Kaset on the development Mac | [Measured](PERFORMANCE.md#november-6-2026-comparison); battery and AC results kept separate |
| Long listening sessions and memory growth | Pending |

The local checks above were run on November 6–8, 2026. They do not establish
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
