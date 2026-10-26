#!/usr/bin/env python3
"""Bound the directly and file-locally transitively skippable Swift XCTest surface.

Counting rule: a test is skip-capable when its lexical body contains an
``XCTSkip`` API reference or calls, directly or transitively, a function in the
same Swift source file whose body does. The intentionally conservative lexical
call graph over-approximates overloads with the same name. One reviewed,
source-pinned cross-file installed-app guard is recognized explicitly; arbitrary
cross-file calls and dynamic dispatch remain a known gap because resolving those
requires Swift compiler semantic information unavailable in the hosted lane.

The allowlist is symmetric: both a newly skippable method and an entry whose
skip disappeared are drift. Every accepted entry carries a reviewed reason.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import NamedTuple


SCHEMA_VERSION = 2
COUNTING_RULE = "direct-and-file-local-transitive-swift-test-methods"
FUNCTION_PATTERN = re.compile(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>{}]*>)?\s*\(")
SKIP_PATTERN = re.compile(r"\bXCTSkip(?:If|Unless)?\s*\(")
CALL_PATTERN = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")
# Reviewed cross-file skip helpers, each fully qualified and narrow:
# - the installed-app target's destructive-automation opt-in
#   (test_installed_app_ui_harness.py independently pins its XCTSkip body);
# - CoreTests/Support/HostCompilerFixture.swift, which compiles a small host fixture with xcrun and
#   skips when the toolchain or the compile is unavailable (U7d).
REVIEWED_CROSS_FILE_SKIP_PATTERN = re.compile(
    r"\bInstalledAppUITestHarness\s*\.\s*requireOptedInCandidate\s*\("
    r"|\bHostCompilerFixture\s*\.\s*objc\s*\("
)


class SkipMethod(NamedTuple):
    file: str
    method: str

    def as_json(self) -> dict[str, str]:
        return {"file": self.file, "method": self.method}


def _lexical_code(text: str) -> str:
    """Replace Swift comments and string contents with spaces, preserving shape."""
    output = list(text)
    index = 0
    block_depth = 0
    state = "code"
    string_delimiter = ""

    def blank(position: int) -> None:
        if output[position] != "\n":
            output[position] = " "

    while index < len(text):
        if state == "code":
            if text.startswith("//", index):
                blank(index)
                blank(index + 1)
                index += 2
                state = "line-comment"
            elif text.startswith("/*", index):
                blank(index)
                blank(index + 1)
                index += 2
                block_depth = 1
                state = "block-comment"
            elif text.startswith('"""', index):
                for offset in range(3):
                    blank(index + offset)
                index += 3
                string_delimiter = '"""'
                state = "string"
            elif text[index] == '"':
                blank(index)
                index += 1
                string_delimiter = '"'
                state = "string"
            else:
                index += 1
        elif state == "line-comment":
            if text[index] == "\n":
                state = "code"
            else:
                blank(index)
            index += 1
        elif state == "block-comment":
            if text.startswith("/*", index):
                blank(index)
                blank(index + 1)
                block_depth += 1
                index += 2
            elif text.startswith("*/", index):
                blank(index)
                blank(index + 1)
                block_depth -= 1
                index += 2
                if block_depth == 0:
                    state = "code"
            else:
                blank(index)
                index += 1
        else:
            if string_delimiter == '"""' and text.startswith('"""', index):
                for offset in range(3):
                    blank(index + offset)
                index += 3
                state = "code"
            elif string_delimiter == '"' and text[index] == '"':
                blank(index)
                index += 1
                state = "code"
            elif text[index] == "\\" and string_delimiter == '"' and index + 1 < len(text):
                blank(index)
                blank(index + 1)
                index += 2
            else:
                blank(index)
                index += 1
    return "".join(output)


def _matching_brace(code: str, opening: int) -> int | None:
    depth = 0
    for index in range(opening, len(code)):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    return None


def scan_skip_methods(tests_root: Path) -> list[SkipMethod]:
    methods: list[SkipMethod] = []
    for path in sorted(tests_root.rglob("*.swift")):
        code = _lexical_code(path.read_text(encoding="utf-8"))
        functions: list[tuple[str, str]] = []
        for match in FUNCTION_PATTERN.finditer(code):
            opening = code.find("{", match.end())
            if opening < 0:
                continue
            closing = _matching_brace(code, opening)
            if closing is None:
                continue
            functions.append((match.group(1), code[opening + 1:closing]))

        bodies_by_name: dict[str, list[str]] = {}
        for name, body in functions:
            bodies_by_name.setdefault(name, []).append(body)

        # A helper name is safe to propagate only when every same-name
        # declaration in the file can skip. This avoids falsely attributing a
        # skip through an unrelated overload when lexical analysis cannot
        # resolve Swift overloads.
        skip_functions = {
            name
            for name, bodies in bodies_by_name.items()
            if all(
                SKIP_PATTERN.search(body)
                or REVIEWED_CROSS_FILE_SKIP_PATTERN.search(body)
                for body in bodies
            )
        }
        changed = True
        while changed:
            changed = False
            for name, bodies in bodies_by_name.items():
                if name in skip_functions:
                    continue
                every_overload_can_skip = all(
                    bool(set(CALL_PATTERN.findall(body)) & skip_functions)
                    for body in bodies
                )
                if every_overload_can_skip:
                    skip_functions.add(name)
                    changed = True

        relative = path.relative_to(tests_root).as_posix()
        for name, _ in functions:
            if name.startswith("test") and name in skip_functions:
                methods.append(SkipMethod(relative, name))
    return sorted(set(methods))


def load_allowlist(path: Path) -> tuple[list[SkipMethod], list[str]]:
    errors: list[str] = []
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return [], [f"allowlist file is missing: {path}"]
    except (OSError, json.JSONDecodeError) as error:
        return [], [f"allowlist cannot be read as JSON: {error}"]

    if not isinstance(value, dict):
        return [], ["allowlist root must be an object"]
    if value.get("schemaVersion") != SCHEMA_VERSION:
        errors.append(f"schemaVersion must equal {SCHEMA_VERSION}")
    if value.get("countingRule") != COUNTING_RULE:
        errors.append(f"countingRule must equal {COUNTING_RULE!r}")
    if not isinstance(value.get("knownGap"), str) or not value["knownGap"].strip():
        errors.append("knownGap must document the remaining semantic-call limitation")

    entries = value.get("entries")
    if not isinstance(entries, list):
        return [], errors + ["entries must be an array"]
    parsed: list[SkipMethod] = []
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            errors.append(f"entries[{index}] must be an object")
            continue
        file = entry.get("file")
        method = entry.get("method")
        reason = entry.get("reason")
        if not isinstance(file, str) or not file:
            errors.append(f"entries[{index}].file must be a non-empty string")
            continue
        if not isinstance(method, str) or not method.startswith("test"):
            errors.append(f"entries[{index}].method must name a test method")
            continue
        if not isinstance(reason, str) or len(reason.strip()) < 12:
            errors.append(f"entries[{index}].reason must give a specific reviewed reason")
        parsed.append(SkipMethod(file, method))
    if len(parsed) != len(set(parsed)):
        errors.append("entries must not contain duplicate file/method pairs")
    if parsed != sorted(parsed):
        errors.append("entries must be sorted by file then method")
    return parsed, errors


def report(tests_root: Path, allowlist_path: Path) -> tuple[dict[str, object], list[str]]:
    current = scan_skip_methods(tests_root)
    allowed, errors = load_allowlist(allowlist_path)
    current_set = set(current)
    allowed_set = set(allowed)
    added = sorted(current_set - allowed_set)
    removed = sorted(allowed_set - current_set)
    accepted = not errors and not added and not removed
    payload: dict[str, object] = {
        "accepted": accepted,
        "schemaVersion": SCHEMA_VERSION,
        "countingRule": COUNTING_RULE,
        "knownGap": (
            "Except for the reviewed installed-app opt-in guard, cross-file helper calls "
            "and dynamic dispatch are not resolved without Swift semantic information."
        ),
        "currentCount": len(current),
        "current": [item.as_json() for item in current],
        "added": [item.as_json() for item in added],
        "removed": [item.as_json() for item in removed],
        "errors": errors,
    }
    return payload, errors


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    repository_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests-root", type=Path, default=repository_root / "MacScope/Tests")
    parser.add_argument(
        "--allowlist",
        type=Path,
        default=repository_root / "docs/qualification/skip-allowlist.json",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    if not arguments.allowlist.exists():
        print("skip allowlist absent; check skipped")
        return 0
    payload, _ = report(arguments.tests_root.resolve(), arguments.allowlist.resolve())
    print(json.dumps(payload, indent=2, sort_keys=True))
    if not payload["accepted"]:
        for error in payload["errors"]:
            print(f"ERROR: {error}", file=sys.stderr)
        for item in payload["added"]:
            print(f"ERROR: unallowlisted skip-capable method: {item['file']}::{item['method']}", file=sys.stderr)
        for item in payload["removed"]:
            print(f"ERROR: stale skip allowlist entry: {item['file']}::{item['method']}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
