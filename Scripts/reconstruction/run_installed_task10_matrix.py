#!/usr/bin/env python3
"""Run the catalog-owned installed Task 10 matrix and seal its physical identity."""

from __future__ import annotations

import argparse
from collections import Counter
import json
import os
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts.reconstruction.installed_matrix_receipt import (  # noqa: E402
    InstalledMatrixReceiptError,
    assert_input_snapshot_equal,
    capture_input_snapshot,
    create_document,
    expected_argv,
    expected_environment,
    preflight_execution,
    write_execution_xctestrun_create_only,
    write_create_only,
)
from Scripts.reconstruction.app_preference_recovery import (  # noqa: E402
    PreferenceRecoveryError,
    RESTORATION_FAILURE_NOTE,
    WRITER_UNSETTLED_NOTE,
    JOURNAL_CLOSEOUT_FAILURE_NOTE,
    _mark_provider_preference_writer_unsettled,
    run_with_isolated_provider_preference_recovery as run_with_provider_preference_recovery,
)
from Scripts.reconstruction.audit_installed_network_acquisition import (  # noqa: E402
    AuditInputError,
    EXECUTION_REPORT_NAME as NETWORK_EXECUTION_REPORT_NAME,
    OBSERVATION_NAME as NETWORK_OBSERVATION_NAME,
    REPORT_NAME as NETWORK_REPORT_NAME,
    audit_matrix_workload,
)
from Scripts.ws24_emit_installed_qualification_report import (  # noqa: E402
    ReportError,
    exclusively_passed_case,
    load_installed_selector_catalog,
    installed_selector_projection,
    result_bundle_sha256,
    xcresult_test_cases,
    xcresult_test_nodes,
    xcresult_test_summary,
)
from Scripts.reconstruction_gate_f.canonical_json import canonical_sha256  # noqa: E402
from Scripts.reconstruction_gate_f.receipt_validator import (  # noqa: E402
    QualificationRunAuthority,
)


PROCESS_GROUP_TERM_GRACE_SECONDS = 5.0
PROCESS_GROUP_KILL_GRACE_SECONDS = 5.0
PROCESS_GROUP_POLL_INTERVAL_SECONDS = 0.05


def _process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # EPERM proves existence, not ownership. Keep waiting; escalation must
        # separately prove the parent-owned leader has not been reaped.
        return True
    return True


def _wait_for_process_group_exit(
    process: subprocess.Popen[str],
    process_group_id: int,
    timeout_seconds: float,
) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while True:
        process.poll()
        if not _process_group_exists(process_group_id):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(PROCESS_GROUP_POLL_INTERVAL_SECONDS)


def _signal_task_owned_process_group(
    process: subprocess.Popen[str],
    process_group_id: int,
    process_signal: signal.Signals,
) -> None:
    if process_group_id != process.pid:
        raise InstalledMatrixReceiptError(
            "refusing to signal a process group not owned by the installed matrix"
        )
    # Like command_execution._signal_owned, only an unreaped leader prevents
    # numeric PID/PGID reuse. Poll may itself reap it: check before EVERY signal.
    if process.poll() is not None:
        raise InstalledMatrixReceiptError(
            "installed-matrix process group ownership unproven after leader reap"
        )
    try:
        os.killpg(process_group_id, process_signal)
    except ProcessLookupError:
        return
    except PermissionError as error:
        raise InstalledMatrixReceiptError(
            "cannot signal the task-owned installed-matrix process group"
        ) from error


def _terminate_timed_out_process_group(
    process: subprocess.Popen[str],
    process_group_id: int,
    *,
    term_grace_seconds: float = PROCESS_GROUP_TERM_GRACE_SECONDS,
    kill_grace_seconds: float = PROCESS_GROUP_KILL_GRACE_SECONDS,
) -> None:
    """Boundedly settle writers while unreaped-leader ownership remains proven."""
    _signal_task_owned_process_group(process, process_group_id, signal.SIGTERM)
    if _wait_for_process_group_exit(process, process_group_id, term_grace_seconds):
        return
    _signal_task_owned_process_group(process, process_group_id, signal.SIGKILL)
    if not _wait_for_process_group_exit(process, process_group_id, kill_grace_seconds):
        raise InstalledMatrixReceiptError(
            "timed-out installed-matrix process group still has live descendants"
        )


def _run_xcodebuild_process_group(
    command: list[str],
    environment: dict[str, str],
    timeout_seconds: int,
    *,
    term_grace_seconds: float = PROCESS_GROUP_TERM_GRACE_SECONDS,
    kill_grace_seconds: float = PROCESS_GROUP_KILL_GRACE_SECONDS,
) -> tuple[int, bool]:
    """Run xcodebuild in a dedicated session and leave no timed-out children."""
    process = subprocess.Popen(
        command,
        env=environment,
        text=True,
        start_new_session=True,
    )
    try:
        process_group_id = os.getpgid(process.pid)
    except ProcessLookupError:
        try:
            if not _wait_for_process_group_exit(process, process.pid, kill_grace_seconds):
                raise InstalledMatrixReceiptError("exited installed-matrix leader has live descendants")
            return process.wait(), False
        except BaseException as original:
            _mark_provider_preference_writer_unsettled(original)
            raise
    except BaseException as original:
        _mark_provider_preference_writer_unsettled(original)
        raise
    if process_group_id != process.pid:
        try:
            process.kill()
            process.wait()
        except BaseException as original:
            _mark_provider_preference_writer_unsettled(original)
            raise
        error = InstalledMatrixReceiptError(
            "xcodebuild did not enter its dedicated task-owned process group"
        )
        _mark_provider_preference_writer_unsettled(error)
        raise error
    try:
        returncode = process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        try:
            _terminate_timed_out_process_group(
                process,
                process_group_id,
                term_grace_seconds=term_grace_seconds,
                kill_grace_seconds=kill_grace_seconds,
            )
        except BaseException as error:
            _mark_provider_preference_writer_unsettled(error)
            raise
        return 124, True
    except BaseException as original:
        # An interrupted wait can reap before assigning returncode. Its unknown
        # outcome cannot authorize signalling even when returncode is still None.
        _mark_provider_preference_writer_unsettled(original)
        raise
    # A successfully exited leader alone does not settle its preference writers.
    try:
        settled = _wait_for_process_group_exit(process, process_group_id, kill_grace_seconds)
    except BaseException as original:
        _mark_provider_preference_writer_unsettled(original)
        raise
    if not settled:
        error = InstalledMatrixReceiptError("completed installed-matrix process group still has live descendants")
        _mark_provider_preference_writer_unsettled(error)
        raise error
    return returncode, False


def _validate_xcresult_documents(
    summary: object,
    tests: object,
    selectors: list[str],
) -> dict[str, object]:
    """Require exact one-to-one execution of the catalog-owned 22 selectors."""
    if not isinstance(summary, dict) or not isinstance(tests, dict):
        raise InstalledMatrixReceiptError("xcresult summary and tests must be objects")
    count_fields = (
        "totalTestCount",
        "passedTests",
        "failedTests",
        "skippedTests",
        "expectedFailures",
    )
    counts: dict[str, int] = {}
    for field in count_fields:
        value = summary.get(field)
        if type(value) is not int or value < 0:
            raise InstalledMatrixReceiptError(f"xcresult has invalid {field}")
        counts[field] = value
    if (
        summary.get("title") != "Test - MacScopeInstalledAppUITests"
        or summary.get("result") != "Passed"
        or counts["totalTestCount"] != len(selectors)
        or counts["passedTests"] != len(selectors)
        or counts["failedTests"] != 0
        or counts["skippedTests"] != 0
        or counts["expectedFailures"] != 0
        or sum(counts[field] for field in count_fields[1:])
        != counts["totalTestCount"]
    ):
        raise InstalledMatrixReceiptError(
            "xcresult did not execute and exclusively pass the exact installed selector count"
        )
    try:
        cases = xcresult_test_cases(tests, 0)
    except ReportError as error:
        raise InstalledMatrixReceiptError(f"xcresult test nodes are invalid: {error}") from error
    observed = [case["identifier"] for case in cases]
    if (
        Counter(observed) != Counter(selectors)
        or len(observed) != len(selectors)
        or any(not case["inExpectedBundle"] or not case["inExpectedSuite"] for case in cases)
    ):
        raise InstalledMatrixReceiptError(
            "xcresult selectors differ from the exact installed selector catalog"
        )
    try:
        for case in cases:
            exclusively_passed_case(case["node"], 0)
    except ReportError as error:
        raise InstalledMatrixReceiptError(f"xcresult contains a non-passed selector: {error}") from error
    case_by_identifier = {case["identifier"]: case for case in cases}
    return {
        "expected_selector_count": len(selectors),
        "executed_selector_count": len(observed),
        "passed_selector_count": counts["passedTests"],
        "failed_selector_count": counts["failedTests"],
        "skipped_selector_count": counts["skippedTests"],
        "selectors": [
            {
                "test_identifier": identifier,
                "status": str(case_by_identifier[identifier]["node"]["result"]).lower(),
            }
            for identifier in selectors
        ],
    }


def _validate_exact_xcresult(xcresult: Path, selectors: list[str]) -> dict[str, object]:
    try:
        summary = xcresult_test_summary(xcresult, 0)
        tests = xcresult_test_nodes(xcresult, 0)
    except ReportError as error:
        raise InstalledMatrixReceiptError(f"cannot inspect exact xcresult: {error}") from error
    return _validate_xcresult_documents(summary, tests, selectors)


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run and seal the exact installed Task 10 XCUITest matrix."
    )
    parser.add_argument("--candidate-identity", type=Path, required=True)
    parser.add_argument("--preparation-receipt", type=Path, required=True)
    parser.add_argument("--installed-app", type=Path, default=Path("/Applications/MacScope.app"))
    parser.add_argument("--xctestrun", type=Path, required=True)
    parser.add_argument("--test-bundle", type=Path, required=True)
    parser.add_argument("--ui-runner", type=Path, required=True)
    parser.add_argument("--xcresult", type=Path, required=True)
    parser.add_argument("--xcresult-semantic-manifest", type=Path, required=True)
    parser.add_argument("--receipt-output", type=Path, required=True)
    parser.add_argument("--network-artifact-root", type=Path, required=True)
    parser.add_argument("--qualification-run-id", required=True)
    parser.add_argument("--qualification-run-nonce", required=True)
    parser.add_argument("--predecessor-observations-sha256", required=True)
    parser.add_argument("--developer-dir", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, default=1800)
    return parser.parse_args(argv)


def _canonical_absent(path: Path, name: str) -> Path:
    if not path.is_absolute() or path.exists() or path.is_symlink():
        raise InstalledMatrixReceiptError(f"{name} must be an absent absolute path")
    parent = _non_symlink_existing(path.parent, name=f"{name} parent", directory=True)
    if parent != path.parent:
        raise InstalledMatrixReceiptError(f"{name} parent must already be canonical")
    return parent / path.name


def _non_symlink_existing(path: Path, *, name: str, directory: bool) -> Path:
    if not path.is_absolute():
        raise InstalledMatrixReceiptError(f"{name} must be absolute")
    try:
        metadata = path.lstat()
    except OSError as error:
        raise InstalledMatrixReceiptError(f"{name} is unavailable: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not (stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)):
        raise InstalledMatrixReceiptError(f"{name} must be an existing non-symlink {'directory' if directory else 'file'}")
    canonical = path.resolve(strict=True)
    if canonical != path:
        raise InstalledMatrixReceiptError(f"{name} must already be canonical")
    return canonical


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        qualification_run = QualificationRunAuthority(
            run_id=arguments.qualification_run_id,
            nonce=arguments.qualification_run_nonce,
        )
        xcresult = _canonical_absent(arguments.xcresult, "xcresult")
        xcresult_semantic_manifest = _canonical_absent(
            arguments.xcresult_semantic_manifest,
            "xcresult semantic manifest",
        )
        receipt_output = _canonical_absent(arguments.receipt_output, "receipt output")
        catalog = load_installed_selector_catalog()
        selector_projection = installed_selector_projection(catalog)
        selectors = [item["test_identifier"] for item in selector_projection]
        developer_dir = _non_symlink_existing(arguments.developer_dir, name="developer directory", directory=True)
        xcodebuild = developer_dir / "usr/bin/xcodebuild"
        xcodebuild = _non_symlink_existing(xcodebuild, name="xcodebuild", directory=False)
        if not os.access(xcodebuild, os.X_OK):
            raise InstalledMatrixReceiptError(
                "developer directory has no executable xcodebuild"
            )
        prepared_xctestrun = _non_symlink_existing(
            arguments.xctestrun, name="prepared xctestrun", directory=False
        )
        installed_app = _non_symlink_existing(arguments.installed_app, name="installed app", directory=True)
        test_bundle = _non_symlink_existing(arguments.test_bundle, name="test bundle", directory=True)
        ui_runner = _non_symlink_existing(arguments.ui_runner, name="UI runner", directory=True)
        candidate_identity = _non_symlink_existing(arguments.candidate_identity, name="candidate identity", directory=False)
        preparation_receipt = _non_symlink_existing(arguments.preparation_receipt, name="preparation receipt", directory=False)
        execution_identity = canonical_sha256(
            {
                "prepared_xctestrun": str(prepared_xctestrun),
                "receipt_output": str(receipt_output),
                "xcresult": str(xcresult),
            }
        )
        execution_xctestrun = _canonical_absent(
            prepared_xctestrun.with_name(
                f"{prepared_xctestrun.stem}-Task10OptIn-{execution_identity}"
                f"{prepared_xctestrun.suffix}"
            ),
            "execution xctestrun",
        )
        execution_xctestrun_sha256 = write_execution_xctestrun_create_only(
            prepared_xctestrun,
            execution_xctestrun,
            installed_app,
        )
        command = expected_argv(xcodebuild, execution_xctestrun, xcresult, selectors)
        recorded_environment = expected_environment(
            developer_dir, installed_app, dict(os.environ)
        )
        before_snapshot = preflight_execution(
            candidate_identity_path=candidate_identity,
            preparation_receipt_path=preparation_receipt,
            installed_app=installed_app,
            prepared_xctestrun=prepared_xctestrun,
            execution_xctestrun=execution_xctestrun,
            test_bundle=test_bundle,
            ui_runner=ui_runner,
            xcodebuild=xcodebuild,
            expected_xcresult=xcresult,
            argv=command,
            selectors=selectors,
            selector_projection=selector_projection,
            environment=recorded_environment,
        )
        def execute_exact_matrix() -> tuple[
            tuple[int, bool, dict[str, object], str], dict[str, object]
        ]:
            started = int(time.time() * 1000)
            exit_code, timed_out = run_with_provider_preference_recovery(
                (installed_app,),
                lambda: _run_xcodebuild_process_group(
                    command,
                    recorded_environment,
                    arguments.timeout_seconds,
                ),
            )
            ended = int(time.time() * 1000)
            after_snapshot = capture_input_snapshot(
                candidate_identity_path=candidate_identity,
                preparation_receipt_path=preparation_receipt,
                installed_app=installed_app,
                prepared_xctestrun=prepared_xctestrun,
                execution_xctestrun=execution_xctestrun,
                test_bundle=test_bundle,
                ui_runner=ui_runner,
                xcodebuild=xcodebuild,
            )
            assert_input_snapshot_equal(before_snapshot, after_snapshot)
            result_bundle = xcresult if xcresult.is_dir() else None
            failure = None
            if result_bundle is None:
                failure = "xcodebuild did not produce the required xcresult bundle"
            document = create_document(
                candidate_identity_path=candidate_identity,
                preparation_receipt_path=preparation_receipt,
                installed_app=installed_app,
                prepared_xctestrun=prepared_xctestrun,
                execution_xctestrun=execution_xctestrun,
                test_bundle=test_bundle,
                ui_runner=ui_runner,
                xcresult=result_bundle,
                argv=command,
                selectors=selectors,
                selector_projection=selector_projection,
                environment=recorded_environment,
                started_at_unix_ms=started,
                ended_at_unix_ms=ended,
                exit_code=exit_code,
                failure=failure,
                input_snapshot_before=before_snapshot,
                input_snapshot_after=after_snapshot,
            )
            receipt_file_sha256 = canonical_sha256(document)
            selector_semantics: dict[str, object] = {
                "expected_selector_count": len(selectors),
                "executed_selector_count": 0,
                "passed_selector_count": 0,
                "failed_selector_count": 0,
                "skipped_selector_count": 0,
                "selectors": [],
            }
            xcresult_bundle_digest: str | None = None
            xcresult_closed_tree_digest: str | None = None
            if document["execution"]["result"] == "passed" and result_bundle is not None:
                selector_semantics = _validate_exact_xcresult(result_bundle, selectors)
                try:
                    xcresult_bundle_digest = result_bundle_sha256(result_bundle)
                except ReportError as error:
                    raise InstalledMatrixReceiptError(
                        f"cannot seal exact xcresult tree: {error}"
                    ) from error
                xcresult_closed_tree_digest = document["products"]["xcresult"][
                    "closed_tree_sha256"
                ]
            if (
                document["execution"]["result"] != "passed"
                or xcresult_bundle_digest is None
                or xcresult_closed_tree_digest is None
            ):
                raise InstalledMatrixReceiptError(
                    "cannot emit favorable installed evidence without an exact passing xcresult"
                )
            observed_selector_projection = document["accessibility_observations"][
                "observed_selector_projection"
            ]
            semantic_manifest: dict[str, object] = {
                "schema_version": 3,
                "candidate_identity_sha256": document["candidate"]["identity_sha256"],
                "source_xcresult": {
                    "bundle_sha256": xcresult_bundle_digest,
                    "closed_tree_sha256": xcresult_closed_tree_digest,
                },
                "selector_catalog_sha256": canonical_sha256(selectors),
                "selector_projection": selector_projection,
                "selector_projection_sha256": canonical_sha256(selector_projection),
                "observed_selector_projection": observed_selector_projection,
                "observed_selector_projection_sha256": canonical_sha256(
                    observed_selector_projection
                ),
                "expected_selector_count": selector_semantics["expected_selector_count"],
                "executed_selector_count": selector_semantics["executed_selector_count"],
                "passed_selector_count": selector_semantics["passed_selector_count"],
                "failed_selector_count": selector_semantics["failed_selector_count"],
                "skipped_selector_count": selector_semantics["skipped_selector_count"],
                "selectors": selector_semantics["selectors"],
                "result": "passed",
            }
            semantic_manifest_sha256 = write_create_only(
                xcresult_semantic_manifest,
                semantic_manifest,
            )
            written_receipt_sha256 = write_create_only(receipt_output, document)
            if written_receipt_sha256 != receipt_file_sha256:
                raise InstalledMatrixReceiptError(
                    "installed matrix receipt publication changed canonical bytes"
                )
            evidence: dict[str, object] = {
                "matrix_receipt_sha256": receipt_file_sha256,
                "xcresult_bundle_sha256": xcresult_bundle_digest,
                "xcresult_closed_tree_sha256": xcresult_closed_tree_digest,
                "selector_catalog_sha256": canonical_sha256(selectors),
                "selector_projection_sha256": canonical_sha256(selector_projection),
                "xcresult_semantic_manifest_sha256": semantic_manifest_sha256,
                **{
                    key: selector_semantics[key]
                    for key in (
                        "expected_selector_count",
                        "executed_selector_count",
                        "passed_selector_count",
                        "failed_selector_count",
                        "skipped_selector_count",
                    )
                },
                "matrix_result": document["execution"]["result"],
            }
            return (exit_code, timed_out, document, receipt_file_sha256), evidence

        (
            exit_code,
            timed_out,
            document,
            receipt_file_sha256,
        ), network_document, network_exit_code = (
            audit_matrix_workload(
                candidate_identity_path=candidate_identity,
                app_bundle=installed_app,
                artifact_root=arguments.network_artifact_root,
                qualification_run=qualification_run,
                predecessor_observations_sha256=(
                    arguments.predecessor_observations_sha256
                ),
                workload=execute_exact_matrix,
            )
        )
    except (
        AuditInputError,
        OSError,
        UnicodeError,
        ValueError,
        InstalledMatrixReceiptError,
        PreferenceRecoveryError,
    ) as error:
        print(f"ERROR: installed Task 10 matrix failed: {error}", file=sys.stderr)
        for note in (RESTORATION_FAILURE_NOTE, WRITER_UNSETTLED_NOTE, JOURNAL_CLOSEOUT_FAILURE_NOTE):
            if note in getattr(error, "__notes__", ()):
                print(f"ERROR: {note}", file=sys.stderr)
        return 2
    print(
        json.dumps(
            {
                "exitCode": exit_code,
                "receiptPath": str(receipt_output),
                "receiptSHA256": receipt_file_sha256,
                "result": document["execution"]["result"],
                "networkAuditExecutionReportPath": str(
                    arguments.network_artifact_root / NETWORK_EXECUTION_REPORT_NAME
                ),
                "networkAuditObservationPath": str(
                    arguments.network_artifact_root / NETWORK_OBSERVATION_NAME
                ),
                "networkAuditReportPath": str(
                    arguments.network_artifact_root / NETWORK_REPORT_NAME
                ),
                "networkAuditResult": network_document["result"],
                "executionXCTestrunPath": str(execution_xctestrun),
                "executionXCTestrunSHA256": execution_xctestrun_sha256,
                "selectorCount": len(selectors),
                "timedOut": timed_out,
                "xcresultPath": str(xcresult),
                "xcresultSemanticManifestPath": str(xcresult_semantic_manifest),
            },
            sort_keys=True,
        )
    )
    return 0 if exit_code == 0 and network_exit_code == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
