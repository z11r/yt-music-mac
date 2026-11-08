#!/usr/bin/env python3
"""Check optional framework load commands and undefined imports without running the app."""
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import sys
import tempfile


FRAMEWORKS = ("Translation", "_Translation_SwiftUI", "FoundationModels")
INSTALL_NAMES = {
    name: f"/System/Library/Frameworks/{name}.framework/Versions/A/{name}" for name in FRAMEWORKS
}
CPU_TYPES = {"arm64": 16777228, "x86_64": 16777223}
MAX_OUTPUT = 8 * 1024 * 1024


class ContractError(ValueError):
    """Contains fixed diagnostics only, never tool output or symbol/file names."""


@dataclass
class LoadMetadata:
    frameworks: dict
    undefined_count: int


def lines(output):
    if not output or len(output.encode("utf-8")) > MAX_OUTPUT or not output.endswith("\n"):
        raise ContractError("Optional framework metadata is empty, incomplete or oversized.")
    if any((ord(character) < 32 and character not in "\t\r\n") or ord(character) == 127 for character in output):
        raise ContractError("Optional framework metadata contains invalid text.")
    return [line.strip() for line in output.splitlines() if line.strip()]


def parse_loads(output, executable, architecture):
    rows = lines(output)
    headers = {f"{executable}:", f"{executable} (architecture {architecture}):"}
    if len(rows) < 7 or rows[0] not in headers or rows[1] != "Mach header" or rows[2].split() != [
        "magic", "cputype", "cpusubtype", "caps", "filetype", "ncmds", "sizeofcmds", "flags"
    ]:
        raise ContractError("Optional framework load header is malformed.")
    try:
        values = [int(value, 0) for value in rows[3].split()]
    except ValueError:
        raise ContractError("Optional framework load header is malformed.") from None
    if len(values) != 8 or values[0] != 0xFEEDFACF or values[1] != CPU_TYPES[architecture] or not 0 < values[5] <= 4096:
        raise ContractError("Optional framework load header is malformed.")
    blocks = []
    for row in rows[4:]:
        if row.startswith("Load command "):
            if row != f"Load command {len(blocks)}":
                raise ContractError("Optional framework load commands are incomplete.")
            blocks.append([])
        elif blocks:
            blocks[-1].append(row)
        else:
            raise ContractError("Optional framework load commands are malformed.")
    if len(blocks) != values[5]:
        raise ContractError("Optional framework load commands are incomplete.")
    frameworks, undefined_count, command_bytes = {}, None, 0
    for block in blocks:
        commands = [re.fullmatch(r"cmd (LC_[A-Z0-9_]+)", row) for row in block if row.startswith("cmd ")]
        sizes = [re.fullmatch(r"cmdsize ([0-9]+)", row) for row in block if row.startswith("cmdsize ")]
        if len(commands) != 1 or not commands[0] or len(sizes) != 1 or not sizes[0] or int(sizes[0][1]) <= 0:
            raise ContractError("Optional framework load commands are malformed.")
        command, size = commands[0][1], int(sizes[0][1])
        command_bytes += size
        if command == "LC_DYSYMTAB":
            counts = [re.fullmatch(r"nundefsym ([0-9]+)", row) for row in block if row.startswith("nundefsym ")]
            if undefined_count is not None or len(counts) != 1 or not counts[0]:
                raise ContractError("Optional framework import count is malformed.")
            undefined_count = int(counts[0][1])
        if command in {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB"}:
            names = [re.fullmatch(r"name (.+) \(offset [0-9]+\)", row) for row in block if row.startswith("name ")]
            if len(names) != 1 or not names[0] or not names[0][1].strip():
                raise ContractError("Optional framework load name is missing or malformed.")
            if not all(any(row.startswith(prefix) for row in block) for prefix in
                       ("time stamp ", "current version ", "compatibility version ")):
                raise ContractError("Optional framework load metadata is incomplete.")
            path = names[0][1]
            for name, install_name in INSTALL_NAMES.items():
                if path == install_name or f"/{name}.framework/" in path:
                    if path != install_name or command != "LC_LOAD_WEAK_DYLIB":
                        raise ContractError(f"Optional framework {name} has a nonweak or unsupported load.")
                    if name in frameworks:
                        raise ContractError(f"Optional framework {name} has duplicate loads.")
                    frameworks[name] = 0
    if command_bytes != values[6] or undefined_count is None or undefined_count <= 0:
        raise ContractError("Optional framework load/import metadata is incomplete.")
    return LoadMetadata(frameworks, undefined_count)


def validate_imports(output, metadata):
    rows = lines(output)
    if len(rows) != metadata.undefined_count:
        raise ContractError("Optional framework imports are incomplete.")
    counts = dict(metadata.frameworks)
    pattern = re.compile(r"\(undefined\) ((?:(?:weak|private) )*external) (\S+) \(from ([^()\s]+)\)")
    for row in rows:
        match = pattern.fullmatch(row)
        if not match:
            raise ContractError("Optional framework import metadata is malformed.")
        flags, _, provider = match.groups()
        if len(flags.split()) != len(set(flags.split())):
            raise ContractError("Optional framework import metadata is malformed.")
        if provider in FRAMEWORKS:
            if provider not in counts:
                raise ContractError(f"Optional framework {provider} import has no weak load.")
            if "weak" not in flags.split():
                raise ContractError(f"Optional framework {provider} has a strong import.")
            counts[provider] += 1
    return counts


def read_metadata(tool, arguments):
    wrapper = Path(__file__).resolve().parent / "with-xcode.sh"
    # Tool output can be large; keep it out of memory until its size is checked.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        try:
            result = subprocess.run([str(wrapper), "xcrun", tool, *arguments], stdout=output, stderr=errors, timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            raise ContractError("Optional framework metadata tool failed or timed out.") from None
        if result.returncode or errors.tell() or not 0 < output.tell() <= MAX_OUTPUT:
            raise ContractError("Optional framework metadata tool failed or returned invalid output.")
        output.seek(0)
        try:
            return output.read().decode("utf-8")
        except UnicodeDecodeError:
            raise ContractError("Optional framework metadata is not valid text.") from None


def check(executable, architecture, read=read_metadata):
    if architecture not in CPU_TYPES or not executable.is_file():
        raise ContractError("An existing executable and arm64 or x86_64 architecture are required.")
    executable = str(executable.resolve())
    loads = parse_loads(read("otool", ["-arch", architecture, "-h", "-l", executable]), executable, architecture)
    return validate_imports(read("nm", ["-arch", architecture, "-m", "-u", executable]), loads)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: check-optional-frameworks.py EXECUTABLE arm64|x86_64")
    try:
        counts = check(Path(sys.argv[1]), sys.argv[2])
    except ContractError as error:
        raise SystemExit(str(error))
    print(f"Checked optional frameworks ({sys.argv[2]}): " + ", ".join(
        f"{name}=" + (f"weak/{counts[name]} imports" if name in counts else "absent") for name in FRAMEWORKS))
