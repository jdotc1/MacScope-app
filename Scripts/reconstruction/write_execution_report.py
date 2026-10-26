#!/usr/bin/env python3
"""Create one closed, create-only Gate F execution timing/result artifact."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
import stat
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes  # noqa: E402
from Scripts.reconstruction_gate_f.receipt_validator import (  # noqa: E402
    QualificationRunAuthority,
    qualification_run_mapping,
)
from Scripts.reconstruction_gate_f.schema import STABLE_ID_RE, is_sha256  # noqa: E402


class ExecutionReportError(ValueError):
    pass


NATIVE_LIVE_REPORT_NAME = "NativeDecompilerLiveXPC.execution-report.json"
NATIVE_LIVE_TARGET = "CoreTests"
NATIVE_LIVE_SUITE = "NativeDecompilerLiveXPCTests"
NATIVE_LIVE_METHODS = frozenset(
    {
        "testSignedProviderPreservesAuthoredSnapshotCalleeAndReadonlyDataContext",
        "testSignedProviderTokenAndSourceScalarsProjectForCompleteAndTruncatedDocuments",
        "testSignedServiceHonorsSupervisionAndRelaunchContract",
        "testSignedServiceReturnsMalformedFailureAndHonorsCooperativeCancellation",
    }
)
MAXIMUM_EXECUTION_REPORT_BYTES = 64 * 1024
MAXIMUM_PREPARATION_RECEIPT_BYTES = 2 * 1024 * 1024
MAXIMUM_XCTESTRUN_BYTES = 16 * 1024 * 1024
MAXIMUM_CANDIDATE_IDENTITY_BYTES = 16 * 1024 * 1024
MAXIMUM_TEST_RESULTS_BYTES = 4 * 1024 * 1024
MAXIMUM_NATIVE_EXECUTABLE_BYTES = 1024 * 1024 * 1024


@dataclass(frozen=True)
class StableRegularFile:
    path: Path
    metadata: tuple[int, int, int, int, int, int, int]
    sha256: str
    payload: bytes | None


@dataclass(frozen=True)
class PublishedFile:
    path: Path
    device: int
    inode: int
    size: int
    sha256: str


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--started-at-unix-ms", type=int, required=True)
    parser.add_argument("--ended-at-unix-ms", type=int, required=True)
    parser.add_argument("--result", choices=("passed", "failed", "unavailable"), required=True)
    parser.add_argument("--exit-code", type=int)
    parser.add_argument("--qualification-run-id", required=True)
    parser.add_argument("--qualification-run-nonce", required=True)
    parser.add_argument("--predecessor-observations-sha256", required=True)
    parser.add_argument("--native-preparation-receipt", type=Path)
    parser.add_argument("--native-xctestrun", type=Path)
    parser.add_argument("--native-candidate-app", type=Path)
    parser.add_argument("--native-candidate-identity", type=Path)
    parser.add_argument("--native-result-bundle", type=Path)
    parser.add_argument("--native-test-results", type=Path)
    parser.add_argument("--native-service-artifact", type=Path)
    parser.add_argument("--native-test-selector")
    return parser.parse_args(argv)


def qualification_run_authority(arguments: argparse.Namespace) -> QualificationRunAuthority:
    run_id = arguments.qualification_run_id
    nonce = arguments.qualification_run_nonce
    if not isinstance(run_id, str) or STABLE_ID_RE.fullmatch(run_id) is None:
        raise ExecutionReportError(
            "qualification run ID must be an coordinator-issued canonical stable ID"
        )
    if not is_sha256(nonce):
        raise ExecutionReportError(
            "qualification run nonce must be an coordinator-issued lowercase SHA-256"
        )
    return QualificationRunAuthority(run_id=run_id, nonce=nonce)


def document(
    arguments: argparse.Namespace,
    *,
    qualification_run: QualificationRunAuthority,
    predecessor_observations_sha256: str,
) -> dict[str, object]:
    started = arguments.started_at_unix_ms
    ended = arguments.ended_at_unix_ms
    result = arguments.result
    exit_code = arguments.exit_code
    if started < 0 or ended < started:
        raise ExecutionReportError("execution timestamps are invalid or reversed")
    if result == "unavailable":
        if exit_code is not None:
            raise ExecutionReportError("unavailable execution requires no exit code")
    elif exit_code is None:
        raise ExecutionReportError("executed result requires an exit code")
    elif not 0 <= exit_code <= 255:
        raise ExecutionReportError("executed exit code must be in the shell status range")
    elif (result == "passed") != (exit_code == 0):
        raise ExecutionReportError("result and exit code disagree")
    if not isinstance(qualification_run, QualificationRunAuthority):
        raise ExecutionReportError(
            "qualification run authority must be supplied by the coordinator"
        )
    if not is_sha256(predecessor_observations_sha256):
        raise ExecutionReportError(
            "predecessor observations digest must be a lowercase SHA-256"
        )
    return {
        "ended_at_unix_ms": ended,
        "exit_code": exit_code,
        "predecessor_observations_sha256": predecessor_observations_sha256,
        "qualification_run": qualification_run_mapping(qualification_run),
        "result": result,
        "schema_version": 2,
        "started_at_unix_ms": started,
        "stress": None,
    }


def _stable_metadata(metadata: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IMODE(metadata.st_mode),
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _canonical_parent(path: Path, *, label: str) -> tuple[Path, os.stat_result]:
    if not path.is_absolute() or not path.name or any(
        character in str(path) for character in ("\x00", "\n", "\r")
    ):
        raise ExecutionReportError(f"{label} must be an absolute canonical path")
    try:
        parent = path.parent.resolve(strict=True)
        metadata = parent.lstat()
    except OSError as error:
        raise ExecutionReportError(f"{label} parent is unavailable: {error}") from error
    canonical_path = parent / path.name
    allowed_alias = False
    if sys.platform == "darwin":
        raw = str(path)
        canonical_text = str(canonical_path)
        for alias in ("/etc", "/tmp", "/var"):
            if raw == alias or raw.startswith(f"{alias}/"):
                allowed_alias = canonical_text == f"/private{raw}"
                break
    if path != canonical_path and not allowed_alias:
        raise ExecutionReportError(f"{label} must be canonical and traverse no symbolic links")
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise ExecutionReportError(f"{label} parent must be a non-symlink directory")
    return parent, metadata


def _open_parent(path: Path, *, label: str) -> tuple[int, Path]:
    parent, expected = _canonical_parent(path, label=label)
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        descriptor = os.open(parent, flags)
    except OSError as error:
        raise ExecutionReportError(f"{label} parent cannot be opened safely: {error}") from error
    observed = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(observed.st_mode)
        or (observed.st_dev, observed.st_ino) != (expected.st_dev, expected.st_ino)
    ):
        os.close(descriptor)
        raise ExecutionReportError(f"{label} parent changed before use")
    return descriptor, parent


def read_stable_regular(
    path: Path,
    *,
    label: str,
    maximum_bytes: int,
    retain_payload: bool,
) -> StableRegularFile:
    parent_descriptor, parent = _open_parent(path, label=label)
    flags = (
        os.O_RDONLY
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    descriptor = -1
    try:
        descriptor = os.open(path.name, flags, dir_fd=parent_descriptor)
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size < 0
            or before.st_size > maximum_bytes
        ):
            raise ExecutionReportError(
                f"{label} must be a bounded, singly linked ordinary file"
            )
        digest = hashlib.sha256()
        chunks: list[bytes] | None = [] if retain_payload else None
        total = 0
        while True:
            block = os.read(descriptor, min(1024 * 1024, maximum_bytes + 1 - total))
            if not block:
                break
            total += len(block)
            if total > maximum_bytes:
                raise ExecutionReportError(f"{label} exceeds its bounded size contract")
            digest.update(block)
            if chunks is not None:
                chunks.append(block)
        after = os.fstat(descriptor)
        if _stable_metadata(before) != _stable_metadata(after) or total != before.st_size:
            raise ExecutionReportError(f"{label} changed while it was read")
        parent_after = os.fstat(parent_descriptor)
        if (parent_after.st_dev, parent_after.st_ino) != (
            os.stat(parent).st_dev,
            os.stat(parent).st_ino,
        ):
            raise ExecutionReportError(f"{label} parent changed while it was read")
        return StableRegularFile(
            path=path,
            metadata=_stable_metadata(before),
            sha256=digest.hexdigest(),
            payload=b"".join(chunks) if chunks is not None else None,
        )
    except OSError as error:
        raise ExecutionReportError(f"{label} cannot be read safely: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent_descriptor)


def require_unchanged_regular(snapshot: StableRegularFile, *, label: str) -> None:
    observed = read_stable_regular(
        snapshot.path,
        label=label,
        maximum_bytes=max(snapshot.metadata[4], 1),
        retain_payload=False,
    )
    if observed.metadata != snapshot.metadata or observed.sha256 != snapshot.sha256:
        raise ExecutionReportError(f"{label} changed before report publication completed")


def _canonical_directory(path: Path, *, label: str) -> Path:
    if not path.is_absolute() or any(
        character in str(path) for character in ("\x00", "\n", "\r")
    ):
        raise ExecutionReportError(f"{label} must be an absolute canonical directory")
    try:
        metadata = path.lstat()
        canonical = path.resolve(strict=True)
        final_metadata = canonical.lstat()
    except OSError as error:
        raise ExecutionReportError(f"{label} is unavailable: {error}") from error
    if (
        canonical != path
        or not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISDIR(final_metadata.st_mode)
        or stat.S_ISLNK(final_metadata.st_mode)
    ):
        raise ExecutionReportError(f"{label} must traverse no symbolic links")
    return canonical


def _decode_json(payload: bytes, *, label: str) -> Any:
    def closed_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ExecutionReportError(f"{label} contains duplicate JSON key {key!r}")
            result[key] = value
        return result

    try:
        return json.loads(payload.decode("utf-8"), object_pairs_hook=closed_object)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ExecutionReportError(f"{label} is invalid JSON: {error}") from error


def validate_exact_native_test_results(document: Any, selector: str) -> None:
    parts = selector.split("/")
    if (
        len(parts) != 3
        or parts[0] != NATIVE_LIVE_TARGET
        or parts[1] != NATIVE_LIVE_SUITE
        or parts[2] not in NATIVE_LIVE_METHODS
    ):
        raise ExecutionReportError("native live selector is not a governed exact test vector")
    target, suite, method = parts
    matches: list[dict[str, Any]] = []

    def visit(node: Any, ancestors: list[str]) -> None:
        if not isinstance(node, dict):
            raise ExecutionReportError("native test-results JSON contains a non-object test node")
        node_type = node.get("nodeType")
        name = node.get("name")
        identifier = node.get("nodeIdentifier")
        if not isinstance(node_type, str) or not isinstance(name, str):
            raise ExecutionReportError("native test-results JSON contains an unidentifiable node")
        texts = [name]
        if isinstance(identifier, str):
            texts.append(identifier)
        lineage = ancestors + texts
        joined = "/".join(lineage)
        method_names = {method, f"{method}()", f"{suite}.{method}", f"{suite}/{method}"}
        if (
            node_type == "Test Case"
            and (name in method_names or selector in joined)
            and suite in joined
            and target in joined
        ):
            matches.append(node)
        children = node.get("children", [])
        if not isinstance(children, list):
            raise ExecutionReportError("native test-results JSON has malformed children")
        for child in children:
            visit(child, lineage)

    roots = document.get("testNodes") if isinstance(document, dict) else None
    if not isinstance(roots, list):
        raise ExecutionReportError("native test-results JSON lacks a testNodes array")
    for root in roots:
        visit(root, [])
    if len(matches) != 1:
        raise ExecutionReportError(
            f"expected exactly one recorded exact native test case, found {len(matches)}"
        )
    results: list[str] = []
    skip_messages: list[str] = []

    def collect(node: dict[str, Any]) -> None:
        node_type = node.get("nodeType")
        result = node.get("result")
        if node_type in ("Test Case", "Test Case Run") and isinstance(result, str):
            results.append(result)
        if node_type == "Skip Message":
            skip_messages.append(str(node.get("name", "skip")))
        for child in node.get("children", []):
            collect(child)

    collect(matches[0])
    if skip_messages:
        raise ExecutionReportError("the exact native test recorded a skip message")
    if not results or any(result != "Passed" for result in results):
        raise ExecutionReportError(
            f"the exact native test was not exclusively passed: {results}"
        )


def _native_argument_values(arguments: argparse.Namespace) -> tuple[Any, ...]:
    return (
        arguments.native_preparation_receipt,
        arguments.native_xctestrun,
        arguments.native_candidate_app,
        arguments.native_candidate_identity,
        arguments.native_result_bundle,
        arguments.native_test_results,
        arguments.native_service_artifact,
        arguments.native_test_selector,
    )


def validate_native_live_success(arguments: argparse.Namespace) -> tuple[StableRegularFile, ...]:
    values = _native_argument_values(arguments)
    if any(value is None for value in values):
        raise ExecutionReportError(
            "passing native live-XPC report requires the complete sealed evidence set"
        )
    assert arguments.native_preparation_receipt is not None
    assert arguments.native_xctestrun is not None
    assert arguments.native_candidate_app is not None
    assert arguments.native_candidate_identity is not None
    assert arguments.native_result_bundle is not None
    assert arguments.native_test_results is not None
    assert arguments.native_service_artifact is not None
    assert arguments.native_test_selector is not None

    candidate_app = _canonical_directory(
        arguments.native_candidate_app, label="native candidate app"
    )
    result_bundle = _canonical_directory(
        arguments.native_result_bundle, label="native result bundle"
    )
    if result_bundle.suffix != ".xcresult":
        raise ExecutionReportError("native result bundle must use the .xcresult suffix")

    snapshots = (
        read_stable_regular(
            arguments.native_preparation_receipt,
            label="native preparation receipt",
            maximum_bytes=MAXIMUM_PREPARATION_RECEIPT_BYTES,
            retain_payload=False,
        ),
        read_stable_regular(
            arguments.native_xctestrun,
            label="native xctestrun",
            maximum_bytes=MAXIMUM_XCTESTRUN_BYTES,
            retain_payload=False,
        ),
        read_stable_regular(
            arguments.native_candidate_identity,
            label="native candidate identity",
            maximum_bytes=MAXIMUM_CANDIDATE_IDENTITY_BYTES,
            retain_payload=False,
        ),
        read_stable_regular(
            arguments.native_test_results,
            label="native test results",
            maximum_bytes=MAXIMUM_TEST_RESULTS_BYTES,
            retain_payload=True,
        ),
        read_stable_regular(
            arguments.native_service_artifact,
            label="native service artifact",
            maximum_bytes=MAXIMUM_NATIVE_EXECUTABLE_BYTES,
            retain_payload=False,
        ),
    )
    test_results = snapshots[3]
    assert test_results.payload is not None
    validate_exact_native_test_results(
        _decode_json(test_results.payload, label="native test-results JSON"),
        arguments.native_test_selector,
    )
    if arguments.native_service_artifact.name != "NativeDecompilerXPCService":
        raise ExecutionReportError("native service artifact has the wrong executable name")

    try:
        from Scripts.reconstruction import native_live_preparation_receipt as preparation
        from Scripts.reconstruction_gate_f.materialize_candidate_identity import (
            CandidateMaterializationError,
            capture_bundle_snapshot,
            require_unchanged_bundle_snapshot,
        )

        receipt = preparation.load_receipt(arguments.native_preparation_receipt)
        if receipt.get("schema_version") != preparation.SCHEMA_VERSION:
            raise ExecutionReportError("native preparation receipt must use the current schema")
        preparation.validate_prepared(
            receipt,
            arguments.native_xctestrun,
            candidate_app,
            arguments.native_candidate_identity,
        )
        if snapshots[4].sha256 != receipt["artifacts"]["native_decompiler"]["sha256"]:
            raise ExecutionReportError(
                "published native service executable differs from the sealed candidate"
            )
        result_snapshot = capture_bundle_snapshot(result_bundle)
        require_unchanged_bundle_snapshot(
            result_snapshot, phase="native live result binding"
        )
    except CandidateMaterializationError as error:
        raise ExecutionReportError(f"native result bundle is unsafe: {error}") from error
    except preparation.PreparationReceiptError as error:
        raise ExecutionReportError(f"native preparation authority is invalid: {error}") from error
    return snapshots


def _temporary_name(output_name: str) -> str:
    return f".{output_name}.tmp.{os.getpid()}.{os.urandom(16).hex()}"


def write_create_only(path: Path, value: dict[str, object]) -> PublishedFile:
    payload = canonical_bytes(value)
    if len(payload) <= 0 or len(payload) > MAXIMUM_EXECUTION_REPORT_BYTES:
        raise ExecutionReportError("execution report exceeds its bounded size contract")
    parent_descriptor, _ = _open_parent(path, label="output")
    temporary_name = _temporary_name(path.name)
    temporary_descriptor = -1
    linked = False
    succeeded = False
    try:
        try:
            os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise ExecutionReportError("output must be an absent absolute path")
        temporary_descriptor = os.open(
            temporary_name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            0o600,
            dir_fd=parent_descriptor,
        )
        offset = 0
        while offset < len(payload):
            written = os.write(temporary_descriptor, payload[offset:])
            if written <= 0:
                raise ExecutionReportError("execution report write made no progress")
            offset += written
        os.fsync(temporary_descriptor)
        temporary_metadata = os.fstat(temporary_descriptor)
        if (
            not stat.S_ISREG(temporary_metadata.st_mode)
            or temporary_metadata.st_nlink != 1
            or temporary_metadata.st_size != len(payload)
        ):
            raise ExecutionReportError("execution report temporary identity is invalid")
        try:
            os.link(
                temporary_name,
                path.name,
                src_dir_fd=parent_descriptor,
                dst_dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileExistsError as error:
            raise ExecutionReportError("output must be an absent absolute path") from error
        linked = True
        destination_metadata = os.stat(
            path.name, dir_fd=parent_descriptor, follow_symlinks=False
        )
        if (
            not stat.S_ISREG(destination_metadata.st_mode)
            or (destination_metadata.st_dev, destination_metadata.st_ino)
            != (temporary_metadata.st_dev, temporary_metadata.st_ino)
            or destination_metadata.st_nlink != 2
        ):
            raise ExecutionReportError("execution report publication identity is invalid")
        os.unlink(temporary_name, dir_fd=parent_descriptor)
        temporary_name = ""
        final_metadata = os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (
            final_metadata.st_nlink != 1
            or final_metadata.st_size != len(payload)
            or stat.S_IMODE(final_metadata.st_mode) != 0o600
        ):
            raise ExecutionReportError("execution report final identity is invalid")
        os.fsync(parent_descriptor)
        final_snapshot = read_stable_regular(
            path,
            label="published execution report",
            maximum_bytes=MAXIMUM_EXECUTION_REPORT_BYTES,
            retain_payload=True,
        )
        if final_snapshot.payload != payload:
            raise ExecutionReportError("published execution report bytes are not canonical")
        publication = PublishedFile(
            path=path,
            device=final_metadata.st_dev,
            inode=final_metadata.st_ino,
            size=final_metadata.st_size,
            sha256=final_snapshot.sha256,
        )
        succeeded = True
        return publication
    except OSError as error:
        raise ExecutionReportError(f"execution report publication failed: {error}") from error
    finally:
        if temporary_descriptor >= 0:
            os.close(temporary_descriptor)
        if temporary_name:
            try:
                os.unlink(temporary_name, dir_fd=parent_descriptor)
            except FileNotFoundError:
                pass
        if linked and not succeeded:
            try:
                metadata = os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                if (
                    metadata.st_dev,
                    metadata.st_ino,
                ) == (temporary_metadata.st_dev, temporary_metadata.st_ino):
                    os.unlink(path.name, dir_fd=parent_descriptor)
        os.close(parent_descriptor)


def remove_published_file(publication: PublishedFile) -> None:
    parent_descriptor, _ = _open_parent(publication.path, label="published output")
    try:
        metadata = os.stat(
            publication.path.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if (metadata.st_dev, metadata.st_ino) != (
            publication.device,
            publication.inode,
        ):
            raise ExecutionReportError(
                "failed native report was substituted and cannot be removed safely"
            )
        os.unlink(publication.path.name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    except OSError as error:
        raise ExecutionReportError(f"failed native report cannot be removed safely: {error}") from error
    finally:
        os.close(parent_descriptor)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    publication: PublishedFile | None = None
    try:
        authority = qualification_run_authority(arguments)
        native_values = _native_argument_values(arguments)
        if arguments.output.name == NATIVE_LIVE_REPORT_NAME:
            if arguments.result == "passed":
                native_snapshots = validate_native_live_success(arguments)
            elif any(value is not None for value in native_values):
                raise ExecutionReportError(
                    "failed native live report must not carry a partial passing evidence set"
                )
            else:
                native_snapshots = ()
        elif any(value is not None for value in native_values):
            raise ExecutionReportError(
                "native live evidence may only publish the governed report filename"
            )
        else:
            native_snapshots = ()
        publication = write_create_only(
            arguments.output,
            document(
                arguments,
                qualification_run=authority,
                predecessor_observations_sha256=(
                    arguments.predecessor_observations_sha256
                ),
            ),
        )
        if native_snapshots:
            for snapshot in native_snapshots:
                require_unchanged_regular(snapshot, label=f"native evidence {snapshot.path.name}")
            validate_native_live_success(arguments)
    except (OSError, ExecutionReportError) as error:
        if publication is not None:
            try:
                remove_published_file(publication)
            except ExecutionReportError as cleanup_error:
                print(
                    f"ERROR: execution report cleanup failed: {cleanup_error}",
                    file=sys.stderr,
                )
        print(f"ERROR: execution report emission failed: {error}", file=sys.stderr)
        return 1
    print(f"MACSCOPE_EXECUTION_REPORT={arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
