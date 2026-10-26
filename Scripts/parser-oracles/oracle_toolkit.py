#!/usr/bin/env python3
"""Shared offline helpers for the RX-03 parser-oracle goldens.

No network, no downloads. The engines are the natively built LIEF, pe-parse and
go-macho archives that the analysis worker links; this module only resolves
pins, hashes and canonical JSON. Standard library only; Python 3.9 compatible.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
from pathlib import Path
from typing import Any, Dict, Iterable, List

ORACLE_DIR = Path(__file__).resolve().parent
ROOT = ORACLE_DIR.parents[1]
LOCK_PATH = ORACLE_DIR / "oracles.lock.json"
LOCK_SCHEMA = "macscope.parser-oracles.lock.v2"


class OracleToolkitError(RuntimeError):
    pass


def load_lock() -> Dict[str, Any]:
    with LOCK_PATH.open("rb") as stream:
        lock = json.load(stream)
    if lock.get("schema") != LOCK_SCHEMA:
        raise OracleToolkitError("unexpected parser-oracle lock schema")
    return lock


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git_blob_sha1(payload: bytes) -> str:
    """The Git object identity of `payload`, as `git hash-object` reports it."""
    return hashlib.sha1(b"blob %d\x00" % len(payload) + payload).hexdigest()


def canonical_json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode("ascii")


def require_external(path: Path) -> Path:
    """Generated outputs stay outside the repository."""
    resolved = path.expanduser().resolve()
    if resolved == ROOT or ROOT in resolved.parents:
        raise OracleToolkitError(f"path must be outside the repository: {resolved}")
    return resolved


def tree_files(root: Path) -> Iterable[Path]:
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        if path.name == ".DS_Store":
            continue
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise OracleToolkitError(f"symbolic link in source tree: {path}")
        if stat.S_ISREG(metadata.st_mode):
            yield path


def tree_sha256(root: Path) -> str:
    """Path-and-content identity of a source tree, independent of where it is checked out."""
    digest = hashlib.sha256()
    for path in tree_files(root):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "big") + relative)
        digest.update(bytes.fromhex(sha256_file(path)))
    return digest.hexdigest()


def engine_identities() -> Dict[str, Dict[str, str]]:
    """Machine-independent golden identity of each engine: pin plus vendored source tree."""
    lock = load_lock()
    bridge = tree_sha256(ROOT / lock["bridge"]["source"])
    identities: Dict[str, Dict[str, str]] = {}
    for name, engine in sorted(lock["engines"].items()):
        identities[name] = {
            "oracle": name,
            "kind": "linked-engine",
            "version": engine["version"],
            "git_revision": engine["git_revision"],
            "source_tree_sha256": tree_sha256(ROOT / engine["source"]),
            "bridge_source_tree_sha256": bridge,
        }
    return identities


def environment_root(name: str, default: Path) -> Path:
    value = os.environ.get(name)
    return Path(value).expanduser() if value else default


def as_list(value: Any) -> List[Any]:
    return value if isinstance(value, list) else [value]
