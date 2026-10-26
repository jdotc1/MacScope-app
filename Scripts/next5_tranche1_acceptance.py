#!/usr/bin/env python3
"""Publish the minimal aggregate authority for completed Next-Five Tranche 1."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import stat
import sys
import time
from typing import Any, Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from Scripts import next5_adaptive_pane_acceptance as pane  # noqa: E402
from Scripts import next5_runloop_acceptance as runloop  # noqa: E402
from Scripts.reconstruction import installed_matrix_receipt as matrix  # noqa: E402
from Scripts.reconstruction import validate_final_local_candidate as final_local  # noqa: E402
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    canonical_bytes,
    file_sha256,
    load_canonical_json,
)
from Scripts.reconstruction_gate_f import next5_gatef_readiness as gatef  # noqa: E402


SCHEMA_VERSION = 1
RECEIPT_KIND = "macscope-next5-tranche1-acceptance"
MAXIMUM_RECEIPT_BYTES = 4 * 1024 * 1024
INSTALLED_APP = "/Applications/MacScope.app"


class Tranche1AcceptanceError(RuntimeError):
    pass


@dataclass(frozen=True)
class InputReceipt:
    path: Path
    sha256: str
    document: dict[str, Any]
    identity: tuple[int, int, int, int, int, int]


def _load(path: Path, *, label: str) -> InputReceipt:
    if not path.is_absolute():
        raise Tranche1AcceptanceError(f"{label} must use an absolute path")
    try:
        resolved = path.resolve(strict=True)
        before = path.lstat()
        document = load_canonical_json(path)
        after = path.lstat()
    except (OSError, ValueError) as error:
        raise Tranche1AcceptanceError(f"{label} is unavailable or invalid: {error}") from error
    identity = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
        stat.S_IMODE(before.st_mode),
    )
    after_identity = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
        stat.S_IMODE(after.st_mode),
    )
    if (
        resolved != path
        or not stat.S_ISREG(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_nlink != 1
        or before.st_size <= 0
        or before.st_size > MAXIMUM_RECEIPT_BYTES
        or identity != after_identity
        or identity[-1] != 0o600
        or not isinstance(document, dict)
    ):
        raise Tranche1AcceptanceError(f"{label} is not one stable private canonical receipt")
    return InputReceipt(path, file_sha256(path), document, identity)


def _record(value: object, *, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise Tranche1AcceptanceError(f"{label} must be an object")
    return value


def _same(receipt: InputReceipt) -> None:
    observed = _load(receipt.path, label="aggregate input revalidation")
    if observed.identity != receipt.identity or observed.sha256 != receipt.sha256:
        raise Tranche1AcceptanceError(f"aggregate input changed: {receipt.path}")


def build_document(
    *,
    final_receipt: InputReceipt,
    runloop_receipt: InputReceipt,
    pane_receipt: InputReceipt,
    negative_receipt: InputReceipt,
    readiness_receipt: InputReceipt,
    produced_at_unix_ns: int,
) -> dict[str, object]:
    final = final_receipt.document
    if (
        final.get("schema_version") != final_local.SCHEMA_VERSION
        or final.get("receipt_kind") != final_local.RECEIPT_KIND
        or final.get("result") != "passed"
    ):
        raise Tranche1AcceptanceError("FinalLocalCandidate is not passed schema-v1 authority")
    integration = _record(final.get("integration"), label="final integration")
    candidate = _record(final.get("candidate"), label="final candidate")
    qualification = _record(final.get("qualification"), label="final qualification")
    installation = _record(final.get("installation"), label="final installation")
    transaction = _record(final.get("transaction_result"), label="final transaction")
    scope = _record(final.get("scope"), label="final scope")
    if (
        qualification.get("mode") != "full-test"
        or qualification.get("dependency_network_used") is not False
        or installation.get("installed_app_path") != INSTALLED_APP
        or installation.get("transaction_phase") != "committed"
        or installation.get("rolled_back") is not False
        or scope.get("gate_f_claimed") is not False
        or scope.get("online_delivery_claimed") is not False
        or scope.get("post_2026_09_11_proof_claimed") is not False
        or scope.get("public_release_claimed") is not False
    ):
        raise Tranche1AcceptanceError("FinalLocalCandidate scope or installation is not admissible")

    runloop._validate_generated_receipt(runloop_receipt.document)
    pane._validate_generated_receipt(pane_receipt.document)
    run_authority = _record(runloop_receipt.document["authority"], label="runloop authority")
    run_candidate = _record(run_authority["candidate"], label="runloop candidate")
    run_final = _record(run_authority["final"], label="runloop final")
    run_qualification = _record(run_authority["qualification"], label="runloop qualification")
    run_application = _record(run_authority["application"], label="runloop application")
    pane_authority = _record(pane_receipt.document["authority"], label="pane authority")
    pane_products = _record(pane_receipt.document["products"], label="pane products")
    installed_product = _record(pane_products["installed_app"], label="pane installed app")
    bindings = (
        run_final.get("receipt_path") == str(final_receipt.path),
        run_final.get("receipt_sha256") == final_receipt.sha256,
        pane_authority.get("final_local_candidate_path") == str(final_receipt.path),
        pane_authority.get("final_local_candidate_sha256") == final_receipt.sha256,
        run_candidate.get("identity_path") == candidate.get("identity_path"),
        run_candidate.get("identity_file_sha256") == candidate.get("identity_file_sha256"),
        run_candidate.get("identity_semantic_sha256") == candidate.get("identity_sha256"),
        pane_authority.get("candidate_identity_path") == candidate.get("identity_path"),
        pane_authority.get("candidate_identity_file_sha256") == candidate.get("identity_file_sha256"),
        pane_authority.get("candidate_identity_sha256") == candidate.get("identity_sha256"),
        run_candidate.get("source_commit") == integration.get("commit"),
        run_candidate.get("source_tree") == integration.get("tree"),
        pane_authority.get("source_commit") == integration.get("commit"),
        pane_authority.get("source_tree") == integration.get("tree"),
        run_qualification.get("receipt_path") == qualification.get("receipt_path"),
        run_qualification.get("receipt_sha256") == qualification.get("receipt_sha256"),
        run_qualification.get("integration_ref") == integration.get("ref"),
        pane_authority.get("qualification_receipt_path") == qualification.get("receipt_path"),
        pane_authority.get("qualification_receipt_sha256") == qualification.get("receipt_sha256"),
        pane_authority.get("qualification_run_id") == qualification.get("run_id"),
        pane_authority.get("qualification_run_nonce") == qualification.get("run_nonce"),
        run_candidate.get("application_executable_sha256") == candidate.get("application_executable_sha256"),
        run_application.get("executable_sha256") == candidate.get("application_executable_sha256"),
        installed_product.get("executable_sha256") == candidate.get("application_executable_sha256"),
        pane_authority.get("installed_app_path") == INSTALLED_APP,
        installed_product.get("path") == INSTALLED_APP,
        pane_authority.get("gate_plan_path") == transaction.get("gate_plan_path"),
        pane_authority.get("gate_plan_sha256") == transaction.get("gate_plan_sha256"),
        pane_authority.get("gate_plan_authority_sha256") == transaction.get("gate_plan_authority_sha256"),
    )
    if not all(bindings):
        raise Tranche1AcceptanceError("pane/runloop authority differs from FinalLocalCandidate")

    gatef._validate_publication_expectation(
        negative_receipt.document, "blocked-negative-control"
    )
    gatef._validate_publication_expectation(
        readiness_receipt.document, "complete-readiness"
    )
    readiness_subject = _record(
        readiness_receipt.document.get("residual_evidence_subject"),
        label="Gate F readiness subject",
    )
    if (
        readiness_subject.get("candidate_file_sha256") != candidate.get("identity_file_sha256")
        or readiness_subject.get("candidate_identity_sha256") != candidate.get("identity_sha256")
        or readiness_subject.get("source_commit") != integration.get("commit")
        or readiness_subject.get("source_tree") != integration.get("tree")
    ):
        raise Tranche1AcceptanceError("complete Gate F readiness targets another candidate")

    latest = max(
        int(final.get("produced_at_unix_ns", 0)),
        int(runloop_receipt.document.get("produced_at_unix_ns", 0)),
        int(pane_receipt.document.get("produced_at_unix_ns", 0)),
    )
    if produced_at_unix_ns < latest:
        raise Tranche1AcceptanceError("aggregate timestamp predates its receipt chain")
    return {
        "acceptance": {
            "gate_f_complete": False,
            "online_delivery_claimed": False,
            "reconstruction_authorized": False,
            "step_8_authorized": False,
            "tranche_1_complete": True,
        },
        "candidate": {
            "application_executable_sha256": candidate["application_executable_sha256"],
            "identity_file_sha256": candidate["identity_file_sha256"],
            "identity_path": candidate["identity_path"],
            "identity_sha256": candidate["identity_sha256"],
            "installed_app_path": INSTALLED_APP,
            "integration_commit": integration["commit"],
            "integration_ref": integration["ref"],
            "integration_tree": integration["tree"],
            "qualification_receipt_path": qualification["receipt_path"],
            "qualification_receipt_sha256": qualification["receipt_sha256"],
        },
        "evidence": {
            "adaptive_pane": {"path": str(pane_receipt.path), "sha256": pane_receipt.sha256},
            "final_local_candidate": {"path": str(final_receipt.path), "sha256": final_receipt.sha256},
            "gate_f_complete_readiness": {"path": str(readiness_receipt.path), "sha256": readiness_receipt.sha256},
            "gate_f_negative_control": {"path": str(negative_receipt.path), "sha256": negative_receipt.sha256},
            "runloop": {"path": str(runloop_receipt.path), "sha256": runloop_receipt.sha256},
        },
        "produced_at_unix_ns": produced_at_unix_ns,
        "receipt_kind": RECEIPT_KIND,
        "result": "passed",
        "schema_version": SCHEMA_VERSION,
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--final-local-candidate", required=True, type=Path)
    parser.add_argument("--runloop-receipt", required=True, type=Path)
    parser.add_argument("--adaptive-pane-receipt", required=True, type=Path)
    parser.add_argument("--gatef-negative-control", required=True, type=Path)
    parser.add_argument("--gatef-complete-readiness", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args(argv)
    try:
        inputs = (
            _load(arguments.final_local_candidate, label="FinalLocalCandidate"),
            _load(arguments.runloop_receipt, label="runloop receipt"),
            _load(arguments.adaptive_pane_receipt, label="adaptive-pane receipt"),
            _load(arguments.gatef_negative_control, label="Gate F negative control"),
            _load(arguments.gatef_complete_readiness, label="Gate F complete readiness"),
        )
        if len({item.identity[:2] for item in inputs}) != len(inputs):
            raise Tranche1AcceptanceError("aggregate inputs must be physically distinct")
        document = build_document(
            final_receipt=inputs[0],
            runloop_receipt=inputs[1],
            pane_receipt=inputs[2],
            negative_receipt=inputs[3],
            readiness_receipt=inputs[4],
            produced_at_unix_ns=time.time_ns(),
        )
        for item in inputs:
            _same(item)
        matrix.write_create_only(arguments.output, document)
        if arguments.output.read_bytes() != canonical_bytes(document):
            raise Tranche1AcceptanceError("published aggregate differs from canonical receipt")
    except (OSError, ValueError, Tranche1AcceptanceError) as error:
        print(f"ERROR: Tranche 1 acceptance refused: {error}", file=sys.stderr)
        return 1
    print(arguments.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
