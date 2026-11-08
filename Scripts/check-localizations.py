#!/usr/bin/env python3
"""Check translated tables, optionally including compiler-extracted SwiftUI keys."""

import argparse
import json
from pathlib import Path
import re
import subprocess


def read_strings(path):
    result = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
        capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)


def signature(value):
    return sorted(re.findall(r"%(?:[0-9]+\$)?(?:lld|ld|d|u|@|f|g)", value))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stringsdata-root", type=Path,
                        help="Build directory produced with -Xswiftc -emit-localized-strings")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    errors = []
    counts = {}
    native_lookup = re.compile(r'(?:App|Core|Service)Localization\.(?:text|format)\("((?:[^"\\]|\\.)*)"')
    for module in ["YTMusicMac", "MusicCore", "YouTubeMusic"]:
        source = root / "Sources" / module
        english = read_strings(source / "Resources/en.lproj/Localizable.strings")
        french = read_strings(source / "Resources/fr.lproj/Localizable.strings")
        if english.keys() != french.keys():
            errors.append(f"{module}: English and French keys differ")
        for key in english.keys() & french.keys():
            if signature(english[key]) != signature(french[key]):
                errors.append(f"{module}: format arguments differ for {key!r}")
        for path in source.rglob("*.swift"):
            for match in native_lookup.finditer(path.read_text()):
                key = json.loads('"' + match[1] + '"')
                if key not in english:
                    errors.append(f"{module}: missing explicit key {key!r}")
        counts[module] = len(english)
        if args.stringsdata_root:
            # Swift build may emit both executable and testable module copies.
            # Their source field identifies the owning target without guessing
            # a particular build directory name or architecture.
            extracted = set()
            for path in args.stringsdata_root.rglob("*.stringsdata"):
                data = json.loads(path.read_text())
                source_path = Path(data.get("source", ""))
                if source not in source_path.parents:
                    continue
                for entry in data.get("tables", {}).get("Localizable", []):
                    if entry["key"]:
                        extracted.add(entry["key"])
            if module == "YTMusicMac" and not extracted:
                errors.append("No compiler-extracted app strings found; build with -emit-localized-strings first")
            for key in extracted - english.keys():
                errors.append(f"{module}: missing compiler-extracted key {key!r}")
    # Feature-specific tables use explicit lookup helpers rather than SwiftUI's
    # default Localizable table; keep their checks in the same CI entry point.
    for table, helper in [("QueueBuilder", "QueueBuilderCopy"), ("SponsorBlock", "SponsorBlockText"), ("Haptics", "HapticsText"),
                          ("LoginMedia", "LoginMediaText"), ("LocalAudio", "LocalAudioCopy"),
                          ("LocalAudioLibrary", "LocalAudioLibraryCopy"), ("StartupWindow", "StartupWindowText"),
                          ("EpisodeDetails", "EpisodeDetailsText"), ("RecordingCounterpart", "RecordingCounterpartText")]:
        source = root / "Sources/YTMusicMac"
        english = read_strings(source / f"Resources/en.lproj/{table}.strings")
        french = read_strings(source / f"Resources/fr.lproj/{table}.strings")
        if english.keys() != french.keys():
            errors.append(f"{table}: English and French keys differ")
        for key in english.keys() & french.keys():
            if signature(english[key]) != signature(french[key]):
                errors.append(f"{table}: format arguments differ for {key!r}")
        lookup = re.compile(rf'{helper}\.(?:text|format)\("((?:[^"\\]|\\.)*)"')
        for path in source.rglob("*.swift"):
            for match in lookup.finditer(path.read_text()):
                key = json.loads('"' + match[1] + '"')
                if key not in english:
                    errors.append(f"{table}: missing explicit key {key!r}")
        counts[table] = len(english)
    for language in ["en", "fr"]:
        phrases = read_strings(root / f"Sources/YTMusicMac/Resources/{language}.lproj/AppShortcuts.strings")
        if len(phrases) != 8 or any(key.count("${applicationName}") != 1 or
                                   value.count("${applicationName}") != 1 for key, value in phrases.items()):
            errors.append(f"{language}: shortcut phrases must preserve the applicationName token")
    if errors:
        raise SystemExit("\n".join(sorted(set(errors))))
    print("Checked English/French localization keys: " + ", ".join(f"{m}={n}" for m, n in counts.items()))


if __name__ == "__main__":
    main()
