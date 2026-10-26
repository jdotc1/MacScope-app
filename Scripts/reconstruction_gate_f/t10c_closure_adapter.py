"""Current installed T10C closure derived from retained, replayable evidence.

No publication, reviewer authentication, process execution, or historical rewrite
occurs here. The external authority adapter owns the non-installed predecessors.
"""
from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
from dataclasses import dataclass, replace
from pathlib import Path, PurePosixPath
from typing import Any, Mapping

from Scripts.reconstruction.installed_matrix_receipt import (PRESENTATION_SCENARIO,
    PRESENTATION_TEST_IDENTIFIER, presentation_artifact_handoff_name)
from Scripts.reconstruction_task10_adjudication import core
from . import gate_specific_artifact_validator as gates
from .artifact_validator import _open_root_without_symlinks, safe_relative_artifact_path
from .canonical_json import canonical_bytes, canonical_sha256, decode_canonical_bytes, to_primitive
from .command_catalog import CampaignProfile, CommandExecutionMode, CommandHost, campaign_profile_for_inputs
from .command_compiler import EXTERNAL_PREREQUISITE_IDS
from .command_execution import ExecutionAdmission
from .evidence_model import EvidenceReceiptInput
from .prerequisite_dag import validate_integrated_lane_c_command_plan
from .qualification_artifact_validator import validate_source_export
from .receipt_validator import (CommandPrerequisiteExpectation, qualification_run_mapping,
                                ReceiptValidationContext, validate_qualification_run_authority, validate_receipt)
from .runtime_resolution import resolve_command_record
from .schema import EvidenceLayer, QualificationPhase, ReceiptType, STABLE_ID_RE

COMMAND_ID = "evidence.t10c-current-source-adjudication"
INSTALLED_COMMANDS = tuple(sorted(("installed.task10-workflow", "installed.accessibility-semantics",
    "installed.source-equality", "installed.shell-smoke", "installed.emit-report")))
MAX_BYTES = gates.MAX_SEMANTIC_ARTIFACT_BYTES
_INSTALLED_ROLES = {
    "installed.accessibility-semantics": (ReceiptType.INSTALLED_ACCESSIBILITY, EvidenceLayer.INSTALLED_ACCESSIBILITY),
    "installed.emit-report": (ReceiptType.INSTALLED_WORKFLOW, EvidenceLayer.INSTALLED_WORKFLOW),
    "installed.shell-smoke": (ReceiptType.INSTALLED_LAUNCH_LOG, EvidenceLayer.INSTALLED_LAUNCH_LOG),
    "installed.source-equality": (ReceiptType.INSTALLED_SOURCE_EQUALITY, EvidenceLayer.INSTALLED_SOURCE_EQUALITY),
    "installed.task10-workflow": (ReceiptType.INSTALLED_WORKFLOW, EvidenceLayer.INSTALLED_WORKFLOW),
}
_GAP_VECTORS = {
    "T10A-P2-006": ("covering.presentation.000", "xcui.keyboardAndMenuEquivalence",
                     "xcui.privacyNoRawPathPromptPseudocode"),
    "T10A-P2-008": ("history.jobs.1.provenance.crashAfterCommit", "xcui.saveReopenProjectsBeforeResume"),
    "T10A-P3-003": ("covering.presentation.000", "xcui.destinationVisibleWhenReady",
                     "xcui.destinationVisibleWhenEndpointMissing", "xcui." + PRESENTATION_SCENARIO),
}


@dataclass(frozen=True)
class T10CClosureAdmission:
    execution: ExecutionAdmission
    profile: CampaignProfile
    historical_bundle_root: Path
    historical_bundle_ledger_sha256: str
    current_bundle_root: Path
    installed_receipts: tuple[EvidenceReceiptInput, ...]
    reviewer_id: str
    started_at_unix_ms: int
    ended_at_unix_ms: int


@dataclass(frozen=True)
class T10CClosureSemantics:
    source_drift: Mapping[str, Any]
    adjudication: Mapping[str, Any]
    review: Mapping[str, Any]
    execution_report: Mapping[str, Any]
    authority: Mapping[str, Any]


class T10CClosureError(ValueError):
    pass


def _require(condition, message):
    if not condition:
        raise T10CClosureError(message)


def _digest(data):
    return hashlib.sha256(data).hexdigest()


def _metadata(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns, info.st_nlink)


def _read(root, name):
    """Bounded descriptor read with file and ancestor identity, including links."""
    _require(safe_relative_artifact_path(name), "invalid closure relative path")
    descriptors = []
    try:
        fd = _open_root_without_symlinks(root, descriptors)
        ancestors = [(os.fstat(item).st_dev, os.fstat(item).st_ino) for item in descriptors]
        parts = PurePosixPath(name).parts
        for part in parts[:-1]:
            fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            descriptors.append(fd)
            ancestors.append((os.fstat(fd).st_dev, os.fstat(fd).st_ino))
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        descriptors.append(fd)
        before = os.fstat(fd)
        _require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_size <= MAX_BYTES,
                 "closure member is not a bounded ordinary single-link file")
        data = bytearray()
        while len(data) <= MAX_BYTES:
            chunk = os.read(fd, min(1024 * 1024, MAX_BYTES + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        _require(len(data) <= MAX_BYTES and _metadata(before) == _metadata(os.fstat(fd)),
                 "closure member changed during read")
        return bytes(data), (tuple(ancestors), _metadata(before), _digest(data))
    finally:
        for fd in reversed(descriptors):
            os.close(fd)


class _Fence:
    def __init__(self):
        self.observations = {}

    def read(self, root, name):
        data, identity = _read(root, name)
        key = (root, name)
        if key in self.observations:
            _require(self.observations[key] == identity, "closure member mutated between reads")
        self.observations[key] = identity
        return data

    def check(self):
        for (root, name), expected in self.observations.items():
            _require(_read(root, name)[1] == expected, "closure member mutated at final fence")


def _decode(data, *, newline=False):
    if newline:
        _require(data.endswith(b"\n") and not data.endswith(b"\n\n"), "T10C JSON needs one trailing LF")
        data = data[:-1]
    return decode_canonical_bytes(data)


def _ledger_bytes(ledger):
    return "".join(digest + "  " + name + "\n" for name, digest in sorted(ledger.items())).encode()


def _historical_bundle(root, expected_digest, fence):
    raw = fence.read(root, "bundle.sha256")
    _require(_digest(raw) == expected_digest, "historical ledger differs from retained authority")
    ledger = gates._parse_t10c_bundle_ledger(raw)
    members = {name: fence.read(root, name) for name in sorted(ledger)}
    _require(all(_digest(members[name]) == digest for name, digest in ledger.items()),
             "historical physical bundle member differs from ledger")
    source = _decode(members["SOURCE_DRIFT.json"], newline=True)
    adjudication = _decode(members["FINDING_ADJUDICATION.json"], newline=True)
    gates._validate_t10c_adjudication(adjudication, source_drift=source, historical=True)
    _require(source.get("schemaVersion") == 1 and source.get("originalSource") == {
        "commit": core.T10A_ACCEPTED_MAIN, "tree": core.T10A_ACCEPTED_TREE}, "historical source identity differs")
    _require([row.get("findingID") for row in source["mappings"]] ==
             list(gates._T10C_HISTORICAL_FINDING_IDS), "historical mapping inventory differs")
    historical_mappings = {row["findingID"]: row for row in source["mappings"]}
    historical_findings = {row["findingID"]: row for row in adjudication["findings"]}
    for spec in core.FINDING_SPECS:
        mapping = historical_mappings[spec.finding_id]
        row = historical_findings[spec.finding_id]
        _require((mapping["currentPath"], mapping["currentSymbol"], mapping["currentAnchor"], mapping["requiredTokens"])
                 == (spec.current_path, spec.current_symbol, spec.anchor, list(spec.required_tokens)),
                 "historical finding mapping differs from frozen source specification")
        _require((row["outcome"], row["currentSeverity"], row["blocks"], row["closestTestSuite"],
                  row["installedExecutionRequired"], row["expectedProductionBehavior"])
                 == (spec.outcome, spec.current_severity, spec.blocks, spec.closest_suite,
                     bool(spec.installed_vector_ids), spec.current_behavior), "historical finding classification differs")
    return ledger, source, adjudication


def _source_drift(candidate, root, fence):
    mappings, hashes = [], {}
    for spec in core.FINDING_SPECS:
        data = fence.read(root, spec.current_path)
        text = data.decode("utf-8")
        _require(all(token in text for token in spec.required_tokens), "required current source token missing")
        fingerprint, line = core._semantic_fingerprint(text, spec.anchor, radius=18)
        hashes[spec.current_path] = _digest(data)
        mappings.append({"findingID": spec.finding_id, "currentPath": spec.current_path,
            "currentSymbol": spec.current_symbol, "currentAnchor": spec.anchor,
            "currentAnchorLineDiagnosticOnly": line, "currentBlobSHA256": hashes[spec.current_path],
            "semanticFingerprintSHA256": fingerprint, "requiredTokens": list(spec.required_tokens),
            "classification": spec.drift, "directlyEvaluable": True})
    return {"schemaVersion": 1, "taskID": core.TASK_ID,
        "originalSource": {"commit": core.T10A_ACCEPTED_MAIN, "tree": core.T10A_ACCEPTED_TREE},
        "currentSource": {"headCommit": candidate.source.commit, "headTree": candidate.source.tree,
            "worktreeInputManifestSHA256": core._manifest_digest(hashes), "inputPathCount": len(hashes),
            "dirtyInputPaths": [], "identityInterpretation":
                "HEAD identifies ancestry; the manifest identifies exact inspected worktree bytes."},
        "mappings": mappings, "mappingCount": len(mappings), "allSymbolsResolved": True}


def _adjudication(historical, source):
    result = _decode(canonical_bytes(historical))
    mappings = {row["findingID"]: row for row in source["mappings"]}
    current_ids = {spec.finding_id for spec in core.FINDING_SPECS}
    _require(set(mappings) == current_ids and len(source["mappings"]) == len(current_ids),
             "current source mapping inventory differs")
    result["findings"] = [row for row in result["findings"] if row["findingID"] in current_ids]
    _require([row["findingID"] for row in result["findings"]] == sorted(current_ids),
             "current finding inventory differs")
    result.update(schemaVersion=2, sourceIdentity=source["currentSource"], findingCount=len(current_ids),
        openSeverityCounts={"P1": 0, "P2": 0},
        outcomeCounts={"already-fixed-on-current-source": 15, "closed-by-current-installed-evidence": 3,
                       "obsolete-after-source-change": 0})
    for row in result["findings"]:
        mapping = mappings[row["findingID"]]
        for key in ("currentPath", "currentSymbol", "currentBlobSHA256", "semanticFingerprintSHA256"):
            row[key] = mapping[key]
        if row["findingID"] in _GAP_VECTORS:
            row.update(outcome="closed-by-current-installed-evidence", currentSeverity="none", blocks="neither")
    return result


def _admit(admission):
    _require(isinstance(admission, T10CClosureAdmission) and isinstance(admission.execution, ExecutionAdmission),
             "retained T10C closure admission required")
    execution = admission.execution
    retained = execution.integrated_plan_input
    integrated = replace(retained, inputs=_decode(canonical_bytes(retained.inputs)),
                         templates=dict(retained.templates))
    _require(admission.profile is CampaignProfile.BOOTSTRAP_VERIFIER and
             campaign_profile_for_inputs(integrated.inputs) is admission.profile, "T10C closure requires bootstrap profile")
    validated, issues = validate_integrated_lane_c_command_plan(integrated, candidate=execution.candidate,
                                                              profile=admission.profile)
    _require(validated is not None and not issues, "T10C full command-plan admission failed: " +
             "; ".join(item.code for item in issues))
    records = [item for item in integrated.plan.commands if item.command_id == COMMAND_ID]
    _require(len(records) == 1, "T10C command missing or duplicated")
    record = records[0]
    _require(record.execution_mode is CommandExecutionMode.EXECUTOR_REQUIRED and
             record.host is CommandHost.INDEPENDENT_REVIEWER and
             record.evidence_layer is EvidenceLayer.INDEPENDENT_REVIEW, "T10C external command role differs")
    run = execution.qualification_run
    _require(not validate_qualification_run_authority(qualification_run_mapping(run), expected=run, path="$.run")
        and (integrated.inputs["qualification_run_id"], integrated.inputs["qualification_run_nonce"]) ==
            (run.run_id, run.nonce), "T10C run differs from compiled authority")
    _require((execution.producer_source_commit, execution.producer_source_tree) ==
             (execution.candidate.source.commit, execution.candidate.source.tree), "T10C producer source differs")
    predecessors = execution.admitted_predecessors
    _require(type(predecessors) is tuple and all(isinstance(p, CommandPrerequisiteExpectation) for p in predecessors),
             "T10C requires exact retained predecessor tuple")
    expected = tuple(sorted(set(record.prerequisite_ids) - EXTERNAL_PREREQUISITE_IDS))
    _require(tuple(p.command_id for p in predecessors) == expected and set(INSTALLED_COMMANDS).issubset(expected)
             and len({p.receipt_id for p in predecessors}) == len(predecessors), "T10C predecessor set/order differs")
    _require(all((p.qualification_run_id, p.qualification_run_nonce) == (run.run_id, run.nonce)
                 for p in predecessors), "T10C predecessor run differs")
    resolve_command_record(record, prerequisite_receipts=predecessors, qualification_run=run, profile=admission.profile)
    _require(isinstance(admission.reviewer_id, str) and STABLE_ID_RE.fullmatch(admission.reviewer_id) is not None,
             "T10C independent reviewer label invalid")
    _require(type(admission.started_at_unix_ms) is int and type(admission.ended_at_unix_ms) is int and
             0 <= admission.started_at_unix_ms <= admission.ended_at_unix_ms, "T10C interval invalid")
    return validated, record


def _installed(admission, fence):
    from .command_execution import ExecutionCapture
    from .executor_request_adapter import ExecutorReceiptAdmission
    inputs = admission.installed_receipts
    _require(type(inputs) is tuple and len(inputs) == 5 and all(isinstance(i, EvidenceReceiptInput) for i in inputs),
             "T10C requires exactly five retained installed inputs")
    expected = {item.command_id: item for item in admission.execution.admitted_predecessors}
    receipts = {}
    for item in inputs:
        receipt = _decode(canonical_bytes(item.receipt))
        command = receipt.get("command_id")
        _require(command in INSTALLED_COMMANDS and command not in receipts, "T10C installed command missing/extra/duplicate")
        context = item.context
        _require(isinstance(context, ReceiptValidationContext), "installed predecessor retained context missing")
        _require(context.expected_candidate == admission.execution.candidate and
            context.expected_qualification_run == admission.execution.qualification_run and
            context.qualification_phase is QualificationPhase.PREMERGE and
            isinstance(context.capture_admission, ExecutorReceiptAdmission) and
            isinstance(context.capture_admission.capture, ExecutionCapture),
            "installed predecessor candidate/run/phase/capture differs")
        _require((context.expected_receipt_type, context.expected_layer) == _INSTALLED_ROLES[command],
                 "installed predecessor semantic receipt role differs")
        capture_execution = context.capture_admission.capture.admission
        _require(capture_execution.integrated_plan_input == admission.execution.integrated_plan_input,
                 "installed predecessor compiled profile/plan differs")
        for artifact in receipt.get("artifacts", ()):
            _require(context.artifact_root is not None, "installed physical root missing")
            fence.read(context.artifact_root, artifact["relative_path"])
        if command == "installed.task10-workflow":
            _matrix_handoff(receipt, context,
                _decode(canonical_bytes(admission.execution.integrated_plan_input.inputs)), fence)
        issues = validate_receipt(receipt, context=context)
        _require(not issues and receipt.get("evidence_status") == "passed" and not receipt.get("skips"),
                 "installed predecessor failed public replay or contains skips")
        predecessor = expected[command]
        _require((receipt.get("receipt_id"), receipt.get("canonical_sha256"), receipt.get("qualification_run")) ==
            (predecessor.receipt_id, predecessor.canonical_sha256, qualification_run_mapping(admission.execution.qualification_run)),
            "installed predecessor substituted")
        _require(receipt["execution_interval"]["ended_at_unix_ms"] <= admission.started_at_unix_ms,
                 "T10C interval precedes installed terminal observation")
        constituents = receipt["constituents"]
        _require(constituents and all(row["status"] == "passed" and row["artifact_ids"] for row in constituents),
                 "installed predecessor lacks passed physical selectors")
        receipts[command] = receipt
    _require(tuple(receipts) == INSTALLED_COMMANDS, "installed retained inputs must be command sorted")
    _require("installed.accessibility" in {c["selector_id"] for c in receipts["installed.accessibility-semantics"]["constituents"]},
             "accessibility predecessor has wrong selector")
    _require("installed.no-unauthorized-network-or-acquisition" in
             {c["selector_id"] for c in receipts["installed.task10-workflow"]["constituents"]},
             "matrix predecessor has wrong selector")
    return receipts


def _matrix_handoff(receipt, context, inputs, fence):
    """Fence matrix PNG handoff members that are nested, not top-level artifacts."""
    artifacts = [a for a in receipt["artifacts"]
                 if a["command_output"] == "artifact:" + inputs["installed_matrix_receipt"]]
    _require(len(artifacts) == 1, "installed matrix physical receipt output missing")
    artifact = artifacts[0]
    raw = fence.read(context.artifact_root, artifact["relative_path"])
    matrix = json.loads(raw, object_pairs_hook=gates._closed_json_pairs)
    bundle_name = presentation_artifact_handoff_name(Path(matrix["products"]["xcresult"]["path"]))
    relative = PurePosixPath(artifact["relative_path"]).parent / bundle_name
    manifest = json.loads(fence.read(context.artifact_root, str(relative / "manifest.json")),
                          object_pairs_hook=gates._closed_json_pairs)
    _require(isinstance(manifest, list), "matrix presentation manifest must be an array")
    for entry in manifest:
        _require(isinstance(entry, dict), "matrix presentation manifest entry malformed")
        if entry.get("testIdentifier") != PRESENTATION_TEST_IDENTIFIER:
            continue
        _require(isinstance(entry.get("attachments"), list), "matrix presentation attachments missing")
        for attachment in entry["attachments"]:
            _require(isinstance(attachment, dict), "matrix presentation attachment malformed")
            name = attachment.get("suggestedHumanReadableName")
            if not isinstance(name, str) or not name.startswith(PRESENTATION_SCENARIO + "-"):
                continue
            exported = attachment.get("exportedFileName")
            _require(isinstance(exported, str) and PurePosixPath(exported).name == exported and
                     safe_relative_artifact_path(exported), "matrix presentation attachment path invalid")
            fence.read(context.artifact_root, str(relative / exported))


def _producer_closure(execution, source, fence):
    loaded_root = Path(__file__).resolve().parents[2]
    for module in tuple(sys.modules.values()):
        raw = getattr(module, "__file__", None)
        if not raw:
            continue
        path = Path(raw).absolute()
        try:
            relative = path.relative_to(loaded_root)
        except ValueError:
            continue
        if relative.suffix != ".py" or "tests" in relative.parts:
            continue
        _require(fence.read(loaded_root, relative.as_posix()) ==
            fence.read(source, relative.as_posix()), "loaded producer differs from sealed source")
    catalog = "Scripts/acceptance/installed_selectors.json"
    _require(fence.read(loaded_root, catalog) == fence.read(source, catalog),
             "loaded installed selector catalogue differs from sealed source")


def _derive(admission, *, validate):
    plan, record = _admit(admission)
    execution = admission.execution
    inputs = _decode(canonical_bytes(execution.integrated_plan_input.inputs))
    source = Path(inputs["source_export_root"])
    _require(admission.current_bundle_root != admission.historical_bundle_root, "current bundle cannot overwrite historical evidence")
    provenance = validate_source_export(execution.candidate, source, inputs["integration_ref"])
    fence = _Fence()
    _producer_closure(execution, source, fence)
    historical_ledger, historical_source, historical = _historical_bundle(admission.historical_bundle_root,
        admission.historical_bundle_ledger_sha256, fence)
    historical_candidate = replace(execution.candidate, source=replace(execution.candidate.source,
        commit=historical_source["currentSource"]["headCommit"], tree=historical_source["currentSource"]["headTree"]))
    gates._validate_t10c_source_drift(historical_source, candidate=historical_candidate, historical=True)
    drift = _source_drift(execution.candidate, source, fence)
    adjudication = _adjudication(historical, drift)
    receipts = _installed(admission, fence)
    current = admission.current_bundle_root
    derived = {"SOURCE_DRIFT.json": core.canonical_json_bytes(drift),
               "FINDING_ADJUDICATION.json": core.canonical_json_bytes(adjudication)}
    ledger = {}
    for name in sorted(gates._T10C_BUNDLE_FILES):
        if name in derived:
            data = derived[name]
            if validate:
                _require(fence.read(current, name) == data, "current governed T10C JSON differs from physical derivation")
        else:
            data = fence.read(current, name)
            _require(_digest(data) == historical_ledger[name], "current bundle changed historical selection/archive facts")
        ledger[name] = _digest(data)
    ledger_bytes = _ledger_bytes(ledger)
    authority = {"review_commit": execution.candidate.source.commit, "review_tree": execution.candidate.source.tree,
        "p0_count": 0, "p1_count": 0, "p2_count": 0, "p3_count": 0, "unresolved_blocking_count": 0}
    closure_rows = []
    for finding, vectors in sorted(_GAP_VECTORS.items()):
        commands = ["installed.task10-workflow"]
        if finding != "T10A-P2-008":
            commands.append("installed.accessibility-semantics")
        rows = []
        for command in sorted(commands):
            receipt = receipts[command]
            rows.append({"command_id": command, "receipt_id": receipt["receipt_id"],
                "canonical_sha256": receipt["canonical_sha256"],
                "selector_ids": sorted(c["selector_id"] for c in receipt["constituents"]),
                "artifact_ids": sorted({a for c in receipt["constituents"] for a in c["artifact_ids"]})})
        closure_rows.append({"finding_id": finding, "vector_ids": sorted(vectors), "installed_receipts": rows})
    predecessors = [to_primitive(item) for item in execution.admitted_predecessors]
    review = {"schema_version": 2, "report_kind": "t10c-current-source-installed-closure",
        "reviewer_id": admission.reviewer_id, "observed_at_unix_ms": admission.ended_at_unix_ms,
        "candidate_commit": execution.candidate.source.commit, "candidate_tree": execution.candidate.source.tree,
        "candidate_identity_sha256": plan.candidate_identity_sha256,
        "qualification_run": qualification_run_mapping(execution.qualification_run),
        "command_plan_sha256": plan.command_plan_sha256,
        "command_record_sha256": plan.command_record_sha256_by_id[COMMAND_ID],
        "source_drift_sha256": ledger["SOURCE_DRIFT.json"],
        "finding_adjudication_sha256": ledger["FINDING_ADJUDICATION.json"],
        "bundle_ledger_sha256": _digest(ledger_bytes), "bundle_manifest_sha256": core._manifest_digest(ledger),
        "bundle_file_count": 14, "historical_bundle_ledger_sha256": admission.historical_bundle_ledger_sha256,
        "historical_finding_adjudication_sha256": historical_ledger["FINDING_ADJUDICATION.json"],
        "finding_count": len(core.FINDING_SPECS), "fixed_count": 15, "closed_evidence_gap_count": 3, "obsolete_count": 0,
        "closure_rows": closure_rows, "prerequisite_receipts": predecessors,
        "prerequisite_receipts_sha256": canonical_sha256(predecessors),
        "authority": authority, "result": "passed", "exit_code": 0, "diagnostic": None}
    terminal = {"schema_version": 2, "qualification_run": qualification_run_mapping(execution.qualification_run),
        "predecessor_observations_sha256": canonical_sha256(predecessors),
        "started_at_unix_ms": admission.started_at_unix_ms, "ended_at_unix_ms": admission.ended_at_unix_ms,
        "result": "passed", "exit_code": 0, "stress": None}
    if validate:
        for name, data in (("bundle.sha256", ledger_bytes), ("current-source-independent-review.json", canonical_bytes(review)),
                           ("current-source-review-execution-report.json", canonical_bytes(terminal))):
            _require(fence.read(current, name) == data, "current T10C report/ledger differs from independently derived semantics")
    # Replay retained raw inputs again, and cover modules lazily imported by replay.
    _installed(admission, fence)
    _producer_closure(execution, source, fence)
    _require(validate_source_export(execution.candidate, source, inputs["integration_ref"]) == provenance,
             "sealed source changed at final fence")
    final_plan, final_record = _admit(admission)
    _require(final_plan == plan and final_record == record, "T10C plan changed at final fence")
    _require(_decode(canonical_bytes(execution.integrated_plan_input.inputs)) == inputs,
             "T10C static inputs changed at final fence")
    fence.check()
    return T10CClosureSemantics(drift, adjudication, review, terminal, authority)


def derive_t10c_closure(admission: T10CClosureAdmission) -> T10CClosureSemantics:
    return _derive(admission, validate=False)


def validate_t10c_closure(admission: T10CClosureAdmission) -> T10CClosureSemantics:
    return _derive(admission, validate=True)
