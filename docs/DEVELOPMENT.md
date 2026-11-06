# Development

The app target has not been added yet. For now, the repository contains setup
scripts and the plan for the first prototype.

## Tools

Install full Xcode and Homebrew, then run:

```sh
brew bundle
Scripts/doctor.sh
```

The Brewfile installs GitHub CLI, ShellCheck, and actionlint. The scripts use
`DEVELOPER_DIR` if set, otherwise the selected Xcode or `/Applications/Xcode.app`.
They do not change the system's Xcode selection.

To use a different Xcode installation:

```sh
DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer Scripts/doctor.sh
```

## Checks

```sh
shellcheck Scripts/*.sh
actionlint .github/workflows/checks.yml
```

GitHub Actions checks the scripts and workflow, then runs the tool check on
Intel and Apple silicon runners. App builds and tests will be added with the
first app target.

## Code changes

Use Swift and SwiftUI, with AppKit where needed for Mac behavior. Keep playback
ownership outside navigation views so browsing and window changes cannot
interrupt a session.

Use `feature/`, `fix/`, or `chore/` branches. Separate debug and release bundle
identifiers, storage, and update feeds. Preserve the license and source revision
when importing third-party code.
