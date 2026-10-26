#!/usr/bin/env python3
"""Publish the vendored SLEIGH component as one strict external materialization.

The repository component contains license, provenance, and independently
governed AArch64 records beside the runtime package.  Native consumers accept
the fail-closed archive identity plus a separate patched-resource identity.
This offline producer publishes both records beside ``package/`` outside the
repository. Consumers must explicitly admit the patched-resource contract.

The release-archive ``package/`` is verified strictly first; the MacScope-patched
AArch64 resources (``AARCH64/``, recorded in ``PATCHED_RESOURCES.json``, decision D3)
are then overlaid onto its SLEIGH languages directory, and the overlaid tree must
match ``patched.packageTreeSha256WithResourceOverlay``. The record is copied into
the materialization so consumers can see the patched identity.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile


SCRIPT_ROOT = Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_ROOT.parents[1]
VENDORED_VERIFIER = (
    REPOSITORY_ROOT / "Scripts/dependencies/verify_vendored_sleigh_native.py"
)
STRICT_VERIFIER = (
    REPOSITORY_ROOT / "Scripts/native-decompiler-direct/verify_sleigh_package.py"
)
DESTINATION_NAME = "materialization"
PATCHED_RECORD_NAME = "PATCHED_RESOURCES.json"
LANGUAGES_RELATIVE = Path("share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages")
LOCK_NAME = ".macscope-sleigh-materialization.lock"


class RepositoryMaterializationError(RuntimeError):
    """Raised when the vendored component cannot be published safely."""


def _is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def _ordinary_directory(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise RepositoryMaterializationError(f"{label} is unavailable: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise RepositoryMaterializationError(f"{label} must be an ordinary directory")
    return path.resolve(strict=True)


def _ordinary_file(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise RepositoryMaterializationError(f"{label} is unavailable: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise RepositoryMaterializationError(f"{label} must be an ordinary file")
    return path


def _run_verifier(command: list[str], label: str) -> dict[str, object]:
    completed = subprocess.run(command, text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        diagnostic = " ".join((completed.stderr or completed.stdout).split())
        suffix = f": {diagnostic}" if diagnostic else ""
        raise RepositoryMaterializationError(f"{label} failed{suffix}")
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RepositoryMaterializationError(f"{label} returned malformed identity") from error
    if not isinstance(value, dict):
        raise RepositoryMaterializationError(f"{label} returned a non-object identity")
    return value


def _verify_component(component_root: Path) -> dict[str, object]:
    return _run_verifier(
        [sys.executable, "-B", str(VENDORED_VERIFIER), str(component_root)],
        "vendored SLEIGH component verification",
    )


def _verify_strict(materialization_root: Path) -> dict[str, object]:
    return _run_verifier(
        [
            sys.executable,
            "-B",
            str(STRICT_VERIFIER),
            "verify",
            "--materialization-root",
            str(materialization_root),
        ],
        "strict SLEIGH materialization verification",
    )


def _source_manifest(component_root: Path) -> dict[str, object]:
    manifest = _ordinary_file(
        component_root / "MATERIALIZATION.json", "vendored materialization manifest"
    )
    try:
        value = json.loads(manifest.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RepositoryMaterializationError("vendored materialization manifest is malformed") from error
    if not isinstance(value, dict):
        raise RepositoryMaterializationError("vendored materialization manifest is not an object")
    return value


def _patched_record(component_root: Path) -> dict[str, object]:
    record_path = _ordinary_file(
        component_root / PATCHED_RECORD_NAME, "patched AArch64 resource record"
    )
    try:
        record = json.loads(record_path.read_text(encoding="utf-8"))
        expected = record["patched"]["packageTreeSha256WithResourceOverlay"]
    except (UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise RepositoryMaterializationError("patched AArch64 resource record is malformed") from error
    if (not isinstance(expected, str) or len(expected) != 64
            or any(character not in "0123456789abcdef" for character in expected)):
        raise RepositoryMaterializationError("patched AArch64 resource record is malformed")
    return record


def _package_tree_sha256(package: Path) -> str:
    """Same digest as verify_vendored_sleigh_native.tree_digest and the patch contract."""
    entries = []
    for candidate in package.rglob("*"):
        mode = candidate.lstat().st_mode
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            raise RepositoryMaterializationError(
                f"non-regular package member: {candidate.relative_to(package)}"
            )
        entries.append(candidate)
    entries.sort(key=lambda path: path.relative_to(package).as_posix().encode())
    digest = hashlib.sha256()
    for candidate in entries:
        relative = candidate.relative_to(package).as_posix()
        member = hashlib.sha256(candidate.read_bytes()).hexdigest()
        digest.update(
            relative.encode() + b"\0" + str(candidate.stat().st_size).encode()
            + b"\0" + member.encode() + b"\0"
        )
    return digest.hexdigest()


def _overlay_patched_resources(component_root: Path, materialization: Path) -> None:
    resources = _ordinary_directory(component_root / "AARCH64", "patched AArch64 resources")
    languages = _ordinary_directory(
        materialization / "package" / LANGUAGES_RELATIVE, "materialized SLEIGH languages"
    )
    for source in sorted(resources.iterdir(), key=lambda path: path.name):
        _ordinary_file(source, f"patched AArch64 resource {source.name}")
        target = languages / source.name
        if target.is_symlink():
            raise RepositoryMaterializationError(f"materialized resource is a link: {source.name}")
        shutil.copyfile(source, target, follow_symlinks=False)
    shutil.copyfile(
        component_root / PATCHED_RECORD_NAME, materialization / PATCHED_RECORD_NAME,
        follow_symlinks=False,
    )


def _verify_overlay(materialization: Path, record: dict[str, object]) -> None:
    _ordinary_directory(materialization, "patched materialization")
    if {path.name for path in materialization.iterdir()} != {
        "MATERIALIZATION.json", "package", PATCHED_RECORD_NAME
    }:
        raise RepositoryMaterializationError("patched materialization contains unexpected entries")
    _ordinary_file(materialization / "MATERIALIZATION.json", "materialization manifest")
    package = _ordinary_directory(materialization / "package", "materialized package")
    expected = record["patched"]["packageTreeSha256WithResourceOverlay"]  # type: ignore[index]
    observed = _package_tree_sha256(package)
    if observed != expected:
        raise RepositoryMaterializationError(
            "patched AArch64 overlay does not match PATCHED_RESOURCES.json"
        )
    published = _ordinary_file(materialization / PATCHED_RECORD_NAME, "patched resource record")
    if json.loads(published.read_text(encoding="utf-8")) != record:
        raise RepositoryMaterializationError("materialized patched resource record differs")


def _copy_closure(component_root: Path, temporary_root: Path) -> None:
    source_manifest = _ordinary_file(
        component_root / "MATERIALIZATION.json", "vendored materialization manifest"
    )
    source_package = _ordinary_directory(
        component_root / "package", "vendored SLEIGH package"
    )
    shutil.copy2(source_manifest, temporary_root / "MATERIALIZATION.json", follow_symlinks=False)

    destination_package = temporary_root / "package"
    clone = subprocess.run(
        ["/bin/cp", "-cR", str(source_package), str(destination_package)],
        text=True,
        capture_output=True,
        check=False,
    )
    if clone.returncode == 0:
        return

    # Clonefile is an optimization, not an authority requirement.  A volume
    # without clone support falls back to an ordinary recursive copy, and the
    # complete destination is independently verified before publication.
    if destination_package.is_symlink() or (
        destination_package.exists() and not destination_package.is_dir()
    ):
        destination_package.unlink()
    elif destination_package.exists():
        shutil.rmtree(destination_package)
    copied = subprocess.run(
        ["/bin/cp", "-R", str(source_package), str(destination_package)],
        text=True,
        capture_output=True,
        check=False,
    )
    if copied.returncode != 0:
        diagnostic = " ".join((copied.stderr or clone.stderr).split())
        suffix = f": {diagnostic}" if diagnostic else ""
        raise RepositoryMaterializationError(f"vendored package copy failed{suffix}")


def _open_lock(work_root: Path) -> int:
    path = work_root / LOCK_NAME
    try:
        descriptor = os.open(
            path,
            os.O_RDWR
            | os.O_CREAT
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise RepositoryMaterializationError("materialization lock is not an ordinary file")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        return descriptor
    except Exception:
        if "descriptor" in locals():
            os.close(descriptor)
        raise


def prepare(component_root: Path, work_root: Path) -> Path:
    component_root = _ordinary_directory(Path(component_root), "vendored SLEIGH component root")
    work_root = Path(work_root)
    if not work_root.is_absolute():
        raise RepositoryMaterializationError("work root must be an absolute external path")
    repository_root = REPOSITORY_ROOT.resolve(strict=True)
    prospective_work_root = work_root.resolve(strict=False)
    if _is_within(prospective_work_root, repository_root) or _is_within(
        repository_root, prospective_work_root
    ):
        raise RepositoryMaterializationError("work root must be outside the repository")
    if _is_within(prospective_work_root, component_root) or _is_within(
        component_root, prospective_work_root
    ):
        raise RepositoryMaterializationError("work root must be separate from the component root")
    work_root.mkdir(parents=True, exist_ok=True)
    work_root = _ordinary_directory(work_root, "SLEIGH materialization work root")
    if _is_within(work_root, repository_root) or _is_within(repository_root, work_root):
        raise RepositoryMaterializationError("work root must be outside the repository")
    if _is_within(work_root, component_root) or _is_within(component_root, work_root):
        raise RepositoryMaterializationError("work root must be separate from the component root")

    _ordinary_file(VENDORED_VERIFIER, "vendored SLEIGH verifier")
    _ordinary_file(STRICT_VERIFIER, "strict SLEIGH verifier")
    _verify_component(component_root)
    expected_identity = _source_manifest(component_root)
    patched_record = _patched_record(component_root)
    overlay_tree = patched_record["patched"]["packageTreeSha256WithResourceOverlay"]  # type: ignore[index]
    destination = work_root / f"{DESTINATION_NAME}-{overlay_tree[:16]}"

    lock_descriptor = _open_lock(work_root)
    temporary: Path | None = None
    try:
        if destination.exists() or destination.is_symlink():
            _ordinary_directory(destination, "existing SLEIGH materialization")
            if _source_manifest(destination) != expected_identity:
                raise RepositoryMaterializationError(
                    "existing materialization belongs to a different source identity"
                )
            _verify_overlay(destination, patched_record)
            return destination.resolve(strict=True)

        temporary = Path(tempfile.mkdtemp(prefix=".materialization.", dir=work_root))
        _copy_closure(component_root, temporary)
        observed_identity = _verify_strict(temporary)
        if observed_identity != expected_identity:
            raise RepositoryMaterializationError(
                "published materialization identity does not match the vendored source"
            )
        # The archive identity is proven above; now apply the patched resources (D3).
        _overlay_patched_resources(component_root, temporary)
        _verify_overlay(temporary, patched_record)

        try:
            os.rename(temporary, destination)
            temporary = None
        except FileExistsError:
            # Another process using the same lock protocol cannot reach this
            # branch, but retain a fail-closed race check for external writers.
            if _source_manifest(destination) != expected_identity:
                raise RepositoryMaterializationError(
                    "concurrent materialization has a different source identity"
                )
        _verify_overlay(destination, patched_record)
        return destination.resolve(strict=True)
    finally:
        if temporary is not None and temporary.exists():
            shutil.rmtree(temporary)
        fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component-root", type=Path, required=True)
    parser.add_argument("--work-root", type=Path, required=True)
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    try:
        destination = prepare(arguments.component_root, arguments.work_root)
    except (OSError, RepositoryMaterializationError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"MACSCOPE_SLEIGH_MATERIALIZATION_ROOT={destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
