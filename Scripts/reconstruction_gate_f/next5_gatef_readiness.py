#!/usr/bin/env python3
"""Build-free, fail-closed inventory of the remaining Gate F evidence.

This is a thin read-only adapter over the existing Gate F receipt and WS24
live-evidence validators. It cannot create evidence, complete Gate F, or
authorize the evidence-gated merge step.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import stat
import subprocess
import sys
from typing import Any, Iterable, Mapping


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from Scripts.reconstruction import install_release_to_applications as installer  # noqa: E402
from Scripts.reconstruction import installed_matrix_receipt as matrix  # noqa: E402
from Scripts.reconstruction import run_ws24_installed_live_gates as live  # noqa: E402
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    CanonicalJSONError,
    canonical_bytes,
    canonical_sha256,
    file_sha256,
    load_canonical_json,
)
from Scripts.reconstruction_gate_f.command_catalog import (  # noqa: E402
    INSTALLED_ACCESSIBILITY_SCREENSHOT_OUTPUTS,
    PRESENTATION_VARIANTS,
    command_templates,
)
from Scripts.reconstruction_gate_f.executor_receipt import (  # noqa: E402
    ReceiptEmissionError,
    emit_executor_receipt,
)
from Scripts.reconstruction_gate_f.receipt_validator import (  # noqa: E402
    QualificationRunAuthority,
)
from Scripts.reconstruction_gate_f.schema import (  # noqa: E402
    CandidateIdentity,
    CandidateSubjectKind,
    EvidenceStatus,
    candidate_identity_sha256,
    parse_candidate_identity,
)
from Scripts.ws24_emit_installed_qualification_report import (  # noqa: E402
    LIVE_EXECUTION_REPORT_KIND,
    MINIMUM_ACCEPTED_ATTEMPTS,
    REQUIRED_GATES,
    STRESS_GATES,
    ReportError,
    load_installed_selector_catalog,
    validate_live_execution_evidence,
)


PRESERVED_COMMIT = "9fd75a02b34ee89b1511b133c78ab82a588a6c59"
PRESERVED_TREE = "59d0e94e001c6025883f377b741eb38aec334199"
PRESERVED_CANDIDATE_IDENTITY_SHA256 = (
    "97897c421a7ca845815dd81d23c41a6e1c881c72314d155d23200a767619857b"
)
PRESERVED_CANDIDATE_FILE_SHA256 = (
    "2a36a27e054d656258c1999c1f58fa1013f2d4228509a5268f8cef2bafa4ade6"
)
# Canonical GitHub rewrite of the historical checkpoint. Removing only the exact
# admitted LFS attributes entry must reconstruct PRESERVED_TREE, even in a fresh
# clone which does not retain the historical commit or tree objects.
CANONICAL_PRESERVED_COMMIT = "ae1a44e6c762fc88a66945f6a3fb5b4b8a595638"
CANONICAL_PRESERVED_TREE = "ec6629dc17dd60ab379c8fa1fb9207bd6a57e897"
CANONICAL_LFS_ATTRIBUTES = (
    b"ThirdParty/SleighNative/package/lib/libdecomp.a filter=lfs diff=lfs merge=lfs -text\n"
    b"ThirdParty/Zig/zig-0.16.0/zig filter=lfs diff=lfs merge=lfs -text\n"
)
INSTALLED = "exact-installed-accessibility-selectors-screenshots"
DETERMINISTIC = "two-fresh-process-determinism-and-network"
SIGNED_STRESS = "exact-head-signed-xpc-and-stress"
FAMILIES = (INSTALLED, DETERMINISTIC, SIGNED_STRESS)
MAXIMUM_INPUT_BYTES = 64 * 1024 * 1024
PUBLICATION_EXPECTATIONS = frozenset(
    {"blocked-negative-control", "complete-readiness"}
)


class ReadinessError(ValueError):
    pass


# Command, layer, and receipt type form the exact residual admission surface.
# Another governed command cannot be substituted merely because it emitted JSON.
EXECUTOR_REQUIREMENTS: dict[str, tuple[str, str, str]] = {
    "installed.task10-workflow": (INSTALLED, "installed-workflow", "installed-workflow"),
    "installed.accessibility-semantics": (
        INSTALLED,
        "installed-accessibility",
        "installed-accessibility",
    ),
    "reconstruction.deterministic-evidence": (
        DETERMINISTIC,
        "xcode-focused",
        "test-result",
    ),
    "signed-xpc.complete-truncated-content": (SIGNED_STRESS, "signed-xpc", "signed-xpc"),
    "signed-xpc.error-cancellation": (SIGNED_STRESS, "signed-xpc", "signed-xpc"),
    "signed-xpc.supervision": (SIGNED_STRESS, "signed-xpc", "signed-xpc"),
    "stress.reconstruction-authority-races": (
        SIGNED_STRESS,
        "stress-recovery",
        "stress-recovery",
    ),
}
FAMILY_COMMAND_REQUIREMENTS = {
    INSTALLED: frozenset(
        {"installed.task10-workflow", "installed.accessibility-semantics"}
    ),
    # The installed Task 10 owner is the governed network-observation authority
    # consumed alongside the two-fresh-process/cross-hash owner receipt.
    DETERMINISTIC: frozenset(
        {"installed.task10-workflow", "reconstruction.deterministic-evidence"}
    ),
    SIGNED_STRESS: frozenset(
        {
            "signed-xpc.complete-truncated-content",
            "signed-xpc.error-cancellation",
            "signed-xpc.supervision",
            "stress.reconstruction-authority-races",
        }
    ),
}


def _git(root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ("git", "-C", str(root), *arguments),
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        raise ReadinessError(result.stderr.strip() or f"git {' '.join(arguments)} failed")
    return result.stdout.strip()


def _is_ancestor(root: Path, ancestor: str, descendant: str) -> bool:
    result = subprocess.run(
        ("git", "-C", str(root), "merge-base", "--is-ancestor", ancestor, descendant),
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode not in {0, 1}:
        raise ReadinessError(result.stderr.strip() or "git ancestry proof failed")
    return result.returncode == 0


def _object_exists(root: Path, object_name: str) -> bool:
    result = subprocess.run(
        ("git", "-C", str(root), "cat-file", "-e", object_name),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode not in {0, 1, 128}:
        raise ReadinessError("cannot inspect authority object")
    return result.returncode == 0


def _git_bytes(root: Path, *arguments: str) -> bytes:
    result = subprocess.run(
        ("git", "-C", str(root), *arguments),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise ReadinessError("cannot read authority object")
    return result.stdout


def _verify_canonical_mapping(root: Path) -> None:
    if _git(root, "rev-parse", f"{CANONICAL_PRESERVED_COMMIT}^{{tree}}") != CANONICAL_PRESERVED_TREE:
        raise ReadinessError("canonical preserved authority tree differs")
    if _git_bytes(root, "show", f"{CANONICAL_PRESERVED_COMMIT}:.gitattributes") != CANONICAL_LFS_ATTRIBUTES:
        raise ReadinessError("canonical preserved LFS attributes differ")
    tree = _git_bytes(root, "cat-file", "tree", CANONICAL_PRESERVED_TREE)
    retained = bytearray()
    offset = 0
    removed = 0
    while offset < len(tree):
        end = tree.find(b"\0", offset)
        if end < 0 or end + 21 > len(tree):
            raise ReadinessError("malformed canonical preserved tree")
        header = tree[offset:end]
        if header == b"100644 .gitattributes":
            removed += 1
        else:
            retained.extend(tree[offset:end + 21])
        offset = end + 21
    historical_tree = hashlib.sha1(
        b"tree " + str(len(retained)).encode("ascii") + b"\0" + retained
    ).hexdigest()
    if removed != 1 or historical_tree != PRESERVED_TREE:
        raise ReadinessError("canonical preserved snapshot is not the exact admitted mapping")


def _verify_preserved_authority(root: Path) -> tuple[str, ...]:
    anchors = []
    if _object_exists(root, PRESERVED_COMMIT):
        if _git(root, "rev-parse", f"{PRESERVED_COMMIT}^{{tree}}") != PRESERVED_TREE:
            raise ReadinessError("preserved Steps 1-7 authority does not resolve to its recorded tree")
        anchors.append(PRESERVED_COMMIT)
    if _object_exists(root, CANONICAL_PRESERVED_COMMIT):
        _verify_canonical_mapping(root)
        anchors.append(CANONICAL_PRESERVED_COMMIT)
    if not anchors:
        raise ReadinessError("neither preserved authority anchor is available")
    return tuple(anchors)


def _canonical_file(path: Path, *, label: str, maximum_bytes: int) -> tuple[Path, Any]:
    if not path.is_absolute():
        raise ReadinessError(f"{label} must be an absolute path")
    try:
        resolved = path.resolve(strict=True)
        metadata = path.lstat()
    except OSError as error:
        raise ReadinessError(f"{label} is unavailable: {error}") from error
    if (
        resolved != path
        or not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_nlink != 1
    ):
        raise ReadinessError(f"{label} must be one canonical singly-linked regular file")
    if metadata.st_size < 1 or metadata.st_size > maximum_bytes:
        raise ReadinessError(f"{label} must be nonempty and within its physical byte bound")
    return resolved, metadata


def _canonical_directory(path: Path, *, label: str) -> tuple[Path, Any]:
    if not path.is_absolute():
        raise ReadinessError(f"{label} must be an absolute path")
    try:
        resolved = path.resolve(strict=True)
        metadata = path.lstat()
    except OSError as error:
        raise ReadinessError(f"{label} is unavailable: {error}") from error
    if resolved != path or not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise ReadinessError(f"{label} must be one canonical ordinary directory")
    return resolved, metadata


def _claim_inode(
    claims: dict[tuple[int, int], str], *, metadata: Any, evidence_key: str
) -> None:
    inode = (int(metadata.st_dev), int(metadata.st_ino))
    earlier = claims.get(inode)
    if earlier is not None:
        raise ReadinessError(
            f"evidence keys {earlier!r} and {evidence_key!r} resolve to the same inode"
        )
    claims[inode] = evidence_key


def _candidate_from_file(
    *, repository_root: Path, path: Path, inode_claims: dict[tuple[int, int], str]
) -> tuple[CandidateIdentity, dict[str, object]]:
    path, metadata = _canonical_file(
        path, label="candidate identity", maximum_bytes=MAXIMUM_INPUT_BYTES
    )
    _claim_inode(inode_claims, metadata=metadata, evidence_key="candidate-identity")
    try:
        payload = load_canonical_json(path)
    except CanonicalJSONError as error:
        raise ReadinessError(f"candidate identity is not canonical JSON: {error}") from error
    candidate, issues = parse_candidate_identity(payload, path="$.candidate_identity")
    if candidate is None or issues:
        detail = "; ".join(
            f"{issue.code} {issue.path}: {issue.message}" for issue in issues
        )
        raise ReadinessError(f"candidate identity is invalid: {detail}")
    if candidate.subject_kind is not CandidateSubjectKind.CANDIDATE:
        raise ReadinessError("residual evidence subject must be an exact candidate, not a merge identity")
    if candidate.source.dirty:
        raise ReadinessError("residual evidence candidate source is dirty")
    if _git(repository_root, "rev-parse", f"{candidate.source.commit}^{{commit}}") != candidate.source.commit:
        raise ReadinessError("candidate source commit is not an exact local commit object")
    if _git(repository_root, "rev-parse", f"{candidate.source.commit}^{{tree}}") != candidate.source.tree:
        raise ReadinessError("candidate source tree does not match its commit")
    if not any(_is_ancestor(repository_root, anchor, candidate.source.commit)
               for anchor in _verify_preserved_authority(repository_root)):
        raise ReadinessError("candidate is not the preserved Steps 1-7 authority or its successor")
    identity_digest = candidate_identity_sha256(candidate)
    physical_digest = file_sha256(path)
    if candidate.source.commit == PRESERVED_COMMIT and (
        candidate.source.tree != PRESERVED_TREE
        or identity_digest != PRESERVED_CANDIDATE_IDENTITY_SHA256
        or physical_digest != PRESERVED_CANDIDATE_FILE_SHA256
    ):
        raise ReadinessError("supplied preserved candidate differs from its immutable recorded identity")
    return candidate, {
        "path": str(path),
        "byte_count": metadata.st_size,
        "file_sha256": physical_digest,
        "candidate_identity_sha256": identity_digest,
        "source_commit": candidate.source.commit,
        "source_tree": candidate.source.tree,
        "validated": True,
        "selection": (
            "explicit-preserved-candidate"
            if candidate.source.commit == PRESERVED_COMMIT
            else "explicit-validated-successor"
        ),
    }


def _owner_outputs(command_id: str) -> tuple[str, ...]:
    matches = [item for item in command_templates() if item.command_id == command_id]
    if len(matches) != 1 or not matches[0].generated_artifacts:
        raise ReadinessError(f"live Gate F command output authority missing: {command_id}")
    return tuple(matches[0].generated_artifacts)


def catalog_snapshot() -> dict[str, object]:
    selectors = tuple(item["testIdentifier"] for item in load_installed_selector_catalog())
    variants = tuple(matrix.PRESENTATION_VARIANTS)
    if variants != tuple(PRESENTATION_VARIANTS):
        raise ReadinessError("installed and Gate F screenshot catalogs disagree")
    if len(INSTALLED_ACCESSIBILITY_SCREENSHOT_OUTPUTS) != len(variants):
        raise ReadinessError("Gate F screenshot outputs do not close the installed matrix")
    if set(STRESS_GATES) != set(live.STRESS_GATES):
        raise ReadinessError("WS24 stress owners disagree")
    if any(MINIMUM_ACCEPTED_ATTEMPTS[gate] < 10 for gate in STRESS_GATES):
        raise ReadinessError("WS24 stress authority permits fewer than ten attempts")
    return {
        "ws24_required_gates": list(REQUIRED_GATES),
        "ws24_required_gate_count": len(REQUIRED_GATES),
        "installer_transaction_gates": list(installer.REQUIRED_ACCEPTANCE_GATES),
        "installer_transaction_gate_count": len(installer.REQUIRED_ACCEPTANCE_GATES),
        "installed_selector_count": len(selectors),
        "installed_selector_catalog_sha256": canonical_sha256(selectors),
        "governed_screenshot_count": len(variants),
        "governed_screenshot_catalog_sha256": canonical_sha256(variants),
        "stress_families": sorted(STRESS_GATES),
        "stress_family_count": len(STRESS_GATES),
        "minimum_attempts_per_stress_family": min(
            MINIMUM_ACCEPTED_ATTEMPTS[gate] for gate in STRESS_GATES
        ),
    }


def _validate_executor_request(
    *,
    command_id: str,
    request_path: Path | None,
    artifact_root: Path,
    candidate: CandidateIdentity,
    qualification_run: QualificationRunAuthority | None,
    inode_claims: dict[tuple[int, int], str],
    admission: object = None,
    completed_result: object = None,
    shared_container: Path | None = None,
) -> tuple[dict[str, object], QualificationRunAuthority]:
    family, expected_layer, expected_receipt_type = EXECUTOR_REQUIREMENTS[command_id]
    if completed_result is None:
        request_path, request_metadata = _canonical_file(
            request_path, label=f"{command_id} executor request", maximum_bytes=MAXIMUM_INPUT_BYTES,
        )
        _claim_inode(inode_claims, metadata=request_metadata, evidence_key=f"executor:{command_id}:request")
        try:
            request = load_canonical_json(request_path)
        except CanonicalJSONError as error:
            raise ReadinessError(f"{command_id} request is not canonical JSON: {error}") from error
    else:
        # Called only with freshly replayed completions from load_run below.
        request = completed_result.request
    artifact_root, root_metadata = _canonical_directory(
        artifact_root, label=f"{command_id} artifact root"
    )
    if shared_container is None:
        _claim_inode(inode_claims, metadata=root_metadata, evidence_key=f"executor:{command_id}:artifact-root")
    elif artifact_root != shared_container or completed_result is None:
        raise ReadinessError("shared artifact container requires freshly validated persisted-run completion")
    if not isinstance(request, Mapping) or request.get("command_id") != command_id:
        raise ReadinessError(f"{command_id} request has the wrong Gate F owner command ID")
    if request.get("evidence_layer") != expected_layer:
        raise ReadinessError(f"{command_id} request has the wrong Gate F evidence layer")
    if request.get("receipt_type") != expected_receipt_type:
        raise ReadinessError(f"{command_id} request has the wrong Gate F report kind")
    from Scripts.reconstruction_gate_f.executor_request_adapter import ExecutorReceiptAdmission
    if not isinstance(admission, ExecutorReceiptAdmission):
        raise ReadinessError("executor request requires independent persisted-run capture admission")
    admitted_run = admission.capture.admission.qualification_run
    if admission.capture.admission.candidate != candidate:
        raise ReadinessError("capture admission belongs to another independently selected candidate")
    if qualification_run is None or admitted_run != qualification_run:
        raise ReadinessError("capture admission differs from independently supplied qualification run")
    request_run = admitted_run
    try:
        receipt, _ = emit_executor_receipt(
            request,
            artifact_root=artifact_root,
            qualification_run_authority=request_run,
            admission=admission,
        )
    except (OSError, ValueError) as error:
        raise ReadinessError(f"{command_id} owner validation failed: {error}") from error
    if completed_result is not None and receipt != completed_result.receipt:
        raise ReadinessError("persisted-run owner evidence changed during readiness validation")
    expected_candidate_digest = candidate_identity_sha256(candidate)
    if receipt.get("candidate_identity_sha256") != expected_candidate_digest:
        raise ReadinessError(f"{command_id} receipt belongs to another candidate")
    receipt_candidate = receipt.get("candidate_identity")
    if not isinstance(receipt_candidate, Mapping):
        raise ReadinessError(f"{command_id} receipt omits its candidate")
    receipt_source = receipt_candidate.get("source")
    if not isinstance(receipt_source, Mapping) or (
        receipt_source.get("commit") != candidate.source.commit
        or receipt_source.get("tree") != candidate.source.tree
    ):
        raise ReadinessError(f"{command_id} receipt source is not the exact candidate")
    if (
        receipt.get("command_id") != command_id
        or receipt.get("evidence_layer") != expected_layer
        or receipt.get("receipt_type") != expected_receipt_type
        or receipt.get("evidence_status") != EvidenceStatus.PASSED.value
        or receipt.get("skips") != []
    ):
        raise ReadinessError(f"{command_id} receipt does not prove a passed exact-scope execution")

    artifacts: list[dict[str, object]] = []
    raw_artifacts = receipt.get("artifacts")
    if not isinstance(raw_artifacts, list) or not raw_artifacts:
        raise ReadinessError(f"{command_id} receipt has no physical artifacts")
    for artifact in raw_artifacts:
        if not isinstance(artifact, Mapping):
            raise ReadinessError(f"{command_id} receipt has a malformed artifact record")
        artifact_id = artifact.get("artifact_id")
        relative_path = artifact.get("relative_path")
        if not isinstance(artifact_id, str) or not isinstance(relative_path, str):
            raise ReadinessError(f"{command_id} receipt has an unbound artifact")
        physical_path = artifact_root / relative_path
        physical_path, metadata = _canonical_file(
            physical_path,
            label=f"{command_id} artifact {artifact_id}",
            maximum_bytes=MAXIMUM_INPUT_BYTES,
        )
        evidence_key = f"executor:{command_id}:artifact:{artifact_id}"
        _claim_inode(inode_claims, metadata=metadata, evidence_key=evidence_key)
        artifacts.append(
            {
                "evidence_key": evidence_key,
                "artifact_id": artifact_id,
                "path": str(physical_path),
                "byte_count": artifact.get("byte_count"),
                "sha256": artifact.get("sha256"),
                "media_type": artifact.get("media_type"),
                "kind": artifact.get("kind"),
                "root_id": artifact.get("root_id"),
                "producer_receipt_id": artifact.get("producer_receipt_id"),
                "command_output": artifact.get("command_output"),
            }
        )
    return (
        {
            "family_id": family,
            "command_id": command_id,
            "request_path": str(request_path) if request_path is not None else None,
            "request_sha256": canonical_sha256(request),
            "artifact_root": str(artifact_root),
            "evidence_layer": expected_layer,
            "receipt_type": expected_receipt_type,
            "receipt_id": receipt.get("receipt_id"),
            "receipt_sha256": receipt.get("canonical_sha256"),
            "command_plan_sha256": receipt.get("command_plan_sha256"),
            "qualification_run": {
                "run_id": request_run.run_id,
                "nonce": request_run.nonce,
            },
            "artifact_count": len(artifacts),
            "artifacts": artifacts,
            "owner_generated_outputs": list(_owner_outputs(command_id)),
            "validated_by": "Scripts.reconstruction_gate_f.executor_receipt.emit_executor_receipt",
        },
        request_run,
    )


def _validate_stress_report(
    *,
    gate: str,
    path: Path,
    candidate: CandidateIdentity,
    evidence_index: int,
    inode_claims: dict[tuple[int, int], str],
) -> dict[str, object]:
    path, metadata = _canonical_file(
        path,
        label=f"{gate} live stress report",
        maximum_bytes=1024 * 1024,
    )
    evidence_key = f"ws24-live-stress:{gate}"
    _claim_inode(inode_claims, metadata=metadata, evidence_key=evidence_key)
    digest = file_sha256(path)
    try:
        normalized = validate_live_execution_evidence(
            gate,
            [{"kind": LIVE_EXECUTION_REPORT_KIND, "path": str(path), "sha256": digest}],
            evidence_index=evidence_index,
            expected_source_commit=candidate.source.commit,
            expected_source_tree=candidate.source.tree,
            expected_installed_executable_sha256=candidate.application.executable_sha256,
        )
    except (OSError, ReportError) as error:
        raise ReadinessError(f"{gate} owner validation failed: {error}") from error
    if (
        normalized.get("status") != "passed"
        or normalized.get("acceptedAttempts", 0) < MINIMUM_ACCEPTED_ATTEMPTS[gate]
        or normalized.get("failureCount") != 0
    ):
        raise ReadinessError(
            f"{gate} does not prove consecutive minimum attempts with zero failures/timeouts"
        )
    return {
        "family_id": SIGNED_STRESS,
        "evidence_key": evidence_key,
        "gate": gate,
        "path": str(path),
        "byte_count": metadata.st_size,
        "sha256": digest,
        "accepted_attempts": normalized["acceptedAttempts"],
        "attempt_seeds": normalized["attemptSeeds"],
        "failure_count": normalized["failureCount"],
        "source_commit": candidate.source.commit,
        "source_tree": candidate.source.tree,
        "installed_executable_sha256": candidate.application.executable_sha256,
        "validated_by": (
            "Scripts.ws24_emit_installed_qualification_report."
            "validate_live_execution_evidence"
        ),
    }


def _missing_inputs(
    *,
    candidate_supplied: bool,
    executor_requests: Mapping[str, Path],
    artifact_roots: Mapping[str, Path],
    stress_reports: Mapping[str, Path],
) -> dict[str, list[dict[str, object]]]:
    missing = {family: [] for family in FAMILIES}
    if not candidate_supplied:
        for family in FAMILIES:
            missing[family].append(
                {
                    "evidence_key": "candidate-identity",
                    "description": "explicit canonical CandidateIdentity for the residual evidence subject",
                }
            )
    for family, commands in FAMILY_COMMAND_REQUIREMENTS.items():
        for command_id in sorted(commands):
            _, layer, receipt_type = EXECUTOR_REQUIREMENTS[command_id]
            if command_id not in executor_requests:
                missing[family].append(
                    {
                        "evidence_key": f"executor:{command_id}:request",
                        "description": "closed executor-receipt request validated by the existing owner",
                        "evidence_layer": layer,
                        "receipt_type": receipt_type,
                        "owner_generated_outputs": list(_owner_outputs(command_id)),
                    }
                )
            if command_id not in artifact_roots:
                missing[family].append(
                    {
                        "evidence_key": f"executor:{command_id}:artifact-root",
                        "description": "canonical physical root for every request-bound artifact",
                    }
                )
    for gate in sorted(STRESS_GATES):
        if gate not in stress_reports:
            missing[SIGNED_STRESS].append(
                {
                    "evidence_key": f"ws24-live-stress:{gate}",
                    "description": (
                        "closed WS24 live report with consecutive attempts, exact source/app, "
                        "and zero failures/timeouts"
                    ),
                    "minimum_attempts": MINIMUM_ACCEPTED_ATTEMPTS[gate],
                }
            )
    return missing


def build_readiness(
    *,
    repository_root: Path,
    candidate_identity_path: Path | None = None,
    executor_requests: Mapping[str, Path] | None = None,
    artifact_roots: Mapping[str, Path] | None = None,
    stress_reports: Mapping[str, Path] | None = None,
    qualification_run_authority: QualificationRunAuthority | None = None,
    executor_admissions: Mapping[str, object] | None = None,
    operator_run_root: Path | None = None,
) -> dict[str, object]:
    repository_root = repository_root.resolve(strict=True)
    _verify_preserved_authority(repository_root)
    requests = dict(executor_requests or {})
    roots = dict(artifact_roots or {})
    stress = dict(stress_reports or {})
    if operator_run_root is not None and (
        requests or roots or qualification_run_authority is not None or executor_admissions is not None
    ):
        raise ReadinessError("persisted-run inputs cannot be mixed with caller executor requests, roots or admissions")
    unknown_commands = sorted((set(requests) | set(roots)) - set(EXECUTOR_REQUIREMENTS))
    if unknown_commands:
        raise ReadinessError(
            "evidence is not an exact Gate F residual owner command: "
            + ", ".join(unknown_commands)
        )
    unknown_stress = sorted(set(stress) - set(STRESS_GATES))
    if unknown_stress:
        raise ReadinessError(
            "evidence is not an exact Gate F stress family: " + ", ".join(unknown_stress)
        )
    if set(requests) != set(roots):
        raise ReadinessError("every executor request requires its uniquely bound artifact root")
    if candidate_identity_path is None and (requests or roots or stress or operator_run_root is not None):
        raise ReadinessError("physical evidence requires an explicit validated CandidateIdentity")

    inode_claims: dict[tuple[int, int], str] = {}
    candidate: CandidateIdentity | None = None
    if candidate_identity_path is None:
        subject: dict[str, object] = {
            "selection": "preserved-candidate-default",
            "source_commit": PRESERVED_COMMIT,
            "source_tree": PRESERVED_TREE,
            "candidate_identity_sha256": PRESERVED_CANDIDATE_IDENTITY_SHA256,
            "candidate_file_sha256": PRESERVED_CANDIDATE_FILE_SHA256,
            "validated": False,
            "physical_candidate_identity_available": False,
        }
    else:
        candidate, subject = _candidate_from_file(
            repository_root=repository_root,
            path=candidate_identity_path,
            inode_claims=inode_claims,
        )

    validated_receipts: list[dict[str, object]] = []
    shared_plan_sha256: str | None = None
    qualification_run = qualification_run_authority
    completed = {}
    run = None
    if operator_run_root is not None:
        from Scripts.reconstruction_gate_f.operator_run import load_run
        try:
            run = load_run(operator_run_root)
            if run.candidate != candidate:
                raise ReadinessError("persisted run belongs to another independently selected candidate")
            _, container_metadata = _canonical_directory(run.root, label="persisted run")
            _claim_inode(inode_claims, metadata=container_metadata, evidence_key="persisted-run:container")
            for command_id in sorted(EXECUTOR_REQUIREMENTS):
                completed[command_id] = run.completed_result(command_id)
            run._unchanged()
        except (OSError, ValueError) as error:
            raise ReadinessError(f"persisted run validation failed: {error}") from error
        requests = dict.fromkeys(completed)
        roots = {command: run.root for command in completed}
        executor_admissions = {command: result.admission for command, result in completed.items()}
        qualification_run = run.qualification_run
    if candidate is not None:
        for command_id in sorted(requests):
            validated, qualification_run = _validate_executor_request(
                command_id=command_id,
                request_path=requests[command_id],
                artifact_root=roots[command_id],
                candidate=candidate,
                qualification_run=qualification_run,
                inode_claims=inode_claims,
                admission=(executor_admissions or {}).get(command_id),
                completed_result=completed.get(command_id),
                shared_container=run.root if run is not None else None,
            )
            plan_sha256 = validated["command_plan_sha256"]
            if shared_plan_sha256 is not None and plan_sha256 != shared_plan_sha256:
                raise ReadinessError("executor captures do not share one independently recompiled command plan")
            shared_plan_sha256 = plan_sha256
            validated_receipts.append(validated)
    validated_stress: list[dict[str, object]] = []
    if candidate is not None:
        for index, gate in enumerate(sorted(stress), start=1):
            validated_stress.append(
                _validate_stress_report(
                    gate=gate,
                    path=stress[gate],
                    candidate=candidate,
                    evidence_index=index,
                    inode_claims=inode_claims,
                )
            )

    if run is not None:
        try:
            run._unchanged()
        except (OSError, ValueError) as error:
            raise ReadinessError(f"persisted run final validation failed: {error}") from error

    missing = _missing_inputs(
        candidate_supplied=candidate is not None,
        executor_requests=requests,
        artifact_roots=roots,
        stress_reports=stress,
    )
    families = []
    for family in FAMILIES:
        receipt_commands = sorted(
            row["command_id"]
            for row in validated_receipts
            if row["command_id"] in FAMILY_COMMAND_REQUIREMENTS[family]
        )
        stress_gates = sorted(
            row["gate"] for row in validated_stress if row["family_id"] == family
        )
        families.append(
            {
                "family_id": family,
                "complete": not missing[family],
                "validated_executor_commands": receipt_commands,
                "validated_stress_gates": stress_gates,
                "missing_physical_inputs": missing[family],
            }
        )
    ready = candidate is not None and all(family["complete"] for family in families)
    return {
        "schema_version": 2,
        "report_kind": "next5-gate-f-readiness-v2",
        "evidence_scope": "gate-f-readiness-only",
        "preserved_steps_1_through_7_authority": {
            "commit": PRESERVED_COMMIT,
            "tree": PRESERVED_TREE,
            "candidate_identity_sha256": PRESERVED_CANDIDATE_IDENTITY_SHA256,
            "candidate_file_sha256": PRESERVED_CANDIDATE_FILE_SHA256,
            "git_object_verified": True,
            "authority_mutated": False,
        },
        "residual_evidence_subject": subject,
        "live_catalog": catalog_snapshot(),
        "validated_executor_receipts": validated_receipts,
        "validated_live_stress_reports": validated_stress,
        "residual_families": families,
        "readiness_status": (
            "physical-evidence-validated-readiness-only"
            if ready
            else "blocked-missing-physical-owner-evidence"
        ),
        "gate_f_completion_claimed": False,
        "step_8": {
            "authorized": False,
            "earliest_calendar_date": None,
            "authorization_source": (
                "date restriction revoked by owner 2026-09-01; this adapter cannot authorize Step 8"
            ),
        },
    }


def _validate_publication_expectation(
    report: Mapping[str, object], expectation: str
) -> None:
    if expectation not in PUBLICATION_EXPECTATIONS:
        raise ReadinessError("unsupported readiness publication expectation")
    if report.get("gate_f_completion_claimed") is not False:
        raise ReadinessError("readiness publication cannot claim Gate F completion")
    step_8 = report.get("step_8")
    if not isinstance(step_8, Mapping) or step_8.get("authorized") is not False:
        raise ReadinessError("readiness publication cannot authorize Step 8")
    families = report.get("residual_families")
    receipts = report.get("validated_executor_receipts")
    stress = report.get("validated_live_stress_reports")
    if not isinstance(families, list) or not isinstance(receipts, list) or not isinstance(
        stress, list
    ):
        raise ReadinessError("readiness publication has malformed evidence collections")
    if expectation == "blocked-negative-control":
        subject = report.get("residual_evidence_subject")
        if (
            report.get("readiness_status") != "blocked-missing-physical-owner-evidence"
            or not isinstance(subject, Mapping)
            or subject.get("selection") != "preserved-candidate-default"
            or subject.get("validated") is not False
            or receipts
            or stress
            or len(families) != len(FAMILIES)
            or any(item.get("complete") is not False for item in families if isinstance(item, Mapping))
            or any(not isinstance(item, Mapping) for item in families)
        ):
            raise ReadinessError("blocked negative control does not match the preserved default")
        return
    receipt_commands = {
        item.get("command_id") for item in receipts if isinstance(item, Mapping)
    }
    stress_gates = {item.get("gate") for item in stress if isinstance(item, Mapping)}
    if (
        report.get("readiness_status")
        != "physical-evidence-validated-readiness-only"
        or len(families) != len(FAMILIES)
        or any(item.get("complete") is not True for item in families if isinstance(item, Mapping))
        or any(not isinstance(item, Mapping) for item in families)
        or receipt_commands != set(EXECUTOR_REQUIREMENTS)
        or len(receipts) != len(EXECUTOR_REQUIREMENTS)
        or stress_gates != set(STRESS_GATES)
        or len(stress) != len(STRESS_GATES)
    ):
        raise ReadinessError("complete readiness does not close every physical owner family")


def _publish_create_only(path: Path, report: dict[str, object]) -> None:
    try:
        matrix.write_create_only(path, report)
        metadata = path.lstat()
        payload = path.read_bytes()
    except (OSError, matrix.InstalledMatrixReceiptError) as error:
        raise ReadinessError(f"readiness publication failed: {error}") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or payload != canonical_bytes(report)
    ):
        raise ReadinessError("published readiness report is not exact, private, and canonical")


def _parse_keyed_paths(arguments: Iterable[str], *, label: str) -> dict[str, Path]:
    parsed: dict[str, Path] = {}
    for argument in arguments:
        key, separator, path = argument.partition("=")
        if not separator or not key or not path or key in parsed:
            raise ReadinessError(f"{label} must use one unique KEY=/absolute/path")
        parsed[key] = Path(path)
    return parsed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", type=Path, default=REPOSITORY_ROOT)
    parser.add_argument("--candidate-identity", type=Path)
    parser.add_argument("--operator-run-root", type=Path,
                        help="read-only replay of all seven owners from a canonical run.json container")
    parser.add_argument("--executor-request", action="append", default=[])
    parser.add_argument("--artifact-root", action="append", default=[])
    parser.add_argument("--stress-report", action="append", default=[])
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--expect-status",
        choices=sorted(PUBLICATION_EXPECTATIONS),
    )
    arguments = parser.parse_args(argv)
    try:
        if (arguments.output is None) != (arguments.expect_status is None):
            raise ReadinessError("--output and --expect-status must be supplied together")
        executor_requests = _parse_keyed_paths(
            arguments.executor_request, label="executor request"
        )
        artifact_roots = _parse_keyed_paths(
            arguments.artifact_root, label="artifact root"
        )
        stress_reports = _parse_keyed_paths(
            arguments.stress_report, label="stress report"
        )
        if arguments.expect_status == "blocked-negative-control" and (
            arguments.candidate_identity is not None
            or executor_requests
            or artifact_roots
            or stress_reports
            or arguments.operator_run_root is not None
        ):
            raise ReadinessError("blocked negative control forbids physical evidence inputs")
        if arguments.expect_status == "complete-readiness" and (
            arguments.candidate_identity is None
            or (arguments.operator_run_root is None and (
                set(executor_requests) != set(EXECUTOR_REQUIREMENTS)
                or set(artifact_roots) != set(EXECUTOR_REQUIREMENTS)))
            or set(stress_reports) != set(STRESS_GATES)
        ):
            raise ReadinessError(
                "complete readiness requires the candidate, a persisted run or all seven owner pairs, "
                "and all three stress reports"
            )
        build_arguments = {
            "repository_root": arguments.repository_root,
            "candidate_identity_path": arguments.candidate_identity,
            "executor_requests": executor_requests,
            "artifact_roots": artifact_roots,
            "stress_reports": stress_reports,
            "operator_run_root": arguments.operator_run_root,
        }
        report = build_readiness(**build_arguments)
        if arguments.output is not None:
            _validate_publication_expectation(report, arguments.expect_status)
            second = build_readiness(**build_arguments)
            _validate_publication_expectation(second, arguments.expect_status)
            if canonical_bytes(second) != canonical_bytes(report):
                raise ReadinessError("readiness physical inputs changed before publication")
            _publish_create_only(arguments.output, report)
    except (OSError, ReadinessError) as error:
        print(f"Gate F readiness failed: {error}", file=sys.stderr)
        return 2
    if arguments.output is not None:
        print(arguments.output)
        return 0
    print(json.dumps(report, separators=(",", ":"), sort_keys=True))
    return 0 if report["readiness_status"] == "physical-evidence-validated-readiness-only" else 1


if __name__ == "__main__":
    raise SystemExit(main())
