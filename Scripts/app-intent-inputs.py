#!/usr/bin/env python3
"""Select one app target's compiler constants for metadata extraction."""
from pathlib import Path
import sys


def collect_inputs(scratch, configuration, architecture, project, output):
    if configuration not in {"debug", "release"} or architecture not in {"arm64", "x86_64"}:
        raise ValueError("Invalid metadata configuration or architecture.")
    candidates = set()
    for path in scratch.rglob("*.swiftconstvalues"):
        parts = path.relative_to(scratch).parts
        target = next((parent.name for parent in path.parents if parent.name.endswith(".build")), None)
        if target not in {"YTMusicMac-p.build", "YTMusicMac.build"}:
            continue
        if "Objects-normal" in parts:
            if architecture not in parts or configuration.capitalize() not in parts:
                continue
        elif configuration not in parts or not any(
            part == architecture or part.startswith(architecture + "-") for part in parts
        ):
            continue
        candidates.add(path.parent.resolve())
    if len(candidates) != 1:
        raise ValueError("Expected one compiler constant-value directory for the app target and architecture.")
    objects = candidates.pop()
    values = sorted(objects.glob("*.swiftconstvalues"))
    names = {path.name for path in values}
    per_file = {"PlaybackIntents.swiftconstvalues", "NavigationIntents.swiftconstvalues", "MusicShortcuts.swiftconstvalues"}
    aggregate = {"YTMusicMac-primary.swiftconstvalues", "YTMusicMac.swiftconstvalues"}
    if not per_file.issubset(names) and not aggregate.intersection(names):
        raise ValueError("The compiler did not emit all shortcut constants or an app module aggregate.")
    sources = sorted((project / "Sources/YTMusicMac").rglob("*.swift"))
    if not sources:
        raise ValueError("The app sources are missing.")
    output.mkdir(parents=True, exist_ok=True)
    (output / "constants.txt").write_text("".join(str(path.resolve()) + "\n" for path in values))
    (output / "sources.txt").write_text("".join(str(path.resolve()) + "\n" for path in sources))


if __name__ == "__main__":
    if len(sys.argv) != 6:
        raise SystemExit("Usage: app-intent-inputs.py SCRATCH CONFIGURATION ARCH PROJECT OUTPUT")
    try:
        collect_inputs(Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4]), Path(sys.argv[5]))
    except ValueError as error:
        raise SystemExit(str(error))
