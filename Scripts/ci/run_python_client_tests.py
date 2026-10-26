#!/usr/bin/env python3
"""Run the portable MacScope Python client tests (MacScope/python/tests).

Standard library only: no pytest, no MacScope build, no network. Every
``test_*.py`` module is included by default; modules that need a real MacScope
executable are listed explicitly below with the concrete native boundary. As in
run_hosted_governance.py, this is a denylist on purpose, so a new client test is
covered unless a contributor classifies it deliberately.

The lane fails on any failure, error, skip or empty selection: every selected
module is expected to run completely on a POSIX host.

Before the tests, the lane compiles the other Python that runs under Apple's
Python 3.9 interpreters (MS-21): every script MacScope/project.yml build phases
invoke through /usr/bin/python3, and the Python program text embedded in the
LLDB extractor Swift sources. Governance CI runs this lane under 3.9 and 3.12,
so a 3.10+ construct fails the 3.9 leg instead of a build phase or LLDB.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path
from typing import Iterable, List, Mapping, NamedTuple, Optional, Tuple

ROOT = Path(__file__).resolve().parents[2]
CLIENT_ROOT = ROOT / "MacScope" / "python"
TESTS = CLIENT_ROOT / "tests"

PROJECT_SPEC = ROOT / "MacScope" / "project.yml"
LLDB_EXTRACTOR_SOURCES = (
    ROOT / "MacScope" / "Services" / "Debugger" / "LLDBVariableExtractorProgram.swift",
    ROOT / "MacScope" / "Services" / "Debugger" / "LLDBRuntimeModuleExtractorProgram.swift",
)
BUILD_PHASE_SCRIPT = re.compile(r"\$\(?SRCROOT\)?/\.\./(?P<path>[A-Za-z0-9_./-]+\.py)\b")
EXTRACTOR_SOURCE = re.compile(
    r'static let extractorSource = #"""\n(?P<body>.*?)\n"""#', re.DOTALL
)

NATIVE_ONLY_REASONS = {
    "test_macscope.py": "drives a built MacScope --mcp executable end to end and imports pytest",
}


class ClientTestDiscoveryError(ValueError):
    """The client test closure is inconsistent with the native-only denylist."""


class ClientTestDiscovery(NamedTuple):
    discovered_modules: Tuple[str, ...]
    native_only_modules: Tuple[Tuple[str, str], ...]
    selected_modules: Tuple[str, ...]


def classify_modules(
    discovered_modules: Iterable[str],
    native_only_reasons: Mapping[str, str] = NATIVE_ONLY_REASONS,
) -> ClientTestDiscovery:
    discovered = tuple(sorted(set(discovered_modules)))
    missing = sorted(set(native_only_reasons) - set(discovered))
    if missing:
        raise ClientTestDiscoveryError(f"denylist names tests that no longer exist: {missing}")
    native_only = tuple((name, native_only_reasons[name]) for name in sorted(native_only_reasons))
    selected = tuple(name for name in discovered if name not in native_only_reasons)
    if not selected:
        raise ClientTestDiscoveryError("portable client test selection is empty")
    return ClientTestDiscovery(discovered, native_only, selected)


def discover_modules(tests_directory: Path = TESTS) -> ClientTestDiscovery:
    return classify_modules(path.name for path in tests_directory.glob("test_*.py"))


def build_suite(selected_modules: Iterable[str], tests_directory: Path = TESTS) -> unittest.TestSuite:
    for entry in (str(tests_directory), str(tests_directory.parent)):
        if entry not in sys.path:
            sys.path.insert(0, entry)
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    for name in selected_modules:
        suite.addTests(loader.loadTestsFromName(name[: -len(".py")]))
    return suite


class FloorCompileError(ValueError):
    """The Python 3.9 floor sources could not be located."""


def build_phase_scripts(project_spec: Path = PROJECT_SPEC) -> Tuple[Path, ...]:
    text = project_spec.read_text(encoding="utf-8")
    paths = sorted({match.group("path") for match in BUILD_PHASE_SCRIPT.finditer(text)})
    if not paths:
        raise FloorCompileError(f"no build-phase Python scripts found in {project_spec}")
    scripts = tuple(ROOT / path for path in paths)
    missing = [str(path.relative_to(ROOT)) for path in scripts if not path.is_file()]
    if missing:
        raise FloorCompileError(f"build-phase scripts named in project.yml are missing: {missing}")
    return scripts


def extractor_program(swift_source: Path) -> str:
    # The program is a Swift raw string whose closing delimiter is in column 0, so
    # its text is verbatim: no escapes, interpolation, or indentation stripping.
    match = EXTRACTOR_SOURCE.search(swift_source.read_text(encoding="utf-8"))
    if match is None:
        raise FloorCompileError(f"no extractorSource raw string in {swift_source}")
    return match.group("body") + "\n"


def floor_compile_units(
    project_spec: Path = PROJECT_SPEC,
    extractor_sources: Iterable[Path] = LLDB_EXTRACTOR_SOURCES,
) -> Tuple[Tuple[str, str], ...]:
    units = [
        (str(path.relative_to(ROOT)), path.read_text(encoding="utf-8"))
        for path in build_phase_scripts(project_spec)
    ]
    for swift_source in extractor_sources:
        units.append((f"{swift_source.relative_to(ROOT)}:extractorSource", extractor_program(swift_source)))
    return tuple(units)


def compile_floor_sources(units: Iterable[Tuple[str, str]]) -> List[str]:
    """Compile each unit with the running interpreter; return one message per failure."""
    failures = []
    for name, text in units:
        try:
            compile(text, name, "exec", dont_inherit=True)
        except SyntaxError as error:
            failures.append(f"{name}:{error.lineno}: {error.msg}")
    return failures


def main(argv: Optional[List[str]] = None) -> int:
    try:
        discovery = discover_modules()
        units = floor_compile_units()
    except (ClientTestDiscoveryError, FloorCompileError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    failures = compile_floor_sources(units)
    print(
        f"Python floor compile (Python {sys.version.split()[0]}): "
        f"{len(units)} build-phase scripts and LLDB extractor programs, {len(failures)} failures"
    )
    for name, _ in units:
        print(f"  compiled {name}")
    if failures:
        for failure in failures:
            print(f"ERROR: does not compile: {failure}", file=sys.stderr)
        return 1
    print(
        "portable Python client lane: "
        f"{len(discovery.selected_modules)} of {len(discovery.discovered_modules)} test modules "
        f"(Python {sys.version.split()[0]})"
    )
    for name, reason in discovery.native_only_modules:
        print(f"  excluded native-only {name}: {reason}")
    suite = build_suite(discovery.selected_modules)
    if suite.countTestCases() == 0:
        print("ERROR: portable client selection contains no test cases", file=sys.stderr)
        return 2
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print(
        f"portable Python client lane: ran={result.testsRun} failures={len(result.failures)} "
        f"errors={len(result.errors)} skipped={len(result.skipped)}"
    )
    if result.skipped:
        print("ERROR: portable client tests must not skip on a POSIX host", file=sys.stderr)
        return 1
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
