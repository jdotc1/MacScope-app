#!/usr/bin/env python3
"""Exact-generation developer run loop for the MacScope app.

The shell entrypoint owns Xcode.  This helper owns only source/build receipts,
LaunchServices readiness, and one explicitly receipted app process.  It never
searches or signals by process name and never adopts an unreceipted process.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
import uuid
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


BUILD_SCHEMA = "macscope.developer-run-build.v1"
PROCESS_SCHEMA = "macscope.developer-run-process.v1"
HANDOFF_SCHEMA = "macscope.developer-run-handoff.v1"
HELPER_CACHE_SCHEMA = "macscope.developer-run-helper-cache.v1"
EXPECTED_BUNDLE_IDENTIFIER = "org.macscope.app"
EXPECTED_EXECUTABLE_NAME = "MacScope"
MAX_RECEIPT_BYTES = 128 * 1024
MAX_HANDOFF_IDENTITY_BYTES = 8 * 1024
DEFAULT_LAUNCH_TIMEOUT_SECONDS = 20.0
DEFAULT_STOP_TIMEOUT_SECONDS = 8.0
DEFAULT_HANDOFF_IDENTITY_TIMEOUT_SECONDS = 5.0
DEFAULT_HANDOFF_ACK_TIMEOUT_SECONDS = 8.0
DEFAULT_HANDOFF_EXIT_TIMEOUT_SECONDS = 10.0
HANDOFF_ACK = b"ACK\n"
HANDOFF_CLEANED_EXIT = 20
HANDOFF_CLEANUP_FAILED_EXIT = 21
POLL_SECONDS = 0.10
TELEMETRY_SUBSYSTEMS = (
    "org.macscope.MacScope",
    "org.macscope.app",
)


class RunLoopError(RuntimeError):
    """The requested action could not prove the exact developer generation."""


class ProcessAPI(Protocol):
    def bsd_info(self, pid: int) -> object:
        ...

    def pid_path(self, pid: int) -> str:
        ...


@dataclass(frozen=True)
class ExactProcess:
    pid: int
    start_seconds: int
    start_microseconds: int
    executable_path: str


def _canonical_json(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _stable_ordinary_file_identity(
    path: Path,
    *,
    label: str,
    require_mode: int | None = None,
    require_executable: bool = False,
) -> dict[str, object]:
    """Hash one non-link single-link file through a stable open descriptor."""

    try:
        before = path.lstat()
    except OSError as error:
        raise RunLoopError(f"{label} is unavailable: {path}: {error}") from error
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise RunLoopError(f"{label} must be an ordinary single-link file: {path}")
    if require_mode is not None and stat.S_IMODE(before.st_mode) != require_mode:
        raise RunLoopError(f"{label} must have mode {require_mode:04o}: {path}")
    if require_executable and before.st_mode & 0o111 == 0:
        raise RunLoopError(f"{label} is not executable: {path}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        opened = os.fstat(descriptor)
        digest = hashlib.sha256()
        size = 0
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            size += len(block)
            digest.update(block)
        after_descriptor = os.fstat(descriptor)
    except OSError as error:
        raise RunLoopError(f"{label} could not be read safely: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    try:
        after = path.lstat()
    except OSError as error:
        raise RunLoopError(f"{label} changed while inspected: {error}") from error
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if size != before.st_size or any(
        getattr(before, field) != getattr(observed, field)
        for observed in (opened, after_descriptor, after)
        for field in stable_fields
    ):
        raise RunLoopError(f"{label} changed while inspected: {path}")
    return {
        "path": str(path.resolve(strict=True)),
        "device": before.st_dev,
        "inode": before.st_ino,
        "size": before.st_size,
        "sha256": digest.hexdigest(),
    }


def _selected_command_identity(path: Path, *, label: str) -> dict[str, object]:
    """Bind an executable command path and its resolved ordinary-file bytes."""

    if not path.is_absolute():
        raise RunLoopError(f"{label} path is not absolute: {path}")
    try:
        before = path.lstat()
        link_target = os.readlink(path) if stat.S_ISLNK(before.st_mode) else None
        resolved = path.resolve(strict=True)
        target = _stable_ordinary_file_identity(
            resolved,
            label=f"resolved {label}",
            require_executable=True,
        )
        after = path.lstat()
        after_link_target = os.readlink(path) if stat.S_ISLNK(after.st_mode) else None
    except OSError as error:
        raise RunLoopError(f"{label} is unavailable or unstable: {error}") from error
    if (
        not (stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode))
        or before.st_nlink != 1
    ):
        raise RunLoopError(f"{label} must select an ordinary executable: {path}")
    selected_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if any(getattr(before, field) != getattr(after, field) for field in selected_fields):
        raise RunLoopError(f"{label} selection changed while inspected: {path}")
    if link_target != after_link_target:
        raise RunLoopError(f"{label} link target changed while inspected: {path}")
    return {
        "path": str(path),
        "linkTarget": link_target,
        "selectedDevice": before.st_dev,
        "selectedInode": before.st_ino,
        "resolved": target,
    }


def _canonical_existing(path: Path, *, directory: bool, label: str) -> Path:
    try:
        if path.is_symlink():
            raise RunLoopError(f"{label} must not be a symbolic link: {path}")
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise RunLoopError(f"{label} is unavailable: {path}: {error}") from error
    if directory and not resolved.is_dir():
        raise RunLoopError(f"{label} must be a directory: {resolved}")
    if not directory and not resolved.is_file():
        raise RunLoopError(f"{label} must be a file: {resolved}")
    return resolved


def _run(
    argv: Sequence[str],
    *,
    cwd: Path | None = None,
    timeout: float = 120.0,
) -> subprocess.CompletedProcess[bytes]:
    try:
        completed = subprocess.run(
            list(argv),
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RunLoopError(f"command failed to execute: {argv[0]}: {error}") from error
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace")[-4096:].strip()
        raise RunLoopError(
            f"command exited {completed.returncode}: {' '.join(argv)}"
            + (f": {detail}" if detail else "")
        )
    return completed


def _git(repository: Path, *arguments: str) -> bytes:
    return _run(("/usr/bin/git", "-C", str(repository), *arguments), timeout=60.0).stdout


def source_identity(repository: Path) -> dict[str, object]:
    """Hash HEAD plus every tracked/untracked byte visible to an Xcode build."""

    repository = _canonical_existing(repository, directory=True, label="repository")
    top = Path(_git(repository, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    if top != repository:
        raise RunLoopError(f"repository path is not the worktree root: {repository}")
    head = _git(repository, "rev-parse", "HEAD").decode().strip()
    head_tree = _git(repository, "rev-parse", "HEAD^{tree}").decode().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", head) or not re.fullmatch(
        r"[0-9a-f]{40}", head_tree
    ):
        raise RunLoopError("Git returned an invalid HEAD or tree identity")

    tracked_diff = _git(
        repository,
        "diff",
        "--binary",
        "--no-ext-diff",
        "--no-textconv",
        "HEAD",
        "--",
        ".",
    )
    untracked_output = _git(
        repository, "ls-files", "--others", "--exclude-standard", "-z", "--", "."
    )
    untracked = sorted(value for value in untracked_output.split(b"\0") if value)
    worktree_digest = hashlib.sha256()
    worktree_digest.update(b"tracked-diff\0")
    worktree_digest.update(len(tracked_diff).to_bytes(8, "big"))
    worktree_digest.update(tracked_diff)
    worktree_digest.update(b"untracked\0")
    for encoded_relative in untracked:
        try:
            relative = encoded_relative.decode("utf-8")
        except UnicodeDecodeError as error:
            raise RunLoopError("an untracked path is not valid UTF-8") from error
        candidate = repository / relative
        if candidate.is_symlink():
            payload = os.readlink(candidate).encode("utf-8")
            kind = b"symlink"
        elif candidate.is_file():
            payload = candidate.read_bytes()
            kind = b"file"
        else:
            raise RunLoopError(f"untracked build input is not a file: {relative}")
        worktree_digest.update(len(encoded_relative).to_bytes(8, "big"))
        worktree_digest.update(encoded_relative)
        worktree_digest.update(kind)
        worktree_digest.update(len(payload).to_bytes(8, "big"))
        worktree_digest.update(payload)

    core = {
        "repositoryRoot": str(repository),
        "head": head,
        "headTree": head_tree,
        "worktreeSha256": worktree_digest.hexdigest(),
        "dirty": bool(tracked_diff or untracked),
    }
    return {**core, "identitySha256": _sha256_bytes(_canonical_json(core))}


def generated_project_identity(repository: Path) -> str:
    """Reuse qualification's closed, symlink-resistant Xcode-project hasher."""

    repository = _canonical_existing(repository, directory=True, label="repository")
    owner_path = repository / "Scripts/qualification/restore_build_source.py"
    owner_path = _canonical_existing(
        owner_path, directory=False, label="generated-project identity owner"
    )
    spec = importlib.util.spec_from_file_location(
        "macscope_runloop_restore_build_source", owner_path
    )
    if spec is None or spec.loader is None:
        raise RunLoopError("generated-project identity owner could not be loaded")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
        identity = module._generated_project_identity(
            repository / "MacScope/MacScope.xcodeproj",
            require_complete=True,
        )
    except (OSError, RuntimeError, ValueError) as error:
        raise RunLoopError(f"generated Xcode project identity failed: {error}") from error
    if not isinstance(identity, str) or not re.fullmatch(r"[0-9a-f]{64}", identity):
        raise RunLoopError("generated Xcode project identity is missing or malformed")
    return identity


def _parse_dependency_config(path: Path) -> dict[str, str]:
    path = _canonical_existing(path, directory=False, label="dependency root config")
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("//") or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Z0-9_]+)\s*=\s*(.*?)\s*", line)
        if match is None:
            raise RunLoopError(f"dependency root config contains an invalid line: {raw_line!r}")
        key, value = match.groups()
        if not value or any(token in value for token in ('"', "'", "$", "//")):
            raise RunLoopError(f"dependency root {key} is empty or indirect")
        if key in values:
            raise RunLoopError(f"dependency root {key} is assigned more than once")
        values[key] = value
    return values


def verify_dependencies(repository: Path, config_path: Path) -> dict[str, object]:
    """Run the existing repository verifiers for every generated build root."""

    repository = _canonical_existing(repository, directory=True, label="repository")
    config_path = _canonical_existing(
        config_path, directory=False, label="dependency root config"
    )
    values = _parse_dependency_config(config_path)
    required = {
        "MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT",
        "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR",
        "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT",
        "MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK",
        "MACSCOPE_SLEIGH_COMPONENT_ROOT",
        "MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT",
        "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT",
        "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT",
    }
    missing = sorted(required - values.keys())
    if missing:
        raise RunLoopError(f"dependency root config is missing: {', '.join(missing)}")

    roots = {key: Path(values[key]) for key in required}
    canonical: dict[str, Path] = {}
    for key, candidate in roots.items():
        canonical[key] = _canonical_existing(
            candidate,
            directory=key != "MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK",
            label=key,
        )

    expected_component = (repository / "ThirdParty/SleighNative").resolve(strict=True)
    if canonical["MACSCOPE_SLEIGH_COMPONENT_ROOT"] != expected_component:
        raise RunLoopError("SLEIGH component root is not the repository-owned component")
    ghostty_work = canonical["MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT"]
    ghostty_source = canonical["MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR"]
    if ghostty_source != ghostty_work / "GhosttySurface":
        raise RunLoopError("Ghostty surface source is incoherent with its work root")
    expected_artifact = ghostty_source / "macos/GhosttyKit.xcframework"
    if canonical["MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT"] != expected_artifact:
        raise RunLoopError("Ghostty surface artifact root is incoherent")
    expected_framework = expected_artifact / "macos-arm64/libghostty-internal.a"
    if canonical["MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK"] != expected_framework:
        raise RunLoopError("Ghostty surface framework is incoherent")
    sleigh_source = canonical["MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT"]
    sleigh_materialization = canonical["MACSCOPE_SLEIGH_MATERIALIZATION_ROOT"]
    if sleigh_materialization != sleigh_source / "materialization":
        raise RunLoopError("SLEIGH materialization is incoherent with its source build")

    _run(
        (
            str(repository / "Scripts/dependencies/build_vendored_ghostty_surface.sh"),
            "--work-root",
            str(ghostty_work),
            "--verify-only",
        ),
        cwd=repository,
        timeout=180.0,
    )
    _run(
        (
            "/usr/bin/python3",
            "-B",
            str(repository / "Scripts/native-decompiler-direct/verify_sleigh_package.py"),
            "verify",
            "--materialization-root",
            str(sleigh_materialization),
        ),
        cwd=repository,
        timeout=180.0,
    )
    observed_sleigh_receipt = _run(
        (
            "/usr/bin/python3",
            "-B",
            str(repository / "Scripts/dependencies/verify_vendored_sleigh_source.py"),
            "package",
            str(sleigh_materialization / "package"),
            "--governed-package",
            str(expected_component / "package"),
        ),
        cwd=repository,
        timeout=180.0,
    ).stdout.strip()
    recorded_sleigh_receipt = _canonical_existing(
        sleigh_source / "SOURCE_BUILD_MATERIALIZATION.json",
        directory=False,
        label="SLEIGH source build receipt",
    ).read_bytes().strip()
    if recorded_sleigh_receipt != observed_sleigh_receipt:
        raise RunLoopError("SLEIGH source build receipt does not match the package")
    _run(
        (
            "/usr/bin/python3",
            "-B",
            str(repository / "Scripts/machokit_source_identity.py"),
            "verify",
            "--materialization-root",
            str(canonical["MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT"]),
            "--quiet",
        ),
        cwd=repository,
        timeout=180.0,
    )

    receipt_paths = (
        ghostty_source / ".git/macscope-vendored-inputs",
        sleigh_source / "SOURCE_BUILD_MATERIALIZATION.json",
        sleigh_materialization / "MATERIALIZATION.json",
        canonical["MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT"] / "MATERIALIZATION.json",
    )
    identity = {
        "configSha256": _sha256_file(config_path),
        "roots": {key: str(canonical[key]) for key in sorted(canonical)},
        "receipts": {
            str(path): _sha256_file(
                _canonical_existing(path, directory=False, label="dependency receipt")
            )
            for path in receipt_paths
        },
    }
    return {**identity, "identitySha256": _sha256_bytes(_canonical_json(identity))}


def atomic_write_receipt(path: Path, value: Mapping[str, object]) -> None:
    requested = path.absolute()
    requested.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if requested.parent.is_symlink():
        raise RunLoopError(f"receipt directory must not be a symbolic link: {requested.parent}")
    parent = requested.parent.resolve(strict=True)
    if not parent.is_dir():
        raise RunLoopError(f"receipt parent must be a directory: {parent}")
    os.chmod(parent, 0o700)
    path = parent / requested.name
    temporary = parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        payload = _canonical_json(dict(value))
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise RunLoopError("receipt write made no progress")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        os.replace(temporary, path)
        directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        directory_descriptor = os.open(parent, directory_flags)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary.exists():
            temporary.unlink()


def load_receipt(path: Path, expected_schema: str) -> dict[str, object]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise RunLoopError(f"receipt is unavailable: {path}: {error}") from error
    if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600:
        raise RunLoopError(f"receipt must be an ordinary mode-0600 file: {path}")
    if metadata.st_size <= 0 or metadata.st_size > MAX_RECEIPT_BYTES:
        raise RunLoopError(f"receipt size is outside the safety bound: {path}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        chunks: list[bytes] = []
        remaining = MAX_RECEIPT_BYTES + 1
        while remaining > 0:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (metadata.st_dev, metadata.st_ino, metadata.st_size) != (
        after.st_dev,
        after.st_ino,
        after.st_size,
    ):
        raise RunLoopError(f"receipt changed while being read: {path}")
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RunLoopError(f"receipt is not valid JSON: {path}: {error}") from error
    if not isinstance(value, dict) or value.get("schema") != expected_schema:
        raise RunLoopError(f"receipt has the wrong schema: {path}")
    if _canonical_json(value) != payload:
        raise RunLoopError(f"receipt is not canonical JSON: {path}")
    return value


def record_build(
    *,
    repository: Path,
    app_bundle: Path,
    executable: Path,
    configuration: str,
    expected_source_identity: str,
    expected_project_identity: str,
    expected_dependency_identity: str,
    receipt_path: Path,
) -> dict[str, object]:
    if not re.fullmatch(r"[0-9a-f]{64}", expected_source_identity):
        raise RunLoopError("expected source identity is invalid")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_project_identity):
        raise RunLoopError("expected generated-project identity is invalid")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_dependency_identity):
        raise RunLoopError("expected dependency identity is invalid")
    repository = _canonical_existing(repository, directory=True, label="repository")
    app_bundle = _canonical_existing(app_bundle, directory=True, label="app bundle")
    executable = _canonical_existing(executable, directory=False, label="app executable")
    expected_executable = app_bundle / "Contents/MacOS" / EXPECTED_EXECUTABLE_NAME
    if executable != expected_executable:
        raise RunLoopError("app executable is outside the exact built bundle location")
    plist_path = _canonical_existing(
        app_bundle / "Contents/Info.plist", directory=False, label="app Info.plist"
    )
    with plist_path.open("rb") as handle:
        metadata = plistlib.load(handle)
    if (
        metadata.get("CFBundleIdentifier") != EXPECTED_BUNDLE_IDENTIFIER
        or metadata.get("CFBundleExecutable") != EXPECTED_EXECUTABLE_NAME
    ):
        raise RunLoopError("built app bundle identity is not MacScope")
    source = source_identity(repository)
    if source["identitySha256"] != expected_source_identity:
        raise RunLoopError("source generation changed while the app was building")
    project_identity = generated_project_identity(repository)
    if project_identity != expected_project_identity:
        raise RunLoopError("generated Xcode project changed while the app was building")
    dependency_contract = verify_dependencies(
        repository, repository / "MacScope/DependencyRoots.local.xcconfig"
    )
    if dependency_contract["identitySha256"] != expected_dependency_identity:
        raise RunLoopError("verified dependency contract changed while the app was building")
    executable_stat = executable.stat()
    receipt: dict[str, object] = {
        "schema": BUILD_SCHEMA,
        "buildGeneration": uuid.uuid4().hex,
        "recordedAtUnixNs": time.time_ns(),
        "repositoryRoot": str(repository),
        "source": source,
        "generatedProjectIdentitySha256": project_identity,
        "dependencyContract": dependency_contract,
        "configuration": configuration,
        "appBundlePath": str(app_bundle),
        "executablePath": str(executable),
        "executableSha256": _sha256_file(executable),
        "executableDevice": executable_stat.st_dev,
        "executableInode": executable_stat.st_ino,
    }
    atomic_write_receipt(receipt_path, receipt)
    return receipt


def validate_build_receipt(path: Path, *, require_current_source: bool = True) -> dict[str, object]:
    receipt = load_receipt(path, BUILD_SCHEMA)
    for key in (
        "repositoryRoot",
        "appBundlePath",
        "executablePath",
        "executableSha256",
        "buildGeneration",
    ):
        if not isinstance(receipt.get(key), str) or not receipt[key]:
            raise RunLoopError(f"build receipt has an invalid {key}")
    repository = _canonical_existing(
        Path(str(receipt["repositoryRoot"])), directory=True, label="build repository"
    )
    app_bundle = _canonical_existing(
        Path(str(receipt["appBundlePath"])), directory=True, label="built app bundle"
    )
    executable = _canonical_existing(
        Path(str(receipt["executablePath"])), directory=False, label="built executable"
    )
    if executable != app_bundle / "Contents/MacOS" / EXPECTED_EXECUTABLE_NAME:
        raise RunLoopError("build receipt executable path is incoherent")
    executable_stat = executable.stat()
    if (
        receipt.get("executableSha256") != _sha256_file(executable)
        or receipt.get("executableDevice") != executable_stat.st_dev
        or receipt.get("executableInode") != executable_stat.st_ino
    ):
        raise RunLoopError("built executable no longer matches its receipt")
    source = receipt.get("source")
    if not isinstance(source, dict) or not isinstance(source.get("identitySha256"), str):
        raise RunLoopError("build receipt source identity is invalid")
    if require_current_source and source_identity(repository) != source:
        raise RunLoopError("current source no longer matches the built generation")
    recorded_project_identity = receipt.get("generatedProjectIdentitySha256")
    if not isinstance(recorded_project_identity, str) or not re.fullmatch(
        r"[0-9a-f]{64}", recorded_project_identity
    ):
        raise RunLoopError("build receipt generated-project identity is invalid")
    if generated_project_identity(repository) != recorded_project_identity:
        raise RunLoopError("generated Xcode project no longer matches the built generation")
    recorded_dependencies = receipt.get("dependencyContract")
    if not isinstance(recorded_dependencies, dict):
        raise RunLoopError("build receipt dependency contract is missing or invalid")
    current_dependencies = verify_dependencies(
        repository, repository / "MacScope/DependencyRoots.local.xcconfig"
    )
    if current_dependencies != recorded_dependencies:
        raise RunLoopError("verified dependency contract no longer matches the built generation")
    return receipt


def _default_process_api() -> ProcessAPI:
    debugger_fixture = Path(__file__).resolve().parent / "debugger-fixture"
    sys.path.insert(0, str(debugger_fixture))
    try:
        from darwin_process_backend import DarwinLibprocAPI  # type: ignore
    finally:
        try:
            sys.path.remove(str(debugger_fixture))
        except ValueError:
            pass
    return DarwinLibprocAPI()


def capture_exact_process(process_api: ProcessAPI, pid: int) -> ExactProcess:
    if type(pid) is not int or pid <= 0:
        raise RunLoopError("process PID must be positive")
    try:
        before = process_api.bsd_info(pid)
        before_path = os.path.realpath(process_api.pid_path(pid))
        after = process_api.bsd_info(pid)
        after_path = os.path.realpath(process_api.pid_path(pid))
    except (OSError, RuntimeError, ValueError) as error:
        raise RunLoopError(f"could not capture exact process {pid}: {error}") from error
    fields = ("pid", "start_seconds", "start_microseconds")
    if any(not hasattr(before, field) or not hasattr(after, field) for field in fields):
        raise RunLoopError("process API returned an incomplete identity")
    identity = (
        int(getattr(before, "pid")),
        int(getattr(before, "start_seconds")),
        int(getattr(before, "start_microseconds")),
    )
    after_identity = (
        int(getattr(after, "pid")),
        int(getattr(after, "start_seconds")),
        int(getattr(after, "start_microseconds")),
    )
    if identity != after_identity or identity[0] != pid or before_path != after_path:
        raise RunLoopError("process identity changed during A-B-A capture")
    if not before_path.startswith("/"):
        raise RunLoopError("process executable path is not absolute")
    return ExactProcess(pid, identity[1], identity[2], before_path)


JXA_RUNNING_APPLICATIONS = r'''
ObjC.import('AppKit');
function run(argv) {
  const identifier = argv[0];
  const values = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(identifier);
  const result = [];
  for (let index = 0; index < values.count; index += 1) {
    const app = values.objectAtIndex(index);
    const executable = app.executableURL;
    result.push({
      pid: Number(app.processIdentifier),
      executablePath: executable ? ObjC.unwrap(executable.path) : null,
      finishedLaunching: Boolean(app.finishedLaunching),
      activationPolicy: Number(app.activationPolicy)
    });
  }
  return JSON.stringify(result);
}
'''


SWIFT_EXACT_LAUNCHER = r'''
import AppKit
import Darwin
import Foundation

private let handoffSchema = "macscope.developer-run-handoff.v1"
private let cleanedExit: Int32 = 20
private let cleanupFailedExit: Int32 = 21

private struct LauncherFailure: Error, CustomStringConvertible {
    let description: String
}

private func writeAll(_ descriptor: Int32, _ payload: Data) throws {
    try payload.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
            guard written > 0 else {
                throw LauncherFailure(description: "write failed: \(String(cString: strerror(errno)))")
            }
            offset += written
        }
    }
}

private func writeRecovery(
    path: String,
    launchNonce: String,
    appBundlePath: String,
    pid: pid_t?,
    executablePath: String?,
    state: String,
    cleanupProved: Bool
) throws {
    var value: [String: Any] = [
        "appBundlePath": appBundlePath,
        "cleanupProved": cleanupProved,
        "handoffState": state,
        "helperPID": Int(getpid()),
        "launchNonce": launchNonce,
        "schema": handoffSchema,
    ]
    if let pid { value["pid"] = Int(pid) }
    if let executablePath { value["executablePath"] = executablePath }
    var payload = try JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    payload.append(0x0a)
    let temporary = path + ".\(getpid()).\(UUID().uuidString).tmp"
    let descriptor = Darwin.open(
        temporary,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
        throw LauncherFailure(description: "recovery receipt open failed")
    }
    do {
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw LauncherFailure(description: "recovery receipt chmod failed")
        }
        try writeAll(descriptor, payload)
        guard Darwin.fsync(descriptor) == 0 else {
            throw LauncherFailure(description: "recovery receipt fsync failed")
        }
        guard Darwin.close(descriptor) == 0 else {
            throw LauncherFailure(description: "recovery receipt close failed")
        }
        guard Darwin.rename(temporary, path) == 0 else {
            throw LauncherFailure(description: "recovery receipt rename failed")
        }
        let parentPath = (path as NSString).deletingLastPathComponent
        let parentDescriptor = Darwin.open(parentPath, O_RDONLY | O_CLOEXEC)
        guard parentDescriptor >= 0 else {
            throw LauncherFailure(description: "recovery directory open failed")
        }
        defer { _ = Darwin.close(parentDescriptor) }
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw LauncherFailure(description: "recovery directory fsync failed")
        }
    } catch {
        _ = Darwin.close(descriptor)
        _ = Darwin.unlink(temporary)
        throw error
    }
}

private func waitForExit(_ application: NSRunningApplication, seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !application.isTerminated && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    return application.isTerminated
}

private func cleanup(_ application: NSRunningApplication) -> Bool {
    if application.isTerminated { return true }
    _ = application.terminate()
    if waitForExit(application, seconds: 2.0) { return true }
    _ = application.forceTerminate()
    return waitForExit(application, seconds: 3.0)
}

@main
struct MacScopeExactLauncher {
    static func main() async {
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        _ = Darwin.signal(SIGINT, SIG_IGN)
        _ = Darwin.signal(SIGTERM, SIG_IGN)
        guard CommandLine.arguments.count == 5,
              let timeout = Double(CommandLine.arguments[3]),
              timeout > 0,
              timeout <= 30,
              CommandLine.arguments[4].count == 32 else {
            FileHandle.standardError.write(Data("invalid launcher arguments\n".utf8))
            Darwin.exit(2)
        }
        let applicationURL = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        ).resolvingSymlinksInPath()
        let recoveryPath = CommandLine.arguments[2]
        let launchNonce = CommandLine.arguments[4]
        do {
            try writeRecovery(
                path: recoveryPath,
                launchNonce: launchNonce,
                appBundlePath: applicationURL.path,
                pid: nil,
                executablePath: nil,
                state: "opening",
                cleanupProved: false
            )
        } catch {
            FileHandle.standardError.write(Data("opening receipt failed: \(error)\n".utf8))
            Darwin.exit(cleanupFailedExit)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        var ownedApplication: NSRunningApplication?
        var executablePath: String?
        do {
            let application = try await NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            ownedApplication = application
            guard let launchedPath = application.executableURL?
                .resolvingSymlinksInPath().path else {
                throw LauncherFailure(description: "launched app has no executable URL")
            }
            executablePath = launchedPath
            try writeRecovery(
                path: recoveryPath,
                launchNonce: launchNonce,
                appBundlePath: applicationURL.path,
                pid: application.processIdentifier,
                executablePath: launchedPath,
                state: "helper-owned",
                cleanupProved: false
            )
            let identity: [String: Any] = [
                "executablePath": launchedPath,
                "pid": Int(application.processIdentifier),
            ]
            var payload = try JSONSerialization.data(
                withJSONObject: identity,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            payload.append(0x0a)
            try writeAll(STDOUT_FILENO, payload)

            var descriptor = pollfd(
                fd: STDIN_FILENO,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let timeoutMilliseconds = Int32(timeout * 1_000)
            let ready = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            guard ready > 0 else {
                throw LauncherFailure(description: "parent ACK timed out")
            }
            var buffer = [UInt8](repeating: 0, count: 16)
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            guard count == 4,
                  Data(buffer[0..<Int(count)]) == Data("ACK\n".utf8) else {
                throw LauncherFailure(description: "parent ACK was absent or invalid")
            }
            try writeRecovery(
                path: recoveryPath,
                launchNonce: launchNonce,
                appBundlePath: applicationURL.path,
                pid: application.processIdentifier,
                executablePath: launchedPath,
                state: "python-owned",
                cleanupProved: false
            )
            ownedApplication = nil
            Darwin.exit(0)
        } catch {
            guard let application = ownedApplication else {
                var noApplicationRecorded = false
                do {
                    try writeRecovery(
                        path: recoveryPath,
                        launchNonce: launchNonce,
                        appBundlePath: applicationURL.path,
                        pid: nil,
                        executablePath: nil,
                        state: "no-application",
                        cleanupProved: true
                    )
                    noApplicationRecorded = true
                } catch {
                    FileHandle.standardError.write(Data("no-application proof failed: \(error)\n".utf8))
                }
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                Darwin.exit(noApplicationRecorded ? cleanedExit : cleanupFailedExit)
            }
            let proved = cleanup(application)
            var recoveryRecorded = false
            do {
                try writeRecovery(
                    path: recoveryPath,
                    launchNonce: launchNonce,
                    appBundlePath: applicationURL.path,
                    pid: application.processIdentifier,
                    executablePath: executablePath,
                    state: proved ? "terminated" : "cleanup-failed",
                    cleanupProved: proved
                )
                recoveryRecorded = true
            } catch {
                FileHandle.standardError.write(Data("recovery proof failed: \(error)\n".utf8))
            }
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(proved && recoveryRecorded ? cleanedExit : cleanupFailedExit)
        }
    }
}
'''


@dataclass(frozen=True)
class CompiledLaunchHelper:
    path: Path
    sha256: str
    cache_key: str


def swift_toolchain_identity() -> dict[str, object]:
    """Bind the helper cache to xcrun's effective Xcode and compiler bytes."""

    xcodebuild_output = _run(
        ("/usr/bin/xcrun", "--find", "xcodebuild"), timeout=10.0
    ).stdout
    xcodebuild_path = Path(xcodebuild_output.decode().strip())
    xcodebuild_identity = _selected_command_identity(
        xcodebuild_path,
        label="effective xcodebuild",
    )
    try:
        developer_candidate = xcodebuild_path.parents[2]
    except IndexError as error:
        raise RunLoopError("xcrun returned an invalid xcodebuild path") from error
    if xcodebuild_path != developer_candidate / "usr/bin/xcodebuild":
        raise RunLoopError("xcrun xcodebuild is outside an effective Developer directory")
    developer_path = _canonical_existing(
        developer_candidate,
        directory=True,
        label="effective Xcode developer directory",
    )
    resolved_xcodebuild = Path(str(xcodebuild_identity["resolved"]["path"]))
    if developer_path not in resolved_xcodebuild.parents:
        raise RunLoopError("effective xcodebuild resolves outside its Developer directory")
    swiftc_output = _run(("/usr/bin/xcrun", "--find", "swiftc"), timeout=10.0).stdout
    swiftc_path = Path(swiftc_output.decode().strip())
    expected_swiftc = (
        developer_path
        / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    )
    try:
        selected_swiftc_parent = swiftc_path.parent.resolve(strict=True)
        expected_swiftc_parent = expected_swiftc.parent.resolve(strict=True)
    except OSError as error:
        raise RunLoopError(f"effective Xcode swiftc path is unavailable: {error}") from error
    if swiftc_path.name != "swiftc" or selected_swiftc_parent != expected_swiftc_parent:
        raise RunLoopError("xcrun did not select the effective Xcode default Swift compiler")
    swiftc_identity = _selected_command_identity(
        swiftc_path,
        label="selected swiftc",
    )
    resolved_swiftc = Path(str(swiftc_identity["resolved"]["path"]))
    if developer_path not in resolved_swiftc.parents:
        raise RunLoopError("xcrun swiftc resolves outside the effective Developer directory")
    core: dict[str, object] = {
        "developerDirectory": str(developer_path),
        "xcodebuild": xcodebuild_identity,
        "xcodeVersion": _run((str(xcodebuild_path), "-version"), timeout=10.0)
        .stdout.decode("utf-8", "strict")
        .strip(),
        "swiftcVersion": _run((str(swiftc_path), "--version"), timeout=10.0)
        .stdout.decode("utf-8", "strict")
        .strip(),
        "swiftc": swiftc_identity,
    }
    return {**core, "identitySha256": _sha256_bytes(_canonical_json(core))}


def _launch_helper_cache_root(repository: Path, override: Path | None = None) -> Path:
    repository = _canonical_existing(repository, directory=True, label="repository")
    requested = override
    if requested is None:
        configured = os.environ.get("MACSCOPE_RUNLOOP_HELPER_CACHE")
        requested = (
            Path(configured)
            if configured
            else Path.home()
            / "Library/Caches/org.macscope.app/DeveloperRunLoopLaunchHelper"
        )
    if not requested.is_absolute():
        raise RunLoopError("launch-helper cache must be an absolute external path")
    requested.mkdir(mode=0o700, parents=True, exist_ok=True)
    if requested.is_symlink():
        raise RunLoopError("launch-helper cache must not be a symbolic link")
    resolved = requested.resolve(strict=True)
    if resolved == repository or repository in resolved.parents:
        raise RunLoopError("launch-helper cache must remain outside the repository")
    if not resolved.is_dir():
        raise RunLoopError("launch-helper cache is not a directory")
    os.chmod(resolved, 0o700)
    return resolved


def _compile_launch_helper(
    swiftc_path: Path,
    source_path: Path,
    output_path: Path,
) -> None:
    _run(
        (
            str(swiftc_path),
            "-parse-as-library",
            str(source_path),
            "-o",
            str(output_path),
        ),
        timeout=180.0,
    )


def _validate_compiled_launch_helper(helper: CompiledLaunchHelper) -> None:
    identity = _stable_ordinary_file_identity(
        helper.path,
        label="compiled launch helper",
        require_mode=0o700,
        require_executable=True,
    )
    if identity["sha256"] != helper.sha256:
        raise RunLoopError("compiled launch helper digest no longer matches its cache receipt")


def ensure_compiled_launch_helper(
    repository: Path,
    *,
    cache_root: Path | None = None,
    source_bytes: bytes | None = None,
    toolchain_identity_provider: Callable[[], Mapping[str, object]] = swift_toolchain_identity,
    compiler: Callable[[Path, Path, Path], None] = _compile_launch_helper,
) -> CompiledLaunchHelper:
    """Return a validated external helper, compiling only on cache-key change.

    The fast path hashes the fixed Swift source and selected Xcode/swiftc identity,
    then validates the cached ordinary executable.  Compilation occurs only when
    either the exact source bytes or exact toolchain identity creates a new key.
    """

    repository = _canonical_existing(repository, directory=True, label="repository")
    root = _launch_helper_cache_root(repository, cache_root)
    source = source_bytes if source_bytes is not None else SWIFT_EXACT_LAUNCHER.encode()
    toolchain = dict(toolchain_identity_provider())
    toolchain_hash = toolchain.get("identitySha256")
    if not isinstance(toolchain_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", toolchain_hash):
        raise RunLoopError("Swift toolchain identity is missing or malformed")
    swiftc = toolchain.get("swiftc")
    if not isinstance(swiftc, dict) or not isinstance(swiftc.get("path"), str):
        raise RunLoopError("Swift toolchain identity does not name swiftc")
    key_input = {
        "sourceSha256": _sha256_bytes(source),
        "toolchain": toolchain,
    }
    cache_key = _sha256_bytes(_canonical_json(key_input))
    key_root = root / cache_key
    key_root.mkdir(mode=0o700, exist_ok=True)
    if key_root.is_symlink() or key_root.resolve(strict=True).parent != root:
        raise RunLoopError("launch-helper cache key directory is unsafe")
    os.chmod(key_root, 0o700)
    executable = key_root / "MacScopeRunLoopLauncher"
    receipt_path = key_root / "cache-receipt.json"
    lock_path = root / f"{cache_key}.lock"
    lock_descriptor = os.open(
        lock_path,
        os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
        if executable.exists() and receipt_path.exists():
            receipt = load_receipt(receipt_path, HELPER_CACHE_SCHEMA)
            if (
                receipt.get("cacheKey") != cache_key
                or receipt.get("sourceSha256") != key_input["sourceSha256"]
                or receipt.get("toolchain") != toolchain
                or receipt.get("executablePath") != str(executable)
                or not isinstance(receipt.get("executableSha256"), str)
            ):
                raise RunLoopError("compiled launch-helper cache receipt is incoherent")
            helper = CompiledLaunchHelper(
                executable, str(receipt["executableSha256"]), cache_key
            )
            _validate_compiled_launch_helper(helper)
            return helper
        if executable.exists() != receipt_path.exists():
            raise RunLoopError("compiled launch-helper cache entry is incomplete")

        nonce = uuid.uuid4().hex
        source_path = key_root / f"launcher.{nonce}.swift"
        output_path = key_root / f"launcher.{nonce}.out"
        source_descriptor = os.open(
            source_path,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        try:
            offset = 0
            while offset < len(source):
                written = os.write(source_descriptor, source[offset:])
                if written <= 0:
                    raise RunLoopError("launch-helper source write made no progress")
                offset += written
            os.fsync(source_descriptor)
        finally:
            os.close(source_descriptor)
        try:
            compiler(Path(str(swiftc["path"])), source_path, output_path)
            post_compile_toolchain = dict(toolchain_identity_provider())
            if post_compile_toolchain != toolchain:
                raise RunLoopError(
                    "Swift toolchain identity changed while compiling the launch helper"
                )
            os.chmod(output_path, 0o700)
            output_identity = _stable_ordinary_file_identity(
                output_path,
                label="new compiled launch helper",
                require_mode=0o700,
                require_executable=True,
            )
            os.replace(output_path, executable)
            os.chmod(executable, 0o700)
            receipt = {
                "schema": HELPER_CACHE_SCHEMA,
                "cacheKey": cache_key,
                "sourceSha256": key_input["sourceSha256"],
                "toolchain": toolchain,
                "executablePath": str(executable),
                "executableSha256": output_identity["sha256"],
            }
            atomic_write_receipt(receipt_path, receipt)
        finally:
            source_path.unlink(missing_ok=True)
            output_path.unlink(missing_ok=True)
        helper = CompiledLaunchHelper(executable, str(receipt["executableSha256"]), cache_key)
        _validate_compiled_launch_helper(helper)
        return helper
    finally:
        fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)


def _handoff_recovery_path(process_receipt_path: Path) -> Path:
    return process_receipt_path.with_name("launch-handoff-recovery.json")


def _handoff_cleanup_is_proved(receipt: Mapping[str, object]) -> bool:
    state = receipt.get("handoffState")
    common_identity_is_valid = (
        isinstance(receipt.get("launchNonce"), str)
        and re.fullmatch(r"[0-9a-f]{32}", str(receipt["launchNonce"])) is not None
        and isinstance(receipt.get("appBundlePath"), str)
        and str(receipt["appBundlePath"]).startswith("/")
        and type(receipt.get("helperPID")) is int
        and int(receipt["helperPID"]) > 0
    )
    if not common_identity_is_valid or receipt.get("cleanupProved") is not True:
        return False
    if state == "no-application":
        return "pid" not in receipt and "executablePath" not in receipt
    return state == "terminated" and type(receipt.get("pid")) is int and int(
        receipt["pid"]
    ) > 0


@dataclass
class LaunchHandoff:
    child: subprocess.Popen[bytes]
    recovery_path: Path
    exit_timeout_seconds: float
    launch_nonce: str
    app_bundle_path: str
    identity: dict[str, object] | None = None
    ack_sent: bool = False
    acknowledged: bool = False

    def _close_stdin(self) -> None:
        if self.child.stdin is not None and not self.child.stdin.closed:
            self.child.stdin.close()

    def _close_outputs(self) -> None:
        for stream in (self.child.stdout, self.child.stderr):
            if stream is not None and not stream.closed:
                stream.close()

    def _terminate_helper(self) -> None:
        if self.child.poll() is not None:
            return
        self.child.terminate()
        try:
            self.child.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            self.child.kill()
            self.child.wait(timeout=1.0)

    def _wait(self, *, terminate_without_cleanup_proof: bool) -> int:
        try:
            return self.child.wait(timeout=self.exit_timeout_seconds)
        except subprocess.TimeoutExpired as error:
            if terminate_without_cleanup_proof:
                self._terminate_helper()
            else:
                try:
                    recovery = self._recovery()
                except RunLoopError as recovery_error:
                    raise RunLoopError(
                        "launch helper remains active before app ownership was resolved; "
                        f"recovery is unverifiable ({recovery_error}); preserve "
                        f"{self.recovery_path}"
                    ) from error
                if _handoff_cleanup_is_proved(recovery):
                    self._terminate_helper()
                    return HANDOFF_CLEANED_EXIT
                raise RunLoopError(
                    "launch helper remains active with unresolved pre-ACK ownership; "
                    f"it was left running and {self.recovery_path} must be preserved"
                ) from error
            raise RunLoopError(
                f"launch helper did not complete cleanup; preserve {self.recovery_path}"
            ) from error

    def _recovery(self) -> dict[str, object]:
        receipt = load_receipt(self.recovery_path, HANDOFF_SCHEMA)
        if (
            receipt.get("launchNonce") != self.launch_nonce
            or receipt.get("appBundlePath") != self.app_bundle_path
        ):
            raise RunLoopError(
                f"launch handoff recovery request is incoherent; preserve {self.recovery_path}"
            )
        helper_pid = receipt.get("helperPID")
        if helper_pid is not None and helper_pid != self.child.pid:
            raise RunLoopError(
                f"launch handoff helper identity is incoherent; preserve {self.recovery_path}"
            )
        if helper_pid is None and receipt.get("handoffState") != "launch-requested":
            raise RunLoopError(
                f"launch handoff recovery lacks helper identity; preserve {self.recovery_path}"
            )
        if self.identity is not None and (
            receipt.get("pid") != self.identity.get("pid")
            or receipt.get("executablePath") != self.identity.get("executablePath")
        ):
            raise RunLoopError(
                f"launch handoff recovery identity is incoherent; preserve {self.recovery_path}"
            )
        return receipt

    def abort(self) -> None:
        """Close the ACK pipe and require helper-proved exact app termination."""

        self._close_stdin()
        try:
            returncode = self._wait(terminate_without_cleanup_proof=False)
        finally:
            self._close_outputs()
        if returncode != HANDOFF_CLEANED_EXIT:
            raise RunLoopError(
                "launch helper could not prove pre-ACK cleanup "
                f"(exit {returncode}); preserve {self.recovery_path}"
            )
        recovery = self._recovery()
        if not _handoff_cleanup_is_proved(recovery):
            raise RunLoopError(
                f"launch helper cleanup proof is invalid; preserve {self.recovery_path}"
            )
        self.recovery_path.unlink()

    def acknowledge(self) -> None:
        """Transfer ownership only after Python has durably receipted the process."""

        if self.child.stdin is None or self.child.stdin.closed:
            raise RunLoopError("launch helper ACK pipe is unavailable")
        try:
            offset = 0
            descriptor = self.child.stdin.fileno()
            while offset < len(HANDOFF_ACK):
                written = os.write(descriptor, HANDOFF_ACK[offset:])
                if written <= 0:
                    raise RunLoopError("launch helper ACK made no progress")
                offset += written
            self.ack_sent = True
        except OSError as error:
            raise RunLoopError(f"launch helper ACK failed: {error}") from error
        finally:
            self._close_stdin()
        try:
            returncode = self._wait(terminate_without_cleanup_proof=True)
        except BaseException:
            self._terminate_helper()
            raise
        finally:
            self._close_outputs()
        if returncode != 0:
            raise RunLoopError(
                f"launch helper rejected ownership ACK (exit {returncode}); "
                f"preserve {self.recovery_path}"
            )
        recovery = self._recovery()
        if (
            recovery.get("handoffState") != "python-owned"
            or recovery.get("cleanupProved") is not False
        ):
            raise RunLoopError(
                f"launch helper ACK receipt is invalid; preserve {self.recovery_path}"
            )
        self.recovery_path.unlink()
        self.acknowledged = True


def begin_launch_handoff(
    app_bundle: Path,
    process_receipt_path: Path,
    repository: Path,
    *,
    compiled_helper: CompiledLaunchHelper | None = None,
    identity_timeout_seconds: float = DEFAULT_HANDOFF_IDENTITY_TIMEOUT_SECONDS,
    ack_timeout_seconds: float = DEFAULT_HANDOFF_ACK_TIMEOUT_SECONDS,
    exit_timeout_seconds: float = DEFAULT_HANDOFF_EXIT_TIMEOUT_SECONDS,
    popen_factory: Callable[..., subprocess.Popen[bytes]] = subprocess.Popen,
    selector_factory: Callable[[], selectors.BaseSelector] = selectors.DefaultSelector,
    monotonic: Callable[[], float] = time.monotonic,
) -> LaunchHandoff:
    """Start the compiled helper and retain helper ownership until explicit ACK."""

    if not 0 < identity_timeout_seconds <= 30 or not 0 < ack_timeout_seconds <= 30:
        raise RunLoopError("launch handoff timeout is outside the safety bound")
    helper = compiled_helper or ensure_compiled_launch_helper(repository)
    _validate_compiled_launch_helper(helper)
    recovery_path = _handoff_recovery_path(process_receipt_path)
    app_bundle_path = os.path.realpath(app_bundle)
    launch_nonce = uuid.uuid4().hex
    process_receipt_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if process_receipt_path.parent.is_symlink():
        raise RunLoopError("launch receipt directory must not be a symbolic link")
    os.chmod(process_receipt_path.parent, 0o700)
    if recovery_path.exists() or recovery_path.is_symlink():
        existing_recovery = load_receipt(recovery_path, HANDOFF_SCHEMA)
        if not _handoff_cleanup_is_proved(existing_recovery):
            raise RunLoopError(
                f"unresolved launch handoff recovery evidence exists: {recovery_path}"
            )
        recovery_path.unlink()
    selector = selector_factory()
    try:
        atomic_write_receipt(
            recovery_path,
            {
                "schema": HANDOFF_SCHEMA,
                "launchNonce": launch_nonce,
                "appBundlePath": app_bundle_path,
                "helperPath": str(helper.path),
                "helperSha256": helper.sha256,
                "handoffState": "launch-requested",
                "cleanupProved": False,
            },
        )
        child = popen_factory(
            [
                str(helper.path),
                app_bundle_path,
                str(recovery_path),
                str(ack_timeout_seconds),
                launch_nonce,
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            close_fds=True,
            bufsize=0,
            start_new_session=True,
        )
    except OSError:
        recovery_path.unlink(missing_ok=True)
        selector.close()
        raise
    except BaseException:
        selector.close()
        raise
    handoff = LaunchHandoff(
        child,
        recovery_path,
        exit_timeout_seconds,
        launch_nonce,
        app_bundle_path,
    )
    if child.stdin is None or child.stdout is None:
        try:
            handoff.abort()
        finally:
            selector.close()
        raise RunLoopError("launch helper pipes are unavailable")
    pending = bytearray()
    deadline = monotonic() + identity_timeout_seconds
    try:
        os.set_blocking(child.stdout.fileno(), False)
        selector.register(child.stdout, selectors.EVENT_READ)
        while monotonic() < deadline:
            events = selector.select(timeout=min(POLL_SECONDS, max(0.0, deadline - monotonic())))
            for key, _ in events:
                chunk = os.read(key.fileobj.fileno(), MAX_HANDOFF_IDENTITY_BYTES + 1)
                if not chunk:
                    raise RunLoopError("launch helper closed before ownership identity")
                pending.extend(chunk)
                if len(pending) > MAX_HANDOFF_IDENTITY_BYTES:
                    raise RunLoopError("launch helper identity exceeds its safety bound")
                newline = pending.find(b"\n")
                if newline >= 0:
                    if pending[newline + 1 :]:
                        raise RunLoopError("launch helper emitted trailing identity bytes")
                    try:
                        value = json.loads(bytes(pending[:newline]))
                    except (UnicodeDecodeError, json.JSONDecodeError) as error:
                        raise RunLoopError(
                            f"launch helper emitted invalid identity JSON: {error}"
                        ) from error
                    if (
                        not isinstance(value, dict)
                        or type(value.get("pid")) is not int
                        or int(value["pid"]) <= 0
                        or not isinstance(value.get("executablePath"), str)
                        or not str(value["executablePath"]).startswith("/")
                    ):
                        raise RunLoopError("launch helper emitted an invalid app identity")
                    handoff.identity = value
                    recovery = handoff._recovery()
                    if (
                        recovery.get("handoffState") != "helper-owned"
                        or recovery.get("cleanupProved") is not False
                    ):
                        raise RunLoopError("launch helper did not persist helper ownership")
                    return handoff
            if child.poll() is not None:
                raise RunLoopError(
                    f"launch helper exited before ownership identity ({child.returncode})"
                )
        if pending:
            raise RunLoopError("launch helper emitted partial identity JSON")
        raise RunLoopError("launch helper ownership identity timed out")
    except BaseException as error:
        cleanup_error: RunLoopError | None = None
        try:
            handoff.abort()
        except RunLoopError as candidate:
            cleanup_error = candidate
        if cleanup_error is not None:
            raise RunLoopError(f"{error}; {cleanup_error}") from error
        if isinstance(error, RunLoopError):
            raise
        if isinstance(error, Exception):
            raise RunLoopError(f"launch handoff failed: {error}") from error
        raise
    finally:
        selector.close()
        child.stdout.close()


def running_applications() -> list[dict[str, object]]:
    payload = _run(
        (
            "/usr/bin/osascript",
            "-l",
            "JavaScript",
            "-e",
            JXA_RUNNING_APPLICATIONS,
            EXPECTED_BUNDLE_IDENTIFIER,
        ),
        timeout=3.0,
    ).stdout
    try:
        decoded = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RunLoopError(f"LaunchServices returned invalid JSON: {error}") from error
    if not isinstance(decoded, list):
        raise RunLoopError("LaunchServices inventory is not an array")
    return [item for item in decoded if isinstance(item, dict)]


def window_count(pid: int) -> int:
    script = (
        "on run argv\n"
        "set targetPID to (item 1 of argv) as integer\n"
        'tell application "System Events"\n'
        "set matches to every application process whose unix id is targetPID\n"
        'if (count of matches) is not 1 then return "missing"\n'
        "return (count of windows of item 1 of matches) as text\n"
        "end tell\n"
        "end run"
    )
    value = _run(
        ("/usr/bin/osascript", "-e", script, str(pid)), timeout=3.0
    ).stdout.decode("utf-8", "replace").strip()
    if value == "missing":
        return 0
    try:
        return max(0, int(value))
    except ValueError as error:
        raise RunLoopError(f"window observation returned an invalid count: {value!r}") from error


def _process_from_receipt(receipt: Mapping[str, object]) -> ExactProcess:
    if (
        type(receipt.get("pid")) is not int
        or type(receipt.get("startSeconds")) is not int
        or type(receipt.get("startMicroseconds")) is not int
        or not isinstance(receipt.get("executablePath"), str)
    ):
        raise RunLoopError("process receipt identity has invalid field types")
    try:
        process = ExactProcess(
            pid=receipt["pid"],
            start_seconds=receipt["startSeconds"],
            start_microseconds=receipt["startMicroseconds"],
            executable_path=str(receipt["executablePath"]),
        )
    except (KeyError, TypeError, ValueError) as error:
        raise RunLoopError("process receipt identity is invalid") from error
    if process.pid <= 0 or process.start_seconds < 0 or not (
        0 <= process.start_microseconds < 1_000_000
    ):
        raise RunLoopError("process receipt identity is outside valid bounds")
    if not process.executable_path.startswith("/"):
        raise RunLoopError("process receipt executable path is not absolute")
    return process


def _same_process(left: ExactProcess, right: ExactProcess) -> bool:
    return left == right


def verify_live_process(
    build_receipt_path: Path,
    process_receipt_path: Path,
    *,
    process_api: ProcessAPI | None = None,
    application_inventory: Callable[[], list[dict[str, object]]] = running_applications,
    count_windows: Callable[[int], int] = window_count,
    require_current_source: bool = True,
) -> dict[str, object]:
    build = validate_build_receipt(
        build_receipt_path, require_current_source=require_current_source
    )
    process = load_receipt(process_receipt_path, PROCESS_SCHEMA)
    if process.get("buildGeneration") != build.get("buildGeneration"):
        raise RunLoopError("running process belongs to a different build generation")
    expected = _process_from_receipt(process)
    if expected.executable_path != build.get("executablePath"):
        raise RunLoopError("process receipt executable does not match the build receipt")
    observed = capture_exact_process(process_api or _default_process_api(), expected.pid)
    if not _same_process(expected, observed):
        raise RunLoopError("running process no longer matches its PID/start/path receipt")
    exact_apps = [
        item
        for item in application_inventory()
        if item.get("pid") == observed.pid
        and item.get("executablePath") == observed.executable_path
    ]
    if len(exact_apps) != 1:
        raise RunLoopError("LaunchServices does not expose exactly one receipted app process")
    application = exact_apps[0]
    if application.get("finishedLaunching") is not True:
        raise RunLoopError("receipted app has not finished launching")
    if application.get("activationPolicy") != 0:
        raise RunLoopError("receipted app does not have regular activation policy")
    windows = count_windows(observed.pid)
    if windows < 1:
        raise RunLoopError("receipted app has no observable first window")
    return {
        "pid": observed.pid,
        "startSeconds": observed.start_seconds,
        "startMicroseconds": observed.start_microseconds,
        "executablePath": observed.executable_path,
        "windowCount": windows,
        "buildGeneration": build["buildGeneration"],
    }


def retire_receipted_process(
    process_receipt_path: Path,
    *,
    process_api: ProcessAPI | None = None,
    signal_process: Callable[[int, int], None] = os.kill,
    sleeper: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
    timeout_seconds: float = DEFAULT_STOP_TIMEOUT_SECONDS,
) -> bool:
    if not process_receipt_path.exists() and not process_receipt_path.is_symlink():
        return False
    receipt = load_receipt(process_receipt_path, PROCESS_SCHEMA)
    expected = _process_from_receipt(receipt)
    stopped = retire_exact_process(
        expected,
        process_api=process_api,
        signal_process=signal_process,
        sleeper=sleeper,
        monotonic=monotonic,
        timeout_seconds=timeout_seconds,
    )
    process_receipt_path.unlink()
    return stopped


def retire_exact_process(
    expected: ExactProcess,
    *,
    process_api: ProcessAPI | None = None,
    signal_process: Callable[[int, int], None] = os.kill,
    sleeper: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
    timeout_seconds: float = DEFAULT_STOP_TIMEOUT_SECONDS,
) -> bool:
    """Terminate only one already captured PID/start/path identity."""

    api = process_api or _default_process_api()
    try:
        observed = capture_exact_process(api, expected.pid)
    except RunLoopError as error:
        cause = error.__cause__
        if isinstance(cause, ProcessLookupError):
            return False
        raise
    if not _same_process(expected, observed):
        raise RunLoopError("refusing to signal a process that does not match its receipt")
    try:
        signal_process(expected.pid, signal.SIGTERM)
    except ProcessLookupError:
        return False
    except OSError as error:
        raise RunLoopError(f"could not signal receipted process: {error}") from error
    deadline = monotonic() + timeout_seconds
    while monotonic() < deadline:
        try:
            current = capture_exact_process(api, expected.pid)
        except RunLoopError as error:
            if isinstance(error.__cause__, ProcessLookupError):
                return True
            raise
        if not _same_process(expected, current):
            raise RunLoopError("process identity changed while waiting for termination")
        sleeper(POLL_SECONDS)
    raise RunLoopError("receipted process did not exit after SIGTERM")


def launch_exact_process(
    build_receipt_path: Path,
    process_receipt_path: Path,
    *,
    process_api: ProcessAPI | None = None,
    application_inventory: Callable[[], list[dict[str, object]]] = running_applications,
    count_windows: Callable[[int], int] = window_count,
    handoff_factory: Callable[[Path, Path, Path], LaunchHandoff] | None = None,
    signal_process: Callable[[int, int], None] = os.kill,
    sleeper: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
    stop_sleeper: Callable[[float], None] = time.sleep,
    stop_monotonic: Callable[[], float] = time.monotonic,
    timeout_seconds: float = DEFAULT_LAUNCH_TIMEOUT_SECONDS,
) -> dict[str, object]:
    build = validate_build_receipt(build_receipt_path)
    retire_receipted_process(
        process_receipt_path,
        process_api=process_api,
        signal_process=signal_process,
        sleeper=stop_sleeper,
        monotonic=stop_monotonic,
    )
    executable_path = str(build["executablePath"])
    app_bundle = Path(str(build["appBundlePath"]))
    repository = Path(str(build["repositoryRoot"]))
    if handoff_factory is None:
        handoff_factory = lambda bundle, receipt, source: begin_launch_handoff(
            bundle,
            receipt,
            source,
            identity_timeout_seconds=min(
                timeout_seconds, DEFAULT_HANDOFF_IDENTITY_TIMEOUT_SECONDS
            ),
            ack_timeout_seconds=min(
                timeout_seconds, DEFAULT_HANDOFF_ACK_TIMEOUT_SECONDS
            ),
        )
    api = process_api or _default_process_api()
    observed: ExactProcess | None = None
    provisional: dict[str, object] | None = None
    handoff: LaunchHandoff | None = None
    try:
        handoff = handoff_factory(app_bundle, process_receipt_path, repository)
        if handoff.identity is None:
            raise RunLoopError("launch helper did not retain an exact app identity")
        owned_pid_value = handoff.identity.get("pid")
        if type(owned_pid_value) is int and owned_pid_value > 0:
            owned_pid = owned_pid_value
            observed = capture_exact_process(api, owned_pid)
        else:
            raise RunLoopError("launch helper did not retain an exact app identity")
        owned_path_value = handoff.identity.get("executablePath")
        if not isinstance(owned_path_value, str) or not owned_path_value.startswith("/"):
            raise RunLoopError("launch helper did not retain an exact app identity")
        owned_path = os.path.realpath(owned_path_value)
        deadline = monotonic() + timeout_seconds
        launched_at_unix_ns = time.time_ns()
        if observed.executable_path != owned_path:
            raise RunLoopError("libproc and launch-helper executable paths disagree")
        if observed.executable_path != executable_path:
            raise RunLoopError("launch helper opened a different executable than the build receipt")
        provisional = {
            "schema": PROCESS_SCHEMA,
            "buildGeneration": build["buildGeneration"],
            "launchedAtUnixNs": launched_at_unix_ns,
            "pid": observed.pid,
            "startSeconds": observed.start_seconds,
            "startMicroseconds": observed.start_microseconds,
            "executablePath": observed.executable_path,
            "finishedLaunching": False,
            "activationPolicy": None,
            "firstWindowReady": False,
        }
        atomic_write_receipt(process_receipt_path, provisional)
        if load_receipt(process_receipt_path, PROCESS_SCHEMA) != provisional:
            raise RunLoopError("provisional process receipt did not round-trip before ACK")
        handoff.acknowledge()
        while monotonic() < deadline:
            exact = [
                item
                for item in application_inventory()
                if item.get("pid") == observed.pid
                and item.get("executablePath") == observed.executable_path
            ]
            if len(exact) > 1:
                raise RunLoopError("LaunchServices returned duplicate records for the owned app")
            if exact:
                item = exact[0]
                candidate = capture_exact_process(api, observed.pid)
                if candidate != observed:
                    raise RunLoopError(
                        "launched process identity changed before first-window readiness"
                    )
                updated = {
                    **provisional,
                    "finishedLaunching": item.get("finishedLaunching") is True,
                    "activationPolicy": item.get("activationPolicy"),
                }
                atomic_write_receipt(process_receipt_path, updated)
                if (
                    item.get("finishedLaunching") is True
                    and item.get("activationPolicy") == 0
                    and count_windows(observed.pid) > 0
                ):
                    receipt = {
                        **updated,
                        "finishedLaunching": True,
                        "activationPolicy": 0,
                        "firstWindowReady": True,
                    }
                    atomic_write_receipt(process_receipt_path, receipt)
                    return receipt
            sleeper(POLL_SECONDS)
        raise RunLoopError("owned exact app process never reached first-window readiness")
    except BaseException as error:
        cleanup_error: RunLoopError | None = None
        cleanup_proved = False
        if handoff is not None and not handoff.ack_sent:
            try:
                handoff.abort()
                cleanup_proved = True
            except RunLoopError as candidate:
                cleanup_error = candidate
        if not cleanup_proved and observed is not None:
            try:
                retire_exact_process(
                    observed,
                    process_api=api,
                    signal_process=signal_process,
                    sleeper=stop_sleeper,
                    monotonic=stop_monotonic,
                )
                cleanup_proved = True
                cleanup_error = None
            except RunLoopError as candidate:
                cleanup_error = candidate
        if cleanup_proved:
            try:
                process_receipt_path.unlink(missing_ok=True)
                _handoff_recovery_path(process_receipt_path).unlink(missing_ok=True)
            except OSError as candidate:
                cleanup_error = RunLoopError(
                    f"exact app exit was proved but cleanup evidence could not be retired: {candidate}"
                )
        elif provisional is not None and not process_receipt_path.exists():
            try:
                atomic_write_receipt(
                    process_receipt_path,
                    {**provisional, "cleanupUnproved": True},
                )
            except (OSError, RunLoopError):
                pass
        if cleanup_error is not None:
            recovery = _handoff_recovery_path(process_receipt_path)
            raise RunLoopError(
                f"{error}; exact launch cleanup is unproved: {cleanup_error}; "
                f"preserve {process_receipt_path} and {recovery}"
            ) from error
        if isinstance(error, RunLoopError):
            raise
        if isinstance(error, Exception):
            raise RunLoopError(f"launch receipt/readiness failed: {error}") from error
        raise


def diagnostic_command(mode: str, pid: int) -> list[str]:
    if mode == "logs":
        predicate = f"processID == {pid}"
    elif mode == "telemetry":
        subsystems = " || ".join(f'subsystem == "{value}"' for value in TELEMETRY_SUBSYSTEMS)
        predicate = f"processID == {pid} && ({subsystems}) && category != nil"
    else:
        raise RunLoopError(f"unsupported diagnostic mode: {mode}")
    return [
        "/usr/bin/log",
        "stream",
        "--style",
        "ndjson",
        "--info",
        "--debug",
        "--predicate",
        predicate,
    ]


def _diagnostic_target_is_live(
    process_api: ProcessAPI,
    expected: ExactProcess,
) -> bool:
    """Return false once the receipted PID/start/path generation has ended."""

    try:
        observed = capture_exact_process(process_api, expected.pid)
    except RunLoopError as error:
        if isinstance(error.__cause__, ProcessLookupError):
            return False
        if "identity changed during A-B-A capture" in str(error):
            return False
        raise
    return _same_process(expected, observed)


def _stop_diagnostic_child(child: subprocess.Popen[bytes]) -> None:
    """Boundedly stop only the log-stream child created by this invocation."""

    if child.poll() is not None:
        return
    try:
        child.terminate()
        child.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=2.0)
    except ProcessLookupError:
        return


def supervise_diagnostics(
    mode: str,
    build_receipt_path: Path,
    process_receipt_path: Path,
    *,
    process_api: ProcessAPI | None = None,
    application_inventory: Callable[[], list[dict[str, object]]] = running_applications,
    count_windows: Callable[[int], int] = window_count,
    popen_factory: Callable[..., subprocess.Popen[bytes]] = subprocess.Popen,
    selector_factory: Callable[[], selectors.BaseSelector] = selectors.DefaultSelector,
    output: object | None = None,
    poll_seconds: float = POLL_SECONDS,
) -> int:
    """Proxy diagnostics only while one exact PID/start/path generation lives.

    ``log stream`` can outlive the process named by a PID predicate and can then
    observe a reused PID.  Keep ownership of the stream child, revalidate the
    full libproc identity around every read, and never forward bytes obtained
    after that identity has ended.
    """

    if poll_seconds <= 0:
        raise RunLoopError("diagnostic poll interval must be positive")
    api = process_api or _default_process_api()
    proof = verify_live_process(
        build_receipt_path,
        process_receipt_path,
        process_api=api,
        application_inventory=application_inventory,
        count_windows=count_windows,
    )
    process_receipt = load_receipt(process_receipt_path, PROCESS_SCHEMA)
    expected = _process_from_receipt(process_receipt)
    if (
        proof.get("pid") != expected.pid
        or proof.get("startSeconds") != expected.start_seconds
        or proof.get("startMicroseconds") != expected.start_microseconds
        or proof.get("executablePath") != expected.executable_path
    ):
        raise RunLoopError("diagnostic proof does not match the process receipt")

    destination = output if output is not None else sys.stdout.buffer
    if not hasattr(destination, "write") or not hasattr(destination, "flush"):
        raise RunLoopError("diagnostic output is not writable")
    command = diagnostic_command(mode, expected.pid)
    try:
        selector = selector_factory()
    except OSError as error:
        raise RunLoopError(f"could not create diagnostic selector: {error}") from error
    try:
        child = popen_factory(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=None,
            close_fds=True,
            bufsize=0,
        )
    except OSError as error:
        selector.close()
        raise RunLoopError(f"could not start diagnostic stream: {error}") from error
    if child.stdout is None:
        try:
            _stop_diagnostic_child(child)
        finally:
            selector.close()
        raise RunLoopError("diagnostic stream has no standard output pipe")

    pending = bytearray()
    try:
        os.set_blocking(child.stdout.fileno(), False)
        selector.register(child.stdout, selectors.EVENT_READ)
        while True:
            if not _diagnostic_target_is_live(api, expected):
                return 0
            status = child.poll()
            if status is not None:
                if status != 0:
                    raise RunLoopError(f"diagnostic stream exited {status}")
                return 0
            events = selector.select(timeout=poll_seconds)
            for key, _ in events:
                if not _diagnostic_target_is_live(api, expected):
                    return 0
                try:
                    chunk = os.read(key.fileobj.fileno(), 64 * 1024)
                except BlockingIOError:
                    continue
                if not chunk:
                    status = child.poll()
                    if status is None:
                        raise RunLoopError("diagnostic stream closed its output unexpectedly")
                    if status != 0:
                        raise RunLoopError(f"diagnostic stream exited {status}")
                    return 0
                if not _diagnostic_target_is_live(api, expected):
                    return 0
                pending.extend(chunk)
                while True:
                    newline = pending.find(b"\n")
                    if newline < 0:
                        break
                    if not _diagnostic_target_is_live(api, expected):
                        return 0
                    line = bytes(pending[: newline + 1])
                    del pending[: newline + 1]
                    destination.write(line)
                    destination.flush()
    finally:
        try:
            selector.close()
        finally:
            _stop_diagnostic_child(child)
            child.stdout.close()


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    source_parser = subparsers.add_parser("source-identity")
    source_parser.add_argument("--repository", required=True, type=Path)

    project_parser = subparsers.add_parser("generated-project-identity")
    project_parser.add_argument("--repository", required=True, type=Path)

    dependency_parser = subparsers.add_parser("verify-dependencies")
    dependency_parser.add_argument("--repository", required=True, type=Path)
    dependency_parser.add_argument("--config", required=True, type=Path)

    record_parser = subparsers.add_parser("record-build")
    record_parser.add_argument("--repository", required=True, type=Path)
    record_parser.add_argument("--app-bundle", required=True, type=Path)
    record_parser.add_argument("--executable", required=True, type=Path)
    record_parser.add_argument("--configuration", required=True)
    record_parser.add_argument("--expected-source-identity", required=True)
    record_parser.add_argument("--expected-project-identity", required=True)
    record_parser.add_argument("--expected-dependency-identity", required=True)
    record_parser.add_argument("--build-receipt", required=True, type=Path)

    for command in ("verify-build", "launch", "verify", "logs", "telemetry"):
        command_parser = subparsers.add_parser(command)
        command_parser.add_argument("--build-receipt", required=True, type=Path)
        if command != "verify-build":
            command_parser.add_argument("--process-receipt", required=True, type=Path)
        if command == "launch":
            command_parser.add_argument(
                "--timeout", type=float, default=DEFAULT_LAUNCH_TIMEOUT_SECONDS
            )

    stop_parser = subparsers.add_parser("stop")
    stop_parser.add_argument("--process-receipt", required=True, type=Path)
    stop_parser.add_argument("--timeout", type=float, default=DEFAULT_STOP_TIMEOUT_SECONDS)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.command == "source-identity":
            print(source_identity(arguments.repository)["identitySha256"])
        elif arguments.command == "generated-project-identity":
            print(generated_project_identity(arguments.repository))
        elif arguments.command == "verify-dependencies":
            print(verify_dependencies(arguments.repository, arguments.config)["identitySha256"])
        elif arguments.command == "record-build":
            receipt = record_build(
                repository=arguments.repository,
                app_bundle=arguments.app_bundle,
                executable=arguments.executable,
                configuration=arguments.configuration,
                expected_source_identity=arguments.expected_source_identity,
                expected_project_identity=arguments.expected_project_identity,
                expected_dependency_identity=arguments.expected_dependency_identity,
                receipt_path=arguments.build_receipt,
            )
            print(receipt["buildGeneration"])
        elif arguments.command == "verify-build":
            receipt = validate_build_receipt(arguments.build_receipt)
            print(receipt["executablePath"])
        elif arguments.command == "launch":
            if not 0 < arguments.timeout <= 120:
                raise RunLoopError("launch timeout is outside the safety bound")
            receipt = launch_exact_process(
                arguments.build_receipt,
                arguments.process_receipt,
                timeout_seconds=arguments.timeout,
            )
            print(f"MacScope ready: pid={receipt['pid']} generation={receipt['buildGeneration']}")
        elif arguments.command == "stop":
            if not 0 < arguments.timeout <= 60:
                raise RunLoopError("stop timeout is outside the safety bound")
            stopped = retire_receipted_process(
                arguments.process_receipt, timeout_seconds=arguments.timeout
            )
            print("MacScope stopped" if stopped else "No receipted MacScope process is running")
        elif arguments.command == "verify":
            proof = verify_live_process(
                arguments.build_receipt, arguments.process_receipt
            )
            print(json.dumps(proof, sort_keys=True, separators=(",", ":")))
        else:
            return supervise_diagnostics(
                arguments.command,
                arguments.build_receipt,
                arguments.process_receipt,
            )
    except RunLoopError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
