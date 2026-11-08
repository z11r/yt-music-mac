"""Run with python3 -B -m unittest discover -s Scripts/tests."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("optional_frameworks", Path(__file__).parents[1] / "check-optional-frameworks.py")
checker = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = checker
spec.loader.exec_module(checker)

BINARY = "/fixture/Example App"


def load(name, command="LC_LOAD_WEAK_DYLIB"):
    path = checker.INSTALL_NAMES.get(name, f"/System/Library/Frameworks/{name}.framework/Versions/A/{name}")
    return [f"cmd {command}", "cmdsize 112", f"name {path} (offset 24)",
            "time stamp 2 Wed Dec 31 17:00:02 1969", "current version 1.0.0", "compatibility version 1.0.0"]


def output(blocks, count, architecture="arm64", binary=BINARY):
    all_blocks = [["cmd LC_DYSYMTAB", "cmdsize 80", f"nundefsym {count}"], *blocks]
    result = [f"{binary}:", "Mach header", "magic cputype cpusubtype caps filetype ncmds sizeofcmds flags",
              f"0xfeedfacf {checker.CPU_TYPES[architecture]} 0 0x00 2 {len(all_blocks)} {80 + 112 * len(blocks)} 0x00200085"]
    for index, block in enumerate(all_blocks):
        result.extend([f"Load command {index}", *block])
    return "\n".join(result) + "\n"


def symbol(provider, weak=True):
    return f" (undefined) {'weak ' if weak else ''}external _symbol_weak_in_name (from {provider})\n"


class OptionalFrameworkChecks(unittest.TestCase):
    def test_all_optional_frameworks_are_weak_on_both_architectures(self):
        for architecture in checker.CPU_TYPES:
            metadata = checker.parse_loads(output([load(name) for name in checker.FRAMEWORKS], 3, architecture), BINARY, architecture)
            self.assertEqual(checker.validate_imports("".join(symbol(name) for name in checker.FRAMEWORKS), metadata),
                             dict.fromkeys(checker.FRAMEWORKS, 1))

    def test_absent_optional_frameworks_do_not_reject_normal_strong_imports(self):
        metadata = checker.parse_loads(output([load("SwiftUI", "LC_LOAD_DYLIB")], 1), BINARY, "arm64")
        self.assertEqual(checker.validate_imports(symbol("SwiftUI", weak=False), metadata), {})

    def test_every_optional_strong_reexport_and_upward_load_is_rejected(self):
        for name in checker.FRAMEWORKS:
            for command in ["LC_LOAD_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB"]:
                with self.subTest(framework=name, command=command), self.assertRaises(checker.ContractError):
                    checker.parse_loads(output([load(name, command)], 1), BINARY, "arm64")

    def test_weak_spelling_in_a_symbol_does_not_make_a_strong_import_weak(self):
        for name in checker.FRAMEWORKS:
            metadata = checker.parse_loads(output([load(name)], 1), BINARY, "arm64")
            with self.assertRaisesRegex(checker.ContractError, "strong import"):
                checker.validate_imports(symbol(name, weak=False), metadata)

    def test_optional_import_without_a_matching_weak_load_is_rejected(self):
        metadata = checker.parse_loads(output([load("SwiftUI", "LC_LOAD_DYLIB")], 1), BINARY, "arm64")
        with self.assertRaises(checker.ContractError):
            checker.validate_imports(symbol("Translation"), metadata)

    def test_empty_garbage_wrong_file_and_wrong_architecture_headers_fail(self):
        valid = output([load("Translation")], 1)
        for value in ["", "garbage\n", valid.replace(BINARY, "/different/file"), valid.replace("16777228", "16777223"), valid.replace("Mach header", "unknown header")]:
            with self.subTest(value=value[:20]), self.assertRaises(checker.ContractError):
                checker.parse_loads(value, BINARY, "arm64")

    def test_complete_prefix_of_load_commands_cannot_hide_a_truncated_optional_load(self):
        valid = output([load("SwiftUI", "LC_LOAD_DYLIB"), load("Translation")], 1)
        prefix = valid[:valid.index("Load command 2")]
        with self.assertRaises(checker.ContractError):
            checker.parse_loads(prefix, BINARY, "arm64")

    def test_missing_name_terminator_fields_and_import_count_fail(self):
        valid = output([load("Translation")], 1)
        for value in [valid.replace("name ", "missing "), valid.replace("compatibility version 1.0.0\n", ""),
                      valid.replace("nundefsym 1", "missing 1"), valid.replace("cmdsize 112", "cmdsize 104"),
                      valid.rstrip("\n"), valid.replace("current version", "\x00current version")]:
            with self.subTest(value=value[-30:]), self.assertRaises(checker.ContractError):
                checker.parse_loads(value, BINARY, "arm64")

    def test_unknown_install_location_and_duplicate_optional_loads_fail(self):
        valid = output([load("Translation")], 1)
        for value in [valid.replace("/System/Library/Frameworks/", "@rpath/"), output([load("Translation"), load("Translation")], 1)]:
            with self.assertRaises(checker.ContractError):
                checker.parse_loads(value, BINARY, "arm64")

    def test_empty_truncated_or_unrecognized_import_output_is_not_absence(self):
        metadata = checker.parse_loads(output([load("Translation")], 2), BINARY, "arm64")
        for value in ["", symbol("SwiftUI"), "unrecognized\n" + symbol("Translation"), symbol("Translation") + "(undefined) weak external missing_provider\n"]:
            with self.subTest(value=value[:20]), self.assertRaises(checker.ContractError):
                checker.validate_imports(value, metadata)

    def test_tool_failure_never_includes_raw_output_in_the_diagnostic(self):
        def failed(*args, **kwargs):
            kwargs["stdout"].write(b"private raw output")
            kwargs["stderr"].write(b"private error with path")
            return subprocess.CompletedProcess([], 1)
        with patch.object(checker.subprocess, "run", failed), self.assertRaises(checker.ContractError) as error:
            checker.read_metadata("nm", [])
        self.assertNotIn("private", str(error.exception))

    def test_nonzero_timeout_warning_invalid_text_and_empty_tools_fail(self):
        for content, warning, status in [(b"", b"", 0), (b"x\n", b"warning", 0), (b"\xff", b"", 0), (b"x\n", b"", 1)]:
            def fake(*args, **kwargs):
                kwargs["stdout"].write(content); kwargs["stderr"].write(warning)
                return subprocess.CompletedProcess([], status)
            with patch.object(checker.subprocess, "run", fake), self.assertRaises(checker.ContractError):
                checker.read_metadata("nm", [])
        with patch.object(checker.subprocess, "run", side_effect=subprocess.TimeoutExpired("nm", 20)), self.assertRaises(checker.ContractError):
            checker.read_metadata("nm", [])

    def test_metadata_admission_uses_the_requested_architecture_without_executing_the_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "not an executable"
            binary.write_text("synthetic metadata fixture")
            calls = []
            def fake(tool, arguments):
                calls.append((tool, arguments))
                if tool == "otool": return output([load("Translation")], 1, "x86_64", arguments[-1])
                return symbol("Translation")
            self.assertEqual(checker.check(binary, "x86_64", read=fake), {"Translation": 1})
            self.assertEqual([call[0] for call in calls], ["otool", "nm"])
            self.assertTrue(all(call[1][:2] == ["-arch", "x86_64"] for call in calls))
            with self.assertRaises(checker.ContractError):
                checker.check(binary, "unsupported", read=fake)
            self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
