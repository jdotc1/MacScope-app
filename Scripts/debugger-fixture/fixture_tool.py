#!/usr/bin/env python3
"""Build and verify the deterministic WS-18 debugger fixture."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, Mapping, Optional, Tuple


SCHEMA_VERSION = 1
TARGET_TRIPLE = "arm64-apple-macos27.0"
APP_NAME = "MacScopeDebuggerFixture.app"
APP_EXECUTABLE = "MacScopeDebuggerFixture"
FRAMEWORK_NAME = "MacScopeDebuggerFixtureRuntime.framework"
FRAMEWORK_EXECUTABLE = "MacScopeDebuggerFixtureRuntime"
HELPER_EXECUTABLE = "MacScopeDebuggerHelper"
APP_IDENTIFIER = "org.macscope.app.debugger-fixture"
FRAMEWORK_IDENTIFIER = "org.macscope.app.debugger-fixture.runtime"
HELPER_IDENTIFIER = "org.macscope.app.debugger-fixture.helper"
APPROVED_SIGNER = "Apple Development: MacScope Developer (CERT000000)"
APPROVED_TEAM = "TEAM000000"

REQUIRED_RELATIVE_PATHS = (
    "MacScopeDebuggerFixture.app/Contents/Info.plist",
    "MacScopeDebuggerFixture.app/Contents/MacOS/MacScopeDebuggerFixture",
    "MacScopeDebuggerFixture.app/Contents/Frameworks/"
    "MacScopeDebuggerFixtureRuntime.framework/Info.plist",
    "MacScopeDebuggerFixture.app/Contents/Frameworks/"
    "MacScopeDebuggerFixtureRuntime.framework/MacScopeDebuggerFixtureRuntime",
    "MacScopeDebuggerFixture.app/Contents/Helpers/MacScopeDebuggerHelper",
    "MacScopeDebuggerFixture.app.dSYM/Contents/Resources/DWARF/MacScopeDebuggerFixture",
    "MacScopeDebuggerFixtureRuntime.framework.dSYM/Contents/Resources/DWARF/"
    "MacScopeDebuggerFixtureRuntime",
    "MacScopeDebuggerHelper.dSYM/Contents/Resources/DWARF/MacScopeDebuggerHelper",
)

FIXTURE_SOURCE_INPUTS = (
    "README.md",
    "fixture_tool.py",
    "Resources/AppInfo.plist",
    "Resources/FrameworkInfo.plist",
    "Resources/DebuggableTarget.entitlements",
    "Sources/main.c",
    "Sources/helper.c",
    "Sources/framework.c",
    "Sources/fixture_runtime.c",
    "Sources/fixture_runtime.h",
)


class FixtureError(RuntimeError):
    """A fail-closed fixture planning, build, or verification error."""


class RuntimeProtocol:
    def __init__(self, *, nonce: str, role: str, pid: int) -> None:
        if not nonce or len(nonce.encode("utf-8")) > 128:
            raise FixtureError("nonce must contain between 1 and 128 UTF-8 bytes")
        if role not in ("main", "helper"):
            raise FixtureError("runtime role must be main or helper")
        if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
            raise FixtureError("runtime PID must be a positive integer")
        self.nonce = nonce
        self.role = role
        self.pid = pid
        self._event_sequence = 0
        self._next_command_sequence = 1
        self._ready = False
        self._exiting = False
        self._framework_loaded = False
        self._counters = {"checkpoint": 0, "load": 0, "unload": 0}

    def _event(self, operation: str, result: str = "ok", command_sequence=None):
        self._event_sequence += 1
        event = {
            "schema": SCHEMA_VERSION,
            "sequence": self._event_sequence,
            "pid": self.pid,
            "nonce": self.nonce,
            "role": self.role,
            "operation": operation,
            "result": result,
            "counters": dict(self._counters),
            "frameworkLoaded": self._framework_loaded,
            "exiting": self._exiting,
        }
        if command_sequence is not None:
            event["commandSequence"] = command_sequence
        return event

    def ready(self):
        if self._ready:
            raise FixtureError("readiness event was already emitted")
        self._ready = True
        return self._event("ready")

    def accept(self, line):
        if self._exiting:
            raise FixtureError("runtime is exiting and cannot accept another command")
        if isinstance(line, bytes):
            encoded = line
            try:
                line = line.decode("utf-8")
            except UnicodeDecodeError as error:
                raise FixtureError("command is not valid UTF-8") from error
        elif isinstance(line, str):
            encoded = line.encode("utf-8")
        else:
            raise FixtureError("command must be one JSONL string or bytes value")
        if len(encoded) > 4096:
            raise FixtureError("command exceeds the 4096-byte protocol limit")
        try:
            command = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            raise FixtureError("command is not valid JSON") from error
        if not isinstance(command, dict):
            raise FixtureError("command must be a JSON object")
        if set(command) != {"schema", "sequence", "nonce", "operation"}:
            raise FixtureError("command has missing or unknown fields")
        if command["schema"] != SCHEMA_VERSION:
            raise FixtureError("command schema is unsupported")
        sequence = command["sequence"]
        if isinstance(sequence, bool) or not isinstance(sequence, int):
            raise FixtureError("command sequence must be an integer")
        if sequence != self._next_command_sequence:
            raise FixtureError(
                "command sequence mismatch: expected %d, received %d"
                % (self._next_command_sequence, sequence)
            )
        if command["nonce"] != self.nonce:
            raise FixtureError("command nonce does not match this fixture run")
        operation = command["operation"]
        if operation not in ("load", "checkpoint", "unload", "exit"):
            raise FixtureError("unsupported fixture operation")

        if operation == "load":
            if self._framework_loaded:
                raise FixtureError("framework is already loaded")
            self._framework_loaded = True
            self._counters["load"] += 1
        elif operation == "checkpoint":
            self._counters["checkpoint"] += 1
        elif operation == "unload":
            if not self._framework_loaded:
                raise FixtureError("framework is not loaded")
            self._framework_loaded = False
            self._counters["unload"] += 1
        elif operation == "exit":
            self._exiting = True

        self._next_command_sequence += 1
        return self._event(operation, command_sequence=sequence)

    def debugger_disconnected(self):
        if self._exiting:
            raise FixtureError("runtime is already exiting")
        return self._event("debuggerDisconnected", result="survived")

    def command_eof(self):
        if self._exiting:
            raise FixtureError("runtime is already exiting")
        self._exiting = True
        return self._event("commandEOF", result="gracefulExit")


def validate_control_root(root: Path, *, expected_uid: int, started_after_ns: int) -> None:
    path = Path(root)
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise FixtureError("control root does not exist") from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise FixtureError("control root is not a directory")
    if stat.S_IMODE(metadata.st_mode) != 0o700:
        raise FixtureError("control root permissions must be exactly 0700")
    if metadata.st_uid != expected_uid:
        raise FixtureError("control root owner does not match the fixture owner")
    if metadata.st_mtime_ns < started_after_ns:
        raise FixtureError("control root predates this fixture run")


def validate_command_channel(channel: Path, *, expected_uid: int) -> None:
    path = Path(channel)
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise FixtureError("command channel does not exist") from error
    if not stat.S_ISFIFO(metadata.st_mode):
        raise FixtureError("command channel must be a FIFO")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise FixtureError("command channel permissions must be exactly 0600")
    if metadata.st_uid != expected_uid:
        raise FixtureError("command channel owner does not match the fixture owner")


@dataclass(frozen=True)
class SigningIdentity:
    fingerprint: str
    subject: str


@dataclass(frozen=True)
class ToolchainEvidence:
    developer_directory: str
    xcode_version: str
    xcode_major: int
    sdk_path: str
    sdk_version: str
    sdk_major: int
    tools: Dict[str, str]
    tool_versions: Dict[str, str]

    def as_manifest(self) -> Dict[str, object]:
        return {
            "developerDirectory": self.developer_directory,
            "xcodeVersion": self.xcode_version,
            "xcodeMajor": self.xcode_major,
            "sdkPath": self.sdk_path,
            "sdkVersion": self.sdk_version,
            "sdkMajor": self.sdk_major,
            "tools": dict(sorted(self.tools.items())),
            "toolVersions": dict(sorted(self.tool_versions.items())),
        }


class SubprocessRunner:
    """Text-mode, bounded command runner used by the executable CLI."""

    def __call__(self, command, environment=None):
        merged_environment = dict(os.environ)
        merged_environment.update(environment or {})
        try:
            return subprocess.run(
                list(command),
                capture_output=True,
                text=True,
                env=merged_environment,
                timeout=120,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            return subprocess.CompletedProcess(command, 124, "", str(error))


def _run_checked(runner, command, environment=None):
    result = runner(list(command), environment)
    if result.returncode != 0:
        diagnostic = (result.stderr or result.stdout or "command failed").strip()
        raise FixtureError("%s: %s" % (command[0], diagnostic))
    return result


def _major_version(value: str, description: str) -> int:
    match = re.search(r"(?:^|\s)(\d+)(?:\.|\s|$)", value)
    if match is None:
        raise FixtureError("could not parse %s major version" % description)
    return int(match.group(1))


def discover_toolchain(developer_directory: Path, runner) -> ToolchainEvidence:
    """Resolve and validate the exact selected Xcode 27 toolchain."""

    developer_directory = Path(developer_directory).expanduser()
    developer_text = str(developer_directory)
    environment = {"DEVELOPER_DIR": developer_text}
    xcodebuild = developer_directory / "usr" / "bin" / "xcodebuild"
    xcode_version = _run_checked(runner, (str(xcodebuild), "-version"), environment).stdout.strip()
    xcode_match = re.search(r"(?m)^Xcode\s+(\d+)(?:\.|$)", xcode_version)
    if xcode_match is None:
        raise FixtureError("selected developer directory did not report an Xcode version")
    xcode_major = int(xcode_match.group(1))
    if xcode_major != 27:
        raise FixtureError("selected developer directory must contain Xcode 27")

    sdk_path = _run_checked(
        runner,
        ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"),
        environment,
    ).stdout.strip()
    sdk_version = _run_checked(
        runner,
        ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"),
        environment,
    ).stdout.strip()
    sdk_major = _major_version(sdk_version, "macOS SDK")
    if sdk_major != 27:
        raise FixtureError("selected Xcode must expose a macOS 27 SDK")

    tool_names = (
        "clang",
        "ld",
        "dsymutil",
        "dwarfdump",
        "nm",
        "lipo",
        "vtool",
        "lldb",
        "lldb-dap",
    )
    tools = {}
    for name in tool_names:
        resolved = _run_checked(
            runner, ("/usr/bin/xcrun", "--find", name), environment
        ).stdout.strip()
        if not resolved or not Path(resolved).is_absolute():
            raise FixtureError("selected Xcode returned an invalid path for %s" % name)
        tools[name] = resolved
    return ToolchainEvidence(
        developer_directory=developer_text,
        xcode_version=xcode_version,
        xcode_major=xcode_major,
        sdk_path=sdk_path,
        sdk_version=sdk_version,
        sdk_major=sdk_major,
        tools=tools,
        tool_versions={name: xcode_version for name in tool_names},
    )


def _split_requirement_conjunction(expression: str):
    clauses = []
    start = 0
    quoted = False
    escaped = False
    index = 0
    while index < len(expression):
        character = expression[index]
        if quoted:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                quoted = False
            index += 1
            continue
        if character == '"':
            quoted = True
            index += 1
            continue
        for keyword in ("or", "and"):
            if expression.startswith(keyword, index):
                before = expression[index - 1] if index else " "
                after_index = index + len(keyword)
                after = expression[after_index] if after_index < len(expression) else " "
                if not (before.isalnum() or before == "_") and not (
                    after.isalnum() or after == "_"
                ):
                    if keyword == "or":
                        raise FixtureError("designated requirement may not contain disjunctions")
                    clause = expression[start:index].strip()
                    if not clause:
                        raise FixtureError("designated requirement contains an empty clause")
                    clauses.append(clause)
                    index = after_index
                    start = index
                    break
        else:
            index += 1
            continue
    if quoted or escaped:
        raise FixtureError("designated requirement contains an unterminated string")
    final = expression[start:].strip()
    if not final:
        raise FixtureError("designated requirement contains an empty clause")
    clauses.append(final)
    return clauses


def parse_exact_designated_requirement(output: str, identifier: str) -> str:
    markers = list(re.finditer(r"(?m)^[ \t]*designated[ \t]*=>", output))
    if len(markers) != 1:
        raise FixtureError("expected exactly one designated requirement")
    clauses = _split_requirement_conjunction(output[markers[0].end() :].strip())
    patterns = {
        "identifier": re.compile(r'identifier\s+"%s"' % re.escape(identifier)),
        "anchor": re.compile(r"anchor\s+apple\s+generic"),
        "leaf": re.compile(
            r'certificate\s+leaf\s*\[\s*subject\s*\.\s*CN\s*\]\s*=\s*'
            r'"(?P<subject>Apple Development:[^"\r\n]+)"'
        ),
        "intermediate": re.compile(
            r"certificate\s+1\s*\[\s*field\s*\.\s*1\s*\.\s*2\s*\.\s*840\s*\.\s*"
            r"113635\s*\.\s*100\s*\.\s*6\s*\.\s*2\s*\.\s*1\s*\]\s+"
            r"(?:exists|/\*\s*exists\s*\*/)"
        ),
    }
    observed = {}
    for clause in clauses:
        matches = [(name, pattern.fullmatch(clause)) for name, pattern in patterns.items()]
        matches = [(name, match) for name, match in matches if match is not None]
        if len(matches) != 1:
            raise FixtureError("unexpected designated-requirement clause: %s" % clause)
        name, match = matches[0]
        if name in observed:
            raise FixtureError("duplicate designated-requirement clause: %s" % name)
        observed[name] = match
    if set(observed) != set(patterns):
        raise FixtureError("designated requirement is missing required clauses")
    subject = observed["leaf"].group("subject")
    if subject != APPROVED_SIGNER:
        raise FixtureError("designated requirement has the wrong signing subject")
    return subject


def parse_codesign_entitlements(output: str) -> Dict[str, object]:
    xml_start = output.find("<?xml")
    if xml_start < 0:
        return {}
    marker = "</plist>"
    xml_end = output.find(marker, xml_start)
    if xml_end < 0:
        raise FixtureError("codesign returned a truncated entitlement property list")
    payload = output[xml_start : xml_end + len(marker)].encode("utf-8")
    try:
        value = plistlib.loads(payload)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise FixtureError("codesign returned invalid entitlements") from error
    if not isinstance(value, dict):
        raise FixtureError("codesign entitlements must be a dictionary")
    return value


def resolve_signing_identity(runner, approved_fingerprint=None) -> SigningIdentity:
    result = _run_checked(
        runner,
        ("/usr/bin/security", "find-identity", "-v", "-p", "codesigning"),
    )
    pattern = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"\s*$', re.MULTILINE)
    matches = [
        SigningIdentity(fingerprint=match.group(1).upper(), subject=match.group(2))
        for match in pattern.finditer(result.stdout)
        if match.group(2) == APPROVED_SIGNER
    ]
    if approved_fingerprint is not None:
        normalized = approved_fingerprint.upper()
        if len(normalized) != 40 or any(
            character not in "0123456789ABCDEF" for character in normalized
        ):
            raise FixtureError("approved signing fingerprint must be 40 hexadecimal characters")
        matches = [match for match in matches if match.fingerprint == normalized]
    if len(matches) != 1:
        raise FixtureError(
            "expected exactly one approved Apple Development identity, found %d" % len(matches)
        )
    return matches[0]


@dataclass(frozen=True)
class _ArtifactSpec:
    role: str
    binary: str
    signing_target: str
    dsym_binary: str
    identifier: str
    entitlements: Dict[str, bool]
    preferred_probe: bool


_ARTIFACT_SPECS = (
    _ArtifactSpec(
        role="app",
        binary="MacScopeDebuggerFixture.app/Contents/MacOS/MacScopeDebuggerFixture",
        signing_target="MacScopeDebuggerFixture.app",
        dsym_binary=(
            "MacScopeDebuggerFixture.app.dSYM/Contents/Resources/DWARF/"
            "MacScopeDebuggerFixture"
        ),
        identifier=APP_IDENTIFIER,
        entitlements={"com.apple.security.get-task-allow": True},
        preferred_probe=True,
    ),
    _ArtifactSpec(
        role="framework",
        binary=(
            "MacScopeDebuggerFixture.app/Contents/Frameworks/"
            "MacScopeDebuggerFixtureRuntime.framework/MacScopeDebuggerFixtureRuntime"
        ),
        signing_target=(
            "MacScopeDebuggerFixture.app/Contents/Frameworks/"
            "MacScopeDebuggerFixtureRuntime.framework"
        ),
        dsym_binary=(
            "MacScopeDebuggerFixtureRuntime.framework.dSYM/Contents/Resources/DWARF/"
            "MacScopeDebuggerFixtureRuntime"
        ),
        identifier=FRAMEWORK_IDENTIFIER,
        entitlements={},
        preferred_probe=True,
    ),
    _ArtifactSpec(
        role="helper",
        binary="MacScopeDebuggerFixture.app/Contents/Helpers/MacScopeDebuggerHelper",
        signing_target="MacScopeDebuggerFixture.app/Contents/Helpers/MacScopeDebuggerHelper",
        dsym_binary=(
            "MacScopeDebuggerHelper.dSYM/Contents/Resources/DWARF/MacScopeDebuggerHelper"
        ),
        identifier=HELPER_IDENTIFIER,
        entitlements={"com.apple.security.get-task-allow": True},
        preferred_probe=False,
    ),
)


def _first_match(pattern: str, text: str, description: str) -> str:
    match = re.search(pattern, text, flags=re.MULTILINE)
    if match is None:
        raise FixtureError("could not parse %s" % description)
    return match.group(1)


def verify_artifacts(root: Path, runner, environment=None, toolchain=None):
    root = Path(root)
    for relative_path in REQUIRED_RELATIVE_PATHS:
        path = root / relative_path
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            raise FixtureError("required fixture leaf is missing: %s" % relative_path)
        if not stat.S_ISREG(metadata.st_mode):
            raise FixtureError("required fixture leaf is not a regular file: %s" % relative_path)

    expected_executables = {spec.binary for spec in _ARTIFACT_SPECS}
    app_root = root / APP_NAME
    for path in app_root.rglob("*"):
        relative = str(path.relative_to(root))
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise FixtureError("fixture topology may not contain symlinks: %s" % relative)
        if (
            stat.S_ISREG(metadata.st_mode)
            and metadata.st_mode & 0o111
            and relative not in expected_executables
            and "_CodeSignature" not in path.parts
        ):
            raise FixtureError("unexpected executable fixture leaf: %s" % relative)

    expected_plists = {
        root / APP_NAME / "Contents" / "Info.plist": {
            "CFBundleExecutable": APP_EXECUTABLE,
            "CFBundleIdentifier": APP_IDENTIFIER,
            "CFBundlePackageType": "APPL",
            "LSMinimumSystemVersion": "27.0",
            "LSUIElement": True,
        },
        root / APP_NAME / "Contents" / "Frameworks" / FRAMEWORK_NAME / "Info.plist": {
            "CFBundleExecutable": FRAMEWORK_EXECUTABLE,
            "CFBundleIdentifier": FRAMEWORK_IDENTIFIER,
            "CFBundlePackageType": "FMWK",
            "LSMinimumSystemVersion": "27.0",
        },
    }
    for plist_path, expected_values in expected_plists.items():
        try:
            with plist_path.open("rb") as stream:
                plist = plistlib.load(stream)
        except (OSError, plistlib.InvalidFileException) as error:
            raise FixtureError("fixture Info.plist is invalid: %s" % plist_path) from error
        if any(plist.get(key) != value for key, value in expected_values.items()):
            raise FixtureError("fixture Info.plist does not match the frozen topology")

    evidence = {}
    lipo_tool = toolchain.tools["lipo"] if toolchain is not None else "/usr/bin/lipo"
    vtool_tool = toolchain.tools["vtool"] if toolchain is not None else None
    dwarfdump_tool = toolchain.tools["dwarfdump"] if toolchain is not None else None
    nm_tool = toolchain.tools["nm"] if toolchain is not None else None
    for spec in _ARTIFACT_SPECS:
        binary = root / spec.binary
        signing_target = root / spec.signing_target
        dsym_binary = root / spec.dsym_binary
        architecture = _run_checked(
            runner, (lipo_tool, "-archs", str(binary)), environment
        ).stdout.strip()
        if architecture != "arm64":
            raise FixtureError("%s architecture must be exactly arm64" % spec.role)
        deployment = _run_checked(
            runner,
            (
                (vtool_tool, "-show-build", str(binary))
                if vtool_tool is not None
                else ("/usr/bin/xcrun", "vtool", "-show-build", str(binary))
            ),
            environment,
        ).stdout
        minimum_os = _first_match(r"^\s*minos\s+(\S+)", deployment, "minimum OS")
        sdk = _first_match(r"^\s*sdk\s+(\S+)", deployment, "SDK")
        if minimum_os not in ("27", "27.0") or sdk.split(".")[0] != "27":
            raise FixtureError("%s must target macOS 27 with SDK 27" % spec.role)

        _run_checked(
            runner,
            ("/usr/bin/codesign", "--verify", "--strict", str(signing_target)),
            environment,
        )
        details_result = _run_checked(
            runner,
            ("/usr/bin/codesign", "-d", "--verbose=4", str(signing_target)),
            environment,
        )
        details = details_result.stderr + details_result.stdout
        identifier = _first_match(r"^Identifier=(.+)$", details, "code identifier")
        signer = _first_match(r"^Authority=(.+)$", details, "signing authority")
        team = _first_match(r"^TeamIdentifier=(.+)$", details, "team identifier")
        if identifier != spec.identifier:
            raise FixtureError("%s code identifier does not match" % spec.role)
        if signer != APPROVED_SIGNER or team != APPROVED_TEAM:
            raise FixtureError("%s signer or team does not match approved policy" % spec.role)
        if re.search(r"CodeDirectory.*\bruntime\b", details) is None:
            raise FixtureError("%s does not carry the hardened-runtime flag" % spec.role)
        cdhash = _first_match(r"^CDHash=([0-9A-Fa-f]+)$", details, "code directory hash")

        requirements_result = _run_checked(
            runner,
            ("/usr/bin/codesign", "-d", "-r-", str(signing_target)),
            environment,
        )
        requirements = requirements_result.stderr + requirements_result.stdout
        parse_exact_designated_requirement(requirements, spec.identifier)
        entitlement_result = _run_checked(
            runner,
            ("/usr/bin/codesign", "-d", "--entitlements", ":-", str(signing_target)),
            environment,
        )
        entitlements = parse_codesign_entitlements(
            entitlement_result.stdout + entitlement_result.stderr
        )
        if entitlements != spec.entitlements:
            raise FixtureError("%s entitlements differ from exact fixture policy" % spec.role)

        binary_uuid_text = _run_checked(
            runner,
            (
                (dwarfdump_tool, "--uuid", str(binary))
                if dwarfdump_tool is not None
                else ("/usr/bin/xcrun", "dwarfdump", "--uuid", str(binary))
            ),
            environment,
        ).stdout
        dsym_uuid_text = _run_checked(
            runner,
            (
                (dwarfdump_tool, "--uuid", str(dsym_binary))
                if dwarfdump_tool is not None
                else ("/usr/bin/xcrun", "dwarfdump", "--uuid", str(dsym_binary))
            ),
            environment,
        ).stdout
        binary_uuid = _first_match(
            r"UUID:\s+([0-9A-Fa-f-]{36})\s+\(arm64\)", binary_uuid_text, "Mach-O UUID"
        )
        dsym_uuid = _first_match(
            r"UUID:\s+([0-9A-Fa-f-]{36})\s+\(arm64\)", dsym_uuid_text, "dSYM UUID"
        )
        if binary_uuid.upper() != dsym_uuid.upper():
            raise FixtureError("%s dSYM UUID does not match its Mach-O" % spec.role)

        preferred_address = None
        if spec.preferred_probe:
            symbols = _run_checked(
                runner,
                (
                    (nm_tool, "-nm", str(binary))
                    if nm_tool is not None
                    else ("/usr/bin/xcrun", "nm", "-nm", str(binary))
                ),
                environment,
            ).stdout
            preferred_address = _first_match(
                r"^([0-9A-Fa-f]{16})\s+\(__MACSCOPE,__probe\)\s+.*"
                r"_macscope_fixture_preferred_probe$",
                symbols,
                "%s preferred probe address" % spec.role,
            ).lower()
        evidence[spec.role] = {
            "path": spec.binary,
            "architecture": architecture,
            "minimumOS": minimum_os,
            "sdk": sdk,
            "identifier": identifier,
            "signer": signer,
            "team": team,
            "runtime": True,
            "cdhash": cdhash.lower(),
            "entitlements": entitlements,
            "uuid": binary_uuid.upper(),
            "dsymUUID": dsym_uuid.upper(),
            "preferredAddress": preferred_address,
        }

    if evidence["app"]["uuid"] == evidence["framework"]["uuid"]:
        raise FixtureError("app and framework Mach-O UUIDs must differ")
    if evidence["app"]["preferredAddress"] != evidence["framework"]["preferredAddress"]:
        raise FixtureError("app and framework preferred probe addresses must collide")
    return evidence


def normalize_manifest(manifest):
    volatile_keys = {
        "buildRoot",
        "builtAt",
        "cdhash",
        "cdhashes",
        "signedHash",
        "signedHashes",
        "signedContainerHashes",
        "cmsHash",
        "cmsHashes",
    }

    def normalize(value):
        if isinstance(value, dict):
            return {
                key: normalize(item)
                for key, item in sorted(value.items())
                if key not in volatile_keys
            }
        if isinstance(value, list):
            return [normalize(item) for item in value]
        return value

    if not isinstance(manifest, dict):
        raise FixtureError("manifest must be a JSON object")
    return normalize(manifest)


def compare_manifests(first, second):
    normalized_first = normalize_manifest(first)
    normalized_second = normalize_manifest(second)
    if normalized_first != normalized_second:
        raise FixtureError("normalized fixture manifests differ")
    return normalized_first


def execute_build(plan: BuildPlan, runner, verifier):
    if plan.staging_root.exists():
        raise FixtureError("staging root already exists")
    if plan.output_root.exists():
        raise FixtureError("accepted output root already exists")

    app_contents = plan.staging_root / APP_NAME / "Contents"
    binary_paths = {
        "app": app_contents / "MacOS" / APP_EXECUTABLE,
        "framework": app_contents / "Frameworks" / FRAMEWORK_NAME / FRAMEWORK_EXECUTABLE,
        "helper": app_contents / "Helpers" / HELPER_EXECUTABLE,
    }
    unsigned_hashes = {}
    try:
        (app_contents / "MacOS").mkdir(parents=True)
        (app_contents / "Helpers").mkdir(parents=True)
        framework_root = app_contents / "Frameworks" / FRAMEWORK_NAME
        framework_root.mkdir(parents=True)
        (plan.staging_root / "Objects").mkdir(parents=True)
        shutil.copy2(plan.source_root / "Resources" / "AppInfo.plist", app_contents / "Info.plist")
        shutil.copy2(
            plan.source_root / "Resources" / "FrameworkInfo.plist",
            framework_root / "Info.plist",
        )

        for step in plan.steps:
            if step.name == "sign-framework":
                unsigned_hashes = {
                    role: _sha256(path) for role, path in sorted(binary_paths.items())
                }
            result = runner(list(step.argv), dict(plan.environment))
            if result.returncode != 0:
                diagnostic = (result.stderr or result.stdout or "command failed").strip()
                raise FixtureError("%s failed: %s" % (step.name, diagnostic))

        for relative_path in plan.required_relative_paths:
            if not (plan.staging_root / relative_path).is_file():
                raise FixtureError("build did not create required leaf: %s" % relative_path)
        verification = verifier(plan.staging_root)
        manifest = {
            "schema": SCHEMA_VERSION,
            "target": TARGET_TRIPLE,
            "toolchain": plan.toolchain.as_manifest() if plan.toolchain is not None else None,
            "requiredPaths": list(plan.required_relative_paths),
            "commands": [
                {"name": name, "argv": list(argv)}
                for name, argv in plan.normalized_commands()
            ],
            "sourceHashes": _hash_tree(plan.source_root, FIXTURE_SOURCE_INPUTS),
            "unsignedHashes": unsigned_hashes,
            "signedHashes": {
                role: _sha256(path) for role, path in sorted(binary_paths.items())
            },
            "verification": verification,
        }
        (plan.staging_root / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        plan.output_root.parent.mkdir(parents=True, exist_ok=True)
        os.replace(str(plan.staging_root), str(plan.output_root))
        return plan.output_root
    except Exception as error:
        shutil.rmtree(plan.staging_root, ignore_errors=True)
        if isinstance(error, FixtureError):
            raise
        raise FixtureError("fixture build failed: %s" % error) from error


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _hash_tree(root: Path, relative_paths=None):
    root = Path(root)
    if relative_paths is not None:
        hashes = {}
        for relative in relative_paths:
            path = root / relative
            try:
                metadata = path.lstat()
            except FileNotFoundError as error:
                raise FixtureError("fixture source input is missing: %s" % relative) from error
            if not stat.S_ISREG(metadata.st_mode):
                raise FixtureError("fixture source input is not a regular file: %s" % relative)
            hashes[relative] = _sha256(path)
        return hashes
    return {
        str(path.relative_to(root)): _sha256(path)
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


@dataclass(frozen=True)
class PlannedCommand:
    name: str
    argv: Tuple[str, ...]


@dataclass(frozen=True)
class BuildPlan:
    source_root: Path
    staging_root: Path
    output_root: Path
    environment: Dict[str, str]
    steps: Tuple[PlannedCommand, ...]
    required_relative_paths: Tuple[str, ...]
    toolchain: Optional[ToolchainEvidence] = None

    def normalized_commands(self) -> Tuple[Tuple[str, Tuple[str, ...]], ...]:
        substitutions = (
            (str(self.source_root), "${SOURCE_ROOT}"),
            (str(self.staging_root), "${STAGING_ROOT}"),
            (str(self.output_root), "${OUTPUT_ROOT}"),
        )

        def normalize(argument: str) -> str:
            for concrete, placeholder in substitutions:
                argument = argument.replace(concrete, placeholder)
            return argument

        return tuple(
            (step.name, tuple(normalize(argument) for argument in step.argv))
            for step in self.steps
        )


def _command(name: str, arguments: Iterable[object]) -> PlannedCommand:
    return PlannedCommand(name=name, argv=tuple(str(argument) for argument in arguments))


def make_build_plan(
    *,
    source_root: Path,
    staging_root: Path,
    output_root: Path,
    developer_directory: Path,
    signing_fingerprint: str,
    toolchain: Optional[ToolchainEvidence] = None,
) -> BuildPlan:
    """Return a stable Xcode-27 build/sign plan without executing it."""

    source_root = Path(source_root)
    staging_root = Path(staging_root)
    output_root = Path(output_root)
    developer_directory = Path(developer_directory)
    if len(signing_fingerprint) != 40 or any(
        character not in "0123456789abcdefABCDEF" for character in signing_fingerprint
    ):
        raise FixtureError("signing fingerprint must be exactly 40 hexadecimal characters")

    sources = source_root / "Sources"
    app = staging_root / APP_NAME
    app_contents = app / "Contents"
    framework = app_contents / "Frameworks" / FRAMEWORK_NAME
    objects = staging_root / "Objects"
    products = {
        "main": app_contents / "MacOS" / APP_EXECUTABLE,
        "helper": app_contents / "Helpers" / HELPER_EXECUTABLE,
        "framework": framework / FRAMEWORK_EXECUTABLE,
    }
    common_compile = (
        "/usr/bin/xcrun",
        "--sdk",
        "macosx",
        "clang",
        "-target",
        TARGET_TRIPLE,
        "-arch",
        "arm64",
        "-g",
        "-O0",
        "-fno-omit-frame-pointer",
        "-fno-inline",
        "-fdebug-prefix-map=%s=/MacScopeFixture/Sources" % source_root,
        "-ffile-prefix-map=%s=/MacScopeFixture/Sources" % source_root,
        "-fdebug-prefix-map=%s=/MacScopeFixture/Build" % staging_root,
        "-ffile-prefix-map=%s=/MacScopeFixture/Build" % staging_root,
    )

    def compile_step(name: str, source: str, output: str) -> PlannedCommand:
        return _command(
            "compile-" + name,
            common_compile + ("-c", sources / source, "-o", objects / output),
        )

    common_link = (
        "/usr/bin/xcrun",
        "--sdk",
        "macosx",
        "clang",
        "-target",
        TARGET_TRIPLE,
        "-arch",
        "arm64",
        "-Wl,-reproducible",
        "-Wl,-no_adhoc_codesign",
        "-Wl,-oso_prefix,%s/" % staging_root,
    )
    dsym = (
        "/usr/bin/xcrun",
        "--sdk",
        "macosx",
        "dsymutil",
        "--oso-prepend-path",
        staging_root,
    )
    sign = (
        "/usr/bin/codesign",
        "--force",
        "--sign",
        signing_fingerprint.upper(),
        "--options",
        "runtime",
        "--timestamp=none",
    )
    steps = (
        compile_step("runtime", "fixture_runtime.c", "fixture_runtime.o"),
        compile_step("main", "main.c", "main.o"),
        compile_step("helper", "helper.c", "helper.o"),
        compile_step("framework", "framework.c", "framework.o"),
        _command(
            "link-framework",
            common_link
            + (
                "-dynamiclib",
                objects / "framework.o",
                "-Wl,-install_name,@rpath/%s/%s" % (FRAMEWORK_NAME, FRAMEWORK_EXECUTABLE),
                "-Wl,-segaddr,__MACSCOPE,0x700000000",
                "-o",
                products["framework"],
            ),
        ),
        _command(
            "link-main",
            common_link
            + (
                objects / "main.o",
                objects / "fixture_runtime.o",
                "-Wl,-rpath,@executable_path/../Frameworks",
                "-Wl,-segaddr,__MACSCOPE,0x700000000",
                "-o",
                products["main"],
            ),
        ),
        _command(
            "link-helper",
            common_link
            + (
                objects / "helper.o",
                objects / "fixture_runtime.o",
                "-Wl,-rpath,@executable_path/../Frameworks",
                "-o",
                products["helper"],
            ),
        ),
        _command(
            "dsym-framework",
            dsym
            + (
                products["framework"],
                "-o",
                staging_root / "MacScopeDebuggerFixtureRuntime.framework.dSYM",
            ),
        ),
        _command(
            "dsym-main",
            dsym
            + (
                products["main"],
                "-o",
                staging_root / "MacScopeDebuggerFixture.app.dSYM",
            ),
        ),
        _command(
            "dsym-helper",
            dsym
            + (
                products["helper"],
                "-o",
                staging_root / "MacScopeDebuggerHelper.dSYM",
            ),
        ),
        _command(
            "sign-framework",
            sign
            + (
                "--identifier",
                FRAMEWORK_IDENTIFIER,
                products["framework"].parent,
            ),
        ),
        _command(
            "sign-helper",
            sign
            + (
                "--entitlements",
                source_root / "Resources" / "DebuggableTarget.entitlements",
                "--identifier",
                HELPER_IDENTIFIER,
                products["helper"],
            ),
        ),
        _command(
            "sign-app",
            sign
            + (
                "--entitlements",
                source_root / "Resources" / "DebuggableTarget.entitlements",
                "--identifier",
                APP_IDENTIFIER,
                app,
            ),
        ),
    )
    return BuildPlan(
        source_root=source_root,
        staging_root=staging_root,
        output_root=output_root,
        environment={"DEVELOPER_DIR": str(developer_directory)},
        steps=steps,
        required_relative_paths=REQUIRED_RELATIVE_PATHS,
        toolchain=toolchain,
    )


def _manifest_path(path: Path) -> Path:
    path = Path(path)
    return path / "manifest.json" if path.is_dir() else path


def _read_manifest(path: Path):
    manifest_path = _manifest_path(path)
    try:
        value = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FixtureError("could not load fixture manifest: %s" % error) from error
    if not isinstance(value, dict):
        raise FixtureError("fixture manifest must contain a JSON object")
    return value


def _default_developer_directory() -> str:
    return os.environ.get(
        "DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"
    )


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fixture_tool.py",
        description="Build and verify the deterministic WS-18 debugger fixture.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    build = subparsers.add_parser("build", help="build, sign, verify, and promote a fixture")
    build.add_argument(
        "--source-root", default=str(Path(__file__).resolve().parent), type=Path
    )
    build.add_argument("--output-root", required=True, type=Path)
    build.add_argument(
        "--developer-directory", default=_default_developer_directory(), type=Path
    )
    build.add_argument(
        "--signing-fingerprint",
        help="explicit approved Apple Development SHA-1 fingerprint for duplicate-subject keychains",
    )

    verify = subparsers.add_parser("verify", help="verify an existing fixture root")
    verify.add_argument("--root", required=True, type=Path)
    verify.add_argument(
        "--developer-directory", default=_default_developer_directory(), type=Path
    )

    compare = subparsers.add_parser("compare", help="compare stable manifest projections")
    compare.add_argument("--first", required=True, type=Path)
    compare.add_argument("--second", required=True, type=Path)
    return parser


def main(argv=None, runner=None) -> int:
    parser = _argument_parser()
    try:
        arguments = parser.parse_args(argv)
    except SystemExit as error:
        return int(error.code)
    runner = runner or SubprocessRunner()
    try:
        if arguments.command == "build":
            output_root = arguments.output_root.expanduser().absolute()
            output_root.parent.mkdir(parents=True, exist_ok=True)
            toolchain = discover_toolchain(arguments.developer_directory, runner)
            identity = resolve_signing_identity(
                runner, approved_fingerprint=arguments.signing_fingerprint
            )
            staging_root = output_root.parent / (
                ".%s.staging-%s" % (output_root.name, uuid.uuid4().hex)
            )
            plan = make_build_plan(
                source_root=arguments.source_root.expanduser().absolute(),
                staging_root=staging_root,
                output_root=output_root,
                developer_directory=arguments.developer_directory,
                signing_fingerprint=identity.fingerprint,
                toolchain=toolchain,
            )
            accepted = execute_build(
                plan,
                runner,
                lambda root: verify_artifacts(
                    root, runner, plan.environment, toolchain=plan.toolchain
                ),
            )
            print(
                json.dumps(
                    {
                        "status": "built",
                        "root": str(accepted),
                        "manifest": str(accepted / "manifest.json"),
                    },
                    sort_keys=True,
                )
            )
            return 0
        if arguments.command == "verify":
            toolchain = discover_toolchain(arguments.developer_directory, runner)
            evidence = verify_artifacts(
                arguments.root,
                runner,
                {"DEVELOPER_DIR": toolchain.developer_directory},
                toolchain=toolchain,
            )
            print(json.dumps({"status": "verified", "artifacts": evidence}, sort_keys=True))
            return 0
        if arguments.command == "compare":
            stable = compare_manifests(
                _read_manifest(arguments.first), _read_manifest(arguments.second)
            )
            digest = hashlib.sha256(
                (json.dumps(stable, sort_keys=True, separators=(",", ":")) + "\n").encode(
                    "utf-8"
                )
            ).hexdigest()
            print(json.dumps({"status": "equal", "stableDigest": digest}, sort_keys=True))
            return 0
        raise FixtureError("unsupported fixture command")
    except FixtureError as error:
        print("fixture_tool.py: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
