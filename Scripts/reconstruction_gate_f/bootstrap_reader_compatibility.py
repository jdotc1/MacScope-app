"""Closed tooling-only reader amendment, not qualification of a new product tree.

Historical producer commitments are verified against their original Git blobs.
The reader is separately bound to a clean descendant and its exact current blobs.
No native input, workflow, dependency, skip policy or qualification producer other
than the bootstrap admission reader may differ.
"""
from __future__ import annotations

import hashlib
from pathlib import Path
import re
import subprocess

from .artifact_validator import read_descriptor_relative_bytes

BOOTSTRAP_PATH = "Scripts/reconstruction_gate_f/bootstrap_qualification.py"
READER_PATH = "Scripts/reconstruction_gate_f/bootstrap_reader_compatibility.py"
POLICY_ID = "gatef-tooling-reader-amendment-20261004-v1"
# Exact paths, never directory prefixes. The quiescence change is an explicit
# consumer-policy amendment, not a claim that only the byte-budget fix changed.
ALLOWED_PATHS = frozenset((BOOTSTRAP_PATH, READER_PATH,
    "Scripts/tests/test_gate_f_bootstrap_reader_compatibility.py",
    "Scripts/tests/test_gate_f_bootstrap_qualification.py",
    "Scripts/reconstruction/app_quiescence.py",
    "Scripts/tests/test_app_quiescence.py"))
MAX_BYTES = 16 * 1024 * 1024


def _git(root, *args):
    result = subprocess.run(["/usr/bin/git", *args], cwd=root, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=True)
    if len(result.stdout) > MAX_BYTES or len(result.stderr) > 16384:
        raise ValueError("reader Git observation exceeds byte budget")
    return result.stdout


def _hash(value, length=64):
    if type(value) is not str or re.fullmatch("[0-9a-f]{%d}" % length, value) is None:
        raise ValueError("invalid reader identity hash")


def _closed(value, fields):
    if type(value) is not dict or set(value) != set(fields):
        raise ValueError("reader identity fields are not closed")


def _blob(root, commit, relative, *, absent=False):
    entry = _git(root, "ls-tree", commit, "--", relative).decode().strip()
    if not entry and absent:
        return None
    if re.fullmatch(r"100(?:644|755) blob [0-9a-f]{40}\t" + re.escape(relative), entry) is None:
        raise ValueError("reader/producer must be a tracked canonical regular file")
    payload = _git(root, "show", commit + ":" + relative)
    return entry[:6], payload, hashlib.sha256(payload).hexdigest()


def validate_reader_identity_shape(value):
    """Closed wire shape; replay must additionally recompute physical authority."""
    _closed(value, {"policy_id", "repository_root", "repository_clean", "commit", "tree",
                    "original_source", "changed_paths", "file_manifest"})
    if value["policy_id"] != POLICY_ID or value["repository_clean"] is not True:
        raise ValueError("unsupported reader policy or dirty identity")
    root = value["repository_root"]
    if type(root) is not str or not Path(root).is_absolute() or str(Path(root)) != root or ".." in Path(root).parts:
        raise ValueError("invalid reader repository root")
    for key in ("commit", "tree"):
        _hash(value[key], 40)
    _closed(value["original_source"], {"commit", "tree"})
    for item in value["original_source"].values():
        _hash(item, 40)
    for field, fields in (("changed_paths", {"relative_path", "original_mode", "original_sha256", "current_mode", "current_sha256"}),
                          ("file_manifest", {"relative_path", "mode", "sha256"})):
        items = value[field]
        if type(items) is not list or not items:
            raise ValueError("reader manifest is empty")
        paths = []
        for item in items:
            _closed(item, fields)
            path = item["relative_path"]
            if type(path) is not str or not path or Path(path).is_absolute() or any(p in {"", ".", ".."} for p in path.split("/")):
                raise ValueError("invalid reader manifest path")
            paths.append(path)
            if field == "changed_paths":
                if path not in ALLOWED_PATHS:
                    raise ValueError("unlisted tooling delta")
                if (item["original_mode"] is None) != (item["original_sha256"] is None):
                    raise ValueError("inconsistent original reader file")
                if item["original_mode"] is not None:
                    if item["original_mode"] not in {"100644", "100755"}:
                        raise ValueError("invalid original reader mode")
                    _hash(item["original_sha256"])
                if item["current_mode"] not in {"100644", "100755"}:
                    raise ValueError("invalid current reader mode")
                _hash(item["current_sha256"])
            else:
                if item["mode"] not in {"100644", "100755"}:
                    raise ValueError("invalid reader file mode")
                _hash(item["sha256"])
        if paths != sorted(set(paths)):
            raise ValueError("reader manifest paths are not sorted and unique")
    if BOOTSTRAP_PATH not in {p["relative_path"] for p in value["changed_paths"]}:
        raise ValueError("amended bootstrap reader must actually differ")
    if not {BOOTSTRAP_PATH, READER_PATH} <= {p["relative_path"] for p in value["file_manifest"]}:
        raise ValueError("active reader manifest is incomplete")


def observe_reader_identity(*, repository_root: Path, original_commit: str, original_tree: str,
                            original_manifest: list, producer_paths: tuple[str, ...]) -> dict:
    """Observe both Git identities and every unchanged producer; no record writes."""
    root = repository_root
    if not isinstance(root, Path) or not root.is_absolute() or root.resolve(strict=True) != root or not root.is_dir():
        raise ValueError("reader root must be canonical and existing")
    _hash(original_commit, 40)
    _hash(original_tree, 40)
    if _git(root, "rev-parse", "--show-toplevel").decode().strip() != str(root):
        raise ValueError("reader checkout is not its Git root")
    if _git(root, "status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"):
        raise ValueError("reader checkout must be clean")
    commit = _git(root, "rev-parse", "--verify", "HEAD^{commit}").decode().strip()
    tree = _git(root, "rev-parse", "--verify", "HEAD^{tree}").decode().strip()
    if _git(root, "rev-parse", "--verify", original_commit + "^{tree}").decode().strip() != original_tree:
        raise ValueError("original source tree differs")
    try:
        _git(root, "merge-base", "--is-ancestor", original_commit, commit)
    except subprocess.CalledProcessError as exc:
        raise ValueError("original source is not a reader ancestor") from exc
    changed = _git(root, "diff", "--no-renames", "--name-only", "-z", original_commit, commit).decode().split("\0")[:-1]
    if not changed or not set(changed) <= ALLOWED_PATHS:
        raise ValueError("empty or unlisted tooling delta; native source cannot be reused")
    if type(original_manifest) is not list or len(original_manifest) != len(producer_paths):
        raise ValueError("original producer manifest is incomplete")
    for relative, item in zip(producer_paths, original_manifest):
        _closed(item, {"relative_path", "sha256"})
        if item["relative_path"] != relative:
            raise ValueError("original producer manifest paths differ")
        old = _blob(root, original_commit, relative)
        if item["sha256"] != old[2]:
            raise ValueError("original producer commitment differs from original Git blob")
        current = _blob(root, commit, relative)
        if relative != BOOTSTRAP_PATH and old != current:
            raise ValueError("unchanged qualification producer differs")
    manifest = []
    for relative in sorted(set(producer_paths) | ALLOWED_PATHS):
        current = _blob(root, commit, relative, absent=relative not in producer_paths)
        if current is None:
            continue
        physical = read_descriptor_relative_bytes(root, relative, maximum_bytes=MAX_BYTES)[0]
        if physical != current[1] or format((root / relative).stat().st_mode & 0o777, "o") != ("755" if current[0] == "100755" else "644"):
            raise ValueError("physical reader file differs from current Git blob/mode")
        manifest.append({"relative_path": relative, "mode": current[0], "sha256": current[2]})
    differences = []
    for relative in sorted(changed):
        old = _blob(root, original_commit, relative, absent=True)
        current = _blob(root, commit, relative)
        differences.append({"relative_path": relative, "original_mode": old[0] if old else None,
            "original_sha256": old[2] if old else None, "current_mode": current[0], "current_sha256": current[2]})
    result = {"policy_id": POLICY_ID, "repository_root": str(root), "repository_clean": True,
        "commit": commit, "tree": tree, "original_source": {"commit": original_commit, "tree": original_tree},
        "changed_paths": differences, "file_manifest": manifest}
    validate_reader_identity_shape(result)
    if (_git(root, "rev-parse", "HEAD").decode().strip() != commit or
            _git(root, "status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none")):
        raise ValueError("reader checkout changed during observation")
    return result
