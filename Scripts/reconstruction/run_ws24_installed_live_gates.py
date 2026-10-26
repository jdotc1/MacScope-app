#!/usr/bin/env python3
"""Run the six WS24 live gates against the exact installed MacScope candidate.

The installed Release process owns every live observation.  This coordinator
only validates the already-pending installation authority, launches the exact
``/Applications/MacScope.app`` executable in its reserved qualification mode,
validates the canonical terminal bytes returned by that process, and publishes
those bytes create-only after all six gates have passed.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn, Sequence

from Scripts.reconstruction import (
    install_release_to_applications as installer,
    native_live_preparation_receipt as preparation,
)
from Scripts.reconstruction_gate_f.canonical_json import (
    CanonicalJSONError,
    canonical_bytes,
    decode_canonical_bytes,
)
from Scripts.reconstruction_gate_f.receipt_validator import QualificationRunAuthority


INSTALLED_APP = Path("/Applications/MacScope.app")
INSTALLED_EXECUTABLE = INSTALLED_APP / "Contents/MacOS/MacScope"
PROVENANCE = INSTALLED_APP / "Contents/Resources/MacScopeBuildProvenance.json"
LIVE_REPORT_KIND = "ws24-live-gate-execution-report-v1"
LIVE_REPORT_SCHEMA_VERSION = 1
MAXIMUM_REPORT_BYTES = 1024 * 1024
MAXIMUM_PROVENANCE_BYTES = 16 * 1024
MAXIMUM_STDERR_BYTES = 64 * 1024
MAXIMUM_FAILURE_UTF8_BYTES = 512
MAXIMUM_PEAK_RSS_MEGABYTES = 2_048
DEFAULT_TIMEOUT_SECONDS = 1_800
MAXIMUM_TIMEOUT_SECONDS = 3_600
MINIMUM_STRESS_ATTEMPTS = 10
PREPARATION_RECEIPT_NAME = "NativeLivePreparation.receipt.json"

GIT_OID_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")


@dataclass(frozen=True)
class GateSpec:
    gate: str
    filename: str


GATES: tuple[GateSpec, ...] = (
    GateSpec(
        "installed-launch-smoke",
        "installed-launch-smoke.live-execution-report.json",
    ),
    GateSpec(
        "direct-debugger-transport-contracts",
        "direct-debugger-transport-contracts.live-execution-report.json",
    ),
    GateSpec(
        "repeated-launch-detach-stress",
        "repeated-launch-detach-stress.live-execution-report.json",
    ),
    GateSpec(
        "repeated-attach-detach-stress",
        "repeated-attach-detach-stress.live-execution-report.json",
    ),
    GateSpec(
        "repeated-restart-stress",
        "repeated-restart-stress.live-execution-report.json",
    ),
    GateSpec("performance-gate", "performance-gate.live-execution-report.json"),
)
STRESS_GATES = frozenset(
    {
        "repeated-launch-detach-stress",
        "repeated-attach-detach-stress",
        "repeated-restart-stress",
    }
)
DURATION_LIMIT_MILLISECONDS = {
    "repeated-launch-detach-stress": 15_000,
    "repeated-attach-detach-stress": 15_000,
    "repeated-restart-stress": 20_000,
}
REPORT_FIELDS = frozenset(
    {
        "attempts",
        "gate",
        "installedExecutableSHA256",
        "schemaVersion",
        "sourceCommit",
        "sourceTree",
    }
)
ATTEMPT_FIELDS = frozenset(
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
ORDERED_OPTIONS = (
    "--candidate-identity",
    "--source-app",
    "--installed-app",
    "--installation-pending-state",
    "--preparation-receipt",
    "--qualification-run-id",
    "--qualification-run-nonce",
    "--output-root",
    "--timeout-seconds",
)


class LiveGateRunnerError(RuntimeError):
    """The runner cannot publish favorable installed-live evidence."""


@dataclass(frozen=True)
class Arguments:
    candidate_identity: Path
    source_app: Path
    installed_app: Path
    installation_pending_state: Path
    preparation_receipt: Path
    qualification_run_id: str
    qualification_run_nonce: str
    output_root: Path
    timeout_seconds: int


@dataclass(frozen=True)
class Authority:
    source_commit: str
    source_tree: str
    installed_executable_sha256: str
    exposed_at_unix_ns: int
    developer_directory: Path
    source_authority: installer.SourceAuthority
    pending_state: dict[str, object]
    pending_snapshot: installer.StableFile
    preparation_snapshot: installer.StableFile
    installed_snapshot: installer.ExactBundleSnapshot
    provenance_snapshot: installer.StableFile
    preparation_receipt: dict[str, Any]
    preparation_artifacts_sha256: str


def fail(message: str) -> NoReturn:
    raise LiveGateRunnerError(message)


class _DuplicateReleaseProvenanceKey(ValueError):
    pass


def _release_provenance_object(
    pairs: list[tuple[str, object]],
) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise _DuplicateReleaseProvenanceKey(key)
        result[key] = value
    return result


def decode_release_provenance_bytes(
    payload: bytes,
    *,
    expected_sha256: object,
) -> dict[str, object]:
    """Decode the signing-policy provenance encoding and bind its exact bytes."""
    try:
        document = json.loads(
            payload,
            object_pairs_hook=_release_provenance_object,
            parse_float=lambda value: (_ for _ in ()).throw(ValueError(value)),
            parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)),
        )
    except _DuplicateReleaseProvenanceKey as error:
        fail(f"installed Release provenance contains duplicate key {error.args[0]!r}")
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        fail(f"installed Release provenance is malformed JSON: {error}")
    if not isinstance(document, dict):
        fail("installed Release provenance must be an object")
    try:
        canonical = (
            json.dumps(
                document,
                ensure_ascii=True,
                allow_nan=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        fail(f"installed Release provenance is not canonical data: {error}")
    if payload != canonical:
        fail(
            "installed Release provenance must use exact canonical signing-policy "
            "JSON encoding with one trailing LF"
        )
    if hashlib.sha256(payload).hexdigest() != expected_sha256:
        fail("installed provenance digest differs from pending authority")
    return document


def _path_value(raw: str, *, label: str) -> Path:
    if not raw or "\x00" in raw:
        fail(f"{label} must be non-empty bounded text")
    path = Path(raw)
    if not path.is_absolute():
        fail(f"{label} must be absolute")
    return path


def parse_arguments(arguments: Sequence[str]) -> Arguments:
    values = list(arguments)
    if len(values) not in {16, 18}:
        fail("runner arguments must use the frozen ordered option contract")
    expected_options = ORDERED_OPTIONS if len(values) == 18 else ORDERED_OPTIONS[:-1]
    if tuple(values[0::2]) != expected_options:
        fail("runner arguments must use the frozen ordered option contract")
    parsed = dict(zip(values[0::2], values[1::2]))
    timeout_raw = parsed.get("--timeout-seconds", str(DEFAULT_TIMEOUT_SECONDS))
    try:
        timeout_seconds = int(timeout_raw, 10)
    except ValueError:
        fail("timeout seconds must be an integer")
    if not 1 <= timeout_seconds <= MAXIMUM_TIMEOUT_SECONDS:
        fail("timeout seconds must be in 1...3600")

    installed_app = _path_value(parsed["--installed-app"], label="installed app")
    if installed_app != INSTALLED_APP:
        fail("installed app must be exactly /Applications/MacScope.app")
    run_id = parsed["--qualification-run-id"]
    nonce = parsed["--qualification-run-nonce"]
    if RUN_ID_RE.fullmatch(run_id) is None:
        fail("qualification run ID is invalid")
    if SHA256_RE.fullmatch(nonce) is None:
        fail("qualification run nonce must be a lowercase SHA-256")
    return Arguments(
        candidate_identity=_path_value(
            parsed["--candidate-identity"], label="candidate identity"
        ),
        source_app=_path_value(parsed["--source-app"], label="source app"),
        installed_app=installed_app,
        installation_pending_state=_path_value(
            parsed["--installation-pending-state"],
            label="installation pending state",
        ),
        preparation_receipt=_path_value(
            parsed["--preparation-receipt"], label="preparation receipt"
        ),
        qualification_run_id=run_id,
        qualification_run_nonce=nonce,
        output_root=_path_value(parsed["--output-root"], label="output root"),
        timeout_seconds=timeout_seconds,
    )


def _canonical_existing(path: Path, *, directory: bool, label: str) -> Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if stat.S_ISLNK(metadata.st_mode):
        fail(f"{label} must not be a symbolic link")
    if directory:
        if not stat.S_ISDIR(metadata.st_mode):
            fail(f"{label} must be a directory")
    elif not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        fail(f"{label} must be a singly linked regular file")
    try:
        canonical = path.resolve(strict=True)
    except OSError as error:
        fail(f"{label} cannot be canonicalized: {error}")
    if canonical != path:
        fail(f"{label} path must already be canonical")
    return canonical


def _require_absent_output_root(path: Path) -> None:
    try:
        path.lstat()
    except FileNotFoundError:
        pass
    except OSError as error:
        fail(f"output root cannot be inspected: {error}")
    else:
        fail("output root must begin absent")
    parent = _canonical_existing(path.parent, directory=True, label="output parent")
    if parent != path.parent or path.name in {"", ".", ".."}:
        fail("output root path is not canonical")


def _stable_equal(left: installer.StableFile, right: installer.StableFile) -> bool:
    return (
        left.path == right.path
        and left.metadata == right.metadata
        and left.payload == right.payload
    )


def _load_preparation_authority(
    path: Path,
    *,
    source_commit: str,
    source_tree: str,
) -> tuple[dict[str, Any], installer.StableFile, Path, str]:
    if path.name != PREPARATION_RECEIPT_NAME:
        fail(f"preparation receipt must be named {PREPARATION_RECEIPT_NAME}")
    try:
        snapshot = installer._stable_file(path, maximum_bytes=2 * 1024 * 1024)
        document = decode_canonical_bytes(snapshot.payload)
        receipt = preparation.parse_document(document)
    except (
        OSError,
        installer.InstallationError,
        preparation.PreparationReceiptError,
        CanonicalJSONError,
    ) as error:
        fail(f"preparation receipt is invalid: {error}")
    if receipt.get("schema_version") != preparation.SCHEMA_VERSION:
        fail("preparation receipt must use the current schema")
    source = receipt["source"]
    if source.get("commit") != source_commit or source.get("tree") != source_tree:
        fail("preparation receipt source authority differs from the candidate")
    toolchain = receipt["toolchain"]
    developer_raw = toolchain.get("developer_dir")
    if not isinstance(developer_raw, str):
        fail("preparation receipt developer directory is invalid")
    developer_directory = _canonical_existing(
        Path(developer_raw), directory=True, label="preparation developer directory"
    )
    if not str(toolchain.get("xcode_version", "")).startswith("27."):
        fail("preparation receipt does not bind Xcode 27")
    if (
        receipt["build"].get("preparation_mode")
        != preparation.NATIVE_LIVE_PREPARATION_MODE
    ):
        fail("native preparation receipt must bind the native live CoreTests mode")
    lldb = developer_directory / "usr/bin/lldb"
    if not lldb.is_file() or not os.access(lldb, os.X_OK):
        fail("preparation developer directory has no executable LLDB")
    artifacts = receipt["artifacts"]
    try:
        artifacts_sha256 = preparation.validate_prepared_artifacts(
            receipt,
            Path(artifacts["xctestrun"]["path"]),
            Path(artifacts["app"]["path"]),
        )
    except (OSError, preparation.PreparationReceiptError) as error:
        fail(f"prepared native artifacts are invalid: {error}")
    return receipt, snapshot, developer_directory, artifacts_sha256


def load_authority(arguments: Arguments) -> Authority:
    _require_absent_output_root(arguments.output_root)
    candidate_identity = _canonical_existing(
        arguments.candidate_identity,
        directory=False,
        label="candidate identity",
    )
    source_app = _canonical_existing(
        arguments.source_app, directory=True, label="source app"
    )
    installed_app = _canonical_existing(
        arguments.installed_app, directory=True, label="installed app"
    )
    if installed_app != INSTALLED_APP:
        fail("installed app canonical path changed")
    pending_state_path = _canonical_existing(
        arguments.installation_pending_state,
        directory=False,
        label="installation pending state",
    )
    preparation_path = _canonical_existing(
        arguments.preparation_receipt,
        directory=False,
        label="preparation receipt",
    )
    if preparation_path.parent != candidate_identity.parent:
        fail("preparation receipt must share the candidate identity root")

    try:
        source_authority = installer._load_source_authority(
            candidate_identity, source_app
        )
        candidate = source_authority.candidate
        expected_pending = (
            INSTALLED_APP.parent
            / f".MacScope.pending-{source_authority.candidate_identity_sha256}"
            / "transaction.json"
        )
        if pending_state_path != expected_pending:
            fail("installation pending state is outside its canonical candidate root")
        pending_state, pending_snapshot = installer._pending_read_stable(
            pending_state_path.parent
        )
        run_authority = QualificationRunAuthority(
            run_id=arguments.qualification_run_id,
            nonce=arguments.qualification_run_nonce,
        )
        installer._pending_validate_state(
            pending_state,
            authority=source_authority,
            token=source_authority.candidate_identity_sha256,
            installed_app=INSTALLED_APP,
            source_app=source_app,
            artifact_root=Path(str(pending_state.get("artifact_root", ""))),
            qualification_run=run_authority,
            predecessor_observations_sha256=str(
                pending_state.get("predecessor_observations_sha256", "")
            ),
        )
        installed_snapshot = installer._capture_exact_bundle(INSTALLED_APP)
    except installer.InstallationError as error:
        fail(f"candidate or pending installation authority is invalid: {error}")

    if not installer._snapshot_matches_record(
        installed_snapshot, pending_state["candidate_identity"]
    ):
        fail("installed app no longer matches the pending candidate identity")
    if (
        installed_snapshot.digests.content_sha256
        != candidate.application.bundle_sha256
        or installed_snapshot.digests.closed_tree_sha256
        != candidate.application.closed_tree_sha256
        or installed_snapshot.root_mode != candidate.application.root_mode
    ):
        fail("installed app tree differs from the exact candidate")

    executable = _canonical_existing(
        INSTALLED_EXECUTABLE,
        directory=False,
        label="installed executable",
    )
    provenance = _canonical_existing(
        PROVENANCE,
        directory=False,
        label="installed Release provenance",
    )
    try:
        installed_digest = installer._sha256_file(executable)
        provenance_snapshot = installer._stable_file(
            provenance, maximum_bytes=MAXIMUM_PROVENANCE_BYTES
        )
        provenance_document = decode_release_provenance_bytes(
            provenance_snapshot.payload,
            expected_sha256=pending_state.get("build_provenance_sha256"),
        )
    except installer.InstallationError as error:
        fail(f"installed executable or provenance is invalid: {error}")
    source_commit = candidate.source.commit
    source_tree = candidate.source.tree
    if GIT_OID_RE.fullmatch(source_commit) is None or GIT_OID_RE.fullmatch(source_tree) is None:
        fail("candidate source authority is malformed")
    if (
        installed_digest != source_authority.executable_sha256
        or installed_digest != candidate.application.executable_sha256
        or installed_digest != pending_state.get("application_executable_sha256")
    ):
        fail("installed executable differs from candidate/pending authority")
    if (
        provenance_document.get("schema_version") != 1
        or provenance_document.get("qualification_eligible") is not True
        or provenance_document.get("configuration") != "Release"
        or provenance_document.get("repository_clean") is not True
        or provenance_document.get("git_head_commit") != source_commit
        or provenance_document.get("git_head_tree") != source_tree
        or provenance_document.get("architecture") != "arm64"
        or provenance_document.get("deployment_target") != "27.0"
    ):
        fail("installed Release provenance differs from exact source authority")
    (
        preparation_receipt,
        preparation_snapshot,
        developer_directory,
        preparation_artifacts_sha256,
    ) = _load_preparation_authority(
        preparation_path,
        source_commit=source_commit,
        source_tree=source_tree,
    )
    exposed_at = pending_state.get("exposed_at_unix_ns")
    if type(exposed_at) is not int or exposed_at <= 0 or exposed_at > time.time_ns():
        fail("pending candidate exposure timestamp is invalid or in the future")
    return Authority(
        source_commit=source_commit,
        source_tree=source_tree,
        installed_executable_sha256=installed_digest,
        exposed_at_unix_ns=exposed_at,
        developer_directory=developer_directory,
        source_authority=source_authority,
        pending_state=dict(pending_state),
        pending_snapshot=pending_snapshot,
        preparation_snapshot=preparation_snapshot,
        installed_snapshot=installed_snapshot,
        provenance_snapshot=provenance_snapshot,
        preparation_receipt=preparation_receipt,
        preparation_artifacts_sha256=preparation_artifacts_sha256,
    )


def deterministic_seed(
    authority: Authority,
    *,
    report_gate: str,
    scenario: str,
    attempt_index: int,
) -> int:
    framed = "\x00".join(
        (
            "ws24-installed-live-seed-v1",
            authority.source_commit,
            authority.source_tree,
            authority.installed_executable_sha256,
            report_gate,
            scenario,
            str(attempt_index),
        )
    ).encode("utf-8")
    return int.from_bytes(hashlib.sha256(framed).digest()[:8], "big") & ((1 << 63) - 1)


def _closed_record(value: Any, fields: frozenset[str], *, label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        fail(f"{label} is not the exact closed record")
    return value


def _validate_attempt(
    raw: Any,
    *,
    label: str,
    exposure_unix_ns: int,
) -> dict[str, Any]:
    attempt = _closed_record(raw, ATTEMPT_FIELDS, label=label)
    index = attempt["attemptIndex"]
    started = attempt["startedAtUnixMilliseconds"]
    ended = attempt["endedAtUnixMilliseconds"]
    exit_code = attempt["exitCode"]
    failure = attempt["failure"]
    peak = attempt["peakResidentMemoryMegabytes"]
    scenario = attempt["scenario"]
    seed = attempt["seed"]
    timed_out = attempt["timedOut"]
    if type(index) is not int or index < 1:
        fail(f"{label} attemptIndex is invalid")
    if (
        type(started) is not int
        or type(ended) is not int
        or started < 0
        or ended < started
        or started * 1_000_000 < exposure_unix_ns
    ):
        fail(f"{label} timestamps are invalid or predate candidate exposure")
    if type(exit_code) is not int:
        fail(f"{label} exitCode is invalid")
    if failure is not None:
        if not isinstance(failure, str) or not failure:
            fail(f"{label} failure is invalid")
        try:
            failure_size = len(failure.encode("utf-8"))
        except UnicodeEncodeError:
            failure_size = MAXIMUM_FAILURE_UTF8_BYTES + 1
        if failure_size > MAXIMUM_FAILURE_UTF8_BYTES:
            fail(f"{label} failure exceeds its UTF-8 bound")
    if peak is not None and (type(peak) is not int or peak < 0):
        fail(f"{label} peak RSS is invalid or noncanonical")
    if not isinstance(scenario, str) or scenario not in STRESS_GATES | {
        "installed-launch-smoke",
        "direct-debugger-transport-contracts",
    }:
        fail(f"{label} scenario is invalid")
    if seed is not None and (type(seed) is not int or seed < 0):
        fail(f"{label} seed is invalid")
    if type(timed_out) is not bool:
        fail(f"{label} timedOut is invalid")
    if exit_code != 0 or failure is not None or timed_out:
        fail(f"{label} did not pass inside installed-app authority")
    return attempt


def validate_report_payload(payload: bytes, spec: GateSpec, authority: Authority) -> bytes:
    if not payload or len(payload) > MAXIMUM_REPORT_BYTES or payload.endswith(b"\n"):
        fail(f"{spec.gate} terminal report violates its byte bound or no-LF contract")
    try:
        decoded = decode_canonical_bytes(payload)
    except CanonicalJSONError as error:
        fail(f"{spec.gate} terminal report is not canonical JSON: {error}")
    report = _closed_record(decoded, REPORT_FIELDS, label=f"{spec.gate} report")
    if (
        report["schemaVersion"] != LIVE_REPORT_SCHEMA_VERSION
        or report["gate"] != spec.gate
        or report["sourceCommit"] != authority.source_commit
        or report["sourceTree"] != authority.source_tree
        or report["installedExecutableSHA256"]
        != authority.installed_executable_sha256
    ):
        fail(f"{spec.gate} terminal report belongs to another candidate")
    raw_attempts = report["attempts"]
    if not isinstance(raw_attempts, list) or not raw_attempts:
        fail(f"{spec.gate} report attempts must be non-empty")
    attempts = [
        _validate_attempt(
            raw,
            label=f"{spec.gate} attempt {offset + 1}",
            exposure_unix_ns=authority.exposed_at_unix_ns,
        )
        for offset, raw in enumerate(raw_attempts)
    ]
    if spec.gate in {
        "installed-launch-smoke",
        "direct-debugger-transport-contracts",
    }:
        attempt = attempts[0]
        if (
            len(attempts) != 1
            or attempt["attemptIndex"] != 1
            or attempt["scenario"] != spec.gate
            or attempt["seed"] is not None
            or attempt["peakResidentMemoryMegabytes"] is not None
        ):
            fail(f"{spec.gate} simple-gate attempt contract is invalid")
    elif spec.gate in STRESS_GATES:
        if len(attempts) != MINIMUM_STRESS_ATTEMPTS:
            fail(f"{spec.gate} must contain exactly ten real attempts")
        for index, attempt in enumerate(attempts, start=1):
            expected_seed = deterministic_seed(
                authority,
                report_gate=spec.gate,
                scenario=spec.gate,
                attempt_index=index,
            )
            if (
                attempt["attemptIndex"] != index
                or attempt["scenario"] != spec.gate
                or attempt["seed"] != expected_seed
                or attempt["peakResidentMemoryMegabytes"] is not None
            ):
                fail(f"{spec.gate} stress attempt authority is invalid")
    else:
        expected_count = MINIMUM_STRESS_ATTEMPTS * len(STRESS_GATES)
        if len(attempts) != expected_count:
            fail("performance gate must contain exactly thirty real attempts")
        offset = 0
        for scenario in (
            "repeated-launch-detach-stress",
            "repeated-attach-detach-stress",
            "repeated-restart-stress",
        ):
            scenario_attempts = attempts[offset : offset + MINIMUM_STRESS_ATTEMPTS]
            offset += MINIMUM_STRESS_ATTEMPTS
            for index, attempt in enumerate(scenario_attempts, start=1):
                expected_seed = deterministic_seed(
                    authority,
                    report_gate=spec.gate,
                    scenario=scenario,
                    attempt_index=index,
                )
                peak = attempt["peakResidentMemoryMegabytes"]
                if (
                    attempt["attemptIndex"] != index
                    or attempt["scenario"] != scenario
                    or attempt["seed"] != expected_seed
                    or type(peak) is not int
                    or peak > MAXIMUM_PEAK_RSS_MEGABYTES
                    or attempt["endedAtUnixMilliseconds"]
                    - attempt["startedAtUnixMilliseconds"]
                    > DURATION_LIMIT_MILLISECONDS[scenario]
                ):
                    fail(f"performance attempt authority is invalid for {scenario}")
    if canonical_bytes(report) != payload:
        fail(f"{spec.gate} terminal report bytes changed during validation")
    return payload


def _installed_process_environment(authority: Authority) -> dict[str, str]:
    allowed = ("HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL")
    environment = {
        key: os.environ[key]
        for key in allowed
        if key in os.environ and "\x00" not in os.environ[key]
    }
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["DEVELOPER_DIR"] = str(authority.developer_directory)
    return environment


def installed_gate_argv(spec: GateSpec, authority: Authority) -> list[str]:
    return [
        str(INSTALLED_EXECUTABLE),
        "--ws24-installed-live-gate",
        spec.gate,
        "--source-commit",
        authority.source_commit,
        "--source-tree",
        authority.source_tree,
        "--installed-executable-sha256",
        authority.installed_executable_sha256,
        "--pending-exposed-at-unix-nanoseconds",
        str(authority.exposed_at_unix_ns),
        "--developer-directory",
        str(authority.developer_directory),
    ]


def _terminate_owned_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        process_group = os.getpgid(process.pid)
    except (OSError, ProcessLookupError):
        return
    if process_group != process.pid:
        return
    for sig, grace in ((signal.SIGTERM, 1.0), (signal.SIGKILL, 1.0)):
        try:
            os.killpg(process_group, sig)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=grace)
            return
        except subprocess.TimeoutExpired:
            continue


def _drain_owned_process_group(process_group: int) -> None:
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process_group, 0)
        except ProcessLookupError:
            return
        except OSError as error:
            fail(f"owned installed live-gate process group cannot be inspected: {error}")
        try:
            os.killpg(process_group, sig)
        except ProcessLookupError:
            return
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            try:
                os.killpg(process_group, 0)
            except ProcessLookupError:
                return
            except OSError as error:
                fail(f"owned installed live-gate process group cannot be fenced: {error}")
            time.sleep(0.01)
    fail("owned installed live-gate process group left residual processes")


def _capture_bounded_process(
    process: subprocess.Popen[bytes],
    *,
    deadline: float,
) -> tuple[int, bytes, bytes]:
    if process.stdout is None or process.stderr is None:
        fail("installed gate process did not expose bounded pipes")
    selector = selectors.DefaultSelector()
    streams = {process.stdout.fileno(): (process.stdout, bytearray(), MAXIMUM_REPORT_BYTES),
               process.stderr.fileno(): (process.stderr, bytearray(), MAXIMUM_STDERR_BYTES)}
    try:
        for descriptor, (stream, _, _) in streams.items():
            os.set_blocking(descriptor, False)
            selector.register(stream, selectors.EVENT_READ, descriptor)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _terminate_owned_process_group(process)
                fail("installed live-gate process exceeded the overall timeout")
            events = selector.select(min(0.1, remaining))
            if not events and process.poll() is not None:
                events = [
                    (key, selectors.EVENT_READ)
                    for key in tuple(selector.get_map().values())
                ]
            for key, _ in events:
                descriptor = key.data
                stream, buffer, maximum = streams[descriptor]
                try:
                    chunk = os.read(descriptor, 16 * 1024)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(stream)
                    continue
                buffer.extend(chunk)
                if len(buffer) > maximum:
                    _terminate_owned_process_group(process)
                    fail("installed live-gate output exceeded its bounded capture")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            _terminate_owned_process_group(process)
            fail("installed live-gate process exceeded the overall timeout")
        try:
            return_code = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            _terminate_owned_process_group(process)
            fail("installed live-gate process exceeded the overall timeout")
        return (
            return_code,
            bytes(streams[process.stdout.fileno()][1]),
            bytes(streams[process.stderr.fileno()][1]),
        )
    finally:
        selector.close()
        process.stdout.close()
        process.stderr.close()


def run_installed_gate(spec: GateSpec, authority: Authority, *, deadline: float) -> bytes:
    if deadline <= time.monotonic():
        fail("overall installed live-gate timeout expired before dispatch")
    process = subprocess.Popen(
        installed_gate_argv(spec, authority),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=str(INSTALLED_APP.parent),
        env=_installed_process_environment(authority),
        start_new_session=True,
    )
    return_code, standard_output, _standard_error = _capture_bounded_process(
        process, deadline=deadline
    )
    _drain_owned_process_group(process.pid)
    if return_code != 0:
        fail(f"{spec.gate} installed-app authority exited {return_code}")
    return validate_report_payload(standard_output, spec, authority)


def assert_authority_unchanged(authority: Authority, *, final: bool) -> None:
    try:
        installer._require_source_unchanged(
            authority.source_authority,
            phase="WS24 installed live-gate authority fence",
        )
        current_pending, pending_snapshot = installer._pending_read_stable(
            authority.pending_snapshot.path.parent
        )
        preparation_snapshot = installer._stable_file(
            authority.preparation_snapshot.path,
            maximum_bytes=2 * 1024 * 1024,
        )
        provenance_snapshot = installer._stable_file(
            authority.provenance_snapshot.path,
            maximum_bytes=1024 * 1024,
        )
        installed_digest = installer._sha256_file(INSTALLED_EXECUTABLE)
        if final:
            installed_snapshot = installer._capture_exact_bundle(INSTALLED_APP)
            preparation_artifacts_sha256 = preparation.validate_prepared_artifacts(
                authority.preparation_receipt,
                Path(authority.preparation_receipt["artifacts"]["xctestrun"]["path"]),
                Path(authority.preparation_receipt["artifacts"]["app"]["path"]),
            )
        else:
            installed_snapshot = None
            preparation_artifacts_sha256 = authority.preparation_artifacts_sha256
    except (installer.InstallationError, preparation.PreparationReceiptError) as error:
        fail(f"candidate authority changed during installed live gates: {error}")
    if (
        current_pending != authority.pending_state
        or not _stable_equal(pending_snapshot, authority.pending_snapshot)
        or not _stable_equal(preparation_snapshot, authority.preparation_snapshot)
        or not _stable_equal(provenance_snapshot, authority.provenance_snapshot)
        or installed_digest != authority.installed_executable_sha256
        or preparation_artifacts_sha256 != authority.preparation_artifacts_sha256
    ):
        fail("pending/candidate/source authority changed during installed live gates")
    if final and (
        installed_snapshot is None
        or installed_snapshot.digests != authority.installed_snapshot.digests
        or installed_snapshot.root_mode != authority.installed_snapshot.root_mode
        or installed_snapshot.tree.root != authority.installed_snapshot.tree.root
    ):
        fail("installed app tree changed during installed live gates")


def _create_output_root(path: Path) -> int:
    _require_absent_output_root(path)
    parent_descriptor = os.open(
        path.parent,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        os.mkdir(path.name, 0o700, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    except OSError as error:
        os.close(parent_descriptor)
        fail(f"cannot create private output root: {error}")
    os.close(parent_descriptor)
    descriptor = os.open(
        path,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0),
    )
    metadata = os.fstat(descriptor)
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o700:
        os.close(descriptor)
        try:
            os.rmdir(path)
        except OSError:
            pass
        fail("private output root identity is invalid")
    return descriptor


def _write_report_file(
    root_descriptor: int,
    spec: GateSpec,
    payload: bytes,
    *,
    exposed_at_unix_ns: int,
) -> tuple[int, int]:
    descriptor = -1
    created_identity: tuple[int, int] | None = None
    try:
        descriptor = os.open(
            spec.filename,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            0o600,
            dir_fd=root_descriptor,
        )
        created_metadata = os.fstat(descriptor)
        created_identity = (created_metadata.st_dev, created_metadata.st_ino)
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                fail(f"{spec.gate} report write made no progress")
            offset += written
        os.fsync(descriptor)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_size != len(payload)
            or metadata.st_mtime_ns < exposed_at_unix_ns
        ):
            fail(f"{spec.gate} published report identity or freshness is invalid")
        os.close(descriptor)
        descriptor = -1
        read_descriptor = os.open(
            spec.filename,
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            dir_fd=root_descriptor,
        )
        try:
            read_metadata = os.fstat(read_descriptor)
            if (read_metadata.st_dev, read_metadata.st_ino) != created_identity:
                fail(f"{spec.gate} report identity changed before readback")
            chunks: list[bytes] = []
            remaining = len(payload) + 1
            while remaining > 0:
                chunk = os.read(read_descriptor, min(64 * 1024, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            if b"".join(chunks) != payload:
                fail(f"{spec.gate} report bytes changed during create-only publication")
        finally:
            os.close(read_descriptor)
        return created_identity
    except (OSError, LiveGateRunnerError) as error:
        if created_identity is not None:
            try:
                observed = os.stat(
                    spec.filename,
                    dir_fd=root_descriptor,
                    follow_symlinks=False,
                )
                if (observed.st_dev, observed.st_ino) == created_identity:
                    os.unlink(spec.filename, dir_fd=root_descriptor)
            except OSError:
                pass
        if isinstance(error, LiveGateRunnerError):
            raise
        fail(f"cannot publish {spec.gate} report: {error}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _remove_created_output_root(
    path: Path,
    *,
    root_identity: tuple[int, int],
) -> None:
    try:
        parent_descriptor = os.open(
            path.parent,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError:
        return
    try:
        observed = os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (
            stat.S_ISDIR(observed.st_mode)
            and (observed.st_dev, observed.st_ino) == root_identity
        ):
            os.rmdir(path.name, dir_fd=parent_descriptor)
            os.fsync(parent_descriptor)
    except OSError:
        pass
    finally:
        os.close(parent_descriptor)


def publish_reports(
    output_root: Path,
    reports: Sequence[tuple[GateSpec, bytes]],
    *,
    exposed_at_unix_ns: int,
) -> None:
    if tuple(spec for spec, _ in reports) != GATES:
        fail("publication requires the exact ordered six-gate set")
    root_descriptor = _create_output_root(output_root)
    root_metadata = os.fstat(root_descriptor)
    root_identity = (root_metadata.st_dev, root_metadata.st_ino)
    created: dict[str, tuple[int, int]] = {}
    succeeded = False
    try:
        for spec, payload in reports:
            created[spec.filename] = _write_report_file(
                root_descriptor,
                spec,
                payload,
                exposed_at_unix_ns=exposed_at_unix_ns,
            )
        os.fsync(root_descriptor)
        names = sorted(os.listdir(root_descriptor))
        if names != sorted(spec.filename for spec in GATES):
            fail("output root does not contain exactly the six governed reports")
        succeeded = True
    finally:
        if not succeeded:
            for name, identity in reversed(tuple(created.items())):
                try:
                    observed = os.stat(
                        name,
                        dir_fd=root_descriptor,
                        follow_symlinks=False,
                    )
                    if (observed.st_dev, observed.st_ino) == identity:
                        os.unlink(name, dir_fd=root_descriptor)
                except OSError:
                    pass
            try:
                os.fsync(root_descriptor)
            except OSError:
                pass
        os.close(root_descriptor)
        if not succeeded:
            _remove_created_output_root(
                output_root,
                root_identity=root_identity,
            )


def run(arguments: Arguments) -> Path:
    authority = load_authority(arguments)
    deadline = time.monotonic() + arguments.timeout_seconds
    reports: list[tuple[GateSpec, bytes]] = []
    for spec in GATES:
        payload = run_installed_gate(spec, authority, deadline=deadline)
        reports.append((spec, payload))
        assert_authority_unchanged(authority, final=False)
    assert_authority_unchanged(authority, final=True)
    if deadline <= time.monotonic():
        fail("overall installed live-gate timeout expired before publication")
    publish_reports(
        arguments.output_root,
        reports,
        exposed_at_unix_ns=authority.exposed_at_unix_ns,
    )
    return arguments.output_root


def main(arguments: Sequence[str] | None = None) -> int:
    try:
        parsed = parse_arguments(sys.argv[1:] if arguments is None else arguments)
        output_root = run(parsed)
    except LiveGateRunnerError as error:
        print(f"ERROR: WS24 installed live gates failed: {error}", file=sys.stderr)
        return 1
    print(f"MACSCOPE_WS24_INSTALLED_LIVE_GATE_ROOT={output_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
