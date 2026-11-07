# Development

The app uses Swift, SwiftUI, AppKit, and WebKit. Building requires full Xcode
with Swift 6.2 or later. The deployment target is macOS 14.

## Tools

Install Xcode, open it once to finish setup, then run:

```sh
Scripts/doctor.sh
```

The scripts respect `DEVELOPER_DIR` when set. Otherwise they use the selected
full Xcode installation or `/Applications/Xcode.app`. They do not change the
system's Xcode selection.

Homebrew is optional. `brew bundle` installs the repository's command-line
contribution tools: GitHub CLI, ShellCheck, and actionlint. The app has no
third-party package dependencies.

## Build an app

Build a debug app for the current Mac:

```sh
app_path="$(Scripts/build-app.sh)"
open "$app_path"
```

Build an optimized app containing both Intel and Apple silicon executables:

```sh
app_path="$(Scripts/build-app.sh --configuration release --universal)"
Scripts/check-app.sh "$app_path" --configuration release --universal --smoke-test
```

Each invocation creates a new directory under `.build/app-bundles/`. It keeps
the app and separate build directories for each architecture. Existing builds
are left intact. Build diagnostics go to stderr; stdout contains the completed
app's path.

The bundle contains its executable, package resources, licenses, and any Swift
compatibility libraries selected by Xcode. It can be copied out of the build
directory. The smoke check copies it to a temporary location and verifies the
bundle identity and playback script without creating a session or contacting
YouTube Music.

Debug builds use `io.github.z11r.ytmusicmac.debug`; release builds use
`io.github.z11r.ytmusicmac`. Their preferences, queue files, and WebKit website
stores are separate. Local bundles receive an ad-hoc signature. These scripts
do not use a signing account, notarize the app, or create a public release.

## Run checks

```sh
Scripts/with-xcode.sh swift test --jobs 2
shellcheck Scripts/*.sh
actionlint .github/workflows/checks.yml
```

GitHub Actions is configured to run tests, build the host architecture, and
check a relocated release bundle on Intel/macOS 15 and Apple silicon/macOS 26.
The network probes described in [Testing](TESTING.md) are opt-in and are not
part of routine CI.

## Change the code

Keep playback ownership outside navigation views. Queue identity belongs to
each occurrence of a track, so repeated songs remain separate queue entries.
Service requests and continuation tokens belong to the account scope that
created them. Reject stale responses after an account change or sign-out.

Use `feature/`, `fix/`, or `chore/` branches. Keep credentials and authenticated
responses out of source, fixtures, and logs. Preserve the license and source
revision when adapting third-party code.
