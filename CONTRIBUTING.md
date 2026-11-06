# Contributing

Work is starting with a playback prototype. Check the [roadmap](docs/ROADMAP.md)
before taking on a larger feature.

Keep pull requests focused. Describe the problem, what changed, and how you
tested it. For app changes, include the macOS version and processor used.

Playback, queue, session, and library changes need tests for the behavior they
fix. Use isolated test storage; tests must not change a signed-in music library.
Newer system APIs need a fallback on the oldest supported macOS version.

Bug reports should include reproduction steps, the app version, macOS version,
Mac model, and audio output. For performance problems, include memory size and
whether the build is debug or release. Report the app and WebKit processes
separately. Remove credentials and personal account data from logs before posting.

Contributions are MIT licensed. Keep copyright notices and attribution when
reusing third-party code.
