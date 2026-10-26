#!/usr/bin/env python3
"""Single-invocation native CTest evidence and non-executing physical replay.

The runner owns its remaining link checks. Only its subsequent ``finalize``
call may publish favorable evidence; an execution record is diagnostic only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

REPOSITORY = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPOSITORY), str(REPOSITORY / "Scripts/native-decompiler-direct"),
                str(Path(__file__).resolve().parent)]
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes, decode_canonical_bytes
import native_decompiler_source_identity as source_identity
import sleigh_package
import sleigh_sanitizer_profile

MAX_BYTES = 16 * 1024 * 1024
MAX_FILES = 1024
PREFIX = "macscope_native_decompiler_"
PLAIN_TESTS = (
    "contract_tests", "canonical_request_tests", "provider_tests",
    "ghidra_package_identity_tests", "opcode_vocabulary_binding_tests",
    "ghidra_provider_location_tests",
)
PROVIDER_SCENARIOS = (
    "apple-profile-readiness", "target-normalization", "pac-output", "pac-memory",
    "pac-control", "hidden-pac-contrast", "pac-bounds", "pac-cancellation",
    "authored-names-and-direct-calls", "authored-complete-type-catalog",
    "authored-signature-merge-matrix", "authored-applied-noncode-objects",
    "authored-atomic-unsupported", "authored-application-cancellation",
    "authored-parameter-storage",
)
PRODUCER_COMMON = (
    "Scripts/native-decompiler-xpc/native_qualification_report.py",
    "Scripts/native-decompiler-xpc/native_decompiler_source_identity.py",
    "Scripts/native-decompiler-xpc/build_native_bridge.sh",
    "Scripts/native-decompiler-direct/verify_sleigh_package.py",
    "Scripts/native-decompiler-direct/sleigh_package.py",
    "Scripts/native-decompiler-direct/sleigh_sanitizer_profile.py",
    "Scripts/reconstruction_gate_f/__init__.py",
    "Scripts/reconstruction_gate_f/schema.py",
    "Scripts/reconstruction_gate_f/canonical_json.py",
    "Scripts/dependencies/build_vendored_sleigh_native_source.sh",
    "Scripts/dependencies/verify_vendored_sleigh_source.py",
    "Scripts/dependencies/verify_vendored_sleigh_native.py",
)
BASE_PRODUCTS = (
    "libmacscope_native_decompiler_contract.a",
    "generated/MacScopeNativeDecompiler/GhidraBuildIdentity.hpp",
    "CMakeCache.txt", "build.ninja", "compile_commands.json",
)
NORMAL_EARLY = ("macscope_native_decompiler_relocatable_link_probe",)
NORMAL_FINAL = (
    "macscope-native-decompiler-link-inputs.xcfilelist",
    "macscope-native-decompiler-link-probe-inspection.txt",
    "macscope-native-decompiler-link-probe.otool-l.txt",
    "macscope-native-decompiler-link-probe.otool-L.txt",
)
REPORT_FIELDS = {
    "schema_version", "record_kind", "profile", "build_root", "wrapper_source_sha256",
    "producer_files", "toolchain", "configuration", "architecture", "deployment_target",
    "products", "dependency_evidence",
}
EXECUTION_FIELDS = {
    "schema_version", "record_kind", "profile", "build_root", "started_at_unix_ms",
    "ended_at_unix_ms", "exit_code", "inventory", "junit", "input_snapshot", "tests",
}
TOOLCHAIN_FIELDS = {
    "developer_dir", "compiler", "compiler_version", "sdk_root", "sdk_settings", "cmake", "ctest",
    "cmake_version", "ctest_version",
}


class NativeReportError(ValueError):
    """Evidence is missing, unsafe, changed, or inconsistent with its producer."""


def producer_paths(profile: str) -> tuple[str, ...]:
    _profile(profile)
    runner = "build_native_bridge.sh" if profile == "none" else "run_native_bridge_sanitizers.sh"
    return tuple(sorted(set((*PRODUCER_COMMON, "Scripts/native-decompiler-xpc/" + runner))))


def _profile(value: str) -> None:
    if not isinstance(value, str) or value not in {"none", "address", "undefined"}:
        raise NativeReportError("unknown native profile")


def _closed(value: object, fields: set[str], label: str) -> dict:
    if not isinstance(value, dict) or set(value) != fields:
        raise NativeReportError(label + " has unknown or missing fields")
    return value


def _integer(value: object, *, nonnegative: bool = True) -> int:
    if type(value) is not int or not -(2**63) <= value < 2**63 or (nonnegative and value < 0):
        raise NativeReportError("invalid integer in native evidence")
    return value


def _text(value: object, limit: int = 4096) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > limit or "\x00" in value:
        raise NativeReportError("invalid bounded text in native evidence")
    return value


def _path(value: Path | str, *, directory: bool = False) -> Path:
    path = Path(value)
    if not path.is_absolute() or str(path) != str(value) or ".." in path.parts:
        raise NativeReportError("physical paths must be canonical absolute paths")
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        metadata = current.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise NativeReportError("physical path contains a symlink")
    metadata = path.lstat()
    if directory:
        if not stat.S_ISDIR(metadata.st_mode):
            raise NativeReportError("physical root must be an ordinary directory")
    elif not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise NativeReportError("physical evidence must be an ordinary single-link file")
    if path.resolve(strict=True) != path:
        raise NativeReportError("physical path is aliased")
    return path


def _bytes(path: Path, limit: int = MAX_BYTES) -> bytes:
    path = _path(path)
    before = path.lstat()
    if before.st_size > limit:
        raise NativeReportError("native evidence exceeds its size limit")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if not source_identity._metadata_equal(before, opened):
            raise NativeReportError("native evidence changed before reading")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            payload = stream.read(limit + 1)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if len(payload) > limit or not source_identity._metadata_equal(before, after) or not source_identity._metadata_equal(before, path.lstat()):
        raise NativeReportError("native evidence changed while reading")
    return payload


def _external(path: Path) -> dict:
    path = _path(path)
    before = path.lstat()
    digest = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        if not source_identity._metadata_equal(before, os.fstat(descriptor)):
            raise NativeReportError("product changed before hashing")
        while block := os.read(descriptor, 1024 * 1024):
            digest.update(block)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if not source_identity._metadata_equal(before, after) or not source_identity._metadata_equal(before, path.lstat()):
        raise NativeReportError("product changed during hashing")
    return {"absolute_path": str(path), "byte_count": before.st_size, "sha256": digest.hexdigest()}


def _selected_tool(path: Path, kind: str) -> tuple:
    """Narrow selected-tool aliases; all evidence paths still use _path."""
    if not path.is_absolute() or ".." in path.parts:
        raise NativeReportError("selected tool path must be canonical absolute")
    _path(path.parent, directory=True)
    before = path.lstat()
    target = path
    alias = None
    if stat.S_ISLNK(before.st_mode):
        alias = os.readlink(path)
        if before.st_nlink != 1:
            raise NativeReportError("selected tool alias has multiple links")
        if kind == "compiler" and path.name == "clang++" and alias == "clang":
            target = path.parent / "clang"
        elif kind in {"cmake", "ctest"} and path.name == kind and path.parent.name == "bin" and re.fullmatch(
                r"\.\./Cellar/cmake/[0-9]+(?:\.[0-9]+){1,3}(?:_[0-9]+)?/bin/" + kind, alias):
            target = Path(os.path.normpath(str(path.parent / alias)))
        else:
            raise NativeReportError("selected tool has an undeclared alias")
    resolved_before = _path(target).lstat()
    reference = _external(target)
    if not source_identity._metadata_equal(resolved_before, target.lstat()):
        raise NativeReportError("selected tool executable changed during observation")
    after = path.lstat()
    if not source_identity._metadata_equal(before, after) or (alias is not None and os.readlink(path) != alias):
        raise NativeReportError("selected tool alias changed during observation")
    metadata = (before.st_dev, before.st_ino, before.st_mode, before.st_nlink,
                before.st_size, before.st_mtime_ns, before.st_ctime_ns)
    resolved = resolved_before
    identity = (resolved.st_dev, resolved.st_ino, resolved.st_mode, resolved.st_nlink,
                resolved.st_size, resolved.st_mtime_ns, resolved.st_ctime_ns)
    return reference, (metadata, alias, identity)


def _file_ref(path: Path, report: Path) -> dict:
    external = _external(path)
    return {"relative_path": path.relative_to(report).as_posix(),
            "byte_count": external["byte_count"], "sha256": external["sha256"]}


def _reference_path(value: object, root: Path | None = None, expected: Path | None = None) -> Path:
    """Check reference shape/admission without reading a report-selected path."""
    field = "relative_path" if root is not None else "absolute_path"
    ref = _closed(value, {field, "byte_count", "sha256"}, "file reference")
    _integer(ref["byte_count"])
    if not isinstance(ref["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", ref["sha256"]):
        raise NativeReportError("invalid SHA-256")
    text = _text(ref[field])
    if root is not None:
        relative = Path(text)
        if relative.is_absolute() or text != relative.as_posix() or any(v in {".", ".."} for v in relative.parts):
            raise NativeReportError("unsafe report-relative path")
        path = root / relative
    else:
        path = Path(text)
        if not path.is_absolute() or str(path) != text or ".." in path.parts:
            raise NativeReportError("unsafe external path")
    if expected is not None and path != expected:
        raise NativeReportError("file reference is outside its fixed producer inventory")
    return path


def _verify_ref(value: object, root: Path | None = None, expected: Path | None = None) -> Path:
    path = _reference_path(value, root, expected)
    observed = _file_ref(path, root) if root is not None else _external(path)
    if value != observed:
        raise NativeReportError("physical file differs from retained reference")
    return path


def _write(path: Path, payload: bytes) -> None:
    _path(path.parent, directory=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())


def _load(path: Path) -> dict:
    value = decode_canonical_bytes(_bytes(path))
    if not isinstance(value, dict):
        raise NativeReportError("native document must be an object")
    return value


def _raw_json(payload: bytes) -> object:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise NativeReportError("duplicate JSON key")
            result[key] = value
        return result
    def constant(value):
        raise NativeReportError("non-finite JSON value")
    try:
        return json.loads(payload.decode("utf-8"), object_pairs_hook=pairs, parse_constant=constant)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise NativeReportError("invalid JSON input") from error


def _commands(build: Path) -> dict[str, list[str]]:
    values = {PREFIX + suffix: [str(build / (PREFIX + suffix))] for suffix in PLAIN_TESTS}
    provider = PREFIX + "ghidra_provider_tests"
    values[provider] = [str(build / provider), "--scenario-group", "core"]
    for scenario in PROVIDER_SCENARIOS:
        values[PREFIX + "ghidra_provider_" + scenario.replace("-", "_") + "_tests"] = [str(build / provider), "--scenario", scenario]
    return dict(sorted(values.items()))


def _inventory(payload: bytes, build: Path) -> list[dict]:
    if len(payload) > MAX_BYTES:
        raise NativeReportError("CTest inventory exceeded its byte bound")
    value = _raw_json(payload)
    if not isinstance(value, dict) or value.get("kind") != "ctestInfo":
        raise NativeReportError("unsupported CTest json-v1 inventory")
    version = _closed(value.get("version"), {"major", "minor"}, "CTest inventory version")
    if _integer(version["major"]) != 1 or _integer(version["minor"]) != 0:
        raise NativeReportError("unsupported CTest json-v1 inventory")
    tests = value.get("tests")
    if not isinstance(tests, list) or not 0 < len(tests) <= MAX_FILES:
        raise NativeReportError("CTest inventory must be bounded and nonempty")
    expected = _commands(build)
    seen = set()
    rows = []
    for test in tests:
        if not isinstance(test, dict):
            raise NativeReportError("invalid CTest registration")
        name = _text(test.get("name"), 256)
        argv = test.get("command")
        if not isinstance(argv, list) or not argv or len(argv) > MAX_FILES:
            raise NativeReportError("invalid CTest argv")
        for argument in argv:
            _text(argument)
        if name in seen or name not in expected or argv != expected[name]:
            raise NativeReportError("CTest registration differs from the frozen name/argv mapping")
        seen.add(name)
        properties = test.get("properties", [])
        if not isinstance(properties, list) or len(properties) > MAX_FILES:
            raise NativeReportError("invalid CTest properties")
        for prop in properties:
            if not isinstance(prop, dict) or set(prop) != {"name", "value"}:
                raise NativeReportError("invalid CTest property")
            if prop["name"] == "DISABLED" and not (prop["value"] is False or type(prop["value"]) is str and prop["value"] in {"FALSE", "OFF", "0"}):
                raise NativeReportError("disabled CTest registration")
        executable = _path(Path(argv[0]))
        if build not in executable.parents or not os.access(executable, os.X_OK):
            raise NativeReportError("CTest executable is outside the build root or not executable")
        rows.append({"name": name, "argv": argv, "executable": _external(executable), "status": "not-run"})
    if seen != set(expected):
        raise NativeReportError("CTest inventory differs from all 21 frozen registrations")
    return sorted(rows, key=lambda row: row["name"])


def _duration(value: str) -> None:
    try:
        parsed = float(value)
    except ValueError as error:
        raise NativeReportError("invalid JUnit duration") from error
    if not math.isfinite(parsed) or parsed < 0:
        raise NativeReportError("non-finite or negative JUnit duration")


def _count(element: ET.Element, name: str, expected: int) -> None:
    if name in element.attrib:
        value = element.attrib[name]
        if not re.fullmatch(r"[0-9]+", value) or len(value) > 12 or int(value) != expected:
            raise NativeReportError("contradictory JUnit " + name + " count")


def _junit(payload: bytes, names: set[str]) -> dict[str, str]:
    if len(payload) > MAX_BYTES or b"<!DOCTYPE" in payload.upper() or b"<!ENTITY" in payload.upper():
        raise NativeReportError("JUnit DTD/entity declarations or oversized input are forbidden")
    try:
        text = payload.decode("utf-8")
        root = ET.fromstring(text)
    except (ET.ParseError, UnicodeError) as error:
        raise NativeReportError("malformed JUnit") from error
    if root.tag == "testsuite":
        suites = [root]
    elif root.tag == "testsuites" and all(child.tag == "testsuite" for child in root):
        suites = list(root)
    else:
        raise NativeReportError("unsupported JUnit root")
    outcomes = {}
    counts = {"tests": 0, "failures": 0, "errors": 0, "skipped": 0, "disabled": 0}
    for suite in suites:
        local = dict.fromkeys(counts, 0)
        if "time" in suite.attrib:
            _duration(suite.attrib["time"])
        for case in suite:
            if case.tag in {"properties", "system-out", "system-err"}:
                continue
            if case.tag != "testcase":
                raise NativeReportError("unsupported JUnit suite child")
            name = _text(case.get("name"), 256)
            if name not in names or name in outcomes:
                raise NativeReportError("duplicate or unknown JUnit identity")
            _duration(case.get("time", "0"))
            status = case.get("status", "run")
            if status not in {"run", "notrun", "disabled"}:
                raise NativeReportError("unsupported JUnit testcase status")
            children = [child.tag for child in case]
            if any(tag not in {"failure", "error", "skipped", "system-out", "system-err", "properties"} for tag in children):
                raise NativeReportError("unsupported JUnit testcase child")
            if any(children.count(tag) > 1 for tag in ("failure", "error", "skipped")) or sum(tag in children for tag in ("failure", "error", "skipped")) > 1:
                raise NativeReportError("contradictory JUnit testcase outcomes")
            failed = "failure" in children or "error" in children
            skipped = "skipped" in children
            if status != "run" and (failed or skipped):
                raise NativeReportError("contradictory JUnit testcase status")
            for key in ("failures", "errors", "skipped", "disabled"):
                observed = int((key == "failures" and "failure" in children) or (key == "errors" and "error" in children) or (key == "skipped" and skipped) or (key == "disabled" and status == "disabled"))
                _count(case, key, observed)
                local[key] += observed
            outcome = "failed" if failed else "skipped" if skipped or status == "disabled" else "not-run" if status == "notrun" else "passed"
            outcomes[name] = outcome
            local["tests"] += 1
        for key, number in local.items():
            _count(suite, key, number)
            counts[key] += number
    if root.tag == "testsuites":
        for key, number in counts.items():
            _count(root, key, number)
        if "time" in root.attrib:
            _duration(root.attrib["time"])
    if set(outcomes) != names:
        raise NativeReportError("JUnit does not contain all 21 exact test cases")
    return outcomes


def _cache(build: Path) -> dict[str, str]:
    values = {}
    for line in _bytes(build / "CMakeCache.txt").decode("utf-8").splitlines():
        if not line or line.startswith(("#", "//")):
            continue
        match = re.fullmatch(r"([^:=]+):[^=]+=(.*)", line)
        if not match or match[1] in values:
            raise NativeReportError("ambiguous CMakeCache")
        values[match[1]] = match[2]
    return values


def _capture(argv: list[str], limit: int = MAX_BYTES, env: dict | None = None) -> bytes:
    # No new session/process group: the outer executor owns cancellation.
    with subprocess.Popen(argv, stdout=subprocess.PIPE, env=env) as child:
        chunks = []
        size = 0
        try:
            while block := child.stdout.read(65536):
                size += len(block)
                if size > limit:
                    raise NativeReportError("producer tool output exceeded its bound")
                chunks.append(block)
            code = child.wait()
        except BaseException:
            child.kill()
            child.wait()
            raise
        if code:
            raise NativeReportError("producer tool probe failed")
    return b"".join(chunks)


def _version(path: Path, env: dict, prefix: str) -> str:
    kind = {"Apple clang version ": "compiler", "cmake version ": "cmake", "ctest version ": "ctest"}[prefix]
    selection = _selected_tool(path, kind)
    value = _capture([str(path), "--version"], 65536, env).decode("utf-8").splitlines()[0]
    if _selected_tool(path, kind) != selection:
        raise NativeReportError("selected tool changed during version observation")
    if not value.startswith(prefix):
        raise NativeReportError("unexpected producer tool version")
    return _text(value, 4096)


def _bridge_profile(build: Path, repository: Path, profile: str, compiler: Path, sdk: Path) -> None:
    commands = _raw_json(_bytes(build / "compile_commands.json"))
    if not isinstance(commands, list) or not 0 < len(commands) <= 100000:
        raise NativeReportError("bridge compile commands must be a bounded nonempty array")
    required = {Path(argv[0]).name for argv in _commands(build).values()} | {"macscope_native_decompiler_contract"}
    seen = set()
    for entry in commands:
        if not isinstance(entry, dict):
            raise NativeReportError("invalid bridge compile command")
        argv = entry.get("arguments")
        if argv is None:
            argv = shlex.split(_text(entry.get("command"), MAX_BYTES))
        if not isinstance(argv, list) or not argv or len(argv) > 4096:
            raise NativeReportError("invalid bridge compile arguments")
        for argument in argv:
            _text(argument)
        if Path(argv[0]) != compiler or any(arg.startswith(("@", "-Xclang", "-mllvm", "-fno-sanitize=", "-fno-sanitize-address", "-fsanitize-ignorelist", "-fsanitize-blacklist")) for arg in argv):
            raise NativeReportError("unchecked bridge compiler or profile override")
        for option, expected in (("-arch", "arm64"), ("-isysroot", str(sdk))):
            if argv.count(option) != 1 or argv.index(option) + 1 >= len(argv) or argv[argv.index(option) + 1] != expected:
                raise NativeReportError("bridge compile architecture or SDK differs")
        if [arg for arg in argv if arg.startswith("-mmacosx-version-min=")] != ["-mmacosx-version-min=27.0"]:
            raise NativeReportError("bridge compile deployment target differs")
        sanitizer = [arg for arg in argv if arg.startswith("-fsanitize=")]
        if sanitizer != ([] if profile == "none" else ["-fsanitize=" + profile]):
            raise NativeReportError("bridge compile profile differs")
        if profile != "none":
            for required_flag in sleigh_package.SANITIZER_FLAGS[profile]:
                if required_flag not in argv:
                    raise NativeReportError("bridge compile sanitizer flag missing")
            if profile == "undefined" and any(arg.startswith("-fsanitize-recover") for arg in argv):
                raise NativeReportError("bridge compile enables undefined recovery")
        if "-c" not in argv or argv.count("-o") != 1 or argv.index("-o") + 1 >= len(argv):
            raise NativeReportError("bridge compile command lacks its object")
        output = argv[argv.index("-o") + 1]
        matches = [name for name in required if "CMakeFiles/" + name + ".dir/" in output]
        seen.update(matches)
    if seen != required:
        raise NativeReportError("bridge compile commands omit executed native targets")


def _roots(repository: Path, build: Path, material: Path, developer: Path) -> tuple[Path, Path, Path, Path]:
    roots = tuple(_path(p, directory=True) for p in (repository, build, material, developer))
    repository, build, material, developer = roots
    if repository == build or repository in build.parents or build in repository.parents or material == build or material in build.parents:
        raise NativeReportError("build root must be separate from source and materialization")
    return roots


def _sanitizer_archive_replay(material: Path, commands_path: Path, instrumentation: dict,
                              compiler: Path, sdk: Path) -> None:
    """Recheck schema-3 object/member closure without nm or any subprocess.

    Admit the same effective profile requirements before any producer tool
    probe. The existing strict inspector additionally observes nm symbols;
    replay checks commands and every admitted object/member without executing.
    """
    # Retain this report boundary's generic JSON/argument bounds; effective
    # sanitizer-profile interpretation belongs solely to the shared helper.
    commands = _raw_json(_bytes(commands_path))
    if not isinstance(commands, list) or not 0 < len(commands) <= sleigh_package.MAX_FILES:
        raise NativeReportError("invalid sanitizer compile-command inventory")
    for entry in commands:
        if not isinstance(entry, dict):
            raise NativeReportError("invalid sanitizer compile command")
        argv = entry.get("arguments")
        if argv is None:
            argv = shlex.split(_text(entry.get("command"), MAX_BYTES))
        if not isinstance(argv, list) or not argv or len(argv) > 4096:
            raise NativeReportError("invalid sanitizer compile argv")
        for argument in argv:
            _text(argument)
    _path(commands_path.parent, directory=True)
    admitted = sleigh_sanitizer_profile.admit_sanitizer_compile_commands(
        commands_path, compiler, sdk, instrumentation["profile"])
    objects = {target: {name: _external(path)["sha256"] for name, path in members.items()}
               for target, members in admitted.items()}
    for target, relative in sleigh_package.SANITIZER_ARCHIVES.items():
        members = objects[target]
        if not members or len(members) != instrumentation["translationUnitCounts"][target]:
            raise NativeReportError("sanitizer translation-unit count differs")
        archive = _path(material / "package" / relative)
        before = _external(archive)
        observed = sleigh_sanitizer_profile._native_archive_member_digests(archive)
        if observed != members or _external(archive) != before or before["sha256"] != instrumentation["archiveSha256"][relative]:
            raise NativeReportError("sanitizer archive member bytes differ from admitted objects")


def _snapshot(*, repository_root: Path, build_root: Path, materialization_root: Path,
              profile: str, developer_dir: Path, final: bool, observe: bool,
              recorded_toolchain: dict | None = None, actual_ctest: Path | None = None) -> dict:
    _profile(profile)
    repository, build, material, developer = _roots(repository_root, build_root, materialization_root, developer_dir)
    cache = _cache(build)
    digest = source_identity.profile_digest(repository, "wrapper")
    expected = {"CMAKE_BUILD_TYPE": "Release" if profile == "none" else "RelWithDebInfo",
                "CMAKE_OSX_ARCHITECTURES": "arm64", "CMAKE_OSX_DEPLOYMENT_TARGET": "27.0",
                "CMAKE_EXPORT_COMPILE_COMMANDS": "ON", "BUILD_TESTING": "ON",
                "MACSCOPE_ENABLE_GHIDRA_PROVIDER": "ON", "MACSCOPE_ENABLE_SLEIGH_DECOMP_API_PROBE": "OFF",
                "MACSCOPE_NATIVE_DECOMPILER_WRAPPER_GIT_REVISION": digest,
                "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT": str(material),
                "CMAKE_HOME_DIRECTORY": str(repository / "Tools/NativeDecompilerBridge"),
                "CMAKE_CACHEFILE_DIR": str(build)}
    for key, value in expected.items():
        if cache.get(key) != value:
            raise NativeReportError("CMakeCache differs from governed configuration: " + key)
    if cache.get("MACSCOPE_NATIVE_DECOMPILER_SANITIZER", "none") != profile:
        raise NativeReportError("CMakeCache native profile differs")
    compiler = Path(_text(cache.get("CMAKE_CXX_COMPILER")))
    compiler_selection = _selected_tool(compiler, "compiler")
    sdk = _path(Path(_text(cache.get("CMAKE_OSX_SYSROOT"))), directory=True)
    if developer not in compiler.parents or developer not in sdk.parents:
        raise NativeReportError("selected compiler/SDK are outside the developer directory")
    cmake = Path(_text(cache.get("CMAKE_COMMAND")))
    ctest = Path(_text(cache.get("CMAKE_CTEST_COMMAND")))
    selections = {compiler: ("compiler", compiler_selection),
        cmake: ("cmake", _selected_tool(cmake, "cmake")), ctest: ("ctest", _selected_tool(ctest, "ctest"))}
    actual_selection = _selected_tool(actual_ctest, "ctest") if actual_ctest is not None else None
    if actual_selection is not None and actual_selection[0] != selections[ctest][1][0]:
        raise NativeReportError("actual CTest differs from the CMakeCache binding")
    _bridge_profile(build, repository, profile, compiler, sdk)
    toolchain = {"developer_dir": str(developer), "compiler": compiler_selection[0], "sdk_root": str(sdk),
                 "sdk_settings": _external(sdk / "SDKSettings.json"), "cmake": selections[cmake][1][0], "ctest": selections[ctest][1][0]}
    dependency = [material / "MATERIALIZATION.json", material / "package/lib/libdecomp.a", material / "package/lib/libsla.a"]
    package = sleigh_package.verify_materialization(material, expected_sanitizer=profile)
    if profile == "none":
        dependency.append(sdk / "usr/lib/libz.tbd")
    else:
        publication = build / "native-source" / ("SleighNativeSource-" + profile)
        if material != publication / "materialization":
            raise NativeReportError("sanitizer materialization is outside its owned publication")
        commands_path = publication / "build/compile_commands.json"
        dependency += [publication / "SOURCE_BUILD_MATERIALIZATION.json", commands_path]
        instrumentation = package["sourceBuild"]["instrumentation"]
        if (_external(commands_path)["sha256"] != instrumentation["compileCommandsSha256"]
                or instrumentation["sdkRoot"] != str(sdk)
                or instrumentation["sdkSettingsSha256"] != toolchain["sdk_settings"]["sha256"]
                or package["sourceBuild"]["toolchain"]["compiler"]["path"] != toolchain["compiler"]["absolute_path"]
                or package["sourceBuild"]["toolchain"]["compiler"]["sha256"] != toolchain["compiler"]["sha256"]):
            raise NativeReportError("sanitizer package compiler/SDK/commands drift")
        _sanitizer_archive_replay(material, commands_path, instrumentation, compiler, sdk)
    product_paths = {Path(argv[0]) for argv in _commands(build).values()}
    product_paths.update(build / relative for relative in BASE_PRODUCTS)
    if profile == "none":
        product_paths.update(build / relative for relative in NORMAL_EARLY)
        if final:
            product_paths.update(build / relative for relative in NORMAL_FINAL)
    snapshot = {"schema_version": 1, "record_kind": "macscope-native-input-snapshot", "profile": profile,
            "build_root": str(build), "wrapper_source_sha256": digest,
            "producer_files": [_external(repository / relative) for relative in producer_paths(profile)],
            "toolchain": toolchain, "configuration": expected["CMAKE_BUILD_TYPE"], "architecture": "arm64",
            "deployment_target": "27.0", "products": [_external(path) for path in sorted(product_paths)],
            "dependency_evidence": [_external(path) for path in sorted(dependency)]}
    # Admit the complete physical source/product/package/tool closure before
    # executing even a version probe. Tool versions are observations only after
    # their paths, bytes, configuration and dependency profile have passed.
    if observe:
        xcodebuild = _path(developer / "usr/bin/xcodebuild")
        executables = {compiler, cmake, ctest, xcodebuild, *(Path(argv[0]) for argv in _commands(build).values())}
        if any(not os.access(path, os.X_OK) for path in executables):
            raise NativeReportError("admitted native tool or test product is not executable")
        env = {**os.environ, "DEVELOPER_DIR": str(developer)}
        xcode = _capture([str(xcodebuild), "-version"], 65536, env).decode("utf-8")
        if not re.match(r"Xcode 27(?:\.|\s|$)", xcode):
            raise NativeReportError("native qualification requires Xcode 27")
        toolchain.update(compiler_version=_version(compiler, env, "Apple clang version "),
                         cmake_version=_version(cmake, env, "cmake version "),
                         ctest_version=_version(ctest, env, "ctest version "))
    else:
        recorded = _closed(recorded_toolchain, TOOLCHAIN_FIELDS, "toolchain")
        for key, prefix in (("compiler_version", "Apple clang version "), ("cmake_version", "cmake version "), ("ctest_version", "ctest version ")):
            text = _text(recorded[key])
            if not text.startswith(prefix):
                raise NativeReportError("invalid recorded tool version")
            toolchain[key] = text
    if profile != "none":
        if package["sourceBuild"]["toolchain"]["compiler"]["version"] != toolchain["compiler_version"]:
            raise NativeReportError("sanitizer source compiler version differs")
        if observe:
            inspected = sleigh_sanitizer_profile.inspect_sanitizer_build(material / "package", commands_path, compiler, sdk, profile)
            if inspected != instrumentation:
                raise NativeReportError("sanitizer archive inspection differs from schema-3 identity")
    if observe:
        verifier = repository / "Scripts/native-decompiler-direct/verify_sleigh_package.py"
        argv = [sys.executable, "-B", str(verifier), "verify", "--materialization-root", str(material), "--expected-sanitizer", profile]
        if profile != "none":
            argv += ["--compile-commands", str(commands_path), "--compiler", str(compiler), "--sdk-root", str(sdk)]
        _capture(argv, env=env)
    if (any(_selected_tool(path, kind) != selection for path, (kind, selection) in selections.items())
            or (actual_selection is not None and _selected_tool(actual_ctest, "ctest") != actual_selection)):
        raise NativeReportError("selected tool identity changed during native observation")
    return snapshot


def _document(value: dict, *, kind: str) -> None:
    fields = REPORT_FIELDS | ({"ctest"} if kind == "qualification" else set())
    _closed(value, fields, "native " + kind)
    if type(value["schema_version"]) is not int or value["schema_version"] != 1 or value["record_kind"] != "macscope-native-" + kind:
        raise NativeReportError("invalid native schema/kind")
    _profile(value["profile"])
    toolchain = _closed(value["toolchain"], TOOLCHAIN_FIELDS, "toolchain")
    for field in ("compiler", "sdk_settings", "cmake", "ctest"):
        _reference_path(toolchain[field])
    for field in ("developer_dir", "sdk_root", "compiler_version", "cmake_version", "ctest_version"):
        _text(toolchain[field])
    for field in ("build_root", "wrapper_source_sha256", "configuration", "architecture", "deployment_target"):
        _text(value[field])
    for key in ("producer_files", "products", "dependency_evidence"):
        refs = value[key]
        if not isinstance(refs, list) or not 0 < len(refs) <= MAX_FILES:
            raise NativeReportError("invalid external reference list")
        paths = []
        for ref in refs:
            paths.append(str(_reference_path(ref)))
        if paths != sorted(set(paths)):
            raise NativeReportError("external references must be sorted and unique")


def _execution(report: Path, build: Path, profile: str) -> tuple[dict, dict]:
    value = _load(report / "ctest.execution.json")
    _closed(value, EXECUTION_FIELDS, "CTest execution")
    if type(value["schema_version"]) is not int or value["schema_version"] != 1 or value["record_kind"] != "macscope-native-ctest-execution" or value["profile"] != profile or value["build_root"] != str(build):
        raise NativeReportError("invalid CTest execution identity")
    started = _integer(value["started_at_unix_ms"])
    ended = _integer(value["ended_at_unix_ms"])
    if ended < started or ended > time.time_ns() // 1000000 or _integer(value["exit_code"], nonnegative=False) != 0:
        raise NativeReportError("CTest failed or has an invalid execution interval")
    inventory_path = _verify_ref(value["inventory"], report, report / "ctest.inventory.json")
    junit_path = _verify_ref(value["junit"], report, report / "ctest.junit.xml")
    snapshot_path = _verify_ref(value["input_snapshot"], report, report / "native-inputs.json")
    rows = _inventory(_bytes(inventory_path), build)
    outcomes = _junit(_bytes(junit_path), set(_commands(build)))
    if any(status != "passed" for status in outcomes.values()):
        raise NativeReportError("all 21 native outcomes must pass without skips")
    for row in rows:
        row["status"] = outcomes[row["name"]]
    tests = value["tests"]
    if not isinstance(tests, list) or len(tests) != len(rows):
        raise NativeReportError("invalid normalized native tests")
    for test in tests:
        test = _closed(test, {"name", "argv", "executable", "status"}, "native test")
        name = _text(test["name"], 256)
        expected = _commands(build).get(name)
        if expected is None or not isinstance(test["argv"], list) or test["argv"] != expected:
            raise NativeReportError("native test differs from its frozen argv")
        for argument in test["argv"]:
            _text(argument)
        if not isinstance(test["status"], str) or test["status"] not in {"passed", "failed", "skipped", "not-run"}:
            raise NativeReportError("invalid native test status")
        _reference_path(test["executable"], expected=Path(expected[0]))
    if value["tests"] != rows:
        raise NativeReportError("retained normalized tests differ from raw inventory/JUnit/executables")
    snapshot = _load(snapshot_path)
    _document(snapshot, kind="input-snapshot")
    return value, snapshot


def run_ctest(*, repository_root: Path, ctest: Path, build_root: Path,
              report_dir: Path, materialization_root: Path, profile: str,
              developer_dir: Path, jobs: int) -> int:
    _profile(profile)
    _integer(jobs)
    if not 0 < jobs <= 4096:
        raise NativeReportError("native CTest jobs must be positive and bounded")
    _roots(repository_root, build_root, materialization_root, developer_dir)
    if not report_dir.is_absolute() or report_dir.parent != build_root:
        raise NativeReportError("report directory must be an absent direct child of the owned build root")
    if report_dir.exists() or report_dir.is_symlink():
        raise FileExistsError("native report directory already exists")
    snapshot = _snapshot(repository_root=repository_root, build_root=build_root, materialization_root=materialization_root,
                         profile=profile, developer_dir=developer_dir, final=False, observe=True, actual_ctest=ctest)
    ctest_selection = _selected_tool(ctest, "ctest")
    if ctest_selection[0] != snapshot["toolchain"]["ctest"]:
        raise NativeReportError("selected CTest changed before invocation")
    report_dir.mkdir(mode=0o700)  # Exclusive reservation; failures never overwrite diagnostics.
    inventory = _capture([str(ctest), "--test-dir", str(build_root), "--show-only=json-v1"])
    if _selected_tool(ctest, "ctest") != ctest_selection:
        raise NativeReportError("selected CTest changed during inventory observation")
    _write(report_dir / "ctest.inventory.json", inventory)
    rows = _inventory(inventory, build_root)
    _write(report_dir / "native-inputs.json", canonical_bytes(snapshot))
    inventory_ref = _file_ref(report_dir / "ctest.inventory.json", report_dir)
    snapshot_ref = _file_ref(report_dir / "native-inputs.json", report_dir)
    started = time.time_ns() // 1000000
    env = {**os.environ, "DEVELOPER_DIR": str(developer_dir)}
    if profile == "address":
        env["ASAN_OPTIONS"] = "detect_leaks=0:halt_on_error=1:abort_on_error=1"
    elif profile == "undefined":
        env["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
    # Inherit stdout/stderr and the executor's process group. There is exactly
    # one test execution, with no filters, retries, detached child, or rerun.
    if _selected_tool(ctest, "ctest") != ctest_selection:
        raise NativeReportError("selected CTest changed before test invocation")
    code = subprocess.run([str(ctest), "--test-dir", str(build_root), "--parallel", str(jobs),
                           "--output-on-failure", "--no-tests=error", "--output-junit",
                           str(report_dir / "ctest.junit.xml")], env=env, check=False).returncode
    if _selected_tool(ctest, "ctest") != ctest_selection:
        raise NativeReportError("selected CTest changed during invocation")
    ended = time.time_ns() // 1000000
    junit = None
    try:
        payload = _bytes(report_dir / "ctest.junit.xml")
        junit = _file_ref(report_dir / "ctest.junit.xml", report_dir)
        outcomes = _junit(payload, {row["name"] for row in rows})
        for row in rows:
            row["status"] = outcomes[row["name"]]
    except (OSError, ValueError, RuntimeError):
        pass  # Preserve the actual exit, raw diagnostics and not-run outcomes.
    execution = {"schema_version": 1, "record_kind": "macscope-native-ctest-execution",
                 "profile": profile, "build_root": str(build_root), "started_at_unix_ms": started,
                 "ended_at_unix_ms": ended, "exit_code": code,
                 "inventory": inventory_ref,
                 "junit": junit, "input_snapshot": snapshot_ref, "tests": rows}
    _write(report_dir / "ctest.execution.json", canonical_bytes(execution))
    return code


def finalize_native_qualification(*, repository_root: Path, build_root: Path,
                                  report_dir: Path, materialization_root: Path,
                                  profile: str, developer_dir: Path) -> Path:
    _path(report_dir, directory=True)
    if report_dir.parent != build_root:
        raise NativeReportError("report root is outside the owned build root")
    _, before = _execution(report_dir, build_root, profile)
    inputs = dict(repository_root=repository_root, build_root=build_root,
                  materialization_root=materialization_root, profile=profile, developer_dir=developer_dir)
    observed = _snapshot(**inputs, final=False, observe=True)
    if before != observed:
        raise NativeReportError("native input snapshot changed during execution")
    final = _snapshot(**inputs, final=True, observe=False, recorded_toolchain=before["toolchain"])
    final["record_kind"] = "macscope-native-qualification"
    final["ctest"] = _file_ref(report_dir / "ctest.execution.json", report_dir)
    path = report_dir / "native-qualification.json"
    _write(path, canonical_bytes(final))
    try:
        validate_native_report(report_path=path, repository_root=repository_root, build_root=build_root,
                               materialization_root=materialization_root, expected_profile=profile, developer_dir=developer_dir)
    except BaseException:
        # Only this newly created publication belongs to this producer. Preserve
        # every earlier diagnostic and never leave favorable failed evidence.
        path.unlink()
        raise
    return path


def validate_native_report(*, report_path: Path, repository_root: Path,
                           build_root: Path, materialization_root: Path,
                           expected_profile: str, developer_dir: Path) -> dict[str, object]:
    _profile(expected_profile)
    _roots(repository_root, build_root, materialization_root, developer_dir)
    report = _path(report_path.parent, directory=True)
    if report.parent != build_root or report_path.name != "native-qualification.json":
        raise NativeReportError("final native report is outside its fixed build/report layout")
    value = _load(report_path)
    _document(value, kind="qualification")
    _verify_ref(value["ctest"], report, report / "ctest.execution.json")
    _, before = _execution(report, build_root, expected_profile)
    inputs = dict(repository_root=repository_root, build_root=build_root, materialization_root=materialization_root,
                  profile=expected_profile, developer_dir=developer_dir, observe=False, recorded_toolchain=before["toolchain"])
    if before != _snapshot(**inputs, final=False):
        raise NativeReportError("physical native inputs no longer match the pre-test snapshot")
    observed = _snapshot(**inputs, final=True)
    observed["record_kind"] = "macscope-native-qualification"
    observed["ctest"] = _file_ref(report / "ctest.execution.json", report)
    if value != observed:
        raise NativeReportError("final native report differs from current physical evidence")
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("run-ctest", "finalize"):
        child = commands.add_parser(command)
        for option in ("repository-root", "build-root", "report-dir", "materialization-root", "developer-dir"):
            child.add_argument("--" + option, required=True, type=Path)
        child.add_argument("--profile", required=True, choices=("none", "address", "undefined"))
        if command == "run-ctest":
            child.add_argument("--ctest", required=True, type=Path)
            child.add_argument("--jobs", required=True, type=int)
    args = vars(parser.parse_args(argv))
    command = args.pop("command")
    try:
        if command == "run-ctest":
            code = run_ctest(**args)
            return code if code >= 0 else 128 - code
        path = finalize_native_qualification(**args)
        print("MACSCOPE_NATIVE_QUALIFICATION_REPORT=" + str(path))
        return 0
    except (OSError, ValueError, RuntimeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
