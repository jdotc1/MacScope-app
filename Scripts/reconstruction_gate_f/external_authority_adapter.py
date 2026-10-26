"""Retained external observations for the eight non-process Gate F commands.

An admission is local orchestration state, never decoded from receipt JSON.
Reviewer names bind retained assignments; they do not authenticate principals.
No entry point executes an owner command or publishes evidence.
"""
from __future__ import annotations

import stat
import sys
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Mapping, TYPE_CHECKING

from .artifact_validator import read_descriptor_relative_bytes, safe_relative_artifact_path
from .canonical_json import canonical_bytes, canonical_sha256, decode_canonical_bytes, to_primitive
from .command_catalog import (CampaignProfile, CommandExecutionMode,
                              INDEPENDENT_REVIEW_COMMAND_LENSES, campaign_profile_for_inputs)
from .command_execution import ExecutionAdmission
from .evidence_model import EvidenceReceiptInput
from .executor_request_adapter import OwnerArtifactSource, _artifact
from .gate_evaluator import QualifiedPremergeAuthority
from .gate_specific_artifact_validator import MAX_SEMANTIC_ARTIFACT_BYTES
from .prerequisite_dag import validate_integrated_lane_c_command_plan
from .qualification_artifact_validator import validate_source_export
from .receipt_schema import seal_receipt
from .receipt_validator import (CommandPrerequisiteExpectation, ReceiptValidationContext,
                                qualification_run_mapping, validate_receipt)
from .runtime_resolution import resolve_command_record
from .schema import (ArtifactKind, CandidateSubjectKind, EvidenceLayer, EvidenceStatus,
                     QualificationPhase, ReceiptType, candidate_identity_sha256,
                     candidate_to_mapping, is_sha256)

if TYPE_CHECKING:
    from .t10c_closure_adapter import T10CClosureAdmission

T10C_COMMAND = "evidence.t10c-current-source-adjudication"
EXTERNAL_COMMAND_IDS = frozenset({T10C_COMMAND, *INDEPENDENT_REVIEW_COMMAND_LENSES,
                                 "review.independent", "merge.prospective-tree",
                                 "postmerge.exact-tree-proof"})


@dataclass(frozen=True)
class ExternalAuthorityAdmission:
    execution: ExecutionAdmission
    profile: CampaignProfile
    command_id: str
    scenario_id: str
    artifact_root: Path
    receipt_id: str
    requirement_id: str
    qualification_phase: QualificationPhase
    receipt_type: ReceiptType
    artifact_root_id: str
    execution_report_artifact_id: str
    owner_artifacts: tuple[OwnerArtifactSource, ...]
    predecessor_inputs: tuple[EvidenceReceiptInput, ...]
    executor: Mapping[str, str]
    reviewer_assignments: tuple[tuple[str, str], ...]
    retained_observations: tuple[tuple[str, bytes], ...]
    qualified_premerge_authority: QualifiedPremergeAuthority | None
    t10c_closure: T10CClosureAdmission | None
    attempt: int = 1


def _fail(message):
    from .executor_receipt import ReceiptEmissionError
    raise ReceiptEmissionError(message)


def _metadata(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _snapshot(root, relative):
    """Bounded descriptor read plus name/inode fence, including hard links."""
    if not safe_relative_artifact_path(relative):
        _fail("external artifact path escapes its owned root")
    path = root / relative
    before = path.lstat()
    parents = (root, *tuple(path.parents)[:len(Path(relative).parts) - 1])
    parent_before = tuple((p.stat().st_dev, p.stat().st_ino) for p in parents)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        _fail("external proof must be singly-linked ordinary file bytes")
    payload, count, digest = read_descriptor_relative_bytes(
        root, relative, maximum_bytes=MAX_SEMANTIC_ARTIFACT_BYTES)
    after = path.lstat()
    if (_metadata(before) != _metadata(after)
            or path.resolve(strict=True) != path
            or parent_before != tuple((p.stat().st_dev, p.stat().st_ino) for p in parents)):
        _fail("external artifact identity changed during observation")
    return payload, count, digest, (_metadata(after), parent_before)


def _source_fence(execution):
    inputs = execution.integrated_plan_input.inputs
    export = Path(inputs["source_export_root"])
    validate_source_export(execution.candidate, export, inputs["integration_ref"])
    # Bind the actual loaded production Python closure, not an asserted module
    # list. Tests are fixtures, never authority-producing implementation.
    runtime_root = Path(__file__).resolve().parents[2]
    result = {}
    for module in tuple(sys.modules.values()):
        filename = getattr(module, "__file__", None)
        if not filename or not str(filename).endswith(".py"):
            continue
        path = Path(filename).resolve()
        try:
            relative = path.relative_to(runtime_root).as_posix()
        except ValueError:
            name = getattr(module, "__name__", "")
            if name.startswith("Scripts.") and ".tests." not in name and not name.endswith(".tests"):
                _fail("external producer imported repository code from a foreign runtime root: " + name)
            continue
        if not relative.startswith("Scripts/") or "/tests/" in relative or "/test_" in relative:
            continue
        actual = _snapshot(runtime_root, relative)
        sealed = _snapshot(export, relative)
        if actual[:3] != sealed[:3]:
            _fail("loaded external producer differs from sealed candidate: " + relative)
        result[relative] = (actual, sealed)
    if "Scripts/reconstruction_gate_f/external_authority_adapter.py" not in result:
        _fail("external producer closure is absent")
    return result


def _predecessors(admission):
    execution = admission.execution
    from .command_compiler import command_plan_sha256
    expected_plan = command_plan_sha256(execution.integrated_plan_input.plan)
    if admission.command_id == "postmerge.exact-tree-proof":
        if not isinstance(admission.qualified_premerge_authority, QualifiedPremergeAuthority):
            _fail("postmerge requires complete retained premerge plan authority")
        expected_plan = admission.qualified_premerge_authority.command_plan_sha256
    observed = []
    inputs = admission.predecessor_inputs
    if type(inputs) is not tuple:
        _fail("external predecessors require an ordered retained tuple")
    for item in inputs:
        if not isinstance(item, EvidenceReceiptInput) or not isinstance(item.context, ReceiptValidationContext):
            _fail("external predecessor lacks its retained raw receipt/context")
        issues = validate_receipt(item.receipt, context=item.context)
        if issues:
            _fail("external predecessor replay failed: " + "; ".join(issue.code for issue in issues))
        receipt = item.receipt
        if receipt["command_plan_sha256"] != expected_plan:
            _fail("external predecessor belongs to another complete command plan")
        if (receipt["evidence_status"] != EvidenceStatus.PASSED.value
                or receipt["qualification_run"] != qualification_run_mapping(execution.qualification_run)
                or receipt["candidate_identity"] != candidate_to_mapping(execution.candidate)):
            # Postmerge retains the prospective receipt as the exact admitted
            # earlier subject; only its explicit transition is permitted.
            prospective = replace(execution.candidate, subject_kind=CandidateSubjectKind.PROSPECTIVE_MERGE,
                                  accepted_postmerge_commit=None, accepted_postmerge_tree=None)
            if not (admission.command_id == "postmerge.exact-tree-proof"
                    and receipt["command_id"] == "merge.prospective-tree"
                    and receipt["evidence_status"] == "passed"
                    and receipt["qualification_run"] == qualification_run_mapping(execution.qualification_run)
                    and receipt["candidate_identity"] == candidate_to_mapping(prospective)):
                _fail("external predecessor has wrong result, candidate or run")
        observed.append(CommandPrerequisiteExpectation(
            receipt["command_id"], receipt["receipt_id"], receipt["canonical_sha256"],
            receipt["qualification_run"]["run_id"], receipt["qualification_run"]["nonce"]))
    expected = execution.admitted_predecessors
    if (tuple(observed) != expected or tuple(observed) != tuple(sorted(observed))
            or len({item.command_id for item in observed}) != len(observed)
            or len({item.receipt_id for item in observed}) != len(observed)):
        _fail("external predecessors omitted, duplicated, reordered or substituted")
    return tuple(observed)


def _admit(admission):
    if not isinstance(admission, ExternalAuthorityAdmission) or not isinstance(admission.execution, ExecutionAdmission):
        _fail("external authority requires independently retained admission")
    if admission.command_id not in EXTERNAL_COMMAND_IDS:
        _fail("command is not one of the eight external authorities")
    execution = admission.execution
    if type(admission.profile) is not CampaignProfile or campaign_profile_for_inputs(
            execution.integrated_plan_input.inputs) is not admission.profile:
        _fail("external campaign profile differs from independently admitted inputs")
    validated, issues = validate_integrated_lane_c_command_plan(
        execution.integrated_plan_input, candidate=execution.candidate, profile=admission.profile)
    if validated is None or issues:
        _fail("external full plan admission failed: " + "; ".join(issue.code for issue in issues))
    records = [r for r in execution.integrated_plan_input.plan.commands if r.command_id == admission.command_id]
    if len(records) != 1:
        _fail("external command is absent or ambiguous")
    record = records[0]
    expected_role = {"merge.prospective-tree": ReceiptType.PROSPECTIVE_MERGE_TREE,
                     "postmerge.exact-tree-proof": ReceiptType.POST_MERGE}.get(record.command_id, ReceiptType.INDEPENDENT_REVIEW)
    expected_phase = QualificationPhase.POSTMERGE if record.command_id == "postmerge.exact-tree-proof" else QualificationPhase.PREMERGE
    if (record.execution_mode is not CommandExecutionMode.EXECUTOR_REQUIRED or record.argv
            or admission.scenario_id not in (record.scenario_ids or (record.command_id,))
            or admission.receipt_type is not expected_role or admission.qualification_phase is not expected_phase):
        _fail("external command mode, scenario, role or phase differs from frozen contract")
    inputs = execution.integrated_plan_input.inputs
    run = execution.qualification_run
    if (inputs.get("qualification_run_id"), inputs.get("qualification_run_nonce")) != (run.run_id, run.nonce):
        _fail("external compiled run differs from retained run")
    if (execution.producer_source_commit, execution.producer_source_tree) != (execution.candidate.source.commit, execution.candidate.source.tree):
        _fail("external producer source differs from candidate")
    if dict(admission.executor).get("host") != record.host.value:
        _fail("external executor host differs from frozen authority host")
    predecessors = _predecessors(admission)
    resolved = resolve_command_record(record, prerequisite_receipts=predecessors,
                                      qualification_run=run, profile=admission.profile)
    return validated, record, resolved


def _qualified_authority(admission):
    value = admission.qualified_premerge_authority
    if admission.command_id not in {"merge.prospective-tree", "postmerge.exact-tree-proof"}:
        if value is not None:
            _fail("review cannot assert a qualified merge authority")
        return None
    if (value is None and admission.command_id == "merge.prospective-tree"
            and admission.execution.candidate.subject_kind is CandidateSubjectKind.PROSPECTIVE_MERGE
            and admission.qualification_phase is QualificationPhase.PREMERGE
            and admission.receipt_type is ReceiptType.PROSPECTIVE_MERGE_TREE):
        # The initial prospective observation is an input to QUALIFIED_PREMERGE:
        # its receipt digest participates in the decision's source/DAG roots.
        # It cannot seal that future decision. This is observation authority,
        # not merge authorization: the final evaluator requires the actual seal
        # on MERGE/POSTMERGE node receipts, and postmerge admission below requires
        # both the full retained decision and its sealed prospective predecessor.
        return None
    if not isinstance(value, QualifiedPremergeAuthority):
        _fail("merge admission requires the complete qualified premerge authority")
    payload = to_primitive(value)
    digest = payload.pop("canonical_sha256")
    candidate = admission.execution.candidate
    prospective = replace(candidate, subject_kind=CandidateSubjectKind.PROSPECTIVE_MERGE,
                          accepted_postmerge_commit=None, accepted_postmerge_tree=None)
    if (value.schema_version != 2 or value.decision_status != "qualified-premerge"
            or value.qualification_run_id != admission.execution.qualification_run.run_id
            or value.qualification_run_nonce != admission.execution.qualification_run.nonce
            or value.prospective_candidate_identity_sha256 != candidate_identity_sha256(prospective)
            or digest != canonical_sha256(payload)
            or any(not is_sha256(payload[key]) for key in ("source_contract_sha256", "prerequisite_dag_sha256",
                "evidence_partial_order_sha256", "evidence_root_sha256", "command_plan_sha256"))
            or type(value.receipt_digests) is not tuple or not value.receipt_digests
            or any(type(row) is not tuple or len(row) != 2 or type(row[0]) is not str
                   or not is_sha256(row[1]) for row in value.receipt_digests)
            or value.receipt_digests != tuple(sorted(set(value.receipt_digests)))
            or len({row[0] for row in value.receipt_digests}) != len(value.receipt_digests)):
        _fail("qualified premerge authority differs from exact retained candidate/run/root")
    if admission.command_id == "merge.prospective-tree":
        from .command_compiler import command_plan_sha256
        if value.command_plan_sha256 != command_plan_sha256(admission.execution.integrated_plan_input.plan):
            _fail("qualified premerge authority belongs to another command plan")
        observed = {(item.receipt["receipt_id"], item.receipt["canonical_sha256"]) for item in admission.predecessor_inputs}
        if not observed.issubset(set(value.receipt_digests)):
            _fail("qualified premerge authority omitted the real review approval")
    else:
        if any(item.receipt["qualified_premerge_authority_sha256"] != digest for item in admission.predecessor_inputs):
            _fail("postmerge substituted the qualified prospective authority")
    return digest


def _owned_outputs(admission, record):
    expected = {*('artifact:' + name for name in record.generated_artifacts),
                *('log:' + name for name in record.generated_logs)}
    sources = admission.owner_artifacts
    observations = admission.retained_observations
    if (type(sources) is not tuple or any(not isinstance(s, OwnerArtifactSource) for s in sources)
            or len(sources) != len(expected) or {s.command_output for s in sources} != expected
            or len({s.artifact_id for s in sources}) != len(sources)
            or len({s.relative_path for s in sources}) != len(sources)):
        _fail("external owner artifacts differ from exact unique declaration closure")
    if (type(observations) is not tuple or any(type(row) is not tuple or len(row) != 2
            or type(row[0]) is not str or type(row[1]) is not bytes for row in observations)
            or len(observations) != len(expected) or {row[0] for row in observations} != expected):
        _fail("external retained observations differ from exact output declarations")
    retained = dict(observations)
    artifacts, documents, snapshots = [], {}, {}
    for source in sources:
        snapshot = _snapshot(admission.artifact_root, source.relative_path)
        payload, size, digest, _ = snapshot
        if payload != retained[source.command_output]:
            _fail("external physical output differs from independently retained observation")
        if source.media_type == "application/json":
            # Historical source-adjudication documents have one governed LF.
            raw = payload[:-1] if record.command_id == T10C_COMMAND and source.relative_path.endswith(
                ("SOURCE_DRIFT.json", "FINDING_ADJUDICATION.json")) and payload.endswith(b"\n") else payload
            documents[source.command_output] = decode_canonical_bytes(raw)
        elif record.command_id != T10C_COMMAND or not source.command_output.endswith("bundle.sha256"):
            _fail("external observation must be governed canonical JSON")
        artifacts.append(_artifact(admission, record, source, size=size, digest=digest))
        snapshots[source.relative_path] = snapshot
    if len({value[3][0][:2] for value in snapshots.values()}) != len(snapshots):
        _fail("external artifacts alias the same file identity")
    return artifacts, documents, snapshots


def _review_semantics(admission, artifacts, documents, interval):
    candidate = admission.execution.candidate
    authority = dict(review_commit=candidate.source.commit, review_tree=candidate.source.tree,
                     p0_count=0, p1_count=0, p2_count=0, p3_count=0, unresolved_blocking_count=0)
    constituents = []
    assignments = admission.reviewer_assignments
    expected_assignments = (tuple(INDEPENDENT_REVIEW_COMMAND_LENSES) if admission.command_id == "review.independent"
                            else (admission.command_id,))
    if (type(assignments) is not tuple
            or any(type(row) is not tuple or len(row) != 2 or type(row[1]) is not str or not row[1] for row in assignments)
            or tuple(row[0] for row in assignments) != expected_assignments):
        _fail("external reviewer assignments differ from exact retained commands")
    labels = dict(assignments)
    for artifact in artifacts:
        if artifact["kind"] != ArtifactKind.REVIEW_REPORT.value:
            continue
        report = documents[artifact["command_output"]]
        if admission.command_id == "review.independent":
            command = report.get("command_id")
            predecessors = {item.receipt["command_id"]: item for item in admission.predecessor_inputs}
            if command not in predecessors or report != predecessors[command].receipt:
                _fail("aggregate nested approval differs from independently replayed lens receipt")
            retained = getattr(predecessors[command].context, "external_admission", None)
            if (not isinstance(retained, ExternalAuthorityAdmission)
                    or retained.reviewer_assignments != ((command, labels[command]),)):
                _fail("aggregate reviewer label differs from actual retained lens assignment")
            counts = report["authority"]
            selector = command
        else:
            if (report.get("reviewer_id") != labels[admission.command_id]
                    or not interval.started_at_unix_ms <= report.get("observed_at_unix_ms", -1) <= interval.ended_at_unix_ms):
                _fail("review report differs from retained reviewer assignment or interval")
            counts = report if admission.command_id in INDEPENDENT_REVIEW_COMMAND_LENSES else report.get("authority", {})
            selector = INDEPENDENT_REVIEW_COMMAND_LENSES.get(admission.command_id)
        for key in ("p0_count", "p1_count", "p2_count", "p3_count", "unresolved_blocking_count"):
            value = counts.get(key)
            if type(value) is not int or value < 0:
                _fail("review report lacks closed severity counts")
            authority[key] += value
        if selector is not None:
            constituents.append(dict(selector_id=selector, status="passed", evidence_layer=EvidenceLayer.INDEPENDENT_REVIEW.value,
                candidate_identity_sha256=candidate_identity_sha256(candidate), artifact_ids=[artifact["artifact_id"]]))
    return authority, constituents


def _derive(admission):
    validated, record, resolved = _admit(admission)
    source_before = _source_fence(admission.execution)
    artifacts, documents, snapshots = _owned_outputs(admission, record)
    execution_artifacts = [a for a in artifacts if a["artifact_id"] == admission.execution_report_artifact_id]
    if len(execution_artifacts) != 1:
        _fail("external terminal report must select exactly one owned artifact")
    from .executor_receipt import _parse_execution_report
    result, _, interval = _parse_execution_report(documents[execution_artifacts[0]["command_output"]],
        receipt_type=admission.receipt_type, expected_qualification_run=admission.execution.qualification_run,
        expected_predecessor_observations_sha256=canonical_sha256(to_primitive(admission.execution.admitted_predecessors)))
    if any(item.receipt["execution_interval"]["ended_at_unix_ms"] > interval.started_at_unix_ms for item in admission.predecessor_inputs):
        _fail("external interval begins before an admitted predecessor ended")
    semantics = None
    if admission.receipt_type is ReceiptType.INDEPENDENT_REVIEW:
        authority, constituents = _review_semantics(admission, artifacts, documents, interval)
        if record.command_id == T10C_COMMAND:
            review = next(documents[a["command_output"]] for a in artifacts if a["kind"] == ArtifactKind.REVIEW_REPORT.value)
            if review.get("schema_version") == 2:
                from .t10c_closure_adapter import validate_t10c_closure
                # Lazy producer code is measured before its first use as well
                # as at the final fence; loading it never rebinds old snapshots.
                expanded_source = _source_fence(admission.execution)
                if any(expanded_source.get(key) != value for key, value in source_before.items()):
                    _fail("external source changed while loading T10C producer")
                source_before = expanded_source
                closure = admission.t10c_closure
                if (closure is None or closure.execution != admission.execution or closure.profile is not admission.profile
                        or closure.reviewer_id != dict(admission.reviewer_assignments)[T10C_COMMAND]
                        or (closure.started_at_unix_ms, closure.ended_at_unix_ms)
                        != (interval.started_at_unix_ms, interval.ended_at_unix_ms)
                        or any(admission.artifact_root / source.relative_path != closure.current_bundle_root / source.relative_path.split("/")[-1]
                               for source in admission.owner_artifacts)):
                    _fail("T10C closure differs from external admission")
                closed = validate_t10c_closure(closure)
                if review != closed.review or authority != closed.authority:
                    _fail("T10C v2 differs from freshly derived closure")
                semantics = dict(t10c_closure_admission=closure, t10c_closure_semantics=closed)
            elif review.get("schema_version") != 1 or admission.t10c_closure is not None:
                _fail("unknown T10C schema cannot fall back to historical evidence")
        elif admission.t10c_closure is not None:
            _fail("non-T10C command cannot carry closure authority")
    else:
        if admission.reviewer_assignments or admission.t10c_closure is not None:
            _fail("merge observation cannot carry reviewer or T10C authority")
        authority, constituents = None, []
        for document in documents.values():
            if isinstance(document, Mapping) and "observed_at_unix_ms" in document:
                observed = document["observed_at_unix_ms"]
                if type(observed) is not int or not interval.started_at_unix_ms <= observed <= interval.ended_at_unix_ms:
                    _fail("merge observation is outside retained terminal interval")
    authority_record = validated.command_records_by_id[record.command_id]
    request = dict(schema_version=4, candidate_identity=candidate_to_mapping(admission.execution.candidate),
        qualification_run=qualification_run_mapping(admission.execution.qualification_run),
        qualification_phase=admission.qualification_phase.value, evidence_layer=record.evidence_layer.value,
        receipt_type=admission.receipt_type.value, receipt_id=admission.receipt_id, requirement_id=admission.requirement_id,
        command_id=record.command_id, scenario_id=admission.scenario_id,
        command_plan_sha256=validated.command_plan_sha256,
        command_record_sha256=validated.command_record_sha256_by_id[record.command_id],
        runtime_resolution=to_primitive(resolved.runtime_resolution),
        qualified_premerge_authority_sha256=_qualified_authority(admission), attempt=admission.attempt,
        artifact_root_id=admission.artifact_root_id, execution_report_artifact_id=admission.execution_report_artifact_id,
        executor=dict(admission.executor), command_authority=dict(host=authority_record.host,
            execution_mode=authority_record.execution_mode, argv_sha256=canonical_sha256(list(resolved.record.argv)),
            working_directory_sha256=authority_record.working_directory_sha256, environment_sha256=authority_record.environment_sha256,
            generated_artifacts=list(authority_record.generated_artifacts), generated_logs=list(authority_record.generated_logs),
            prerequisite_receipts=to_primitive(admission.execution.admitted_predecessors)),
        artifacts=artifacts, constituents=constituents, skips=[], diagnostic=None, authority=authority)
    # Execute semantic validators now as well as in the internal receipt parser.
    from .gate_specific_artifact_validator import validate_gate_specific_artifacts
    kwargs = dict(admitted_command_record=resolved.record, admitted_command_inputs=admission.execution.integrated_plan_input.inputs,
        candidate=admission.execution.candidate, command_id=record.command_id, receipt_type=admission.receipt_type,
        artifacts=artifacts, artifact_root=admission.artifact_root, execution_report_artifact_id=admission.execution_report_artifact_id,
        result=result, stress=None, constituents=constituents, authority=authority, generated_artifacts=record.generated_artifacts,
        generated_logs=record.generated_logs, command_plan_sha256=request["command_plan_sha256"],
        command_record_sha256=request["command_record_sha256"], prerequisite_receipts=request["command_authority"]["prerequisite_receipts"])
    if semantics is not None:
        kwargs["admitted_external_semantics"] = semantics
    derived = validate_gate_specific_artifacts(**kwargs)
    if authority is None:
        request["authority"] = derived
    _fence(admission, snapshots, source_before)
    return request, resolved, semantics, snapshots, source_before


def _fence(admission, snapshots, source_before):
    for relative, before in snapshots.items():
        if _snapshot(admission.artifact_root, relative) != before:
            _fail("external artifact mutated at final fence")
    after = _source_fence(admission.execution)
    if any(after.get(key) != value for key, value in source_before.items()):
        _fail("external source mutated at final fence")
    _admit(admission)


def build_external_request(admission: ExternalAuthorityAdmission) -> dict[str, Any]:
    try:
        return _derive(admission)[0]
    except (OSError, RuntimeError, TypeError, KeyError, AttributeError, ValueError) as error:
        _fail("external physical admission rejected: " + str(error))


def _materialize(admission):
    from .executor_receipt import _validate_legacy_physical_evidence
    request, resolved, semantics, snapshots, source = _derive(admission)
    physical = dict(request, schema_version=2)
    physical.pop("runtime_resolution")
    kwargs = dict(artifact_root=admission.artifact_root, qualification_run_authority=admission.execution.qualification_run,
        admitted_command_record=resolved.record, admitted_command_inputs=admission.execution.integrated_plan_input.inputs)
    if semantics is not None:
        kwargs["admitted_external_semantics"] = semantics
    receipt, context = _validate_legacy_physical_evidence(physical, **kwargs)
    receipt = seal_receipt(dict(receipt, runtime_resolution=request["runtime_resolution"]))
    context = replace(context, external_admission=admission, expected_runtime_resolution=request["runtime_resolution"])
    _fence(admission, snapshots, source)
    return request, receipt, context, snapshots, source


def emit_external_receipt(request: object, *, admission: ExternalAuthorityAdmission) -> tuple[dict[str, Any], ReceiptValidationContext]:
    try:
        expected, receipt, context, _, _ = _materialize(admission)
        if canonical_bytes(request) != canonical_bytes(expected):
            _fail("external request differs from independently regenerated physical authority")
        validate_external_receipt(receipt, context=context)
        return receipt, context
    except (OSError, RuntimeError, TypeError, KeyError, AttributeError, ValueError) as error:
        _fail("external emission rejected: " + str(error))


def validate_external_receipt(receipt: object, *, context: ReceiptValidationContext) -> None:
    try:
        admission = getattr(context, "external_admission", None)
        _, fresh, expected_context, snapshots, source = _materialize(admission)
        if canonical_bytes(receipt) != canonical_bytes(fresh) or context != expected_context:
            _fail("external receipt/context differs from complete fresh admission")
        from .receipt_validator import _validate_physical_receipt
        issues = _validate_physical_receipt(receipt, context=replace(context, external_admission=None))
        if issues:
            _fail("external receipt physical replay failed: " + "; ".join(item.code for item in issues))
        _fence(admission, snapshots, source)
    except (OSError, RuntimeError, TypeError, KeyError, AttributeError, ValueError) as error:
        _fail("external replay rejected: " + str(error))
