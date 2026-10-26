#!/usr/bin/env python3
"""Create and verify canonical, Git-less MacScope source exports."""

from __future__ import annotations

import argparse
import base64
import binascii
import configparser
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
from typing import Any, Optional, Sequence


SCHEMA_VERSION = 2
PACKAGE_CONTRACT_VERSION = 4
FILES_NAME = "SOURCE_FILES.json"
PROVENANCE_NAME = "SOURCE_PROVENANCE.json"
COMMIT_OBJECT_NAME = "SOURCE_COMMIT_OBJECT"
MAX_FILES = 100_000
MAX_TOTAL_BYTES = 4 * 1024 * 1024 * 1024
MAX_RECORD_BYTES = 32 * 1024 * 1024
MAX_COMMIT_OBJECT_BYTES = 4 * 1024 * 1024
MAX_SUBMODULES = 256
MAX_SUBMODULE_COMMIT_BYTES = 8 * 1024 * 1024
HEX_SHA1 = re.compile(r"[0-9a-f]{40}")
HEX_SHA256 = re.compile(r"[0-9a-f]{64}")
FULL_REMOTE_REF = re.compile(r"refs/remotes/([^/]+)/(.+)")
LFS_PATHS = frozenset({
    "ThirdParty/Zig/zig-0.16.0/zig",
    "ThirdParty/SleighNative/package/lib/libdecomp.a",
})
LFS_HEADER = b"version https://git-lfs.github.com/spec/v1"


def _lfs_pointer(digest: str, size: int) -> bytes:
    return LFS_HEADER + f"\noid sha256:{digest}\nsize {size}\n".encode("ascii")


def _pointer_blob_oid(digest: str, size: int) -> str:
    pointer = _lfs_pointer(digest, size)
    return hashlib.sha1(f"blob {len(pointer)}\0".encode("ascii") + pointer).hexdigest()


def _parse_lfs_pointer(prefix: bytes, size: int, relative: str) -> tuple[str, int] | None:
    if not prefix.startswith(LFS_HEADER):
        return None
    if relative not in LFS_PATHS:
        raise SourceExportError(f"unsupported LFS source path: {relative}")
    match = re.fullmatch(
        rb"version https://git-lfs.github.com/spec/v1\noid sha256:([0-9a-f]{64})\nsize ([1-9][0-9]*)\n",
        prefix,
    )
    if match is None or len(prefix) != size:
        raise SourceExportError(f"noncanonical LFS pointer: {relative}")
    payload_size = int(match.group(2))
    if payload_size > MAX_TOTAL_BYTES:
        raise SourceExportError("LFS payload exceeds the aggregate-size bound")
    return match.group(1).decode("ascii"), payload_size


def _copy_lfs_payload(root: Path, relative: str, target: int, mode: str,
                      digest: str, size: int) -> None:
    source = _require_safe_relative_file(root, relative)
    before = source.lstat()
    permissions = 0o755 if mode == "100755" else 0o644
    if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or before.st_size != size or stat.S_IMODE(before.st_mode) != permissions):
        raise SourceExportError(f"LFS payload must be a materialized ordinary file: {relative}")
    stable = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    binding = tuple(getattr(before, field) for field in stable)
    flags = getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(source, os.O_RDONLY | flags)
    try:
        if tuple(getattr(os.fstat(descriptor), field) for field in stable) != binding:
            raise SourceExportError("LFS payload changed before copying")
        target_metadata = os.fstat(target)
        if not stat.S_ISREG(target_metadata.st_mode) or target_metadata.st_nlink != 1:
            raise SourceExportError("LFS export output is not one ordinary file")
        os.lseek(target, 0, os.SEEK_SET)
        os.ftruncate(target, 0)
        observed = hashlib.sha256()
        remaining = size
        while remaining:
            block = os.read(descriptor, min(1024 * 1024, remaining))
            if not block:
                raise SourceExportError("LFS payload truncated during copying")
            remaining -= len(block)
            observed.update(block)
            view = memoryview(block)
            while view:
                view = view[os.write(target, view):]
        if os.read(descriptor, 1) or observed.hexdigest() != digest:
            raise SourceExportError("LFS payload does not match its canonical Git pointer")
        after = _require_safe_relative_file(root, relative).lstat()
        if any(tuple(getattr(item, field) for field in stable) != binding
               for item in (os.fstat(descriptor), after)):
            raise SourceExportError("LFS payload changed during copying")
    finally:
        os.close(descriptor)


class SourceExportError(RuntimeError):
    """The source tree or its provenance violated the export contract."""


def _validated_integration_ref(integration_ref: str) -> tuple[str, str]:
    match = FULL_REMOTE_REF.fullmatch(integration_ref)
    if (
        match is None
        or len(integration_ref) > 256
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in integration_ref)
        or match.group(2) == "HEAD"
        or any(
            component in {"", ".", ".."}
            for component in match.group(2).split("/")
        )
    ):
        raise SourceExportError(
            "integration ref must be an explicit fully-qualified refs/remotes/<remote>/<branch>"
        )
    # Verification of a sealed export must not depend on a Git installation or repository.
    if (any(character in integration_ref for character in " ~^:?*[\\")
            or ".." in integration_ref or "@{" in integration_ref
            or integration_ref.endswith(".")
            or any(part.startswith(".") or part.endswith(".lock")
                   for part in integration_ref.split("/"))):
        raise SourceExportError(
            "integration ref must be a canonical Git refs/remotes/<remote>/<branch> name"
        )
    return match.group(1), match.group(2)


def _integration_remote(root: Path, integration_ref: str) -> tuple[str, str]:
    remote, _branch = _validated_integration_ref(integration_ref)
    remote_url = _required_git_text(root, "remote", "get-url", remote)
    if len(remote_url) > 2048 or any(ord(character) < 0x20 for character in remote_url):
        raise SourceExportError("authorized integration remote URL is malformed")
    return remote, remote_url


def _canonical_json(value: object) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=True,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


def _object_without_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SourceExportError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _read_stable_bounded_file(
    path: Path,
    maximum_bytes: int,
    label: str,
    *,
    expected_mode: int | None = None,
) -> bytes:
    try:
        before = path.lstat()
    except FileNotFoundError as error:
        raise SourceExportError(f"{label} is missing") from error
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size <= 0
        or before.st_size > maximum_bytes
        or (
            expected_mode is not None
            and stat.S_IMODE(before.st_mode) != expected_mode
        )
    ):
        raise SourceExportError(f"{label} must be one bounded ordinary file")
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
        )
        opened = os.fstat(descriptor)
        remaining = maximum_bytes + 1
        chunks: list[bytes] = []
        while remaining:
            block = os.read(descriptor, min(1024 * 1024, remaining))
            if not block:
                break
            chunks.append(block)
            remaining -= len(block)
        after_descriptor = os.fstat(descriptor)
    except OSError as error:
        raise SourceExportError(f"{label} could not be read safely") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    try:
        after_path = path.lstat()
    except OSError as error:
        raise SourceExportError(f"{label} changed while read") from error
    stable = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    payload = b"".join(chunks)
    if (
        len(payload) != before.st_size
        or len(payload) > maximum_bytes
        or any(
            getattr(before, field) != getattr(opened, field)
            or getattr(before, field) != getattr(after_descriptor, field)
            or getattr(before, field) != getattr(after_path, field)
            for field in stable
        )
    ):
        raise SourceExportError(f"{label} changed while read")
    return payload


def _load_canonical_json(path: Path) -> tuple[dict[str, Any], bytes]:
    payload = _read_stable_bounded_file(
        path,
        MAX_RECORD_BYTES,
        f"source record {path.name}",
    )
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_object_without_duplicate_keys,
            parse_constant=lambda token: (_ for _ in ()).throw(
                SourceExportError(f"invalid JSON constant: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SourceExportError(f"source record is malformed: {path.name}") from error
    if not isinstance(value, dict) or _canonical_json(value) != payload:
        raise SourceExportError(f"source record is not canonical: {path.name}")
    return value, payload


def _git(root: Path, *arguments: str, text: bool = False) -> subprocess.CompletedProcess:
    environment = os.environ.copy()
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    environment["GIT_NO_LAZY_FETCH"] = "1"
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    return subprocess.run(
        ["/usr/bin/git", *arguments],
        cwd=root,
        check=False,
        capture_output=True,
        env=environment,
        text=text,
    )


def _required_git_text(root: Path, *arguments: str) -> str:
    result = _git(root, *arguments, text=True)
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or "git command failed"
        raise SourceExportError(diagnostic)
    value = result.stdout.strip()
    if not value or "\n" in value or "\r" in value:
        raise SourceExportError(f"git {' '.join(arguments)} returned invalid text")
    return value


def _commit_object_oid(payload: bytes) -> str:
    digest = hashlib.sha1()
    digest.update(f"commit {len(payload)}\0".encode("ascii"))
    digest.update(payload)
    return digest.hexdigest()


def _commit_object_identity(payload: bytes) -> tuple[str, list[str]]:
    header, separator, _message = payload.partition(b"\n\n")
    if not separator or not header:
        raise SourceExportError("canonical Git commit object is malformed")
    tree_values: list[str] = []
    parents: list[str] = []
    previous_key: bytes | None = None
    for line in header.split(b"\n"):
        if line.startswith(b" "):
            if previous_key is None:
                raise SourceExportError("canonical Git commit object has an orphan continuation")
            continue
        key, separator, value = line.partition(b" ")
        if not separator or not key or not value:
            raise SourceExportError("canonical Git commit object has a malformed header")
        try:
            key.decode("ascii", errors="strict")
        except UnicodeError as error:
            raise SourceExportError("canonical Git commit object has a non-ASCII header") from error
        previous_key = key
        if key not in {b"tree", b"parent"}:
            continue
        try:
            object_id = value.decode("ascii", errors="strict")
        except UnicodeError as error:
            raise SourceExportError("canonical Git commit object has a malformed object ID") from error
        if HEX_SHA1.fullmatch(object_id) is None:
            raise SourceExportError("canonical Git commit object has a malformed object ID")
        if key == b"tree":
            tree_values.append(object_id)
        else:
            parents.append(object_id)
    if len(tree_values) != 1:
        raise SourceExportError("canonical Git commit object must contain exactly one tree")
    return tree_values[0], parents


def _canonical_git_commit_object(root: Path, object_id: str) -> bytes:
    if HEX_SHA1.fullmatch(object_id) is None:
        raise SourceExportError("Git commit object ID is malformed")
    if _required_git_text(root, "cat-file", "-t", object_id) != "commit":
        raise SourceExportError("authorized Git source object is not a commit")
    size_text = _required_git_text(root, "cat-file", "-s", object_id)
    if not size_text.isdigit():
        raise SourceExportError("canonical Git commit object size is malformed")
    size = int(size_text)
    if size <= 0 or size > MAX_COMMIT_OBJECT_BYTES:
        raise SourceExportError("canonical Git commit object exceeds its fixed size bound")
    result = _git(root, "cat-file", "commit", object_id)
    if result.returncode != 0 or result.stderr or len(result.stdout) != size:
        raise SourceExportError("canonical Git commit object could not be read exactly")
    payload = bytes(result.stdout)
    if _commit_object_oid(payload) != object_id:
        raise SourceExportError("canonical Git commit bytes do not match their object ID")
    return payload


def _read_exported_commit_object(path: Path) -> bytes:
    return _read_stable_bounded_file(
        path,
        MAX_COMMIT_OBJECT_BYTES,
        "canonical Git commit object",
        expected_mode=0o644,
    )


def _canonical_relative_path(raw: str) -> str:
    if not raw or any(ord(character) < 0x20 or ord(character) == 0x7F for character in raw):
        raise SourceExportError("source path contains a control character")
    try:
        raw.encode("utf-8", errors="strict")
    except UnicodeError as error:
        raise SourceExportError("source path is not UTF-8") from error
    path = PurePosixPath(raw)
    if path.is_absolute() or raw != path.as_posix() or any(
        part in {"", ".", ".."} for part in path.parts
    ):
        raise SourceExportError("source path must be canonical and repository-relative")
    if path.parts[0] in {FILES_NAME, PROVENANCE_NAME, COMMIT_OBJECT_NAME} or any(
        part.casefold() == ".git" for part in path.parts
    ):
        raise SourceExportError("source path collides with reserved export metadata")
    return raw


def _require_clean_git_root(root: Path) -> None:
    root = root.resolve(strict=True)
    top_level = Path(_required_git_text(root, "rev-parse", "--show-toplevel")).resolve(
        strict=True
    )
    if top_level != root:
        raise SourceExportError("repository root does not match the Git worktree root")
    status = _git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none")
    if status.returncode != 0:
        raise SourceExportError("could not verify clean repository status")
    if status.stdout:
        raise SourceExportError("source export requires a clean Git worktree")


def _require_safe_relative_file(root: Path, relative: str) -> Path:
    current = root
    parts = PurePosixPath(_canonical_relative_path(relative)).parts
    for part in parts[:-1]:
        current = current / part
        metadata = current.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise SourceExportError(f"source path has an unsafe ancestor: {relative}")
    candidate = root / relative
    if candidate.resolve(strict=True) != candidate:
        raise SourceExportError(f"source path is not canonical and symlink-free: {relative}")
    return candidate


def _tracked_entries(root: Path, revision: str, *, allow_gitlinks: bool = False,
                     allow_empty: bool = False) -> list[tuple[str, str, str]]:
    result = _git(root, "ls-tree", "-r", "-z", revision)
    if result.returncode != 0:
        raise SourceExportError("could not enumerate HEAD source files")
    entries: list[tuple[str, str, str]] = []
    for raw_record in result.stdout.split(b"\0"):
        if not raw_record:
            continue
        try:
            metadata, raw_path = raw_record.split(b"\t", 1)
            mode, object_type, object_id = metadata.decode("ascii").split(" ")
            relative = raw_path.decode("utf-8", errors="strict")
        except (ValueError, UnicodeError) as error:
            raise SourceExportError("HEAD contains an unsupported tree record") from error
        relative = _canonical_relative_path(relative)
        ordinary = mode in {"100644", "100755"} and object_type == "blob"
        gitlink = allow_gitlinks and mode == "160000" and object_type == "commit"
        if not ordinary and not gitlink:
            raise SourceExportError(
                f"source export accepts only ordinary HEAD blobs: {relative}"
            )
        if HEX_SHA1.fullmatch(object_id) is None:
            raise SourceExportError("HEAD contains a malformed object identifier")
        entries.append((relative, mode, object_id))
        if len(entries) > MAX_FILES:
            raise SourceExportError("source export exceeds the file-count bound")
    if not entries and not allow_empty:
        raise SourceExportError("source export must not be empty")
    entries.sort(key=lambda entry: os.fsencode(entry[0]))
    return entries


def _ordinary_file_identity(path: Path) -> tuple[str, int, str, tuple[int, ...]]:
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise SourceExportError(f"source input must be one ordinary file: {path}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(path, flags)
    digest = hashlib.sha256()
    blob_digest = hashlib.sha1()
    blob_digest.update(f"blob {before.st_size}\0".encode("ascii"))
    size = 0
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_size) != (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_size,
        ):
            raise SourceExportError("source input changed before hashing")
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            digest.update(block)
            blob_digest.update(block)
            size += len(block)
        after_descriptor = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    after_path = path.lstat()
    stable = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(
        getattr(before, field) != getattr(after_descriptor, field)
        or getattr(before, field) != getattr(after_path, field)
        for field in stable
    ):
        raise SourceExportError("source input changed during hashing")
    if size != before.st_size:
        raise SourceExportError("source input size changed during hashing")
    return (
        digest.hexdigest(),
        size,
        blob_digest.hexdigest(),
        tuple(getattr(after_path, field) for field in stable),
    )


def _gitmodule_mapping(root: Path, records: Sequence[dict[str, object]]) -> dict[str, str]:
    """Parse the tracked canonical .gitmodules bytes, never local Git config."""
    record = next((record for record in records if record["path"] == ".gitmodules"), None)
    if record is None:
        raise SourceExportError("submodule export requires tracked .gitmodules")
    payload = _read_stable_bounded_file(
        _require_safe_relative_file(root, ".gitmodules"), MAX_RECORD_BYTES, ".gitmodules"
    )
    # Bind the bytes actually parsed, not a later reread after a transient path/content swap.
    if hashlib.sha1(f"blob {len(payload)}\0".encode() + payload).hexdigest() != record["blob_oid"]:
        raise SourceExportError("tracked .gitmodules does not match its manifest blob")
    return _parse_gitmodule_mapping(payload)


def _parse_gitmodule_mapping(payload: bytes) -> dict[str, str]:
    parser = configparser.RawConfigParser(
        strict=True, delimiters=("=",), interpolation=None,
        inline_comment_prefixes=None,
    )
    try:
        parser.read_string(payload.decode("utf-8", errors="strict"))
    except (UnicodeError, configparser.Error) as error:
        raise SourceExportError("tracked .gitmodules is malformed") from error
    if parser.defaults() or len(parser.sections()) > MAX_SUBMODULES:
        raise SourceExportError("tracked .gitmodules has unsupported defaults or too many modules")
    mappings: dict[str, str] = {}
    for section in parser.sections():
        if re.fullmatch(r'submodule "[^"\r\n]+"', section) is None:
            raise SourceExportError("tracked .gitmodules has an unsupported section")
        values = dict(parser.items(section))
        if not {"path", "url"} <= set(values):
            raise SourceExportError("tracked .gitmodules lacks a path or URL")
        resolved: dict[str, str] = {}
        for key in ("path", "url"):
            value = values[key]
            if value.startswith('"'):
                # Deliberately accept only the overlap of Git and JSON quoting, not JSON's
                # slash/Unicode escapes or Git's concatenated quoted/unquoted segments.
                if re.fullmatch(r'"(?:[^"\\\x00-\x1f]|\\["\\ntb])*"', value) is None:
                    raise SourceExportError("tracked .gitmodules has unsupported quoted value syntax")
                try:
                    value = json.loads(value)
                except json.JSONDecodeError as error:
                    raise SourceExportError("tracked .gitmodules has invalid quoting") from error
            elif any(character in value for character in '#;"\\'):
                raise SourceExportError("tracked .gitmodules has unsupported unquoted value syntax")
            if not isinstance(value, str) or not value or len(value) > 2048 or any(
                ord(character) < 0x20 or ord(character) == 0x7F for character in value
            ):
                raise SourceExportError("tracked .gitmodules path or URL is malformed")
            resolved[key] = value
        relative = _canonical_relative_path(resolved["path"])
        if relative in mappings:
            raise SourceExportError("tracked .gitmodules has duplicate paths")
        mappings[relative] = resolved["url"]
    return mappings


def _validated_submodules(value: dict[str, Any]) -> list[dict[str, str]]:
    if "submodules" not in value:
        return []
    raw = value["submodules"]
    if not isinstance(raw, list) or not raw or len(raw) > MAX_SUBMODULES:
        raise SourceExportError("source submodule manifest has an invalid module list")
    modules: list[dict[str, str]] = []
    total_commit_bytes = 0
    previous: bytes | None = None
    for item in raw:
        if (not isinstance(item, dict) or set(item) != {
                "path", "url", "commit_oid", "tree_oid", "commit_object_base64"
        } or not all(isinstance(field, str) for field in item.values())):
            raise SourceExportError("source submodule manifest contains a malformed record")
        relative = _canonical_relative_path(item["path"])
        encoded = os.fsencode(relative)
        if previous is not None and encoded <= previous:
            raise SourceExportError("source submodule paths are not strictly ordered")
        previous = encoded
        if any(relative.startswith(other["path"] + "/") or other["path"].startswith(relative + "/")
               for other in modules):
            raise SourceExportError("source submodule paths overlap")
        if (not item["url"] or len(item["url"]) > 2048
                or any(ord(c) < 0x20 or ord(c) == 0x7F for c in item["url"])):
            raise SourceExportError("source submodule URL is malformed")
        if any(HEX_SHA1.fullmatch(item[key]) is None for key in ("commit_oid", "tree_oid")):
            raise SourceExportError("source submodule identity is malformed")
        encoded_commit = item["commit_object_base64"]
        if len(encoded_commit) > ((MAX_COMMIT_OBJECT_BYTES + 2) // 3) * 4:
            raise SourceExportError("source submodule commit exceeds its size bound")
        try:
            commit = base64.b64decode(encoded_commit, validate=True)
        except (ValueError, binascii.Error) as error:
            raise SourceExportError("source submodule commit encoding is malformed") from error
        total_commit_bytes += len(commit)
        if (not commit or len(commit) > MAX_COMMIT_OBJECT_BYTES
                or total_commit_bytes > MAX_SUBMODULE_COMMIT_BYTES
                or base64.b64encode(commit).decode("ascii") != encoded_commit):
            raise SourceExportError("source submodule commit exceeds bounds or is not canonical")
        if (_commit_object_oid(commit) != item["commit_oid"]
                or _commit_object_identity(commit)[0] != item["tree_oid"]):
            raise SourceExportError("source submodule commit does not bind its identity and tree")
        modules.append(item)
    return modules


def validated_submodules(value: dict[str, Any]) -> list[dict[str, str]]:
    """Validate optional submodule metadata without Git; file/tree binding requires full verification."""
    return _validated_submodules(value)


def _parent_tree_records(root: Path, records: Sequence[dict[str, object]],
                         modules: Sequence[dict[str, str]]) -> list[dict[str, object]]:
    if not modules:
        return list(records)
    mappings = _gitmodule_mapping(root, records)
    if mappings != {module["path"]: module["url"] for module in modules}:
        raise SourceExportError("submodule manifest does not match tracked .gitmodules")
    grouped: dict[str, list[dict[str, object]]] = {module["path"]: [] for module in modules}
    parent: list[dict[str, object]] = []
    for record in records:
        relative = str(record["path"])
        if relative in grouped:
            raise SourceExportError("submodule path collides with an ordinary source file")
        owner = next((path for path in grouped if relative.startswith(path + "/")), None)
        if owner is None:
            parent.append(record)
        else:
            grouped[owner].append({**record, "path": relative[len(owner) + 1:]})
    for module in modules:
        if _reconstructed_tree_oid(grouped[module["path"]]) != module["tree_oid"]:
            raise SourceExportError("source files do not reconstruct the pinned submodule tree")
        parent.append({"path": module["path"], "mode": "160000", "blob_oid": module["commit_oid"]})
    return parent


def _materialized_submodule(root: Path, relative: str, commit_oid: str) -> Path:
    path = _require_safe_relative_file(root, relative)
    if not stat.S_ISDIR(path.lstat().st_mode):
        raise SourceExportError("submodule must be an ordinary materialized directory")
    _require_clean_git_root(path)
    if _required_git_text(path, "rev-parse", "HEAD") != commit_oid:
        raise SourceExportError("materialized submodule HEAD does not match its pinned gitlink")
    return path


def _canonical_gitmodules(root: Path, entries: Sequence[tuple[str, str, str]]) -> dict[str, str]:
    entry = next((entry for entry in entries if entry[0] == ".gitmodules" and entry[1] in {"100644", "100755"}), None)
    if entry is None:
        raise SourceExportError("submodule export requires tracked .gitmodules")
    oid = entry[2]
    size = _required_git_text(root, "cat-file", "-s", oid)
    if not size.isdigit() or not 0 < int(size) <= MAX_RECORD_BYTES:
        raise SourceExportError("tracked .gitmodules exceeds its size bound")
    result = _git(root, "cat-file", "blob", oid)
    if (result.returncode or result.stderr or len(result.stdout) != int(size)
            or hashlib.sha1(f"blob {size}\0".encode() + result.stdout).hexdigest() != oid):
        raise SourceExportError("tracked .gitmodules does not match its canonical blob")
    return _parse_gitmodule_mapping(result.stdout)


def _canonical_source_groups(root: Path, revision: str) -> tuple[
    list[tuple[str, str, str]],
    list[tuple[Path, list[tuple[str, str, str]], dict[str, str]]],
]:
    entries = _tracked_entries(root, revision, allow_gitlinks=True)
    links = [entry for entry in entries if entry[1] == "160000"]
    ordinary = [entry for entry in entries if entry[1] != "160000"]
    groups: list[tuple[Path, list[tuple[str, str, str]], dict[str, str]]] = []
    if not links:
        return ordinary, groups
    if len(links) > MAX_SUBMODULES:
        raise SourceExportError("source export exceeds the submodule-count bound")
    mappings = _canonical_gitmodules(root, entries)
    if set(mappings) != {entry[0] for entry in links}:
        raise SourceExportError("tracked .gitmodules does not match parent gitlinks")
    total_files = len(entries)
    for relative, _mode, commit_oid in links:
        module_root = _materialized_submodule(root, relative, commit_oid)
        module_commit = _canonical_git_commit_object(module_root, commit_oid)
        module_tree, _parents = _commit_object_identity(module_commit)
        # Nested gitlinks, symlinks, and special Git modes remain fail-closed.
        module_entries = _tracked_entries(module_root, commit_oid, allow_empty=True)
        total_files += len(module_entries)
        if total_files > MAX_FILES:
            raise SourceExportError("source export exceeds the aggregate file-count bound")
        for name, _file_mode, _oid in module_entries:
            source_file = _require_safe_relative_file(module_root, name)
            metadata = source_file.lstat()
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                raise SourceExportError("submodule input must be one ordinary file")
        metadata = {
            "path": relative, "url": mappings[relative], "commit_oid": commit_oid,
            "tree_oid": module_tree,
            "commit_object_base64": base64.b64encode(module_commit).decode("ascii"),
        }
        groups.append((module_root, module_entries, metadata))
        _validated_submodules({"submodules": [group[2] for group in groups]})
    return ordinary, groups


def canonical_git_file_entries(repository_root: Path) -> dict[str, tuple[str, str]]:
    """Read the clean HEAD's flat canonical file identity, including pinned local submodules.

    Never fetches, checks out, or writes an export. Values are (ordinary Git mode, blob OID).
    Submodule gitlinks are represented by their files, not a competing directory identity.
    """
    root = repository_root.resolve(strict=True)
    _require_clean_git_root(root)
    head = _required_git_text(root, "rev-parse", "HEAD")
    ordinary, groups = _canonical_source_groups(root, head)
    entries = {path: (mode, oid) for path, mode, oid in ordinary}
    for _module_root, module_entries, metadata in groups:
        entries.update({metadata["path"] + "/" + path: (mode, oid) for path, mode, oid in module_entries})
        _materialized_submodule(root, metadata["path"], metadata["commit_oid"])
    _require_clean_git_root(root)
    if _required_git_text(root, "rev-parse", "HEAD") != head:
        raise SourceExportError("Git source identity changed during enumeration")
    return dict(sorted(entries.items(), key=lambda item: os.fsencode(item[0])))


def _require_unchanged_submodule_authority(root: Path) -> None:
    # Inspect index-vs-HEAD and worktree-vs-index separately. A staged mapping must not be
    # hidden by restoring only its working bytes; unrelated parent edits remain permitted.
    for comparison in (("--cached", "HEAD"), ()):
        result = _git(root, "diff", "--raw", "-z", "--no-renames", "--no-ext-diff",
                      "--no-textconv", "--ignore-submodules=none", *comparison, "--")
        if result.returncode:
            raise SourceExportError("could not verify unchanged submodule authority")
        fields = result.stdout.split(b"\0")
        if fields[-1] != b"" or (len(fields) - 1) % 2:
            raise SourceExportError("Git returned malformed submodule authority changes")
        for index in range(0, len(fields) - 1, 2):
            header = fields[index].split()
            if len(header) != 5 or not header[0].startswith(b":"):
                raise SourceExportError("Git returned malformed submodule authority changes")
            if (fields[index + 1] == b".gitmodules"
                    or header[0][1:] == b"160000" or header[1] == b"160000"):
                raise SourceExportError("submodule .gitmodules and gitlinks must match HEAD in index and worktree")


def canonical_git_submodule_inventory(repository_root: Path) -> list[
    tuple[Path, list[tuple[str, str, str]], dict[str, str]]
]:
    """Return pinned module roots, relative (path, mode, blob) entries, and wire metadata.

    Ordinary development may modify unrelated parent files. Submodule authority (.gitmodules
    and all gitlinks), each materialized module, and HEAD itself must remain unchanged.
    No parent file contents are hashed and no checkout/export is written.
    """
    root = repository_root.resolve(strict=True)
    if Path(_required_git_text(root, "rev-parse", "--show-toplevel")).resolve(strict=True) != root:
        raise SourceExportError("repository root does not match the Git worktree root")
    head = _required_git_text(root, "rev-parse", "HEAD")
    _require_unchanged_submodule_authority(root)
    _ordinary, groups = _canonical_source_groups(root, head)
    for _module_root, _entries, metadata in groups:
        _materialized_submodule(root, metadata["path"], metadata["commit_oid"])
    _require_unchanged_submodule_authority(root)
    if _required_git_text(root, "rev-parse", "HEAD") != head:
        raise SourceExportError("Git source identity changed during submodule enumeration")
    return groups


def _copy_git_blobs(
    root: Path,
    destination: Path,
    entries: list[tuple[str, str, str]],
    *, initial_total_bytes: int = 0,
) -> tuple[list[dict[str, object]], int]:
    """Stream canonical Git blob bytes into a Git-less ordinary-file export."""
    records: list[dict[str, object]] = []
    total_bytes = initial_total_bytes
    environment = os.environ.copy()
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    environment["GIT_NO_LAZY_FETCH"] = "1"
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    process = subprocess.Popen(
        ["/usr/bin/git", "cat-file", "--batch"],
        cwd=root,
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if process.stdin is None or process.stdout is None or process.stderr is None:
        process.kill()
        process.wait()
        raise SourceExportError("could not start canonical Git blob reader")
    try:
        for relative, mode, object_id in entries:
            process.stdin.write(object_id.encode("ascii") + b"\n")
            process.stdin.flush()
            header = process.stdout.readline(512)
            if not header.endswith(b"\n") or len(header) >= 512:
                raise SourceExportError("git cat-file returned a malformed blob header")
            fields = header[:-1].split(b" ")
            if len(fields) != 3:
                raise SourceExportError("git cat-file did not return a canonical blob")
            try:
                observed_id = fields[0].decode("ascii")
                object_type = fields[1].decode("ascii")
                size_text = fields[2].decode("ascii")
            except UnicodeError as error:
                raise SourceExportError("git cat-file returned non-ASCII metadata") from error
            if (
                observed_id != object_id
                or object_type != "blob"
                or not size_text.isdigit()
            ):
                raise SourceExportError("git cat-file returned an unexpected object")
            size = int(size_text)
            total_bytes += size
            if total_bytes > MAX_TOTAL_BYTES:
                raise SourceExportError("source export exceeds the aggregate-size bound")

            output_path = destination / relative
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_descriptor = os.open(
                output_path,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                0o600,
            )
            digest = hashlib.sha256()
            blob_digest = hashlib.sha1()
            blob_digest.update(f"blob {size}\0".encode("ascii"))
            remaining = size
            prefix = b""
            try:
                while remaining:
                    block = process.stdout.read(min(1024 * 1024, remaining))
                    if not block:
                        raise SourceExportError("git cat-file truncated a canonical blob")
                    remaining -= len(block)
                    if len(prefix) < 1024:
                        prefix += block[:1024 - len(prefix)]
                    digest.update(block)
                    blob_digest.update(block)
                    view = memoryview(block)
                    while view:
                        written = os.write(output_descriptor, view)
                        view = view[written:]
                if process.stdout.read(1) != b"\n":
                    raise SourceExportError("git cat-file returned a malformed blob terminator")
                if blob_digest.hexdigest() != object_id:
                    raise SourceExportError("canonical Git blob bytes do not match their object ID")
                pointer = _parse_lfs_pointer(prefix, size, relative)
                physical_digest = digest.hexdigest()
                if pointer is not None:
                    physical_digest, physical_size = pointer
                    total_bytes += physical_size - size
                    if total_bytes > MAX_TOTAL_BYTES:
                        raise SourceExportError("source export exceeds the aggregate-size bound")
                    _copy_lfs_payload(root, relative, output_descriptor, mode, physical_digest, physical_size)
                    size = physical_size
                output_binding = os.fstat(output_descriptor)
                output_path_binding = output_path.lstat()
                if (not stat.S_ISREG(output_path_binding.st_mode)
                        or output_binding.st_nlink != 1
                        or output_path_binding.st_nlink != 1
                        or (output_binding.st_dev, output_binding.st_ino)
                        != (output_path_binding.st_dev, output_path_binding.st_ino)):
                    raise SourceExportError("source export output changed during copying")
                os.fchmod(output_descriptor, 0o755 if mode == "100755" else 0o644)
            finally:
                os.close(output_descriptor)
            records.append(
                {
                    "blob_oid": object_id,
                    "mode": mode,
                    "path": relative,
                    "sha256": physical_digest,
                    "size": size,
                }
            )

        process.stdin.close()
        if process.stdout.read(1):
            raise SourceExportError("git cat-file returned unexpected trailing output")
        return_code = process.wait()
        diagnostic = process.stderr.read(MAX_RECORD_BYTES + 1)
        if return_code != 0:
            message = diagnostic.decode("utf-8", errors="replace").strip()
            raise SourceExportError(message or "git cat-file failed")
        if diagnostic:
            raise SourceExportError("git cat-file emitted an unexpected diagnostic")
    finally:
        if not process.stdin.closed:
            process.stdin.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        process.stdout.close()
        process.stderr.close()
    return records, total_bytes


def _reconstructed_tree_oid(records: Sequence[dict[str, object]]) -> str:
    root: dict[str, Any] = {}
    for record in records:
        relative = str(record["path"])
        parts = PurePosixPath(relative).parts
        node = root
        for component in parts[:-1]:
            existing = node.get(component)
            if existing is None:
                child: dict[str, Any] = {}
                node[component] = child
                node = child
            elif isinstance(existing, dict):
                node = existing
            else:
                raise SourceExportError("source manifest contains a file/directory collision")
        leaf = parts[-1]
        if leaf in node:
            raise SourceExportError("source manifest contains a duplicate tree entry")
        node[leaf] = (str(record["mode"]), str(record["blob_oid"]))

    def tree_oid(node: dict[str, Any]) -> str:
        serialized: list[tuple[bytes, bytes]] = []
        for name, value in node.items():
            encoded_name = name.encode("utf-8", errors="strict")
            if isinstance(value, dict):
                mode = b"40000"
                object_id = tree_oid(value)
                sort_key = encoded_name + b"/"
            else:
                mode_text, object_id = value
                mode = mode_text.encode("ascii")
                sort_key = encoded_name
            serialized.append(
                (
                    sort_key,
                    mode + b" " + encoded_name + b"\0" + bytes.fromhex(object_id),
                )
            )
        payload = b"".join(value for _key, value in sorted(serialized, key=lambda item: item[0]))
        digest = hashlib.sha1()
        digest.update(f"tree {len(payload)}\0".encode("ascii"))
        digest.update(payload)
        return digest.hexdigest()

    return tree_oid(root)


def _dependency_contract(root: Path, records: list[dict[str, object]]) -> dict[str, object]:
    by_path = {record["path"]: record for record in records}
    required = ("THIRD_PARTY_COMPONENTS.yml", "THIRD_PARTY_NOTICES.md")
    if any(path not in by_path for path in required):
        raise SourceExportError("dependency governance records are not tracked source")
    try:
        manifest_bytes = _read_stable_bounded_file(
            _require_safe_relative_file(root, required[0]),
            MAX_RECORD_BYTES,
            "third-party component inventory",
        )
        manifest_record = by_path[required[0]]
        if (
            len(manifest_bytes) != manifest_record["size"]
            or hashlib.sha256(manifest_bytes).hexdigest()
            != manifest_record["sha256"]
        ):
            raise SourceExportError(
                "third-party component inventory differs from the source manifest"
            )
        manifest = json.loads(manifest_bytes)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SourceExportError("third-party component inventory is malformed") from error
    components = manifest.get("components") if isinstance(manifest, dict) else None
    if not isinstance(components, list):
        raise SourceExportError("third-party component inventory lacks components")
    pins: list[dict[str, object]] = []
    for component in components:
        if not isinstance(component, dict) or not isinstance(component.get("id"), str):
            raise SourceExportError("third-party component identity is malformed")
        pin = component.get("pin")
        if not isinstance(pin, dict) or not pin:
            raise SourceExportError("third-party component pin is malformed")
        pins.append({"id": component["id"], "pin": pin})
    pins.sort(key=lambda item: os.fsencode(str(item["id"])))
    if len({str(item["id"]) for item in pins}) != len(pins):
        raise SourceExportError("third-party component ids are not unique")
    return {
        "component_manifest_sha256": by_path[required[0]]["sha256"],
        "notices_sha256": by_path[required[1]]["sha256"],
        "component_pins": pins,
    }


def _source_export_package_contract(commit_object: bytes, *, has_submodules: bool = False) -> dict[str, object]:
    return {
        "commit_object_name": COMMIT_OBJECT_NAME,
        "commit_object_sha256": hashlib.sha256(commit_object).hexdigest(),
        "commit_object_size": len(commit_object),
        "version": 5 if has_submodules else PACKAGE_CONTRACT_VERSION,
    }


def _verify_exported_records(
    root: Path,
    records: Sequence[dict[str, object]],
) -> dict[str, tuple[int, ...]]:
    total_bytes = 0
    bindings: dict[str, tuple[int, ...]] = {}
    for record in records:
        relative = str(record["path"])
        digest, size, blob_oid, binding = _ordinary_file_identity(
            _require_safe_relative_file(root, relative)
        )
        total_bytes += size
        if total_bytes > MAX_TOTAL_BYTES:
            raise SourceExportError("source export exceeds the aggregate-size bound")
        expected_permissions = 0o755 if record["mode"] == "100755" else 0o644
        observed_permissions = stat.S_IMODE(binding[2])
        # These two committed pointers bind physical payloads without changing the
        # canonical tree identity. Every other path remains an ordinary Git blob.
        canonical_blob = blob_oid == record["blob_oid"]
        if relative in LFS_PATHS and 0 < size <= 1024:
            prefix = _read_stable_bounded_file(root / relative, 1024, "LFS export input")
            if prefix.startswith(LFS_HEADER):
                raise SourceExportError("source export contains an unmaterialized LFS pointer")
        pointer_binding = (relative in LFS_PATHS
                           and _pointer_blob_oid(digest, size) == record["blob_oid"])
        if (
            size != record["size"]
            or digest != record["sha256"]
            or not (canonical_blob or pointer_binding)
            or observed_permissions != expected_permissions
        ):
            raise SourceExportError(
                f"exported source does not match its manifest: {relative}"
            )
        bindings[relative] = binding
    return bindings


def _revalidate_exported_record_bindings(
    root: Path,
    bindings: dict[str, tuple[int, ...]],
) -> None:
    stable = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    for relative, expected in bindings.items():
        candidate = _require_safe_relative_file(root, relative)
        try:
            observed = candidate.lstat()
        except OSError as error:
            raise SourceExportError(
                f"exported source changed during final revalidation: {relative}"
            ) from error
        if tuple(getattr(observed, field) for field in stable) != expected:
            raise SourceExportError(
                f"exported source changed during final revalidation: {relative}"
            )


def create_export(
    repository_root: Path,
    destination: Path,
    integration_ref: str,
    *,
    bindings_out: Optional[dict[str, tuple[int, ...]]] = None,
) -> dict[str, object]:
    root = repository_root.resolve(strict=True)
    _require_clean_git_root(root)
    _integration_remote_name, remote_url = _integration_remote(root, integration_ref)
    destination = destination.parent.resolve(strict=True) / destination.name
    if destination.exists():
        raise SourceExportError("source export destination must not already exist")
    destination.mkdir(mode=0o700)

    head_commit = _required_git_text(root, "rev-parse", "HEAD")
    head_tree = _required_git_text(root, "rev-parse", "HEAD^{tree}")
    integration_commit = _required_git_text(root, "rev-parse", f"{integration_ref}^{{commit}}")
    if any(HEX_SHA1.fullmatch(value) is None for value in (head_commit, head_tree, integration_commit)):
        raise SourceExportError("Git source identity is malformed")
    if integration_commit != head_commit:
        raise SourceExportError("HEAD does not match the authorized integration ref")
    commit_object = _canonical_git_commit_object(root, head_commit)
    commit_tree, commit_parents = _commit_object_identity(commit_object)
    parent_line = _required_git_text(root, "rev-list", "--parents", "-n", "1", "HEAD")
    parent_parts = parent_line.split()
    if not parent_parts or parent_parts[0] != head_commit or any(
        HEX_SHA1.fullmatch(value) is None for value in parent_parts
    ):
        raise SourceExportError("Git parent identity is malformed")
    if commit_tree != head_tree or commit_parents != parent_parts[1:]:
        raise SourceExportError(
            "canonical Git commit object does not bind the observed tree and parents"
        )
    ordinary, groups = _canonical_source_groups(root, head_commit)
    records, total_bytes = _copy_git_blobs(root, destination, ordinary)
    submodules: list[dict[str, str]] = []
    for module_root, module_entries, metadata in groups:
        relative = metadata["path"]
        module_destination = destination / relative
        module_destination.mkdir(parents=True, exist_ok=False)
        module_records, total_bytes = _copy_git_blobs(
            module_root, module_destination, module_entries, initial_total_bytes=total_bytes
        )
        if _reconstructed_tree_oid(module_records) != metadata["tree_oid"]:
            raise SourceExportError("canonical submodule blobs do not reconstruct its tree")
        records.extend({**record, "path": relative + "/" + str(record["path"])}
                       for record in module_records)
        submodules.append(metadata)
    records.sort(key=lambda record: os.fsencode(str(record["path"])))
    if _reconstructed_tree_oid(_parent_tree_records(destination, records, submodules)) != head_tree:
        raise SourceExportError("canonical Git blobs do not reconstruct the HEAD tree")

    _require_clean_git_root(root)
    for module in submodules:
        module_root = _materialized_submodule(root, module["path"], module["commit_oid"])
        if _canonical_git_commit_object(module_root, module["commit_oid"]) != base64.b64decode(module["commit_object_base64"]):
            raise SourceExportError("submodule commit changed during export")
    if (
        _required_git_text(root, "rev-parse", "HEAD") != head_commit
        or _required_git_text(root, "rev-parse", "HEAD^{tree}") != head_tree
        or _required_git_text(root, "rev-parse", f"{integration_ref}^{{commit}}")
        != integration_commit
        or _canonical_git_commit_object(root, head_commit) != commit_object
    ):
        raise SourceExportError("Git source identity changed during export")

    files_payload = {"files": records, "schema_version": SCHEMA_VERSION}
    if submodules:
        files_payload["submodules"] = submodules
    files_bytes = _canonical_json(files_payload)
    if len(files_bytes) > MAX_RECORD_BYTES:
        raise SourceExportError("source manifest exceeds its record-size bound")
    (destination / FILES_NAME).write_bytes(files_bytes)
    (destination / FILES_NAME).chmod(0o644)
    (destination / COMMIT_OBJECT_NAME).write_bytes(commit_object)
    (destination / COMMIT_OBJECT_NAME).chmod(0o644)
    provenance: dict[str, object] = {
        "canonical_integration_commit": integration_commit,
        "canonical_integration_ref": integration_ref,
        "canonical_remote_url": remote_url,
        "dependency_contract": {
            **_dependency_contract(destination, records),
            "source_export_package": _source_export_package_contract(commit_object, has_submodules=bool(submodules)),
        },
        "git_head_commit": head_commit,
        "git_head_tree": head_tree,
        "git_parent_commits": parent_parts[1:],
        "repository_clean": True,
        "schema_version": SCHEMA_VERSION,
        "source_file_count": len(records),
        "source_files_sha256": hashlib.sha256(files_bytes).hexdigest(),
    }
    (destination / PROVENANCE_NAME).write_bytes(_canonical_json(provenance))
    (destination / PROVENANCE_NAME).chmod(0o644)
    load_verified_export(destination, require_closed_tree=True, bindings_out=bindings_out)
    return provenance


def _validated_file_records(value: dict[str, Any]) -> list[dict[str, object]]:
    if set(value) not in ({"files", "schema_version"}, {"files", "schema_version", "submodules"}) or value["schema_version"] != SCHEMA_VERSION:
        raise SourceExportError("source file manifest has an unsupported schema")
    raw_records = value["files"]
    if not isinstance(raw_records, list) or not raw_records or len(raw_records) > MAX_FILES:
        raise SourceExportError("source file manifest has an invalid file list")
    records: list[dict[str, object]] = []
    previous: Optional[bytes] = None
    for raw in raw_records:
        if not isinstance(raw, dict) or set(raw) != {
            "blob_oid",
            "mode",
            "path",
            "sha256",
            "size",
        }:
            raise SourceExportError("source file manifest contains a malformed record")
        path = _canonical_relative_path(raw["path"] if isinstance(raw["path"], str) else "")
        encoded = os.fsencode(path)
        if previous is not None and encoded <= previous:
            raise SourceExportError("source file manifest paths are not strictly ordered")
        previous = encoded
        if raw["mode"] not in {"100644", "100755"}:
            raise SourceExportError("source file manifest mode is invalid")
        if not isinstance(raw["blob_oid"], str) or HEX_SHA1.fullmatch(raw["blob_oid"]) is None:
            raise SourceExportError("source file manifest blob OID is invalid")
        if not isinstance(raw["sha256"], str) or HEX_SHA256.fullmatch(raw["sha256"]) is None:
            raise SourceExportError("source file manifest SHA-256 is invalid")
        if isinstance(raw["size"], bool) or not isinstance(raw["size"], int) or raw["size"] < 0:
            raise SourceExportError("source file manifest size is invalid")
        records.append(raw)
    return records


def load_verified_export(
    source_root: Path,
    *,
    require_closed_tree: bool = True,
    bindings_out: Optional[dict[str, tuple[int, ...]]] = None,
) -> tuple[dict[str, object], dict[str, dict[str, object]]]:
    root = source_root.resolve(strict=True)
    root_metadata = root.lstat()
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        raise SourceExportError("source export root must be one ordinary directory")
    files_value, files_bytes = _load_canonical_json(root / FILES_NAME)
    provenance, provenance_bytes = _load_canonical_json(root / PROVENANCE_NAME)
    records = _validated_file_records(files_value)
    submodules = _validated_submodules(files_value)
    if len(records) + len(submodules) > MAX_FILES:
        raise SourceExportError("source export exceeds the aggregate file-count bound")

    required_provenance = {
        "canonical_integration_commit",
        "canonical_integration_ref",
        "canonical_remote_url",
        "dependency_contract",
        "git_head_commit",
        "git_head_tree",
        "git_parent_commits",
        "repository_clean",
        "schema_version",
        "source_file_count",
        "source_files_sha256",
    }
    if set(provenance) != required_provenance or provenance["schema_version"] != SCHEMA_VERSION:
        raise SourceExportError("source provenance has an unsupported schema")
    if provenance["repository_clean"] is not True:
        raise SourceExportError("source provenance does not attest a clean repository")
    integration_ref = provenance["canonical_integration_ref"]
    remote_url = provenance["canonical_remote_url"]
    if (
        not isinstance(integration_ref, str)
    ):
        raise SourceExportError("source provenance integration ref is malformed")
    try:
        _validated_integration_ref(integration_ref)
    except SourceExportError as error:
        raise SourceExportError("source provenance integration ref is malformed") from error
    if (
        not isinstance(remote_url, str)
        or not remote_url
        or len(remote_url) > 2048
        or any(ord(character) < 0x20 for character in remote_url)
    ):
        raise SourceExportError("source provenance remote URL is malformed")
    for key in ("git_head_commit", "git_head_tree", "canonical_integration_commit"):
        if not isinstance(provenance[key], str) or HEX_SHA1.fullmatch(provenance[key]) is None:
            raise SourceExportError(f"source provenance {key} is malformed")
    if provenance["canonical_integration_commit"] != provenance["git_head_commit"]:
        raise SourceExportError(
            "source provenance integration commit must equal the recorded Git HEAD"
        )
    parents = provenance["git_parent_commits"]
    if not isinstance(parents, list) or any(
        not isinstance(value, str) or HEX_SHA1.fullmatch(value) is None for value in parents
    ):
        raise SourceExportError("source provenance parent commits are malformed")
    if provenance["source_file_count"] != len(records):
        raise SourceExportError("source provenance file count does not match")
    if provenance["source_files_sha256"] != hashlib.sha256(files_bytes).hexdigest():
        raise SourceExportError("source file manifest digest does not match provenance")
    commit_object = _read_exported_commit_object(root / COMMIT_OBJECT_NAME)
    if _commit_object_oid(commit_object) != provenance["git_head_commit"]:
        raise SourceExportError(
            "canonical Git commit object does not match the recorded Git HEAD"
        )
    commit_tree, commit_parents = _commit_object_identity(commit_object)
    if (
        commit_tree != provenance["git_head_tree"]
        or commit_parents != parents
    ):
        raise SourceExportError(
            "canonical Git commit object does not bind the recorded tree and parents"
        )
    if _reconstructed_tree_oid(_parent_tree_records(root, records, submodules)) != provenance["git_head_tree"]:
        raise SourceExportError("source file manifest does not reconstruct the recorded Git tree")

    expected_paths = {str(record["path"]) for record in records}
    initial_bindings = _verify_exported_records(root, records)

    if require_closed_tree:
        observed_paths: set[str] = set()
        for candidate in root.rglob("*"):
            metadata = candidate.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                raise SourceExportError("source export contains a symlink")
            if stat.S_ISDIR(metadata.st_mode):
                continue
            if not stat.S_ISREG(metadata.st_mode):
                raise SourceExportError("source export contains a non-regular file")
            observed_paths.add(candidate.relative_to(root).as_posix())
        allowed = expected_paths | {FILES_NAME, PROVENANCE_NAME, COMMIT_OBJECT_NAME}
        unexpected = sorted(observed_paths - allowed, key=os.fsencode)
        missing = sorted(allowed - observed_paths, key=os.fsencode)
        if unexpected:
            raise SourceExportError(
                f"source export contains an unmanifested file: {unexpected[0]}"
            )
        if missing:
            raise SourceExportError(f"source export is missing a manifested file: {missing[0]}")

    expected_dependency = {
        **_dependency_contract(root, records),
        "source_export_package": _source_export_package_contract(commit_object, has_submodules=bool(submodules)),
    }
    if provenance["dependency_contract"] != expected_dependency:
        raise SourceExportError("dependency contract does not match exported governance files")
    final_bindings = _verify_exported_records(root, tuple(reversed(records)))
    if final_bindings != initial_bindings:
        raise SourceExportError("exported source bindings changed during verification")
    _revalidate_exported_record_bindings(root, final_bindings)
    final_files_value, final_files_bytes = _load_canonical_json(root / FILES_NAME)
    final_provenance, final_provenance_bytes = _load_canonical_json(
        root / PROVENANCE_NAME
    )
    final_commit_object = _read_exported_commit_object(root / COMMIT_OBJECT_NAME)
    if (
        final_files_value != files_value
        or final_files_bytes != files_bytes
        or final_provenance != provenance
        or final_provenance_bytes != provenance_bytes
        or final_commit_object != commit_object
    ):
        raise SourceExportError("source export authority changed during verification")
    if bindings_out is not None:
        bindings_out.clear()
        bindings_out.update(final_bindings)
    return provenance, {str(record["path"]): record for record in records}


def verify_export(source_root: Path) -> dict[str, object]:
    provenance, _records = load_verified_export(source_root, require_closed_tree=True)
    return provenance


# ---------------------------------------------------------------------------
# Tree-keyed reuse of verified source exports.
#
# A fully verified export is published once per reuse key into a shared
# verification cache. The key binds every input the full verification depends
# on (commit, tree, integration ref and remote URL, this verifier's own SHA-256
# as frozen by the qualifier, the export schema, and the Python/Git/macOS
# identities that ran it). Publication records an O(metadata) snapshot of the
# verified tree (device, inode, mode, link count, size, mtime and ctime of every
# file and directory) taken from the verifier's own final bindings. Reuse
# requires an exact key match and an identical snapshot; any difference falls
# back to full verification. Runs receive an APFS clonefile(2) copy and never
# mutate the shared entry.
# ---------------------------------------------------------------------------

REUSE_SCHEMA_VERSION = 1
REUSE_RECEIPT_NAME = "VERIFICATION_RECEIPT.json"
REUSE_EXPORT_NAME = "export"
CLONE_UNSUPPORTED_STATUS = 3
STABLE_METADATA_FIELDS = (
    "st_dev",
    "st_ino",
    "st_mode",
    "st_nlink",
    "st_size",
    "st_mtime_ns",
    "st_ctime_ns",
)
REUSE_RECEIPT_FIELDS = frozenset({
    "commit_object_sha256",
    "export_metadata_sha256",
    "file_count",
    "key",
    "key_inputs",
    "provenance_sha256",
    "schema_version",
    "source_files_sha256",
    "total_bytes",
    "verification",
    "verified_at",
})
SYSTEM_VERSION_PLIST = Path("/System/Library/CoreServices/SystemVersion.plist")


class ReuseRejectedError(SourceExportError):
    """A stored verification receipt cannot be reused for this request."""


class CloneUnsupportedError(SourceExportError):
    """The filesystem cannot produce a kernel clone of the verified export."""


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _reuse_key_inputs(
    repository_root: Path, integration_ref: str, verifier_sha256: str
) -> dict[str, object]:
    if HEX_SHA256.fullmatch(verifier_sha256) is None:
        raise SourceExportError("verifier identity must be a lowercase SHA-256")
    root = repository_root.resolve(strict=True)
    _require_clean_git_root(root)
    _remote_name, remote_url = _integration_remote(root, integration_ref)
    head_commit = _required_git_text(root, "rev-parse", "HEAD")
    head_tree = _required_git_text(root, "rev-parse", "HEAD^{tree}")
    integration_commit = _required_git_text(root, "rev-parse", f"{integration_ref}^{{commit}}")
    if any(HEX_SHA1.fullmatch(value) is None for value in (head_commit, head_tree, integration_commit)):
        raise SourceExportError("Git source identity is malformed")
    if integration_commit != head_commit:
        raise SourceExportError("HEAD does not match the authorized integration ref")
    system_version = _read_stable_bounded_file(
        SYSTEM_VERSION_PLIST, 1024 * 1024, "macOS system version"
    )
    return {
        "canonical_integration_ref": integration_ref,
        "canonical_remote_url": remote_url,
        "git_head_commit": head_commit,
        "git_head_tree": head_tree,
        "reuse_schema_version": REUSE_SCHEMA_VERSION,
        "source_export_package_version": PACKAGE_CONTRACT_VERSION,
        "source_export_schema_version": SCHEMA_VERSION,
        "toolchain": {
            "git": _required_git_text(root, "--version"),
            "python": sys.version,
            "python_executable": sys.executable,
            "system_version_sha256": _sha256_bytes(system_version),
        },
        "verifier_sha256": verifier_sha256,
    }


def _metadata_entry(relative: str, metadata: os.stat_result) -> list[object]:
    if stat.S_ISDIR(metadata.st_mode):
        kind = "directory"
    elif stat.S_ISREG(metadata.st_mode):
        kind = "file"
    else:
        raise SourceExportError(f"verified export contains a non-regular entry: {relative}")
    return [relative, kind, *(getattr(metadata, field) for field in STABLE_METADATA_FIELDS)]


def _walk_metadata(root: Path) -> list[list[object]]:
    """Return lstat metadata of every entry below root without following links."""
    root_metadata = root.lstat()
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        raise SourceExportError("verified export root must be one ordinary directory")
    entries: list[list[object]] = []
    pending = [("", root)]
    while pending:
        prefix, directory = pending.pop()
        with os.scandir(directory) as iterator:
            for item in iterator:
                relative = f"{prefix}{item.name}"
                metadata = item.stat(follow_symlinks=False)
                entries.append(_metadata_entry(relative, metadata))
                if stat.S_ISDIR(metadata.st_mode):
                    pending.append((relative + "/", Path(item.path)))
        if len(entries) > 2 * MAX_FILES:
            raise SourceExportError("verified export exceeds the entry-count bound")
    entries.sort(key=lambda entry: os.fsencode(str(entry[0])))
    return entries


def _metadata_summary(entries: Sequence[list[object]]) -> tuple[str, int, int]:
    files = [entry for entry in entries if entry[1] == "file"]
    size_index = 2 + STABLE_METADATA_FIELDS.index("st_size")
    return (
        _sha256_bytes(_canonical_json(list(entries))),
        len(files),
        sum(int(entry[size_index]) for entry in files),
    )


def _reuse_layout(cache_root: Path) -> dict[str, Path]:
    if not cache_root.is_absolute():
        raise SourceExportError("verification cache root must be absolute")
    root = cache_root.resolve(strict=True)
    metadata = cache_root.lstat()
    if (root != cache_root or not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022):
        raise SourceExportError("verification cache root must be ordinary, owner-controlled and not group/world writable")
    base = root / "source-exports" / f"v{REUSE_SCHEMA_VERSION}"
    layout = {name: base / name for name in ("entries", "locks", "temporary", "quarantine")}
    for directory in (root / "source-exports", base, *layout.values()):
        if not directory.exists() and not directory.is_symlink():
            directory.mkdir(mode=0o700, exist_ok=True)
        metadata = directory.lstat()
        if (directory.resolve(strict=True) != directory or not stat.S_ISDIR(metadata.st_mode)
                or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022):
            raise SourceExportError("verification cache layout must be ordinary and owner-controlled")
    return layout


def _make_tree_writable(root: Path) -> None:
    if not root.exists() or root.is_symlink():
        return
    for current, directories, _files in os.walk(root, topdown=True, followlinks=False):
        os.chmod(current, 0o700)
        for name in directories:
            path = Path(current) / name
            if not path.is_symlink():
                os.chmod(path, 0o700)


def _remove_owned_tree(root: Path) -> None:
    import shutil

    if root.is_symlink():
        root.unlink()
        return
    if root.exists():
        _make_tree_writable(root)
        shutil.rmtree(root)


def _freeze_directories(root: Path) -> None:
    directories: list[Path] = []
    for current, names, _files in os.walk(root, topdown=True, followlinks=False):
        directories.extend(Path(current) / name for name in names)
    for directory in sorted(directories, key=lambda path: len(path.parts), reverse=True):
        os.chmod(directory, 0o555)
    os.chmod(root, 0o555)


def _load_reusable_entry(
    entry: Path,
    key: str,
    key_inputs: Optional[dict[str, object]],
) -> tuple[dict[str, Any], bytes, bytes, list[dict[str, object]]]:
    """Revalidate a stored export by metadata only; raise ReuseRejectedError on any drift."""
    try:
        entry_metadata = entry.lstat()
    except FileNotFoundError as error:
        raise ReuseRejectedError("no verified receipt for this key") from error
    if not stat.S_ISDIR(entry_metadata.st_mode) or stat.S_ISLNK(entry_metadata.st_mode):
        raise ReuseRejectedError("stored entry is not one ordinary directory")
    if entry_metadata.st_mode & 0o222:
        raise ReuseRejectedError("stored entry directory is writable")
    try:
        receipt, receipt_bytes = _load_canonical_json(entry / REUSE_RECEIPT_NAME)
    except SourceExportError as error:
        raise ReuseRejectedError(f"stored receipt is unreadable: {error}") from error
    if set(receipt) != REUSE_RECEIPT_FIELDS or receipt.get("schema_version") != REUSE_SCHEMA_VERSION:
        raise ReuseRejectedError("stored receipt schema is unsupported")
    stored_inputs = receipt["key_inputs"]
    if (
        not isinstance(stored_inputs, dict)
        or any(
            not isinstance(stored_inputs.get(name), str)
            for name in (
                "canonical_integration_ref",
                "canonical_remote_url",
                "git_head_commit",
                "git_head_tree",
            )
        )
        or any(
            not isinstance(receipt[name], str) or HEX_SHA256.fullmatch(receipt[name]) is None
            for name in (
                "commit_object_sha256",
                "export_metadata_sha256",
                "provenance_sha256",
                "source_files_sha256",
            )
        )
        or any(
            isinstance(receipt[name], bool) or not isinstance(receipt[name], int)
            for name in ("file_count", "total_bytes")
        )
    ):
        raise ReuseRejectedError("stored receipt fields are malformed")
    if receipt.get("key") != key or _sha256_bytes(_canonical_json(receipt["key_inputs"])) != key:
        raise ReuseRejectedError("stored receipt key differs")
    if key_inputs is not None and receipt["key_inputs"] != key_inputs:
        raise ReuseRejectedError("stored receipt key inputs differ")
    export = entry / REUSE_EXPORT_NAME
    try:
        observed = _metadata_summary(_walk_metadata(export))
    except (OSError, SourceExportError) as error:
        raise ReuseRejectedError(f"stored export could not be enumerated: {error}") from error
    if observed != (
        receipt["export_metadata_sha256"],
        receipt["file_count"],
        receipt["total_bytes"],
    ):
        raise ReuseRejectedError("stored export metadata changed since verification")
    provenance_bytes = _read_stable_bounded_file(
        export / PROVENANCE_NAME, MAX_RECORD_BYTES, "stored source provenance"
    )
    files_value, files_bytes = _load_canonical_json(export / FILES_NAME)
    commit_object = _read_exported_commit_object(export / COMMIT_OBJECT_NAME)
    if (
        _sha256_bytes(provenance_bytes) != receipt["provenance_sha256"]
        or _sha256_bytes(files_bytes) != receipt["source_files_sha256"]
        or _sha256_bytes(commit_object) != receipt["commit_object_sha256"]
    ):
        raise ReuseRejectedError("stored export records differ from the receipt")
    provenance = json.loads(provenance_bytes)
    inputs = receipt["key_inputs"]
    if (
        not isinstance(provenance, dict)
        or provenance.get("source_files_sha256") != receipt["source_files_sha256"]
        or provenance.get("git_head_commit") != inputs["git_head_commit"]
        or provenance.get("git_head_tree") != inputs["git_head_tree"]
        or provenance.get("canonical_integration_ref") != inputs["canonical_integration_ref"]
        or provenance.get("canonical_remote_url") != inputs["canonical_remote_url"]
        or _commit_object_oid(commit_object) != inputs["git_head_commit"]
    ):
        raise ReuseRejectedError("stored provenance does not bind the receipt key")
    return receipt, receipt_bytes, provenance_bytes, _validated_file_records(files_value)


def _write_decision(path: Path, decision: dict[str, object]) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(_canonical_json(decision))


def _publish_verified_export(
    repository_root: Path,
    integration_ref: str,
    key: str,
    key_inputs: dict[str, object],
    layout: dict[str, Path],
    entry: Path,
) -> tuple[bytes, str]:
    import tempfile
    from datetime import datetime, timezone

    temporary = Path(tempfile.mkdtemp(prefix=f"{key}.", dir=layout["temporary"]))
    try:
        export = temporary / REUSE_EXPORT_NAME
        bindings: dict[str, tuple[int, ...]] = {}
        provenance = create_export(repository_root, export, integration_ref, bindings_out=bindings)
        if (
            provenance["git_head_commit"] != key_inputs["git_head_commit"]
            or provenance["git_head_tree"] != key_inputs["git_head_tree"]
            or provenance["canonical_integration_ref"] != key_inputs["canonical_integration_ref"]
            or provenance["canonical_remote_url"] != key_inputs["canonical_remote_url"]
        ):
            raise SourceExportError("verified export does not match its reuse key")
        _freeze_directories(export)
        entries = _walk_metadata(export)
        observed_files = {str(item[0]): tuple(item[2:]) for item in entries if item[1] == "file"}
        # Bind the snapshot to the verifier's own final per-file observations so
        # no write can slip between full verification and receipt publication.
        for relative, binding in bindings.items():
            if observed_files.get(relative) != tuple(binding):
                raise SourceExportError(f"verified export changed before publication: {relative}")
        if set(observed_files) != set(bindings) | {FILES_NAME, PROVENANCE_NAME, COMMIT_OBJECT_NAME}:
            raise SourceExportError("verified export file set changed before publication")
        digest, file_count, total_bytes = _metadata_summary(entries)
        provenance_bytes = _read_stable_bounded_file(
            export / PROVENANCE_NAME, MAX_RECORD_BYTES, "published source provenance"
        )
        if provenance_bytes != _canonical_json(provenance):
            raise SourceExportError("published source provenance differs from verification")
        _files_value, files_bytes = _load_canonical_json(export / FILES_NAME)
        commit_object = _read_exported_commit_object(export / COMMIT_OBJECT_NAME)
        receipt = {
            "commit_object_sha256": _sha256_bytes(commit_object),
            "export_metadata_sha256": digest,
            "file_count": file_count,
            "key": key,
            "key_inputs": key_inputs,
            "provenance_sha256": _sha256_bytes(provenance_bytes),
            "schema_version": REUSE_SCHEMA_VERSION,
            "source_files_sha256": _sha256_bytes(files_bytes),
            "total_bytes": total_bytes,
            "verification": "source_export_provenance.create (Git blob copy, tree reconstruction, full byte verification)",
            "verified_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        }
        receipt_bytes = _canonical_json(receipt)
        receipt_path = temporary / REUSE_RECEIPT_NAME
        receipt_path.write_bytes(receipt_bytes)
        receipt_path.chmod(0o444)
        if entry.exists() or entry.is_symlink():
            raise SourceExportError("verification cache entry appeared while locked")
        os.rename(temporary, entry)
        os.chmod(entry, 0o555)
        return provenance_bytes, _sha256_bytes(receipt_bytes)
    finally:
        if temporary.exists():
            _remove_owned_tree(temporary)


def reuse_or_verify_export(
    repository_root: Path,
    integration_ref: str,
    cache_root: Path,
    verifier_sha256: str,
    fallback_destination: Path,
    decision_output: Path,
) -> bytes:
    """Return verified provenance bytes, reusing a matching receipt when one exists."""
    import time

    key_inputs = _reuse_key_inputs(repository_root, integration_ref, verifier_sha256)
    key = _sha256_bytes(_canonical_json(key_inputs))
    layout = _reuse_layout(cache_root)
    entry = layout["entries"] / key
    decision: dict[str, object] = {
        "commit": key_inputs["git_head_commit"],
        "key": key,
        "tree": key_inputs["git_head_tree"],
    }

    def reused(receipt_bytes: bytes) -> None:
        decision.update(
            decision="reused",
            entry=str(entry),
            export_root=str(entry / REUSE_EXPORT_NAME),
            reason=None,
            receipt_sha256=_sha256_bytes(receipt_bytes),
        )

    try:
        _receipt, receipt_bytes, provenance_bytes, _records = _load_reusable_entry(
            entry, key, key_inputs
        )
    except ReuseRejectedError as error:
        reason = str(error)
    except OSError as error:
        reason = f"stored entry could not be read: {error}"
    else:
        reused(receipt_bytes)
        _write_decision(decision_output, decision)
        return provenance_bytes

    lock = layout["locks"] / f"{key}.lock"
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError:
        # Another gate is publishing this key. Never wait on or share a partial
        # publication: verify privately in this work root instead.
        provenance = create_export(repository_root, fallback_destination, integration_ref)
        decision.update(
            decision="full-unpublished",
            entry=None,
            export_root=str(fallback_destination),
            reason=f"{reason}; publication lock held by another gate ({lock})",
            receipt_sha256=None,
        )
        _write_decision(decision_output, decision)
        return _canonical_json(provenance)
    try:
        (lock / "owner").write_text(f"pid={os.getpid()}\nkey={key}\n", encoding="utf-8")
        if entry.exists() or entry.is_symlink():
            try:
                _receipt, receipt_bytes, provenance_bytes, _records = _load_reusable_entry(
                    entry, key, key_inputs
                )
            except (ReuseRejectedError, OSError) as error:
                reason = f"stored receipt rejected: {error}"
                quarantine = layout["quarantine"] / f"{key}.{time.time_ns()}.{os.getpid()}"
                if not entry.is_symlink():
                    os.chmod(entry, 0o700)
                os.rename(entry, quarantine)
                reason += f" (quarantined to {quarantine})"
            else:
                reused(receipt_bytes)
                _write_decision(decision_output, decision)
                return provenance_bytes
        provenance_bytes, receipt_sha256 = _publish_verified_export(
            repository_root, integration_ref, key, key_inputs, layout, entry
        )
        decision.update(
            decision="published",
            entry=str(entry),
            export_root=str(entry / REUSE_EXPORT_NAME),
            reason=reason,
            receipt_sha256=receipt_sha256,
        )
        _write_decision(decision_output, decision)
        return provenance_bytes
    finally:
        try:
            (lock / "owner").unlink()
        except FileNotFoundError:
            pass
        lock.rmdir()


def _clonefile(source: Path, destination: Path) -> None:
    import ctypes
    import errno

    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    function = library.clonefile
    function.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32)
    function.restype = ctypes.c_int
    clone_nofollow, clone_noownercopy = 0x0001, 0x0002
    if function(os.fsencode(source), os.fsencode(destination), clone_nofollow | clone_noownercopy) != 0:
        code = ctypes.get_errno()
        if code in {errno.ENOTSUP, errno.EXDEV, errno.EOPNOTSUPP}:
            raise CloneUnsupportedError(f"clonefile unsupported: {os.strerror(code)}")
        raise OSError(code, os.strerror(code), str(destination))


def clone_verified_export(cache_root: Path, key: str, destination: Path) -> bytes:
    """Give a run its own kernel clone of a reusable export and check it by metadata."""
    if HEX_SHA256.fullmatch(key) is None:
        raise SourceExportError("verification key is malformed")
    layout = _reuse_layout(cache_root)
    entry = layout["entries"] / key
    receipt, _receipt_bytes, provenance_bytes, records = _load_reusable_entry(entry, key, None)
    if not destination.is_absolute() or destination.exists() or destination.is_symlink():
        raise SourceExportError("clone destination must be a new absolute path")
    parent = destination.parent.resolve(strict=True)
    if parent != destination.parent or parent == Path("/"):
        raise SourceExportError("clone destination parent is broad or indirect")
    try:
        _clonefile(entry / REUSE_EXPORT_NAME, destination)
    except BaseException:
        if destination.exists() or destination.is_symlink():
            _remove_owned_tree(destination)
        raise
    try:
        # The shared entry must not have changed while the kernel cloned it.
        if _metadata_summary(_walk_metadata(entry / REUSE_EXPORT_NAME)) != (
            receipt["export_metadata_sha256"], receipt["file_count"], receipt["total_bytes"]
        ):
            raise SourceExportError("stored export changed while it was cloned")
        _make_tree_writable(destination)
        expected = {str(record["path"]): record for record in records}
        observed = _walk_metadata(destination)
        observed_files: dict[str, list[object]] = {}
        for item in observed:
            if item[1] == "file":
                observed_files[str(item[0])] = item
        allowed = set(expected) | {FILES_NAME, PROVENANCE_NAME, COMMIT_OBJECT_NAME}
        if set(observed_files) != allowed:
            raise SourceExportError("cloned export file set differs from its manifest")
        mode_index = 2 + STABLE_METADATA_FIELDS.index("st_mode")
        nlink_index = 2 + STABLE_METADATA_FIELDS.index("st_nlink")
        size_index = 2 + STABLE_METADATA_FIELDS.index("st_size")
        for relative, record in expected.items():
            item = observed_files[relative]
            permissions = stat.S_IMODE(int(item[mode_index]))
            if (
                item[nlink_index] != 1
                or item[size_index] != record["size"]
                or permissions != (0o755 if record["mode"] == "100755" else 0o644)
            ):
                raise SourceExportError(f"cloned export does not match its manifest: {relative}")
        cloned_provenance = _read_stable_bounded_file(
            destination / PROVENANCE_NAME, MAX_RECORD_BYTES, "cloned source provenance"
        )
        _files_value, cloned_files = _load_canonical_json(destination / FILES_NAME)
        cloned_commit = _read_exported_commit_object(destination / COMMIT_OBJECT_NAME)
        if (
            cloned_provenance != provenance_bytes
            or _sha256_bytes(cloned_files) != receipt["source_files_sha256"]
            or _sha256_bytes(cloned_commit) != receipt["commit_object_sha256"]
        ):
            raise SourceExportError("cloned export records differ from the receipt")
    except BaseException:
        _remove_owned_tree(destination)
        raise
    return provenance_bytes


# ── Git-identity staging (owner decision D1, 2026-10-12) ─────────────────────
#
# Git already gives every tree a cryptographic identity. A run source is
# admitted by `HEAD == HEAD^{tree} owner == integration ref (== expected
# commit)` plus an empty `git status --porcelain`, then materialized as an APFS
# clone of the tracked worktree files. Nothing is re-verified afterwards. The
# SOURCE_FILES.json/SOURCE_PROVENANCE.json records keep their schema so every
# consumer (dependency cache keys, Release provenance, Gate F) is unchanged;
# each file's SHA-256 is computed once per Git blob ID (with a Git blob-ID check
# of the same bytes) and later runs trust that memo by its key.

BLOB_MEMO_NAME = "git-blob-sha256.v1.json"


def _load_blob_memo(path: Optional[Path]) -> dict[str, list[object]]:
    if path is None:
        return {}
    try:
        value = json.loads(path.read_bytes())
    except (OSError, ValueError):
        return {}
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        return {}
    blobs = value.get("blobs")
    return blobs if isinstance(blobs, dict) else {}


def _store_blob_memo(path: Optional[Path], blobs: dict[str, list[object]]) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}")
    temporary.write_bytes(_canonical_json({"blobs": blobs, "schema_version": 1}))
    temporary.chmod(0o600)
    os.replace(temporary, path)


def _hash_once(source: Path, object_id: str) -> tuple[str, int]:
    """SHA-256 of a worktree file whose bytes must be the Git blob `object_id`."""
    size = source.lstat().st_size
    digest = hashlib.sha256()
    blob = hashlib.sha1(f"blob {size}\0".encode("ascii"))
    with source.open("rb") as handle:
        while True:
            block = handle.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
            blob.update(block)
    if blob.hexdigest() != object_id:
        raise SourceExportError(f"worktree file does not match its HEAD blob: {source}")
    return digest.hexdigest(), size


def _worktree_records(
    root: Path,
    entries: Sequence[tuple[str, str, str]],
    memo: dict[str, list[object]],
) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for relative, mode, object_id in entries:
        source = root / relative
        metadata = source.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            raise SourceExportError(f"tracked source is not an ordinary worktree file: {relative}")
        if bool(metadata.st_mode & 0o100) != (mode == "100755"):
            raise SourceExportError(f"worktree file mode differs from HEAD: {relative}")
        cached = memo.get(object_id)
        parsed = None
        if relative in LFS_PATHS and cached is None:
            blob_size = _required_git_text(root, "cat-file", "-s", object_id)
            if blob_size.isdigit() and int(blob_size) <= 512:
                pointer = _git(root, "cat-file", "blob", object_id).stdout
                parsed = _parse_lfs_pointer(pointer, len(pointer), relative)
        elif relative in LFS_PATHS and cached[1] != metadata.st_size:
            raise SourceExportError(f"LFS payload is not materialized (run git lfs pull): {relative}")
        if parsed is not None:
            digest, size = parsed
            if metadata.st_size != size:
                raise SourceExportError(f"LFS payload is not materialized (run git lfs pull): {relative}")
            observed = hashlib.sha256()
            with source.open("rb") as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b""):
                    observed.update(block)
            if observed.hexdigest() != digest:
                raise SourceExportError(f"LFS payload does not match its Git pointer: {relative}")
            memo[object_id] = [digest, size]
        elif cached is None or cached[1] != metadata.st_size:
            memo[object_id] = list(_hash_once(source, object_id))
        digest, size = memo[object_id]
        records.append({"blob_oid": object_id, "mode": mode, "path": relative,
                        "sha256": digest, "size": size})
    return records


def _remove_staged_path(path: Path) -> None:
    import shutil
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def _prune_untracked(git_root: Path, staged_root: Path) -> None:
    """Drop .git and ignored paths from a directory clone of a clean worktree."""
    _remove_staged_path(staged_root / ".git")
    listing = _git(git_root, "ls-files", "-z", "--others", "--ignored",
                   "--exclude-standard", "--directory").stdout
    for raw in listing.split(b"\0"):
        if raw:
            _remove_staged_path(staged_root / os.fsdecode(raw).rstrip("/"))


def _stage_tree_by_clone(root: Path, destination: Path,
                         records: Sequence[dict[str, object]],
                         module_roots: Sequence[tuple[Path, str]]) -> None:
    import shutil
    try:
        _clonefile(root, destination)
    except CloneUnsupportedError:
        shutil.copytree(root, destination, symlinks=True)
    _prune_untracked(root, destination)
    for module_root, relative in module_roots:
        _prune_untracked(module_root, destination / relative)
    # Structure check only (no bytes): the clone holds exactly the HEAD file set.
    expected = {str(record["path"]): int(record["size"]) for record in records}
    seen = 0
    for directory, directories, files in os.walk(destination):
        base = Path(directory)
        for name in directories:
            if (base / name).is_symlink():
                raise SourceExportError(f"staged source contains a symlink: {base / name}")
        for name in files:
            path = base / name
            relative = path.relative_to(destination).as_posix()
            size = expected.get(relative)
            metadata = path.lstat()
            if size is None or not stat.S_ISREG(metadata.st_mode) or metadata.st_size != size:
                raise SourceExportError(f"staged source differs from the HEAD file set: {relative}")
            seen += 1
    if seen != len(expected):
        raise SourceExportError("staged source is missing HEAD files")


def stage_git_source(
    repository_root: Path,
    destination: Path,
    integration_ref: str,
    *,
    expected_commit: Optional[str] = None,
    record_cache: Optional[Path] = None,
) -> dict[str, object]:
    """Admit a clean Git worktree by identity and stage it without re-verification."""
    root = repository_root.resolve(strict=True)
    _require_clean_git_root(root)
    _remote_name, remote_url = _integration_remote(root, integration_ref)
    head_commit = _required_git_text(root, "rev-parse", "HEAD")
    head_tree = _required_git_text(root, "rev-parse", "HEAD^{tree}")
    integration_commit = _required_git_text(root, "rev-parse", f"{integration_ref}^{{commit}}")
    if any(HEX_SHA1.fullmatch(value) is None for value in (head_commit, head_tree, integration_commit)):
        raise SourceExportError("Git source identity is malformed")
    if integration_commit != head_commit:
        raise SourceExportError("HEAD does not match the authorized integration ref")
    if expected_commit is not None and expected_commit != head_commit:
        raise SourceExportError("HEAD does not match the expected integration commit")
    commit_object = _canonical_git_commit_object(root, head_commit)
    commit_tree, parents = _commit_object_identity(commit_object)
    if commit_tree != head_tree:
        raise SourceExportError("Git commit object does not bind HEAD^{tree}")
    destination = destination.parent.resolve(strict=True) / destination.name
    if destination.exists() or destination.is_symlink():
        raise SourceExportError("source stage destination must not already exist")
    memo_path = record_cache / BLOB_MEMO_NAME if record_cache is not None else None
    memo = _load_blob_memo(memo_path)
    known = len(memo)
    ordinary, groups = _canonical_source_groups(root, head_commit)
    records = _worktree_records(root, ordinary, memo)
    submodules: list[dict[str, str]] = []
    module_roots: list[tuple[Path, str]] = []
    for module_root, module_entries, metadata in groups:
        relative = metadata["path"]
        module_records = _worktree_records(module_root, module_entries, memo)
        records.extend({**record, "path": relative + "/" + str(record["path"])}
                       for record in module_records)
        submodules.append(metadata)
        module_roots.append((module_root, relative))
    records.sort(key=lambda record: os.fsencode(str(record["path"])))
    if len(memo) != known:
        _store_blob_memo(memo_path, memo)
    _stage_tree_by_clone(root, destination, records, module_roots)
    _require_clean_git_root(root)
    if _required_git_text(root, "rev-parse", "HEAD") != head_commit:
        raise SourceExportError("Git source identity changed during staging")
    files_payload: dict[str, object] = {"files": records, "schema_version": SCHEMA_VERSION}
    if submodules:
        files_payload["submodules"] = submodules
    files_bytes = _canonical_json(files_payload)
    (destination / FILES_NAME).write_bytes(files_bytes)
    (destination / COMMIT_OBJECT_NAME).write_bytes(commit_object)
    provenance: dict[str, object] = {
        "canonical_integration_commit": integration_commit,
        "canonical_integration_ref": integration_ref,
        "canonical_remote_url": remote_url,
        "dependency_contract": {
            **_dependency_contract(destination, records),
            "source_export_package": _source_export_package_contract(
                commit_object, has_submodules=bool(submodules)
            ),
        },
        "git_head_commit": head_commit,
        "git_head_tree": head_tree,
        "git_parent_commits": parents,
        "repository_clean": True,
        "schema_version": SCHEMA_VERSION,
        "source_file_count": len(records),
        "source_files_sha256": hashlib.sha256(files_bytes).hexdigest(),
    }
    (destination / PROVENANCE_NAME).write_bytes(_canonical_json(provenance))
    for name in (FILES_NAME, COMMIT_OBJECT_NAME, PROVENANCE_NAME):
        (destination / name).chmod(0o644)
    return provenance


def main(arguments: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("create")
    create.add_argument("--repository-root", required=True, type=Path)
    create.add_argument("--destination", required=True, type=Path)
    create.add_argument("--integration-ref", required=True)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--source-root", required=True, type=Path)
    reuse = subparsers.add_parser("reuse-export")
    reuse.add_argument("--repository-root", required=True, type=Path)
    reuse.add_argument("--integration-ref", required=True)
    reuse.add_argument("--cache-root", required=True, type=Path)
    reuse.add_argument("--verifier-sha256", required=True)
    reuse.add_argument("--fallback-destination", required=True, type=Path)
    reuse.add_argument("--decision-output", required=True, type=Path)
    clone = subparsers.add_parser("clone-export")
    clone.add_argument("--cache-root", required=True, type=Path)
    clone.add_argument("--key", required=True)
    clone.add_argument("--destination", required=True, type=Path)
    git_stage = subparsers.add_parser("git-stage")
    git_stage.add_argument("--repository-root", required=True, type=Path)
    git_stage.add_argument("--destination", required=True, type=Path)
    git_stage.add_argument("--integration-ref", required=True)
    git_stage.add_argument("--expected-commit")
    git_stage.add_argument("--record-cache", type=Path)
    parsed = parser.parse_args(arguments)
    try:
        if parsed.command == "git-stage":
            result = stage_git_source(
                parsed.repository_root,
                parsed.destination,
                parsed.integration_ref,
                expected_commit=parsed.expected_commit or None,
                record_cache=parsed.record_cache,
            )
            sys.stdout.buffer.write(_canonical_json(result))
            return 0
        if parsed.command == "reuse-export":
            sys.stdout.buffer.write(reuse_or_verify_export(
                parsed.repository_root,
                parsed.integration_ref,
                parsed.cache_root,
                parsed.verifier_sha256,
                parsed.fallback_destination,
                parsed.decision_output,
            ))
            return 0
        if parsed.command == "clone-export":
            sys.stdout.buffer.write(clone_verified_export(
                parsed.cache_root, parsed.key, parsed.destination
            ))
            return 0
        if parsed.command == "create":
            result = create_export(
                parsed.repository_root,
                parsed.destination,
                parsed.integration_ref,
            )
        else:
            result = verify_export(parsed.source_root)
        sys.stdout.buffer.write(_canonical_json(result))
        return 0
    except CloneUnsupportedError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return CLONE_UNSUPPORTED_STATUS
    except (OSError, SourceExportError, UnicodeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
