#!/usr/bin/env python3
"""Validate two fresh-process Reconstruction artifact sets byte-for-byte."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import stat
import sys
from pathlib import Path
from xml.parsers.expat import ExpatError


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes  # noqa: E402
from Scripts.reconstruction_gate_f.schema import (  # noqa: E402
    candidate_identity_sha256,
    parse_candidate_identity,
)


COMMAND_ID = "reconstruction.deterministic-evidence"
ARTIFACTS = (
    ("corpus", "corpus-manifest.json"),
    ("evidence-frontier", "evidence-frontier.json"),
    ("retrieval-packet", "retrieval-packet.json"),
    ("receipt", "tool-receipt.json"),
    ("checkpoint", "checkpoint.json"),
)
ARTIFACT_IDS = tuple(item[0] for item in ARTIFACTS)
ARTIFACT_PATHS = tuple(item[1] for item in ARTIFACTS)
MAX_ARTIFACT_BYTES = 64 * 1024 * 1024
OUTPUT_ROOT_ENVIRONMENT = "MACSCOPE_DETERMINISTIC_EVIDENCE_OUTPUT_ROOT"


class DeterministicEvidenceError(ValueError):
    pass


def _canonical_file(path: Path, *, field: str) -> Path:
    if not path.is_absolute():
        raise DeterministicEvidenceError(f"{field} must be absolute")
    try:
        parent = path.parent.resolve(strict=True)
        metadata = path.lstat()
    except OSError as error:
        raise DeterministicEvidenceError(f"{field} is unavailable: {error}") from error
    canonical = parent / path.name
    if canonical != path or not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise DeterministicEvidenceError(f"{field} must be a canonical non-symlink regular file")
    if metadata.st_nlink != 1:
        raise DeterministicEvidenceError(f"{field} must not be hard-linked")
    if metadata.st_size > MAX_ARTIFACT_BYTES:
        raise DeterministicEvidenceError(f"{field} exceeds the artifact byte bound")
    return canonical


def _canonical_directory(path: Path, *, field: str) -> Path:
    if not path.is_absolute():
        raise DeterministicEvidenceError(f"{field} must be absolute")
    try:
        canonical = path.resolve(strict=True)
        metadata = path.lstat()
    except OSError as error:
        raise DeterministicEvidenceError(f"{field} is unavailable: {error}") from error
    if canonical != path or not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise DeterministicEvidenceError(f"{field} must be a canonical non-symlink directory")
    return canonical


def _candidate_digest(path: Path) -> str:
    canonical = _canonical_file(path, field="candidate identity")
    try:
        value = json.loads(canonical.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as error:
        raise DeterministicEvidenceError(f"candidate identity cannot be decoded: {error}") from error
    candidate, issues = parse_candidate_identity(value)
    if candidate is None or issues:
        detail = "; ".join(issue.render() for issue in issues)
        raise DeterministicEvidenceError(f"candidate identity is invalid: {detail}")
    return candidate_identity_sha256(candidate)


def _artifact_files(root: Path, *, field: str) -> dict[str, Path]:
    canonical = _canonical_directory(root, field=field)
    try:
        actual = {item.name for item in canonical.iterdir()}
    except OSError as error:
        raise DeterministicEvidenceError(f"{field} cannot be enumerated: {error}") from error
    expected = set(ARTIFACT_PATHS)
    if actual != expected:
        raise DeterministicEvidenceError(
            f"artifact-set mismatch for {field}: expected {sorted(expected)}, observed {sorted(actual)}"
        )
    return {
        relative_path: _canonical_file(canonical / relative_path, field=f"{field}/{relative_path}")
        for relative_path in ARTIFACT_PATHS
    }


def compare_artifact_roots(
    *,
    candidate_identity_path: Path,
    first_root: Path,
    second_root: Path,
) -> dict[str, object]:
    candidate_digest = _candidate_digest(candidate_identity_path)
    first = _artifact_files(first_root, field="first artifact root")
    second = _artifact_files(second_root, field="second artifact root")
    records: list[dict[str, object]] = []
    for artifact_id, relative_path in ARTIFACTS:
        try:
            first_bytes = first[relative_path].read_bytes()
            second_bytes = second[relative_path].read_bytes()
        except OSError as error:
            raise DeterministicEvidenceError(
                f"artifact {artifact_id} cannot be read safely: {error}"
            ) from error
        if first_bytes != second_bytes:
            raise DeterministicEvidenceError(f"byte-mismatch for artifact {artifact_id}")
        records.append(
            {
                "artifact_id": artifact_id,
                "byte_count": len(first_bytes),
                "relative_path": relative_path,
                "sha256": hashlib.sha256(first_bytes).hexdigest(),
            }
        )
    return {
        "artifacts": records,
        "candidate_identity_sha256": candidate_digest,
        "command_id": COMMAND_ID,
        "fresh_process_count": 2,
        "schema_version": 1,
    }


def write_create_only(path: Path, value: dict[str, object]) -> None:
    _write_bytes_create_only(path, canonical_bytes(value))


def _write_bytes_create_only(path: Path, payload: bytes) -> None:
    if not path.is_absolute() or path.exists() or path.is_symlink():
        raise DeterministicEvidenceError("output must be an absent absolute path")
    try:
        parent = path.parent.resolve(strict=True)
        metadata = path.parent.lstat()
    except OSError as error:
        raise DeterministicEvidenceError(f"output parent is unavailable: {error}") from error
    if parent != path.parent or not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise DeterministicEvidenceError("output parent must be a canonical non-symlink directory")
    descriptor = os.open(
        parent / path.name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        os.close(descriptor)


def _freeze_test_root(value: object, test_root: Path) -> object:
    if isinstance(value, str):
        return value.replace("__TESTROOT__", str(test_root))
    if isinstance(value, list):
        return [_freeze_test_root(item, test_root) for item in value]
    if isinstance(value, dict):
        return {
            key: _freeze_test_root(item, test_root)
            for key, item in value.items()
        }
    return value


def write_run_xctestrun(
    *,
    source_path: Path,
    output_path: Path,
    artifact_root: Path,
) -> None:
    """Derive one execution-only xctestrun with a single qualified output root."""

    source = _canonical_file(source_path, field="source xctestrun")
    canonical_artifact_root = _canonical_directory(
        artifact_root,
        field="artifact root",
    )
    try:
        with source.open("rb") as stream:
            document = plistlib.load(stream)
    except (
        OSError,
        plistlib.InvalidFileException,
        ExpatError,
        TypeError,
        ValueError,
    ) as error:
        raise DeterministicEvidenceError(
            f"source xctestrun cannot be decoded safely: {error}"
        ) from error
    if not isinstance(document, dict):
        raise DeterministicEvidenceError("source xctestrun root must be a dictionary")
    document = _freeze_test_root(document, source.parent)
    if not isinstance(document, dict):  # defensive: the root type was already proved
        raise DeterministicEvidenceError("derived xctestrun root must remain a dictionary")
    metadata = document.get("__xctestrun_metadata__")
    if not isinstance(metadata, dict) or metadata.get("ContainerInfo", {}).get(
        "SchemeName"
    ) != "MacScopeApp":
        raise DeterministicEvidenceError("source xctestrun is not for the MacScopeApp scheme")
    suites = [
        value
        for key, value in document.items()
        if key != "__xctestrun_metadata__"
        and isinstance(value, dict)
        and value.get("BlueprintName") == "CoreTests"
    ]
    if len(suites) != 1:
        raise DeterministicEvidenceError(
            f"source xctestrun must carry exactly one CoreTests configuration, found {len(suites)}"
        )
    suite = suites[0]
    environment = suite.get("EnvironmentVariables")
    testing_environment = suite.get("TestingEnvironmentVariables")
    if not isinstance(environment, dict) or not isinstance(testing_environment, dict):
        raise DeterministicEvidenceError(
            "CoreTests xctestrun environments must both be dictionaries"
        )
    if OUTPUT_ROOT_ENVIRONMENT in environment or OUTPUT_ROOT_ENVIRONMENT in testing_environment:
        raise DeterministicEvidenceError(
            f"source xctestrun already carries {OUTPUT_ROOT_ENVIRONMENT}"
        )
    if any(
        not isinstance(key, str) or not isinstance(value, str)
        for mapping in (environment, testing_environment)
        for key, value in mapping.items()
    ):
        raise DeterministicEvidenceError(
            "CoreTests xctestrun environments must contain only string pairs"
        )
    suite["EnvironmentVariables"] = {
        **environment,
        OUTPUT_ROOT_ENVIRONMENT: str(canonical_artifact_root),
    }
    try:
        payload = plistlib.dumps(document, fmt=plistlib.FMT_BINARY, sort_keys=True)
    except (TypeError, ValueError) as error:
        raise DeterministicEvidenceError(
            f"derived xctestrun cannot be encoded safely: {error}"
        ) from error
    _write_bytes_create_only(output_path, payload)


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="operation", required=True)
    compare = subparsers.add_parser("compare")
    compare.add_argument("--candidate-identity", type=Path, required=True)
    compare.add_argument("--first-root", type=Path, required=True)
    compare.add_argument("--second-root", type=Path, required=True)
    compare.add_argument("--output", type=Path, required=True)
    prepare = subparsers.add_parser("prepare-xctestrun")
    prepare.add_argument("--source", type=Path, required=True)
    prepare.add_argument("--output", type=Path, required=True)
    prepare.add_argument("--artifact-root", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        if arguments.operation == "prepare-xctestrun":
            write_run_xctestrun(
                source_path=arguments.source,
                output_path=arguments.output,
                artifact_root=arguments.artifact_root,
            )
            print(f"MACSCOPE_DETERMINISTIC_EVIDENCE_XCTESTRUN={arguments.output}")
            return 0
        value = compare_artifact_roots(
            candidate_identity_path=arguments.candidate_identity,
            first_root=arguments.first_root,
            second_root=arguments.second_root,
        )
        write_create_only(arguments.output, value)
    except (OSError, DeterministicEvidenceError) as error:
        print(f"ERROR: deterministic evidence comparison failed: {error}", file=sys.stderr)
        return 1
    print(f"MACSCOPE_DETERMINISTIC_EVIDENCE_COMPARISON={arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
