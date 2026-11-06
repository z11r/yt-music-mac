# YT Music for Mac

A native YouTube Music player for macOS.

Early development. There is no playable app or download yet. This repository
contains the development setup and plans for the first Swift/SwiftUI prototype.

The first version will focus on playback, search, playlists, and a queue that
keeps playing while you browse. Mac features on the roadmap include media keys,
Control Center, a mini-player, and menu bar controls.

## Compatibility

The target is macOS 14 or later, with native builds for Intel and Apple silicon.
The minimum version is still being tested. See the [compatibility notes](docs/COMPATIBILITY.md).

## Development

Install Xcode, then run:

```sh
brew bundle
Scripts/doctor.sh
```

See [development setup](docs/DEVELOPMENT.md), the [roadmap](docs/ROADMAP.md),
[architecture](docs/ARCHITECTURE.md), [testing](docs/TESTING.md), and
[contributing](CONTRIBUTING.md).

## License

[MIT](LICENSE). This is an unofficial project and is not affiliated with Google
or YouTube.
