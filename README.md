# YT Music for Mac

A native YouTube Music player for macOS.

Local prototype. The native interface, browsing client, playback bridge, and
queue are implemented. Signed-in playback and the compatibility matrix are
still being validated. There is no signed public download yet.

The app includes search, discovery, collection pages, an editable queue,
shuffle/repeat, a mini-player, and menu bar controls. Google sign-in uses the
app's own WebKit session. Remote likes and playlist edits remain disabled until
signed-in checks pass.

## Compatibility

The target is macOS 14 or later, with native builds for Intel and Apple silicon.
The minimum version is still being tested. See the [compatibility notes](docs/COMPATIBILITY.md).

## Development

Install Xcode, then run:

```sh
brew bundle
Scripts/doctor.sh
Scripts/with-xcode.sh swift test --jobs 2
app_path="$(Scripts/build-app.sh)"
open "$app_path"
```

This creates an ad-hoc signed development app with separate storage from release
builds. A public notarized release requires an Apple Developer membership.

See [development setup](docs/DEVELOPMENT.md), the [roadmap](docs/ROADMAP.md),
[architecture](docs/ARCHITECTURE.md), [testing](docs/TESTING.md), and
[interface design](docs/DESIGN.md). [Native playback commands](docs/AUTOMATION.md)
are available for local automation.

## License

[MIT](LICENSE). This is an unofficial project and is not affiliated with Google
or YouTube.
