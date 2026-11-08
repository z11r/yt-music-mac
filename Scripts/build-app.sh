#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
configuration=debug
universal=false

usage() {
  echo "Usage: Scripts/build-app.sh [--configuration debug|release] [--universal]" >&2
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      configuration="$2"
      shift 2
      ;;
    --universal) universal=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[[ "$configuration" == debug || "$configuration" == release ]] || { usage; exit 2; }

host_arch="$(uname -m)"
[[ "$host_arch" == arm64 || "$host_arch" == x86_64 ]] || { echo "A Mac with Intel or Apple silicon is required." >&2; exit 1; }
architectures=("$host_arch")
variant="$host_arch"
if [[ "$universal" == true ]]; then
  architectures=(arm64 x86_64)
  variant=universal
fi

# Keep each build, architecture, and output isolated. Existing app bundles are never replaced.
mkdir -p "$project_dir/.build/app-bundles"
build_dir="$(mktemp -d "$project_dir/.build/app-bundles/$configuration-$variant.XXXXXX")"
app_name="YT Music for Mac"
bundle_identifier="io.github.z11r.ytmusicmac"
music_link_scheme="ytmusicmac"
if [[ "$configuration" == debug ]]; then
  app_name="$app_name Debug"
  bundle_identifier="$bundle_identifier.debug"
  music_link_scheme="ytmusicmac-debug"
fi
bundle="$build_dir/$app_name.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Frameworks"

executables=()
resource_source=""
for architecture in "${architectures[@]}"; do
  scratch="$build_dir/work-$architecture"
  build_args=(--package-path "$project_dir" --scratch-path "$scratch" --configuration "$configuration"
              --arch "$architecture" --product YTMusicMac --jobs 1 --disable-keychain --disable-netrc)
  MACOSX_DEPLOYMENT_TARGET=14.0 "$script_dir/with-xcode.sh" xcrun swift build "${build_args[@]}" >&2
  bin_path="$(MACOSX_DEPLOYMENT_TARGET=14.0 "$script_dir/with-xcode.sh" xcrun swift build "${build_args[@]}" --show-bin-path)"
  [[ -x "$bin_path/YTMusicMac" ]] || { echo "Build did not produce YTMusicMac for $architecture." >&2; exit 1; }
  # Metadata is independent of machine architecture; extracting each thin build
  # also verifies that both slices expose the same installed app actions.
  "$script_dir/extract-app-intents.sh" "$scratch" "$configuration" "$architecture" "$bundle/Contents/Resources" >&2
  "$script_dir/with-xcode.sh" xcrun lipo "$bin_path/YTMusicMac" -verify_arch "$architecture"
  # Rewrite only the packaging copy; retain SwiftPM's original build product.
  thin_executable="$build_dir/YTMusicMac-$architecture"
  cp "$bin_path/YTMusicMac" "$thin_executable"
  frameworks_rpath_present=false
  while IFS= read -r runtime_path; do
    case "$runtime_path" in
      '@executable_path/../Frameworks') frameworks_rpath_present=true ;;
      /System/Library/*|/usr/lib/*|@loader_path|@loader_path/*|@executable_path|@executable_path/*) ;;
      *) "$script_dir/with-xcode.sh" xcrun install_name_tool -delete_rpath "$runtime_path" "$thin_executable" >&2 ;;
    esac
  done < <("$script_dir/with-xcode.sh" xcrun otool -l "$thin_executable" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { wanted = 1; next }
    wanted && $1 == "path" {
      sub(/^[[:space:]]*path[[:space:]]+/, ""); sub(/[[:space:]]+\(offset.*$/, ""); print; wanted = 0
    }
  ')
  if [[ "$frameworks_rpath_present" == false ]]; then
    "$script_dir/with-xcode.sh" xcrun install_name_tool -add_rpath '@executable_path/../Frameworks' "$thin_executable" >&2
  fi
  executables+=("$thin_executable")
  if [[ -z "$resource_source" ]]; then
    resource_source="$bin_path/YTMusicMac_YTMusicMac.bundle"
  fi
done

if [[ "$universal" == true ]]; then
  "$script_dir/with-xcode.sh" xcrun lipo -create "${executables[@]}" -output "$bundle/Contents/MacOS/YTMusicMac"
else
  cp "${executables[0]}" "$bundle/Contents/MacOS/YTMusicMac"
fi
chmod 755 "$bundle/Contents/MacOS/YTMusicMac"
[[ -d "$resource_source" ]] || { echo "The Swift package resource bundle is missing." >&2; exit 1; }
/usr/bin/ditto "$resource_source" "$bundle/Contents/Resources/YTMusicMac_YTMusicMac.bundle"
cp "$project_dir/Sources/YTMusicMac/Resources/YTMusicMac.sdef" "$bundle/Contents/Resources/YTMusicMac.sdef"
cp "$project_dir/LICENSE" "$bundle/Contents/Resources/LICENSE"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>$app_name</string>
  <key>CFBundleName</key><string>$app_name</string>
  <key>CFBundleExecutable</key><string>YTMusicMac</string>
  <key>CFBundleIdentifier</key><string>$bundle_identifier</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleScriptEnabled</key><true/>
  <key>OSAScriptingDefinition</key><string>YTMusicMac.sdef</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>$bundle_identifier.music-links</string>
    <key>CFBundleURLSchemes</key><array><string>$music_link_scheme</string></array>
  </dict></array>
  <key>YTMusicBuildConfiguration</key><string>$configuration</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$bundle/Contents/Info.plist" >&2

# Apple supplies any required Swift compatibility libraries with Xcode.
"$script_dir/with-xcode.sh" xcrun swift-stdlib-tool --copy --platform macosx \
  --scan-executable "$bundle/Contents/MacOS/YTMusicMac" \
  --destination "$bundle/Contents/Frameworks" >&2
while IFS= read -r -d '' library; do
  /usr/bin/codesign --force --sign - --timestamp=none "$library" >&2
done < <(find "$bundle/Contents/Frameworks" -type f -name '*.dylib' -print0)
/usr/bin/codesign --force --sign - --timestamp=none --options runtime "$bundle" >&2

check_args=("$bundle" --configuration "$configuration")
if [[ "$universal" == true ]]; then check_args+=(--universal); else check_args+=(--arch "$host_arch"); fi
"$script_dir/check-app.sh" "${check_args[@]}" >&2
# Keep stdout suitable for app_path="$(Scripts/build-app.sh ...)".
printf '%s\n' "$bundle"
