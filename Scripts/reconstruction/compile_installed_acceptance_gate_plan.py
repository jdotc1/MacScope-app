#!/usr/bin/python3 -B
"""Compile one identity-bound installed-acceptance command plan.

The compiler is deliberately build-free and execution-free.  It accepts only
already-sealed qualification/candidate authority plus one live schema-3
installer pending state, then publishes a closed canonical plan for the
transaction driver.  No command is represented as shell text and no result is
inferred by this compiler.
"""

from __future__ import annotations

import sys

# This executable imports repository modules solely to validate their frozen
# parsers and sealed authority.  Keep that read-only operation bytecode-free
# even when an embedding host ignores the shebang's ``-B`` flag.
sys.dont_write_bytecode = True

import argparse
import hashlib
import os
from pathlib import Path
import stat
from dataclasses import dataclass
from typing import Any, NoReturn


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from Scripts.phase2 import run_installed_shell_smoke as renderer_runner  # noqa: E402
from Scripts import ws24_emit_installed_qualification_report as ws24_reporter  # noqa: E402
from Scripts.reconstruction import emit_installed_live_evidence as live_evidence  # noqa: E402
from Scripts.reconstruction import install_release_to_applications as installer  # noqa: E402
from Scripts.reconstruction import native_live_preparation_receipt as native_receipt  # noqa: E402
from Scripts.reconstruction.qualification_xctestrun import resolve_xctestrun  # noqa: E402
from Scripts.reconstruction.validate_qualification_product_identity import (  # noqa: E402
    QUALIFICATION_V4_FIELDS,
    SOURCE_EXPORT_V2_FIELDS,
)
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    CanonicalJSONError,
    canonical_bytes,
    decode_canonical_bytes,
)
from Scripts.reconstruction_gate_f.schema import (  # noqa: E402
    GIT_OBJECT_RE,
    SHA256_RE,
    STABLE_ID_RE,
    candidate_identity_sha256,
    parse_candidate_identity,
)


PLAN_SCHEMA_VERSION = 1
PLAN_KIND = "macscope-installed-acceptance-gate-plan"
PLAN_FILENAME = "InstalledAcceptanceGate.plan.json"
MAXIMUM_PLAN_BYTES = 1024 * 1024
MAXIMUM_INPUT_BYTES = 4 * 1024 * 1024
MAXIMUM_XCTESTRUN_BYTES = 16 * 1024 * 1024
MAXIMUM_ARGV_TOKENS = 64
MAXIMUM_ARGV_BYTES = 32 * 1024
MAXIMUM_TOKEN_BYTES = 4 * 1024

CANDIDATE_IDENTITY_NAME = "candidate.json"
NATIVE_PREPARATION_RECEIPT_NAME = "NativeLivePreparation.receipt.json"
INSTALLED_UI_PREPARATION_RECEIPT_NAME = "InstalledUIPreparation.receipt.json"
NATIVE_TEST_SELECTOR = (
    "CoreTests/NativeDecompilerLiveXPCTests/"
    "testSignedServiceHonorsSupervisionAndRelaunchContract"
)

GATE_IDS = installer.REQUIRED_ACCEPTANCE_GATES
if GATE_IDS != tuple(sorted(GATE_IDS)):
    raise RuntimeError("installer acceptance gate identifiers are not canonical")

TOP_LEVEL_FIELDS = frozenset(
    {
        "authority",
        "authority_sha256",
        "candidate_artifact_root",
        "evidence_root",
        "gates",
        "output_path",
        "plan_kind",
        "schema_version",
    }
)
AUTHORITY_FIELDS = frozenset(
    {
        "application_executable_sha256",
        "artifact_root_identity_sha256",
        "artifact_root_path",
        "began_at_unix_ns",
        "build_provenance_sha256",
        "candidate_file_sha256",
        "candidate_identity_path",
        "candidate_identity_sha256",
        "destination_identity_sha256",
        "execution_identity_sha256",
        "exposed_at_unix_ns",
        "installed_app_path",
        "installed_task10_incremental_evidence_path",
        "installed_task10_matrix_receipt_path",
        "installed_task10_network_artifact_root",
        "installed_task10_xcresult_path",
        "installed_task10_xcresult_semantic_manifest_path",
        "installed_ui_preparation_receipt_path",
        "installed_ui_preparation_receipt_sha256",
        "installed_ui_runner_closed_tree_sha256",
        "installed_ui_runner_executable_sha256",
        "installed_ui_runner_path",
        "installed_ui_test_bundle_closed_tree_sha256",
        "installed_ui_test_bundle_executable_sha256",
        "installed_ui_test_bundle_path",
        "installed_ui_xctestrun_path",
        "installed_ui_xctestrun_sha256",
        "native_preparation_receipt_path",
        "native_preparation_receipt_sha256",
        "native_xctestrun_path",
        "native_xctestrun_sha256",
        "pending_state_path",
        "pending_state_sha256",
        "predecessor_digest",
        "predecessor_observations_sha256",
        "qualification_receipt_path",
        "qualification_receipt_sha256",
        "qualification_run_id",
        "qualification_run_nonce",
        "source_app_path",
        "source_commit",
        "source_equality_sha256",
        "source_tree",
        "transaction_id",
        "transaction_nonce",
    }
)
GATE_FIELDS = frozenset(
    {
        "argv",
        "authority_sha256",
        "depends_on",
        "environment",
        "gate_id",
        "operation_id",
        "output",
        "timeout_seconds",
    }
)
OUTPUT_FIELDS = frozenset({"kind", "maximum_bytes", "path", "publication"})
ENVIRONMENT_KEYS = frozenset(
    {
        "LANG",
        "LC_ALL",
        "MACSCOPE_ACCEPTANCE_AUTHORITY_SHA256",
        "NO_PROXY",
        "PATH",
        "no_proxy",
    }
)
FIXED_TIMEOUTS = {
    "cli": 90,
    "forced-legacy-grid": 90,
    "full-surface": 90,
    "gui": 90,
    "mcp": 60,
    "native-xpc": 300,
    "shellbroker-launchagent": 1_860,
    "signing": 120,
}
FIXED_DEPENDENCIES = {
    "cli": ("forced-legacy-grid", "full-surface", "native-xpc"),
    "forced-legacy-grid": (),
    "full-surface": (),
    "gui": ("forced-legacy-grid", "full-surface", "native-xpc"),
    "mcp": ("forced-legacy-grid", "full-surface", "native-xpc"),
    "native-xpc": (),
    "shellbroker-launchagent": (),
    "signing": (
        "cli",
        "forced-legacy-grid",
        "full-surface",
        "gui",
        "mcp",
        "native-xpc",
        "shellbroker-launchagent",
    ),
}
FIXED_OPERATION_IDS = {
    "cli": "cli-gui-operability",
    "forced-legacy-grid": "renderer-dual",
    "full-surface": "renderer-dual",
    "gui": "cli-gui-operability",
    "mcp": "mcp-probe",
    "native-xpc": "native-xpc-probe",
    "shellbroker-launchagent": "shellbroker-launchagent-probe",
    "signing": "ws24-finalize",
}
FIXED_OUTPUT_KINDS = {
    "cli": "command-file",
    "forced-legacy-grid": "command-file",
    "full-surface": "command-file",
    "gui": "captured-stdout",
    "mcp": "command-file",
    "native-xpc": "command-file",
    "shellbroker-launchagent": "command-file",
    "signing": "command-file",
}
FIXED_OUTPUT_MAXIMUM_BYTES = {
    "cli": 64 * 1024,
    "forced-legacy-grid": 4 * 1024 * 1024,
    "full-surface": 4 * 1024 * 1024,
    "gui": 64 * 1024,
    "mcp": 64 * 1024,
    "native-xpc": 1024 * 1024,
    "shellbroker-launchagent": 8 * 1024 * 1024,
    "signing": 8 * 1024 * 1024,
}
PRIMARY_OUTPUT_RELATIVE_PATHS = {
    "cli": Path("cli-gui-operability.report.json"),
    "forced-legacy-grid": Path("full-surface.legacy-grid.json"),
    "full-surface": Path("full-surface.json"),
    "gui": Path("cli-gui-operability.status.txt"),
    "mcp": Path("mcp-operability.report.json"),
    "native-xpc": Path(
        "native-xpc-artifacts/NativeDecompilerLiveXPC.execution-report.json"
    ),
    "shellbroker-launchagent": Path("live-evidence.json"),
    "signing": Path("WS24.installed-qualification.json"),
}

SHELL_CLI_CONTRACTS = {
    "Scripts/smoke/cli_gui_operability_smoke.sh": (
        'parser.add_argument("--output", "--report", dest="output", type=Path)',
        'parser.add_argument("--source-app", type=Path)',
        'parser.add_argument("--candidate-identity", type=Path)',
        'parser.add_argument("--qualification-run-id")',
        'parser.add_argument("--qualification-run-nonce")',
        'parser.add_argument("--installation-pending-state", type=Path)',
        'parser.add_argument("--full-surface-report", type=Path)',
        'parser.add_argument("--legacy-grid-report", type=Path)',
        'parser.add_argument("--native-xpc-execution-report", type=Path)',
        'choices=("preflight", "cli", "gui", "both")',
    ),
    "Scripts/smoke/mcp_operability_smoke.sh": (
        'parser.add_argument("--mode", choices=("preflight", "installed"), required=True)',
        'parser.add_argument("--app", type=Path, default=DEFAULT_APP)',
        'parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)',
        'parser.add_argument("--candidate-commit", default="")',
        'parser.add_argument("--timeout-seconds", type=float, default=DEFAULT_TIMEOUT)',
        'parser.add_argument("--output", "--report", dest="output", type=Path)',
        'parser.add_argument("--source-app", type=Path)',
        'parser.add_argument("--candidate-identity", type=Path)',
        'parser.add_argument("--qualification-run-id")',
        'parser.add_argument("--qualification-run-nonce")',
        'parser.add_argument("--installation-pending-state", type=Path)',
        'parser.add_argument("--full-surface-report", type=Path)',
        'parser.add_argument("--legacy-grid-report", type=Path)',
        'parser.add_argument("--native-xpc-execution-report", type=Path)',
    ),
    "Scripts/native-decompiler-xpc/run_installed_native_xpc_gate.py": (
        'parser.add_argument("--installed-app", type=Path, required=True)',
        'parser.add_argument("--candidate-identity", type=Path, required=True)',
        'parser.add_argument("--preparation-receipt", type=Path, required=True)',
        'parser.add_argument("--artifact-root", type=Path, required=True)',
        'parser.add_argument("--qualification-run-id", required=True)',
        'parser.add_argument("--qualification-run-nonce", required=True)',
        'parser.add_argument("--predecessor-observations-sha256", required=True)',
        'parser.add_argument("--phase-timeout-seconds", type=int, required=True)',
    ),
    "Scripts/reconstruction/emit_installed_live_evidence.py": (
        'parser.add_argument("--candidate-identity", type=Path, required=True)',
        'parser.add_argument("--source-app", type=Path, required=True)',
        'parser.add_argument("--installed-app", type=Path, required=True)',
        'parser.add_argument("--installation-pending-state", type=Path, required=True)',
        'parser.add_argument("--native-preparation-receipt", type=Path, required=True)',
        'parser.add_argument("--matrix-receipt", type=Path, required=True)',
        'parser.add_argument("--xcresult-semantic-manifest", type=Path, required=True)',
        'parser.add_argument("--network-artifact-root", type=Path, required=True)',
        'parser.add_argument("--qualification-run-id", required=True)',
        'parser.add_argument("--qualification-run-nonce", required=True)',
        'parser.add_argument("--evidence-root", type=Path, required=True)',
        '"--live-gates-timeout-seconds"',
    ),
}
DIRECT_EXECUTABLES = frozenset(
    {
        REPOSITORY_ROOT
        / "Scripts/native-decompiler-xpc/run_installed_native_xpc_gate.py",
    }
)


class PlanCompilationError(RuntimeError):
    """A favorable command plan cannot be compiled from the supplied authority."""


@dataclass(frozen=True)
class StableFile:
    path: Path
    metadata: tuple[int, int, int, int, int, int, int]
    payload: bytes


@dataclass(frozen=True)
class CompilationInputs:
    qualification_receipt: StableFile
    candidate_file: StableFile
    native_preparation_receipt: StableFile
    native_xctestrun: StableFile
    installed_ui_preparation_receipt: StableFile
    installed_ui_xctestrun: StableFile
    pending_state_file: Any
    source_authority: Any
    qualification_document: dict[str, Any]
    native_preparation_document: dict[str, Any]
    installed_ui_preparation_document: dict[str, Any]
    pending_state: dict[str, Any]
    candidate_artifact_root: Path
    evidence_root: Path
    qualification_output_root: Path
    output_path: Path
    source_app: Path
    installed_app: Path


def fail(message: str) -> NoReturn:
    raise PlanCompilationError(message)


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _closed(value: Any, fields: frozenset[str], *, label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        fail(f"{label} does not satisfy its closed field set")
    return value


def _canonical_directory(path: Path, *, label: str) -> Path:
    if not path.is_absolute():
        fail(f"{label} must be absolute")
    try:
        resolved = path.resolve(strict=True)
        metadata = path.lstat()
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if resolved != path or not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(
        metadata.st_mode
    ):
        fail(f"{label} must be a canonical non-symlink directory")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        try:
            observed = os.fstat(descriptor)
        finally:
            os.close(descriptor)
    except OSError as error:
        fail(f"{label} cannot be opened safely: {error}")
    if (metadata.st_dev, metadata.st_ino) != (observed.st_dev, observed.st_ino):
        fail(f"{label} changed during validation")
    return resolved


def _metadata_tuple(metadata: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _stable_file(path: Path, *, maximum_bytes: int, label: str) -> StableFile:
    if not path.is_absolute():
        fail(f"{label} must be absolute")
    try:
        resolved = path.resolve(strict=True)
        metadata = path.lstat()
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if resolved != path:
        fail(f"{label} must use its canonical path")
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size < 0
        or metadata.st_size > maximum_bytes
    ):
        fail(f"{label} must be a bounded singly linked ordinary file")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
        try:
            before = os.fstat(descriptor)
            chunks: list[bytes] = []
            remaining = maximum_bytes + 1
            while remaining > 0:
                chunk = os.read(descriptor, min(1024 * 1024, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            payload = b"".join(chunks)
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
    except OSError as error:
        fail(f"{label} cannot be read safely: {error}")
    expected = _metadata_tuple(metadata)
    if (
        len(payload) > maximum_bytes
        or _metadata_tuple(before) != expected
        or _metadata_tuple(after) != expected
        or len(payload) != metadata.st_size
    ):
        fail(f"{label} changed while it was read")
    return StableFile(path=resolved, metadata=expected, payload=payload)


def _require_unchanged(snapshot: StableFile, *, maximum_bytes: int, label: str) -> None:
    observed = _stable_file(snapshot.path, maximum_bytes=maximum_bytes, label=label)
    if observed.metadata != snapshot.metadata or observed.payload != snapshot.payload:
        fail(f"{label} changed during plan compilation")


def _decode_canonical(payload: bytes, *, label: str, one_trailing_lf: bool = False) -> Any:
    candidate = payload
    if one_trailing_lf:
        if not payload.endswith(b"\n") or payload.endswith(b"\n\n"):
            fail(f"{label} must have exactly one trailing LF")
        candidate = payload[:-1]
    try:
        value = decode_canonical_bytes(candidate)
    except CanonicalJSONError as error:
        fail(f"{label} is not canonical JSON: {error}")
    return value


def _canonical_absent_path(
    path: Path,
    *,
    root: Path,
    label: str,
    direct_child: bool = False,
) -> Path:
    if not path.is_absolute() or not path.name or any(
        part in {"", ".", ".."} for part in path.parts[1:]
    ):
        fail(f"{label} must be an absolute normalized leaf path")
    try:
        relative = path.relative_to(root)
    except ValueError:
        fail(f"{label} must be contained by the evidence root")
    if not relative.parts or (direct_child and len(relative.parts) != 1):
        fail(f"{label} has the wrong evidence-root depth")
    if path.exists() or path.is_symlink():
        fail(f"{label} must be absent for create-only publication")
    cursor = path.parent
    suffix: list[str] = []
    while not cursor.exists() and not cursor.is_symlink():
        suffix.append(cursor.name)
        cursor = cursor.parent
    canonical_ancestor = _canonical_directory(cursor, label=f"{label} existing ancestor")
    rebuilt = canonical_ancestor
    for component in reversed(suffix):
        rebuilt /= component
    rebuilt /= path.name
    if rebuilt != path:
        fail(f"{label} must be canonical and traverse no aliases")
    return path


def _paths_overlap(first: Path, second: Path) -> bool:
    return first == second or first in second.parents or second in first.parents


def _qualification_output_root(evidence_root: Path) -> Path:
    return evidence_root.parent / "InstalledAcceptanceQualification.evidence"


def _validate_cli_contracts() -> None:
    for relative, fragments in SHELL_CLI_CONTRACTS.items():
        path = REPOSITORY_ROOT / relative
        snapshot = _stable_file(path, maximum_bytes=2 * 1024 * 1024, label=relative)
        try:
            source = snapshot.payload.decode("utf-8")
        except UnicodeDecodeError as error:
            fail(f"{relative} is not UTF-8: {error}")
        missing = [fragment for fragment in fragments if fragment not in source]
        if missing:
            fail(f"{relative} CLI parser drifted: missing {missing[0]!r}")
        if not os.access(path, os.X_OK):
            fail(f"{relative} is not executable")


def _validate_qualification_receipt(snapshot: StableFile) -> dict[str, Any]:
    if snapshot.path.name != "QUALIFICATION_INPUTS.json":
        fail("qualification receipt must use the governed QUALIFICATION_INPUTS.json name")
    document = _closed(
        _decode_canonical(
            snapshot.payload,
            label="qualification receipt",
            one_trailing_lf=True,
        ),
        QUALIFICATION_V4_FIELDS,
        label="qualification receipt",
    )
    if document.get("schema_version") != 4 or document.get("mode") != "full-test":
        fail("qualification receipt must be the sealed schema-4 full-test artifact")
    if type(document.get("dependency_network_allowed")) is not bool:
        fail("qualification receipt dependency network authority must be Boolean")
    if document.get("dependency_network_used") is not False:
        fail("qualification receipt records online dependency use")
    source = _closed(
        document.get("source_identity"),
        SOURCE_EXPORT_V2_FIELDS,
        label="qualification source identity",
    )
    if (
        source.get("schema_version") != 2
        or source.get("repository_clean") is not True
        or GIT_OBJECT_RE.fullmatch(str(source.get("git_head_commit", ""))) is None
        or GIT_OBJECT_RE.fullmatch(str(source.get("git_head_tree", ""))) is None
        or SHA256_RE.fullmatch(str(source.get("source_files_sha256", ""))) is None
    ):
        fail("qualification source identity is not one exact clean sealed export")
    run_root = _canonical_directory(snapshot.path.parent, label="qualification run root")
    build_source = _canonical_directory(
        Path(str(document.get("build_source_root"))),
        label="qualification build source root",
    )
    if build_source != run_root / "source":
        fail("qualification receipt does not bind its exact run-owned source root")
    return document


def _validate_native_preparation(
    snapshot: StableFile,
    *,
    candidate_commit: str,
    candidate_tree: str,
) -> tuple[dict[str, Any], StableFile]:
    document = _decode_canonical(snapshot.payload, label="native preparation receipt")
    try:
        parsed = native_receipt.parse_document(document)
    except (OSError, UnicodeError, ValueError, native_receipt.PreparationReceiptError) as error:
        fail(f"native preparation receipt is invalid: {error}")
    source = parsed["source"]
    if source.get("commit") != candidate_commit or source.get("tree") != candidate_tree:
        fail("native preparation receipt belongs to another candidate")
    if parsed["build"].get("preparation_mode") != native_receipt.NATIVE_LIVE_PREPARATION_MODE:
        fail("native preparation receipt is not the governed live-XPC preparation")
    xctestrun_record = parsed["artifacts"]["xctestrun"]
    xctestrun = _stable_file(
        Path(xctestrun_record["path"]),
        maximum_bytes=MAXIMUM_XCTESTRUN_BYTES,
        label="native prepared xctestrun",
    )
    if _sha256(xctestrun.payload) != xctestrun_record["sha256"]:
        fail("native prepared xctestrun differs from its sealed receipt")
    return parsed, xctestrun


def _validate_installed_ui_preparation(
    snapshot: StableFile,
    *,
    candidate_commit: str,
    candidate_tree: str,
) -> tuple[dict[str, Any], StableFile, tuple[Path, Path]]:
    document = _decode_canonical(
        snapshot.payload,
        label="installed UI preparation receipt",
    )
    try:
        parsed = native_receipt.parse_document(document)
    except (OSError, UnicodeError, ValueError, native_receipt.PreparationReceiptError) as error:
        fail(f"installed UI preparation receipt is invalid: {error}")
    if (
        parsed.get("schema_version") != native_receipt.SCHEMA_VERSION
        or parsed.get("receipt_kind") != native_receipt.RECEIPT_KIND
        or parsed["build"].get("preparation_mode")
        != native_receipt.INSTALLED_UI_PREPARATION_MODE
    ):
        fail("installed UI preparation receipt is not exact schema-2 installed-ui authority")
    source = parsed["source"]
    if source.get("commit") != candidate_commit or source.get("tree") != candidate_tree:
        fail("installed UI preparation receipt belongs to another candidate")
    artifacts = parsed["artifacts"]
    xctestrun = _stable_file(
        Path(artifacts["xctestrun"]["path"]),
        maximum_bytes=MAXIMUM_XCTESTRUN_BYTES,
        label="installed UI prepared xctestrun",
    )
    if _sha256(xctestrun.payload) != artifacts["xctestrun"]["sha256"]:
        fail("installed UI prepared xctestrun differs from its sealed receipt")
    test_bundle = _canonical_directory(
        Path(artifacts["ui_test_bundle"]["path"]),
        label="installed UI prepared test bundle",
    )
    ui_runner = _canonical_directory(
        Path(artifacts["ui_runner"]["path"]),
        label="installed UI prepared runner",
    )
    return parsed, xctestrun, (test_bundle, ui_runner)


def _load_inputs(arguments: argparse.Namespace) -> CompilationInputs:
    _validate_cli_contracts()
    qualification_receipt = _stable_file(
        arguments.qualification_receipt,
        maximum_bytes=MAXIMUM_INPUT_BYTES,
        label="qualification receipt",
    )
    qualification_document = _validate_qualification_receipt(qualification_receipt)
    candidate_root = _canonical_directory(
        arguments.candidate_artifact_root,
        label="candidate artifact root",
    )
    qualification_run_root = qualification_receipt.path.parent
    if candidate_root != qualification_run_root / "candidate-artifacts":
        fail("candidate artifact root is not the qualification run's exact candidate-artifacts child")
    products_root = _canonical_directory(
        qualification_run_root / "DerivedData/Build/Products",
        label="qualification shared products root",
    )
    evidence_root = _canonical_directory(arguments.evidence_root, label="evidence root")
    qualification_output_root = _canonical_directory(
        _qualification_output_root(evidence_root),
        label="qualification output root",
    )
    try:
        qualification_entries = tuple(qualification_output_root.iterdir())
    except OSError as error:
        fail(f"qualification output root cannot be inspected: {error}")
    if qualification_entries:
        fail("qualification output root must be empty before plan compilation")
    if _paths_overlap(candidate_root, evidence_root):
        fail("candidate artifact and evidence roots must be disjoint")
    if _paths_overlap(evidence_root, qualification_output_root):
        fail("raw evidence and qualification output roots must be disjoint")
    output_path = _canonical_absent_path(
        arguments.output,
        root=evidence_root,
        label="plan output",
        direct_child=True,
    )
    if output_path.name != PLAN_FILENAME:
        fail(f"plan output must use the exact governed filename {PLAN_FILENAME}")

    candidate_file = _stable_file(
        candidate_root / CANDIDATE_IDENTITY_NAME,
        maximum_bytes=MAXIMUM_INPUT_BYTES,
        label="candidate identity",
    )
    candidate_document = _decode_canonical(candidate_file.payload, label="candidate identity")
    candidate, issues = parse_candidate_identity(candidate_document)
    if candidate is None or issues:
        detail = "; ".join(
            f"{issue.code} {issue.path}: {issue.message}" for issue in issues
        )
        fail(f"candidate identity is invalid: {detail}")
    native_preparation = _stable_file(
        candidate_root / NATIVE_PREPARATION_RECEIPT_NAME,
        maximum_bytes=MAXIMUM_INPUT_BYTES,
        label="native preparation receipt",
    )
    native_document, native_xctestrun = _validate_native_preparation(
        native_preparation,
        candidate_commit=candidate.source.commit,
        candidate_tree=candidate.source.tree,
    )
    installed_ui_preparation = _stable_file(
        candidate_root / INSTALLED_UI_PREPARATION_RECEIPT_NAME,
        maximum_bytes=MAXIMUM_INPUT_BYTES,
        label="installed UI preparation receipt",
    )
    (
        installed_ui_document,
        installed_ui_xctestrun,
        installed_ui_bundles,
    ) = _validate_installed_ui_preparation(
        installed_ui_preparation,
        candidate_commit=candidate.source.commit,
        candidate_tree=candidate.source.tree,
    )
    if native_xctestrun.path != (
        resolve_xctestrun(products_root, "MacScopeApp", native_document["toolchain"]["sdk_version"])
    ):
        fail("native preparation receipt does not bind the exact qualification xctestrun")
    if installed_ui_xctestrun.path != (
        resolve_xctestrun(products_root, "MacScopeInstalledAppUITests", installed_ui_document["toolchain"]["sdk_version"])
    ):
        fail("installed UI receipt does not bind the exact qualification xctestrun")
    expected_ui_runner = products_root / "Debug/MacScopeInstalledAppUITests-Runner.app"
    expected_ui_bundle = (
        expected_ui_runner
        / "Contents/PlugIns/MacScopeInstalledAppUITests.xctest"
    )
    if installed_ui_bundles != (expected_ui_bundle, expected_ui_runner):
        fail("installed UI receipt does not bind the exact qualification UI products")
    if native_document["toolchain"] != installed_ui_document["toolchain"]:
        fail("native and installed UI receipts do not share one exact toolchain authority")

    pending_path = arguments.installation_pending_state
    if pending_path.name != "transaction.json":
        fail("installation pending state must use the exact transaction.json name")
    pending_path = _stable_file(
        pending_path,
        maximum_bytes=installer.MAX_PENDING_TRANSACTION_BYTES,
        label="installation pending state",
    ).path
    try:
        state, pending_state_file = installer._pending_read_stable(pending_path.parent)
    except (OSError, ValueError, installer.InstallationError) as error:
        fail(f"installation pending state is invalid: {error}")
    if pending_state_file.path != pending_path:
        fail("installation pending state is not the transaction root authority")
    _closed(state, installer.PENDING_TRANSACTION_FIELDS, label="installation pending state")
    if state.get("schema_version") != 3 or state.get("phase") != "pending":
        fail("installation transaction must be live schema-3 pending state")

    source_app = _canonical_directory(
        Path(str(state.get("source_app_path"))), label="sealed source Release app"
    )
    if source_app != products_root / "Release/MacScope.app":
        fail("pending source app is not the exact qualification Release product")
    installed_app = _canonical_directory(
        Path(str(state.get("installed_app_path"))), label="installed candidate app"
    )
    if source_app == installed_app or _paths_overlap(source_app, installed_app):
        fail("installed candidate must be physically distinct from its source app")
    qualification_source = qualification_document["source_identity"]
    if (
        qualification_source["git_head_commit"] != candidate.source.commit
        or qualification_source["git_head_tree"] != candidate.source.tree
        or state.get("source_commit") != candidate.source.commit
        or state.get("source_tree") != candidate.source.tree
    ):
        fail("qualification, candidate, and pending source identities differ")

    try:
        source_authority = installer._load_source_authority(candidate_file.path, source_app)
        native_app_record = native_document["artifacts"]["app"]
        native_app = _canonical_directory(
            Path(native_app_record["path"]),
            label="native preparation candidate app",
        )
        if native_app != source_app:
            fail("native preparation receipt does not bind the sealed source app")
        if (
            native_app_record["closed_tree_sha256"]
            != source_authority.candidate.application.closed_tree_sha256
            or native_app_record["executable_sha256"]
            != source_authority.executable_sha256
        ):
            fail("native preparation app identity differs from candidate authority")
        installed_ui_app_record = installed_ui_document["artifacts"]["app"]
        installed_ui_app = _canonical_directory(
            Path(installed_ui_app_record["path"]),
            label="installed UI preparation candidate app",
        )
        if installed_ui_app != source_app:
            fail("installed UI preparation receipt does not bind the sealed source app")
        if (
            installed_ui_app_record["closed_tree_sha256"]
            != source_authority.candidate.application.closed_tree_sha256
            or installed_ui_app_record["executable_sha256"]
            != source_authority.executable_sha256
        ):
            fail("installed UI preparation app identity differs from candidate authority")
        qualification_run = installer.QualificationRunAuthority(
            run_id=str(state.get("qualification_run_id")),
            nonce=str(state.get("qualification_run_nonce")),
        )
        installer._pending_validate_state(
            state,
            authority=source_authority,
            token=source_authority.candidate_identity_sha256,
            installed_app=installed_app,
            source_app=source_app,
            artifact_root=Path(str(state.get("artifact_root"))),
            qualification_run=qualification_run,
            predecessor_observations_sha256=str(
                state.get("predecessor_observations_sha256")
            ),
            allowed_phases=frozenset({"pending"}),
        )
        installed_snapshot = installer._capture_exact_bundle(installed_app)
        if not installer._snapshot_matches_record(
            installed_snapshot, state["candidate_identity"]
        ):
            fail("installed candidate no longer matches pending authority")
        installer._validate_destination_identity(
            state["destination_identity"],
            installed_app,
            snapshot=installed_snapshot,
        )
    except (OSError, ValueError, installer.InstallationError) as error:
        fail(f"pending transaction authority validation failed: {error}")

    if state.get("candidate_file_sha256") != _sha256(candidate_file.payload):
        fail("pending state candidate file digest differs")
    if state.get("candidate_identity_sha256") != candidate_identity_sha256(candidate):
        fail("pending state candidate identity digest differs")
    if state.get("exposed_at_unix_ns", 0) > pending_state_file.metadata[5]:
        fail("pending transaction state predates installed candidate exposure")
    for prepared_product, product_label in (
        (native_xctestrun.path, "native prepared xctestrun"),
        (installed_ui_xctestrun.path, "installed UI prepared xctestrun"),
        (installed_ui_bundles[0], "installed UI prepared test bundle"),
        (installed_ui_bundles[1], "installed UI prepared runner"),
    ):
        for mutable_root, mutable_label in (
            (pending_path.parent, "pending transaction root"),
            (installed_app, "installed app"),
            (evidence_root, "evidence root"),
        ):
            if _paths_overlap(prepared_product, mutable_root):
                fail(f"{product_label} must be disjoint from {mutable_label}")
    for protected, label in (
        (candidate_root, "candidate artifact root"),
        (qualification_receipt.path.parent, "qualification run root"),
        (native_xctestrun.path, "native prepared xctestrun"),
        (installed_ui_xctestrun.path, "installed UI prepared xctestrun"),
        (installed_ui_bundles[0], "installed UI prepared test bundle"),
        (installed_ui_bundles[1], "installed UI prepared runner"),
        (pending_path.parent, "pending transaction root"),
        (Path(str(state["artifact_root"])), "installer artifact root"),
        (source_app, "source app"),
        (installed_app, "installed app"),
    ):
        for output_root, output_label in (
            (evidence_root, "evidence root"),
            (qualification_output_root, "qualification output root"),
        ):
            if _paths_overlap(output_root, protected):
                fail(f"{output_label} must be disjoint from {label}")

    return CompilationInputs(
        qualification_receipt=qualification_receipt,
        candidate_file=candidate_file,
        native_preparation_receipt=native_preparation,
        native_xctestrun=native_xctestrun,
        installed_ui_preparation_receipt=installed_ui_preparation,
        installed_ui_xctestrun=installed_ui_xctestrun,
        pending_state_file=pending_state_file,
        source_authority=source_authority,
        qualification_document=qualification_document,
        native_preparation_document=native_document,
        installed_ui_preparation_document=installed_ui_document,
        pending_state=state,
        candidate_artifact_root=candidate_root,
        evidence_root=evidence_root,
        qualification_output_root=qualification_output_root,
        output_path=output_path,
        source_app=source_app,
        installed_app=installed_app,
    )


def _authority(inputs: CompilationInputs) -> dict[str, Any]:
    state = inputs.pending_state
    task10_paths = _installed_task10_paths(inputs.evidence_root)
    installed_ui_artifacts = inputs.installed_ui_preparation_document["artifacts"]
    return {
        "application_executable_sha256": state["application_executable_sha256"],
        "artifact_root_identity_sha256": _sha256(
            canonical_bytes(state["artifact_root_identity"])
        ),
        "artifact_root_path": state["artifact_root"],
        "began_at_unix_ns": state["began_at_unix_ns"],
        "build_provenance_sha256": state["build_provenance_sha256"],
        "candidate_file_sha256": state["candidate_file_sha256"],
        "candidate_identity_path": str(inputs.candidate_file.path),
        "candidate_identity_sha256": state["candidate_identity_sha256"],
        "destination_identity_sha256": _sha256(
            canonical_bytes(state["destination_identity"])
        ),
        "execution_identity_sha256": state["execution_identity_sha256"],
        "exposed_at_unix_ns": state["exposed_at_unix_ns"],
        "installed_app_path": str(inputs.installed_app),
        **{field: str(path) for field, path in task10_paths.items()},
        "installed_ui_preparation_receipt_path": str(
            inputs.installed_ui_preparation_receipt.path
        ),
        "installed_ui_preparation_receipt_sha256": _sha256(
            inputs.installed_ui_preparation_receipt.payload
        ),
        "installed_ui_runner_closed_tree_sha256": installed_ui_artifacts[
            "ui_runner"
        ]["closed_tree_sha256"],
        "installed_ui_runner_executable_sha256": installed_ui_artifacts[
            "ui_runner"
        ]["executable_sha256"],
        "installed_ui_runner_path": installed_ui_artifacts["ui_runner"]["path"],
        "installed_ui_test_bundle_closed_tree_sha256": installed_ui_artifacts[
            "ui_test_bundle"
        ]["closed_tree_sha256"],
        "installed_ui_test_bundle_executable_sha256": installed_ui_artifacts[
            "ui_test_bundle"
        ]["executable_sha256"],
        "installed_ui_test_bundle_path": installed_ui_artifacts["ui_test_bundle"][
            "path"
        ],
        "installed_ui_xctestrun_path": installed_ui_artifacts["xctestrun"]["path"],
        "installed_ui_xctestrun_sha256": installed_ui_artifacts["xctestrun"][
            "sha256"
        ],
        "native_preparation_receipt_path": str(
            inputs.native_preparation_receipt.path
        ),
        "native_preparation_receipt_sha256": _sha256(
            inputs.native_preparation_receipt.payload
        ),
        "native_xctestrun_path": str(inputs.native_xctestrun.path),
        "native_xctestrun_sha256": _sha256(inputs.native_xctestrun.payload),
        "pending_state_path": str(inputs.pending_state_file.path),
        "pending_state_sha256": _sha256(inputs.pending_state_file.payload),
        "predecessor_digest": state["predecessor_digest"],
        "predecessor_observations_sha256": state[
            "predecessor_observations_sha256"
        ],
        "qualification_receipt_path": str(inputs.qualification_receipt.path),
        "qualification_receipt_sha256": _sha256(
            inputs.qualification_receipt.payload
        ),
        "qualification_run_id": state["qualification_run_id"],
        "qualification_run_nonce": state["qualification_run_nonce"],
        "source_app_path": str(inputs.source_app),
        "source_commit": state["source_commit"],
        "source_equality_sha256": state["source_equality_sha256"],
        "source_tree": state["source_tree"],
        "transaction_id": state["transaction_id"],
        "transaction_nonce": state["transaction_nonce"],
    }


def _fixed_environment(authority_sha256: str) -> dict[str, str]:
    return {
        "LANG": "C",
        "LC_ALL": "C",
        "MACSCOPE_ACCEPTANCE_AUTHORITY_SHA256": authority_sha256,
        "NO_PROXY": "*",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "no_proxy": "*",
    }


def _gate_record(
    *,
    gate_id: str,
    argv: tuple[str, ...],
    authority_sha256: str,
    output_path: Path,
) -> dict[str, Any]:
    return {
        "argv": list(argv),
        "authority_sha256": authority_sha256,
        "depends_on": list(FIXED_DEPENDENCIES[gate_id]),
        "environment": _fixed_environment(authority_sha256),
        "gate_id": gate_id,
        "operation_id": FIXED_OPERATION_IDS[gate_id],
        "output": {
            "kind": FIXED_OUTPUT_KINDS[gate_id],
            "maximum_bytes": FIXED_OUTPUT_MAXIMUM_BYTES[gate_id],
            "path": str(output_path),
            "publication": "create-only",
        },
        "timeout_seconds": FIXED_TIMEOUTS[gate_id],
    }


def _primary_output_paths(evidence_root: Path) -> dict[str, Path]:
    outputs = {
        gate_id: evidence_root / PRIMARY_OUTPUT_RELATIVE_PATHS[gate_id]
        for gate_id in GATE_IDS
    }
    outputs["signing"] = (
        _qualification_output_root(evidence_root)
        / PRIMARY_OUTPUT_RELATIVE_PATHS["signing"]
    )
    return outputs


def _ws24_envelope_paths(evidence_root: Path) -> dict[str, Path]:
    qualification_root = _qualification_output_root(evidence_root)
    return {
        gate_id: qualification_root / f"{gate_id}.acceptance-gate.json"
        for gate_id in GATE_IDS
    }


def _installed_task10_paths(evidence_root: Path) -> dict[str, Path]:
    network_root = evidence_root / "installed-task10-network"
    return {
        "installed_task10_incremental_evidence_path": (
            network_root / "InstalledTask10.incremental-xcuitest.evidence.json"
        ),
        "installed_task10_matrix_receipt_path": (
            evidence_root / "InstalledTask10.matrix-receipt.json"
        ),
        "installed_task10_network_artifact_root": network_root,
        "installed_task10_xcresult_path": evidence_root / "InstalledTask10.xcresult",
        "installed_task10_xcresult_semantic_manifest_path": (
            evidence_root / "InstalledTask10.xcresult-semantic.json"
        ),
    }


def _xcode_developer_dir_from_authority(authority: dict[str, Any]) -> Path:
    snapshot = _stable_file(
        Path(authority["native_preparation_receipt_path"]),
        maximum_bytes=MAXIMUM_INPUT_BYTES,
        label="native preparation receipt for argv reconstruction",
    )
    if _sha256(snapshot.payload) != authority["native_preparation_receipt_sha256"]:
        fail("native preparation receipt changed before argv reconstruction")
    document, _ = _validate_native_preparation(
        snapshot,
        candidate_commit=authority["source_commit"],
        candidate_tree=authority["source_tree"],
    )
    return _canonical_directory(
        Path(document["toolchain"]["developer_dir"]),
        label="native preparation Xcode developer directory",
    )


def _installed_native_gate_argv(
    *,
    authority: dict[str, Any],
    evidence_root: Path,
    output: Path,
) -> tuple[str, ...]:
    artifact_root = evidence_root / "native-xpc-artifacts"
    if output != artifact_root / "NativeDecompilerLiveXPC.execution-report.json":
        fail("installed-native output differs from its governed artifact root")
    return (
        str(
            REPOSITORY_ROOT
            / "Scripts/native-decompiler-xpc/run_installed_native_xpc_gate.py"
        ),
        "--installed-app",
        authority["installed_app_path"],
        "--candidate-identity",
        authority["candidate_identity_path"],
        "--preparation-receipt",
        authority["native_preparation_receipt_path"],
        "--artifact-root",
        str(artifact_root),
        "--qualification-run-id",
        authority["qualification_run_id"],
        "--qualification-run-nonce",
        authority["qualification_run_nonce"],
        "--predecessor-observations-sha256",
        authority["predecessor_observations_sha256"],
        "--phase-timeout-seconds",
        "60",
    )


def _live_evidence_gate_argv(
    *,
    authority: dict[str, Any],
    evidence_root: Path,
    output: Path,
) -> tuple[str, ...]:
    if output != evidence_root / "live-evidence.json":
        fail("installed live-evidence output differs from its governed path")
    return (
        "/usr/bin/python3",
        "-B",
        str(REPOSITORY_ROOT / "Scripts/reconstruction/emit_installed_live_evidence.py"),
        "--candidate-identity",
        authority["candidate_identity_path"],
        "--source-app",
        authority["source_app_path"],
        "--installed-app",
        authority["installed_app_path"],
        "--installation-pending-state",
        authority["pending_state_path"],
        "--native-preparation-receipt",
        authority["native_preparation_receipt_path"],
        "--matrix-receipt",
        authority["installed_task10_matrix_receipt_path"],
        "--xcresult-semantic-manifest",
        authority["installed_task10_xcresult_semantic_manifest_path"],
        "--network-artifact-root",
        authority["installed_task10_network_artifact_root"],
        "--qualification-run-id",
        authority["qualification_run_id"],
        "--qualification-run-nonce",
        authority["qualification_run_nonce"],
        "--evidence-root",
        str(evidence_root),
        "--live-gates-timeout-seconds",
        "1800",
    )


def _build_gate_argv(
    *,
    authority: dict[str, Any],
    authority_sha256: str,
    evidence_root: Path,
    outputs: dict[str, Path],
) -> dict[str, tuple[str, ...]]:
    installed = authority["installed_app_path"]
    source = authority["source_app_path"]
    candidate = authority["candidate_identity_path"]
    pending = authority["pending_state_path"]
    candidate_commit = authority["source_commit"]
    xcode_developer_dir = _xcode_developer_dir_from_authority(authority)
    full_surface = str(outputs["full-surface"])
    legacy_grid = str(outputs["forced-legacy-grid"])
    native_report = str(outputs["native-xpc"])
    marker = f"macscope-installed-acceptance-{authority_sha256}"
    cli_gui_script = str(
        REPOSITORY_ROOT / "Scripts/smoke/cli_gui_operability_smoke.sh"
    )
    mcp_script = str(REPOSITORY_ROOT / "Scripts/smoke/mcp_operability_smoke.sh")
    renderer_script = str(
        REPOSITORY_ROOT / "Scripts/phase2/run_installed_shell_smoke.py"
    )
    ws24_script = str(
        REPOSITORY_ROOT / "Scripts/ws24_emit_installed_qualification_report.py"
    )
    renderer_argv = (
        "/usr/bin/python3",
        "-B",
        renderer_script,
        "--app",
        installed,
        "--output",
        full_surface,
        "--marker",
        marker,
        "--timeout-seconds",
        "30",
        "--single-launch",
        "--expected-source-commit",
        candidate_commit,
    )
    cli_gui_argv = (
        "/bin/bash",
        cli_gui_script,
        "--mode",
        "both",
        "--app",
        installed,
        "--timeout-seconds",
        "30",
        "--binary",
        "/usr/bin/true",
        "--candidate-commit",
        candidate_commit,
        "--output",
        str(outputs["cli"]),
        "--source-app",
        source,
        "--candidate-identity",
        candidate,
        "--qualification-run-id",
        authority["qualification_run_id"],
        "--qualification-run-nonce",
        authority["qualification_run_nonce"],
        "--installation-pending-state",
        pending,
        "--full-surface-report",
        full_surface,
        "--legacy-grid-report",
        legacy_grid,
        "--native-xpc-execution-report",
        native_report,
    )
    mcp_argv = (
        "/bin/bash",
        mcp_script,
        "--mode",
        "installed",
        "--app",
        installed,
        "--binary",
        "/bin/ls",
        "--candidate-commit",
        candidate_commit,
        "--timeout-seconds",
        "30",
        "--output",
        str(outputs["mcp"]),
        "--source-app",
        source,
        "--candidate-identity",
        candidate,
        "--qualification-run-id",
        authority["qualification_run_id"],
        "--qualification-run-nonce",
        authority["qualification_run_nonce"],
        "--installation-pending-state",
        pending,
        "--full-surface-report",
        full_surface,
        "--legacy-grid-report",
        legacy_grid,
        "--native-xpc-execution-report",
        native_report,
    )
    ws24_envelopes = _ws24_envelope_paths(evidence_root)
    ws24_argv = (
        "/usr/bin/python3",
        "-B",
        ws24_script,
        "--source-app",
        source,
        "--installed-app",
        installed,
        "--evidence-json",
        str(outputs["shellbroker-launchagent"]),
        "--candidate-identity",
        candidate,
        "--expected-source-commit",
        candidate_commit,
        "--qualification-run-id",
        authority["qualification_run_id"],
        "--qualification-run-nonce",
        authority["qualification_run_nonce"],
        "--installation-pending-state",
        pending,
        "--full-surface-report",
        full_surface,
        "--legacy-grid-report",
        legacy_grid,
        "--cli-gui-operability-report",
        str(outputs["cli"]),
        "--mcp-operability-report",
        str(outputs["mcp"]),
        "--native-xpc-execution-report",
        native_report,
        "--output",
        str(outputs["signing"]),
    ) + tuple(
        token
        for gate_id in GATE_IDS
        for token in (
            "--acceptance-gate-output",
            f"{gate_id}={ws24_envelopes[gate_id]}",
        )
    ) + ("--xcode-developer-dir", str(xcode_developer_dir))
    return {
        "cli": cli_gui_argv,
        "forced-legacy-grid": renderer_argv,
        "full-surface": renderer_argv,
        "gui": cli_gui_argv,
        "mcp": mcp_argv,
        "native-xpc": _installed_native_gate_argv(
            authority=authority,
            evidence_root=evidence_root,
            output=outputs["native-xpc"],
        ),
        "shellbroker-launchagent": _live_evidence_gate_argv(
            authority=authority,
            evidence_root=evidence_root,
            output=outputs["shellbroker-launchagent"],
        ),
        "signing": ws24_argv,
    }


def compile_plan_document(inputs: CompilationInputs) -> dict[str, Any]:
    authority = _authority(inputs)
    authority_sha256 = _sha256(canonical_bytes(authority))
    evidence = inputs.evidence_root
    outputs = _primary_output_paths(evidence)
    canonical_outputs = {
        gate_id: _canonical_absent_path(
            path,
            root=(
                inputs.qualification_output_root
                if gate_id == "signing"
                else evidence
            ),
            label=f"{gate_id} output",
        )
        for gate_id, path in outputs.items()
    }
    if len(set(canonical_outputs.values())) != len(GATE_IDS):
        fail("gate output paths must be pairwise distinct")
    for gate_id, envelope in _ws24_envelope_paths(evidence).items():
        _canonical_absent_path(
            envelope,
            root=inputs.qualification_output_root,
            label=f"{gate_id} WS24 acceptance envelope",
            direct_child=True,
        )

    argv_by_gate = _build_gate_argv(
        authority=authority,
        authority_sha256=authority_sha256,
        evidence_root=evidence,
        outputs=canonical_outputs,
    )
    gates = [
        _gate_record(
            gate_id=gate_id,
            argv=argv_by_gate[gate_id],
            authority_sha256=authority_sha256,
            output_path=canonical_outputs[gate_id],
        )
        for gate_id in GATE_IDS
    ]
    plan = {
        "authority": authority,
        "authority_sha256": authority_sha256,
        "candidate_artifact_root": str(inputs.candidate_artifact_root),
        "evidence_root": str(inputs.evidence_root),
        "gates": gates,
        "output_path": str(inputs.output_path),
        "plan_kind": PLAN_KIND,
        "schema_version": PLAN_SCHEMA_VERSION,
    }
    validate_plan_document(plan, require_outputs_absent=True)

    # Exercise the importable Python parsers without launching any command.
    # The direct native executable and shell entry points are frozen above by
    # exact parser-source fragments.
    renderer_runner.parse_arguments(list(argv_by_gate["full-surface"][3:]))
    live_evidence.parse_arguments(
        list(argv_by_gate["shellbroker-launchagent"][3:])
    )
    ws24_reporter.parse_arguments(list(argv_by_gate["signing"][3:]))
    return plan


def _safe_text(value: Any, *, label: str, maximum_bytes: int = MAXIMUM_TOKEN_BYTES) -> str:
    if not isinstance(value, str) or not value or any(
        character in value for character in ("\x00", "\n", "\r")
    ):
        fail(f"{label} must be nonempty single-line text")
    try:
        size = len(value.encode("utf-8"))
    except UnicodeEncodeError as error:
        fail(f"{label} is not UTF-8: {error}")
    if size > maximum_bytes:
        fail(f"{label} exceeds its byte bound")
    return value


def _validate_authority(authority: Any) -> dict[str, Any]:
    record = _closed(authority, AUTHORITY_FIELDS, label="plan authority")
    sha_fields = AUTHORITY_FIELDS & {
        "application_executable_sha256",
        "artifact_root_identity_sha256",
        "build_provenance_sha256",
        "candidate_file_sha256",
        "candidate_identity_sha256",
        "destination_identity_sha256",
        "execution_identity_sha256",
        "installed_ui_preparation_receipt_sha256",
        "installed_ui_runner_closed_tree_sha256",
        "installed_ui_runner_executable_sha256",
        "installed_ui_test_bundle_closed_tree_sha256",
        "installed_ui_test_bundle_executable_sha256",
        "installed_ui_xctestrun_sha256",
        "native_preparation_receipt_sha256",
        "native_xctestrun_sha256",
        "pending_state_sha256",
        "predecessor_observations_sha256",
        "qualification_receipt_sha256",
        "qualification_run_nonce",
        "source_equality_sha256",
        "transaction_id",
        "transaction_nonce",
    }
    for field in sha_fields:
        if SHA256_RE.fullmatch(str(record.get(field, ""))) is None:
            fail(f"plan authority {field} must be lowercase SHA-256")
    for field in ("source_commit", "source_tree"):
        if GIT_OBJECT_RE.fullmatch(str(record.get(field, ""))) is None:
            fail(f"plan authority {field} must be a full Git object")
    if STABLE_ID_RE.fullmatch(str(record.get("qualification_run_id", ""))) is None:
        fail("plan authority qualification_run_id is invalid")
    began = record.get("began_at_unix_ns")
    exposed = record.get("exposed_at_unix_ns")
    if (
        type(began) is not int
        or type(exposed) is not int
        or began <= 0
        or exposed < began
    ):
        fail("plan authority transaction timestamps are invalid")
    predecessor_digest = record.get("predecessor_digest")
    if predecessor_digest is not None and SHA256_RE.fullmatch(
        str(predecessor_digest)
    ) is None:
        fail("plan authority predecessor_digest must be null or lowercase SHA-256")
    for field in (
        "artifact_root_path",
        "candidate_identity_path",
        "installed_app_path",
        "installed_task10_incremental_evidence_path",
        "installed_task10_matrix_receipt_path",
        "installed_task10_network_artifact_root",
        "installed_task10_xcresult_path",
        "installed_task10_xcresult_semantic_manifest_path",
        "installed_ui_preparation_receipt_path",
        "installed_ui_runner_path",
        "installed_ui_test_bundle_path",
        "installed_ui_xctestrun_path",
        "native_preparation_receipt_path",
        "native_xctestrun_path",
        "pending_state_path",
        "qualification_receipt_path",
        "source_app_path",
    ):
        path = Path(_safe_text(record.get(field), label=f"plan authority {field}"))
        if not path.is_absolute():
            fail(f"plan authority {field} must be absolute")
    return record


def _validate_argv(argv: Any, *, gate_id: str) -> list[str]:
    if not isinstance(argv, list) or not argv or len(argv) > MAXIMUM_ARGV_TOKENS:
        fail(f"gate {gate_id} argv is missing or unbounded")
    normalized = [
        _safe_text(token, label=f"gate {gate_id} argv token") for token in argv
    ]
    if sum(len(token.encode("utf-8")) + 1 for token in normalized) > MAXIMUM_ARGV_BYTES:
        fail(f"gate {gate_id} argv exceeds its aggregate byte bound")
    if "-c" in normalized or "eval" in normalized:
        fail(f"gate {gate_id} argv contains a shell/eval entry point")
    if normalized[0] == "/bin/bash":
        script_index = 1
    elif normalized[0] == "/usr/bin/python3":
        script_index = 2
        if len(normalized) < 2 or normalized[1] != "-B":
            fail(f"gate {gate_id} Python invocation must disable bytecode writes")
    elif Path(normalized[0]) in DIRECT_EXECUTABLES:
        script_index = 0
    else:
        fail(f"gate {gate_id} executable is outside the closed allowlist")
    if script_index >= len(normalized):
        fail(f"gate {gate_id} argv omits its script")
    script = Path(normalized[script_index])
    if not script.is_absolute() or REPOSITORY_ROOT not in script.parents:
        fail(f"gate {gate_id} script is outside the repository authority")
    if script_index == 0 and not os.access(script, os.X_OK):
        fail(f"gate {gate_id} direct executable is not executable")
    return normalized


def validate_plan_document(
    value: Any,
    *,
    require_outputs_absent: bool = False,
) -> dict[str, Any]:
    _validate_cli_contracts()
    plan = _closed(value, TOP_LEVEL_FIELDS, label="installed acceptance gate plan")
    if plan.get("schema_version") != 1 or plan.get("plan_kind") != PLAN_KIND:
        fail("installed acceptance gate plan schema or kind differs")
    candidate_root = Path(
        _safe_text(plan.get("candidate_artifact_root"), label="candidate artifact root")
    )
    evidence_root = Path(_safe_text(plan.get("evidence_root"), label="evidence root"))
    output_path = Path(_safe_text(plan.get("output_path"), label="plan output path"))
    for path, label in (
        (candidate_root, "candidate artifact root"),
        (evidence_root, "evidence root"),
        (output_path, "plan output path"),
    ):
        if not path.is_absolute():
            fail(f"{label} must be absolute")
    _canonical_directory(candidate_root, label="candidate artifact root")
    _canonical_directory(evidence_root, label="evidence root")
    qualification_output_root = _canonical_directory(
        _qualification_output_root(evidence_root),
        label="qualification output root",
    )
    if _paths_overlap(candidate_root, evidence_root):
        fail("candidate artifact and evidence roots must be disjoint")
    if _paths_overlap(evidence_root, qualification_output_root):
        fail("raw evidence and qualification output roots must be disjoint")
    if output_path != evidence_root / PLAN_FILENAME:
        fail("plan output path is not the governed evidence-root child")
    authority = _validate_authority(plan.get("authority"))
    authority_sha256 = str(plan.get("authority_sha256"))
    if (
        SHA256_RE.fullmatch(authority_sha256) is None
        or authority_sha256 != _sha256(canonical_bytes(authority))
    ):
        fail("plan authority SHA-256 is invalid")
    qualification_receipt = _stable_file(
        Path(authority["qualification_receipt_path"]),
        maximum_bytes=MAXIMUM_INPUT_BYTES,
        label="plan qualification receipt",
    )
    if _sha256(qualification_receipt.payload) != authority["qualification_receipt_sha256"]:
        fail("plan qualification receipt digest differs")
    qualification_document = _validate_qualification_receipt(qualification_receipt)
    qualification_run_root = qualification_receipt.path.parent
    if candidate_root != qualification_run_root / "candidate-artifacts":
        fail("plan candidate root is not the qualification run's governed child")
    qualification_source = qualification_document["source_identity"]
    if (
        qualification_source["git_head_commit"] != authority["source_commit"]
        or qualification_source["git_head_tree"] != authority["source_tree"]
    ):
        fail("plan qualification source identity differs")
    candidate_file = _stable_file(
        Path(authority["candidate_identity_path"]),
        maximum_bytes=MAXIMUM_INPUT_BYTES,
        label="plan candidate identity",
    )
    if _sha256(candidate_file.payload) != authority["candidate_file_sha256"]:
        fail("plan candidate file digest differs")
    candidate_document = _decode_canonical(candidate_file.payload, label="plan candidate identity")
    candidate, issues = parse_candidate_identity(candidate_document)
    if candidate is None or issues:
        fail("plan candidate identity is invalid")
    if (
        candidate_identity_sha256(candidate) != authority["candidate_identity_sha256"]
        or candidate.source.commit != authority["source_commit"]
        or candidate.source.tree != authority["source_tree"]
    ):
        fail("plan candidate identity differs from the sealed authority")
    exact_authority_paths = {
        "candidate_identity_path": candidate_root / CANDIDATE_IDENTITY_NAME,
        "native_preparation_receipt_path": (
            candidate_root / NATIVE_PREPARATION_RECEIPT_NAME
        ),
        "installed_ui_preparation_receipt_path": (
            candidate_root / INSTALLED_UI_PREPARATION_RECEIPT_NAME
        ),
    }
    for field, expected in exact_authority_paths.items():
        if Path(authority[field]) != expected:
            fail(f"plan authority {field} differs from its governed path")
    native_preparation = _stable_file(
        Path(authority["native_preparation_receipt_path"]),
        maximum_bytes=MAXIMUM_INPUT_BYTES,
        label="plan native preparation receipt",
    )
    if _sha256(native_preparation.payload) != authority["native_preparation_receipt_sha256"]:
        fail("plan native preparation receipt digest differs")
    native_document, native_xctestrun = _validate_native_preparation(
        native_preparation,
        candidate_commit=authority["source_commit"],
        candidate_tree=authority["source_tree"],
    )
    products_root = qualification_run_root / "DerivedData/Build/Products"
    if (
        native_xctestrun.path
        != resolve_xctestrun(products_root, "MacScopeApp", native_document["toolchain"]["sdk_version"])
        or str(native_xctestrun.path) != authority["native_xctestrun_path"]
        or _sha256(native_xctestrun.payload) != authority["native_xctestrun_sha256"]
    ):
        fail("plan native xctestrun authority differs")
    if Path(authority["source_app_path"]) != products_root / "Release/MacScope.app":
        fail("plan source app is not the exact full-test Release product")
    native_app = native_document["artifacts"]["app"]
    candidate_application = candidate.application
    if (
        native_app["path"] != authority["source_app_path"]
        or native_app["closed_tree_sha256"]
        != candidate_application.closed_tree_sha256
        or native_app["executable_sha256"]
        != candidate_application.executable_sha256
    ):
        fail("plan native preparation app differs from the candidate")
    installed_ui_receipt = _stable_file(
        Path(authority["installed_ui_preparation_receipt_path"]),
        maximum_bytes=MAXIMUM_INPUT_BYTES,
        label="plan installed UI preparation receipt",
    )
    if (
        _sha256(installed_ui_receipt.payload)
        != authority["installed_ui_preparation_receipt_sha256"]
    ):
        fail("plan installed UI preparation receipt digest differs")
    installed_ui_document, installed_ui_xctestrun, installed_ui_bundles = (
        _validate_installed_ui_preparation(
            installed_ui_receipt,
            candidate_commit=authority["source_commit"],
            candidate_tree=authority["source_tree"],
        )
    )
    installed_ui_artifacts = installed_ui_document["artifacts"]
    expected_ui_runner = products_root / "Debug/MacScopeInstalledAppUITests-Runner.app"
    expected_ui_bundle = expected_ui_runner / "Contents/PlugIns/MacScopeInstalledAppUITests.xctest"
    if (
        installed_ui_xctestrun.path
        != resolve_xctestrun(products_root, "MacScopeInstalledAppUITests", installed_ui_document["toolchain"]["sdk_version"])
        or installed_ui_bundles != (expected_ui_bundle, expected_ui_runner)
        or native_document["toolchain"] != installed_ui_document["toolchain"]
    ):
        fail("plan installed UI products differ from the qualification authority")
    installed_ui_app = installed_ui_artifacts["app"]
    if (
        installed_ui_app["path"] != authority["source_app_path"]
        or installed_ui_app["closed_tree_sha256"]
        != candidate_application.closed_tree_sha256
        or installed_ui_app["executable_sha256"]
        != candidate_application.executable_sha256
    ):
        fail("plan installed UI preparation app differs from the candidate")
    installed_ui_authority = {
        "installed_ui_runner_closed_tree_sha256": installed_ui_artifacts[
            "ui_runner"
        ]["closed_tree_sha256"],
        "installed_ui_runner_executable_sha256": installed_ui_artifacts[
            "ui_runner"
        ]["executable_sha256"],
        "installed_ui_runner_path": installed_ui_artifacts["ui_runner"]["path"],
        "installed_ui_test_bundle_closed_tree_sha256": installed_ui_artifacts[
            "ui_test_bundle"
        ]["closed_tree_sha256"],
        "installed_ui_test_bundle_executable_sha256": installed_ui_artifacts[
            "ui_test_bundle"
        ]["executable_sha256"],
        "installed_ui_test_bundle_path": installed_ui_artifacts["ui_test_bundle"][
            "path"
        ],
        "installed_ui_xctestrun_path": str(installed_ui_xctestrun.path),
        "installed_ui_xctestrun_sha256": installed_ui_artifacts["xctestrun"][
            "sha256"
        ],
    }
    for field, expected in installed_ui_authority.items():
        if authority[field] != expected:
            fail(f"plan authority {field} differs from the installed UI receipt")
    task10_paths = _installed_task10_paths(evidence_root)
    for field, expected in task10_paths.items():
        if Path(authority[field]) != expected:
            fail(f"plan authority {field} differs from its governed Task10 path")
        if require_outputs_absent:
            _canonical_absent_path(
                expected,
                root=evidence_root,
                label=f"plan authority {field}",
            )
    if Path(authority["pending_state_path"]).name != "transaction.json":
        fail("plan authority pending state does not use transaction.json")
    for field in (
        "artifact_root_path",
        "candidate_identity_path",
        "installed_app_path",
        "installed_ui_preparation_receipt_path",
        "installed_ui_runner_path",
        "installed_ui_test_bundle_path",
        "installed_ui_xctestrun_path",
        "native_preparation_receipt_path",
        "native_xctestrun_path",
        "pending_state_path",
        "qualification_receipt_path",
        "source_app_path",
    ):
        if _paths_overlap(evidence_root, Path(authority[field])):
            fail(f"plan evidence root overlaps authority {field}")
    if _paths_overlap(
        Path(authority["installed_app_path"]), Path(authority["source_app_path"])
    ):
        fail("plan installed and source apps are not physically separated")
    for protected_field in (
        "artifact_root_path",
        "candidate_identity_path",
        "installed_app_path",
        "installed_ui_preparation_receipt_path",
        "installed_ui_runner_path",
        "installed_ui_test_bundle_path",
        "installed_ui_xctestrun_path",
        "native_preparation_receipt_path",
        "native_xctestrun_path",
        "pending_state_path",
        "qualification_receipt_path",
        "source_app_path",
    ):
        if _paths_overlap(qualification_output_root, Path(authority[protected_field])):
            fail(f"plan qualification output root overlaps authority {protected_field}")
    expected_outputs = _primary_output_paths(evidence_root)
    expected_argv = _build_gate_argv(
        authority=authority,
        authority_sha256=authority_sha256,
        evidence_root=evidence_root,
        outputs=expected_outputs,
    )
    gates = plan.get("gates")
    if not isinstance(gates, list):
        fail("plan gates must be a list")
    observed_ids = [item.get("gate_id") if isinstance(item, dict) else None for item in gates]
    if tuple(observed_ids) != GATE_IDS:
        fail("plan must contain every required gate exactly once in sorted order")
    output_paths: set[Path] = set()
    operation_groups: dict[str, list[dict[str, Any]]] = {}
    for item in gates:
        record = _closed(item, GATE_FIELDS, label="plan gate")
        gate_id = record["gate_id"]
        if record.get("authority_sha256") != authority_sha256:
            fail(f"gate {gate_id} authority binding differs")
        if record.get("operation_id") != FIXED_OPERATION_IDS[gate_id]:
            fail(f"gate {gate_id} operation identity differs")
        if tuple(record.get("depends_on", ())) != FIXED_DEPENDENCIES[gate_id]:
            fail(f"gate {gate_id} dependency ordering differs")
        if record.get("timeout_seconds") != FIXED_TIMEOUTS[gate_id]:
            fail(f"gate {gate_id} timeout differs from the fixed bound")
        environment = record.get("environment")
        if not isinstance(environment, dict) or set(environment) != ENVIRONMENT_KEYS:
            fail(f"gate {gate_id} environment is not the closed allowlist")
        if environment != _fixed_environment(authority_sha256):
            fail(f"gate {gate_id} environment values differ")
        normalized_argv = _validate_argv(record.get("argv"), gate_id=gate_id)
        if normalized_argv != list(expected_argv[gate_id]):
            fail(f"gate {gate_id} argv differs from the canonical reconstruction")
        output = _closed(record.get("output"), OUTPUT_FIELDS, label=f"gate {gate_id} output")
        if (
            output.get("kind") != FIXED_OUTPUT_KINDS[gate_id]
            or output.get("maximum_bytes")
            != FIXED_OUTPUT_MAXIMUM_BYTES[gate_id]
            or output.get("publication") != "create-only"
        ):
            fail(f"gate {gate_id} output contract differs")
        path = Path(_safe_text(output.get("path"), label=f"gate {gate_id} output path"))
        if path != expected_outputs[gate_id]:
            fail(f"gate {gate_id} output path differs from the governed filename")
        governed_root = (
            qualification_output_root if gate_id == "signing" else evidence_root
        )
        try:
            relative = path.relative_to(governed_root)
        except ValueError:
            fail(f"gate {gate_id} output escapes its governed output root")
        if not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
            fail(f"gate {gate_id} output path is not normalized")
        if path in output_paths:
            fail("plan gate output paths must be distinct")
        if require_outputs_absent:
            _canonical_absent_path(
                path,
                root=governed_root,
                label=f"gate {gate_id} output",
                direct_child=(gate_id == "signing"),
            )
        output_paths.add(path)
        operation_groups.setdefault(record["operation_id"], []).append(record)
    shared_operations = {
        "cli-gui-operability": {"cli", "gui"},
        "renderer-dual": {"forced-legacy-grid", "full-surface"},
    }
    for operation_id, expected_gate_ids in shared_operations.items():
        group = operation_groups.get(operation_id)
        if group is None or {item["gate_id"] for item in group} != expected_gate_ids:
            fail(f"shared operation {operation_id} owns the wrong gates")
        if any(item["argv"] != group[0]["argv"] for item in group[1:]):
            fail(f"shared operation {operation_id} does not use one exact argv")
        if any(
            item["depends_on"] != group[0]["depends_on"] for item in group[1:]
        ):
            fail(f"shared operation {operation_id} has inconsistent dependencies")
    if any(
        len(items) != 1
        for operation_id, items in operation_groups.items()
        if operation_id not in shared_operations
    ):
        fail("a non-shared operation is duplicated")
    if require_outputs_absent:
        for gate_id, envelope in _ws24_envelope_paths(evidence_root).items():
            _canonical_absent_path(
                envelope,
                root=qualification_output_root,
                label=f"gate {gate_id} WS24 acceptance envelope",
                direct_child=True,
            )
    return plan


def load_plan(path: Path) -> tuple[dict[str, Any], str]:
    """Load and structurally validate a canonical schema-1 plan.

    The transaction and result-manifest lanes may import this function instead
    of implementing a second JSON parser.  Physical gate outputs are allowed to
    exist when reopening a completed plan.
    """

    snapshot = _stable_file(path, maximum_bytes=MAXIMUM_PLAN_BYTES, label="gate plan")
    document = _decode_canonical(snapshot.payload, label="gate plan")
    return validate_plan_document(document), _sha256(snapshot.payload)


def _revalidate_inputs(inputs: CompilationInputs) -> None:
    _require_unchanged(
        inputs.qualification_receipt,
        maximum_bytes=MAXIMUM_INPUT_BYTES,
        label="qualification receipt",
    )
    _require_unchanged(
        inputs.candidate_file,
        maximum_bytes=MAXIMUM_INPUT_BYTES,
        label="candidate identity",
    )
    _require_unchanged(
        inputs.native_preparation_receipt,
        maximum_bytes=MAXIMUM_INPUT_BYTES,
        label="native preparation receipt",
    )
    _require_unchanged(
        inputs.native_xctestrun,
        maximum_bytes=MAXIMUM_XCTESTRUN_BYTES,
        label="native prepared xctestrun",
    )
    _require_unchanged(
        inputs.installed_ui_preparation_receipt,
        maximum_bytes=MAXIMUM_INPUT_BYTES,
        label="installed UI preparation receipt",
    )
    _require_unchanged(
        inputs.installed_ui_xctestrun,
        maximum_bytes=MAXIMUM_XCTESTRUN_BYTES,
        label="installed UI prepared xctestrun",
    )
    try:
        installer._require_same_file(
            inputs.pending_state_file,
            phase="installed acceptance plan publication",
            maximum_bytes=installer.MAX_PENDING_TRANSACTION_BYTES,
        )
        installer._require_source_unchanged(
            inputs.source_authority,
            phase="installed acceptance plan publication",
        )
        installed = installer._capture_exact_bundle(inputs.installed_app)
        if not installer._snapshot_matches_record(
            installed, inputs.pending_state["candidate_identity"]
        ):
            fail("installed candidate changed before plan publication")
        installer._validate_destination_identity(
            inputs.pending_state["destination_identity"],
            inputs.installed_app,
            snapshot=installed,
        )
    except (OSError, ValueError, installer.InstallationError) as error:
        fail(f"authority changed before plan publication: {error}")


def _publish_plan(path: Path, document: dict[str, Any]) -> None:
    payload = canonical_bytes(document)
    if len(payload) > MAXIMUM_PLAN_BYTES:
        fail("installed acceptance gate plan exceeds one MiB")
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    descriptor = -1
    created_identity: tuple[int, int] | None = None
    succeeded = False
    try:
        descriptor = os.open(path, flags, 0o600)
        created = os.fstat(descriptor)
        created_identity = (created.st_dev, created.st_ino)
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                fail("plan publication write made no progress")
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or stat.S_ISLNK(metadata.st_mode)
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_size != len(payload)
        ):
            fail("published plan identity is invalid")
        observed, digest = load_plan(path)
        if observed != document or digest != _sha256(payload):
            fail("published plan bytes differ from the compiled document")
        directory = os.open(
            path.parent,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        succeeded = True
    except OSError as error:
        fail(f"plan could not be published create-only: {error}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if created_identity is not None and not succeeded:
            try:
                metadata = path.lstat()
                if (metadata.st_dev, metadata.st_ino) == created_identity:
                    path.unlink()
            except FileNotFoundError:
                pass


def compile_and_publish(arguments: argparse.Namespace) -> Path:
    inputs = _load_inputs(arguments)
    plan = compile_plan_document(inputs)
    first = canonical_bytes(plan)
    if canonical_bytes(compile_plan_document(inputs)) != first:
        fail("installed acceptance gate plan is not deterministic")
    _revalidate_inputs(inputs)
    _publish_plan(inputs.output_path, plan)
    return inputs.output_path


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qualification-receipt", required=True, type=Path)
    parser.add_argument("--candidate-artifact-root", required=True, type=Path)
    parser.add_argument("--installation-pending-state", required=True, type=Path)
    parser.add_argument("--evidence-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    tokens = list(sys.argv[1:] if argv is None else argv)
    required_flags = (
        "--qualification-receipt",
        "--candidate-artifact-root",
        "--installation-pending-state",
        "--evidence-root",
        "--output",
    )
    for flag in required_flags:
        if tokens.count(flag) > 1:
            parser.error(f"{flag} must appear exactly once")
        if any(token.startswith(f"{flag}=") for token in tokens):
            parser.error(f"{flag} must use a separate value token")
    return parser.parse_args(tokens)


def main(argv: list[str] | None = None) -> int:
    try:
        output = compile_and_publish(parse_arguments(argv))
    except (CanonicalJSONError, OSError, ValueError, PlanCompilationError) as error:
        diagnostic = str(error).replace("\n", " ").replace("\x00", "�")[:1_024]
        print(
            f"ERROR: installed acceptance gate plan compilation failed: {diagnostic}",
            file=sys.stderr,
        )
        return 1
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
