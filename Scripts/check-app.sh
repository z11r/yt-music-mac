#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  echo "Usage: Scripts/check-app.sh APP [--configuration debug|release] [--arch arm64|x86_64|--universal] [--smoke-test]" >&2
}
[[ $# -gt 0 ]] || { usage; exit 2; }
[[ "$1" != --help && "$1" != -h ]] || { usage; exit 0; }
bundle="$1"
shift
configuration=""
architectures=()
smoke_test=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      configuration="$2"; shift 2 ;;
    --arch)
      [[ $# -ge 2 && ( "$2" == arm64 || "$2" == x86_64 ) ]] || { usage; exit 2; }
      architectures+=("$2"); shift 2 ;;
    --universal) architectures=(arm64 x86_64); shift ;;
    --smoke-test) smoke_test=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -d "$bundle" && "$bundle" == *.app ]] || { echo "An existing .app bundle is required." >&2; exit 1; }
bundle="$(cd "$bundle" && pwd)"
plist="$bundle/Contents/Info.plist"
executable="$bundle/Contents/MacOS/YTMusicMac"
resources="$bundle/Contents/Resources/YTMusicMac_YTMusicMac.bundle"
/usr/bin/plutil -lint "$plist"
[[ -x "$executable" && -d "$resources" ]] || { echo "Executable or package resources are missing." >&2; exit 1; }
[[ -s "$bundle/Contents/Resources/LICENSE" && -s "$bundle/Contents/Resources/THIRD_PARTY_NOTICES.md" ]] || {
  echo "The app license or third-party notices are missing." >&2; exit 1;
}
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
actual_configuration="$(read_plist YTMusicBuildConfiguration)"
[[ -n "$configuration" ]] || configuration="$actual_configuration"
[[ "$configuration" == debug || "$configuration" == release ]] || { usage; exit 2; }
[[ "$actual_configuration" == "$configuration" ]] || { echo "Build configuration does not match." >&2; exit 1; }
identifier="io.github.z11r.ytmusicmac"
[[ "$configuration" != debug ]] || identifier="$identifier.debug"
[[ "$(read_plist CFBundleIdentifier)" == "$identifier" ]] || { echo "Bundle identifier does not match the build configuration." >&2; exit 1; }
[[ "$(read_plist CFBundleExecutable)" == YTMusicMac ]] || { echo "Bundle executable does not match." >&2; exit 1; }
[[ "$(read_plist CFBundlePackageType)" == APPL ]] || { echo "Bundle type is not APPL." >&2; exit 1; }
[[ "$(read_plist LSMinimumSystemVersion)" == 14.0 ]] || { echo "Bundle minimum must be macOS 14.0." >&2; exit 1; }
[[ "$(read_plist NSAppleScriptEnabled)" == true && "$(read_plist NSScriptingDefinition)" == YTMusicMac.sdef &&
   -s "$bundle/Contents/Resources/YTMusicMac.sdef" ]] || {
  echo "The native scripting definition is missing." >&2; exit 1;
}
[[ -f "$resources/PlayerBridge.js" || -f "$resources/Contents/Resources/PlayerBridge.js" ]] || {
  echo "The packaged playback bridge is missing." >&2; exit 1;
}

if [[ ${#architectures[@]} -eq 0 ]]; then
  read -r -a architectures <<< "$("$script_dir/with-xcode.sh" xcrun lipo -archs "$executable")"
fi
for architecture in "${architectures[@]}"; do
  "$script_dir/with-xcode.sh" xcrun lipo "$executable" -verify_arch "$architecture"
  minimum="$("$script_dir/with-xcode.sh" xcrun vtool -arch "$architecture" -show-build "$executable" | awk '$1 == "minos" { print $2 }')"
  [[ "$minimum" == 14.0 || "$minimum" == 14.0.0 ]] || {
    echo "The $architecture executable minimum is $minimum; expected macOS 14.0." >&2; exit 1;
  }
done
while IFS= read -r -d '' library; do
  for architecture in "${architectures[@]}"; do
    "$script_dir/with-xcode.sh" xcrun lipo "$library" -verify_arch "$architecture"
  done
done < <(find "$bundle/Contents/Frameworks" -type f -name '*.dylib' -print0)

while IFS= read -r dependency; do
  case "$dependency" in
    /System/Library/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
    *) echo "Unexpected library dependency: $dependency" >&2; exit 1 ;;
  esac
done < <("$script_dir/with-xcode.sh" xcrun otool -L "$executable" | awk '/^\t/ { print $1 }')
while IFS= read -r runtime_path; do
  case "$runtime_path" in
    /System/Library/*|/usr/lib/*|@loader_path|@loader_path/*|@executable_path|@executable_path/*) ;;
    *) echo "Unexpected runtime search path: $runtime_path" >&2; exit 1 ;;
  esac
done < <("$script_dir/with-xcode.sh" xcrun otool -l "$executable" | awk '
  $1 == "cmd" && $2 == "LC_RPATH" { wanted = 1; next }
  wanted && $1 == "path" {
    sub(/^[[:space:]]*path[[:space:]]+/, ""); sub(/[[:space:]]+\(offset.*$/, ""); print; wanted = 0
  }
')
/usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle"

if [[ "$smoke_test" == true ]]; then
  check_dir="$(mktemp -d "${TMPDIR:-/tmp}/ytmusic-bundle-check.XXXXXX")"
  # Only this freshly-created temporary directory is removed.
  trap 'rm -rf "$check_dir"' EXIT
  relocated="$check_dir/Relocated Music.app"
  /usr/bin/ditto "$bundle" "$relocated"
  (
    cd "$check_dir"
    env -u PACKAGE_RESOURCE_BUNDLE_PATH -u PACKAGE_RESOURCE_BUNDLE_URL \
      "$relocated/Contents/MacOS/YTMusicMac" --check-bundle
  )
fi
printf 'Checked %s (%s; %s).\n' "$bundle" "$configuration" "${architectures[*]}"
