#!/usr/bin/env python3
"""Stage one already verified native package without acquiring anything."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import stat
import sys
from pathlib import Path, PurePosixPath
from typing import Iterable


DIRECT_VERIFIER_ROOT = Path(__file__).resolve().parents[1] / "native-decompiler-direct"
if str(DIRECT_VERIFIER_ROOT) not in sys.path:
    sys.path.insert(0, str(DIRECT_VERIFIER_ROOT))

from sleigh_package import PackageContractError, verify_materialization


class PackageStageError(RuntimeError):
    """Raised when staging would weaken the verified package boundary."""


class MissingStagedReceiptError(PackageStageError):
    """A staged receipt is absent; structural evidence is retained for recovery."""

    def __init__(self, canonical, root_fields, snapshot):
        super().__init__("staged package receipt is absent")
        self.canonical = canonical
        self.root_fields = root_fields
        self.snapshot = snapshot


def _receipt_metadata(path: Path):
    try:
        return path.lstat()
    except FileNotFoundError:
        return None


def _validated_path(path: Path, label: str) -> Path:
    try:
        text = os.fsdecode(os.fspath(path))
    except (TypeError, ValueError) as error:
        raise PackageStageError(f"{label} has an unsafe path") from error
    if any(character in text for character in ("\r", "\n", "\x00")):
        raise PackageStageError(f"{label} has an unsafe path")
    for component in Path(text).parts:
        if any(character in component for character in ("\r", "\n", "\x00")):
            raise PackageStageError(f"{label} has an unsafe path component")
    return Path(text)


def _canonical_path(path: Path, label: str, *, strict: bool = False) -> Path:
    try:
        resolved = path.resolve(strict=strict)
    except (OSError, ValueError) as error:
        raise PackageStageError(f"{label} is missing, inaccessible, or unsafe: {error}") from error
    return _validated_path(resolved, f"canonical {label}")


def _ordinary_directory(path: Path, label: str) -> Path:
    resolved, descriptor, _metadata = _open_anchored_directory(path, label)
    os.close(descriptor)
    return resolved


def _stable_tree_fields(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _open_anchored_directory(
    path: Path,
    label: str,
) -> tuple[Path, int, os.stat_result]:
    """Open one requested directory without following its leaf or racing resolve()."""

    requested = _validated_path(path, label)
    try:
        before = requested.lstat()
    except OSError as error:
        raise PackageStageError(f"{label} is missing or inaccessible: {error}") from error
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
        raise PackageStageError(f"{label} must be an ordinary directory; unsafe path rejected")
    descriptor = -1
    canonical_descriptor = -1
    try:
        descriptor = os.open(requested, _directory_open_flags())
        opened = os.fstat(descriptor)
        if _stable_tree_fields(opened) != _stable_tree_fields(before):
            raise PackageStageError(f"{label} changed before descriptor anchoring")
        resolved = _canonical_path(requested, label, strict=True)
        canonical_before = resolved.lstat()
        canonical_descriptor = os.open(resolved, _directory_open_flags())
        canonical_opened = os.fstat(canonical_descriptor)
        after_requested = requested.lstat()
        expected_identity = (opened.st_dev, opened.st_ino)
        if (
            not stat.S_ISDIR(canonical_before.st_mode)
            or (canonical_before.st_dev, canonical_before.st_ino) != expected_identity
            or (canonical_opened.st_dev, canonical_opened.st_ino) != expected_identity
            or (after_requested.st_dev, after_requested.st_ino) != expected_identity
            or stat.S_ISLNK(after_requested.st_mode)
        ):
            raise PackageStageError(f"{label} changed while its canonical path was proven")
        return resolved, descriptor, opened
    except OSError as error:
        if descriptor >= 0:
            os.close(descriptor)
        raise PackageStageError(f"{label} cannot be descriptor-anchored safely: {error}") from error
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        raise
    finally:
        if canonical_descriptor >= 0:
            os.close(canonical_descriptor)


def _verify(
    path: Path,
    package_digest_evidence: dict[str, tuple[int, str]] | None = None,
) -> dict[str, object]:
    try:
        return verify_materialization(
            path,
            _package_digest_evidence=package_digest_evidence,
        )
    except (PackageContractError, OSError, ValueError) as error:
        raise PackageStageError(f"package verification failed: {error}") from error


def _checked_verify(
    path: Path,
    label: str,
    package_digest_evidence: dict[str, tuple[int, str]] | None = None,
) -> dict[str, object]:
    try:
        return _verify(path, package_digest_evidence)
    except PackageStageError:
        raise
    except (PackageContractError, OSError, ValueError) as error:
        raise PackageStageError(f"{label} package verification failed: {error}") from error


def _directory_open_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )


def _closed_tree_snapshot(
    root_descriptor: int,
    *,
    prior_snapshot: tuple[tuple[str, str, tuple[int, ...], str | None], ...] | None = None,
    digest_evidence: dict[str, tuple[int, str]] | None = None,
    hash_files: bool = True,
) -> tuple[tuple[str, str, tuple[int, ...], str | None], ...]:
    """Capture a descriptor-rooted closed tree with stable identities for every entry."""

    records: list[tuple[str, str, tuple[int, ...], str | None]] = []
    prior = {relative: (kind, fields, digest) for relative, kind, fields, digest in prior_snapshot or ()}
    observed_files: set[str] = set()

    def visit(directory_descriptor: int, relative: PurePosixPath) -> None:
        directory_before = os.fstat(directory_descriptor)
        try:
            names = sorted(os.listdir(directory_descriptor), key=os.fsencode)
        except OSError as error:
            raise PackageStageError(f"closed package directory is inaccessible: {error}") from error
        for name in names:
            if any(character in name for character in ("\n", "\r", "\x00")):
                raise PackageStageError("closed package contains an unsafe path")
            child_relative = relative / name
            try:
                before = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
            except OSError as error:
                raise PackageStageError(f"closed package entry is inaccessible: {error}") from error
            if stat.S_ISLNK(before.st_mode):
                raise PackageStageError("closed package verification found a link or path escape")
            expected = _stable_tree_fields(before)
            if stat.S_ISDIR(before.st_mode):
                child_descriptor = -1
                try:
                    child_descriptor = os.open(
                        name,
                        _directory_open_flags(),
                        dir_fd=directory_descriptor,
                    )
                    if _stable_tree_fields(os.fstat(child_descriptor)) != expected:
                        raise PackageStageError("closed package directory changed before traversal")
                    visit(child_descriptor, child_relative)
                    after_descriptor = os.fstat(child_descriptor)
                finally:
                    if child_descriptor >= 0:
                        os.close(child_descriptor)
                after_path = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
                if (
                    _stable_tree_fields(after_descriptor) != expected
                    or _stable_tree_fields(after_path) != expected
                ):
                    raise PackageStageError("closed package directory changed during traversal")
                records.append((child_relative.as_posix(), "directory", expected, None))
                continue
            if not stat.S_ISREG(before.st_mode):
                raise PackageStageError(
                    "closed package verification found a non-regular special file"
                )
            if before.st_nlink != 1:
                raise PackageStageError("closed package verification found a hard-linked file")
            file_descriptor = -1
            try:
                file_descriptor = os.open(
                    name,
                    os.O_RDONLY
                    | getattr(os, "O_NOFOLLOW", 0)
                    | getattr(os, "O_CLOEXEC", 0),
                    dir_fd=directory_descriptor,
                )
                opened = os.fstat(file_descriptor)
                relative_path = child_relative.as_posix()
                observed_files.add(relative_path)
                if prior_snapshot is not None:
                    accepted = prior.get(relative_path)
                    if accepted is None or accepted[:2] != ("file", expected) or accepted[2] is None:
                        raise PackageStageError("closed package changed after its verified snapshot")
                    content_digest = accepted[2]
                elif digest_evidence is not None:
                    accepted_digest = digest_evidence.get(relative_path)
                    if accepted_digest is None or accepted_digest[0] != before.st_size:
                        raise PackageStageError("closed package differs from its receipt-bound file set")
                    content_digest = accepted_digest[1]
                elif not hash_files:
                    content_digest = None
                else:
                    digest = hashlib.sha256()
                    while block := os.read(file_descriptor, 1024 * 1024):
                        digest.update(block)
                    content_digest = digest.hexdigest()
                after_descriptor = os.fstat(file_descriptor)
            finally:
                if file_descriptor >= 0:
                    os.close(file_descriptor)
            after_path = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
            if (
                _stable_tree_fields(opened) != expected
                or _stable_tree_fields(after_descriptor) != expected
                or _stable_tree_fields(after_path) != expected
            ):
                raise PackageStageError("closed package file changed during traversal")
            records.append((child_relative.as_posix(), "file", expected, content_digest))
        if _stable_tree_fields(os.fstat(directory_descriptor)) != _stable_tree_fields(
            directory_before
        ):
            raise PackageStageError("closed package directory changed during enumeration")

    visit(root_descriptor, PurePosixPath())
    if digest_evidence is not None and observed_files != set(digest_evidence):
        raise PackageStageError("closed package omitted receipt-bound files")
    if prior_snapshot is not None and tuple(records) != prior_snapshot:
        raise PackageStageError("closed package changed after its verified snapshot")
    return tuple(records)


def _refresh_exact_tree_content(
    root_descriptor: int,
    expected_snapshot: tuple[tuple[str, str, tuple[int, ...], str | None], ...],
) -> tuple[tuple[str, str, tuple[int, ...], str | None], ...]:
    """Refresh content fields only when every pre-recorded path/kind/inode is unchanged."""

    observed_snapshot = _closed_tree_snapshot(root_descriptor)
    expected = {
        relative: (kind, fields)
        for relative, kind, fields, _digest in expected_snapshot
    }
    observed = {
        relative: (kind, fields)
        for relative, kind, fields, _digest in observed_snapshot
    }
    if set(observed) != set(expected):
        raise PackageStageError("owned tree paths changed before cleanup snapshot refresh")
    for relative, (expected_kind, expected_fields) in expected.items():
        observed_kind, observed_fields = observed[relative]
        if (
            observed_kind != expected_kind
            or observed_fields[:2] != expected_fields[:2]
            or stat.S_IFMT(observed_fields[2]) != stat.S_IFMT(expected_fields[2])
            or observed_fields[3] != expected_fields[3]
        ):
            raise PackageStageError("owned tree identity changed before cleanup snapshot refresh")
    return observed_snapshot


def _staged_receipt_path(canonical: Path, receipt_root: str | None = None) -> Path:
    raw = receipt_root or os.environ.get("MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT")
    if not raw:
        raise PackageStageError("staged package reuse requires the private build receipt directory")
    directory = Path(raw)
    metadata = directory.lstat()
    if (not directory.is_absolute() or directory.resolve(strict=True) != directory
            or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) & 0o077):
        raise PackageStageError("staged package receipts require a private canonical directory")
    key = hashlib.sha256(str(canonical).encode()).hexdigest()
    return directory / ("staged-sleigh-" + key + ".json")


def _publish_staged_receipt(canonical: Path, root_fields, snapshot, identity) -> None:
    if os.environ.get("MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE") != "shared-view":
        return
    receipt = _staged_receipt_path(canonical)
    value = {"version": 1, "root": str(canonical), "rootFields": root_fields,
             "snapshot": snapshot, "identity": identity}
    descriptor = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(value, output, sort_keys=True, separators=(",", ":"))
        output.write("\n")


def _reused_source_receipt(canonical: Path):
    helper_path = Path(__file__).resolve().parents[1] / "qualification/dev_dependency_cache.py"
    spec = importlib.util.spec_from_file_location("native_stage_dependency_receipt", helper_path)
    if spec is None or spec.loader is None:
        raise PackageStageError("shared dependency receipt reader is unavailable")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    return helper.reused_sleigh_materialization(helper_path.parents[2], canonical)


def _open_verified_materialization(
    path: Path,
    label: str,
    *,
    require_staged_receipt: bool = False,
) -> tuple[
    Path,
    int,
    tuple[int, ...],
    tuple[tuple[str, str, tuple[int, ...], str | None], ...],
    dict[str, object],
]:
    """Verify one materialization while retaining its descriptor-bound snapshot."""

    canonical, descriptor, root_metadata = _open_anchored_directory(path, label)
    try:
        root_fields = _stable_tree_fields(root_metadata)
        reused = None
        receipt_mode = os.environ.get("MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE", "")
        if receipt_mode == "shared-view":
            receipt = _staged_receipt_path(canonical)
            # A newly changed resource identity keeps its output receipts separate.
            # Admit the prior staged copy by its immutable content receipt;
            # publication of the replacement still writes only the current root.
            prior_root = os.environ.get("MACSCOPE_NATIVE_PRIOR_RECEIPT_ROOT")
            metadata = _receipt_metadata(receipt)
            if metadata is None and prior_root:
                prior = _staged_receipt_path(canonical, prior_root)
                prior_metadata = _receipt_metadata(prior)
                if prior_metadata is not None:
                    receipt, metadata = prior, prior_metadata
            if metadata is not None:
                if (not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1
                        or metadata.st_uid != os.getuid() or metadata.st_mode & 0o222):
                    raise PackageStageError("staged package receipt is not immutable and owner-controlled")
                value = json.loads(receipt.read_text(encoding="utf-8"))
                # Cross-run admission is content-only: relative paths, kinds,
                # sizes and the recorded SHA-256 of every file. The recorded
                # rootFields/per-entry lstat fields are historical and never
                # compared, so a reboot, copy or touch keeps the receipt valid.
                # A file is trusted to hold its recorded digest when its path
                # and size match; it is not rehashed (D1).
                if (not isinstance(value, dict)
                        or set(value) != {"version", "root", "rootFields", "snapshot", "identity"}
                        or value["version"] != 1 or value["root"] != str(canonical)
                        or not isinstance(value["identity"], dict)
                        or _stable_tree_fields(receipt.lstat()) != _stable_tree_fields(metadata)):
                    raise PackageStageError("staged package identity changed after first verification")
                recorded_files: dict[str, tuple[int, str]] = {}
                recorded_directories: set[str] = set()
                for relative, kind, fields, digest in value["snapshot"]:
                    if kind == "file" and isinstance(digest, str) and isinstance(fields[4], int):
                        recorded_files[relative] = (fields[4], digest)
                    elif kind == "directory" and digest is None:
                        recorded_directories.add(relative)
                    else:
                        raise PackageStageError("staged package receipt snapshot is malformed")
                try:
                    snapshot = _closed_tree_snapshot(descriptor, digest_evidence=recorded_files)
                except PackageStageError as error:
                    raise PackageStageError(f"staged package changed after first verification: {error}") from error
                if {relative for relative, kind, _fields, _digest in snapshot
                        if kind == "directory"} != recorded_directories:
                    raise PackageStageError("staged package changed after first verification: directory set")
                if not _source_root_is_anchored(canonical, descriptor):
                    raise PackageStageError("staged package root changed during receipt admission")
                # The fresh snapshot and root_fields carry this run's metadata
                # for the within-run descriptor-anchored revalidation.
                return canonical, descriptor, root_fields, snapshot, value["identity"]
            if require_staged_receipt:
                snapshot = _closed_tree_snapshot(descriptor, hash_files=False)
                if (_stable_tree_fields(os.fstat(descriptor)) != root_fields
                        or not _source_root_is_anchored(canonical, descriptor)):
                    raise PackageStageError("staged package changed during absent receipt admission")
                raise MissingStagedReceiptError(canonical, root_fields, snapshot)
            reused = _reused_source_receipt(canonical)
        elif receipt_mode:
            raise PackageStageError("unsupported native verification receipt mode")
        before = _closed_tree_snapshot(descriptor, digest_evidence=reused["files"] if reused else None)
        package_digest_evidence = {
            relative.removeprefix("package/"): (fields[4], digest)
            for relative, kind, fields, digest in before
            if kind == "file" and relative.startswith("package/") and digest is not None
        }
        identity = reused["identity"] if reused else _checked_verify(canonical, label, package_digest_evidence)
        after = _closed_tree_snapshot(descriptor, prior_snapshot=before)
        if reused:
            if _reused_source_receipt(canonical) != reused:
                raise PackageStageError("shared dependency receipt changed during staging admission")
        if before != after or not _source_root_is_anchored(canonical, descriptor):
            raise PackageStageError(f"{label} changed during descriptor-bound verification")
        return canonical, descriptor, root_fields, before, identity
    except Exception:
        os.close(descriptor)
        raise


def _revalidate_anchored_materialization(
    canonical: Path,
    descriptor: int,
    root_fields: tuple[int, ...],
    snapshot: tuple[tuple[str, str, tuple[int, ...], str | None], ...],
    label: str,
) -> tuple[tuple[str, str, tuple[int, ...], str | None], ...]:
    """Prove a previously verified materialization is still the exact same closed tree."""

    try:
        if _stable_tree_fields(os.fstat(descriptor)) != root_fields:
            raise PackageStageError(f"{label} root changed after verification")
        if not _source_root_is_anchored(canonical, descriptor):
            raise PackageStageError(f"{label} path changed after verification")
        observed_snapshot = _closed_tree_snapshot(descriptor, prior_snapshot=snapshot)
        if observed_snapshot != snapshot:
            raise PackageStageError(f"{label} closed tree changed after verification")
        return observed_snapshot
    except OSError as error:
        raise PackageStageError(f"{label} cannot be revalidated safely: {error}") from error


def _revalidate_directory_anchor(
    canonical: Path,
    descriptor: int,
    identity: tuple[int, int],
    label: str,
) -> None:
    try:
        opened = os.fstat(descriptor)
        observed = canonical.lstat()
    except OSError as error:
        raise PackageStageError(f"{label} parent changed or became inaccessible: {error}") from error
    if (
        not stat.S_ISDIR(opened.st_mode)
        or stat.S_ISLNK(observed.st_mode)
        or not stat.S_ISDIR(observed.st_mode)
        or (opened.st_dev, opened.st_ino) != identity
        or (observed.st_dev, observed.st_ino) != identity
    ):
        raise PackageStageError(f"{label} parent changed after descriptor anchoring")


def _open_anchored_file(
    path: Path,
    expected_payload: bytes,
    label: str,
    *,
    parent_descriptor: int | None = None,
) -> tuple[Path, int, tuple[int, ...], bytes]:
    descriptor = -1
    try:
        before = (
            path.lstat()
            if parent_descriptor is None
            else os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
        )
        descriptor = os.open(
            path if parent_descriptor is None else path.name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
            dir_fd=parent_descriptor,
        )
        opened = os.fstat(descriptor)
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or _stable_tree_fields(opened) != _stable_tree_fields(before)
        ):
            raise PackageStageError(f"published {label} is not the prepared singly linked file")
        payload = bytearray()
        while len(payload) <= len(expected_payload):
            block = os.read(
                descriptor,
                min(1024 * 1024, len(expected_payload) + 1 - len(payload)),
            )
            if not block:
                break
            payload.extend(block)
        after = os.fstat(descriptor)
        after_path = (
            path.lstat()
            if parent_descriptor is None
            else os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
        )
        fields = _stable_tree_fields(opened)
        if (
            bytes(payload) != expected_payload
            or _stable_tree_fields(after) != fields
            or _stable_tree_fields(after_path) != fields
        ):
            raise PackageStageError(f"published {label} changed before descriptor anchoring")
        return path, descriptor, fields, expected_payload
    except OSError as error:
        if descriptor >= 0:
            os.close(descriptor)
        raise PackageStageError(f"published {label} cannot be opened safely: {error}") from error
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        raise


def _revalidate_anchored_file(anchor, label: str) -> None:
    path, descriptor, fields, expected_payload = anchor
    try:
        if _stable_tree_fields(os.fstat(descriptor)) != fields:
            raise PackageStageError(f"published {label} descriptor changed")
        os.lseek(descriptor, 0, os.SEEK_SET)
        payload = bytearray()
        while len(payload) <= len(expected_payload):
            block = os.read(
                descriptor,
                min(1024 * 1024, len(expected_payload) + 1 - len(payload)),
            )
            if not block:
                break
            payload.extend(block)
        after = os.fstat(descriptor)
        after_path = path.lstat()
    except OSError as error:
        raise PackageStageError(f"published {label} cannot be revalidated safely: {error}") from error
    if (
        bytes(payload) != expected_payload
        or _stable_tree_fields(after) != fields
        or _stable_tree_fields(after_path) != fields
    ):
        raise PackageStageError(f"published {label} changed before the success boundary")


def _revalidate_publication_set(
    package_anchor,
    file_anchors,
    parent_anchors,
) -> None:
    """Final return-boundary proof for the exact published multi-object set."""

    canonical, descriptor, root_fields, snapshot = package_anchor
    _revalidate_anchored_materialization(
        canonical,
        descriptor,
        root_fields,
        snapshot,
        "published package",
    )
    for anchor, label in file_anchors:
        _revalidate_anchored_file(anchor, label)
    for canonical_parent, parent_descriptor, parent_identity, label in parent_anchors:
        _revalidate_directory_anchor(
            canonical_parent,
            parent_descriptor,
            parent_identity,
            label,
        )


def _open_source_file(root_descriptor: int, relative: PurePosixPath) -> int:
    components = relative.parts
    if not components or any(component in {"", ".", ".."} for component in components):
        raise PackageStageError("source package contains an unsafe relative path")
    directory_descriptor = os.dup(root_descriptor)
    try:
        for component in components[:-1]:
            try:
                next_descriptor = os.open(
                    component,
                    _directory_open_flags(),
                    dir_fd=directory_descriptor,
                )
            except OSError as error:
                raise PackageStageError(
                    f"source parent cannot be opened without following links: {error}"
                ) from error
            os.close(directory_descriptor)
            directory_descriptor = next_descriptor
        try:
            return os.open(
                components[-1],
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
                dir_fd=directory_descriptor,
            )
        except OSError as error:
            raise PackageStageError(f"source file cannot be opened safely: {error}") from error
    finally:
        os.close(directory_descriptor)


def _copy_file(
    source_root_descriptor: int,
    relative: PurePosixPath,
    destination_root_descriptor: int,
    destination_directories: dict[PurePosixPath, tuple[int, int]],
) -> None:
    """Copy one file using only root-anchored descriptor-relative opens."""

    source_descriptor = -1
    destination_parent_descriptor = -1
    try:
        source_descriptor = _open_source_file(source_root_descriptor, relative)
        destination_parent_descriptor = os.dup(destination_root_descriptor)
        destination_relative = PurePosixPath()
        for component in relative.parts[:-1]:
            destination_relative /= component
            created = False
            try:
                os.mkdir(component, mode=0o755, dir_fd=destination_parent_descriptor)
                created = True
            except FileExistsError:
                if destination_relative not in destination_directories:
                    raise PackageStageError(
                        "staging directory was occupied before this attempt created it"
                    )
            except OSError as error:
                raise PackageStageError(
                    f"staging directory cannot be created descriptor-relatively: {error}"
                ) from error
            try:
                next_descriptor = os.open(
                    component,
                    _directory_open_flags(),
                    dir_fd=destination_parent_descriptor,
                )
            except OSError as error:
                raise PackageStageError(
                    f"staging parent cannot be opened without following links: {error}"
                ) from error
            opened = os.fstat(next_descriptor)
            opened_identity = (opened.st_dev, opened.st_ino)
            if created:
                destination_directories[destination_relative] = opened_identity
            elif destination_directories[destination_relative] != opened_identity:
                os.close(next_descriptor)
                raise PackageStageError("staging directory changed during copy")
            os.close(destination_parent_descriptor)
            destination_parent_descriptor = next_descriptor
        metadata = os.fstat(source_descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise PackageStageError("source package contains a non-regular special file")
        if metadata.st_nlink != 1:
            raise PackageStageError("source package contains a hard-linked file")
        destination_flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
        )
        try:
            destination_descriptor = os.open(
                relative.name,
                destination_flags,
                stat.S_IMODE(metadata.st_mode),
                dir_fd=destination_parent_descriptor,
            )
        except OSError as error:
            raise PackageStageError(f"staging file cannot be created: {error}") from error
        try:
            while True:
                block = os.read(source_descriptor, 1024 * 1024)
                if not block:
                    break
                offset = 0
                while offset < len(block):
                    offset += os.write(destination_descriptor, block[offset:])
            os.fsync(destination_descriptor)
        finally:
            os.close(destination_descriptor)
        if _stable_tree_fields(os.fstat(source_descriptor)) != _stable_tree_fields(metadata):
            raise PackageStageError("source package file changed while it was copied")
    finally:
        if destination_parent_descriptor >= 0:
            os.close(destination_parent_descriptor)
        if source_descriptor >= 0:
            os.close(source_descriptor)


def _file_list_paths(root: Path, relative_files: Iterable[PurePosixPath]) -> list[str]:
    return [str(root / Path(relative.as_posix())) for relative in relative_files]


def _ensure_external_file_list(
    path: Path,
    roots: Iterable[Path],
    label: str,
) -> tuple[Path, Path]:
    path = _validated_path(path, label)
    parent = _ordinary_directory(path.parent, f"{label} parent")
    publication_path = parent / path.name
    canonical_path = _canonical_path(publication_path, label)
    for root in roots:
        if canonical_path.is_relative_to(root):
            raise PackageStageError(f"{label} must be outside the verified resource root")
    return publication_path, canonical_path


def _write_bytes_exclusively(
    path: Path,
    parent_descriptor: int,
    payload: bytes,
    label: str,
) -> tuple[Path, int, tuple[int, ...], bytes]:
    """Create one final metadata name directly and retain its exact descriptor."""

    flags = (
        os.O_RDWR
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    descriptor = -1
    try:
        descriptor = os.open(path.name, flags, 0o644, dir_fd=parent_descriptor)
        offset = 0
        while offset < len(payload):
            offset += os.write(descriptor, payload[offset:])
        os.fsync(descriptor)
        opened = os.fstat(descriptor)
        observed = os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
        fields = _stable_tree_fields(opened)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or _stable_tree_fields(observed) != fields
        ):
            raise PackageStageError(f"published {label} changed during direct creation")
        readable = os.dup(descriptor)
        os.close(descriptor)
        descriptor = readable
        os.lseek(descriptor, 0, os.SEEK_SET)
        return path, descriptor, fields, payload
    except OSError as error:
        if descriptor >= 0:
            os.close(descriptor)
        raise PackageStageError(f"cannot create {label} exclusively: {error}") from error
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        raise


def _source_root_is_anchored(path: Path, descriptor: int) -> bool:
    try:
        path_metadata = os.stat(path, follow_symlinks=False)
    except OSError:
        return False
    descriptor_metadata = os.fstat(descriptor)
    return (path_metadata.st_dev, path_metadata.st_ino) == (
        descriptor_metadata.st_dev,
        descriptor_metadata.st_ino,
    )


def _directory_has_identity(path: Path, identity: tuple[int, int]) -> bool:
    try:
        metadata = path.lstat()
    except OSError:
        return False
    return stat.S_ISDIR(metadata.st_mode) and (metadata.st_dev, metadata.st_ino) == identity


def _require_published_identity(
    path: Path,
    identity: tuple[int, int],
    label: str,
    *,
    directory: bool = False,
) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise PackageStageError(f"published {label} identity is unavailable: {error}") from error
    expected_kind = stat.S_ISDIR if directory else stat.S_ISREG
    if (
        not expected_kind(metadata.st_mode)
        or (metadata.st_dev, metadata.st_ino) != identity
        or (not directory and metadata.st_nlink != 1)
    ):
        raise PackageStageError(f"published {label} identity does not match prepared identity")


def _require_published_file_payload(
    path: Path,
    identity: tuple[int, int],
    expected_payload: bytes,
    label: str,
) -> None:
    """Stable-read one published singly linked file and require exact content."""

    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
        )
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or (before.st_dev, before.st_ino) != identity
        ):
            raise PackageStageError(f"published {label} is not the prepared singly linked file")
        payload = bytearray()
        while len(payload) <= len(expected_payload):
            block = os.read(descriptor, min(1024 * 1024, len(expected_payload) + 1 - len(payload)))
            if not block:
                break
            payload.extend(block)
        after_descriptor = os.fstat(descriptor)
        after_path = path.lstat()
    except OSError as error:
        raise PackageStageError(f"published {label} cannot be read safely: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    expected_fields = _stable_tree_fields(before)
    if (
        bytes(payload) != expected_payload
        or _stable_tree_fields(after_descriptor) != expected_fields
        or _stable_tree_fields(after_path) != expected_fields
    ):
        raise PackageStageError(f"published {label} changed before the success boundary")




def _stage_verified_package_anchored(
    source_anchor,
    destination: Path,
    input_path: Path,
    output_path: Path,
    parent_anchors,
    *,
    publish_file_lists: bool = True,
) -> dict[str, object]:
    """Publish only through caller-retained source and output-parent descriptors."""

    if len(parent_anchors) != 3:
        raise PackageStageError("anchored staging requires exact destination/input/output parents")
    source, source_descriptor, source_root_fields, source_snapshot, source_identity = source_anchor
    for path, anchor, label in (
        (destination, parent_anchors[0], "destination"),
        (input_path, parent_anchors[1], "input file list"),
        (output_path, parent_anchors[2], "output file list"),
    ):
        if path.parent != anchor[0]:
            raise PackageStageError(f"{label} path does not match its retained parent anchor")
        _revalidate_directory_anchor(anchor[0], anchor[1], anchor[2], label)
    _revalidate_anchored_materialization(
        source,
        source_descriptor,
        source_root_fields,
        source_snapshot,
        "source materialization root",
    )

    destination_parent_descriptor = parent_anchors[0][1]
    input_parent_descriptor = parent_anchors[1][1]
    output_parent_descriptor = parent_anchors[2][1]

    def entry_exists(parent_descriptor: int, name: str) -> bool:
        try:
            os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        except FileNotFoundError:
            return False
        except OSError as error:
            raise PackageStageError(f"publication entry cannot be inspected safely: {error}") from error
        return True

    if entry_exists(destination_parent_descriptor, destination.name):
        raise PackageStageError("destination materialization root already exists")
    for path, descriptor, label in (
        (input_path, input_parent_descriptor, "input file list"),
        (output_path, output_parent_descriptor, "output file list"),
    ):
        present = entry_exists(descriptor, path.name)
        if present == publish_file_lists:
            expectation = "already exists" if publish_file_lists else "is missing"
            raise PackageStageError(f"{label} {expectation}")

    try:
        relative_files = tuple(
            PurePosixPath(relative)
            for relative, kind, _fields, _digest in source_snapshot
            if kind == "file"
        )
        if not relative_files:
            raise PackageStageError("source package contains no files")

        try:
            os.mkdir(destination.name, mode=0o700, dir_fd=destination_parent_descriptor)
        except OSError as error:
            raise PackageStageError(
                f"destination materialization root cannot be created exclusively: {error}"
            ) from error
        destination_descriptor = -1
        published_file_anchors = []
        try:
            destination_descriptor = os.open(
                destination.name,
                _directory_open_flags(),
                dir_fd=destination_parent_descriptor,
            )
            destination_metadata = os.fstat(destination_descriptor)
            destination_observed = os.stat(
                destination.name,
                dir_fd=destination_parent_descriptor,
                follow_symlinks=False,
            )
            destination_identity = (
                destination_metadata.st_dev,
                destination_metadata.st_ino,
            )
            if (
                not stat.S_ISDIR(destination_observed.st_mode)
                or (destination_observed.st_dev, destination_observed.st_ino)
                != destination_identity
            ):
                raise PackageStageError("destination root changed during direct creation")

            destination_directories = {PurePosixPath(): destination_identity}
            for relative in relative_files:
                _copy_file(
                    source_descriptor,
                    relative,
                    destination_descriptor,
                    destination_directories,
                )

            try:
                _revalidate_anchored_materialization(
                    source,
                    source_descriptor,
                    source_root_fields,
                    source_snapshot,
                    "source materialization root",
                )
            except PackageStageError as error:
                raise PackageStageError(f"source changed during copy: {error}") from error

            staged_root_fields = _stable_tree_fields(os.fstat(destination_descriptor))
            staged_snapshot = _closed_tree_snapshot(destination_descriptor)
            staged_files = tuple(
                PurePosixPath(relative)
                for relative, kind, _fields, _digest in staged_snapshot
                if kind == "file"
            )
            staged_digest_evidence = {
                relative.removeprefix("package/"): (fields[4], digest)
                for relative, kind, fields, digest in staged_snapshot
                if kind == "file" and relative.startswith("package/") and digest is not None
            }
            if _checked_verify(destination, "staged", staged_digest_evidence) != source_identity or staged_files != relative_files:
                raise PackageStageError("staged package identity does not match source identity")

            input_values = _file_list_paths(source, relative_files)
            output_values = _file_list_paths(destination, relative_files)
            expected_input_payload = ("\n".join(input_values) + "\n").encode("utf-8")
            expected_output_payload = ("\n".join(output_values) + "\n").encode("utf-8")
            if publish_file_lists:
                input_anchor = _write_bytes_exclusively(
                    input_path,
                    input_parent_descriptor,
                    expected_input_payload,
                    "input file list",
                )
                published_file_anchors.append((input_anchor, "input file list"))
                output_anchor = _write_bytes_exclusively(
                    output_path,
                    output_parent_descriptor,
                    expected_output_payload,
                    "output file list",
                )
                published_file_anchors.append((output_anchor, "output file list"))
            else:
                input_anchor = _open_anchored_file(
                    input_path,
                    expected_input_payload,
                    "input file list",
                    parent_descriptor=input_parent_descriptor,
                )
                published_file_anchors.append((input_anchor, "input file list"))
                output_anchor = _open_anchored_file(
                    output_path,
                    expected_output_payload,
                    "output file list",
                    parent_descriptor=output_parent_descriptor,
                )
                published_file_anchors.append((output_anchor, "output file list"))

            _revalidate_anchored_materialization(
                destination,
                destination_descriptor,
                staged_root_fields,
                staged_snapshot,
                "directly published package",
            )
            _revalidate_anchored_materialization(
                source,
                source_descriptor,
                source_root_fields,
                source_snapshot,
                "source materialization root",
            )
            _revalidate_publication_set(
                (destination, destination_descriptor, staged_root_fields, staged_snapshot),
                published_file_anchors,
                parent_anchors,
            )
            _publish_staged_receipt(destination, staged_root_fields, staged_snapshot, source_identity)
            return source_identity
        finally:
            for anchor, _label in published_file_anchors:
                os.close(anchor[1])
            if destination_descriptor >= 0:
                os.close(destination_descriptor)
    finally:
        pass


def stage_verified_package(
    source_materialization_root: Path,
    destination_materialization_root: Path,
    input_file_list: Path,
    output_file_list: Path,
    *,
    publish_file_lists: bool = True,
) -> dict[str, object]:
    """Acquire anchors once, publish through them, and release them on every path."""

    source_requested = _validated_path(
        Path(source_materialization_root),
        "source materialization root",
    )
    destination_requested = _validated_path(
        Path(destination_materialization_root),
        "destination materialization root",
    )
    input_requested = _validated_path(Path(input_file_list), "input file list")
    output_requested = _validated_path(Path(output_file_list), "output file list")

    source_anchor = None
    parent_anchors = []
    try:
        source_anchor = _open_verified_materialization(
            source_requested,
            "source materialization root",
        )
        source = source_anchor[0]
        destination_parent, destination_descriptor, destination_metadata = (
            _open_anchored_directory(destination_requested.parent, "destination parent")
        )
        parent_anchors.append(
            (
                destination_parent,
                destination_descriptor,
                (destination_metadata.st_dev, destination_metadata.st_ino),
                "destination",
            )
        )
        destination = destination_parent / destination_requested.name
        destination_canonical = _canonical_path(
            destination,
            "destination materialization root",
        )
        input_path, input_canonical = _ensure_external_file_list(
            input_requested,
            (source, destination_canonical),
            "input file list",
        )
        output_path, output_canonical = _ensure_external_file_list(
            output_requested,
            (source, destination_canonical),
            "output file list",
        )
        if input_canonical == output_canonical:
            raise PackageStageError("input and output file-list paths must be distinct")
        for path, label in (
            (input_path, "input file list"),
            (output_path, "output file list"),
        ):
            parent, descriptor, metadata = _open_anchored_directory(
                path.parent,
                f"{label} parent",
            )
            parent_anchors.append(
                (
                    parent,
                    descriptor,
                    (metadata.st_dev, metadata.st_ino),
                    label,
                )
            )
        return _stage_verified_package_anchored(
            source_anchor,
            destination,
            input_path,
            output_path,
            tuple(parent_anchors),
            publish_file_lists=publish_file_lists,
        )
    finally:
        if source_anchor is not None:
            os.close(source_anchor[1])
        for _parent, descriptor, _identity, _label in parent_anchors:
            os.close(descriptor)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-materialization-root", type=Path, required=True)
    parser.add_argument("--destination-materialization-root", type=Path, required=True)
    parser.add_argument("--input-file-list", type=Path, required=True)
    parser.add_argument("--output-file-list", type=Path, required=True)
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    try:
        stage_verified_package(
            arguments.source_materialization_root,
            arguments.destination_materialization_root,
            arguments.input_file_list,
            arguments.output_file_list,
        )
    except PackageStageError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
