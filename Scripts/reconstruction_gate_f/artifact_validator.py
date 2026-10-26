"""Descriptor-relative artifact validation with no symlink or traversal authority."""

from __future__ import annotations

import errno
import hashlib
import os
import re
import stat
from collections.abc import Mapping, Sequence
from pathlib import Path, PurePosixPath
from typing import Any

from .receipt_schema import ARTIFACT_FIELDS, ARTIFACT_SCHEMA_VERSION
from .schema import (
    ArtifactKind,
    EvidenceLayer,
    STABLE_ID_RE,
    ValidationIssue,
    closed_record,
    enum_value,
    is_integer,
    is_sha256,
)

MEDIA_TYPE_RE = re.compile(r"^[a-z0-9][a-z0-9.+-]{0,63}/[a-z0-9][a-z0-9.+-]{0,63}$")


def safe_relative_artifact_path(value: object) -> bool:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        return False
    path = PurePosixPath(value)
    return (
        not path.is_absolute()
        and str(path) == value
        and all(part not in {"", ".", ".."} for part in path.parts)
    )


def _open_root_without_symlinks(root: Path, descriptors: list[int]) -> int:
    if not root.is_absolute() or Path(os.path.normpath(str(root))) != root:
        raise OSError(errno.EINVAL, "artifact root must be canonical and absolute", str(root))
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    cloexec = getattr(os, "O_CLOEXEC", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    current_fd = os.open(root.anchor, os.O_RDONLY | directory | nofollow | cloexec)
    descriptors.append(current_fd)
    for component in root.parts[1:]:
        metadata = os.stat(component, dir_fd=current_fd, follow_symlinks=False)
        if stat.S_ISLNK(metadata.st_mode):
            raise OSError(errno.ELOOP, "symlink root component", component)
        next_fd = os.open(
            component,
            os.O_RDONLY | directory | nofollow | cloexec,
            dir_fd=current_fd,
        )
        descriptors.append(next_fd)
        current_fd = next_fd
    return current_fd


def read_descriptor_relative_bytes(
    root: Path,
    relative_path: str,
    *,
    maximum_bytes: int | None = None,
) -> tuple[bytes, int, str]:
    """Read one ordinary artifact through a rooted no-follow descriptor chain.

    This is intentionally the byte-bearing counterpart to the descriptor
    validator below.  Semantic receipt validators must not validate a path and
    then reopen that path by name: a rename between those operations would make
    the semantic assertion describe different bytes than the descriptor.
    """
    parts = PurePosixPath(relative_path).parts
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    cloexec = getattr(os, "O_CLOEXEC", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    nonblock = getattr(os, "O_NONBLOCK", 0)
    descriptors: list[int] = []
    try:
        root_fd = _open_root_without_symlinks(root, descriptors)
        if not stat.S_ISDIR(os.fstat(root_fd).st_mode):
            raise NotADirectoryError(str(root))
        current_fd = root_fd
        for component in parts[:-1]:
            metadata = os.stat(component, dir_fd=current_fd, follow_symlinks=False)
            if stat.S_ISLNK(metadata.st_mode):
                raise OSError(errno.ELOOP, "symlink component", component)
            next_fd = os.open(
                component,
                os.O_RDONLY | directory | nofollow | cloexec,
                dir_fd=current_fd,
            )
            descriptors.append(next_fd)
            current_fd = next_fd
        final = parts[-1]
        metadata = os.stat(final, dir_fd=current_fd, follow_symlinks=False)
        if stat.S_ISLNK(metadata.st_mode):
            raise OSError(errno.ELOOP, "symlink artifact", final)
        file_fd = os.open(
            final,
            os.O_RDONLY | nofollow | cloexec | nonblock,
            dir_fd=current_fd,
        )
        descriptors.append(file_fd)
        before = os.fstat(file_fd)
        if not stat.S_ISREG(before.st_mode):
            raise OSError(errno.EINVAL, "artifact is not a regular file", final)
        if maximum_bytes is not None and before.st_size > maximum_bytes:
            raise OSError(errno.EFBIG, "artifact exceeds caller's byte bound", final)
        digest = hashlib.sha256()
        chunks: list[bytes] = []
        observed_bytes = 0
        while True:
            read_size = 1024 * 1024
            if maximum_bytes is not None:
                # One sentinel byte distinguishes exact-bound EOF from growth;
                # never allocate a full chunk beyond the remaining allowance.
                read_size = min(read_size, maximum_bytes - observed_bytes + 1)
            chunk = os.read(file_fd, read_size)
            if not chunk:
                break
            observed_bytes += len(chunk)
            if maximum_bytes is not None and observed_bytes > maximum_bytes:
                raise OSError(errno.EFBIG, "artifact exceeds caller's byte bound", final)
            digest.update(chunk)
            chunks.append(chunk)
        after = os.fstat(file_fd)
        stable = (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        ) == (
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        if not stable:
            raise OSError(errno.ESTALE, "artifact changed while hashing", final)
        return b"".join(chunks), before.st_size, digest.hexdigest()
    finally:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass


def _read_descriptor_relative(root: Path, relative_path: str) -> tuple[int, str]:
    _, size, digest = read_descriptor_relative_bytes(root, relative_path)
    return size, digest


def validate_artifact_record(
    value: object,
    *,
    expected_candidate_sha256: str,
    expected_layer: EvidenceLayer,
    expected_root_id: str,
    expected_receipt_id: str,
    expected_command_id: str,
    root: Path | None,
    path: str = "$.artifacts[0]",
) -> tuple[ValidationIssue, ...]:
    record, issues = closed_record(value, ARTIFACT_FIELDS, path=path)
    if record is None:
        return tuple(issues)
    if not is_integer(record.get("schema_version")) or record.get("schema_version") != ARTIFACT_SCHEMA_VERSION:
        issues.append(ValidationIssue("artifact-schema-version", f"{path}.schema_version", "unsupported artifact schema"))
    artifact_id = record.get("artifact_id")
    if not isinstance(artifact_id, str) or STABLE_ID_RE.fullmatch(artifact_id) is None:
        issues.append(ValidationIssue("artifact-id", f"{path}.artifact_id", "invalid stable artifact ID"))
    candidate_digest = record.get("candidate_identity_sha256")
    if not is_sha256(candidate_digest):
        issues.append(ValidationIssue("sha256", f"{path}.candidate_identity_sha256", "invalid candidate digest"))
    elif candidate_digest != expected_candidate_sha256:
        issues.append(ValidationIssue("artifact-candidate-mismatch", f"{path}.candidate_identity_sha256", "artifact belongs to another candidate"))
    layer, nested = enum_value(EvidenceLayer, record.get("evidence_layer"), path=f"{path}.evidence_layer")
    issues.extend(nested)
    if layer is not None and layer != expected_layer:
        issues.append(ValidationIssue("artifact-layer-mismatch", f"{path}.evidence_layer", "artifact belongs to another evidence layer"))
    for field, expected in (
        ("root_id", expected_root_id),
        ("producer_receipt_id", expected_receipt_id),
        ("command_id", expected_command_id),
    ):
        observed = record.get(field)
        if not isinstance(observed, str) or STABLE_ID_RE.fullmatch(observed) is None:
            issues.append(ValidationIssue("artifact-binding-id", f"{path}.{field}", "invalid stable binding ID"))
        elif observed != expected:
            issues.append(ValidationIssue("artifact-binding-mismatch", f"{path}.{field}", "artifact binding differs from its receipt plan"))
    relative_path = record.get("relative_path")
    if not safe_relative_artifact_path(relative_path):
        issues.append(ValidationIssue("artifact-path", f"{path}.relative_path", "path must be a safe relative POSIX path"))
    _, nested = enum_value(ArtifactKind, record.get("kind"), path=f"{path}.kind")
    issues.extend(nested)
    media_type = record.get("media_type")
    if not isinstance(media_type, str) or MEDIA_TYPE_RE.fullmatch(media_type) is None:
        issues.append(ValidationIssue("artifact-media-type", f"{path}.media_type", "invalid canonical media type"))
    byte_count = record.get("byte_count")
    if not is_integer(byte_count) or byte_count < 0:
        issues.append(ValidationIssue("artifact-byte-count", f"{path}.byte_count", "must be a nonnegative integer"))
    digest = record.get("sha256")
    if not is_sha256(digest):
        issues.append(ValidationIssue("sha256", f"{path}.sha256", "invalid artifact digest"))

    if root is not None and safe_relative_artifact_path(relative_path):
        try:
            observed_size, observed_digest = _read_descriptor_relative(root, relative_path)
        except FileNotFoundError:
            issues.append(ValidationIssue("artifact-missing", f"{path}.relative_path", "artifact does not exist below the declared root"))
        except NotADirectoryError:
            issues.append(ValidationIssue("artifact-root", f"{path}.relative_path", "root or path component is not a directory"))
        except OSError as error:
            code = "artifact-symlink" if error.errno in {errno.ELOOP, errno.EMLINK} else (
                "artifact-changed" if error.errno == errno.ESTALE else "artifact-not-regular"
            )
            issues.append(ValidationIssue(code, f"{path}.relative_path", "artifact could not be safely opened"))
        else:
            if is_integer(byte_count) and observed_size != byte_count:
                issues.append(ValidationIssue("artifact-byte-count-mismatch", f"{path}.byte_count", "recorded size differs from file"))
            if is_sha256(digest) and observed_digest != digest:
                issues.append(ValidationIssue("artifact-sha256-mismatch", f"{path}.sha256", "recorded digest differs from file"))
    return tuple(sorted(set(issues)))


def validate_artifact_records(
    values: object,
    *,
    expected_candidate_sha256: str,
    expected_layer: EvidenceLayer,
    expected_root_id: str,
    expected_receipt_id: str,
    expected_command_id: str,
    root: Path | None,
    path: str = "$.artifacts",
) -> tuple[ValidationIssue, ...]:
    if not isinstance(values, list):
        return (ValidationIssue("array-type", path, "artifacts must be an array"),)
    issues: list[ValidationIssue] = []
    seen: set[str] = set()
    seen_paths: set[str] = set()
    for index, value in enumerate(values):
        issues.extend(
            validate_artifact_record(
                value,
                expected_candidate_sha256=expected_candidate_sha256,
                expected_layer=expected_layer,
                expected_root_id=expected_root_id,
                expected_receipt_id=expected_receipt_id,
                expected_command_id=expected_command_id,
                root=root,
                path=f"{path}[{index}]",
            )
        )
        if isinstance(value, Mapping) and isinstance(value.get("artifact_id"), str):
            artifact_id = value["artifact_id"]
            if artifact_id in seen:
                issues.append(ValidationIssue("duplicate-artifact-id", f"{path}[{index}].artifact_id", "artifact ID is duplicated"))
            seen.add(artifact_id)
        if isinstance(value, Mapping) and isinstance(value.get("relative_path"), str):
            relative_path = value["relative_path"]
            if relative_path in seen_paths:
                issues.append(ValidationIssue("duplicate-artifact-path", f"{path}[{index}].relative_path", "artifact path is duplicated"))
            seen_paths.add(relative_path)
    return tuple(sorted(set(issues)))
