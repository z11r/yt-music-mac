#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
[[ $# -eq 4 ]] || { echo "Usage: Scripts/extract-app-intents.sh SCRATCH CONFIGURATION ARCH RESOURCES" >&2; exit 2; }
scratch="$1"
configuration="$2"
architecture="$3"
resources="$4"
[[ -d "$scratch" && -d "$resources" && ( "$configuration" == debug || "$configuration" == release ) &&
   ( "$architecture" == arm64 || "$architecture" == x86_64 ) ]] || { echo "Invalid metadata extraction arguments." >&2; exit 2; }
metadata_work="$(mktemp -d "$scratch/intent-metadata-$architecture.XXXXXX")"

# SwiftPM's build engine emits the compiler's constant values but does not run
# the app-bundle metadata step. Select only this executable target and architecture.
python3 - "$scratch" "$configuration" "$architecture" "$project_dir" "$metadata_work" <<'PY'
from pathlib import Path
import sys
scratch, configuration, architecture, project, output = map(Path, sys.argv[1:])
candidates = []
for path in scratch.rglob('MusicShortcuts.swiftconstvalues'):
    target = next((parent.name for parent in path.parents if parent.name.endswith('.build')), None)
    if target not in {'YTMusicMac-p.build', 'YTMusicMac.build'}:
        continue
    if 'Objects-normal' in path.parts:
        if architecture.name not in path.parts or configuration.name.capitalize() not in path.parts:
            continue
    elif configuration.name not in path.parts:
        continue
    candidates.append(path.parent)
if len(candidates) != 1:
    raise SystemExit('Expected one compiler constant-value directory for YTMusicMac. Use a full Xcode toolchain that emits App Intents metadata.')
objects = candidates[0]
required = ['PlaybackIntents.swiftconstvalues', 'NavigationIntents.swiftconstvalues', 'MusicShortcuts.swiftconstvalues']
if not all((objects / name).is_file() for name in required):
    raise SystemExit('The compiler did not emit all shortcut constant values.')
(output / 'constants.txt').write_text(''.join(str(path.resolve()) + '\n' for path in sorted(objects.glob('*.swiftconstvalues'))))
(output / 'sources.txt').write_text(''.join(str(path.resolve()) + '\n' for path in sorted((project / 'Sources/YTMusicMac').rglob('*.swift'))))
PY

sdk_root="$("$script_dir/with-xcode.sh" xcrun --sdk macosx --show-sdk-path)"
swift_compiler="$("$script_dir/with-xcode.sh" xcrun --find swiftc)"
toolchain_dir="$(cd "$(dirname "$swift_compiler")/../.." && pwd)"
xcode_version="$("$script_dir/with-xcode.sh" xcodebuild -version | awk '/Build version/ { print $3 }')"
"$script_dir/with-xcode.sh" xcrun appintentsmetadataprocessor \
  --output "$resources" --toolchain-dir "$toolchain_dir" --module-name YTMusicMac \
  --sdk-root "$sdk_root" --xcode-version "$xcode_version" --platform-family macOS \
  --deployment-target 14.0 --target-triple "$architecture-apple-macos14.0" \
  --source-file-list "$metadata_work/sources.txt" --swift-const-vals-list "$metadata_work/constants.txt"

python3 - "$resources/Metadata.appintents/extract.actionsdata" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    metadata = json.load(source)
expected = {'ResumeMusicIntent', 'PauseMusicIntent', 'NextSongIntent', 'PreviousSongIntent',
            'SetMusicVolumeIntent', 'PlaySongByIDIntent', 'OpenMusicLinkIntent', 'SearchMusicIntent'}
if set(metadata.get('actions', {})) != expected or len(metadata.get('autoShortcuts', [])) != 8:
    raise SystemExit('Packaged shortcut metadata does not describe all eight actions and phrases.')
PY
