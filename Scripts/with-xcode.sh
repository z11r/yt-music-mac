#!/bin/bash
set -euo pipefail

# Respect an explicit selection; otherwise prefer active full Xcode, then the
# standard installation. This does not change the machine's xcode-select state.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  active_developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ -x "$active_developer_dir/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="$active_developer_dir"
  elif [[ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    echo "Full Xcode is required. Set DEVELOPER_DIR to its Contents/Developer directory." >&2
    exit 1
  fi
fi

if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "DEVELOPER_DIR does not identify a full Xcode installation." >&2
  exit 1
fi
if [[ $# -eq 0 ]]; then
  echo "Usage: Scripts/with-xcode.sh <command> [arguments...]" >&2
  exit 2
fi
exec "$@"
