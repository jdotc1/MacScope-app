#!/usr/bin/env python3
"""Emit a deterministic WS-24 installed-app qualification report.

This command is the Phase F report-output path. It gathers evidence that can be
derived from the installed app bundle, merges supplied live-run evidence, derives
composite security/toolchain gates, evaluates the complete WS-24 gate set, and
writes a deterministic JSON report artifact.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
import platform
import plistlib
import re
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, NoReturn

from Scripts.reconstruction import (
    install_release_to_applications as installer,
    installed_matrix_receipt,
)
from Scripts.reconstruction_gate_f.receipt_validator import QualificationRunAuthority
from Scripts.reconstruction_gate_f.canonical_json import (
    CanonicalJSONError,
    canonical_bytes,
    decode_canonical_bytes,
)
from Scripts.reconstruction_gate_f.schema import (
    candidate_identity_sha256,
    parse_candidate_identity,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SIGNING_GUARD = REPOSITORY_ROOT / "Scripts" / "check_local_signing_policy.py"
PROVENANCE_NAME = "MacScopeBuildProvenance.json"
EXECUTABLE_NAME = "MacScope"
SHELL_BROKER_RELATIVE = Path(
    "Contents/XPCServices/ShellBrokerXPCService.xpc/Contents/MacOS/"
    "ShellBrokerXPCService"
)
SHELL_BROKER_INFO_RELATIVE = Path(
    "Contents/XPCServices/ShellBrokerXPCService.xpc/Contents/Info.plist"
)
SHELL_BROKER_BUNDLE_IDENTIFIER = "org.macscope.app.ShellBroker"
SHELL_BROKER_SERVICE_IDENTIFIER = "terminal.human_pty.shell_broker"
SHELL_BROKER_WIRE_PROTOCOL = "macscope.phase2.shell_broker.xpc.v4"
FULL_SURFACE_MODE = "defaultFullGhosttySurface"
LEGACY_GRID_MODE = "forcedLegacyGridRecoveryOverride"
FULL_SURFACE_BACKEND = "ghosttyFullSurface"
LEGACY_GRID_BACKEND = "macScopeGhosttyVTGrid"
LEGACY_GRID_REASON = "recoveryOverride"
INSTALLED_SHELL_REPORT_SCHEMA_VERSION = 5
OPERABILITY_REPORT_SCHEMA_VERSION = 1
INSTALLED_QUALIFICATION_REPORT_SCHEMA_VERSION = 5
CLI_GUI_OPERABILITY_REPORT_KIND = "macscope-cli-gui-operability-report-v1"
MCP_OPERABILITY_REPORT_KIND = "macscope-mcp-operability-report-v1"
NATIVE_XPC_EXECUTION_REPORT_NAME = "NativeDecompilerLiveXPC.execution-report.json"
LIVE_EVIDENCE_NAME = "live-evidence.json"
MAXIMUM_OPERABILITY_JSON_BYTES = 4 * 1024 * 1024
MAXIMUM_OPERABILITY_OUTPUT_BYTES = 64 * 1024
MAXIMUM_INSTALLED_QUALIFICATION_OUTPUT_BYTES = 8 * 1024 * 1024
MAXIMUM_ACCEPTANCE_GATE_OUTPUT_BYTES = 1024 * 1024
REQUIRED_ACCEPTANCE_GATES = installer.REQUIRED_ACCEPTANCE_GATES
ACCEPTANCE_GATE_INPUT_FIELDS = installer.ACCEPTANCE_GATE_INPUT_FIELDS
OPERABILITY_AUTHORITY_FIELDS = frozenset(
    {
        "applicationExecutableSHA256",
        "buildProvenanceSHA256",
        "candidateFileSHA256",
        "candidateIdentitySHA256",
        "destinationIdentitySHA256",
        "executionIdentitySHA256",
        "exposedAtUnixNanoseconds",
        "forcedLegacyGridReportSHA256",
        "fullSurfaceReportSHA256",
        "installedExecutableSHA256",
        "installationPendingStateSHA256",
        "nativeLiveXPCReportSHA256",
        "predecessorObservationsSHA256",
        "qualificationRunID",
        "shellBrokerExecutableSHA256",
        "shellBrokerInfoPlistSHA256",
        "sourceCommit",
        "sourceEqualitySHA256",
        "sourceTree",
        "transactionID",
    }
)
OPERABILITY_REPORT_FIELDS = frozenset(
    {"authority", "probeResults", "reportKind", "schemaVersion", "status"}
)
CLI_GUI_PROBE_FIELDS = frozenset({"cli", "gui"})
MCP_PROBE_FIELDS = frozenset({"initialize", "readOnlyInfo", "toolsList"})
RENDERER_EVIDENCE_FIELDS = frozenset(
    {
        "fallbackReason",
        "rendererPresented",
        "requestedMode",
        "selectedBackend",
        "shellProcessIdentifier",
        "shellRequestID",
        "shellSessionID",
        "transcriptOnlyFallbackPresented",
    }
)
REQUIRED_SHELL_COMMANDS = frozenset(
    {
        "attachDurableSession",
        "cleanupProcess",
        "commitDurableSession",
        "detachDurableSession",
        "durableSessionStatus",
        "heartbeatDurableSession",
        "launchDurableProcess",
        "launchProcess",
        "pollTranscript",
        "reconnectSession",
        "resizeTerminal",
        "sendSignal",
        "writeInput",
    }
)
INSTALLED_SELECTOR_CATALOG = REPOSITORY_ROOT / "Scripts/acceptance/installed_selectors.json"
INSTALLED_SELECTOR_COUNT = 22
INSTALLED_UI_TEST_TARGET = "MacScopeInstalledAppUITests"
INSTALLED_UI_TEST_SUITE = "WS24InstalledAppUITests"
INSTALLED_SELECTOR_METHOD_PREFIX = "testTask10C"
ACCESSIBILITY_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
REQUIRED_GATES = tuple(
    sorted(
        (
            "sealed-release-provenance",
            "local-signing-policy",
            "source-install-equality",
            "cli-gui-operability",
            "mcp-operability",
            "installed-launch-smoke",
            "direct-debugger-transport-contracts",
            "repeated-launch-detach-stress",
            "repeated-attach-detach-stress",
            "repeated-restart-stress",
            "security-gate",
            "performance-gate",
            "supported-toolchain-matrix",
            "incremental-xcuitest",
        )
    )
)
OPTIONAL_GATES: tuple[str, ...] = ()
STRESS_GATES = {
    "repeated-launch-detach-stress",
    "repeated-attach-detach-stress",
    "repeated-restart-stress",
}
SUPPLIED_LIVE_GATES = {
    "installed-launch-smoke",
    "direct-debugger-transport-contracts",
    "repeated-launch-detach-stress",
    "repeated-attach-detach-stress",
    "repeated-restart-stress",
    "incremental-xcuitest",
    "performance-gate",
}
MINIMUM_ACCEPTED_ATTEMPTS = {
    "repeated-launch-detach-stress": 10,
    "repeated-attach-detach-stress": 10,
    "repeated-restart-stress": 10,
}
PERFORMANCE_THRESHOLDS = {
    "launchDetachMaximumDurationMilliseconds": 15_000,
    "attachDetachMaximumDurationMilliseconds": 15_000,
    "restartMaximumDurationMilliseconds": 20_000,
    "maximumPeakResidentMemoryMegabytes": 2_048,
}
PERFORMANCE_DURATION_THRESHOLD_BY_STRESS_GATE = {
    "repeated-launch-detach-stress": "launchDetachMaximumDurationMilliseconds",
    "repeated-attach-detach-stress": "attachDetachMaximumDurationMilliseconds",
    "repeated-restart-stress": "restartMaximumDurationMilliseconds",
}
LIVE_EXECUTION_REPORT_KIND = "ws24-live-gate-execution-report-v1"
LIVE_EXECUTION_GATES = SUPPLIED_LIVE_GATES - {"incremental-xcuitest"}
LIVE_EXECUTION_REPORT_FIELDS = frozenset(
    {
        "attempts",
        "gate",
        "installedExecutableSHA256",
        "schemaVersion",
        "sourceCommit",
        "sourceTree",
    }
)
LIVE_EXECUTION_ATTEMPT_FIELDS = frozenset(
    {
        "attemptIndex",
        "endedAtUnixMilliseconds",
        "exitCode",
        "failure",
        "peakResidentMemoryMegabytes",
        "scenario",
        "seed",
        "startedAtUnixMilliseconds",
        "timedOut",
    }
)
MAXIMUM_LIVE_EXECUTION_REPORT_BYTES = 1024 * 1024
MAXIMUM_LIVE_FAILURE_UTF8_BYTES = 512


class ReportError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise ReportError(message)


def parse_arguments(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Emit the WS-24 installed-app qualification report."
    )
    parser.add_argument(
        "--installed-app",
        type=Path,
        default=Path("/Applications/MacScope.app"),
        help="Installed MacScope.app bundle to qualify.",
    )
    parser.add_argument(
        "--source-app",
        type=Path,
        required=True,
        help="Exact accepted source Release app bundle before installation.",
    )
    parser.add_argument(
        "--evidence-json",
        type=Path,
        required=True,
        help=(
            "JSON file containing live-run evidence for gates this command cannot "
            "derive safely from disk, e.g. UI, direct transport, stress, and "
            "performance."
        ),
    )
    parser.add_argument(
        "--candidate-identity",
        type=Path,
        required=True,
        help="Canonical Gate F candidate identity sealed by the installed matrix receipt.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="Destination report JSON path.",
    )
    parser.add_argument(
        "--expected-source-commit",
        required=True,
        help="Exact integration commit sealed into the candidate and installed Release.",
    )
    parser.add_argument(
        "--qualification-run-id",
        required=True,
        help="Exact coordinator-issued installation qualification run ID.",
    )
    parser.add_argument(
        "--qualification-run-nonce",
        required=True,
        help="Exact coordinator-issued installation qualification run nonce.",
    )
    parser.add_argument(
        "--installation-pending-state",
        type=Path,
        required=True,
        help="Canonical schema-3 installer pending transaction state.",
    )
    parser.add_argument(
        "--full-surface-report",
        type=Path,
        required=True,
        help="Installed shell schema-5 full Ghostty surface report.",
    )
    parser.add_argument(
        "--legacy-grid-report",
        type=Path,
        required=True,
        help="Installed shell schema-5 forced legacy-grid report.",
    )
    parser.add_argument(
        "--cli-gui-operability-report",
        type=Path,
        required=True,
        help="Candidate-bound CLI/GUI operability report.",
    )
    parser.add_argument(
        "--mcp-operability-report",
        type=Path,
        required=True,
        help="Candidate-bound MCP operability report.",
    )
    parser.add_argument(
        "--native-xpc-execution-report",
        type=Path,
        required=True,
        help="NativeDecompilerLiveXPC schema-2 execution report.",
    )
    parser.add_argument(
        "--acceptance-gate-output",
        action="append",
        default=[],
        metavar="GATE_ID=/ABSOLUTE/CANONICAL.json",
        help="Create-only installer acceptance-gate envelope (exactly eight required).",
    )
    parser.add_argument(
        "--generated-at-unix-ms",
        type=int,
        default=None,
        help="Deterministic timestamp override for tests/replay.",
    )
    parser.add_argument(
        "--xcode-developer-dir",
        type=Path,
        default=None,
        help=(
            "Developer directory to validate for the supported-toolchain gate. "
            "Defaults to DEVELOPER_DIR, then xcode-select -p."
        ),
    )
    return parser.parse_args(arguments)


def executable_url(app: Path) -> Path:
    return app / "Contents" / "MacOS" / EXECUTABLE_NAME


def provenance_url(app: Path) -> Path:
    return app / "Contents" / "Resources" / PROVENANCE_NAME


def validate_app_bundle(app: Path, label: str) -> Path:
    if not app.is_absolute():
        fail(f"{label} app path must be absolute")
    if app.suffix != ".app" or app.is_symlink() or not app.is_dir():
        fail(f"{label} app must be an existing non-symlink .app directory")
    executable = executable_url(app)
    if executable.is_symlink() or not executable.is_file():
        fail(f"{label} executable must be an existing non-symlink regular file")
    return executable


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_lowercase_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def is_lowercase_git_oid(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 40
        and all(character in "0123456789abcdef" for character in value)
    )


def shell_broker_url(app: Path) -> Path:
    return app / SHELL_BROKER_RELATIVE


def _stable_metadata(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _read_stable_regular_file(
    path: Path,
    *,
    label: str,
    maximum_bytes: int,
) -> tuple[bytes, str]:
    if not path.is_absolute():
        fail(f"{label} path must be absolute")
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            fail(f"{label} must be one ordinary, non-hardlinked file")
        if before.st_size <= 0 or before.st_size > maximum_bytes:
            fail(f"{label} exceeds its bounded file-size contract")
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            block = os.read(descriptor, min(1024 * 1024, remaining))
            if not block:
                break
            chunks.append(block)
            remaining -= len(block)
        after_descriptor = os.fstat(descriptor)
        after_path = path.lstat()
    except OSError as error:
        fail(f"{label} could not be read safely: {error}")
    finally:
        os.close(descriptor)
    payload = b"".join(chunks)
    if (
        _stable_metadata(before) != _stable_metadata(after_descriptor)
        or _stable_metadata(before) != _stable_metadata(after_path)
        or len(payload) != before.st_size
    ):
        fail(f"{label} changed while it was read")
    return payload, hashlib.sha256(payload).hexdigest()


def _sha256_stable_regular_file(path: Path, *, label: str) -> str:
    if not path.is_absolute():
        fail(f"{label} path must be absolute")
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    digest = hashlib.sha256()
    observed_size = 0
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            fail(f"{label} must be one ordinary, non-hardlinked file")
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            digest.update(block)
            observed_size += len(block)
        after_descriptor = os.fstat(descriptor)
        after_path = path.lstat()
    except OSError as error:
        fail(f"{label} could not be hashed safely: {error}")
    finally:
        os.close(descriptor)
    if (
        before.st_size <= 0
        or observed_size != before.st_size
        or _stable_metadata(before) != _stable_metadata(after_descriptor)
        or _stable_metadata(before) != _stable_metadata(after_path)
    ):
        fail(f"{label} changed while it was hashed")
    return digest.hexdigest()


def _duplicate_free_json(payload: bytes, *, label: str) -> Any:
    def closed_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                fail(f"{label} contains duplicate JSON key {key!r}")
            result[key] = value
        return result

    def reject_constant(value: str) -> NoReturn:
        fail(f"{label} contains forbidden JSON constant {value}")

    try:
        return json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=closed_object,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{label} is invalid JSON: {error}")


def _load_bounded_json(
    path: Path,
    *,
    label: str,
    canonical: bool = False,
    maximum_bytes: int = MAXIMUM_OPERABILITY_JSON_BYTES,
) -> tuple[dict[str, Any], str, bytes]:
    payload, digest = _read_stable_regular_file(
        path,
        label=label,
        maximum_bytes=maximum_bytes,
    )
    try:
        document = decode_canonical_bytes(payload) if canonical else _duplicate_free_json(
            payload, label=label
        )
    except CanonicalJSONError as error:
        fail(f"{label} is not canonical JSON: {error}")
    if not isinstance(document, dict):
        fail(f"{label} must be a JSON object")
    return document, digest, payload


def _load_canonical_live_evidence(path: Path) -> tuple[Any, str]:
    if path.name != LIVE_EVIDENCE_NAME:
        fail("live evidence must use the governed live-evidence.json filename")
    payload, digest = _read_stable_regular_file(
        path,
        label="live evidence",
        maximum_bytes=MAXIMUM_OPERABILITY_JSON_BYTES,
    )
    try:
        document = decode_canonical_bytes(payload)
    except CanonicalJSONError as error:
        fail(f"live evidence is not canonical JSON: {error}")
    if not isinstance(document, (dict, list)):
        fail("live evidence must be a JSON object or list")
    return document, digest


def _canonical_uuid(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)) == value
    except ValueError:
        return False


def _validate_operability_app(app: Path) -> tuple[Path, str, Path, str, str]:
    executable = validate_app_bundle(app, "installed")
    if not os.access(executable, os.X_OK):
        fail("installed executable is not executable")
    broker = shell_broker_url(app)
    broker_digest = _sha256_stable_regular_file(
        broker, label="installed ShellBroker executable"
    )
    if not os.access(broker, os.X_OK):
        fail("installed ShellBroker executable is not executable")
    info_path = app / SHELL_BROKER_INFO_RELATIVE
    info_bytes, info_digest = _read_stable_regular_file(
        info_path,
        label="installed ShellBroker Info.plist",
        maximum_bytes=1024 * 1024,
    )
    try:
        info = plistlib.loads(info_bytes)
    except (plistlib.InvalidFileException, TypeError, ValueError) as error:
        fail(f"installed ShellBroker Info.plist is invalid: {error}")
    if (
        not isinstance(info, dict)
        or info.get("CFBundleIdentifier") != SHELL_BROKER_BUNDLE_IDENTIFIER
        or info.get("CFBundleExecutable") != "ShellBrokerXPCService"
    ):
        fail("installed ShellBroker bundle identity is invalid")
    executable_digest = _sha256_stable_regular_file(
        executable, label="installed MacScope executable"
    )
    return executable, executable_digest, broker, broker_digest, info_digest


def _load_candidate_operability_authority(
    candidate_path: Path,
    *,
    expected_source_commit: str,
    installed_executable_sha256: str,
    shell_broker_executable_sha256: str,
) -> tuple[Any, str, str]:
    document, candidate_file_sha256, _ = _load_bounded_json(
        candidate_path,
        label="candidate identity",
        canonical=True,
    )
    candidate, issues = parse_candidate_identity(document)
    if candidate is None or issues:
        first = issues[0] if issues else None
        suffix = f" ({first.code} at {first.path})" if first is not None else ""
        fail(f"candidate identity is invalid{suffix}")
    embedded = {
        item.identity_id: item.sha256
        for item in candidate.application.embedded_executables
    }
    if (
        candidate.source.commit != expected_source_commit
        or candidate.source.dirty
        or candidate.application.executable_sha256
        != installed_executable_sha256
        or embedded.get("shell-broker") != shell_broker_executable_sha256
    ):
        fail("candidate identity does not match the installed operability subject")
    return candidate, candidate_identity_sha256(candidate), candidate_file_sha256


def _load_operability_provenance(
    app: Path,
    *,
    source_commit: str,
    source_tree: str,
) -> tuple[dict[str, Any], str]:
    document, digest, _ = _load_bounded_json(
        provenance_url(app),
        label="installed Release provenance",
        maximum_bytes=1024 * 1024,
    )
    if (
        document.get("schema_version") != 1
        or document.get("qualification_eligible") is not True
        or document.get("configuration") != "Release"
        or document.get("repository_clean") is not True
        or document.get("git_head_commit") != source_commit
        or document.get("git_head_tree") != source_tree
        or not is_lowercase_sha256(document.get("selected_build_inputs_sha256"))
        or not is_lowercase_sha256(document.get("project_yml_sha256"))
        or document.get("architecture") != "arm64"
        or document.get("deployment_target") != "27.0"
        or document.get("ghostty_surface_compilation_condition")
        != "MACSCOPE_FULL_GHOSTTY_SURFACE"
    ):
        fail("installed Release provenance does not match the exact integration candidate")
    return document, digest


def _validate_installed_shell_report(
    path: Path,
    *,
    label: str,
    expected_mode: str,
    installed_executable: Path,
    installed_executable_sha256: str,
    source_commit: str,
    source_tree: str,
    provenance_sha256: str,
    exposed_at_unix_ns: int,
) -> tuple[str, int, str, str, str]:
    report, digest, _ = _load_bounded_json(
        path,
        label=label,
        maximum_bytes=MAXIMUM_OPERABILITY_JSON_BYTES,
    )
    required_fields = {
        "appExecutablePath",
        "appExecutableSHA256",
        "acceptedTranscriptEventCount",
        "buildProvenanceSHA256",
        "cleanupObservedProcessAbsent",
        "generatedAtUnixMilliseconds",
        "launchedProcessIdentifier",
        "observedReply",
        "reconnectAcceptedTranscriptEventCount",
        "rendererEvidence",
        "schemaVersion",
        "shellBrokerServiceIdentifier",
        "shellBrokerWireProtocol",
        "sourceCommit",
        "sourceTree",
        "status",
        "supportedCommands",
    }
    status = report.get("status")
    allowed_fields = required_fields if status == "passed" else required_fields | {"error"}
    if status != "passed":
        required_fields = required_fields | {"error"}
    missing = sorted(required_fields - set(report))
    unknown = sorted(set(report) - allowed_fields)
    if missing or unknown:
        fail(f"{label} is not a closed schema-5 report; missing={missing}, unknown={unknown}")
    if status != "passed" and (
        not isinstance(report.get("error"), str) or not report["error"].strip()
    ):
        fail(f"{label} failure must retain a non-empty error")
    renderer = require_closed_record(
        report.get("rendererEvidence"),
        RENDERER_EVIDENCE_FIELDS,
        path=f"{label} renderer evidence",
    )
    expected_backend, expected_reason = {
        FULL_SURFACE_MODE: (FULL_SURFACE_BACKEND, None),
        LEGACY_GRID_MODE: (LEGACY_GRID_BACKEND, LEGACY_GRID_REASON),
    }[expected_mode]
    generated = report.get("generatedAtUnixMilliseconds")
    pid = report.get("launchedProcessIdentifier")
    observed_reply = report.get("observedReply")
    accepted_events = report.get("acceptedTranscriptEventCount")
    supported_commands = report.get("supportedCommands")
    supported_commands_are_exact = (
        isinstance(supported_commands, list)
        and all(isinstance(command, str) for command in supported_commands)
        and len(supported_commands) == len(REQUIRED_SHELL_COMMANDS)
        and set(supported_commands) == REQUIRED_SHELL_COMMANDS
    )
    if (
        report.get("schemaVersion") != INSTALLED_SHELL_REPORT_SCHEMA_VERSION
        or status != "passed"
        or report.get("appExecutablePath") != str(installed_executable)
        or report.get("appExecutableSHA256") != installed_executable_sha256
        or report.get("sourceCommit") != source_commit
        or report.get("sourceTree") != source_tree
        or report.get("buildProvenanceSHA256") != provenance_sha256
        or report.get("shellBrokerServiceIdentifier")
        != SHELL_BROKER_SERVICE_IDENTIFIER
        or report.get("shellBrokerWireProtocol") != SHELL_BROKER_WIRE_PROTOCOL
        or not supported_commands_are_exact
        or type(accepted_events) is not int
        or accepted_events < 2
        or report.get("reconnectAcceptedTranscriptEventCount") != 1
        or report.get("cleanupObservedProcessAbsent") is not True
        or not isinstance(observed_reply, str)
        or not observed_reply.startswith("reply:")
        or len(observed_reply.encode("utf-8")) > 1024
        or type(pid) is not int
        or pid <= 1
        or type(generated) is not int
        or generated * 1_000_000 < exposed_at_unix_ns
        or renderer.get("requestedMode") != expected_mode
        or renderer.get("selectedBackend") != expected_backend
        or renderer.get("fallbackReason") != expected_reason
        or renderer.get("rendererPresented") is not True
        or renderer.get("transcriptOnlyFallbackPresented") is not False
        or not _canonical_uuid(renderer.get("shellSessionID"))
        or not _canonical_uuid(renderer.get("shellRequestID"))
        or renderer.get("shellProcessIdentifier") != pid
    ):
        fail(f"{label} is transcript-only, historical, or belongs to another installed candidate")
    return (
        digest,
        generated,
        observed_reply,
        renderer["shellSessionID"],
        renderer["shellRequestID"],
    )


def _load_pending_transaction(
    *,
    pending_state: Path,
    installed_app: Path,
    source_app: Path,
    candidate_identity: Path,
    expected_source_commit: str,
    qualification_run_id: str,
    qualification_run_nonce: str,
    retained_pending_state: installer.StableFile | None = None,
) -> tuple[dict[str, Any], installer.StableFile]:
    """Load pending producer authority or explicitly retained BEGIN replay.

    Commit relocates, but does not rewrite, the original transaction file. A
    retained capture may follow that exact file into its one committed root;
    ordinary producers must still observe an active pending transaction.
    """
    if not pending_state.is_absolute() or pending_state.name != "transaction.json":
        fail("installation pending state must be the canonical absolute transaction.json")
    try:
        source_authority = installer._load_source_authority(
            candidate_identity, source_app
        )
        expected_pending = (
            installed_app.parent
            / f".MacScope.pending-{source_authority.candidate_identity_sha256}"
            / "transaction.json"
        )
        if pending_state != expected_pending:
            fail("installation pending state was substituted outside its canonical root")
        terminal_root = None
        retained_document = None
        if retained_pending_state is not None:
            if (
                not isinstance(retained_pending_state, installer.StableFile)
                or retained_pending_state.path != expected_pending
                or type(retained_pending_state.metadata) is not tuple
                or len(retained_pending_state.metadata) != 6
                or any(type(value) is not int or value < 0 for value in retained_pending_state.metadata)
                or type(retained_pending_state.payload) is not bytes
                or len(retained_pending_state.payload) > installer.MAX_PENDING_TRANSACTION_BYTES
            ):
                fail("retained BEGIN state is not the original bounded physical snapshot")
            retained_document = decode_canonical_bytes(retained_pending_state.payload)
            if not isinstance(retained_document, dict) or not is_lowercase_sha256(
                retained_document.get("transaction_id")
            ):
                fail("retained BEGIN state has no canonical transaction identity")
            token = source_authority.candidate_identity_sha256
            committed_root = installer._committed_root(
                installed_app, token, retained_document["transaction_id"]
            )
            committing_root = installed_app.parent / f".MacScope.committing-{token}"
            rolled_back_root = installer._rolled_back_root(
                installed_app, token, retained_document["transaction_id"]
            )

            def require_location(root: Path) -> None:
                pending_exists = installer._path_exists(expected_pending.parent)
                committed_roots = installer._committed_roots(installed_app, token)
                if (
                    installer._path_exists(committing_root)
                    or installer._path_exists(rolled_back_root)
                    or (root == expected_pending.parent and (not pending_exists or committed_roots))
                    or (root == committed_root and (pending_exists or committed_roots != (committed_root,)))
                ):
                    fail("retained BEGIN state has no single exact pending or committed root")

            if installer._path_exists(expected_pending.parent):
                actual_root = expected_pending.parent
            else:
                actual_root = terminal_root = committed_root
            require_location(actual_root)
            canonical_pending = actual_root.resolve(strict=True) / pending_state.name
            if canonical_pending.parent != actual_root:
                fail("retained installation root traverses a noncanonical path")
        else:
            canonical_pending = pending_state.parent.resolve(strict=True) / pending_state.name
        state, snapshot = installer._pending_read_stable(canonical_pending.parent)
        if retained_pending_state is not None and (
            snapshot.payload != retained_pending_state.payload
            or snapshot.metadata != retained_pending_state.metadata
            or state != retained_document
        ):
            fail("replayed transaction is not the original BEGIN bytes and physical identity")
        run_authority = QualificationRunAuthority(
            run_id=qualification_run_id,
            nonce=qualification_run_nonce,
        )
        installer._pending_validate_state(
            state,
            authority=source_authority,
            token=source_authority.candidate_identity_sha256,
            installed_app=installed_app,
            source_app=source_app,
            artifact_root=Path(str(state.get("artifact_root", ""))),
            qualification_run=run_authority,
            predecessor_observations_sha256=str(
                state.get("predecessor_observations_sha256", "")
            ),
        )
        if retained_pending_state is not None:
            root_metadata = installer._directory_anchor(
                canonical_pending.parent, label="retained installation root"
            )
            terminal_files = []
            if terminal_root is not None:
                marker, marker_file = installer._read_commit_authority(
                    terminal_root, state=state, state_file=snapshot
                )
                receipt_file = installer._validate_acceptance_receipt(
                    state=state,
                    state_file=snapshot,
                    artifact_root=Path(state["artifact_root"]),
                    reader=installer._read_acceptance_receipt_file,
                )
                if marker["acceptance_receipt_sha256"] != hashlib.sha256(receipt_file.payload).hexdigest():
                    fail("committed authority does not bind the physical acceptance receipt")
                terminal_files = [
                    (marker_file, installer.MAX_COMMIT_AUTHORITY_BYTES),
                    (receipt_file, installer.MAX_ACCEPTANCE_RECEIPT_BYTES),
                ]
            installed = installer._capture_exact_bundle(installed_app)
            if not installer._snapshot_matches_record(installed, state["candidate_identity"]):
                fail("replayed installed candidate differs from retained BEGIN authority")
            installer._validate_destination_identity(
                state["destination_identity"], installed_app, snapshot=installed
            )
            installer._require_source_unchanged(
                source_authority, phase="retained installation replay"
            )
            final_installed = installer._capture_exact_bundle(installed_app)
            if (
                not installer._snapshot_matches_record(final_installed, state["candidate_identity"])
                or not installer._same_relocated_directory_identity(final_installed, installed)
            ):
                fail("installed candidate changed during retained installation replay")
            installer._validate_destination_identity(
                state["destination_identity"], installed_app, snapshot=final_installed
            )
            for file, maximum in [(snapshot, installer.MAX_PENDING_TRANSACTION_BYTES), *terminal_files]:
                installer._require_same_file(
                    file, phase="retained installation final fence", maximum_bytes=maximum
                )
            installer._require_directory_identity(
                canonical_pending.parent,
                (root_metadata.st_dev, root_metadata.st_ino),
                label="retained installation root",
            )
            require_location(canonical_pending.parent)
    except (OSError, CanonicalJSONError, installer.InstallationError) as error:
        fail(f"installation pending state is invalid: {error}")
    if snapshot.path != canonical_pending or (
        retained_pending_state is None and pending_state != canonical_pending
    ):
        fail("installation pending state path is not canonical")
    if state.get("source_commit") != expected_source_commit:
        fail("installation pending state source commit differs")
    if state.get("qualification_run_id") != qualification_run_id:
        fail("installation pending state qualification run ID differs")
    if state.get("qualification_run_nonce") != qualification_run_nonce:
        fail("installation pending state qualification run nonce differs")
    if snapshot.metadata[4] < state["exposed_at_unix_ns"]:
        fail("installation pending state predates candidate exposure")
    return state, snapshot


def _validate_native_xpc_execution_report(
    path: Path,
    *,
    state: dict[str, Any],
) -> tuple[str, int, int]:
    if path.name != NATIVE_XPC_EXECUTION_REPORT_NAME:
        fail("native-XPC execution report must use its governed filename")
    report, digest, _ = _load_bounded_json(
        path,
        label="native-XPC execution report",
        canonical=True,
        maximum_bytes=MAXIMUM_ACCEPTANCE_GATE_OUTPUT_BYTES,
    )
    report = require_closed_record(
        report,
        frozenset(
            {
                "ended_at_unix_ms",
                "exit_code",
                "predecessor_observations_sha256",
                "qualification_run",
                "result",
                "schema_version",
                "started_at_unix_ms",
                "stress",
            }
        ),
        path="native-XPC execution report",
    )
    run = require_closed_record(
        report.get("qualification_run"),
        frozenset({"nonce", "run_id"}),
        path="native-XPC qualification run",
    )
    started = report.get("started_at_unix_ms")
    ended = report.get("ended_at_unix_ms")
    if (
        report.get("schema_version") != 2
        or report.get("result") != "passed"
        or report.get("exit_code") != 0
        or report.get("stress") is not None
        or run
        != {
            "nonce": state["qualification_run_nonce"],
            "run_id": state["qualification_run_id"],
        }
        or report.get("predecessor_observations_sha256")
        != state["predecessor_observations_sha256"]
        or type(started) is not int
        or type(ended) is not int
        or started < 0
        or ended < started
        or started * 1_000_000 < state["exposed_at_unix_ns"]
    ):
        fail("native-XPC execution report failed, predates exposure, or belongs to another run")
    return digest, started * 1_000_000, ended * 1_000_000


def validate_operability_authority(
    *,
    installed_app: Path,
    source_app: Path,
    candidate_identity: Path,
    expected_source_commit: str,
    qualification_run_id: str,
    qualification_run_nonce: str,
    installation_pending_state: Path,
    full_surface_report: Path,
    legacy_grid_report: Path,
    native_xpc_execution_report: Path,
    retained_pending_state: installer.StableFile | None = None,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, tuple[str, int, int]]]:
    if not is_lowercase_git_oid(expected_source_commit):
        fail("expected source commit must be a lowercase 40-hex integration commit")
    (
        executable,
        executable_sha256,
        _,
        broker_sha256,
        broker_info_sha256,
    ) = _validate_operability_app(installed_app)
    state, pending_snapshot = _load_pending_transaction(
        pending_state=installation_pending_state,
        installed_app=installed_app,
        source_app=source_app,
        candidate_identity=candidate_identity,
        expected_source_commit=expected_source_commit,
        qualification_run_id=qualification_run_id,
        qualification_run_nonce=qualification_run_nonce,
        retained_pending_state=retained_pending_state,
    )
    candidate, candidate_digest, candidate_file_sha256 = _load_candidate_operability_authority(
        candidate_identity,
        expected_source_commit=expected_source_commit,
        installed_executable_sha256=executable_sha256,
        shell_broker_executable_sha256=broker_sha256,
    )
    _, provenance_sha256 = _load_operability_provenance(
        installed_app,
        source_commit=candidate.source.commit,
        source_tree=candidate.source.tree,
    )
    (
        full_sha256,
        full_generated,
        full_reply,
        full_session_id,
        full_request_id,
    ) = _validate_installed_shell_report(
        full_surface_report,
        label="full-surface installed shell report",
        expected_mode=FULL_SURFACE_MODE,
        installed_executable=executable,
        installed_executable_sha256=executable_sha256,
        source_commit=candidate.source.commit,
        source_tree=candidate.source.tree,
        provenance_sha256=provenance_sha256,
        exposed_at_unix_ns=state["exposed_at_unix_ns"],
    )
    (
        legacy_sha256,
        legacy_generated,
        legacy_reply,
        legacy_session_id,
        legacy_request_id,
    ) = _validate_installed_shell_report(
        legacy_grid_report,
        label="forced legacy-grid installed shell report",
        expected_mode=LEGACY_GRID_MODE,
        installed_executable=executable,
        installed_executable_sha256=executable_sha256,
        source_commit=candidate.source.commit,
        source_tree=candidate.source.tree,
        provenance_sha256=provenance_sha256,
        exposed_at_unix_ns=state["exposed_at_unix_ns"],
    )
    if full_generated > legacy_generated:
        fail("renderer reports are reversed or mixed across historical runs")
    if (
        full_reply != legacy_reply
        or full_session_id == legacy_session_id
        or full_request_id == legacy_request_id
    ):
        fail("renderer reports do not prove one ordered dual-renderer smoke run")
    native_sha256, native_started, native_ended = _validate_native_xpc_execution_report(
        native_xpc_execution_report,
        state=state,
    )
    destination_identity_sha256 = hashlib.sha256(
        canonical_bytes(state["destination_identity"])
    ).hexdigest()
    authority = {
        "applicationExecutableSHA256": state["application_executable_sha256"],
        "buildProvenanceSHA256": provenance_sha256,
        "candidateFileSHA256": candidate_file_sha256,
        "candidateIdentitySHA256": candidate_digest,
        "destinationIdentitySHA256": destination_identity_sha256,
        "executionIdentitySHA256": state["execution_identity_sha256"],
        "exposedAtUnixNanoseconds": state["exposed_at_unix_ns"],
        "forcedLegacyGridReportSHA256": legacy_sha256,
        "fullSurfaceReportSHA256": full_sha256,
        "installedExecutableSHA256": executable_sha256,
        "installationPendingStateSHA256": hashlib.sha256(
            pending_snapshot.payload
        ).hexdigest(),
        "nativeLiveXPCReportSHA256": native_sha256,
        "predecessorObservationsSHA256": state[
            "predecessor_observations_sha256"
        ],
        "qualificationRunID": state["qualification_run_id"],
        "shellBrokerExecutableSHA256": broker_sha256,
        "shellBrokerInfoPlistSHA256": broker_info_sha256,
        "sourceCommit": candidate.source.commit,
        "sourceEqualitySHA256": state["source_equality_sha256"],
        "sourceTree": candidate.source.tree,
        "transactionID": state["transaction_id"],
    }
    closed_authority = require_closed_record(
        authority,
        OPERABILITY_AUTHORITY_FIELDS,
        path="derived operability authority",
    )
    evidence_times = {
        "full-surface": (full_sha256, full_generated * 1_000_000, full_generated * 1_000_000),
        "forced-legacy-grid": (
            legacy_sha256,
            legacy_generated * 1_000_000,
            legacy_generated * 1_000_000,
        ),
        "native-xpc": (native_sha256, native_started, native_ended),
    }
    return closed_authority, state, evidence_times


def operability_report_document(
    *,
    report_kind: str,
    probe_results: dict[str, bool],
    authority: dict[str, Any],
) -> dict[str, Any]:
    expected_probes = {
        CLI_GUI_OPERABILITY_REPORT_KIND: CLI_GUI_PROBE_FIELDS,
        MCP_OPERABILITY_REPORT_KIND: MCP_PROBE_FIELDS,
    }.get(report_kind)
    if expected_probes is None:
        fail("unknown operability report kind")
    require_closed_record(
        probe_results,
        expected_probes,
        path="operability probe results",
    )
    if any(type(value) is not bool for value in probe_results.values()):
        fail("operability probe results must be Boolean")
    require_closed_record(
        authority,
        OPERABILITY_AUTHORITY_FIELDS,
        path="operability authority",
    )
    return {
        "authority": dict(authority),
        "probeResults": dict(probe_results),
        "reportKind": report_kind,
        "schemaVersion": OPERABILITY_REPORT_SCHEMA_VERSION,
        "status": "passed" if all(probe_results.values()) else "incomplete",
    }


def write_operability_report(output: Path, document: dict[str, Any]) -> tuple[str, int]:
    parent = validate_operability_report_output(output)
    payload = canonical_bytes(document)
    if len(payload) > MAXIMUM_OPERABILITY_OUTPUT_BYTES:
        fail("operability report exceeds its bounded output contract")
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        descriptor = os.open(parent / output.name, flags, 0o600)
        try:
            offset = 0
            while offset < len(payload):
                offset += os.write(descriptor, payload[offset:])
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError as error:
        fail(f"operability report could not be created: {error}")
    return hashlib.sha256(payload).hexdigest(), len(payload)


def validate_operability_report_output(output: Path) -> Path:
    if not output.is_absolute():
        fail("operability report output must be absolute")
    if output.exists() or output.is_symlink():
        fail("operability report output must be absent")
    try:
        parent = output.parent.resolve(strict=True)
        parent_metadata = parent.lstat()
    except OSError as error:
        fail(f"operability report output parent is unavailable: {error}")
    if not stat.S_ISDIR(parent_metadata.st_mode) or stat.S_ISLNK(
        parent_metadata.st_mode
    ):
        fail("operability report output parent must be an ordinary directory")
    return parent


def load_operability_report(
    path: Path,
    *,
    expected_kind: str,
    expected_authority: dict[str, Any],
    require_complete: bool,
) -> tuple[dict[str, Any], str]:
    report, digest, _ = _load_bounded_json(
        path,
        label=f"{expected_kind} evidence",
        canonical=True,
        maximum_bytes=MAXIMUM_OPERABILITY_OUTPUT_BYTES,
    )
    report = require_closed_record(
        report,
        OPERABILITY_REPORT_FIELDS,
        path=f"{expected_kind} evidence",
    )
    expected_probes = (
        CLI_GUI_PROBE_FIELDS
        if expected_kind == CLI_GUI_OPERABILITY_REPORT_KIND
        else MCP_PROBE_FIELDS
        if expected_kind == MCP_OPERABILITY_REPORT_KIND
        else frozenset()
    )
    probes = require_closed_record(
        report.get("probeResults"),
        expected_probes,
        path=f"{expected_kind} probe results",
    )
    authority = require_closed_record(
        report.get("authority"),
        OPERABILITY_AUTHORITY_FIELDS,
        path=f"{expected_kind} authority",
    )
    if (
        report.get("schemaVersion") != OPERABILITY_REPORT_SCHEMA_VERSION
        or report.get("reportKind") != expected_kind
        or report.get("status")
        != ("passed" if all(probes.values()) else "incomplete")
        or any(type(value) is not bool for value in probes.values())
        or authority != expected_authority
        or (require_complete and not all(probes.values()))
    ):
        fail(f"{expected_kind} evidence is incomplete or belongs to another authority")
    return report, digest


def selector_test_method(scenario: str) -> str:
    if not scenario or not scenario[0].islower() or not scenario.isalnum():
        fail(f"installed selector scenario has invalid identifier: {scenario!r}")
    return f"{INSTALLED_SELECTOR_METHOD_PREFIX}{scenario[0].upper()}{scenario[1:]}"


def load_installed_selector_catalog(
    path: Path = INSTALLED_SELECTOR_CATALOG,
) -> list[dict[str, Any]]:
    payload = load_json(path)
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        fail("installed selector catalog must be a schema-version-1 JSON object")
    raw_vectors = payload.get("installedVectors")
    if not isinstance(raw_vectors, list):
        fail("installed selector catalog must contain an installedVectors list")
    if len(raw_vectors) != INSTALLED_SELECTOR_COUNT:
        fail(
            "installed selector catalog must contain exactly "
            f"{INSTALLED_SELECTOR_COUNT} selectors, found {len(raw_vectors)}"
        )

    selectors: list[dict[str, Any]] = []
    for index, raw_vector in enumerate(raw_vectors):
        if not isinstance(raw_vector, dict):
            fail(f"installed selector catalog vector {index} must be an object")
        vector_id = raw_vector.get("vectorID")
        scenario = raw_vector.get("scenario")
        if not isinstance(vector_id, str) or not isinstance(scenario, str):
            fail(f"installed selector catalog vector {index} has invalid identity")
        if vector_id != f"xcui.{scenario}":
            fail(
                f"installed selector catalog vector {index} does not bind "
                "vectorID to scenario"
            )
        if raw_vector.get("executionLayer") != INSTALLED_UI_TEST_TARGET:
            fail(
                f"installed selector catalog vector {vector_id} has the wrong "
                "execution layer"
            )
        if raw_vector.get("requiresInstalledMacOS") is not True:
            fail(
                f"installed selector catalog vector {vector_id} does not require "
                "installed macOS execution"
            )
        required_identifiers = raw_vector.get("requiredIdentifiers")
        if (
            not isinstance(required_identifiers, list)
            or not required_identifiers
            or any(
                not isinstance(identifier, str)
                or not identifier
                or identifier != identifier.strip()
                or ACCESSIBILITY_IDENTIFIER_RE.fullmatch(identifier) is None
                for identifier in required_identifiers
            )
            or len(required_identifiers) != len(set(required_identifiers))
        ):
            fail(
                f"installed selector catalog vector {vector_id} has invalid "
                "requiredIdentifiers"
            )
        method = selector_test_method(scenario)
        selectors.append(
            {
                "method": method,
                "requiredIdentifiers": list(required_identifiers),
                "testIdentifier": f"{INSTALLED_UI_TEST_SUITE}/{method}()",
                "vectorID": vector_id,
            }
        )

    for field in ("method", "testIdentifier", "vectorID"):
        values = [selector[field] for selector in selectors]
        if len(set(values)) != len(values):
            fail(f"installed selector catalog contains duplicate {field} values")
    return sorted(selectors, key=lambda selector: selector["vectorID"])


def installed_selector_projection(
    selectors: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    source = load_installed_selector_catalog() if selectors is None else selectors
    return [
        {
            "required_identifiers": list(selector["requiredIdentifiers"]),
            "test_identifier": selector["testIdentifier"],
            "vector_id": selector["vectorID"],
        }
        for selector in source
    ]


def result_bundle_sha256(path: Path) -> str:
    """Return a deterministic content-tree digest for an xcresult bundle."""

    if path.is_symlink() or not path.is_dir():
        fail("xcresult bundle must be a non-symlink directory")
    records: list[dict[str, Any]] = []
    file_inodes: set[tuple[int, int]] = set()
    for current_root, directories, files in os.walk(path, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        current = Path(current_root)
        for name in directories:
            directory = current / name
            metadata = directory.lstat()
            relative = directory.relative_to(path).as_posix()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                fail(
                    "xcresult bundle contains a non-ordinary directory entry: "
                    f"{relative}"
                )
        for name in files:
            artifact = current / name
            metadata = artifact.lstat()
            relative = artifact.relative_to(path).as_posix()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                fail(
                    "xcresult bundle contains a non-ordinary file entry: "
                    f"{relative}"
                )
            inode = (metadata.st_dev, metadata.st_ino)
            if metadata.st_nlink != 1 or inode in file_inodes:
                fail(f"xcresult bundle contains a hardlinked file: {relative}")
            file_inodes.add(inode)
            records.append(
                {
                    "path": relative,
                    "sha256": sha256_file(artifact),
                    "size": metadata.st_size,
                }
            )
    if not records:
        fail("xcresult bundle must contain at least one ordinary file")
    manifest = json.dumps(
        records,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(manifest).hexdigest()


def evidence(
    gate: str,
    status: str,
    source_commit: str,
    installed_executable_sha256: str,
    accepted_attempts: int = 1,
    proof_artifacts: list[dict[str, Any]] | None = None,
    executed_test_count: int | None = None,
    skipped_test_count: int | None = None,
    source_tree: str | None = None,
    result_bundle_sha256_value: str | None = None,
    executed_selector_ids: list[str] | None = None,
    executed_test_identifiers: list[str] | None = None,
    attempt_seeds: list[int] | None = None,
    duration_milliseconds: int | None = None,
    failure_count: int | None = None,
    maximum_duration_milliseconds_by_scenario: dict[str, int] | None = None,
    maximum_peak_resident_memory_megabytes: int | None = None,
    operability_authority: dict[str, Any] | None = None,
    probe_results: dict[str, bool] | None = None,
) -> dict[str, Any]:
    payload = {
        "acceptedAttempts": accepted_attempts,
        "gate": gate,
        "installedExecutableSHA256": installed_executable_sha256,
        "sourceCommit": source_commit,
        "status": status,
    }
    if proof_artifacts is not None:
        payload["proofArtifacts"] = proof_artifacts
    if executed_test_count is not None:
        payload["executedTestCount"] = executed_test_count
    if skipped_test_count is not None:
        payload["skippedTestCount"] = skipped_test_count
    if source_tree is not None:
        payload["sourceTree"] = source_tree
    if result_bundle_sha256_value is not None:
        payload["resultBundleSHA256"] = result_bundle_sha256_value
    if executed_selector_ids is not None:
        payload["executedSelectorIDs"] = executed_selector_ids
    if executed_test_identifiers is not None:
        payload["executedTestIdentifiers"] = executed_test_identifiers
    if attempt_seeds is not None:
        payload["attemptSeeds"] = attempt_seeds
    if duration_milliseconds is not None:
        payload["durationMilliseconds"] = duration_milliseconds
    if failure_count is not None:
        payload["failureCount"] = failure_count
    if maximum_duration_milliseconds_by_scenario is not None:
        payload["maximumDurationMillisecondsByScenario"] = (
            maximum_duration_milliseconds_by_scenario
        )
    if maximum_peak_resident_memory_megabytes is not None:
        payload["maximumPeakResidentMemoryMegabytes"] = (
            maximum_peak_resident_memory_megabytes
        )
    if operability_authority is not None:
        payload["operabilityAuthority"] = operability_authority
    if probe_results is not None:
        payload["probeResults"] = probe_results
    return payload


def load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except OSError as error:
        fail(f"could not read {path}: {error}")
    except json.JSONDecodeError as error:
        fail(f"could not parse JSON {path}: {error}")


def load_provenance(installed_app: Path) -> dict[str, Any]:
    path = provenance_url(installed_app)
    if path.is_symlink() or not path.is_file():
        fail(f"installed Release provenance is missing: {path}")
    payload = load_json(path)
    if not isinstance(payload, dict):
        fail("installed Release provenance must be a JSON object")
    return payload


def provenance_passed(payload: dict[str, Any], expected_source_commit: str) -> bool:
    return (
        payload.get("schema_version") == 1
        and payload.get("qualification_eligible") is True
        and payload.get("configuration") == "Release"
        and payload.get("git_head_commit") == expected_source_commit
        and is_lowercase_git_oid(payload.get("git_head_tree"))
        and payload.get("repository_clean") is True
        and is_lowercase_sha256(payload.get("selected_build_inputs_sha256"))
        and is_lowercase_sha256(payload.get("project_yml_sha256"))
        and str(payload.get("xcode_version", "")).startswith("27.")
        and bool(payload.get("xcode_build"))
        and str(payload.get("swift_compiler_version", "")).startswith("6.")
        and str(payload.get("swift_target_triple", "")).startswith("arm64-apple-macosx27")
        and str(payload.get("sdk_name", "")).startswith("macosx27.")
        and str(payload.get("sdk_version", "")).startswith("27.")
        and payload.get("architecture") == "arm64"
        and payload.get("deployment_target") == "27.0"
    )


def run_signing_guard(installed_app: Path, source_app: Path) -> bool:
    result = subprocess.run(
        [
            sys.executable,
            str(SIGNING_GUARD),
            "--configuration",
            "Release",
            "--app-bundle",
            str(installed_app),
            "--source-app-bundle",
            str(source_app),
        ],
        cwd=REPOSITORY_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    return result.returncode == 0


def default_xcode_developer_dir() -> Path | None:
    environment_value = os.environ.get("DEVELOPER_DIR")
    if environment_value:
        return Path(environment_value)
    result = subprocess.run(
        ["/usr/bin/xcode-select", "-p"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return Path(value) if value else None


def git_tree_for_commit(commit: str) -> str:
    if not is_lowercase_git_oid(commit):
        fail("expected source commit must be a lowercase 40-hex OID")
    result = subprocess.run(
        [
            "/usr/bin/git",
            "-C",
            str(REPOSITORY_ROOT),
            "rev-parse",
            "--verify",
            f"{commit}^{{tree}}",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    observed = result.stdout.strip()
    if result.returncode != 0 or not is_lowercase_git_oid(observed):
        detail = result.stderr.strip() or result.stdout.strip() or "git rev-parse failed"
        fail(f"could not resolve expected source commit tree: {detail}")
    return observed


def developer_directory_uses_xcode27(developer_dir: Path | None) -> bool:
    if developer_dir is None or not developer_dir.is_absolute() or not developer_dir.is_dir():
        return False
    xcodebuild = developer_dir / "usr" / "bin" / "xcodebuild"
    if not xcodebuild.is_file():
        return False
    result = subprocess.run(
        [str(xcodebuild), "-version"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return False
    first_line = result.stdout.splitlines()[0] if result.stdout.splitlines() else ""
    return first_line.startswith("Xcode 27.")


def normalize_proof_artifacts(raw_artifacts: Any, evidence_index: int) -> list[dict[str, Any]]:
    if not isinstance(raw_artifacts, list) or not raw_artifacts:
        fail(f"evidence item {evidence_index} must include non-empty proofArtifacts")
    normalized: list[dict[str, Any]] = []
    for artifact_index, artifact in enumerate(raw_artifacts):
        if not isinstance(artifact, dict):
            fail(f"evidence item {evidence_index} proof artifact {artifact_index} must be an object")
        expected_fields = {"kind", "path"}
        if "sha256" in artifact:
            expected_fields.add("sha256")
        if set(artifact) != expected_fields:
            fail(
                f"evidence item {evidence_index} proof artifact {artifact_index} "
                "must be a closed kind/path[/sha256] record"
            )
        kind = artifact.get("kind")
        path_value = artifact.get("path")
        sha256_value = artifact.get("sha256")
        if not isinstance(kind, str) or not kind:
            fail(f"evidence item {evidence_index} proof artifact {artifact_index} has invalid kind")
        if not isinstance(path_value, str) or not path_value:
            fail(f"evidence item {evidence_index} proof artifact {artifact_index} has invalid path")
        path = Path(path_value)
        if not path.is_absolute() or not path.exists() or path.is_symlink():
            fail(
                f"evidence item {evidence_index} proof artifact {artifact_index} "
                "must be an existing non-symlink absolute path"
            )
        normalized_artifact: dict[str, Any] = {
            "kind": kind,
            "path": str(path),
        }
        if sha256_value is not None:
            if not is_lowercase_sha256(sha256_value):
                fail(
                    f"evidence item {evidence_index} proof artifact {artifact_index} "
                    "has invalid sha256"
                )
            if not path.is_file():
                fail(
                    f"evidence item {evidence_index} proof artifact {artifact_index} "
                    "cannot provide sha256 for a non-file path"
                )
            if sha256_file(path) != sha256_value:
                fail(
                    f"evidence item {evidence_index} proof artifact {artifact_index} "
                    "sha256 does not match path"
                )
            normalized_artifact["sha256"] = sha256_value
        normalized.append(normalized_artifact)
    return sorted(normalized, key=lambda item: (item["kind"], item["path"], item.get("sha256", "")))


def require_closed_record(
    value: Any,
    expected_fields: frozenset[str],
    *,
    path: str,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{path} must be an object")
    missing = sorted(expected_fields - set(value))
    unknown = sorted(set(value) - expected_fields)
    if missing or unknown:
        fail(f"{path} must be a closed record; missing={missing}, unknown={unknown}")
    return value


def load_live_execution_report(
    path: Path,
    expected_sha256: str,
    evidence_index: int,
) -> dict[str, Any]:
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError as error:
        fail(f"evidence item {evidence_index} live execution report is unavailable: {error}")
    try:
        with os.fdopen(descriptor, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                fail(
                    f"evidence item {evidence_index} live execution report must be an "
                    "ordinary, non-hardlinked file"
                )
            if (
                before.st_size <= 0
                or before.st_size > MAXIMUM_LIVE_EXECUTION_REPORT_BYTES
            ):
                fail(
                    f"evidence item {evidence_index} live execution report exceeds the "
                    "bounded file-size contract"
                )
            raw_bytes = stream.read(MAXIMUM_LIVE_EXECUTION_REPORT_BYTES + 1)
            after = os.fstat(stream.fileno())
    except OSError as error:
        fail(f"evidence item {evidence_index} live execution report could not be read: {error}")
    stable_fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    if (
        any(getattr(before, field) != getattr(after, field) for field in stable_fields)
        or len(raw_bytes) != before.st_size
    ):
        fail(f"evidence item {evidence_index} live execution report changed while read")
    if hashlib.sha256(raw_bytes).hexdigest() != expected_sha256:
        fail(
            f"evidence item {evidence_index} live execution report changed after "
            "proof-artifact validation"
        )
    try:
        raw = raw_bytes.decode("utf-8")
        def closed_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
            result: dict[str, Any] = {}
            for key, value in pairs:
                if key in result:
                    fail(
                        f"evidence item {evidence_index} live execution report "
                        f"contains duplicate JSON key {key!r}"
                    )
                result[key] = value
            return result

        payload = json.loads(raw, object_pairs_hook=closed_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"evidence item {evidence_index} live execution report is invalid JSON: {error}")
    if not isinstance(payload, dict):
        fail(f"evidence item {evidence_index} live execution report must be an object")
    return payload


def normalized_live_attempt(
    raw_attempt: Any,
    *,
    evidence_index: int,
    attempt_offset: int,
) -> dict[str, Any]:
    path = f"evidence item {evidence_index} live attempt {attempt_offset}"
    attempt = require_closed_record(
        raw_attempt,
        LIVE_EXECUTION_ATTEMPT_FIELDS,
        path=path,
    )
    attempt_index = attempt["attemptIndex"]
    started = attempt["startedAtUnixMilliseconds"]
    ended = attempt["endedAtUnixMilliseconds"]
    exit_code = attempt["exitCode"]
    failure = attempt["failure"]
    peak_memory = attempt["peakResidentMemoryMegabytes"]
    scenario = attempt["scenario"]
    seed = attempt["seed"]
    timed_out = attempt["timedOut"]
    if (
        not isinstance(attempt_index, int)
        or isinstance(attempt_index, bool)
        or attempt_index < 1
    ):
        fail(f"{path} has invalid attemptIndex")
    if (
        not isinstance(started, int)
        or isinstance(started, bool)
        or started < 0
        or not isinstance(ended, int)
        or isinstance(ended, bool)
        or ended < started
    ):
        fail(f"{path} has invalid or reversed timestamps")
    if not isinstance(exit_code, int) or isinstance(exit_code, bool):
        fail(f"{path} has invalid exitCode")
    if failure is not None:
        if not isinstance(failure, str) or not failure:
            fail(f"{path} has invalid failure text")
        try:
            failure_bytes = len(failure.encode("utf-8"))
        except UnicodeEncodeError:
            failure_bytes = MAXIMUM_LIVE_FAILURE_UTF8_BYTES + 1
        if failure_bytes > MAXIMUM_LIVE_FAILURE_UTF8_BYTES:
            fail(f"{path} failure text exceeds the bounded UTF-8 limit")
    if peak_memory is not None and (
        not isinstance(peak_memory, int)
        or isinstance(peak_memory, bool)
        or peak_memory < 0
    ):
        fail(f"{path} has invalid peakResidentMemoryMegabytes")
    if not isinstance(scenario, str) or scenario not in STRESS_GATES | LIVE_EXECUTION_GATES:
        fail(f"{path} has invalid scenario")
    if seed is not None and (
        not isinstance(seed, int) or isinstance(seed, bool) or seed < 0
    ):
        fail(f"{path} has invalid seed")
    if not isinstance(timed_out, bool):
        fail(f"{path} has invalid timedOut")
    return {
        "attemptIndex": attempt_index,
        "durationMilliseconds": ended - started,
        "endedAtUnixMilliseconds": ended,
        "exitCode": exit_code,
        "failure": failure,
        "peakResidentMemoryMegabytes": peak_memory,
        "scenario": scenario,
        "seed": seed,
        "startedAtUnixMilliseconds": started,
        "timedOut": timed_out,
    }


def live_attempt_passed(attempt: dict[str, Any]) -> bool:
    return (
        attempt["exitCode"] == 0
        and attempt["failure"] is None
        and not attempt["timedOut"]
    )


def validate_live_execution_evidence(
    gate: str,
    proof_artifacts: list[dict[str, Any]],
    *,
    evidence_index: int,
    expected_source_commit: str,
    expected_source_tree: str,
    expected_installed_executable_sha256: str,
    expected_exposed_at_unix_ns: int | None = None,
) -> dict[str, Any]:
    matching = [
        artifact
        for artifact in proof_artifacts
        if artifact["kind"] == LIVE_EXECUTION_REPORT_KIND
    ]
    if len(proof_artifacts) != 1 or len(matching) != 1:
        fail(
            f"evidence item {evidence_index} for {gate} must include exactly one "
            f"{LIVE_EXECUTION_REPORT_KIND} artifact"
        )
    artifact = matching[0]
    if "sha256" not in artifact:
        fail(
            f"evidence item {evidence_index} for {gate} live execution report "
            "must carry its physical SHA-256"
        )
    report = require_closed_record(
        load_live_execution_report(
            Path(artifact["path"]), artifact["sha256"], evidence_index
        ),
        LIVE_EXECUTION_REPORT_FIELDS,
        path=f"evidence item {evidence_index} live execution report",
    )
    if expected_exposed_at_unix_ns is not None:
        _fresh_evidence_time(
            Path(artifact["path"]),
            digest=artifact["sha256"],
            exposed_at=expected_exposed_at_unix_ns,
        )
    if report["schemaVersion"] != 1:
        fail(f"evidence item {evidence_index} live execution report schema mismatch")
    bindings = (
        ("gate", gate),
        ("sourceCommit", expected_source_commit),
        ("sourceTree", expected_source_tree),
        ("installedExecutableSHA256", expected_installed_executable_sha256),
    )
    for field, expected in bindings:
        if report[field] != expected:
            fail(
                f"evidence item {evidence_index} live execution report {field} "
                "does not match the exact candidate"
            )
    raw_attempts = report["attempts"]
    if not isinstance(raw_attempts, list) or not raw_attempts:
        fail(f"evidence item {evidence_index} live execution report attempts must be non-empty")
    attempts = [
        normalized_live_attempt(
            attempt,
            evidence_index=evidence_index,
            attempt_offset=offset,
        )
        for offset, attempt in enumerate(raw_attempts)
    ]
    if expected_exposed_at_unix_ns is not None and any(
        attempt["startedAtUnixMilliseconds"] * 1_000_000
        < expected_exposed_at_unix_ns
        for attempt in attempts
    ):
        fail(
            f"evidence item {evidence_index} for {gate} predates candidate exposure"
        )

    attempt_seeds: list[int] = []
    maximum_durations: dict[str, int] = {}
    maximum_peak_memory: int | None = None
    if gate in {"installed-launch-smoke", "direct-debugger-transport-contracts"}:
        if len(attempts) != 1 or attempts[0]["attemptIndex"] != 1:
            fail(f"evidence item {evidence_index} for {gate} must contain exactly attempt 1")
        if attempts[0]["scenario"] != gate or attempts[0]["seed"] is not None:
            fail(f"evidence item {evidence_index} for {gate} has invalid attempt authority")
        if attempts[0]["peakResidentMemoryMegabytes"] is not None:
            fail(f"evidence item {evidence_index} for {gate} cannot carry performance data")
    elif gate in STRESS_GATES:
        if any(attempt["scenario"] != gate for attempt in attempts):
            fail(f"evidence item {evidence_index} for {gate} contains another scenario")
        indexes = [attempt["attemptIndex"] for attempt in attempts]
        if indexes != list(range(1, len(attempts) + 1)):
            fail(f"evidence item {evidence_index} for {gate} attempt indexes are not contiguous")
        seeds = [attempt["seed"] for attempt in attempts]
        if any(seed is None for seed in seeds) or len(set(seeds)) != len(seeds):
            fail(f"evidence item {evidence_index} for {gate} seeds must be present and unique")
        if any(attempt["peakResidentMemoryMegabytes"] is not None for attempt in attempts):
            fail(f"evidence item {evidence_index} for {gate} cannot carry performance data")
        attempt_seeds = [int(seed) for seed in seeds]
    elif gate == "performance-gate":
        attempts_by_scenario = {
            scenario: [attempt for attempt in attempts if attempt["scenario"] == scenario]
            for scenario in sorted(STRESS_GATES)
        }
        if sum(len(values) for values in attempts_by_scenario.values()) != len(attempts):
            fail(f"evidence item {evidence_index} performance report contains another scenario")
        for scenario, scenario_attempts in attempts_by_scenario.items():
            indexes = [attempt["attemptIndex"] for attempt in scenario_attempts]
            if indexes != list(range(1, len(scenario_attempts) + 1)):
                fail(
                    f"evidence item {evidence_index} performance report {scenario} "
                    "attempt indexes are not contiguous"
                )
            seeds = [attempt["seed"] for attempt in scenario_attempts]
            if any(seed is None for seed in seeds) or len(set(seeds)) != len(seeds):
                fail(
                    f"evidence item {evidence_index} performance report {scenario} "
                    "seeds must be present and unique"
                )
            if any(
                attempt["peakResidentMemoryMegabytes"] is None
                for attempt in scenario_attempts
            ):
                fail(
                    f"evidence item {evidence_index} performance report {scenario} "
                    "omits peak memory"
                )
            attempt_seeds.extend(int(seed) for seed in seeds)
            if scenario_attempts:
                maximum_durations[scenario] = max(
                    attempt["durationMilliseconds"] for attempt in scenario_attempts
                )
        maximum_peak_memory = max(
            attempt["peakResidentMemoryMegabytes"]
            for attempt in attempts
        )

    accepted_flags = [live_attempt_passed(attempt) for attempt in attempts]
    if gate == "performance-gate":
        accepted_flags = [
            accepted
            and attempt["durationMilliseconds"]
            <= PERFORMANCE_THRESHOLDS[
                PERFORMANCE_DURATION_THRESHOLD_BY_STRESS_GATE[attempt["scenario"]]
            ]
            and attempt["peakResidentMemoryMegabytes"]
            <= PERFORMANCE_THRESHOLDS["maximumPeakResidentMemoryMegabytes"]
            for accepted, attempt in zip(accepted_flags, attempts)
        ]
    accepted_attempts = sum(accepted_flags)
    failure_count = len(accepted_flags) - accepted_attempts
    status = "passed" if failure_count == 0 else "failed"
    if gate in STRESS_GATES and len(attempts) < MINIMUM_ACCEPTED_ATTEMPTS[gate]:
        status = "failed"
    if gate == "performance-gate":
        for scenario, scenario_attempts in attempts_by_scenario.items():
            if len(scenario_attempts) < MINIMUM_ACCEPTED_ATTEMPTS[scenario]:
                status = "failed"
    return evidence(
        gate,
        status,
        expected_source_commit,
        expected_installed_executable_sha256,
        accepted_attempts,
        proof_artifacts,
        attempt_seeds=attempt_seeds,
        duration_milliseconds=sum(
            attempt["durationMilliseconds"] for attempt in attempts
        ),
        failure_count=failure_count,
        maximum_duration_milliseconds_by_scenario=(
            maximum_durations if gate == "performance-gate" else None
        ),
        maximum_peak_resident_memory_megabytes=(
            maximum_peak_memory if gate == "performance-gate" else None
        ),
    )


def xcresulttool_json(
    path: Path,
    evidence_index: int,
    report_kind: str,
) -> dict[str, Any]:
    if path.suffix != ".xcresult" or not path.is_dir():
        fail(
            f"evidence item {evidence_index} incremental-xcuitest proof must be "
            "a non-symlink .xcresult bundle"
        )
    try:
        result = subprocess.run(
            [
                "/usr/bin/xcrun",
                "xcresulttool",
                "get",
                "test-results",
                report_kind,
                "--path",
                str(path),
                "--compact",
            ],
            text=True,
            capture_output=True,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail(
            f"evidence item {evidence_index} could not inspect xcresult "
            f"{report_kind}: {error}"
        )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "xcresulttool failed"
        fail(
            f"evidence item {evidence_index} could not inspect xcresult "
            f"{report_kind}: {detail}"
        )
    try:
        summary = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        fail(
            f"evidence item {evidence_index} xcresult {report_kind} is invalid "
            f"JSON: {error}"
        )
    if not isinstance(summary, dict):
        fail(
            f"evidence item {evidence_index} xcresult {report_kind} must be an object"
        )
    return summary


def xcresult_test_summary(path: Path, evidence_index: int) -> dict[str, Any]:
    return xcresulttool_json(path, evidence_index, "summary")


def xcresult_test_nodes(path: Path, evidence_index: int) -> dict[str, Any]:
    return xcresulttool_json(path, evidence_index, "tests")


def xcresult_test_cases(
    document: dict[str, Any],
    evidence_index: int,
) -> list[dict[str, Any]]:
    roots = document.get("testNodes")
    if not isinstance(roots, list):
        fail(f"evidence item {evidence_index} xcresult tests lacks a testNodes list")
    cases: list[dict[str, Any]] = []

    def visit(node: Any, ancestors: list[tuple[str, str]]) -> None:
        if not isinstance(node, dict):
            fail(
                f"evidence item {evidence_index} xcresult tests contains a "
                "non-object node"
            )
        node_type = node.get("nodeType")
        name = node.get("name")
        if not isinstance(node_type, str) or not isinstance(name, str):
            fail(
                f"evidence item {evidence_index} xcresult tests contains an "
                "unidentifiable node"
            )
        lineage = ancestors + [(node_type, name)]
        if node_type == "Test Case":
            identifier = node.get("nodeIdentifier")
            if not isinstance(identifier, str) or not identifier:
                fail(
                    f"evidence item {evidence_index} xcresult Test Case lacks an "
                    "exact nodeIdentifier"
                )
            bundle_names = {
                ancestor_name
                for ancestor_type, ancestor_name in ancestors
                if ancestor_type == "UI test bundle"
            }
            suite_names = {
                ancestor_name
                for ancestor_type, ancestor_name in ancestors
                if ancestor_type == "Test Suite"
            }
            cases.append(
                {
                    "identifier": identifier,
                    "inExpectedBundle": INSTALLED_UI_TEST_TARGET in bundle_names,
                    "inExpectedSuite": INSTALLED_UI_TEST_SUITE in suite_names,
                    "node": node,
                }
            )
        children = node.get("children", [])
        if not isinstance(children, list):
            fail(
                f"evidence item {evidence_index} xcresult tests contains malformed "
                "children"
            )
        for child in children:
            visit(child, lineage)

    for root in roots:
        visit(root, [])
    return cases


def exclusively_passed_case(node: dict[str, Any], evidence_index: int) -> None:
    results: list[str] = []
    forbidden_nodes: list[str] = []

    def collect(current: Any) -> None:
        if not isinstance(current, dict):
            fail(
                f"evidence item {evidence_index} xcresult Test Case contains a "
                "non-object child"
            )
        node_type = current.get("nodeType")
        if node_type in {"Skip Message", "Expected Failure", "Failure Message"}:
            forbidden_nodes.append(str(node_type))
        result = current.get("result")
        if node_type in {"Test Case", "Test Case Run"}:
            if not isinstance(result, str):
                fail(
                    f"evidence item {evidence_index} xcresult Test Case has no "
                    "executed result"
                )
            results.append(result)
        children = current.get("children", [])
        if not isinstance(children, list):
            fail(
                f"evidence item {evidence_index} xcresult Test Case contains "
                "malformed children"
            )
        for child in children:
            collect(child)

    collect(node)
    if forbidden_nodes or any(result != "Passed" for result in results):
        fail(
            f"evidence item {evidence_index} xcresult Test Case was not "
            f"exclusively passed: results={results}, nodes={forbidden_nodes}"
        )


def validate_xcuitest_evidence(
    proof_artifacts: list[dict[str, Any]],
    executed_test_count: int,
    skipped_test_count: int,
    status: str,
    evidence_index: int,
    claimed_result_bundle_sha256: str,
) -> tuple[list[str], list[str]]:
    xcresults = [artifact for artifact in proof_artifacts if artifact["kind"] == "xcresult"]
    if len(xcresults) != 1:
        fail(
            f"evidence item {evidence_index} incremental-xcuitest must include "
            "exactly one xcresult proof artifact"
        )
    result_path = Path(xcresults[0]["path"])
    observed_result_bundle_sha256 = result_bundle_sha256(result_path)
    if claimed_result_bundle_sha256 != observed_result_bundle_sha256:
        fail(
            f"evidence item {evidence_index} incremental-xcuitest "
            "resultBundleSHA256 does not match the xcresult bundle"
        )
    summary = xcresult_test_summary(result_path, evidence_index)
    tests = xcresult_test_nodes(result_path, evidence_index)
    integer_fields = (
        "totalTestCount",
        "passedTests",
        "failedTests",
        "skippedTests",
        "expectedFailures",
    )
    for field in integer_fields:
        value = summary.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            fail(f"evidence item {evidence_index} xcresult has invalid {field}")
    title = summary.get("title")
    if title != "Test - MacScopeInstalledAppUITests":
        fail(
            f"evidence item {evidence_index} xcresult is not from "
            "MacScopeInstalledAppUITests"
        )
    total = summary["totalTestCount"]
    accounted_total = (
        summary["passedTests"]
        + summary["failedTests"]
        + summary["skippedTests"]
        + summary["expectedFailures"]
    )
    if accounted_total != total:
        fail(f"evidence item {evidence_index} xcresult test counts are inconsistent")
    observed_skipped = summary["skippedTests"]
    observed_executed = total - observed_skipped
    selectors = load_installed_selector_catalog()
    expected_identifiers = [selector["testIdentifier"] for selector in selectors]
    expected_selector_by_identifier = {
        selector["testIdentifier"]: selector["vectorID"] for selector in selectors
    }
    if total != len(expected_identifiers):
        fail(
            f"evidence item {evidence_index} incremental-xcuitest xcresult must "
            f"contain exactly {len(expected_identifiers)} tests"
        )
    if (executed_test_count, skipped_test_count) != (observed_executed, observed_skipped):
        fail(
            f"evidence item {evidence_index} incremental-xcuitest counts disagree "
            "with the xcresult summary"
        )
    if executed_test_count + skipped_test_count != total:
        fail(f"evidence item {evidence_index} incremental-xcuitest counts are inconsistent")
    cases = xcresult_test_cases(tests, evidence_index)
    observed_identifiers = [case["identifier"] for case in cases]
    duplicate_identifiers = sorted(
        identifier
        for identifier, count in Counter(observed_identifiers).items()
        if count != 1
    )
    missing_identifiers = sorted(set(expected_identifiers) - set(observed_identifiers))
    unexpected_identifiers = sorted(set(observed_identifiers) - set(expected_identifiers))
    wrong_boundary_identifiers = sorted(
        case["identifier"]
        for case in cases
        if not case["inExpectedBundle"] or not case["inExpectedSuite"]
    )
    if status == "passed" and (
        summary.get("result") != "Passed"
        or summary["failedTests"] != 0
        or summary["expectedFailures"] != 0
        or executed_test_count != total
        or skipped_test_count != 0
        or duplicate_identifiers
        or missing_identifiers
        or unexpected_identifiers
        or wrong_boundary_identifiers
    ):
        fail(
            f"evidence item {evidence_index} incremental-xcuitest claiming passed "
            "must prove exact one-to-one selector execution with zero skipped, "
            "failed, expected-failure, duplicate, missing, unexpected, or "
            "wrong-boundary tests; "
            f"missing={missing_identifiers}, duplicates={duplicate_identifiers}, "
            f"unexpected={unexpected_identifiers}, wrongBoundary={wrong_boundary_identifiers}"
        )
    if status == "passed":
        for case in cases:
            exclusively_passed_case(case["node"], evidence_index)
    if status == "failed" and summary.get("result") == "Passed":
        fail(
            f"evidence item {evidence_index} incremental-xcuitest claiming failed "
            "disagrees with the xcresult summary"
        )
    executed_selector_ids = sorted(
        expected_selector_by_identifier[identifier]
        for identifier in observed_identifiers
        if identifier in expected_selector_by_identifier
    )
    return executed_selector_ids, sorted(observed_identifiers)


def normalize_input_evidence(
    payload: Any,
    *,
    expected_source_commit: str | None = None,
    expected_source_tree: str | None = None,
    expected_installed_executable_sha256: str | None = None,
    expected_exposed_at_unix_ns: int | None = None,
    candidate_identity_path: Path | None = None,
    installed_app: Path | None = None,
) -> list[dict[str, Any]]:
    raw_items = payload.get("evidence") if isinstance(payload, dict) else payload
    if not isinstance(raw_items, list):
        fail("evidence JSON must be a list or an object with an evidence list")

    normalized: list[dict[str, Any]] = []
    for index, item in enumerate(raw_items):
        if not isinstance(item, dict):
            fail(f"evidence item {index} must be a JSON object")
        gate = item.get("gate")
        if gate not in SUPPLIED_LIVE_GATES:
            fail(f"evidence item {index} has unknown gate: {gate!r}")
        if gate in LIVE_EXECUTION_GATES:
            require_closed_record(
                item,
                frozenset({"gate", "proofArtifacts"}),
                path=f"evidence item {index} for {gate}",
            )
            if (
                expected_source_commit is None
                or expected_source_tree is None
                or expected_installed_executable_sha256 is None
            ):
                fail(
                    f"evidence item {index} for {gate} requires exact candidate authority"
                )
            proof_artifacts = normalize_proof_artifacts(
                item.get("proofArtifacts"), index
            )
            normalized.append(
                validate_live_execution_evidence(
                    gate,
                    proof_artifacts,
                    evidence_index=index,
                    expected_source_commit=expected_source_commit,
                    expected_source_tree=expected_source_tree,
                    expected_installed_executable_sha256=(
                        expected_installed_executable_sha256
                    ),
                    expected_exposed_at_unix_ns=expected_exposed_at_unix_ns,
                )
            )
            continue

        require_closed_record(
            item,
            frozenset({"gate", "proofArtifacts"}),
            path=f"evidence item {index} for incremental-xcuitest",
        )
        if candidate_identity_path is None or installed_app is None:
            fail(
                f"evidence item {index} for {gate} requires the candidate identity "
                "and installed app physical identity"
            )
        proof_artifacts = normalize_proof_artifacts(item["proofArtifacts"], index)
        receipt_artifacts = [
            artifact
            for artifact in proof_artifacts
            if artifact["kind"] == installed_matrix_receipt.PROOF_ARTIFACT_KIND
        ]
        if len(receipt_artifacts) != 1 or "sha256" not in receipt_artifacts[0]:
            fail(
                f"evidence item {index} incremental-xcuitest must include exactly "
                "one SHA-bound installed matrix receipt"
            )
        try:
            sealed_receipt, sealed_receipt_sha256 = installed_matrix_receipt.load_receipt_with_sha256(
                Path(receipt_artifacts[0]["path"])
            )
            if sealed_receipt_sha256 != receipt_artifacts[0]["sha256"]:
                fail(
                    f"evidence item {index} installed matrix receipt bytes differ from "
                    "the SHA-bound proof artifact"
                )
            if expected_exposed_at_unix_ns is not None:
                _fresh_evidence_time(
                    Path(receipt_artifacts[0]["path"]),
                    digest=receipt_artifacts[0]["sha256"],
                    exposed_at=expected_exposed_at_unix_ns,
                )
            installed_matrix_receipt.validate_receipt(
                sealed_receipt,
                candidate_identity_path=candidate_identity_path,
                installed_app=installed_app,
                expected_selector_projection=installed_selector_projection(),
            )
        except installed_matrix_receipt.InstalledMatrixReceiptError as error:
            fail(f"evidence item {index} installed matrix receipt is invalid: {error}")
        execution = sealed_receipt["execution"]
        sealed_candidate = sealed_receipt["candidate"]
        sealed_installed = sealed_receipt["products"]["installed_app"]
        status = execution["result"]
        source_commit = sealed_candidate["source_commit"]
        source_tree = sealed_candidate["source_tree"]
        digest = sealed_installed["executable_sha256"]
        attempts = 1
        executed_test_count = len(execution["selectors"])
        skipped_test_count = 0
        xcresult_path = Path(sealed_receipt["products"]["xcresult"]["path"])
        result_bundle_sha256_value = result_bundle_sha256(xcresult_path)
        if expected_source_commit is not None and source_commit != expected_source_commit:
            fail(f"evidence item {index} for {gate} sourceCommit does not match the candidate")
        if expected_source_tree is not None and source_tree != expected_source_tree:
            fail(f"evidence item {index} for {gate} sourceTree does not match the candidate")
        if expected_installed_executable_sha256 is not None and digest != expected_installed_executable_sha256:
            fail(
                f"evidence item {index} for {gate} installedExecutableSHA256 "
                "does not match the installed candidate"
            )
        executed_selector_ids, executed_test_identifiers = validate_xcuitest_evidence(
            proof_artifacts,
            executed_test_count,
            skipped_test_count,
            status,
            index,
            result_bundle_sha256_value,
        )
        normalized.append(
            evidence(
                gate,
                status,
                source_commit,
                digest,
                attempts,
                proof_artifacts,
                executed_test_count,
                skipped_test_count,
                source_tree,
                result_bundle_sha256_value,
                executed_selector_ids,
                executed_test_identifiers,
            )
        )
    return normalized


def evidence_by_gate(items: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    grouped: dict[str, dict[str, Any]] = {}
    for item in items:
        if item["gate"] not in grouped:
            grouped[item["gate"]] = item
    return grouped


def derive_toolchain_evidence(
    provenance: dict[str, Any],
    expected_source_commit: str,
    installed_digest: str,
    developer_dir: Path | None,
) -> dict[str, Any]:
    host_ok = platform.machine() == "arm64"
    try:
        macos_major = int(platform.mac_ver()[0].split(".", maxsplit=1)[0])
    except (IndexError, ValueError):
        macos_major = 0
    accepted = (
        provenance_passed(provenance, expected_source_commit)
        and host_ok
        and macos_major >= 27
        and developer_directory_uses_xcode27(developer_dir)
    )
    return evidence(
        "supported-toolchain-matrix",
        "passed" if accepted else "failed",
        expected_source_commit,
        installed_digest,
    )


def derive_security_evidence(
    items: list[dict[str, Any]],
    expected_source_commit: str,
    installed_digest: str,
) -> dict[str, Any]:
    grouped = evidence_by_gate(items)
    required = (
        "sealed-release-provenance",
        "local-signing-policy",
        "cli-gui-operability",
        "mcp-operability",
        "direct-debugger-transport-contracts",
        "repeated-launch-detach-stress",
        "repeated-attach-detach-stress",
        "repeated-restart-stress",
    )
    accepted = all(
        gate in grouped
        and grouped[gate]["status"] == "passed"
        and grouped[gate]["sourceCommit"] == expected_source_commit
        and grouped[gate]["installedExecutableSHA256"] == installed_digest
        and grouped[gate]["acceptedAttempts"] >= MINIMUM_ACCEPTED_ATTEMPTS.get(gate, 1)
        for gate in required
    )
    return evidence(
        "security-gate",
        "passed" if accepted else "failed",
        expected_source_commit,
        installed_digest,
    )


def canonical_evidence(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        items,
        key=lambda item: (
            item["gate"],
            item["sourceCommit"],
            item["installedExecutableSHA256"],
            item["status"],
            item["acceptedAttempts"],
        ),
    )


def evaluate(
    items: list[dict[str, Any]],
    expected_source_commit: str,
) -> tuple[bool, list[str], list[dict[str, str | None]]]:
    deficiencies: set[tuple[str, str | None]] = set()
    grouped: dict[str, dict[str, Any]] = {}
    duplicate_gates: set[str] = set()
    for item in items:
        gate = item["gate"]
        if gate in grouped:
            duplicate_gates.add(gate)
        else:
            grouped[gate] = item
    for gate in duplicate_gates:
        deficiencies.add(("duplicate-gate-evidence", gate))

    accepted_digests: set[str] = set()
    for gate in REQUIRED_GATES:
        item = grouped.get(gate)
        if item is None:
            deficiencies.add(("missing-required-gate", gate))
            continue
        if item["status"] != "passed":
            deficiencies.add(("gate-failed", gate))
        if item["sourceCommit"] != expected_source_commit:
            deficiencies.add(("stale-source-commit", gate))
        digest = item["installedExecutableSHA256"]
        if digest == "":
            deficiencies.add(("empty-installed-executable-digest", gate))
        elif not is_lowercase_sha256(digest):
            deficiencies.add(("malformed-installed-executable-digest", gate))
        if item["acceptedAttempts"] < MINIMUM_ACCEPTED_ATTEMPTS.get(gate, 1):
            deficiencies.add(("insufficient-accepted-attempts", gate))
        if (
            item["status"] == "passed"
            and item["sourceCommit"] == expected_source_commit
            and is_lowercase_sha256(digest)
        ):
            accepted_digests.add(digest)

    if len(accepted_digests) > 1:
        deficiencies.add(("inconsistent-installed-executable-digest", None))

    sorted_deficiencies = [
        {"code": code, "gate": gate}
        for code, gate in sorted(deficiencies, key=lambda pair: (pair[0], pair[1] or ""))
    ]
    accepted = not sorted_deficiencies
    accepted_gates = list(REQUIRED_GATES) if accepted else []
    return accepted, accepted_gates, sorted_deficiencies


def _canonical_absent_output(path: Path, *, label: str) -> tuple[Path, tuple[int, int]]:
    if not path.is_absolute() or not path.name or path.suffix != ".json":
        fail(f"{label} must be an absolute .json file path")
    if path.exists() or path.is_symlink():
        fail(f"{label} must be absent")
    try:
        parent = path.parent.resolve(strict=True)
        metadata = parent.lstat()
    except OSError as error:
        fail(f"{label} parent is unavailable: {error}")
    if path != parent / path.name:
        fail(f"{label} path is not canonical")
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        fail(f"{label} parent must be an ordinary non-symlink directory")
    return path, (metadata.st_dev, metadata.st_ino)


def _write_create_only(path: Path, payload: bytes, *, label: str) -> int:
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        descriptor = os.open(path, flags, 0o600)
        try:
            os.fchmod(descriptor, 0o600)
            offset = 0
            while offset < len(payload):
                written = os.write(descriptor, payload[offset:])
                if written <= 0:
                    fail(f"{label} write made no progress")
                offset += written
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        metadata = path.lstat()
    except OSError as error:
        fail(f"{label} could not be created: {error}")
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
        or metadata.st_size != len(payload)
    ):
        fail(f"{label} publication identity is invalid")
    return metadata.st_mtime_ns


def write_report(report: dict[str, Any], output: Path) -> tuple[str, int, int]:
    _canonical_absent_output(output, label="installed qualification report output")
    payload = canonical_bytes(report)
    if len(payload) > MAXIMUM_INSTALLED_QUALIFICATION_OUTPUT_BYTES:
        fail("installed qualification report exceeds its bounded output contract")
    mtime_ns = _write_create_only(
        output, payload, label="installed qualification report"
    )
    return hashlib.sha256(payload).hexdigest(), len(payload), mtime_ns


def parse_acceptance_gate_outputs(
    arguments: list[str], *, aggregate_output: Path
) -> dict[str, Path]:
    parsed: dict[str, Path] = {}
    for argument in arguments:
        gate_id, separator, raw_path = argument.partition("=")
        if not separator or not gate_id or not raw_path:
            fail("acceptance gate outputs must use GATE_ID=/absolute/report.json")
        if gate_id in parsed:
            fail(f"duplicate acceptance gate output: {gate_id}")
        parsed[gate_id] = Path(raw_path)
    if tuple(sorted(parsed)) != REQUIRED_ACCEPTANCE_GATES:
        fail("exactly one output for every required acceptance gate is required")
    aggregate, root_identity = _canonical_absent_output(
        aggregate_output, label="installed qualification report output"
    )
    canonical_paths: dict[str, Path] = {}
    seen_paths: set[Path] = {aggregate}
    for gate_id in REQUIRED_ACCEPTANCE_GATES:
        path, parent_identity = _canonical_absent_output(
            parsed[gate_id], label=f"acceptance gate output {gate_id}"
        )
        if parent_identity != root_identity or path.parent != aggregate.parent:
            fail("acceptance gate outputs must share one qualification-evidence root")
        if path in seen_paths:
            fail("acceptance gate outputs must be distinct files")
        seen_paths.add(path)
        canonical_paths[gate_id] = path
    return canonical_paths


def _fresh_evidence_time(path: Path, *, digest: str, exposed_at: int) -> int:
    final_digest = _sha256_stable_regular_file(path, label=f"gate evidence {path.name}")
    if final_digest != digest:
        fail(f"gate evidence changed during aggregation: {path}")
    try:
        observed = path.lstat()
    except OSError as error:
        fail(f"gate evidence is unavailable: {error}")
    if observed.st_mtime_ns < exposed_at:
        fail(f"gate evidence predates candidate exposure: {path}")
    return observed.st_mtime_ns


def operability_authority_from_arguments(
    arguments: argparse.Namespace,
    *,
    retained_pending_state: installer.StableFile | None = None,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, tuple[str, int, int]]]:
    return validate_operability_authority(
        installed_app=arguments.installed_app,
        source_app=arguments.source_app,
        candidate_identity=arguments.candidate_identity,
        expected_source_commit=arguments.expected_source_commit,
        qualification_run_id=arguments.qualification_run_id,
        qualification_run_nonce=arguments.qualification_run_nonce,
        installation_pending_state=arguments.installation_pending_state,
        full_surface_report=arguments.full_surface_report,
        legacy_grid_report=arguments.legacy_grid_report,
        native_xpc_execution_report=arguments.native_xpc_execution_report,
        retained_pending_state=retained_pending_state,
    )


def build_report(
    arguments: argparse.Namespace,
    *,
    retained_pending_state: installer.StableFile | None = None,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, tuple[str, int, int]]]:
    source_executable = validate_app_bundle(arguments.source_app, "source")
    installed_executable = validate_app_bundle(arguments.installed_app, "installed")
    provenance = load_provenance(arguments.installed_app)
    expected_source_commit = arguments.expected_source_commit
    if not isinstance(expected_source_commit, str) or not expected_source_commit:
        fail("expected source commit must be a non-empty string")
    expected_source_tree = provenance.get("git_head_tree")
    if not is_lowercase_git_oid(expected_source_tree):
        fail("installed Release provenance git_head_tree must be a lowercase 40-hex OID")
    observed_source_tree = git_tree_for_commit(expected_source_commit)
    if expected_source_tree != observed_source_tree:
        fail(
            "installed Release provenance git_head_tree does not match "
            "git_head_commit"
        )

    source_digest = sha256_file(source_executable)
    installed_digest = sha256_file(installed_executable)
    operability_authority, pending_state, gate_evidence = (
        operability_authority_from_arguments(arguments, retained_pending_state=retained_pending_state)
    )
    if operability_authority["installedExecutableSHA256"] != installed_digest:
        fail("operability authority executable digest changed before aggregation")
    cli_gui_report, cli_gui_sha256 = load_operability_report(
        arguments.cli_gui_operability_report,
        expected_kind=CLI_GUI_OPERABILITY_REPORT_KIND,
        expected_authority=operability_authority,
        require_complete=True,
    )
    mcp_report, mcp_sha256 = load_operability_report(
        arguments.mcp_operability_report,
        expected_kind=MCP_OPERABILITY_REPORT_KIND,
        expected_authority=operability_authority,
        require_complete=True,
    )
    exposure = pending_state["exposed_at_unix_ns"]
    live_evidence, live_evidence_sha256 = _load_canonical_live_evidence(
        arguments.evidence_json
    )
    _fresh_evidence_time(
        arguments.evidence_json,
        digest=live_evidence_sha256,
        exposed_at=exposure,
    )
    cli_gui_time = _fresh_evidence_time(
        arguments.cli_gui_operability_report,
        digest=cli_gui_sha256,
        exposed_at=exposure,
    )
    mcp_time = _fresh_evidence_time(
        arguments.mcp_operability_report,
        digest=mcp_sha256,
        exposed_at=exposure,
    )
    gate_evidence.update(
        {
            "cli": (cli_gui_sha256, cli_gui_time, cli_gui_time),
            "gui": (cli_gui_sha256, cli_gui_time, cli_gui_time),
            "mcp": (mcp_sha256, mcp_time, mcp_time),
        }
    )
    signing_passed = run_signing_guard(
        arguments.installed_app,
        arguments.source_app,
    )

    items = normalize_input_evidence(
        live_evidence,
        expected_source_commit=expected_source_commit,
        expected_source_tree=expected_source_tree,
        expected_installed_executable_sha256=installed_digest,
        expected_exposed_at_unix_ns=exposure,
        candidate_identity_path=arguments.candidate_identity,
        installed_app=arguments.installed_app,
    )
    items.extend(
        [
            evidence(
                "cli-gui-operability",
                "passed",
                expected_source_commit,
                installed_digest,
                proof_artifacts=[
                    {
                        "kind": CLI_GUI_OPERABILITY_REPORT_KIND,
                        "path": str(arguments.cli_gui_operability_report),
                        "sha256": cli_gui_sha256,
                    }
                ],
                source_tree=expected_source_tree,
                operability_authority=operability_authority,
                probe_results=cli_gui_report["probeResults"],
            ),
            evidence(
                "mcp-operability",
                "passed",
                expected_source_commit,
                installed_digest,
                proof_artifacts=[
                    {
                        "kind": MCP_OPERABILITY_REPORT_KIND,
                        "path": str(arguments.mcp_operability_report),
                        "sha256": mcp_sha256,
                    }
                ],
                source_tree=expected_source_tree,
                operability_authority=operability_authority,
                probe_results=mcp_report["probeResults"],
            ),
            evidence(
                "source-install-equality",
                "passed" if source_digest == installed_digest else "failed",
                expected_source_commit,
                installed_digest,
            ),
            evidence(
                "sealed-release-provenance",
                "passed" if provenance_passed(provenance, expected_source_commit) else "failed",
                provenance.get("git_head_commit") or expected_source_commit,
                installed_digest,
            ),
            evidence(
                "local-signing-policy",
                "passed" if signing_passed else "failed",
                expected_source_commit,
                installed_digest,
            ),
        ]
    )
    developer_dir = arguments.xcode_developer_dir or default_xcode_developer_dir()
    items.append(derive_toolchain_evidence(
        provenance,
        expected_source_commit,
        installed_digest,
        developer_dir,
    ))
    items.append(derive_security_evidence(items, expected_source_commit, installed_digest))

    final_operability_authority, final_pending_state, final_gate_evidence = (
        operability_authority_from_arguments(arguments, retained_pending_state=retained_pending_state)
    )
    if final_operability_authority != operability_authority:
        fail("operability authority changed during installed report aggregation")
    if final_pending_state != pending_state or final_gate_evidence != {
        key: value
        for key, value in gate_evidence.items()
        if key in {"full-surface", "forced-legacy-grid", "native-xpc"}
    }:
        fail("pending or gate evidence authority changed during aggregation")
    _, final_cli_gui_sha256 = load_operability_report(
        arguments.cli_gui_operability_report,
        expected_kind=CLI_GUI_OPERABILITY_REPORT_KIND,
        expected_authority=final_operability_authority,
        require_complete=True,
    )
    _, final_mcp_sha256 = load_operability_report(
        arguments.mcp_operability_report,
        expected_kind=MCP_OPERABILITY_REPORT_KIND,
        expected_authority=final_operability_authority,
        require_complete=True,
    )
    if (
        final_cli_gui_sha256 != cli_gui_sha256
        or final_mcp_sha256 != mcp_sha256
    ):
        fail("operability evidence changed during installed report aggregation")
    _fresh_evidence_time(
        arguments.evidence_json,
        digest=live_evidence_sha256,
        exposed_at=exposure,
    )

    accepted, accepted_gates, deficiencies = evaluate(items, expected_source_commit)
    report = {
        "accepted": accepted,
        "acceptedGates": accepted_gates,
        "deficiencies": deficiencies,
        "evidence": canonical_evidence(items),
        "generatedAtUnixMilliseconds": (
            arguments.generated_at_unix_ms
            if arguments.generated_at_unix_ms is not None
            else int(time.time() * 1000)
        ),
        "installedExecutableSHA256": installed_digest,
        "liveEvidenceSHA256": live_evidence_sha256,
        "operabilityAuthority": operability_authority,
        "operabilityReportSHA256": {
            "cliGUI": cli_gui_sha256,
            "mcp": mcp_sha256,
        },
        "performanceThresholds": dict(PERFORMANCE_THRESHOLDS),
        "schemaVersion": INSTALLED_QUALIFICATION_REPORT_SCHEMA_VERSION,
        "sourceCommit": expected_source_commit,
        "sourceTree": expected_source_tree,
    }
    return report, pending_state, gate_evidence


def _validate_qualification_evidence_root(
    root: Path,
    *,
    arguments: argparse.Namespace,
    pending_state: dict[str, Any],
) -> None:
    protected = (
        arguments.installation_pending_state.parent,
        Path(pending_state["artifact_root"]),
        arguments.installed_app,
        arguments.source_app,
        arguments.candidate_identity,
        arguments.evidence_json,
        arguments.full_surface_report,
        arguments.legacy_grid_report,
        arguments.cli_gui_operability_report,
        arguments.mcp_operability_report,
        arguments.native_xpc_execution_report,
    )
    for path in protected:
        try:
            canonical = path.resolve(strict=True)
        except FileNotFoundError:
            try:
                canonical = path.parent.resolve(strict=True) / path.name
            except OSError as error:
                fail(f"qualification authority root is unavailable: {error}")
        except OSError as error:
            fail(f"qualification authority root is unavailable: {error}")
        if root == canonical or root.is_relative_to(canonical) or canonical.is_relative_to(root):
            fail("qualification-evidence output root must be disjoint from every input authority")


def acceptance_gate_document(
    *,
    gate_id: str,
    state: dict[str, Any],
    evidence_sha256: str,
    started_at_unix_ns: int,
    ended_at_unix_ns: int,
) -> dict[str, Any]:
    destination_identity_sha256 = hashlib.sha256(
        canonical_bytes(state["destination_identity"])
    ).hexdigest()
    document = {
        "application_executable_sha256": state["application_executable_sha256"],
        "build_provenance_sha256": state["build_provenance_sha256"],
        "candidate_file_sha256": state["candidate_file_sha256"],
        "candidate_identity_sha256": state["candidate_identity_sha256"],
        "destination_identity_sha256": destination_identity_sha256,
        "ended_at_unix_ns": ended_at_unix_ns,
        "evidence_sha256": evidence_sha256,
        "execution_identity_sha256": state["execution_identity_sha256"],
        "gate_id": gate_id,
        "input_kind": installer.ACCEPTANCE_GATE_INPUT_KIND,
        "qualification_run_id": state["qualification_run_id"],
        "qualification_run_nonce": state["qualification_run_nonce"],
        "result": "passed",
        "rolled_back": False,
        "schema_version": installer.ACCEPTANCE_GATE_INPUT_SCHEMA_VERSION,
        "source_commit": state["source_commit"],
        "source_equality_sha256": state["source_equality_sha256"],
        "source_tree": state["source_tree"],
        "started_at_unix_ns": started_at_unix_ns,
        "transaction_id": state["transaction_id"],
        "transaction_nonce": state["transaction_nonce"],
        "transaction_phase": "pending",
    }
    if set(document) != ACCEPTANCE_GATE_INPUT_FIELDS:
        fail("acceptance gate envelope does not have the exact installer schema")
    if (
        gate_id not in REQUIRED_ACCEPTANCE_GATES
        or not is_lowercase_sha256(evidence_sha256)
        or type(started_at_unix_ns) is not int
        or type(ended_at_unix_ns) is not int
        or started_at_unix_ns < state["exposed_at_unix_ns"]
        or ended_at_unix_ns < started_at_unix_ns
    ):
        fail(f"acceptance gate {gate_id} is not fresh passing evidence")
    return document


def write_acceptance_gate_outputs(
    outputs: dict[str, Path],
    *,
    state: dict[str, Any],
    gate_evidence: dict[str, tuple[str, int, int]],
) -> None:
    if tuple(sorted(outputs)) != REQUIRED_ACCEPTANCE_GATES:
        fail("acceptance gate outputs are incomplete or duplicated")
    if tuple(sorted(gate_evidence)) != REQUIRED_ACCEPTANCE_GATES:
        fail("acceptance gate evidence is incomplete or duplicated")
    payloads: dict[str, bytes] = {}
    for gate_id in REQUIRED_ACCEPTANCE_GATES:
        _canonical_absent_output(
            outputs[gate_id], label=f"acceptance gate output {gate_id}"
        )
        evidence_sha256, started, ended = gate_evidence[gate_id]
        payload = canonical_bytes(
            acceptance_gate_document(
                gate_id=gate_id,
                state=state,
                evidence_sha256=evidence_sha256,
                started_at_unix_ns=started,
                ended_at_unix_ns=ended,
            )
        )
        if len(payload) > MAXIMUM_ACCEPTANCE_GATE_OUTPUT_BYTES:
            fail(f"acceptance gate output {gate_id} exceeds one MiB")
        payloads[gate_id] = payload
    physical_files: set[tuple[int, int]] = set()
    for gate_id in REQUIRED_ACCEPTANCE_GATES:
        evidence_sha256, started, ended = gate_evidence[gate_id]
        payload = payloads[gate_id]
        mtime_ns = _write_create_only(
            outputs[gate_id], payload, label=f"acceptance gate output {gate_id}"
        )
        document, digest, observed_payload = _load_bounded_json(
            outputs[gate_id],
            label=f"acceptance gate output {gate_id}",
            canonical=True,
            maximum_bytes=MAXIMUM_ACCEPTANCE_GATE_OUTPUT_BYTES,
        )
        metadata = outputs[gate_id].lstat()
        physical = (metadata.st_dev, metadata.st_ino)
        if (
            document
            != acceptance_gate_document(
                gate_id=gate_id,
                state=state,
                evidence_sha256=evidence_sha256,
                started_at_unix_ns=started,
                ended_at_unix_ns=ended,
            )
            or digest != hashlib.sha256(payload).hexdigest()
            or observed_payload != payload
            or metadata.st_nlink != 1
            or physical in physical_files
            or mtime_ns < state["exposed_at_unix_ns"]
        ):
            fail(f"acceptance gate output {gate_id} publication is invalid")
        physical_files.add(physical)


def main(arguments: list[str] | None = None) -> int:
    try:
        parsed = parse_arguments(sys.argv[1:] if arguments is None else arguments)
        acceptance_outputs = parse_acceptance_gate_outputs(
            parsed.acceptance_gate_output,
            aggregate_output=parsed.output,
        )
        report, pending_state, gate_evidence = build_report(parsed)
        _validate_qualification_evidence_root(
            parsed.output.parent,
            arguments=parsed,
            pending_state=pending_state,
        )
        report_sha256, byte_count, report_mtime_ns = write_report(
            report, parsed.output
        )
        if report_mtime_ns < pending_state["exposed_at_unix_ns"]:
            fail("aggregate qualification report predates candidate exposure")
        if report["accepted"]:
            post_authority, post_state, post_gate_evidence = (
                operability_authority_from_arguments(parsed)
            )
            if (
                post_authority != report["operabilityAuthority"]
                or post_state != pending_state
                or post_gate_evidence
                != {
                    key: value
                    for key, value in gate_evidence.items()
                    if key
                    in {"full-surface", "forced-legacy-grid", "native-xpc"}
                }
            ):
                fail("pending or operability authority changed after aggregate publication")
            for evidence_path, expected_digest in (
                (parsed.cli_gui_operability_report, gate_evidence["cli"][0]),
                (parsed.mcp_operability_report, gate_evidence["mcp"][0]),
                (parsed.evidence_json, report["liveEvidenceSHA256"]),
            ):
                _fresh_evidence_time(
                    evidence_path,
                    digest=expected_digest,
                    exposed_at=pending_state["exposed_at_unix_ns"],
                )
            gate_evidence.update(
                {
                    "signing": (
                        report_sha256,
                        report_mtime_ns,
                        report_mtime_ns,
                    ),
                    "shellbroker-launchagent": (
                        report_sha256,
                        report_mtime_ns,
                        report_mtime_ns,
                    ),
                }
            )
            write_acceptance_gate_outputs(
                acceptance_outputs,
                state=pending_state,
                gate_evidence=gate_evidence,
            )
        if report["accepted"]:
            for gate_id in REQUIRED_ACCEPTANCE_GATES:
                print(f"{gate_id}={acceptance_outputs[gate_id]}")
        else:
            print(
                f"ERROR: aggregate qualification rejected with "
                f"{len(report['deficiencies'])} deficiencies",
                file=sys.stderr,
            )
        return 0 if report["accepted"] else 1
    except ReportError as error:
        diagnostic = str(error).replace("\n", " ").replace("\x00", "�")[:512]
        print(f"ERROR: {diagnostic}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
