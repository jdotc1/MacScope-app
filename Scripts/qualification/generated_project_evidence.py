#!/usr/bin/env python3
"""Retain and verify the exact project consumed by one qualification run."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts.qualification.restore_build_source import (  # noqa: E402
    GENERATED_PROJECT_FILES,
    MAX_PROJECT_BYTES,
    BuildSourceRestoreError,
    _generated_project_identity,
)

DIRECTORY = "generated-project-evidence"
MANIFEST = "GeneratedProjectEvidence.json"
FIELDS = frozenset({"schema_version", "commit", "tree", "source_files_sha256",
                    "project_yml_sha256", "project_identity_sha256", "qualification_receipt_sha256"})


class GeneratedProjectEvidenceError(ValueError):
    pass


def _directory(path: Path) -> Path:
    if not path.is_absolute() or path.resolve(strict=True) != path or not stat.S_ISDIR(path.lstat().st_mode):
        raise GeneratedProjectEvidenceError("generated-project evidence directory is not canonical")
    return path


def _read(path: Path) -> bytes:
    before = path.lstat()
    if (path.resolve(strict=True) != path or not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1 or not 0 < before.st_size <= MAX_PROJECT_BYTES):
        raise GeneratedProjectEvidenceError("generated-project evidence file is unsafe or exceeds bounds")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        with os.fdopen(fd, "rb", closefd=False) as stream:
            payload = stream.read(MAX_PROJECT_BYTES + 1)
        after_fd = os.fstat(fd)
    finally:
        os.close(fd)
    after = path.lstat()
    keys = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    if len(payload) != before.st_size or any(
        getattr(before, key) != getattr(observed, key)
        for observed in (opened, after_fd, after) for key in keys
    ):
        raise GeneratedProjectEvidenceError("generated-project evidence changed while read")
    return payload


def _canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()


def _sync_directory(path: Path) -> None:
    _directory(path)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _hex(value: object, length: int) -> str:
    if not isinstance(value, str) or len(value) != length or any(c not in "0123456789abcdef" for c in value):
        raise GeneratedProjectEvidenceError("generated-project evidence identity is malformed")
    return value


def _qualification(run: Path) -> dict:
    _directory(run)
    payload = _read(run / "QUALIFICATION_INPUTS.json")
    value = json.loads(payload)
    if not isinstance(value, dict) or not isinstance(value.get("source_identity"), dict):
        raise GeneratedProjectEvidenceError("qualification inputs require object source authority")
    if payload not in (_canonical(value), _canonical(value) + b"\n"):
        raise GeneratedProjectEvidenceError("qualification inputs are not canonical")
    source = value.get("source_identity", {})
    if (value.get("schema_version") != 4 or value.get("mode") not in {"full-test", "release", "smoke", "focused-test"}
            or value.get("build_source_root") != str(run / "source")
            or source.get("repository_clean") is not True):
        raise GeneratedProjectEvidenceError("generated-project evidence has no exact qualification source")
    return source


def evidence_files(run: Path) -> tuple[Path, ...]:
    root = run / DIRECTORY
    return (run / "QUALIFICATION_INPUTS.json", run / "source/MacScope/project.yml", root / MANIFEST,
            *(root / "MacScope.xcodeproj" / name for name in sorted(GENERATED_PROJECT_FILES)))


def validate(run: Path, *, commit: str, tree: str, project_yml_sha256: str) -> Path:
    """Require run-owned actual JSON project evidence, never an operator project."""
    try:
        source = _qualification(run)
        root = _directory(run / DIRECTORY)
        if {p.name for p in root.iterdir()} != {MANIFEST, "MacScope.xcodeproj"}:
            raise GeneratedProjectEvidenceError("generated-project evidence has unexpected entries")
        payload = _read(root / MANIFEST)
        value = json.loads(payload)
        if (not isinstance(value, dict) or set(value) != FIELDS
                or type(value["schema_version"]) is not int or value["schema_version"] != 1
                or payload != _canonical(value)):
            raise GeneratedProjectEvidenceError("generated-project evidence schema is unsupported")
        for field in ("commit", "tree"):
            _hex(value[field], 40)
        for field in FIELDS - {"schema_version", "commit", "tree"}:
            _hex(value[field], 64)
        if (value["commit"] != commit or value["tree"] != tree
                or source.get("git_head_commit") != commit or source.get("git_head_tree") != tree
                or value["source_files_sha256"] != source.get("source_files_sha256")
                or value["qualification_receipt_sha256"] != hashlib.sha256(_read(run / "QUALIFICATION_INPUTS.json")).hexdigest()
                or value["project_yml_sha256"] != project_yml_sha256
                or hashlib.sha256(_read(run / "source/MacScope/project.yml")).hexdigest() != project_yml_sha256):
            raise GeneratedProjectEvidenceError("generated-project evidence source identity mismatch")
        project = _directory(root / "MacScope.xcodeproj")
        for path in evidence_files(run):
            _read(path)
        if _generated_project_identity(project, require_complete=True) != value["project_identity_sha256"]:
            raise GeneratedProjectEvidenceError("generated-project evidence bytes differ from frozen project")
        return project / "project.xcproj"
    except (OSError, ValueError, KeyError, TypeError, BuildSourceRestoreError) as error:
        if isinstance(error, GeneratedProjectEvidenceError):
            raise
        raise GeneratedProjectEvidenceError(str(error)) from error


def capture(run: Path, expected_project_identity: str) -> Path:
    """Called after Xcode and before restore; partial prior capture is a refusal."""
    _hex(expected_project_identity, 64)
    source = _qualification(run)
    project = _directory(run / "source/MacScope/MacScope.xcodeproj")
    if _generated_project_identity(project, require_complete=True) != expected_project_identity:
        raise GeneratedProjectEvidenceError("generated project differs from its pre-Xcode identity")
    spec = _read(run / "source/MacScope/project.yml")
    document = {
        "schema_version": 1,
        "commit": _hex(source.get("git_head_commit"), 40),
        "tree": _hex(source.get("git_head_tree"), 40),
        "source_files_sha256": _hex(source.get("source_files_sha256"), 64),
        "qualification_receipt_sha256": hashlib.sha256(_read(run / "QUALIFICATION_INPUTS.json")).hexdigest(),
        "project_yml_sha256": hashlib.sha256(spec).hexdigest(),
        "project_identity_sha256": expected_project_identity,
    }
    evidence = run / DIRECTORY
    if os.path.lexists(evidence):
        result = validate(run, commit=document["commit"], tree=document["tree"], project_yml_sha256=document["project_yml_sha256"])
        if _read(evidence / MANIFEST) != _canonical(document):
            raise GeneratedProjectEvidenceError("existing evidence differs from current frozen project")
        return result
    evidence.mkdir(mode=0o700)
    retained = evidence / "MacScope.xcodeproj"
    retained.mkdir(mode=0o700)
    for name in sorted(GENERATED_PROJECT_FILES):
        destination = retained / name
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        _directory(destination.parent)
        payload = _read(project / name)
        fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        _sync_directory(destination.parent)
    if (_generated_project_identity(project, require_complete=True) != expected_project_identity
            or _generated_project_identity(retained, require_complete=True) != expected_project_identity
            or _read(run / "source/MacScope/project.yml") != spec
            or _qualification(run) != source):
        raise GeneratedProjectEvidenceError("generated project or source changed during capture")
    fd = os.open(evidence / MANIFEST, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(_canonical(document))
        stream.flush()
        os.fsync(stream.fileno())
    for directory in sorted((path for path in retained.rglob("*") if path.is_dir()), key=lambda path: len(path.parts), reverse=True):
        _sync_directory(directory)
    _sync_directory(retained)
    _sync_directory(evidence)
    _sync_directory(run)
    return validate(run, commit=document["commit"], tree=document["tree"], project_yml_sha256=document["project_yml_sha256"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-root", type=Path, required=True)
    parser.add_argument("--expected-project-identity", required=True)
    args = parser.parse_args()
    try:
        capture(args.run_root, args.expected_project_identity)
    except (OSError, ValueError, BuildSourceRestoreError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
