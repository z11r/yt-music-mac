#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "macOS: $(sw_vers -productVersion); process architecture: $(uname -m)"
"$script_dir/with-xcode.sh" xcodebuild -version
"$script_dir/with-xcode.sh" xcrun swift --version
"$script_dir/with-xcode.sh" xcrun --sdk macosx --show-sdk-version

if ! "$script_dir/with-xcode.sh" xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  echo "Note: Xcode reports pending first-launch tasks. Open Xcode before packaged-app/UI work."
fi
if command -v gh >/dev/null 2>&1; then
  gh --version | head -n 1
  if gh auth status >/dev/null 2>&1; then
    echo "GitHub CLI: authenticated."
  else
    echo "GitHub CLI: run gh auth login before pushing changes."
  fi
else
  echo "GitHub CLI: install with brew bundle."
fi
echo "Tool check complete."
