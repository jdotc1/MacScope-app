#!/usr/bin/env python3
"""Generated-project freshness contract (standard library only).

The stamp `MacScope/MacScope.xcodeproj/.macscope-project-generation.sha256` binds the inputs
that determine the generated Xcode project and its staged resources. Scripts/bootstrap.sh records
it; dev_loop (script/build_and_run.sh), the signing-environment guard and the qualifier's
bootstrap reuse validate it. Moved out of check_local_signing_policy.py so bootstrap_reuse can
load it without that module's Gate F imports; check_local_signing_policy re-exports every name.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


PROJECT_FRESHNESS_STAMP_NAME = ".macscope-project-generation.sha256"
# Bind generator inputs and the authoritative officially converted JSON bytes.
PROJECT_FRESHNESS_INPUTS = (
    ("MacScope/project.yml", "project.yml"),
    ("MacScope/DependencyRoots.xcconfig", "DependencyRoots.xcconfig"),
    ("MacScope/SigningIdentity.xcconfig", "SigningIdentity.xcconfig"),
    (
        "MacScope/MacScope.xcodeproj/project.xcproj",
        "MacScope.xcodeproj/project.xcproj",
    ),
    # The patched SLEIGH overlay (.sla/.sinc under ThirdParty/SleighNative/AARCH64) reaches the
    # app only through bootstrap's staging; its manifest changes with every overlay change, so
    # binding it makes dev_loop and the qualifier regenerate instead of bundling a stale .sla
    # (MASTER-PLAN 4.74, after #469).
    (
        "ThirdParty/SleighNative/PATCHED_RESOURCES.json",
        "../ThirdParty/SleighNative/PATCHED_RESOURCES.json",
    ),
)
# XcodeGen folder sources (App, CoreTests, ...) pick up whatever files exist
# under their folders, so a file added, removed or renamed by `git merge`
# changes the generated project without touching project.yml. Bind the sorted
# path list (paths only, never contents) of these roots, relative to the
# MacScope directory, so an edit to an existing file keeps the project fresh.
PROJECT_FRESHNESS_SOURCE_PATHS_LABEL = "MacScope/source-paths"
PROJECT_FRESHNESS_SOURCE_PATH_ROOTS = (
    ".",
    "../ThirdParty/SwiftAssemblyVendor/Sources",
    "../ThirdParty/REA/licenses",
)
PROJECT_FRESHNESS_SOURCE_WALK_SKIP = frozenset(
    {"MacScope.xcodeproj", "DerivedData", "build", ".build"}
)
PROJECT_FRESHNESS_LABELS = tuple(
    label for label, _ in PROJECT_FRESHNESS_INPUTS
) + (PROJECT_FRESHNESS_SOURCE_PATHS_LABEL,)
PROJECT_FRESHNESS_STAMP_PATTERN = re.compile(
    b"^"
    + b"".join(
        re.escape(label.encode("ascii")) + rb" [0-9a-f]{64}\n"
        for label in PROJECT_FRESHNESS_LABELS
    )
    + b"$"
)
PROJECT_FRESHNESS_STAMP_SIZE = sum(
    len(label.encode("ascii")) + 1 + 64 + 1
    for label in PROJECT_FRESHNESS_LABELS
)
PROJECT_FRESHNESS_READ_BOUND = PROJECT_FRESHNESS_STAMP_SIZE + 1


def generated_project_freshness_stamp(project_yml: Path) -> Path:
    return project_yml.parent / "MacScope.xcodeproj" / PROJECT_FRESHNESS_STAMP_NAME


def generated_project_freshness_inputs(project_yml: Path) -> list[tuple[str, Path]]:
    macscope_root = project_yml.parent
    paths = {
        "project.yml": project_yml,
        "DependencyRoots.xcconfig": macscope_root / "DependencyRoots.xcconfig",
        "SigningIdentity.xcconfig": macscope_root / "SigningIdentity.xcconfig",
        "MacScope.xcodeproj/project.xcproj": (
            macscope_root / "MacScope.xcodeproj" / "project.xcproj"
        ),
        "../ThirdParty/SleighNative/PATCHED_RESOURCES.json": (
            macscope_root.parent / "ThirdParty" / "SleighNative" / "PATCHED_RESOURCES.json"
        ),
    }
    return [(label, paths[relative]) for label, relative in PROJECT_FRESHNESS_INPUTS]


def sha256_stable_regular_file(path: Path, label: str) -> str:
    try:
        before = path.lstat()
    except OSError as error:
        raise ValueError(f"freshness input {label} is missing or inaccessible: {error}")
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
    ):
        raise ValueError(f"freshness input {label} is not a safe ordinary file")
    digest = sha256_file(path)
    try:
        after = path.lstat()
    except OSError as error:
        raise ValueError(f"freshness input {label} changed while read: {error}")
    stable = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )
    if stable(before) != stable(after):
        raise ValueError(f"freshness input {label} changed while read")
    return digest


def generated_project_source_paths(project_yml: Path) -> list[str]:
    """Sorted file paths under the folder-source roots, relative to MacScope/.

    Uses git (tracked plus untracked, non-ignored files) when the MacScope
    directory is in a work tree; otherwise walks the MacScope directory itself,
    skipping generated and hidden directories. Paths only: no file is read.
    """
    macscope_root = project_yml.parent
    try:
        result = subprocess.run(
            [
                "/usr/bin/git",
                "-C",
                str(macscope_root),
                "ls-files",
                "-z",
                "--cached",
                "--others",
                "--exclude-standard",
                "--",
                *PROJECT_FRESHNESS_SOURCE_PATH_ROOTS,
            ],
            check=False,
            capture_output=True,
        )
    except OSError:
        result = None
    if result is not None and result.returncode == 0:
        paths = {
            entry.decode("utf-8", "surrogateescape")
            for entry in result.stdout.split(b"\0")
            if entry
        }
        return sorted(paths)
    walked: list[str] = []
    for directory, subdirectories, files in os.walk(macscope_root):
        subdirectories[:] = [
            name
            for name in subdirectories
            if not name.startswith(".")
            and name not in PROJECT_FRESHNESS_SOURCE_WALK_SKIP
            and not name.startswith("DerivedData")
        ]
        relative = Path(directory).relative_to(macscope_root)
        walked.extend(
            (relative / name).as_posix() for name in files if not name.startswith(".")
        )
    return sorted(walked)


def generated_project_source_paths_digest(project_yml: Path) -> str:
    joined = "".join(
        f"{path}\0" for path in generated_project_source_paths(project_yml)
    )
    return hashlib.sha256(joined.encode("utf-8", "surrogateescape")).hexdigest()


def generated_project_freshness_payload(project_yml: Path) -> bytes:
    lines = [
        f"{label} {sha256_stable_regular_file(path, label)}\n"
        for label, path in generated_project_freshness_inputs(project_yml)
    ]
    lines.append(
        f"{PROJECT_FRESHNESS_SOURCE_PATHS_LABEL} "
        f"{generated_project_source_paths_digest(project_yml)}\n"
    )
    payload = "".join(lines).encode("ascii")
    if len(payload) != PROJECT_FRESHNESS_STAMP_SIZE:
        raise ValueError("project-generation freshness payload has unexpected size")
    return payload


def record_generated_project_freshness(
    project_yml: Path, expected_source_paths_digest: str | None = None
) -> Path:
    """Records the stamp for the project just generated.

    `expected_source_paths_digest` is the folder-source path digest captured before XcodeGen
    ran. A file added, removed or renamed during generation would otherwise be stamped as
    present in a project that never saw it, and every later run would reuse that project
    (an added test then silently matches no selector). On a mismatch no stamp is left, so the
    next bootstrap regenerates.
    """
    stamp = generated_project_freshness_stamp(project_yml)
    stamp.parent.mkdir(parents=False, exist_ok=True)
    payload = generated_project_freshness_payload(project_yml)
    if expected_source_paths_digest is not None:
        current = generated_project_source_paths_digest(project_yml)
        if current != expected_source_paths_digest:
            stamp.unlink(missing_ok=True)
            raise ValueError(
                "source files were added, removed or renamed while the project was being "
                "generated; no freshness stamp was recorded, so the next bootstrap regenerates"
            )
    descriptor, temporary_name = tempfile.mkstemp(
        dir=stamp.parent,
        prefix=f"{PROJECT_FRESHNESS_STAMP_NAME}.tmp.",
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = -1
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, stamp)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return stamp


def validate_generated_project_freshness(project_yml: Path) -> list[str]:
    stamp = generated_project_freshness_stamp(project_yml)
    try:
        metadata = stamp.lstat()
    except OSError as error:
        return [f"project-generation freshness stamp is missing or inaccessible: {error}"]
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size != PROJECT_FRESHNESS_STAMP_SIZE
    ):
        return ["project-generation freshness stamp is malformed or unsafe"]
    try:
        descriptor = os.open(
            stamp,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
        )
        with os.fdopen(descriptor, "rb") as stream:
            payload = stream.read(PROJECT_FRESHNESS_READ_BOUND)
            opened = os.fstat(stream.fileno())
        observed = stamp.lstat()
    except OSError as error:
        return [f"project-generation freshness stamp cannot be read safely: {error}"]

    def stable_fields(value: os.stat_result) -> tuple[int, ...]:
        return (
            value.st_dev,
            value.st_ino,
            value.st_mode,
            value.st_nlink,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )
    if (
        stable_fields(opened) != stable_fields(metadata)
        or stable_fields(observed) != stable_fields(metadata)
        or PROJECT_FRESHNESS_STAMP_PATTERN.fullmatch(payload) is None
    ):
        return ["project-generation freshness stamp changed while read or is malformed"]
    try:
        current = generated_project_freshness_payload(project_yml)
    except ValueError as error:
        return [str(error)]
    if payload != current:
        recorded_lines = payload.decode("ascii").splitlines()
        current_lines = current.decode("ascii").splitlines()
        changed = [
            label
            for label, recorded, observed in zip(
                PROJECT_FRESHNESS_LABELS,
                recorded_lines,
                current_lines,
            )
            if recorded != observed
        ]
        return [
            "generated MacScope.xcodeproj freshness inputs differ from the recorded "
            f"generation boundary: {changed!r}"
        ]
    return []
