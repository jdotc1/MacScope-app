#!/usr/bin/env python3
"""Run and seal the exact Next-Five adaptive-pane installed proof.

The producer is deliberately downstream of ``FinalLocalCandidate``. It derives
all build products and upstream receipts from that authority, creates only an
installed opt-in xctestrun overlay, and runs three behavior-first selectors
without rebuilding or changing the installed app.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import stat
import sys
import time
from typing import Any, Callable, NoReturn, Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from Scripts import ws24_emit_installed_qualification_report as ws24  # noqa: E402
from Scripts.reconstruction import (  # noqa: E402
    compile_installed_acceptance_gate_plan as gate_plan,
)
from Scripts.reconstruction import installed_matrix_receipt as matrix  # noqa: E402
from Scripts.reconstruction import run_installed_task10_matrix as task10  # noqa: E402
from Scripts.reconstruction import validate_final_local_candidate as final_local  # noqa: E402
from Scripts.reconstruction import write_execution_report as secure_output  # noqa: E402
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    canonical_bytes,
    canonical_sha256,
    decode_canonical_bytes,
)


SCHEMA_VERSION = 1
RECEIPT_KIND = "macscope-next5-adaptive-pane-installed-acceptance"
AUTHORITY_SCOPE = "next5-tranche1-adaptive-pane-installed-only"
INSTALLED_APP = Path("/Applications/MacScope.app")
MAXIMUM_AUTHORITY_BYTES = 4 * 1024 * 1024

SELECTORS = (
    "WorkspaceAdaptivePaneInstalledAppUITests/"
    "testAdaptivePanesRemainInsideWideAndMinimumWindows()",
    "WorkspaceAdaptivePaneInstalledAppUITests/"
    "testNativeDividersMoveClampAndPreserveKeyboardFocus()",
    "WorkspaceAdaptivePaneInstalledAppUITests/"
    "testPaneWidthsRestoreAndRemainIndependentAcrossWindows()",
)
PANE_IDENTIFIERS = (
    "workspace.root",
    "workspace.pane.sidebar",
    "workspace.pane.editor",
    "workspace.pane.inspector",
)
SELECTOR_PROJECTION = (
    {
        "required_identifiers": list(PANE_IDENTIFIERS),
        "test_identifier": SELECTORS[0],
        "vector_id": "next5.adaptive-pane.geometry-and-text",
    },
    {
        "required_identifiers": list(PANE_IDENTIFIERS),
        "test_identifier": SELECTORS[1],
        "vector_id": "next5.adaptive-pane.dividers-focus-and-clamps",
    },
    {
        "required_identifiers": list(PANE_IDENTIFIERS),
        "test_identifier": SELECTORS[2],
        "vector_id": "next5.adaptive-pane.restoration-and-multiwindow",
    },
)

RECEIPT_TOP_FIELDS = frozenset(
    {
        "authority",
        "execution",
        "produced_at_unix_ns",
        "products",
        "receipt_kind",
        "result",
        "schema_version",
        "scope",
    }
)
RECEIPT_AUTHORITY_FIELDS = frozenset(
    {
        "candidate_identity_file_sha256",
        "candidate_identity_path",
        "candidate_identity_sha256",
        "final_local_candidate_path",
        "final_local_candidate_sha256",
        "gate_plan_authority_sha256",
        "gate_plan_path",
        "gate_plan_sha256",
        "installed_app_path",
        "installed_ui_preparation_receipt_path",
        "installed_ui_preparation_receipt_sha256",
        "qualification_receipt_path",
        "qualification_receipt_sha256",
        "qualification_run_id",
        "qualification_run_nonce",
        "source_commit",
        "source_tree",
    }
)
RECEIPT_PRODUCT_FIELDS = frozenset(
    {
        "execution_xctestrun",
        "installed_app",
        "prepared_xctestrun",
        "test_bundle",
        "ui_runner",
        "xcodebuild",
        "xcresult",
    }
)
RECEIPT_EXECUTION_FIELDS = frozenset(
    {
        "argv",
        "authority_snapshot_after",
        "authority_snapshot_before",
        "duration_ms",
        "ended_at_unix_ms",
        "environment",
        "exit_code",
        "input_snapshot_after",
        "input_snapshot_before",
        "selector_projection",
        "selector_projection_sha256",
        "selector_semantics",
        "selector_semantics_sha256",
        "selectors",
        "started_at_unix_ms",
    }
)


class AdaptivePaneAcceptanceError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise AdaptivePaneAcceptanceError(message)


def _record(value: Any, *, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def _absolute(value: Any, *, label: str) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        fail(f"{label} must be a nonempty path")
    path = Path(value)
    if not path.is_absolute():
        fail(f"{label} must be absolute")
    return path


def _stable_file(
    path: Path, *, label: str, maximum_bytes: int = MAXIMUM_AUTHORITY_BYTES
) -> final_local.StableFile:
    try:
        return final_local._read_stable_file(
            path, maximum_bytes=maximum_bytes, label=label
        )
    except final_local.FinalLocalCandidateError as error:
        fail(str(error))


def _require_unchanged(snapshot: final_local.StableFile, *, label: str) -> None:
    try:
        final_local._require_unchanged(snapshot, label=label)
    except final_local.FinalLocalCandidateError as error:
        fail(str(error))


def _snapshot_record(snapshot: final_local.StableFile) -> dict[str, Any]:
    return {
        "path": str(snapshot.path),
        "sha256": snapshot.sha256,
        "device": snapshot.metadata[0],
        "inode": snapshot.metadata[1],
        "mode": snapshot.metadata[2],
        "link_count": snapshot.metadata[3],
        "size": snapshot.metadata[4],
        "mtime_ns": snapshot.metadata[5],
        "ctime_ns": snapshot.metadata[6],
    }


def _canonical_absent(path: Path, *, label: str) -> Path:
    if not path.is_absolute() or path.exists() or path.is_symlink():
        fail(f"{label} must be an absent absolute path")
    try:
        parent = matrix._ordinary(path.parent, directory=True)
    except matrix.InstalledMatrixReceiptError as error:
        fail(f"{label} parent is invalid: {error}")
    if parent != path.parent:
        fail(f"{label} parent must already be canonical")
    return parent / path.name


@dataclass(frozen=True)
class InstalledAuthority:
    final_receipt: final_local.StableFile
    plan: final_local.StableFile
    qualification_receipt: final_local.StableFile
    preparation_receipt: final_local.StableFile
    candidate_identity: Path
    prepared_xctestrun: Path
    test_bundle: Path
    ui_runner: Path
    installed_app: Path
    source_commit: str
    source_tree: str
    candidate_identity_sha256: str
    candidate_identity_file_sha256: str
    gate_plan_authority_sha256: str
    qualification_run_id: str
    qualification_run_nonce: str


def load_installed_authority(final_receipt_path: Path) -> InstalledAuthority:
    """Derive execution inputs from a passing FinalLocalCandidate and its plan."""

    if final_receipt_path.name != "FinalLocalCandidate.receipt.json":
        fail("final receipt must use the governed FinalLocalCandidate.receipt.json name")
    final_receipt = _stable_file(final_receipt_path, label="final local candidate receipt")
    if stat.S_IMODE(final_receipt.metadata[2]) != 0o600:
        fail("final local candidate receipt must be mode 0600")
    try:
        final_document = _record(
            decode_canonical_bytes(final_receipt.payload),
            label="final local candidate receipt",
        )
    except (UnicodeError, ValueError) as error:
        fail(f"final local candidate receipt is not canonical JSON: {error}")
    if (
        final_document.get("schema_version") != final_local.SCHEMA_VERSION
        or final_document.get("receipt_kind") != final_local.RECEIPT_KIND
        or final_document.get("result") != "passed"
        or final_document.get("scope")
        != {
            "authority": final_local.AUTHORITY_SCOPE,
            "gate_f_claimed": False,
            "online_delivery_claimed": False,
            "post_2026_09_11_proof_claimed": False,
            "public_release_claimed": False,
        }
    ):
        fail("final local candidate is not a passing local-private authority")

    candidate = _record(final_document.get("candidate"), label="final candidate")
    installation = _record(
        final_document.get("installation"), label="final installation"
    )
    integration = _record(
        final_document.get("integration"), label="final integration"
    )
    qualification = _record(
        final_document.get("qualification"), label="final qualification"
    )
    transaction = _record(
        final_document.get("transaction_result"), label="final transaction result"
    )
    if (
        installation.get("installed_app_path") != str(INSTALLED_APP)
        or installation.get("rolled_back") is not False
        or installation.get("transaction_phase") != "committed"
    ):
        fail("final local candidate does not own the committed /Applications installation")
    if (
        qualification.get("mode") != "full-test"
        or qualification.get("dependency_network_allowed") is not False
        or qualification.get("dependency_network_used") is not False
    ):
        fail("final local candidate does not bind one offline full-test qualification")
    if not isinstance(transaction.get("installed_task10"), dict):
        fail("final local candidate lacks its installed Task 10 authority")

    plan_path = _absolute(transaction.get("gate_plan_path"), label="gate plan path")
    plan_snapshot = _stable_file(
        plan_path,
        label="installed acceptance gate plan",
        maximum_bytes=gate_plan.MAXIMUM_PLAN_BYTES,
    )
    try:
        plan_document, plan_sha256 = gate_plan.load_plan(plan_path)
    except (OSError, ValueError, gate_plan.PlanCompilationError) as error:
        fail(f"installed acceptance gate plan is invalid: {error}")
    _require_unchanged(plan_snapshot, label="installed acceptance gate plan")
    if (
        plan_sha256 != plan_snapshot.sha256
        or transaction.get("gate_plan_sha256") != plan_sha256
        or transaction.get("gate_plan_authority_sha256")
        != plan_document.get("authority_sha256")
    ):
        fail("final receipt and compiler-validated gate plan differ")

    authority = _record(plan_document.get("authority"), label="gate plan authority")
    final_candidate_root = _absolute(
        transaction.get("candidate_artifact_root"),
        label="final candidate artifact root",
    )
    final_candidate_identity = _absolute(
        candidate.get("identity_path"), label="final candidate identity path"
    )
    final_source_app = _absolute(
        candidate.get("source_app_path"), label="final source app path"
    )
    final_qualification_receipt = _absolute(
        qualification.get("receipt_path"), label="final qualification receipt path"
    )
    cross_bindings = (
        (
            Path(plan_document["candidate_artifact_root"]),
            final_candidate_root,
        ),
        (Path(authority["installed_app_path"]), INSTALLED_APP),
        (Path(installation["installed_app_path"]), INSTALLED_APP),
        (
            Path(authority["candidate_identity_path"]),
            final_candidate_identity,
        ),
        (authority.get("candidate_file_sha256"), candidate.get("identity_file_sha256")),
        (authority.get("candidate_identity_sha256"), candidate.get("identity_sha256")),
        (
            authority.get("application_executable_sha256"),
            candidate.get("application_executable_sha256"),
        ),
        (Path(authority["source_app_path"]), final_source_app),
        (authority.get("source_commit"), integration.get("commit")),
        (authority.get("source_tree"), integration.get("tree")),
        (
            Path(authority["qualification_receipt_path"]),
            final_qualification_receipt,
        ),
        (
            authority.get("qualification_receipt_sha256"),
            qualification.get("receipt_sha256"),
        ),
        (authority.get("qualification_run_id"), qualification.get("run_id")),
        (authority.get("qualification_run_nonce"), qualification.get("run_nonce")),
    )
    if any(observed != expected for observed, expected in cross_bindings):
        fail("final receipt differs from its candidate or qualification gate-plan authority")

    qualification_receipt = _stable_file(
        _absolute(
            authority.get("qualification_receipt_path"),
            label="qualification receipt path",
        ),
        label="full-test qualification receipt",
    )
    preparation_receipt = _stable_file(
        _absolute(
            authority.get("installed_ui_preparation_receipt_path"),
            label="installed UI preparation receipt path",
        ),
        label="installed UI preparation receipt",
    )
    if (
        qualification_receipt.sha256 != authority.get("qualification_receipt_sha256")
        or preparation_receipt.sha256
        != authority.get("installed_ui_preparation_receipt_sha256")
    ):
        fail("qualification or installed UI preparation bytes differ from the gate plan")

    result = InstalledAuthority(
        final_receipt=final_receipt,
        plan=plan_snapshot,
        qualification_receipt=qualification_receipt,
        preparation_receipt=preparation_receipt,
        candidate_identity=_absolute(
            authority.get("candidate_identity_path"), label="candidate identity path"
        ),
        prepared_xctestrun=_absolute(
            authority.get("installed_ui_xctestrun_path"),
            label="prepared xctestrun path",
        ),
        test_bundle=_absolute(
            authority.get("installed_ui_test_bundle_path"), label="test bundle path"
        ),
        ui_runner=_absolute(
            authority.get("installed_ui_runner_path"), label="UI runner path"
        ),
        installed_app=INSTALLED_APP,
        source_commit=str(authority.get("source_commit")),
        source_tree=str(authority.get("source_tree")),
        candidate_identity_sha256=str(authority.get("candidate_identity_sha256")),
        candidate_identity_file_sha256=str(authority.get("candidate_file_sha256")),
        gate_plan_authority_sha256=str(plan_document.get("authority_sha256")),
        qualification_run_id=str(authority.get("qualification_run_id")),
        qualification_run_nonce=str(authority.get("qualification_run_nonce")),
    )
    require_authority_unchanged(result)
    return result


def authority_snapshot(authority: InstalledAuthority) -> dict[str, Any]:
    return {
        "final_local_candidate": _snapshot_record(authority.final_receipt),
        "gate_plan": _snapshot_record(authority.plan),
        "installed_ui_preparation_receipt": _snapshot_record(
            authority.preparation_receipt
        ),
        "qualification_receipt": _snapshot_record(authority.qualification_receipt),
    }


def require_authority_unchanged(authority: InstalledAuthority) -> None:
    for snapshot, label in (
        (authority.final_receipt, "final local candidate receipt"),
        (authority.plan, "installed acceptance gate plan"),
        (authority.qualification_receipt, "full-test qualification receipt"),
        (authority.preparation_receipt, "installed UI preparation receipt"),
    ):
        _require_unchanged(snapshot, label=label)


def validate_selector_documents(summary: object, tests: object) -> dict[str, object]:
    """Use existing xcresult extractors for the sibling adaptive-pane class."""

    if not isinstance(summary, dict) or not isinstance(tests, dict):
        fail("xcresult summary and tests must be objects")
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
            fail(f"xcresult has invalid {field}")
        counts[field] = value
    if (
        summary.get("title") != "Test - MacScopeInstalledAppUITests"
        or summary.get("result") != "Passed"
        or counts
        != {
            "totalTestCount": 3,
            "passedTests": 3,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
        }
    ):
        fail("xcresult did not execute and exclusively pass the exact pane selector count")
    try:
        cases = ws24.xcresult_test_cases(tests, 0)
    except ws24.ReportError as error:
        fail(f"xcresult test nodes are invalid: {error}")
    observed = [case["identifier"] for case in cases]
    if (
        Counter(observed) != Counter(SELECTORS)
        or len(observed) != len(SELECTORS)
        or any(not case["inExpectedBundle"] for case in cases)
    ):
        fail("xcresult selectors differ from the exact adaptive-pane selector catalog")
    try:
        for case in cases:
            ws24.exclusively_passed_case(case["node"], 0)
    except ws24.ReportError as error:
        fail(f"xcresult contains a non-passed pane selector: {error}")
    by_identifier = {case["identifier"]: case for case in cases}
    return {
        "expected_selector_count": 3,
        "executed_selector_count": 3,
        "passed_selector_count": 3,
        "failed_selector_count": 0,
        "skipped_selector_count": 0,
        "expected_failure_count": 0,
        "selectors": [
            {
                "test_identifier": selector,
                "status": str(by_identifier[selector]["node"]["result"]).lower(),
            }
            for selector in SELECTORS
        ],
    }


def _validate_exact_xcresult(path: Path) -> dict[str, object]:
    try:
        return validate_selector_documents(
            ws24.xcresult_test_summary(path, 0),
            ws24.xcresult_test_nodes(path, 0),
        )
    except ws24.ReportError as error:
        fail(f"cannot inspect exact adaptive-pane xcresult: {error}")


def _receipt_document(
    *,
    authority: InstalledAuthority,
    command: list[str],
    environment: dict[str, str],
    input_snapshot: dict[str, Any],
    authority_input_snapshot: dict[str, Any],
    selector_semantics: dict[str, object],
    xcresult_tree: final_local.StableTree,
    started_at: int,
    ended_at: int,
    produced_at: int,
) -> dict[str, Any]:
    return {
        "authority": {
            "candidate_identity_file_sha256": authority.candidate_identity_file_sha256,
            "candidate_identity_path": str(authority.candidate_identity),
            "candidate_identity_sha256": authority.candidate_identity_sha256,
            "final_local_candidate_path": str(authority.final_receipt.path),
            "final_local_candidate_sha256": authority.final_receipt.sha256,
            "gate_plan_authority_sha256": authority.gate_plan_authority_sha256,
            "gate_plan_path": str(authority.plan.path),
            "gate_plan_sha256": authority.plan.sha256,
            "installed_app_path": str(authority.installed_app),
            "installed_ui_preparation_receipt_path": str(
                authority.preparation_receipt.path
            ),
            "installed_ui_preparation_receipt_sha256": (
                authority.preparation_receipt.sha256
            ),
            "qualification_receipt_path": str(authority.qualification_receipt.path),
            "qualification_receipt_sha256": authority.qualification_receipt.sha256,
            "qualification_run_id": authority.qualification_run_id,
            "qualification_run_nonce": authority.qualification_run_nonce,
            "source_commit": authority.source_commit,
            "source_tree": authority.source_tree,
        },
        "execution": {
            "argv": command,
            "authority_snapshot_after": authority_input_snapshot,
            "authority_snapshot_before": authority_input_snapshot,
            "duration_ms": ended_at - started_at,
            "ended_at_unix_ms": ended_at,
            "environment": environment,
            "exit_code": 0,
            "input_snapshot_after": input_snapshot,
            "input_snapshot_before": input_snapshot,
            "selector_projection": [dict(item) for item in SELECTOR_PROJECTION],
            "selector_projection_sha256": canonical_sha256(SELECTOR_PROJECTION),
            "selector_semantics": selector_semantics,
            "selector_semantics_sha256": canonical_sha256(selector_semantics),
            "selectors": list(SELECTORS),
            "started_at_unix_ms": started_at,
        },
        "produced_at_unix_ns": produced_at,
        "products": {
            "execution_xctestrun": input_snapshot["execution_xctestrun"],
            "installed_app": input_snapshot["installed_app"],
            "prepared_xctestrun": input_snapshot["prepared_xctestrun"],
            "test_bundle": input_snapshot["test_bundle"],
            "ui_runner": input_snapshot["ui_runner"],
            "xcodebuild": input_snapshot["xcodebuild"],
            "xcresult": {
                "bundle_sha256": xcresult_tree.bundle_sha256,
                "closed_tree_sha256": xcresult_tree.closed_tree_sha256,
                "path": str(xcresult_tree.path),
            },
        },
        "receipt_kind": RECEIPT_KIND,
        "result": "passed",
        "schema_version": SCHEMA_VERSION,
        "scope": {"authority": AUTHORITY_SCOPE, "gate_f_claimed": False},
    }


def _validate_generated_receipt(document: dict[str, Any]) -> None:
    if (
        set(document) != RECEIPT_TOP_FIELDS
        or set(document["authority"]) != RECEIPT_AUTHORITY_FIELDS
        or set(document["products"]) != RECEIPT_PRODUCT_FIELDS
        or set(document["execution"]) != RECEIPT_EXECUTION_FIELDS
        or document["receipt_kind"] != RECEIPT_KIND
        or document["result"] != "passed"
        or document["scope"]
        != {"authority": AUTHORITY_SCOPE, "gate_f_claimed": False}
    ):
        fail("generated adaptive-pane receipt is not closed")
    execution = document["execution"]
    products = document["products"]
    semantics = execution["selector_semantics"]
    expected_semantics = {
        "expected_selector_count": 3,
        "executed_selector_count": 3,
        "passed_selector_count": 3,
        "failed_selector_count": 0,
        "skipped_selector_count": 0,
        "expected_failure_count": 0,
        "selectors": [
            {"test_identifier": selector, "status": "passed"}
            for selector in SELECTORS
        ],
    }
    if (
        document["authority"]["installed_app_path"] != str(INSTALLED_APP)
        or execution["selectors"] != list(SELECTORS)
        or execution["selector_projection"] != [dict(item) for item in SELECTOR_PROJECTION]
        or execution["selector_projection_sha256"]
        != canonical_sha256(SELECTOR_PROJECTION)
        or semantics != expected_semantics
        or execution["selector_semantics_sha256"] != canonical_sha256(semantics)
        or execution["exit_code"] != 0
        or execution["input_snapshot_before"] != execution["input_snapshot_after"]
        or execution["authority_snapshot_before"]
        != execution["authority_snapshot_after"]
    ):
        fail("generated adaptive-pane receipt does not bind one stable exact execution")
    for product in (
        "execution_xctestrun",
        "installed_app",
        "prepared_xctestrun",
        "test_bundle",
        "ui_runner",
        "xcodebuild",
    ):
        if products[product] != execution["input_snapshot_before"][product]:
            fail(f"generated adaptive-pane product {product} differs from its snapshot")
    xcresult = _record(products["xcresult"], label="xcresult identity")
    if set(xcresult) != {"path", "bundle_sha256", "closed_tree_sha256"}:
        fail("generated adaptive-pane xcresult identity is not closed")
    expected_command = matrix.expected_argv(
        Path(products["xcodebuild"]["path"]),
        Path(products["execution_xctestrun"]["path"]),
        Path(xcresult["path"]),
        list(SELECTORS),
    )
    environment = execution["environment"]
    if (
        execution["argv"] != expected_command
        or set(environment) != matrix.ENVIRONMENT_FIELDS
        or environment[matrix.OPT_IN_KEY] != "1"
        or environment[matrix.INSTALLED_APP_KEY] != str(INSTALLED_APP)
        or environment["PATH"] != "/usr/bin:/bin:/usr/sbin:/sbin"
    ):
        fail("generated adaptive-pane command or environment differs")


def _parent_still_bound(descriptor: int, parent: Path) -> bool:
    retained = os.fstat(descriptor)
    try:
        named = os.stat(parent, follow_symlinks=False)
    except OSError:
        return False
    return (
        stat.S_ISDIR(named.st_mode)
        and not stat.S_ISLNK(named.st_mode)
        and (named.st_dev, named.st_ino) == (retained.st_dev, retained.st_ino)
    )


def _publish_receipt_create_only(
    path: Path,
    document: dict[str, Any],
    *,
    closure_check: Callable[[], None],
) -> str:
    """Publish through one retained no-follow parent descriptor.

    All create/link/unlink/fsync operations are descriptor-relative. If the
    named parent is renamed or replaced, cleanup still removes the exact inode
    from the directory in which it was created rather than following the new
    path.
    """

    payload = canonical_bytes(document)
    if not payload or len(payload) > MAXIMUM_AUTHORITY_BYTES:
        fail("adaptive-pane receipt exceeds its bounded size")
    try:
        parent_descriptor, parent = secure_output._open_parent(path, label="receipt")
    except secure_output.ExecutionReportError as error:
        fail(str(error))
    temporary_name = f".{path.name}.tmp.{os.getpid()}.{os.urandom(16).hex()}"
    temporary_descriptor = -1
    created_identity: tuple[int, int] | None = None
    linked = False
    succeeded = False
    try:
        try:
            os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            fail("adaptive-pane receipt output must remain absent")
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
                fail("adaptive-pane receipt write made no progress")
            offset += written
        os.fsync(temporary_descriptor)
        temporary = os.fstat(temporary_descriptor)
        created_identity = (temporary.st_dev, temporary.st_ino)
        if (
            not stat.S_ISREG(temporary.st_mode)
            or temporary.st_nlink != 1
            or temporary.st_size != len(payload)
        ):
            fail("adaptive-pane receipt temporary identity is invalid")
        os.link(
            temporary_name,
            path.name,
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        linked = True
        destination = os.stat(
            path.name, dir_fd=parent_descriptor, follow_symlinks=False
        )
        if (
            not stat.S_ISREG(destination.st_mode)
            or (destination.st_dev, destination.st_ino) != created_identity
            or destination.st_nlink != 2
        ):
            fail("adaptive-pane receipt publication identity is invalid")
        if not _parent_still_bound(parent_descriptor, parent):
            fail("adaptive-pane receipt parent changed during publication")
        os.unlink(temporary_name, dir_fd=parent_descriptor)
        temporary_name = ""
        os.fsync(parent_descriptor)
        final_metadata = os.stat(
            path.name, dir_fd=parent_descriptor, follow_symlinks=False
        )
        if (
            (final_metadata.st_dev, final_metadata.st_ino) != created_identity
            or final_metadata.st_nlink != 1
            or final_metadata.st_size != len(payload)
            or stat.S_IMODE(final_metadata.st_mode) != 0o600
        ):
            fail("adaptive-pane receipt final identity is invalid")
        descriptor = os.open(
            path.name,
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            dir_fd=parent_descriptor,
        )
        try:
            observed = bytearray()
            while len(observed) <= len(payload):
                block = os.read(descriptor, len(payload) + 1 - len(observed))
                if not block:
                    break
                observed.extend(block)
            if bytes(observed) != payload:
                fail("published adaptive-pane receipt bytes are not canonical")
        finally:
            os.close(descriptor)
        closure_check()
        if not _parent_still_bound(parent_descriptor, parent):
            fail("adaptive-pane receipt parent changed before closure")
        succeeded = True
        return hashlib.sha256(payload).hexdigest()
    except FileExistsError:
        fail("adaptive-pane receipt output must remain absent")
    except OSError as error:
        fail(f"adaptive-pane receipt publication failed: {error}")
    finally:
        if temporary_descriptor >= 0:
            os.close(temporary_descriptor)
        if temporary_name and created_identity is not None:
            try:
                metadata = os.stat(
                    temporary_name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
                if (metadata.st_dev, metadata.st_ino) == created_identity:
                    os.unlink(temporary_name, dir_fd=parent_descriptor)
            except FileNotFoundError:
                pass
        if linked and not succeeded and created_identity is not None:
            try:
                metadata = os.stat(
                    path.name, dir_fd=parent_descriptor, follow_symlinks=False
                )
                if (metadata.st_dev, metadata.st_ino) == created_identity:
                    os.unlink(path.name, dir_fd=parent_descriptor)
            except FileNotFoundError:
                pass
        if not succeeded:
            try:
                os.fsync(parent_descriptor)
            except OSError:
                pass
        os.close(parent_descriptor)


def run_acceptance(
    arguments: argparse.Namespace,
    *,
    run_process: Callable[[list[str], dict[str, str], int], tuple[int, bool]] = (
        task10._run_xcodebuild_process_group
    ),
    clock_ms: Callable[[], int] = lambda: int(time.time() * 1000),
    clock_ns: Callable[[], int] = time.time_ns,
) -> Path:
    authority = load_installed_authority(arguments.final_candidate)
    xcresult = _canonical_absent(arguments.xcresult, label="xcresult")
    receipt_output = _canonical_absent(
        arguments.receipt_output, label="adaptive-pane receipt output"
    )
    try:
        developer_dir = matrix._ordinary(arguments.developer_dir, directory=True)
        xcodebuild = matrix._ordinary(
            developer_dir / "usr/bin/xcodebuild", directory=False
        )
    except matrix.InstalledMatrixReceiptError as error:
        fail(f"developer toolchain is invalid: {error}")
    if not os.access(xcodebuild, os.X_OK):
        fail("developer toolchain xcodebuild is not executable")

    execution_identity = canonical_sha256(
        {
            "final_local_candidate_sha256": authority.final_receipt.sha256,
            "receipt_output": str(receipt_output),
            "xcresult": str(xcresult),
        }
    )
    execution_xctestrun = _canonical_absent(
        authority.prepared_xctestrun.with_name(
            f"{authority.prepared_xctestrun.stem}-AdaptivePaneOptIn-"
            f"{execution_identity}{authority.prepared_xctestrun.suffix}"
        ),
        label="execution xctestrun",
    )
    try:
        matrix.write_execution_xctestrun_create_only(
            authority.prepared_xctestrun, execution_xctestrun, authority.installed_app
        )
        command = matrix.expected_argv(
            xcodebuild, execution_xctestrun, xcresult, list(SELECTORS)
        )
        environment = matrix.expected_environment(
            developer_dir, authority.installed_app, dict(os.environ)
        )
        before = matrix.preflight_execution(
            candidate_identity_path=authority.candidate_identity,
            preparation_receipt_path=authority.preparation_receipt.path,
            installed_app=authority.installed_app,
            prepared_xctestrun=authority.prepared_xctestrun,
            execution_xctestrun=execution_xctestrun,
            test_bundle=authority.test_bundle,
            ui_runner=authority.ui_runner,
            xcodebuild=xcodebuild,
            expected_xcresult=xcresult,
            argv=command,
            selectors=list(SELECTORS),
            selector_projection=[dict(item) for item in SELECTOR_PROJECTION],
            environment=environment,
        )
    except matrix.InstalledMatrixReceiptError as error:
        fail(f"adaptive-pane preflight refused execution: {error}")
    upstream_before = authority_snapshot(authority)
    require_authority_unchanged(authority)

    started_at = clock_ms()
    exit_code, timed_out = run_process(command, environment, arguments.timeout_seconds)
    ended_at = clock_ms()
    try:
        after = matrix.capture_input_snapshot(
            candidate_identity_path=authority.candidate_identity,
            preparation_receipt_path=authority.preparation_receipt.path,
            installed_app=authority.installed_app,
            prepared_xctestrun=authority.prepared_xctestrun,
            execution_xctestrun=execution_xctestrun,
            test_bundle=authority.test_bundle,
            ui_runner=authority.ui_runner,
            xcodebuild=xcodebuild,
        )
        matrix.assert_input_snapshot_equal(before, after)
    except matrix.InstalledMatrixReceiptError as error:
        fail(f"adaptive-pane execution inputs changed: {error}")
    require_authority_unchanged(authority)
    if upstream_before != authority_snapshot(authority):
        fail("adaptive-pane upstream authority changed during execution")
    if timed_out:
        fail("adaptive-pane xcodebuild timed out after bounded process-group cleanup")
    if exit_code != 0:
        fail(f"adaptive-pane xcodebuild failed with exit code {exit_code}")
    if not xcresult.is_dir() or xcresult.is_symlink():
        fail("adaptive-pane xcodebuild did not produce the required xcresult bundle")

    semantics = _validate_exact_xcresult(xcresult)
    try:
        result_tree = final_local._capture_xcresult_tree(
            xcresult, label="adaptive-pane xcresult"
        )
    except final_local.FinalLocalCandidateError as error:
        fail(str(error))
    produced_at = clock_ns()
    if produced_at <= authority.final_receipt.mtime_ns:
        fail("adaptive-pane receipt timestamp does not follow FinalLocalCandidate")
    document = _receipt_document(
        authority=authority,
        command=command,
        environment=environment,
        input_snapshot=before,
        authority_input_snapshot=upstream_before,
        selector_semantics=semantics,
        xcresult_tree=result_tree,
        started_at=started_at,
        ended_at=ended_at,
        produced_at=produced_at,
    )
    _validate_generated_receipt(document)

    def closure_check() -> None:
        require_authority_unchanged(authority)
        try:
            matrix.assert_input_snapshot_equal(
                before,
                matrix.capture_input_snapshot(
                    candidate_identity_path=authority.candidate_identity,
                    preparation_receipt_path=authority.preparation_receipt.path,
                    installed_app=authority.installed_app,
                    prepared_xctestrun=authority.prepared_xctestrun,
                    execution_xctestrun=execution_xctestrun,
                    test_bundle=authority.test_bundle,
                    ui_runner=authority.ui_runner,
                    xcodebuild=xcodebuild,
                ),
            )
            final_local._require_tree_unchanged(
                result_tree, label="adaptive-pane xcresult"
            )
        except (
            matrix.InstalledMatrixReceiptError,
            final_local.FinalLocalCandidateError,
        ) as error:
            fail(f"adaptive-pane closure changed before publication completed: {error}")

    _publish_receipt_create_only(
        receipt_output,
        document,
        closure_check=closure_check,
    )
    return receipt_output


def parse_arguments(arguments: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run and seal the exact installed adaptive-pane selectors.",
        allow_abbrev=False,
    )
    parser.add_argument("--final-candidate", required=True, type=Path)
    parser.add_argument("--xcresult", required=True, type=Path)
    parser.add_argument("--receipt-output", required=True, type=Path)
    parser.add_argument("--developer-dir", required=True, type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parsed = parser.parse_args(arguments)
    if parsed.timeout_seconds < 1 or parsed.timeout_seconds > 1800:
        parser.error("--timeout-seconds must be between 1 and 1800")
    return parsed


def main(arguments: Sequence[str] | None = None) -> int:
    try:
        output = run_acceptance(parse_arguments(arguments))
    except (AdaptivePaneAcceptanceError, OSError, ValueError) as error:
        print(f"ERROR: adaptive-pane acceptance refused: {error}", file=sys.stderr)
        return 1
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
