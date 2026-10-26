#!/usr/bin/env python3
"""Prove that MacScope's ordinary build and test surfaces are offline consumers.

The validator deliberately avoids third-party parsers. It treats network-backed
materializers as an explicit, manifest-governed exception and rejects download
commands, floating package declarations, or materializer calls from normal
bootstrap/build/test entry points.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import re
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

sys.path.insert(0, str(Path(__file__).resolve().parent))
from first_party_components import ACQUISITION_SCRIPTS, LUMEN_MATERIALIZER, FirstPartyValidationError, declared_components

MAX_FILE_BYTES = 4 * 1024 * 1024
MAX_SCANNED_FILES = 20_000
NORMAL_ENTRYPOINTS = (
    "Scripts/bootstrap.sh",
    "Scripts/test.sh",
    "MacScope/project.yml",
)
# These are explicit acquisition commands retained for operator/CI compatibility.
# They may delegate to a manifest-owned network materializer, but ordinary build
# entry points and unrelated helper scripts must not invoke them.
EXPLICIT_MATERIALIZATION_SHIMS = (
    "Scripts/provision_ghostty_vt_ci.sh",
)
EXPLICIT_QUALIFICATION_ENTRYPOINTS = (
    "Scripts/qualify_local_private_build.sh",
)
# Executable operator qualification delegates are distinct from ordinary build
# helpers and reference-only metadata. Permit only their reviewed offline target;
# keep their own bytes under the network/package scans and surface commitment.
EXPLICIT_OFFLINE_QUALIFICATION_DELEGATES = {
    "Scripts/reconstruction_gate_f/bootstrap_cli.py": {
        "Scripts/reconstruction_gate_f/bootstrap_qualification.py",
    },
    "Scripts/reconstruction_gate_f/bootstrap_qualification.py": {
        "Scripts/qualify_local_private_build.sh",
    },
}
# These consumers replay retained qualification evidence; they do not launch a
# qualifier. Their bootstrap import alone is not dependency acquisition.
QUALIFICATION_REVALIDATION_CONSUMERS = {
    "Scripts/reconstruction_gate_f/bootstrap_verifier.py",
    "Scripts/reconstruction_gate_f/bootstrap_verifier_adapter.py",
    "Scripts/reconstruction_gate_f/bootstrap_reader_compatibility.py",
}
QUALIFICATION_REQUIRED_MATERIALIZERS: set[str] = set()
# Build-station tooling (D12; iteration only, never evidence). `station.sh sync`
# (run by claim and by dev_loop.sh before each build) re-aligns a stale
# ThirdParty/Lumen checkout through the offline first-party materializer, from
# the local seed only. Each delegate may reach only its listed target, and
# station.sh is itself an acquisition token, so no other ordinary build helper
# (and no normal or qualification entrypoint) may call it.
STATION_SYNC_ENTRYPOINT = "Scripts/station.sh"
DEVELOPER_STATION_DELEGATES = {
    STATION_SYNC_ENTRYPOINT: {LUMEN_MATERIALIZER},
    "Scripts/dev_loop.sh": {STATION_SYNC_ENTRYPOINT},
}
REFERENCE_ONLY_ACQUISITION_PATHS = {
    # Closed first-party policy metadata, not an acquisition caller.
    "Scripts/dependencies/first_party_components.py",
    # This validator names the explicit qualifier to prove its signing branch;
    # it never executes dependency acquisition.
    "Scripts/check_local_signing_policy.py",
    # Gate F freezes the exact operator command as candidate-bound metadata.
    # The catalog declares argv only; command execution remains an explicit,
    # receipt-producing qualification action and cannot run during bootstrap.
    "Scripts/reconstruction_gate_f/command_catalog.py",
}
BUILD_FILE_NAMES = {
    "CMakeLists.txt",
    "Package.swift",
    "Package.resolved",
    "project.yml",
    "project.yaml",
    "Makefile",
}
BUILD_FILE_SUFFIXES = {
    ".sh",
    ".bash",
    ".zsh",
    ".py",
    ".cmake",
    ".mk",
}
SKIPPED_PREFIXES = (
    ".git/",
    ".build/",
    "MacScope/DerivedData",
    "ThirdParty/",
)
TEST_PREFIXES = (
    "Scripts/tests/",
    "Scripts/reconstruction_gate_f/tests/",
)
VALIDATOR_FILENAMES = {
    "validate_offline_build_surface.py",
    "validate_third_party_components.py",
    "validate_policy_consistency.py",
}

# Patterns are intentionally command-oriented rather than matching every URL.
# Source/repository URLs in manifests are metadata; executing a network client
# or build-system downloader in an ordinary build surface is what is forbidden.
NETWORK_COMMAND_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("curl", re.compile(r"(?m)^[^#\n]*?(?:^|[;&|()\s])(?:/usr/bin/)?curl(?:\s|$)")),
    ("wget", re.compile(r"(?m)^[^#\n]*?(?:^|[;&|()\s])(?:/usr/bin/)?wget(?:\s|$)")),
    (
        "git network operation",
        re.compile(r"(?m)^[^#\n]*?(?:^|[;&|()\s])(?:/usr/bin/)?git\s+(?:clone|fetch|pull|submodule\s+(?:add|update))(?:\s|$)"),
    ),
    (
        "SwiftPM network resolution",
        re.compile(r"(?m)^[^#\n]*?(?:^|[;&|()\s])swift\s+package\s+(?:resolve|update)(?:\s|$)"),
    ),
    (
        "Xcode package resolution",
        re.compile(r"(?m)^[^#\n]*?xcodebuild[^\n]*-resolvePackageDependencies(?:\s|$)"),
    ),
    ("CMake FetchContent", re.compile(r"(?im)^\s*FetchContent_(?:Declare|MakeAvailable|Populate)\s*\(")),
    ("CMake ExternalProject", re.compile(r"(?im)^\s*ExternalProject_Add\s*\(")),
    ("Python urlopen", re.compile(r"\b(?:urllib\.request\.)?urlopen\s*\(")),
    ("Python requests", re.compile(r"\brequests\.(?:get|post|put|patch|delete|request)\s*\(")),
    (
        "Python package acquisition",
        re.compile(r"(?m)^[^#\n]*?(?:-m\s+)?pip(?:3(?:\.\d+)?)?\s+(?:download|install)(?:\s|$)"),
    ),
    (
        "Zig package acquisition",
        re.compile(
            r'(?mi)^[^#\n]*?(?:\bzig|\$[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*\}|"\$\{[^}\n]*ZIG[^}\n]*\}"|"\$[A-Za-z_][A-Za-z0-9_]*")\s+build[^\n]*--fetch(?:=|\s|$)'
        ),
    ),
)

FLOATING_PACKAGE_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("SwiftPM branch dependency", re.compile(r"\.package\s*\([^\n]*\bbranch\s*:", re.IGNORECASE)),
    ("SwiftPM range dependency", re.compile(r"\.package\s*\([^\n]*\bfrom\s*:", re.IGNORECASE)),
    ("SwiftPM version range", re.compile(r"\.package\s*\([^\n]*(?:\.upToNextMajor|\.upToNextMinor|\.range\s*\()", re.IGNORECASE)),
    ("XcodeGen branch dependency", re.compile(r"(?m)^\s*branch\s*:\s*\S+")),
    ("XcodeGen lower-bound dependency", re.compile(r"(?m)^\s*from\s*:\s*\S+")),
)


class OfflineBuildValidationError(RuntimeError):
    pass


class DuplicateJSONKey(ValueError):
    pass


@dataclass(frozen=True)
class OfflineBuildSummary:
    normal_entrypoints: tuple[str, ...]
    scanned_files: tuple[str, ...]
    materializer_scripts: tuple[str, ...]
    network_materializer_scripts: tuple[str, ...]
    surface_sha256: str

    def as_json(self) -> dict[str, object]:
        return {
            "normal_entrypoints": list(self.normal_entrypoints),
            "scanned_file_count": len(self.scanned_files),
            "materializer_scripts": list(self.materializer_scripts),
            "network_materializer_scripts": list(self.network_materializer_scripts),
            "surface_sha256": self.surface_sha256,
        }


def _object_without_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJSONKey(key)
        result[key] = value
    return result


def _read_regular_bytes(path: Path, label: str) -> bytes:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise OfflineBuildValidationError(f"{label} is missing or inaccessible: {error}")
    if not stat.S_ISREG(metadata.st_mode):
        raise OfflineBuildValidationError(f"{label} must be a regular file, not a symlink")
    if metadata.st_size > MAX_FILE_BYTES:
        raise OfflineBuildValidationError(f"{label} exceeds the fixed size bound")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        payload = stream.read(MAX_FILE_BYTES + 1)
    if len(payload) > MAX_FILE_BYTES:
        raise OfflineBuildValidationError(f"{label} grew beyond the fixed size bound")
    return payload


def _read_regular_text(path: Path, label: str) -> tuple[str, bytes]:
    payload = _read_regular_bytes(path, label)
    try:
        return payload.decode("utf-8"), payload
    except UnicodeDecodeError as error:
        raise OfflineBuildValidationError(f"{label} must be UTF-8: {error}")


def _load_manifest(root: Path) -> dict[str, Any]:
    path = root / "THIRD_PARTY_COMPONENTS.yml"
    payload = _read_regular_bytes(path, "THIRD_PARTY_COMPONENTS.yml")
    try:
        value = json.loads(payload, object_pairs_hook=_object_without_duplicate_keys)
    except DuplicateJSONKey as error:
        raise OfflineBuildValidationError(f"manifest contains duplicate key: {error.args[0]}")
    except json.JSONDecodeError as error:
        raise OfflineBuildValidationError(
            f"manifest must remain JSON-compatible YAML: line {error.lineno}: {error.msg}"
        )
    if not isinstance(value, dict) or not isinstance(value.get("components"), list):
        raise OfflineBuildValidationError("manifest components must be an array")
    return value


def _relative(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def _materializers(root: Path, manifest: dict[str, Any]) -> tuple[dict[str, bool], set[str]]:
    result: dict[str, bool] = {}
    expected_untracked_roots: set[str] = set()
    for index, component in enumerate(manifest["components"]):
        if not isinstance(component, dict):
            raise OfflineBuildValidationError(f"components[{index}] must be an object")
        component_id = component.get("id")
        materialization = component.get("materialization")
        if not isinstance(component_id, str) or not isinstance(materialization, dict):
            raise OfflineBuildValidationError(
                f"components[{index}] lacks a valid id/materialization record"
            )
        script = materialization.get("script")
        network_allowed = materialization.get("network_allowed")
        implicit = materialization.get("implicit_build_invocation")
        expected_root = materialization.get("expected_untracked_root")
        if type(network_allowed) is not bool or type(implicit) is not bool:
            raise OfflineBuildValidationError(
                f"{component_id}.materialization flags must be booleans"
            )
        if implicit:
            raise OfflineBuildValidationError(
                f"{component_id} permits implicit materializer invocation"
            )
        if expected_root is not None:
            if not isinstance(expected_root, str) or not expected_root or "/" in expected_root:
                raise OfflineBuildValidationError(
                    f"{component_id}.expected_untracked_root must be a root directory name"
                )
            expected_untracked_roots.add(expected_root)
        if script is None:
            if network_allowed:
                raise OfflineBuildValidationError(
                    f"{component_id} permits network access without a materializer"
                )
            continue
        if not isinstance(script, str) or not script:
            raise OfflineBuildValidationError(f"{component_id}.materialization.script is malformed")
        if Path(script).is_absolute() or ".." in Path(script).parts:
            raise OfflineBuildValidationError(
                f"{component_id}.materialization.script must be repository-relative"
            )
        path = root / script
        _read_regular_bytes(path, f"{component_id} materialization script")
        if script in result:
            raise OfflineBuildValidationError(
                f"materializer is shared by multiple component records: {script}"
            )
        if network_allowed and not re.fullmatch(
            r"Scripts/dependencies/materialize_[A-Za-z0-9_.-]+\.(?:sh|py)", script
        ):
            raise OfflineBuildValidationError(
                f"networked materializer is outside the explicit materialize_* boundary: {script}"
            )
        result[script] = network_allowed
    try:
        first_party = declared_components(root)
    except FirstPartyValidationError as error:
        raise OfflineBuildValidationError(str(error)) from error
    for component in first_party:
        script = component["materialization_script"]
        _read_regular_bytes(root / script, "first-party materialization script")
        if script in result:
            raise OfflineBuildValidationError(f"first-party materializer overlaps the external inventory: {script}")
        result[script] = False
    return result, expected_untracked_roots


def _discover_build_surface(root: Path) -> tuple[str, ...]:
    files: list[str] = []
    for candidate in sorted(root.rglob("*"), key=lambda item: os.fsencode(item.as_posix())):
        if not candidate.is_file() or candidate.is_symlink():
            continue
        relative = _relative(root, candidate)
        if relative.startswith(SKIPPED_PREFIXES):
            continue
        if relative.startswith(TEST_PREFIXES):
            continue
        if candidate.name in VALIDATOR_FILENAMES:
            continue
        if relative.startswith(".github/workflows/"):
            # CI may deliberately invoke an explicit materializer before the
            # normal offline build. Its materializer use is checked separately.
            continue
        if (
            relative.startswith("Scripts/")
            and (candidate.suffix in BUILD_FILE_SUFFIXES or candidate.name in BUILD_FILE_NAMES)
        ) or candidate.name in BUILD_FILE_NAMES:
            files.append(relative)
        if len(files) > MAX_SCANNED_FILES:
            raise OfflineBuildValidationError("build-surface file count exceeds fixed bound")
    return tuple(files)


def _git_quoted_path_word(raw: str) -> bool:
    """A whole quoted data argument with only simple parameter expansion."""
    return re.fullmatch(
        r'"(?:[^"$`\\\r\n]|\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\}))*"', raw
    ) is not None


def _git_local_command_prefix(prefix: str) -> bool:
    # Only command separators, shell control words and data-only environment
    # assignments can precede the literal executable. No env/command/eval trust.
    tail = re.split(r";|&&|\|\||\||\$\(", prefix)[-1].strip()
    tail = re.sub(r"^(?:(?:if|elif|then|while|until|do|!)(?:\s+|$))+", "", tail)
    assignment = re.compile(
        r"[A-Za-z_][A-Za-z0-9_]*="
        r'(?:"(?:[^"$`\\\r\n]|\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\}))*"'
        r"|'[^'\r\n]*'|[A-Za-z0-9_./:-]*)(?:[ \t]+|$)"
    )
    while tail:
        match = assignment.match(tail)
        if not match:
            return False
        tail = tail[match.end():].lstrip()
    return True


def _git_global_option_violation(text: str) -> bool:
    """Bounded literal Git command windows; no filename or role exemption."""
    candidate = re.compile(
        r"(?<![A-Za-z0-9_./-])"
        r"(?:'(?:git|/usr/bin/git|/bin/git)'|"
        r'"(?:git|/usr/bin/git|/bin/git)"|git|/usr/bin/git|/bin/git)'
        r"(?=(?:[ \t]|\\\n)+(?:[-$]|['\"][-$]))"
    )
    visited_text = 0
    max_visited_text = 8 * 1024 * 1024
    for match in candidate.finditer(text):
        line_start = text.rfind("\n", 0, match.start()) + 1
        line_end = text.find("\n", match.end())
        if line_end < 0:
            line_end = len(text)
        command = text[match.start():line_end]
        # A continuation immediately after the executable cannot inject a verb
        # or option. Do not silently normalize arbitrary continuations elsewhere.
        if re.fullmatch(r"[^ \t]+[ \t]+\\", command):
            following_end = text.find("\n", line_end + 1)
            if following_end < 0:
                following_end = len(text)
            command = command[:-1] + text[line_end + 1:following_end].lstrip()
            line_end = following_end
        visited_text += line_end - line_start
        if visited_text > max_visited_text:
            return True  # There is an actual prefixed Git candidate at this limit.
        prefix = text[line_start:match.start()]
        quote = None
        comment = False
        escaped = False
        for index, character in enumerate(prefix):
            if escaped:
                escaped = False
                continue
            if character == "\\" and quote != "'":
                escaped = True
            elif quote:
                if character == quote:
                    quote = None
            elif character in "'\"":
                quote = character
            elif character == "#" and (index == 0 or prefix[index - 1] in " \t;|&"):
                comment = True
                break
        if comment:
            continue
        nested_commands: list[tuple[int, int]] = []
        violation = _scan_git_global_options(command, nested_commands, 64)
        if violation is None or violation:
            return True
        if _git_local_command_prefix(prefix):
            continue
        # Quoted source metadata may describe a local command. The command was
        # still parsed above: a network verb or unsupported prefix is never erased.
        if quote is not None:
            continue
        return True
    return False


def _scan_git_global_options(
    text: str, nested_commands: list[tuple[int, int]], max_pending: int,
) -> bool | None:
    """Scan one bounded span; None means the caller must use its limit policy."""
    words: list[tuple[str, bool, bool, str]] = []
    separators = ";&|()<>\n"
    i = 0
    while i < len(text):
        if text[i] in " \t\r":
            i += 1
            continue
        if text[i] == "#":
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
            continue
        if text[i] in separators:
            separator = text[i]
            i += 1
            if separator in "&|" and i < len(text) and text[i] == separator:
                separator += text[i]
                i += 1
            words.append((separator, True, False, separator))
            continue
        word_start = i
        value: list[str] = []
        valid = True
        quoted = text[i] in "'\""
        pieces = 0
        while i < len(text) and text[i] not in " \t\r" + separators:
            pieces += 1
            if text[i] in "'\"":
                quote = text[i]
                i += 1
                while i < len(text) and text[i] != quote:
                    if quote == '"' and text.startswith("$(", i):
                        end = text.find(")", i + 2)
                        # This bounded inner slice is only an additional lexical
                        # rejection path, never a certificate for outer syntax.
                        if len(nested_commands) >= max_pending:
                            return None
                        nested_commands.append((i + 2, len(text) if end < 0 else end))
                    if text[i] in "$`\\\n\r":
                        valid = False
                    value.append(text[i])
                    i += 1
                if i == len(text):
                    valid = False
                    break
                i += 1
            else:
                while i < len(text) and text[i] not in " \t\r'\"" + separators:
                    if text[i] in "$`\\":
                        valid = False
                    value.append(text[i])
                    i += 1
        if quoted and pieces != 1:
            valid = False
        if not quoted and pieces != 1:
            valid = False
        words.append(("".join(value), valid, quoted, text[word_start:i]))

    boundaries = {";", "&&", "||", "|", "\n"}
    all_separators = set(separators) | {"&&", "||"}
    for index, (executable, valid, _, _) in enumerate(words):
        if executable not in {"git", "/usr/bin/git", "/bin/git"}:
            continue
        cursor = index + 1
        if cursor >= len(words) or not words[cursor][0].startswith(("-", "$")):
            continue
        nested_command = index >= 2 and words[index - 1][0] == "(" and words[index - 2][0] == "$"
        if not valid or (index and words[index - 1][0] not in boundaries and not nested_command):
            return True
        saw_option = False
        deferred_path_parameter = False
        while cursor < len(words) and words[cursor][0] not in all_separators:
            word, literal, quoted, raw = words[cursor]
            attached = re.fullmatch(r'(-C|--git-dir=|--work-tree=)(".*")', raw)
            attached_path = attached is not None and _git_quoted_path_word(attached.group(2))
            if not literal and not attached_path:
                return True
            if not word.startswith("-"):
                break
            saw_option = True
            if quoted:
                return True
            option = None
            argument = None
            if attached_path:
                option = attached.group(1).rstrip("=")
                argument = attached.group(2)[1:-1]
                deferred_path_parameter = True
            elif word == "--no-pager":
                cursor += 1
                continue
            elif word in {"-C", "-c", "--git-dir", "--work-tree"}:
                option = word
                cursor += 1
                if cursor >= len(words):
                    return True
                argument, literal, argument_quoted, argument_raw = words[cursor]
                # Only one whole double-quoted simple parameter is a path value.
                # Keep its exact source spelling: cooked text cannot distinguish
                # single quotes, concatenation, or parameter operators.
                path_parameter = (
                    option in {"-C", "--git-dir", "--work-tree"}
                    and argument_quoted
                    and _git_quoted_path_word(argument_raw)
                )
                if not literal and not path_parameter:
                    return True
                if argument in all_separators or argument.startswith("-"):
                    return True
                deferred_path_parameter = deferred_path_parameter or path_parameter
            elif word.startswith("-C"):
                option, argument = "-C", word[2:]
            elif word.startswith("-c") and not word.startswith("--"):
                option, argument = "-c", word[2:]
            elif word.startswith("--git-dir="):
                option, argument = "--git-dir", word.split("=", 1)[1]
            elif word.startswith("--work-tree="):
                option, argument = "--work-tree", word.split("=", 1)[1]
            else:
                return True
            if not argument:
                return True
            if option == "-c":
                key, equals, _ = argument.partition("=")
                if not equals or not key or key.lower().startswith(("alias.", "include.", "includeif.")):
                    return True
            cursor += 1
        if cursor == len(words) or words[cursor][0] in all_separators:
            if saw_option:
                return True
            continue
        verb, literal, quoted, _ = words[cursor]
        if not literal or quoted:
            return True
        if deferred_path_parameter and verb not in {
            "branch", "rev-parse", "init", "config", "add", "write-tree", "commit",
            "am", "commit-tree", "update-ref", "diff", "status", "merge-base",
            "rev-list", "ls-tree", "cat-file", "archive", "ls-files", "log",
            "hash-object", "show", "symbolic-ref",
        }:
            return True
        if verb in {"clone", "fetch", "pull"}:
            return True
        if verb == "submodule":
            cursor += 1
            if cursor < len(words) and words[cursor][0] not in all_separators:
                operation, literal, quoted, _ = words[cursor]
                if not literal or quoted or operation.startswith("-") or operation in {"add", "update"}:
                    return True
    return False


def _matching_labels(text: str, patterns: tuple[tuple[str, re.Pattern[str]], ...]) -> list[str]:
    return [
        label for label, pattern in patterns
        if pattern.search(text)
        or (label == "git network operation" and _git_global_option_violation(text))
    ]


def _validate_gitignore(root: Path, expected_untracked_roots: set[str]) -> None:
    text, _ = _read_regular_text(root / ".gitignore", ".gitignore")
    normalized_lines = {
        line.strip().lstrip("/").rstrip("/")
        for line in text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    for expected in sorted(expected_untracked_roots):
        if expected not in normalized_lines:
            raise OfflineBuildValidationError(
                f"materialized dependency root is not ignored: {expected}"
            )


def _acquisition_tokens(materializers: dict[str, bool]) -> dict[str, str]:
    tokens: dict[str, str] = {}
    network_materializers = {
        path for path, network_allowed in materializers.items() if network_allowed
    }
    explicit_entrypoints = (
        set(EXPLICIT_MATERIALIZATION_SHIMS) | set(EXPLICIT_QUALIFICATION_ENTRYPOINTS)
        | set(EXPLICIT_OFFLINE_QUALIFICATION_DELEGATES)
    )
    first_party_materializers = set(materializers) & ACQUISITION_SCRIPTS
    # The station sync delegates to the first-party materializer.
    explicit_entrypoints.add(STATION_SYNC_ENTRYPOINT)
    for relative in sorted(network_materializers | explicit_entrypoints | first_party_materializers):
        names = [relative, Path(relative).name]
        if relative in EXPLICIT_OFFLINE_QUALIFICATION_DELEGATES:
            # Python qualification is also callable by import or `python -m`.
            names.extend((Path(relative).stem, relative[:-3].replace("/", ".")))
        for token in names:
            previous = tokens.get(token)
            if previous is not None and previous != relative:
                raise OfflineBuildValidationError(
                    f"ambiguous dependency-acquisition entry point name: {token}"
                )
            tokens[token] = relative
    return tokens


def _inert_literal_output_text(relative, text):
    if '\r' in text:  # CR is not a portable shell token separator.
        return text
    if not relative.endswith(('.sh', '.bash', '.zsh')):
        return text
    lines = text.splitlines()
    if not lines or lines[0] not in {
        '#!/bin/bash', '#!/usr/bin/env bash', '#!/bin/sh', '#!/usr/bin/env sh',
    }:
        return text
    commands, command = [], []
    i = 0
    while i < len(text):
        c = text[i]
        if c in ' \t\r':
            i += 1
            continue
        if c == '#':
            # This branch is reached only at a token boundary outside quotes.
            j = text.find('\n', i)
            i = len(text) if j < 0 else j
            continue
        if c in '\n;':
            if command:
                commands.append(command)
                command = []
            i += 1
            continue
        if c in '$`\\<>(){}|&':
            return text
        start = i
        cooked = []
        wholly_quoted = c in "'\""
        quote_count = 0
        while i < len(text) and text[i] not in ' \t\r\n;':
            c = text[i]
            if c in '$`\\<>(){}|&':
                return text
            if c in "'\"":
                quote = c
                quote_count += 1
                i += 1
                while i < len(text) and text[i] != quote:
                    c = text[i]
                    if quote == '"' and c in '$`':
                        return text
                    if quote == '"' and c == '\\':
                        if i + 1 >= len(text):
                            return text
                        following = text[i + 1]
                        # Shell-special backslash escapes are intentionally not
                        # certified. \n/\t in printf formats remain literal bytes.
                        if following in '$`"\\\n':
                            return text
                        cooked.extend(('\\', following))
                        i += 2
                        continue
                    cooked.append(c)
                    i += 1
                if i == len(text):
                    return text
                i += 1
                if i < len(text) and text[i] not in ' \t\r\n;':
                    wholly_quoted = False
            else:
                wholly_quoted = False
                cooked.append(c)
                i += 1
        command.append((start, i, ''.join(cooked), wholly_quoted and quote_count == 1))
    if command:
        commands.append(command)
    # These constructs can change parsing/executable identity or execute source.
    # No source-path exemption and no attempt to recover through such syntax.
    uncertain = {
        'if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'until', 'do', 'done',
        'case', 'esac', 'in', '[[', ']]', 'function', 'select', 'coproc', 'eval', 'source', '.',
        'exec', 'command', 'builtin', 'alias', 'unalias', 'enable', 'disable',
        'autoload', 'trap', 'emulate', 'zmodload', '!', 'time', 'noglob', 'nocorrect',
    }
    if any(token[2] in uncertain for cmd in commands for token in cmd):
        return text
    spans = []
    for cmd in commands:
        executable = cmd[0][2]
        # Raw exact word: no quote/concatenation/assignment/variable/path-basename
        # inference. The absolute standard executable identity is the only sink
        # semantic assumed; the source file never receives blanket permission.
        if text[cmd[0][0]:cmd[0][1]] != executable:
            continue
        if executable == '/usr/bin/printf':
            if len(cmd) < 3 or cmd[1][2] not in ('%s', '%s\\n') or not cmd[1][3]:
                continue
            arguments = cmd[2:]
        elif executable == '/bin/echo':
            arguments = cmd[1:]
        else:
            continue
        if arguments and all(token[3] for token in arguments):
            spans.extend((token[0], token[1]) for token in arguments)
    if not spans:
        return text
    chars = list(text)
    for start, end in spans:
        for offset in range(start, end):
            if chars[offset] != '\n':
                chars[offset] = ' '
    return ''.join(chars)


def _referenced_acquisition_paths(
    text: str,
    acquisition_tokens: dict[str, str],
    relative: str = "",
) -> set[str]:
    text = _inert_literal_output_text(relative, text)
    return {
        relative
        for token, relative in acquisition_tokens.items()
        if token in text
    }


def _ordinary_acquisition_references(
    relative: str, text: str, acquisition_tokens: dict[str, str],
) -> set[str]:
    # Release provenance records these three policy files as inputs. Permit only
    # that literal inventory expression, not the whole generator or other uses of
    # the materializer name (including a second, executable reference).
    if relative == "Scripts/generate_release_build_provenance.py":
        expected = (
            "FIRST_PARTY_COMPONENTS.json",
            "Scripts/dependencies/first_party_components.py",
            LUMEN_MATERIALIZER,
        )
        try:
            tree = ast.parse(text)
        except SyntaxError:
            return _referenced_acquisition_paths(text, acquisition_tokens, relative)
        payload = text.encode("utf-8")
        lines = payload.splitlines(keepends=True)
        spans: list[tuple[int, int]] = []
        for function in tree.body:
            if not isinstance(function, ast.FunctionDef) or function.name != "selected_source_paths":
                continue
            pending = list(function.body)
            while pending:
                node = pending.pop()
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)):
                    continue
                pending.extend(ast.iter_child_nodes(node))
                call = node.value if isinstance(node, ast.Expr) else None
                if not (isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute)
                        and isinstance(call.func.value, ast.Name) and call.func.value.id == "selected"
                        and call.func.attr == "update" and len(call.args) == 1 and not call.keywords
                        and isinstance(call.args[0], ast.Tuple)):
                    continue
                literal = call.args[0]
                if (not all(isinstance(item, ast.Constant) for item in literal.elts)
                        or tuple(item.value for item in literal.elts) != expected):
                    continue
                start = sum(map(len, lines[:literal.lineno - 1])) + literal.col_offset
                end = sum(map(len, lines[:literal.end_lineno - 1])) + literal.end_col_offset
                spans.append((start, end))
        for start, end in sorted(spans, reverse=True):
            payload = payload[:start] + b"()" + payload[end:]
        text = payload.decode("utf-8")
    return _referenced_acquisition_paths(text, acquisition_tokens, relative)


def _qualification_operation_text(relative: str, text: str) -> str:
    # Only the reviewed literal source inventory is metadata. Executable uses
    # of the CLI path elsewhere remain acquisition references. Candidate identity
    # production is local artifact work, not dependency materialization.
    if relative != "Scripts/reconstruction_gate_f/bootstrap_qualification.py":
        return text
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return text
    metadata_paths = {
        "Scripts/reconstruction_gate_f/bootstrap_cli.py",
        "Scripts/reconstruction_gate_f/materialize_candidate_identity.py",
    }
    payload = text.encode("utf-8")
    lines = payload.splitlines(keepends=True)
    spans = []
    for node in tree.body:
        if not (isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name)
                and node.targets[0].id == "PRODUCER_MANIFEST_PATHS"):
            continue
        literal = node.value
        for name in ("tuple", "sorted"):
            if not (isinstance(literal, ast.Call) and isinstance(literal.func, ast.Name)
                    and literal.func.id == name and len(literal.args) == 1 and not literal.keywords):
                break
            literal = literal.args[0]
        else:
            if isinstance(literal, ast.Tuple) and all(isinstance(item, ast.Constant) for item in literal.elts):
                for item in literal.elts:
                    if item.value in metadata_paths:
                        start = sum(map(len, lines[:item.lineno - 1])) + item.col_offset
                        end = sum(map(len, lines[:item.end_lineno - 1])) + item.end_col_offset
                        spans.append((start, end))
    for start, end in sorted(spans, reverse=True):
        payload = payload[:start] + b'""' + payload[end:]
    return payload.decode("utf-8")


def _validate_explicit_materialization_shims(
    root: Path,
    materializers: dict[str, bool],
) -> None:
    acquisition_tokens = _acquisition_tokens(materializers)
    network_materializers = {
        path for path, network_allowed in materializers.items() if network_allowed
    }
    for relative in EXPLICIT_MATERIALIZATION_SHIMS:
        text, _ = _read_regular_text(root / relative, relative)
        violations = _matching_labels(text, NETWORK_COMMAND_PATTERNS)
        if violations:
            raise OfflineBuildValidationError(
                f"materialization shim performs network I/O directly: "
                f"{relative}: {', '.join(violations)}"
            )
        references = _referenced_acquisition_paths(text, acquisition_tokens, relative)
        references.discard(relative)
        if len(references) != 1 or not references.issubset(network_materializers):
            raise OfflineBuildValidationError(
                f"materialization shim must delegate to exactly one manifested "
                f"network materializer: {relative}"
            )


def _validate_explicit_qualification_entrypoints(
    root: Path,
    materializers: dict[str, bool],
) -> None:
    acquisition_tokens = _acquisition_tokens(materializers)
    for relative in EXPLICIT_QUALIFICATION_ENTRYPOINTS:
        text, _ = _read_regular_text(root / relative, relative)
        violations = _matching_labels(text, NETWORK_COMMAND_PATTERNS)
        if violations:
            raise OfflineBuildValidationError(
                f"qualification entrypoint performs network I/O directly: "
                f"{relative}: {', '.join(violations)}"
            )
        references = _referenced_acquisition_paths(text, acquisition_tokens, relative)
        references.discard(relative)
        if references != QUALIFICATION_REQUIRED_MATERIALIZERS:
            raise OfflineBuildValidationError(
                "qualification entrypoint must consume repository-owned producers "
                f"without network materializers: {relative}"
            )


def _validate_normal_entrypoints(root: Path, materializers: dict[str, bool]) -> None:
    materializer_names = {Path(path).name for path in materializers}
    acquisition_tokens = _acquisition_tokens(materializers)
    for relative in NORMAL_ENTRYPOINTS:
        text, _ = _read_regular_text(root / relative, relative)
        references = _referenced_acquisition_paths(text, acquisition_tokens, relative)
        if references:
            raise OfflineBuildValidationError(
                f"normal entry point invokes or references dependency acquisition: "
                f"{relative}: {', '.join(sorted(references))}"
            )
        # Fail closed even when a new materializer is introduced before its
        # manifest record is added.
        for token in re.findall(r"materialize_[A-Za-z0-9_.-]+\.(?:sh|py)", text):
            if token not in materializer_names:
                raise OfflineBuildValidationError(
                    f"normal entry point references an ungoverned materializer: {relative}: {token}"
                )
        violations = _matching_labels(text, NETWORK_COMMAND_PATTERNS)
        if violations:
            raise OfflineBuildValidationError(
                f"normal entry point contains network-backed operation(s): "
                f"{relative}: {', '.join(violations)}"
            )
        floating = _matching_labels(text, FLOATING_PACKAGE_PATTERNS)
        if floating:
            raise OfflineBuildValidationError(
                f"normal entry point contains floating package declaration(s): "
                f"{relative}: {', '.join(floating)}"
            )


def _validate_ghostty_zig_closure(root: Path) -> None:
    bootstrap, _ = _read_regular_text(root / "Scripts/bootstrap.sh", "Scripts/bootstrap.sh")
    builder, _ = _read_regular_text(
        root / "Scripts/build_ghostty_vt.sh", "Scripts/build_ghostty_vt.sh"
    )
    surface_wrapper, _ = _read_regular_text(
        root / "Scripts/dependencies/build_vendored_ghostty_surface.sh",
        "Scripts/dependencies/build_vendored_ghostty_surface.sh",
    )
    surface_builder, _ = _read_regular_text(
        root / "Scripts/dependencies/build_ghostty_surface.sh",
        "Scripts/dependencies/build_ghostty_surface.sh",
    )
    materializer, _ = _read_regular_text(
        root / "Scripts/dependencies/materialize_ghostty_vt.sh",
        "Scripts/dependencies/materialize_ghostty_vt.sh",
    )

    surface_producer_call = (
        '"${SCRIPT_DIR}/dependencies/build_vendored_ghostty_surface.sh"'
    )
    required_bootstrap_fragments = (
        'GHOSTTY_SURFACE_WORK_ROOT="${MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT:-${TMPDIR:-/tmp}/MacScope}"',
        '--work-root "${GHOSTTY_SURFACE_WORK_ROOT}"',
        'MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR = ${GHOSTTY_SURFACE_SOURCE_DIR}',
        'MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT = ${GHOSTTY_SURFACE_ARTIFACT_ROOT}',
        'MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK = ${GHOSTTY_SURFACE_FRAMEWORK}',
        'MACSCOPE_GHOSTTY_SURFACE_ENABLED = MACSCOPE_FULL_GHOSTTY_SURFACE',
    )
    missing_bootstrap = [
        fragment for fragment in required_bootstrap_fragments if fragment not in bootstrap
    ]
    if (
        bootstrap.count(surface_producer_call) != 1
        or f"{surface_producer_call} --verify-only" in bootstrap
        or missing_bootstrap
    ):
        raise OfflineBuildValidationError(
            "ordinary Ghostty bootstrap must produce or reuse exactly one vendored "
            "full-surface artifact under its published external root"
        )

    required_builder_fragments = (
        'GHOSTTY_DIR="${REPO_ROOT}/ThirdParty/GhosttyVT/Source"',
        '--work-root)',
        'echo "ERROR: --work-root is required and must name an external build root."',
        'ZIG_ROOT="${REPO_ROOT}/ThirdParty/Zig/zig-0.16.0"',
        '--system "${PACKAGE_STORE}"',
        '--cache-dir "${BUILD_CACHE_ROOT}"',
        '--prefix "${ARTIFACT_ROOT}"',
        'ZIG_GLOBAL_CACHE_DIR="${GLOBAL_CACHE_ROOT}"',
        'EXPECTED_GHOSTTY_ZIG_PACKAGE_STORE_SHA256',
        'EXPECTED_ZIG_AARCH64_MACOS_TREE_SHA256',
        'EXPECTED_ZIG_TOOLCHAIN_RECEIPT_SHA256',
        'zig_toolchain_receipt.py',
    )
    missing = [fragment for fragment in required_builder_fragments if fragment not in builder]
    if missing:
        raise OfflineBuildValidationError(
            "ordinary Ghostty builder does not require the closed Zig toolchain/package "
            "identity: " + ", ".join(missing)
        )
    for forbidden in ("--fetch", "--global-cache-dir"):
        if forbidden in builder:
            raise OfflineBuildValidationError(
                f"ordinary Ghostty builder must not use a network/global Zig cache surface: {forbidden}"
            )
    for forbidden in (
        'DYLIB="${GHOSTTY_DIR}',
        'STATIC_LIBRARY="${GHOSTTY_DIR}',
        'HEADERS_ROOT="${GHOSTTY_DIR}',
    ):
        if forbidden in builder:
            raise OfflineBuildValidationError(
                "ordinary Ghostty VT producer must keep all artifacts and caches outside "
                f"the repository-owned source tree: {forbidden}"
            )

    required_surface_wrapper_fragments = (
        'VENDORED_SOURCE="${REPO_ROOT}/ThirdParty/GhosttySurface/Source"',
        'VENDORED_PACKAGE_STORE="${REPO_ROOT}/ThirdParty/GhosttySurface/zig-pkg"',
        'ZIG_ROOT="${REPO_ROOT}/ThirdParty/Zig/zig-0.16.0"',
        'OUTPUT_ROOT="${WORK_ROOT}/GhosttySurface"',
        'MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR="${STAGING}"',
        '"${BUILDER}" --verify-only',
    )
    missing_surface = [
        fragment
        for fragment in required_surface_wrapper_fragments
        if fragment not in surface_wrapper
    ]
    if missing_surface:
        raise OfflineBuildValidationError(
            "ordinary Ghostty full-surface producer is missing its vendored-input, "
            "external-output, or deterministic-verification seam: "
            + ", ".join(missing_surface)
        )
    if 'OUTPUT_ROOT="${REPO_ROOT}' in surface_wrapper:
        raise OfflineBuildValidationError(
            "ordinary Ghostty full-surface producer must keep output outside the repository"
        )
    for relative, text in (
        ("Scripts/build_ghostty_vt.sh", builder),
        ("Scripts/dependencies/build_vendored_ghostty_surface.sh", surface_wrapper),
        ("Scripts/dependencies/build_ghostty_surface.sh", surface_builder),
    ):
        violations = _matching_labels(text, NETWORK_COMMAND_PATTERNS)
        if violations:
            raise OfflineBuildValidationError(
                "ordinary Ghostty producer contains network-backed operation(s): "
                f"{relative}: {', '.join(violations)}"
            )

    bounded_vt_line = 'ZIG_GLOBAL_CACHE_DIR="${isolated_global_cache}" "${zig_root}/zig" build -j1 \\'
    required_materializer_fragments = (
        'local package_store_seed="${MACSCOPE_GHOSTTY_ZIG_PACKAGE_STORE_SOURCE:?',
        'ghostty-source \\\n    --root "${source_dir}"',
        'package-store \\\n    --root "${package_store_seed}"',
        'snapshot \\\n    --kind package-store \\\n    --source "${package_store_seed}" \\\n    --destination "${package_store}"',
        '--system "${package_store}"',
        '--cache-dir "${source_dir}/.zig-cache"',
        '-Demit-lib-vt -Demit-xcframework=false -Dsimd=false',
    )
    missing_materializer = [
        fragment for fragment in required_materializer_fragments if fragment not in materializer
    ]
    if missing_materializer:
        raise OfflineBuildValidationError(
            "explicit Ghostty materializer is missing the fail-closed seed closure path: "
            + ", ".join(missing_materializer)
        )
    if materializer.count(bounded_vt_line) != 1:
        raise OfflineBuildValidationError(
            "explicit Ghostty materializer must own exactly one bounded Ghostty VT materialization operation"
        )
    zig_build_lines = [
        line.strip()
        for line in materializer.splitlines()
        if 'zig" build' in line and not line.lstrip().startswith("#")
    ]
    if zig_build_lines != [bounded_vt_line]:
        raise OfflineBuildValidationError(
            "explicit Ghostty materializer must contain exactly the bounded Ghostty VT Zig build command"
        )
    zig_fetch_lines = [
        line.strip()
        for line in materializer.splitlines()
        if "--fetch" in line and not line.lstrip().startswith("#")
    ]
    if zig_fetch_lines:
        raise OfflineBuildValidationError(
            "explicit Ghostty materializer must contain no composed/eval/sh Zig acquisition path"
        )
    source_verification = materializer.index('ghostty-source \\\n    --root "${source_dir}"')
    seed_verification = materializer.index('package-store \\\n    --root "${package_store_seed}"')
    seed_snapshot = materializer.index('snapshot \\\n    --kind package-store')
    first_zig_invocation = min(
        materializer.index('"${SCRIPT_DIR}/materialize_zig_toolchain.sh"'),
        materializer.index('ZIG_GLOBAL_CACHE_DIR="${isolated_global_cache}" "${zig_root}/zig" build -j1'),
    )
    if not source_verification < first_zig_invocation:
        raise OfflineBuildValidationError(
            "normalized Ghostty source must be verified before any Zig invocation"
        )
    if not seed_verification < seed_snapshot:
        raise OfflineBuildValidationError(
            "Ghostty package-store seed must be verified before its private snapshot"
        )
    if not seed_snapshot < first_zig_invocation:
        raise OfflineBuildValidationError(
            "Ghostty package-store snapshot must be sealed before any Zig invocation"
        )
    if '"${zig_identity_helper}" package-store' not in materializer or '--root "${package_store}"' not in materializer:
        raise OfflineBuildValidationError(
            "explicit Ghostty materializer must verify the frozen package store before building"
        )


def _validate_materializer_inventory(
    root: Path, materializers: dict[str, bool]
) -> tuple[str, ...]:
    materializer_directory = root / "Scripts/dependencies"
    discovered = {
        _relative(root, path)
        for path in materializer_directory.glob("materialize_*")
        if path.is_file() and not path.is_symlink()
    }
    # Inventory every manifest-declared `Scripts/dependencies/materialize_*`
    # entry, including strictly offline direct-source materializers. The
    # network flag governs network-command inspection only; it must not erase a
    # legitimate offline materializer from the ownership inventory.
    manifest_dependency_materializers = {
        script
        for script in materializers
        if script.startswith("Scripts/dependencies/")
        and re.fullmatch(r"materialize_[A-Za-z0-9_.-]+\.(?:sh|py)", Path(script).name)
    }
    ungoverned = sorted(discovered - manifest_dependency_materializers)
    if ungoverned:
        raise OfflineBuildValidationError(
            "materializer script lacks a component manifest record: "
            + ", ".join(ungoverned)
        )
    missing = sorted(manifest_dependency_materializers - discovered)
    if missing:
        raise OfflineBuildValidationError(
            "manifest names a missing/non-canonical materializer: "
            + ", ".join(missing)
        )
    for script, network_allowed in sorted(materializers.items()):
        if script in ACQUISITION_SCRIPTS:
            text, _ = _read_regular_text(root / script, script)
            violations = _matching_labels(text, NETWORK_COMMAND_PATTERNS)
            references = _referenced_acquisition_paths(text, _acquisition_tokens(materializers), script)
            references.discard(script)
            if network_allowed or violations or references:
                raise OfflineBuildValidationError(
                    f"first-party offline materializer may not download or delegate acquisition: {script}"
                )
        if not network_allowed:
            continue
        text, _ = _read_regular_text(root / script, script)
        violations = _matching_labels(text, NETWORK_COMMAND_PATTERNS)
        if not violations:
            raise OfflineBuildValidationError(
                f"network-enabled materializer has no detectable network operation: {script}"
            )
    return tuple(sorted(discovered))


def validate_offline_build_surface(root: Path) -> OfflineBuildSummary:
    root = root.resolve(strict=True)
    manifest = _load_manifest(root)
    materializers, expected_untracked_roots = _materializers(root, manifest)
    _validate_gitignore(root, expected_untracked_roots)
    _validate_explicit_materialization_shims(root, materializers)
    _validate_explicit_qualification_entrypoints(root, materializers)
    _validate_normal_entrypoints(root, materializers)
    _validate_ghostty_zig_closure(root)
    discovered_materializers = _validate_materializer_inventory(root, materializers)

    surface = _discover_build_surface(root)
    acquisition_tokens = _acquisition_tokens(materializers)
    allowed_acquisition_paths = (
        set(discovered_materializers)
        | set(EXPLICIT_MATERIALIZATION_SHIMS)
        | set(EXPLICIT_QUALIFICATION_ENTRYPOINTS)
    )
    digest = hashlib.sha256()
    for relative in surface:
        text, payload = _read_regular_text(root / relative, relative)
        if relative in allowed_acquisition_paths:
            # Explicit acquisition is checked by the manifest/shim validators
            # and intentionally excluded from ordinary-surface prohibition.
            continue
        operation_text = _qualification_operation_text(relative, text)
        references = _ordinary_acquisition_references(relative, operation_text, acquisition_tokens)
        if relative in QUALIFICATION_REVALIDATION_CONSUMERS:
            references.discard("Scripts/reconstruction_gate_f/bootstrap_qualification.py")
            if re.search(r"\bexecute_bootstrap_qualification\b", operation_text):
                raise OfflineBuildValidationError(
                    f"read-only qualification consumer references qualification execution: {relative}"
                )
        if relative in EXPLICIT_OFFLINE_QUALIFICATION_DELEGATES or relative in QUALIFICATION_REVALIDATION_CONSUMERS:
            references.discard(relative)
            references -= EXPLICIT_OFFLINE_QUALIFICATION_DELEGATES.get(relative, set())
            if "--materialize-dependencies" in operation_text:
                raise OfflineBuildValidationError(
                    f"offline qualification delegate references dependency acquisition: {relative}"
                )
            if re.search(r"materialize_[A-Za-z0-9_.-]+\.(?:sh|py)", operation_text):
                raise OfflineBuildValidationError(
                    f"offline qualification delegate references dependency acquisition materializer: {relative}"
                )
        if relative in REFERENCE_ONLY_ACQUISITION_PATHS:
            references.clear()
        if relative in DEVELOPER_STATION_DELEGATES:
            references.discard(relative)
            references -= DEVELOPER_STATION_DELEGATES[relative]
        if references:
            raise OfflineBuildValidationError(
                f"ordinary build helper references dependency acquisition: "
                f"{relative}: {', '.join(sorted(references))}"
            )
        violations = _matching_labels(text, NETWORK_COMMAND_PATTERNS)
        if violations:
            raise OfflineBuildValidationError(
                f"ordinary build surface contains network-backed operation(s): "
                f"{relative}: {', '.join(violations)}"
            )
        floating = _matching_labels(text, FLOATING_PACKAGE_PATTERNS)
        if floating:
            raise OfflineBuildValidationError(
                f"ordinary build surface contains floating package declaration(s): "
                f"{relative}: {', '.join(floating)}"
            )
        encoded_relative = relative.encode("utf-8")
        digest.update(len(encoded_relative).to_bytes(8, "big"))
        digest.update(encoded_relative)
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)

    network_materializers = tuple(
        sorted(script for script, allowed in materializers.items() if allowed)
    )
    return OfflineBuildSummary(
        normal_entrypoints=NORMAL_ENTRYPOINTS,
        scanned_files=surface,
        materializer_scripts=discovered_materializers,
        network_materializer_scripts=network_materializers,
        surface_sha256=digest.hexdigest(),
    )


def parse_arguments(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        summary = validate_offline_build_surface(arguments.repo_root)
    except (OfflineBuildValidationError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    if arguments.emit_json:
        print(json.dumps(summary.as_json(), sort_keys=True, separators=(",", ":")))
    else:
        print(
            "Offline build surface verified: "
            f"{len(summary.scanned_files)} files; "
            f"{len(summary.network_materializer_scripts)} explicit network materializer(s)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
