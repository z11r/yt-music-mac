# Compatibility

The target is macOS 14 or later on Intel and Apple silicon. There is no app
release yet, so this is a development target rather than a supported-version list.

## Older macOS versions

Playback, search, playlists, and queue controls must work without newer visual
effects. Optional features should fall back or be unavailable on older systems
without preventing the rest of the app from running.

[Kaset](https://github.com/sozercan/kaset) is being evaluated as a starting point.
The revision evaluated during setup requires macOS 15.4. A build targeting
macOS 14 found three
areas needing changes: WebKit extension hosting, Spotlight indexing, and
equalizer cleanup. Lowering the deployment target alone is not enough.

## Before release

- Build for both arm64 and x86_64, including bundled frameworks and helpers.
- Run the packaged app on the oldest supported macOS version and the latest
  stable version available for each processor family.
- Check sign-in, session restoration, track changes, seeking, queue edits,
  large playlists, media keys, and closing and reopening the window.
- Test sleep and wake, network loss, Bluetooth reconnects, and output changes.
  Check power use while playing and while paused.
- Check keyboard navigation, VoiceOver, Reduce Motion, Reduce Transparency,
  dark mode, and at least one non-English locale.
- Make the app bundle, installer, and updater agree on the minimum macOS version.

Record the hardware, OS build, app version, and result for each test. A successful
build does not establish runtime compatibility. Rosetta testing is useful, but
does not replace testing on an Intel Mac. Results from patched Macs should be
listed separately from officially supported hardware.
