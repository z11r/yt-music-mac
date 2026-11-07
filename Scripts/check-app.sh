#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  echo "Usage: Scripts/check-app.sh APP [--configuration debug|release] [--arch arm64|x86_64|--universal] [--smoke-test] [--ui-smoke-test]" >&2
}
[[ $# -gt 0 ]] || { usage; exit 2; }
[[ "$1" != --help && "$1" != -h ]] || { usage; exit 0; }
bundle="$1"
shift
configuration=""
architectures=()
smoke_test=false
ui_smoke_test=false
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
    --ui-smoke-test) ui_smoke_test=true; shift ;;
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
[[ "$(read_plist NSAppleScriptEnabled)" == true && "$(read_plist OSAScriptingDefinition)" == YTMusicMac.sdef &&
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

if [[ "$smoke_test" == true || "$ui_smoke_test" == true ]]; then
  check_dir="$(mktemp -d "${TMPDIR:-/tmp}/ytmusic-bundle-check.XXXXXX")"
  check_preferences_domain=""
  cleanup_check() {
    # Both names belong only to this invocation, including after a child crash.
    if [[ -n "$check_preferences_domain" ]]; then
      /usr/bin/defaults delete "$check_preferences_domain" >/dev/null 2>&1 || true
    fi
    rm -rf "$check_dir"
  }
  trap cleanup_check EXIT
  relocated="$check_dir/Relocated Music.app"
  /usr/bin/ditto "$bundle" "$relocated"
  if [[ "$smoke_test" == true ]]; then
    (
      cd "$check_dir"
      env -u PACKAGE_RESOURCE_BUNDLE_PATH -u PACKAGE_RESOURCE_BUNDLE_URL \
        "$relocated/Contents/MacOS/YTMusicMac" --check-bundle
    )
  fi
  if [[ "$ui_smoke_test" == true ]]; then
    check_id="$(/usr/bin/uuidgen)"
    check_preferences_domain="io.github.z11r.ytmusicmac.scenecheck.$check_id"
    python3 - "$relocated" "$check_id" "$check_dir" <<'PY'
import json
import os
import subprocess
import sys

bundle, check_id, check_dir = sys.argv[1:4]
report_path = os.path.join(check_dir, "ui-scenes.json")
errors_path = os.path.join(check_dir, "ui-scenes.err")
# Launch Services starts the app as Finder and the Dock do. On hosted CI runners, a
# directly executed binary finished launching without opening its main window.
command = ["/usr/bin/open", "-n", "-W", "-F", "--stdout", report_path, "--stderr", errors_path,
           bundle, "--args", "--check-ui-scenes", "--check-id", check_id]
try:
    subprocess.run(command, capture_output=True, text=True, timeout=25, check=False)
except subprocess.TimeoutExpired:
    subprocess.run(["/usr/bin/pkill", "-f", "check-id " + check_id], check=False)
    sys.exit("UI scene check exceeded 25 seconds.")


def read(path):
    try:
        with open(path, encoding="utf-8") as file:
            return file.read()
    except OSError:
        return ""


output = read(report_path)
try:
    report = json.loads(output)
except ValueError:
    sys.stderr.write(output[-4096:] + read(errors_path)[-4096:])
    sys.exit("UI scene check did not return a valid report.")
required = {"check": "ui-scenes", "passed": True, "reason": "completed", "renderedRevisions": 100}
if not isinstance(report, dict) or any(report.get(key) != value for key, value in required.items()):
    sys.stderr.write(output[-4096:] + read(errors_path)[-4096:])
    sys.exit("UI scene check did not confirm 100 rendered revisions.")
print(json.dumps(report, sort_keys=True))
PY
  fi
fi
printf 'Checked %s (%s; %s).\n' "$bundle" "$configuration" "${architectures[*]}"
