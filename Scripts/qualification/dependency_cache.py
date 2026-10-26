#!/usr/bin/env python3
"""Content-addressed, immutable dependency artifacts for qualification runs."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from typing import Any, Iterable


SCHEMA_VERSION = 1
EVENT_SCHEMA_VERSION = 1
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
NAME = re.compile(r"[a-z0-9][a-z0-9._-]{0,127}")
MAX_FILES = 100_000
MAX_BYTES = 8 * 1024 * 1024 * 1024


class CacheError(RuntimeError):
    """A cache path or identity violated the closed cache contract."""


def canonical_json(value: object) -> bytes:
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


def object_without_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CacheError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_canonical_json(path: Path, label: str) -> dict[str, Any]:
    if path.is_symlink():
        raise CacheError(f"{label} must not be a symbolic link")
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise CacheError(f"{label} must be one ordinary single-link file")
    payload = path.read_bytes()
    try:
        value = json.loads(payload, object_pairs_hook=object_without_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CacheError(f"{label} is malformed") from error
    if not isinstance(value, dict) or canonical_json(value) != payload:
        raise CacheError(f"{label} is not canonical JSON")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def stable_file_sha256(path: Path, before: os.stat_result) -> str:
    """Hash one ordinary payload leaf while retaining its within-read lease."""
    fields = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
                            value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        if not stat.S_ISREG(opened.st_mode) or fields(opened) != fields(before):
            raise CacheError("cache payload changed before content comparison")
        digest = hashlib.sha256()
        while block := stream.read(1024 * 1024):
            digest.update(block)
        if fields(os.fstat(stream.fileno())) != fields(before):
            raise CacheError("cache payload changed during content comparison")
    if fields(path.lstat()) != fields(before):
        raise CacheError("cache payload changed after content comparison")
    return digest.hexdigest()


def canonical_relative(raw: str, label: str) -> str:
    if not raw or "\x00" in raw or any(ord(character) < 0x20 for character in raw):
        raise CacheError(f"{label} is not a canonical relative path")
    value = PurePosixPath(raw)
    if value.is_absolute() or value.as_posix() != raw or any(
        part in {"", ".", ".."} for part in value.parts
    ):
        raise CacheError(f"{label} is not a canonical relative path")
    return raw


def named_value(raw: str, label: str) -> tuple[str, str]:
    name, separator, value = raw.partition("=")
    if not separator or NAME.fullmatch(name) is None or "\x00" in value:
        raise CacheError(f"{label} must be NAME=VALUE")
    return name, value


def source_records(path: Path) -> list[dict[str, object]]:
    value = read_canonical_json(path, "source-file manifest")
    fields = {"files", "schema_version"}
    if set(value) not in (fields, fields | {"submodules"}) or value["schema_version"] != 2:
        raise CacheError("source-file manifest schema is unsupported")
    if "submodules" in value:
        # Qualification already verified the whole export. Keep the canonical
        # producer's pure metadata checks here without rescanning source bytes
        # or changing unrelated component cache keys.
        verifier = Path(__file__).resolve().parents[1] / "source_export_provenance.py"
        spec = importlib.util.spec_from_file_location("cache_source_provenance", verifier)
        if spec is None or spec.loader is None:
            raise CacheError("source submodule verifier is unavailable")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        try:
            module.validated_submodules(value)
        except module.SourceExportError as error:
            raise CacheError(f"source submodule metadata is invalid: {error}") from error
    raw_records = value["files"]
    if not isinstance(raw_records, list) or not raw_records or len(raw_records) > MAX_FILES:
        raise CacheError("source-file manifest file list is invalid")
    records: list[dict[str, object]] = []
    previous: bytes | None = None
    for record in raw_records:
        if not isinstance(record, dict) or set(record) != {
            "blob_oid",
            "mode",
            "path",
            "sha256",
            "size",
        }:
            raise CacheError("source-file manifest record is malformed")
        relative = canonical_relative(record.get("path", ""), "source-file path")
        encoded = os.fsencode(relative)
        if previous is not None and encoded <= previous:
            raise CacheError("source-file manifest paths are not strictly ordered")
        previous = encoded
        if record["mode"] not in {"100644", "100755"}:
            raise CacheError("source-file mode is unsupported")
        if not isinstance(record["blob_oid"], str) or HEX40.fullmatch(record["blob_oid"]) is None:
            raise CacheError("source-file blob identity is malformed")
        if not isinstance(record["sha256"], str) or HEX64.fullmatch(record["sha256"]) is None:
            raise CacheError("source-file digest is malformed")
        if (
            isinstance(record["size"], bool)
            or not isinstance(record["size"], int)
            or record["size"] < 0
        ):
            raise CacheError("source-file size is malformed")
        records.append(record)
    return records


def external_file_identity(raw: str) -> dict[str, object]:
    name, requested = named_value(raw, "external-file identity")
    requested_path = Path(requested)
    if not requested_path.is_absolute():
        raise CacheError("external-file identity path must be absolute")
    resolved = requested_path.resolve(strict=True)
    metadata = resolved.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise CacheError(f"external-file identity is not an ordinary file: {name}")
    return {
        "name": name,
        "path": str(resolved),
        "sha256": sha256(resolved),
        "size": metadata.st_size,
    }


def key_command(arguments: argparse.Namespace) -> int:
    print(compute_key(arguments))
    return 0


def compute_key(arguments: argparse.Namespace) -> str:
    """Return the cache key; callers in threads must not capture key_command's stdout."""
    if NAME.fullmatch(arguments.component) is None:
        raise CacheError("component name is invalid")
    prefixes = [canonical_relative(value, "source prefix") for value in arguments.prefix]
    if len(set(prefixes)) != len(prefixes):
        raise CacheError("source prefixes must be unique")
    records = source_records(arguments.source_files)
    selected: list[dict[str, object]] = []
    matched = {prefix: False for prefix in prefixes}
    for record in records:
        relative = str(record["path"])
        for prefix in prefixes:
            if relative == prefix or relative.startswith(prefix + "/"):
                matched[prefix] = True
                selected.append(record)
                break
    missing = [prefix for prefix, present in matched.items() if not present]
    if missing:
        raise CacheError("source prefix matched no governed input: " + ", ".join(missing))
    values = dict(named_value(value, "cache-key value") for value in arguments.value)
    if len(values) != len(arguments.value):
        raise CacheError("cache-key value names must be unique")
    external = [external_file_identity(value) for value in arguments.external_file]
    external.sort(key=lambda item: str(item["name"]))
    if len({item["name"] for item in external}) != len(external):
        raise CacheError("external-file identity names must be unique")
    payload = {
        "component": arguments.component,
        "external_files": external,
        "schema_version": SCHEMA_VERSION,
        "source_records": selected,
        "values": values,
    }
    return hashlib.sha256(canonical_json(payload)).hexdigest()


def external_identity_command(arguments: argparse.Namespace) -> int:
    external = [external_file_identity(value) for value in arguments.external_file]
    external.sort(key=lambda item: str(item["name"]))
    if not external or len({item["name"] for item in external}) != len(external):
        raise CacheError("external-file identities must be nonempty and uniquely named")
    print(hashlib.sha256(canonical_json(external)).hexdigest())
    return 0


def payload_records(root: Path, *, hash_files: bool = True, allow_hardlinks: bool = False) -> tuple[list[dict[str, object]], int]:
    if root.is_symlink() or not root.is_dir():
        raise CacheError("cache payload must be an ordinary directory")
    records: list[dict[str, object]] = []
    total_bytes = 0
    candidates = sorted(root.rglob("*"), key=lambda item: os.fsencode(item.relative_to(root)))
    if len(candidates) > MAX_FILES:
        raise CacheError("cache payload exceeds the member bound")
    for candidate in candidates:
        relative = candidate.relative_to(root).as_posix()
        metadata = candidate.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            target = os.readlink(candidate)
            target_path = PurePosixPath(target)
            if target_path.is_absolute() or any(part in {"", ".", ".."} for part in target_path.parts):
                raise CacheError(f"cache payload contains an unsafe symbolic link: {relative}")
            resolved = candidate.resolve(strict=True)
            try:
                resolved.relative_to(root.resolve(strict=True))
            except ValueError as error:
                raise CacheError(f"cache payload symbolic link escapes its root: {relative}") from error
            if not resolved.is_file():
                raise CacheError(f"cache payload symbolic link is not file-bound: {relative}")
            records.append({"kind": "symlink", "path": relative, "target": target})
            continue
        if stat.S_ISDIR(metadata.st_mode):
            records.append({"kind": "directory", "path": relative})
            continue
        if not stat.S_ISREG(metadata.st_mode) or (metadata.st_nlink != 1 and not allow_hardlinks):
            raise CacheError(f"cache payload contains a nonordinary leaf: {relative}")
        total_bytes += metadata.st_size
        if total_bytes > MAX_BYTES:
            raise CacheError("cache payload exceeds the aggregate-size bound")
        record: dict[str, object] = {
            "executable": bool(stat.S_IMODE(metadata.st_mode) & 0o111),
            "kind": "file",
            "path": relative,
            "size": metadata.st_size,
        }
        if hash_files:
            record["sha256"] = stable_file_sha256(candidate, metadata)
        records.append(record)
    if not any(record["kind"] == "file" for record in records):
        raise CacheError("cache payload contains no files")
    return records, total_bytes


def payload_tree_digest(records: Iterable[dict[str, object]]) -> str:
    return hashlib.sha256(canonical_json(list(records))).hexdigest()


def freeze_tree(root: Path) -> None:
    paths = [root, *root.rglob("*")]
    for path in paths:
        metadata = path.lstat()
        if stat.S_ISREG(metadata.st_mode):
            mode = 0o555 if metadata.st_mode & 0o111 else 0o444
            path.chmod(mode)
    directories = sorted(
        [path for path in paths if stat.S_ISDIR(path.lstat().st_mode)],
        key=lambda item: len(item.parts),
        reverse=True,
    )
    for directory in directories:
        directory.chmod(0o555)


def validate_entry_name(component: str, key: str) -> None:
    if NAME.fullmatch(component) is None or HEX64.fullmatch(key) is None:
        raise CacheError("cache entry identity is malformed")


def reject_indirect_ancestors(path: Path, label: str) -> None:
    """Reject lexical paths whose existing ancestry contains a symlink."""
    if not path.is_absolute():
        raise CacheError(f"{label} must be absolute")
    current = Path(path.anchor)
    for part in path.parts[1:-1]:
        current /= part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(metadata.st_mode):
            raise CacheError(f"{label} has an indirect ancestor")
        if not stat.S_ISDIR(metadata.st_mode):
            raise CacheError(f"{label} has a nondirectory ancestor")


def load_entry_receipt(entry: Path, component: str, key: str) -> dict[str, Any]:
    validate_entry_name(component, key)
    reject_indirect_ancestors(entry, "cache entry")
    if entry.is_symlink() or not entry.is_dir():
        raise CacheError("cache entry is missing or indirect")
    if entry.stat().st_mode & 0o222:
        raise CacheError("cache entry directory is writable")
    metadata_path = entry / "ENTRY.json"
    value = read_canonical_json(metadata_path, "cache entry receipt")
    expected_fields = {
        "component",
        "file_count",
        "key",
        "payload_records",
        "payload_tree_sha256",
        "schema_version",
        "total_bytes",
    }
    if set(value) != expected_fields or value.get("schema_version") != SCHEMA_VERSION:
        raise CacheError("cache entry receipt schema is unsupported")
    if value.get("component") != component or value.get("key") != key:
        raise CacheError("cache entry receipt identity differs")
    records = value.get("payload_records")
    if not isinstance(records, list):
        raise CacheError("cache entry payload record is malformed")
    return value


def load_entry(entry: Path, component: str, key: str) -> dict[str, Any]:
    value = load_entry_receipt(entry, component, key)
    metadata_path = entry / "ENTRY.json"
    records = value["payload_records"]
    observed_records, observed_bytes = payload_records(entry / "payload")
    checks = {
        "payload records": observed_records == records,
        "payload digest": value.get("payload_tree_sha256") == payload_tree_digest(observed_records),
        "file count": value.get("file_count")
        == sum(record["kind"] == "file" for record in observed_records),
        "total bytes": value.get("total_bytes") == observed_bytes,
        "receipt read-only": metadata_path.stat().st_mode & 0o222 == 0,
        "payload read-only": all(
            path.lstat().st_mode & 0o222 == 0
            for path in [entry / "payload", *(entry / "payload").rglob("*")]
            if not stat.S_ISLNK(path.lstat().st_mode)
        ),
    }
    failed = [name for name, accepted in checks.items() if not accepted]
    if failed:
        raise CacheError("cache entry verification failed: " + ", ".join(failed))
    return value


def publish_command(arguments: argparse.Namespace) -> int:
    entry = arguments.entry
    payload = arguments.payload
    validate_entry_name(arguments.component, arguments.key)
    if not entry.is_absolute() or not payload.is_absolute():
        raise CacheError("cache publication paths must be absolute")
    reject_indirect_ancestors(entry, "cache entry")
    if entry.exists() or entry.is_symlink():
        raise CacheError("cache entry already exists")
    entry.parent.mkdir(parents=True, exist_ok=True)
    if (
        entry.parent.is_symlink()
        or not entry.parent.is_dir()
        or entry.parent.resolve(strict=True) != entry.parent
    ):
        raise CacheError("cache entry parent is unsafe")
    records, total_bytes = payload_records(payload)
    document = {
        "component": arguments.component,
        "file_count": sum(record["kind"] == "file" for record in records),
        "key": arguments.key,
        "payload_records": records,
        "payload_tree_sha256": payload_tree_digest(records),
        "schema_version": SCHEMA_VERSION,
        "total_bytes": total_bytes,
    }
    staging = Path(tempfile.mkdtemp(prefix=f".{arguments.key}.publish.", dir=entry.parent))
    staged_payload = staging / "payload"
    try:
        os.rename(payload, staged_payload)
        staged_records, staged_bytes = payload_records(staged_payload)
        if staged_records != records or staged_bytes != total_bytes:
            raise CacheError("cache payload changed during publication")
        receipt = staging / "ENTRY.json"
        receipt.write_bytes(canonical_json(document))
        receipt.chmod(0o444)
        freeze_tree(staged_payload)
        staging.chmod(0o555)
        os.rename(staging, entry)
    except Exception:
        if staging.exists():
            for path in [staging, *staging.rglob("*")]:
                try:
                    path.chmod(0o700 if path.is_dir() else 0o600)
                except OSError:
                    pass
            shutil.rmtree(staging, ignore_errors=True)
        raise
    load_entry(entry, arguments.component, arguments.key)
    return 0


def verify_command(arguments: argparse.Namespace) -> int:
    load_entry(arguments.entry, arguments.component, arguments.key)
    return 0


def materialize_command(arguments: argparse.Namespace) -> int:
    entry = arguments.entry
    destination = arguments.destination
    snapshot_before = entry_metadata_digest(entry) if arguments.snapshot_output else None
    document = load_entry(entry, arguments.component, arguments.key)
    if arguments.snapshot_output:
        # Bind the metadata snapshot to the full byte verification just done:
        # the entry must be unchanged across the whole hashing interval.
        if entry_metadata_digest(entry) != snapshot_before:
            raise CacheError("cache entry metadata changed during full verification")
        write_new_canonical(
            arguments.snapshot_output,
            {
                "entry": str(entry),
                "entry_metadata_sha256": snapshot_before,
                "entry_receipt_sha256": sha256(entry / "ENTRY.json"),
                "schema_version": VERIFICATION_SCHEMA_VERSION,
            },
        )
    if not destination.is_absolute() or destination in {Path("/"), Path.home().resolve()}:
        raise CacheError("cache destination must be a dedicated absolute path")
    if destination.exists() or destination.is_symlink():
        raise CacheError("cache destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination_parent = destination.parent.resolve(strict=True)
    if destination_parent == Path("/") or destination_parent != destination.parent:
        raise CacheError("cache destination parent is broad or indirect")
    clone = subprocess.run(
        ["/bin/cp", "-cR", str(entry / "payload"), str(destination)],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if clone.returncode != 0:
        if destination.exists():
            for path in [destination, *destination.rglob("*")]:
                try:
                    path.chmod(0o700 if path.is_dir() else 0o600)
                except OSError:
                    pass
            shutil.rmtree(destination)
        subprocess.run(
            ["/bin/cp", "-pR", str(entry / "payload"), str(destination)],
            check=True,
        )
    try:
        records, total_bytes = payload_records(destination)
        if (
            records != document["payload_records"]
            or total_bytes != document["total_bytes"]
            or payload_tree_digest(records) != document["payload_tree_sha256"]
        ):
            raise CacheError("run-owned cache view differs from the verified entry")
        freeze_tree(destination)
    except Exception:
        if destination.exists():
            for path in [destination, *destination.rglob("*")]:
                try:
                    path.chmod(0o700 if path.is_dir() else 0o600)
                except OSError:
                    pass
            shutil.rmtree(destination, ignore_errors=True)
        raise
    return 0


VERIFICATION_SCHEMA_VERSION = 1
CLONE_UNSUPPORTED_STATUS = 3
NOT_REUSABLE_STATUS = 3
VERIFICATION_RECEIPT_FIELDS = frozenset({
    "bindings",
    "component",
    "entry",
    "entry_metadata_sha256",
    "entry_receipt_sha256",
    "key",
    "schema_version",
    "verification",
    "verification_key",
    "verified_at",
    "verified_run_view",
})


class NotReusableError(CacheError):
    """A dependency verification receipt cannot be reused; verify fully instead."""


def write_new_canonical(path: Path, value: dict[str, object]) -> None:
    descriptor = os.open(
        path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600
    )
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(canonical_json(value))


def entry_metadata_digest(entry: Path) -> str:
    """Digest lstat metadata (not bytes) of every member of an immutable entry."""
    reject_indirect_ancestors(entry, "cache entry")
    if entry.is_symlink() or not entry.is_dir():
        raise CacheError("cache entry is missing or indirect")
    entries: list[list[object]] = []
    pending = [("", entry)]
    while pending:
        prefix, directory = pending.pop()
        with os.scandir(directory) as iterator:
            for item in iterator:
                relative = prefix + item.name
                metadata = item.stat(follow_symlinks=False)
                target = os.readlink(item.path) if stat.S_ISLNK(metadata.st_mode) else None
                entries.append(
                    [
                        relative,
                        target,
                        metadata.st_dev,
                        metadata.st_ino,
                        metadata.st_mode,
                        metadata.st_nlink,
                        metadata.st_size,
                        metadata.st_mtime_ns,
                        metadata.st_ctime_ns,
                    ]
                )
                if stat.S_ISDIR(metadata.st_mode):
                    pending.append((relative + "/", Path(item.path)))
        if len(entries) > 2 * MAX_FILES:
            raise CacheError("cache entry exceeds the member bound")
    entries.sort(key=lambda value: os.fsencode(str(value[0])))
    return hashlib.sha256(canonical_json(entries)).hexdigest()


def verification_bindings(raw: list[str]) -> dict[str, str]:
    values = dict(named_value(value, "verification binding") for value in raw)
    if not values or len(values) != len(raw):
        raise CacheError("verification bindings must be nonempty and uniquely named")
    return values


def verification_identity(arguments: argparse.Namespace) -> tuple[str, Path, dict[str, object]]:
    validate_entry_name(arguments.component, arguments.key)
    bindings = verification_bindings(arguments.binding)
    root = arguments.verification_root
    if not root.is_absolute():
        raise CacheError("verification cache root must be absolute")
    resolved = root.resolve(strict=True)
    metadata = root.lstat()
    if (resolved != root or not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022):
        raise CacheError("verification cache root must be ordinary, owner-controlled and not group/world writable")
    root = resolved
    for directory in (root / "dependency-verifications", root / "dependency-verifications" / f"v{VERIFICATION_SCHEMA_VERSION}",
                      root / "dependency-verifications" / f"v{VERIFICATION_SCHEMA_VERSION}" / arguments.component):
        if directory.exists() or directory.is_symlink():
            metadata = directory.lstat()
            if (directory.resolve(strict=True) != directory or not stat.S_ISDIR(metadata.st_mode)
                    or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022):
                raise CacheError("verification cache layout must be ordinary and owner-controlled")
    entry_receipt_sha256 = sha256(arguments.entry / "ENTRY.json")
    identity = {
        "bindings": bindings,
        "component": arguments.component,
        "entry_receipt_sha256": entry_receipt_sha256,
        "key": arguments.key,
        "schema_version": VERIFICATION_SCHEMA_VERSION,
    }
    verification_key = hashlib.sha256(canonical_json(identity)).hexdigest()
    path = (
        root
        / "dependency-verifications"
        / f"v{VERIFICATION_SCHEMA_VERSION}"
        / arguments.component
        / f"{verification_key}.json"
    )
    return verification_key, path, identity


def bind_reusable_entry(arguments: argparse.Namespace, value: dict[str, Any], receipt_path: Path) -> None:
    """Admit a content-keyed verification receipt; entry metadata never crosses runs.

    The receipt's verification key binds component, key, bindings and the
    SHA-256 of ENTRY.json, which records every payload path, kind, size,
    executable bit and content digest. Across runs the entry is admitted on
    that content identity plus a structural (no-hash) comparison of the
    immutable payload with ENTRY.json; reboots, copies and touches that only
    move device/inode/timestamps do not invalidate it. The lstat digest taken
    here is a WITHIN-RUN guard only: reuse/clone callers compare it again
    after cloning in this same process.
    """
    del value, receipt_path  # Identity was matched by the caller on content.
    before = entry_metadata_digest(arguments.entry)
    document = load_entry_receipt(arguments.entry, arguments.component, arguments.key)
    records, total_bytes = payload_records(arguments.entry / "payload", hash_files=False, allow_hardlinks=True)
    expected = [
        {name: field for name, field in record.items() if name != "sha256"}
        for record in document["payload_records"]
    ]
    if (records != expected
            or total_bytes != document["total_bytes"]
            or sum(row["kind"] == "file" for row in records) != document["file_count"]):
        raise CacheError("verified cache content differs from its receipt; refusing reuse")
    if any(path.lstat().st_mode & 0o222 for path in
           [arguments.entry / "payload", *(arguments.entry / "payload").rglob("*")]
           if not path.is_symlink()):
        raise CacheError("verified cache payload is writable")
    if entry_metadata_digest(arguments.entry) != before:
        raise CacheError("cache entry changed during content comparison")
    arguments._reused_entry_metadata = before


def sleigh_content_receipt(arguments: argparse.Namespace, path: Path,
                           identity: dict[str, object]) -> tuple[dict[str, Any], str]:
    """A cache-key change may inherit the same full SLEIGH artifact authority."""
    current = load_entry_receipt(arguments.entry, arguments.component, arguments.key)
    matching_domain = False
    fields = lambda row: (row.st_dev, row.st_ino, row.st_mode, row.st_nlink,
                          row.st_size, row.st_mtime_ns, row.st_ctime_ns)
    selected = None
    candidates = sorted(path.parent.glob("*.json"))
    if len(candidates) > 4096:
        raise CacheError("SLEIGH verification receipt lookup exceeds its bound")
    for candidate in candidates:
        if HEX64.fullmatch(candidate.stem) is None:
            continue  # Legacy current-content leases are not domain-verification authorities.
        reject_indirect_ancestors(candidate, "SLEIGH verification receipt")
        metadata = candidate.lstat()
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1
                or metadata.st_uid != os.getuid() or metadata.st_mode & 0o222):
            raise CacheError("SLEIGH verification receipt must be immutable and owner-controlled")
        value = read_canonical_json(candidate, "SLEIGH verification receipt")
        if fields(candidate.lstat()) != fields(metadata):
            raise CacheError("SLEIGH verification receipt changed during lookup")
        if (set(value) != VERIFICATION_RECEIPT_FIELDS
                or value.get("schema_version") != VERIFICATION_SCHEMA_VERSION
                or value.get("component") != "sleigh-native-source"
                or value.get("bindings") != identity["bindings"]):
            continue
        matching_domain = True
        old_key = value.get("key")
        if not isinstance(old_key, str) or HEX64.fullmatch(old_key) is None:
            raise CacheError("SLEIGH verification receipt key is malformed")
        old_entry = arguments.entry.parent / old_key
        if value.get("entry") != str(old_entry):
            raise CacheError("SLEIGH verification receipt entry differs from cache layout")
        old_receipt = old_entry / "ENTRY.json"
        old_metadata = old_receipt.lstat()
        if (not stat.S_ISREG(old_metadata.st_mode) or old_metadata.st_nlink != 1
                or old_metadata.st_uid != os.getuid() or old_metadata.st_mode & 0o222):
            raise CacheError("SLEIGH ENTRY receipt must be immutable and owner-controlled")
        old = load_entry_receipt(old_entry, "sleigh-native-source", old_key)
        expected_identity = dict(identity, key=old_key,
                                 entry_receipt_sha256=stable_file_sha256(old_receipt, old_metadata))
        expected_key = hashlib.sha256(canonical_json(expected_identity)).hexdigest()
        if (value.get("entry_receipt_sha256") != expected_identity["entry_receipt_sha256"]
                or value.get("verification_key") != expected_key or candidate.stem != expected_key):
            raise CacheError("SLEIGH verification receipt content binding differs")
        content_fields = ("payload_records", "payload_tree_sha256", "file_count", "total_bytes")
        if all(old[field] == current[field] for field in content_fields):
            selected = (value, candidate, metadata)
            break
    if selected is None:
        if matching_domain:
            raise CacheError("SLEIGH content differs from prior domain receipts; refusing verification fallback")
        raise NotReusableError("no verified receipt for this SLEIGH content and binding set")
    value, candidate, metadata = selected
    # Original receipt remains untouched. Its recorded content identity (equal
    # ENTRY payload records and tree digest) admits this new cache key; the
    # current payload is compared structurally with its own ENTRY.json.
    bind_reusable_entry(arguments, value, candidate)
    digest = stable_file_sha256(candidate, metadata)
    return value, digest

def load_verification_receipt(arguments: argparse.Namespace) -> tuple[dict[str, Any], str]:
    load_entry_receipt(arguments.entry, arguments.component, arguments.key)
    verification_key, path, identity = verification_identity(arguments)
    if not path.exists() and not path.is_symlink():
        if arguments.component == "sleigh-native-source":
            return sleigh_content_receipt(arguments, path, identity)
        raise NotReusableError("no verified receipt for this dependency key and binding set")
    reject_indirect_ancestors(path, "verification receipt")
    try:
        value = read_canonical_json(path, "verification receipt")
    except CacheError as error:
        raise NotReusableError(f"stored verification receipt is unreadable: {error}") from error
    if set(value) != VERIFICATION_RECEIPT_FIELDS or value.get("schema_version") != VERIFICATION_SCHEMA_VERSION:
        raise NotReusableError("stored verification receipt schema is unsupported")
    expected = {
        "bindings": identity["bindings"],
        "component": arguments.component,
        "entry": str(arguments.entry),
        "entry_receipt_sha256": identity["entry_receipt_sha256"],
        "key": arguments.key,
        "verification_key": verification_key,
    }
    differing = sorted(name for name, accepted in expected.items() if value.get(name) != accepted)
    if differing:
        raise NotReusableError("stored verification receipt differs: " + ", ".join(differing))
    if path.stat().st_mode & 0o222:
        raise NotReusableError("stored verification receipt is writable")
    bind_reusable_entry(arguments, value, path)
    return value, sha256(path)


def record_verification_command(arguments: argparse.Namespace) -> int:
    snapshot = read_canonical_json(arguments.snapshot, "entry metadata snapshot")
    load_entry_receipt(arguments.entry, arguments.component, arguments.key)
    verification_key, path, identity = verification_identity(arguments)
    if (
        set(snapshot) != {"entry", "entry_metadata_sha256", "entry_receipt_sha256", "schema_version"}
        or snapshot.get("schema_version") != VERIFICATION_SCHEMA_VERSION
        or snapshot.get("entry") != str(arguments.entry)
        or snapshot.get("entry_receipt_sha256") != identity["entry_receipt_sha256"]
    ):
        raise CacheError("entry metadata snapshot does not describe this entry")
    # The entry must still be the bytes that were fully verified, and that
    # the domain verifier then accepted through the run-owned view.
    if entry_metadata_digest(arguments.entry) != snapshot["entry_metadata_sha256"]:
        raise CacheError("cache entry metadata changed during dependency verification")
    value = {
        "bindings": identity["bindings"],
        "component": arguments.component,
        "entry": str(arguments.entry),
        "entry_metadata_sha256": snapshot["entry_metadata_sha256"],
        "entry_receipt_sha256": identity["entry_receipt_sha256"],
        "key": arguments.key,
        "schema_version": VERIFICATION_SCHEMA_VERSION,
        "verification": arguments.verification,
        "verification_key": verification_key,
        "verified_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "verified_run_view": str(arguments.run_view.resolve(strict=True)),
    }
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    reject_indirect_ancestors(path, "verification receipt")
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    temporary.write_bytes(canonical_json(value))
    temporary.chmod(0o444)
    # Atomic replacement: concurrent gates publish semantically equivalent
    # receipts and readers never observe a partial file.
    os.replace(temporary, path)
    print(sha256(path))
    return 0


def clonefile_tree(source: Path, destination: Path) -> None:
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
            raise NotReusableError(f"clonefile unsupported: {os.strerror(code)}")
        raise OSError(code, os.strerror(code), str(destination))


def remove_view(destination: Path) -> None:
    if destination.exists() or destination.is_symlink():
        for path in [destination, *destination.rglob("*")]:
            try:
                if not path.is_symlink():
                    path.chmod(0o700 if path.is_dir() else 0o600)
            except OSError:
                pass
        shutil.rmtree(destination, ignore_errors=True)


def reuse_check_command(arguments: argparse.Namespace) -> int:
    try:
        _value, digest = load_verification_receipt(arguments)
    except NotReusableError as error:
        print(str(error))
        return NOT_REUSABLE_STATUS
    print(digest)
    return 0


def reuse_verified_command(arguments: argparse.Namespace) -> int:
    destination = arguments.destination
    try:
        value, digest = load_verification_receipt(arguments)
    except NotReusableError as error:
        print(str(error))
        return NOT_REUSABLE_STATUS
    document = load_entry_receipt(arguments.entry, arguments.component, arguments.key)
    if not destination.is_absolute() or destination in {Path("/"), Path.home().resolve()}:
        raise CacheError("cache destination must be a dedicated absolute path")
    if destination.exists() or destination.is_symlink():
        raise CacheError("cache destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination_parent = destination.parent.resolve(strict=True)
    if destination_parent == Path("/") or destination_parent != destination.parent:
        raise CacheError("cache destination parent is broad or indirect")
    try:
        clonefile_tree(arguments.entry / "payload", destination)
        if entry_metadata_digest(arguments.entry) != arguments._reused_entry_metadata:
            raise CacheError("cache entry metadata changed while it was cloned")
        records, total_bytes = payload_records(destination, hash_files=False)
        expected = [
            {name: field for name, field in record.items() if name != "sha256"}
            for record in document["payload_records"]
        ]
        if records != expected or total_bytes != document["total_bytes"]:
            raise NotReusableError("run-owned clone differs from the verified entry metadata")
        freeze_tree(destination)
    except NotReusableError as error:
        remove_view(destination)
        print(str(error))
        return NOT_REUSABLE_STATUS
    except BaseException:
        remove_view(destination)
        raise
    print(digest)
    return 0


def record_event_command(arguments: argparse.Namespace) -> int:
    validate_entry_name(arguments.component, arguments.key)
    # The caller records an event only after materialize has fully verified both
    # the immutable entry and its run-owned view. Re-read the canonical receipt
    # here without a third full payload traversal.
    document = load_entry_receipt(arguments.entry, arguments.component, arguments.key)
    receipt = arguments.receipt
    source = {"commit": arguments.source_commit, "tree": arguments.source_tree}
    cache_root = str(arguments.cache_root.resolve(strict=True))
    if receipt.exists() or receipt.is_symlink():
        value = read_canonical_json(receipt, "cache-event receipt")
        if (
            set(value) != {"dependency_cache_root", "events", "schema_version", "source"}
            or value.get("schema_version") != EVENT_SCHEMA_VERSION
            or value.get("source") != source
            or value.get("dependency_cache_root") != cache_root
            or not isinstance(value.get("events"), list)
        ):
            raise CacheError("cache-event receipt identity differs")
    else:
        value = {
            "dependency_cache_root": cache_root,
            "events": [],
            "schema_version": EVENT_SCHEMA_VERSION,
            "source": source,
        }
    value["events"].append(
        {
            "bytes": document["total_bytes"],
            "component": arguments.component,
            "entry": str(arguments.entry.resolve(strict=True)),
            "key": arguments.key,
            "recorded_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "run_view": str(arguments.run_view.resolve(strict=True)),
            "status": arguments.status,
        }
    )
    temporary = receipt.with_name(receipt.name + f".tmp.{os.getpid()}")
    temporary.write_bytes(canonical_json(value))
    temporary.chmod(0o600)
    os.replace(temporary, receipt)
    return 0


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser()
    commands = value.add_subparsers(dest="command", required=True)

    key = commands.add_parser("key")
    key.add_argument("--source-files", type=Path, required=True)
    key.add_argument("--component", required=True)
    key.add_argument("--prefix", action="append", default=[], required=True)
    key.add_argument("--value", action="append", default=[])
    key.add_argument("--external-file", action="append", default=[])
    key.set_defaults(action=key_command)

    external = commands.add_parser("external-identity")
    external.add_argument("--external-file", action="append", default=[], required=True)
    external.set_defaults(action=external_identity_command)

    for name, action in (("verify", verify_command), ("publish", publish_command)):
        command = commands.add_parser(name)
        command.add_argument("--entry", type=Path, required=True)
        command.add_argument("--component", required=True)
        command.add_argument("--key", required=True)
        if name == "publish":
            command.add_argument("--payload", type=Path, required=True)
        command.set_defaults(action=action)

    materialize = commands.add_parser("materialize")
    materialize.add_argument("--entry", type=Path, required=True)
    materialize.add_argument("--component", required=True)
    materialize.add_argument("--key", required=True)
    materialize.add_argument("--destination", type=Path, required=True)
    materialize.add_argument("--snapshot-output", type=Path)
    materialize.set_defaults(action=materialize_command)

    for name, action in (
        ("reuse-check", reuse_check_command),
        ("reuse-verified", reuse_verified_command),
        ("record-verification", record_verification_command),
    ):
        command = commands.add_parser(name)
        command.add_argument("--entry", type=Path, required=True)
        command.add_argument("--component", required=True)
        command.add_argument("--key", required=True)
        command.add_argument("--verification-root", type=Path, required=True)
        command.add_argument("--binding", action="append", default=[], required=True)
        if name == "reuse-verified":
            command.add_argument("--destination", type=Path, required=True)
        if name == "record-verification":
            command.add_argument("--snapshot", type=Path, required=True)
            command.add_argument("--run-view", type=Path, required=True)
            command.add_argument("--verification", required=True)
        command.set_defaults(action=action)

    event = commands.add_parser("record-event")
    event.add_argument("--receipt", type=Path, required=True)
    event.add_argument("--source-commit", required=True)
    event.add_argument("--source-tree", required=True)
    event.add_argument("--cache-root", type=Path, required=True)
    event.add_argument("--component", required=True)
    event.add_argument("--key", required=True)
    event.add_argument("--status", choices=("verified-hit", "published-miss", "verified-after-wait", "receipt-reused-hit"), required=True)
    event.add_argument("--entry", type=Path, required=True)
    event.add_argument("--run-view", type=Path, required=True)
    event.set_defaults(action=record_event_command)
    return value


def main() -> int:
    arguments = parser().parse_args()
    try:
        return arguments.action(arguments)
    except (CacheError, OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
