#!/usr/bin/env python3
"""Debug-only reuse stamps for MacScope's always-run Xcode script phases.

Several verification phases deliberately run on every build because Xcode's
timestamp graph cannot represent everything they check (whole directory trees,
Git authority, signing identity, the effective build environment).  In routine
Debug edit/build cycles their inputs almost never change, yet the phases cost
seconds each (REA re-reads ~400 Git blobs, Ghostty VT re-hashes ~48k toolchain
and source leaves).

This helper lets such a phase stay always-run while skipping its expensive body
when nothing it reads has changed since the last successful run in the same
target's DerivedData:

* ``check PHASE`` exits 0 only when a stamp exists whose input key equals the
  key computed now and whose recorded output fingerprint still matches the
  outputs on disk.  Otherwise it records the pre-run input key in a pending file
  and exits 1, and the caller runs the full phase body.
* ``record PHASE`` (called only after the full body succeeded) recomputes the
  input key and publishes the stamp only if it still equals the pending pre-run
  key, so inputs edited while the phase ran are never certified.

The input key binds: the phase name and helper schema; the helper itself; the
generated project file (which holds every phase's script text); the complete
script-phase environment (signing identity, SDK, toolchain, dependency roots,
target, configuration; minus Xcode's per-build LLBUILD_* scheduler ids); lstat identity (device, inode, mode, owner, flags,
link count, size, mtime_ns, ctime_ns, symlink target) of every declared input
file and of every entry under every declared input tree; and, where the phase
compares the checkout with Git, the HEAD object ids of the governed paths.

Eligibility is deliberately narrow: ``CONFIGURATION=Debug`` and
``MACSCOPE_DEBUG_SOURCE_IDENTITY=runtime-only`` (routine development).  Release
builds and every qualification/Gate F/CI build (which pass
``MACSCOPE_DEBUG_SOURCE_IDENTITY=source-qualified``) never consult or write a
stamp.  Any helper error is a cache miss, never a skipped verification.

The module is standard-library only and is safe to load without writing
bytecode into the repository.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable, Iterable, Mapping


SCHEMA_VERSION = 1
REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = Path(__file__).resolve()
STAMP_DIRECTORY_NAME = "MacScopePhaseStamps"
MAXIMUM_STAMP_BYTES = 64 * 1024
MAXIMUM_TREE_ENTRIES = 200_000
ELIGIBLE_CONFIGURATION = "Debug"
ELIGIBLE_SOURCE_IDENTITY = "runtime-only"
OPT_OUT_VARIABLE = "MACSCOPE_DISABLE_PHASE_STAMPS"
# Xcode's build scheduler exports per-invocation identifiers (LLBUILD_BUILD_ID, _LANE_ID,
# _TASK_ID) into every script phase. They name the scheduling slot, not anything a phase
# reads, and they differ on every build; keying on them made every stamp miss (D12 layer 3
# measurement 2026-10-12: Ghostty VT 9.0 s + REA verify 7.6 s re-ran on each incremental build).
VOLATILE_ENVIRONMENT_PREFIXES = ("LLBUILD_",)


class StampError(RuntimeError):
    """The stamp cannot be evaluated safely; treat as a cache miss."""


class PhaseSpec:
    def __init__(
        self,
        *,
        files: Iterable[Path] = (),
        trees: Iterable[Path] = (),
        git_paths: Iterable[str] = (),
        output_files: Iterable[Path] = (),
        output_trees: Iterable[Path] = (),
        git_trees: Iterable[Path] = (),
    ) -> None:
        self.files = tuple(files)
        self.trees = tuple(trees)
        self.git_paths = tuple(git_paths)
        self.output_files = tuple(output_files)
        self.output_trees = tuple(output_trees)
        # Large Git-tracked input trees: keyed by HEAD's tree id when `git status` shows the
        # tree exactly at HEAD (content identity, ~0.3 s for 46k files), else by the lstat walk.
        self.git_trees = tuple(git_trees)


def _required(environment: Mapping[str, str], name: str) -> str:
    value = environment.get(name, "")
    if not value:
        raise StampError(f"{name} is required for a phase stamp")
    return value


def _repository(relative: str) -> Path:
    return REPOSITORY_ROOT / relative


def _signing_environment(environment: Mapping[str, str]) -> PhaseSpec:
    # Exactly what `check_local_signing_policy.py --build-environment` reads:
    # the generation-freshness inputs and stamp, plus the whole environment
    # (validate_build_environment iterates every exported setting).
    macscope = _repository("MacScope")
    return PhaseSpec(
        files=(
            _repository("Scripts/check_local_signing_policy.py"),
            _repository("Scripts/project_freshness.py"),
            macscope / "project.yml",
            macscope / "DependencyRoots.xcconfig",
            macscope / "SigningIdentity.xcconfig",
            macscope / "DependencyRoots.local.xcconfig",
            macscope / "MacScope.xcodeproj" / "project.xcproj",
            macscope / "MacScope.xcodeproj" / ".macscope-project-generation.sha256",
        ),
    )


def _ghostty_vt(environment: Mapping[str, str]) -> PhaseSpec:
    build_root = Path(_required(environment, "MACSCOPE_GHOSTTY_VT_BUILD_ROOT"))
    target_build = Path(_required(environment, "TARGET_BUILD_DIR"))
    frameworks = _required(environment, "FRAMEWORKS_FOLDER_PATH")
    files = [
        _repository("Scripts/build_ghostty_vt.sh"),
        _repository("Scripts/ghostty-vt-source.contract"),
        _repository("Scripts/prepare_zig_macos_sdk_overlay.py"),
        _repository("Scripts/dependencies/stage_verified_ghostty_vt.py"),
        _repository("Scripts/dependencies/stage_verified_ghostty_surface.py"),
        _repository("Scripts/dependencies/zig_toolchain_receipt.py"),
        _repository("Scripts/qualification/dev_dependency_cache.py"),
        _repository("Scripts/qualification/dependency_cache.py"),
        _repository("ThirdParty/Zig/zig-0.16.0.receipt.json"),
    ]
    trees: list[Path] = []
    git_trees = [
        _repository("ThirdParty/GhosttyVT/Source"),
        _repository("ThirdParty/Zig/zig-0.16.0"),
    ]
    verified_root = environment.get("MACSCOPE_GHOSTTY_VT_VERIFIED_ARTIFACT_ROOT", "")
    verified_descriptor = environment.get("MACSCOPE_GHOSTTY_VT_VERIFIED_DESCRIPTOR", "")
    if verified_root:
        trees.append(Path(verified_root))
    if verified_descriptor:
        files.append(Path(verified_descriptor))
    return PhaseSpec(
        files=files,
        trees=trees,
        git_trees=git_trees,
        output_trees=(build_root / "artifacts",),
        output_files=(target_build / frameworks / "libghostty-vt.dylib",),
    )


def _rea_resource(environment: Mapping[str, str]) -> PhaseSpec:
    # rea_verify.py compares every governed ThirdParty/REA leaf (and the
    # implementation input rea_build.mjs) with its HEAD blob, so HEAD's object
    # ids are part of the key as well as the on-disk bytes' identity.
    return PhaseSpec(
        files=(
            _repository("Scripts/dependencies/rea_verify.py"),
            _repository("Scripts/dependencies/rea_build.mjs"),
            _repository(".git"),
        ),
        trees=(_repository("ThirdParty/REA"),),
        git_paths=("ThirdParty/REA", "Scripts/dependencies/rea_build.mjs"),
    )


def _machokit_source(environment: Mapping[str, str]) -> PhaseSpec:
    root = Path(_required(environment, "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT"))
    srcroot = Path(_required(environment, "SRCROOT"))
    return PhaseSpec(
        files=(
            _repository("Scripts/machokit_source_identity.py"),
            root,
            srcroot / "LocalPackages",
        ),
        trees=(root,),
    )


def _machokit_compiled(environment: Mapping[str, str]) -> PhaseSpec:
    target_build = Path(_required(environment, "TARGET_BUILD_DIR"))
    executable = _required(environment, "EXECUTABLE_PATH")
    return PhaseSpec(
        files=(
            _repository("Scripts/verify_machokit_analysis_worker_identity.py"),
            target_build / executable,
        ),
    )


def _native_package_stage(environment: Mapping[str, str]) -> PhaseSpec:
    materialization = Path(_required(environment, "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT"))
    target_build = Path(_required(environment, "TARGET_BUILD_DIR"))
    resources = _required(environment, "UNLOCALIZED_RESOURCES_FOLDER_PATH")
    target_temp = Path(_required(environment, "TARGET_TEMP_DIR"))
    return PhaseSpec(
        files=(
            _repository("Scripts/native-decompiler-xpc/stage_xcode_resources.py"),
            _repository("Scripts/native-decompiler-xpc/stage_verified_package.py"),
            _repository("Scripts/native-decompiler-direct/verify_sleigh_package.py"),
            _repository("Scripts/native-decompiler-direct/sleigh_package.py"),
            materialization,
        ),
        trees=(materialization,),
        output_trees=(
            target_build / resources / "NativeDecompilerPackage",
            target_temp / "NativeDecompilerPackageStage",
        ),
    )


PHASES: dict[str, Callable[[Mapping[str, str]], PhaseSpec]] = {
    "signing-environment": _signing_environment,
    "ghostty-vt": _ghostty_vt,
    "rea-resource": _rea_resource,
    "machokit-source": _machokit_source,
    "machokit-compiled": _machokit_compiled,
    "native-package-stage": _native_package_stage,
}


def eligible(environment: Mapping[str, str]) -> bool:
    return (
        environment.get("CONFIGURATION") == ELIGIBLE_CONFIGURATION
        and environment.get("MACSCOPE_DEBUG_SOURCE_IDENTITY") == ELIGIBLE_SOURCE_IDENTITY
        and environment.get(OPT_OUT_VARIABLE, "") in ("", "NO", "0")
        and bool(environment.get("DERIVED_FILE_DIR"))
    )


def _entry_record(path: Path) -> list[object]:
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return ["missing"]
    except OSError as error:
        raise StampError(f"cannot inspect {path}: {error}") from error
    record: list[object] = [
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_gid,
        getattr(metadata, "st_flags", 0),
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    ]
    if stat.S_ISLNK(metadata.st_mode):
        record.append(os.readlink(path))
    return record


def _tree_records(root: Path) -> list[object]:
    """lstat every entry below root without following links, in stable order."""

    records: list[object] = [str(root), os.path.realpath(root), _entry_record(root)]
    if records[-1] == ["missing"]:
        return records
    count = 0
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            with os.scandir(directory) as iterator:
                entries = sorted(iterator, key=lambda entry: entry.name)
        except NotADirectoryError:
            continue
        except OSError as error:
            raise StampError(f"cannot list {directory}: {error}") from error
        for entry in entries:
            count += 1
            if count > MAXIMUM_TREE_ENTRIES:
                raise StampError(f"{root} exceeds the stamp tree bound")
            path = Path(entry.path)
            records.append([os.path.relpath(path, root), _entry_record(path)])
            if entry.is_dir(follow_symlinks=False):
                pending.append(path)
    return records


def _git_records(paths: tuple[str, ...]) -> list[object]:
    if not paths:
        return []
    if not (REPOSITORY_ROOT / ".git").exists():
        return ["no-git"]
    # `rev-parse --verify` accepts exactly one revision: one call per governed path (with
    # two paths in a single call it always failed, so the REA stamp never recorded).
    object_ids: list[str] = []
    for path in paths:
        result = subprocess.run(
            ["git", "-C", str(REPOSITORY_ROOT), "rev-parse", "--verify", "--quiet", f"HEAD:{path}"],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
        if result.returncode != 0:
            raise StampError("Git HEAD authority is unavailable for the stamp key")
        object_ids.append(result.stdout.strip())
    return object_ids


def _git_tree_record(root: Path) -> list[object]:
    """HEAD's tree id for a tracked tree whose working copy is exactly HEAD, else its lstat walk.

    `git status` reports any modified, staged, untracked or ignored entry below the path; a
    clean status means the bytes equal HEAD's tree, so the tree id identifies the content."""
    relative = os.path.relpath(root, REPOSITORY_ROOT)
    if relative.startswith("..") or not (REPOSITORY_ROOT / ".git").exists():
        return ["walk", _tree_records(root)]
    status = subprocess.run(
        ["git", "-C", str(REPOSITORY_ROOT), "status", "--porcelain", "--untracked-files=all",
         "--ignored=matching", "--", relative],
        capture_output=True, text=True, check=False, timeout=120,
    )
    tree = subprocess.run(
        ["git", "-C", str(REPOSITORY_ROOT), "rev-parse", "--verify", "--quiet", f"HEAD:{relative}"],
        capture_output=True, text=True, check=False, timeout=60,
    )
    if status.returncode == 0 and not status.stdout.strip() and tree.returncode == 0:
        return ["git-clean", relative, tree.stdout.strip()]
    return ["walk", _tree_records(root)]


def _digest(value: object) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(payload.encode("ascii")).hexdigest()


def input_key(phase: str, environment: Mapping[str, str]) -> str:
    spec = PHASES[phase](environment)
    project_file = environment.get("PROJECT_FILE_PATH", "")
    record = {
        "schema": SCHEMA_VERSION,
        "phase": phase,
        "helper": _entry_record(HELPER_PATH),
        "project": _entry_record(Path(project_file) / "project.xcproj") if project_file else None,
        "environment": sorted(
            item for item in environment.items()
            if not item[0].startswith(VOLATILE_ENVIRONMENT_PREFIXES)
        ),
        "files": [[str(path), _entry_record(path)] for path in spec.files],
        "trees": [_tree_records(path) for path in spec.trees],
        "git": _git_records(spec.git_paths),
    }
    if spec.git_trees:
        record["git_trees"] = [_git_tree_record(path) for path in spec.git_trees]
    return _digest(record)


def output_fingerprint(phase: str, environment: Mapping[str, str]) -> str:
    spec = PHASES[phase](environment)
    record = {
        "files": [[str(path), _entry_record(path)] for path in spec.output_files],
        "trees": [_tree_records(path) for path in spec.output_trees],
    }
    for path, entry in record["files"]:
        if entry == ["missing"]:
            raise StampError(f"declared output is missing: {path}")
    for tree in record["trees"]:
        if tree[2] == ["missing"]:
            raise StampError(f"declared output tree is missing: {tree[0]}")
    return _digest(record)


def _stamp_paths(phase: str, environment: Mapping[str, str]) -> tuple[Path, Path]:
    directory = Path(_required(environment, "DERIVED_FILE_DIR")) / STAMP_DIRECTORY_NAME
    return directory / f"{phase}.json", directory / f"{phase}.pending.json"


def _read_json(path: Path) -> dict[str, object] | None:
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return None
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size > MAXIMUM_STAMP_BYTES
    ):
        raise StampError(f"stamp is not a safe ordinary file: {path}")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        payload = stream.read(MAXIMUM_STAMP_BYTES + 1)
    value = json.loads(payload)
    if not isinstance(value, dict):
        raise StampError(f"stamp is malformed: {path}")
    return value


def _write_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(descriptor, "w", encoding="ascii") as stream:
            json.dump(value, stream, sort_keys=True)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def _remove(path: Path) -> None:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def check(phase: str, environment: Mapping[str, str]) -> bool:
    """Return True when the phase body may be skipped; otherwise arm a record."""

    if phase not in PHASES or not eligible(environment):
        return False
    stamp_path, pending_path = _stamp_paths(phase, environment)
    _remove(pending_path)
    key = input_key(phase, environment)
    try:
        stamp = _read_json(stamp_path)
    except (StampError, OSError, ValueError):
        stamp = None
    if (
        stamp is not None
        and stamp.get("schema") == SCHEMA_VERSION
        and stamp.get("phase") == phase
        and stamp.get("inputs") == key
    ):
        try:
            if stamp.get("outputs") == output_fingerprint(phase, environment):
                return True
        except StampError:
            pass
    # Invalidate before running so a failed body can never leave a stale hit.
    _remove(stamp_path)
    _write_json(pending_path, {"schema": SCHEMA_VERSION, "phase": phase, "inputs": key})
    return False


def record(phase: str, environment: Mapping[str, str]) -> bool:
    """Publish a stamp for a body that just succeeded; return whether it did."""

    if phase not in PHASES or not eligible(environment):
        return False
    stamp_path, pending_path = _stamp_paths(phase, environment)
    pending = _read_json(pending_path)
    _remove(pending_path)
    if pending is None or pending.get("phase") != phase:
        return False
    key = input_key(phase, environment)
    if pending.get("inputs") != key:
        # Something the phase reads changed while it ran; verify again next build.
        return False
    _write_json(
        stamp_path,
        {
            "schema": SCHEMA_VERSION,
            "phase": phase,
            "inputs": key,
            "outputs": output_fingerprint(phase, environment),
        },
    )
    return True


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in ("check", "record") or argv[2] not in PHASES:
        print(
            "usage: build_phase_stamp.py check|record "
            + "|".join(sorted(PHASES)),
            file=sys.stderr,
        )
        return 2
    command, phase = argv[1], argv[2]
    environment = dict(os.environ)
    try:
        if command == "check":
            if check(phase, environment):
                print(
                    f"note: {phase}: inputs, environment and outputs unchanged since the "
                    "last verified Debug run; reusing its stamp"
                )
                return 0
            return 1
        record(phase, environment)
        return 0
    except (StampError, OSError, ValueError, subprocess.SubprocessError) as error:
        # A stamp problem must never skip verification or fail a verified build.
        print(f"warning: {phase} stamp {command} ignored: {error}", file=sys.stderr)
        return 1 if command == "check" else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
