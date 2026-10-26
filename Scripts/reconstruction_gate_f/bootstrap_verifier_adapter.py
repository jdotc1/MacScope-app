"""Narrow physical replay for the two ordinary bootstrap verifier commands."""
from __future__ import annotations

import base64
from pathlib import Path
from typing import Mapping

from . import bootstrap_verifier as verifier
from .artifact_validator import read_descriptor_relative_bytes
from .bootstrap_qualification import BootstrapSourceAuthority
from .canonical_json import canonical_bytes, canonical_sha256, decode_canonical_bytes, to_primitive
from .command_capture import parse_capture
from .command_catalog import CampaignProfile, campaign_profile_for_inputs, command_templates
from .command_execution import AdmittedCommand
from .executor_request_adapter import ExecutorReceiptAdmission, OwnerArtifactSource
from .qualification_receipt_adapter import captured_path
from .schema import ArtifactKind, ReceiptType, candidate_to_mapping


def _validated(admission, admitted, streams):
    if not isinstance(admission, ExecutorReceiptAdmission) or not isinstance(admitted, AdmittedCommand):
        raise ValueError("independently admitted verifier command required")
    record = admitted.resolved_command.record
    kinds = [kind for kind, command in verifier.COMMANDS.items() if command == record.command_id]
    if len(kinds) != 1:
        raise ValueError("command is not a fixed bootstrap verifier")
    kind = kinds[0]
    context = admission.capture.admission
    inputs = context.integrated_plan_input.inputs
    if campaign_profile_for_inputs(inputs) is not CampaignProfile.BOOTSTRAP_VERIFIER:
        raise ValueError("bootstrap verifier requires independently admitted profile")
    template = next(item for item in command_templates(profile=CampaignProfile.BOOTSTRAP_VERIFIER)
                    if item.command_id == record.command_id)
    predecessor = canonical_sha256([to_primitive(item) for item in context.admitted_predecessors])
    substitutions = dict(inputs)
    substitutions["bootstrap_" + kind + "_predecessor_observations_sha256"] = predecessor
    expected_argv = tuple(substitutions[token[1:-1]] if token.startswith("@") and token.endswith("@")
                          else token for token in template.argv)
    if record.argv != expected_argv or (record.generated_artifacts, record.generated_logs) != (
            template.generated_artifacts, template.generated_logs):
        raise ValueError("verifier argv/output closure differs from frozen command")
    expected_type = ReceiptType.TEST_RESULT if kind == "fullsuite" else ReceiptType.RELEASE_BUILD
    if admission.receipt_type is not expected_type:
        raise ValueError("verifier receipt has the wrong ordinary semantic role")
    root = admission.artifact_root
    verifier._directory(root)
    output_root = Path(inputs["bootstrap_" + kind + "_artifact_root"])
    verifier._directory(output_root)
    if root not in output_root.parents:
        raise ValueError("verifier output root must be strictly contained in campaign root")
    original_root = Path(inputs["bootstrap_artifact_root"])
    other_root = Path(inputs["bootstrap_" + ("products" if kind == "fullsuite" else "fullsuite") + "_artifact_root"])
    if (not other_root.is_absolute() or other_root.resolve() != other_root or root not in other_root.parents
            or verifier._overlap(output_root, original_root)
            or verifier._overlap(output_root, other_root)
            or verifier._overlap(output_root, Path(inputs["repository_root"]))):
        raise ValueError("verifier roots overlap original evidence or one another")
    candidate_path = Path(inputs["candidate_identity_path"])
    candidate_payload = read_descriptor_relative_bytes(candidate_path.parent, candidate_path.name,
                                                       maximum_bytes=verifier.MAX_REPORT_BYTES)[0]
    if decode_canonical_bytes(candidate_payload) != candidate_to_mapping(context.candidate):
        raise ValueError("compiled candidate file differs from candidate authority")
    contract = verifier.output_contract(kind)
    declarations = {"artifact:stdout-path:" + marker for _, marker in contract}
    log_output = "log:" + template.generated_logs[0]
    sources = admission.owner_artifacts
    if (len(sources) != 4 or {s.command_output for s in sources} != declarations | {log_output}
            or len({s.artifact_id for s in sources}) != 4
            or len({s.relative_path for s in sources}) != 4):
        raise ValueError("verifier requires exact unique command-owned files and IDs")
    inodes = set()
    documents = []
    references = []
    for index, (name, marker) in enumerate(contract):
        source = next(s for s in sources if s.command_output == "artifact:stdout-path:" + marker)
        expected_kind = ArtifactKind.JSON if index < 2 else (ArtifactKind.XCRESULT if kind == "fullsuite" else ArtifactKind.APP_BUNDLE)
        expected_relative = (output_root / name).relative_to(root).as_posix()
        if source.relative_path != expected_relative or source.kind is not expected_kind or source.media_type != "application/json":
            raise ValueError("verifier file has wrong kind/path/media type")
        if captured_path(streams, marker) != output_root / name:
            raise ValueError("captured verifier marker differs from owned output")
        payload, reference = verifier._owned_bytes(root, source.relative_path)
        documents.append(decode_canonical_bytes(payload))
        # Owner records are campaign-relative, while semantic projection
        # references are relative to this command's independent output root.
        references.append({**reference, "relative_path": name})
        metadata = (root / source.relative_path).lstat()
        inodes.add((metadata.st_dev, metadata.st_ino))
        if index == 0 and source.artifact_id != admission.execution_report_artifact_id:
            raise ValueError("execution report owner ID differs from admission")
    log_source = next(s for s in sources if s.command_output == log_output)
    if log_source.kind is not ArtifactKind.LAUNCH_LOG:
        raise ValueError("verifier captured output must be an ordinary log")
    log, _ = verifier._owned_bytes(root, log_source.relative_path)
    if log != streams["stdout"] + streams["stderr"]:
        raise ValueError("verifier log differs from captured streams")
    metadata = (root / log_source.relative_path).lstat()
    inodes.add((metadata.st_dev, metadata.st_ino))
    if len(inodes) != 4:
        raise ValueError("verifier output inode aliases another owned file")
    execution, semantic, projection = documents
    from .executor_receipt import _parse_execution_report
    status, _, interval = _parse_execution_report(execution, receipt_type=expected_type,
        expected_qualification_run=context.qualification_run,
        expected_predecessor_observations_sha256=predecessor)
    if type(execution["schema_version"]) is not int or status.value != "passed" or type(execution["exit_code"]) is not int:
        raise ValueError("verifier report does not prove passed fresh verification")
    capture_payload, _, digest = read_descriptor_relative_bytes(root,
        admission.capture.capture_path.relative_to(root).as_posix())
    if digest != admission.capture.capture_sha256:
        raise ValueError("verifier capture changed")
    captured = parse_capture(capture_payload).to_mapping()
    captured_streams = {name: b"".join(base64.b64decode(frame["data_base64"], validate=True)
        for frame in captured["output_frames"] if frame["stream"] == name) for name in ("stdout", "stderr")}
    if (captured["intent"]["command_id"] != record.command_id
            or captured["intent"]["argv"] != list(record.argv)
            or captured["intent"]["candidate_identity_sha256"] != record.candidate_identity_sha256
            or (captured["intent"]["run_id"], captured["intent"]["nonce"]) != (
                context.qualification_run.run_id, context.qualification_run.nonce)
            or (captured["intent"]["producer_source_commit"], captured["intent"]["producer_source_tree"]) != (
                context.candidate.source.commit, context.candidate.source.tree)
            or captured["intent"]["prerequisite_receipts"] != sorted([
                [p.command_id, p.canonical_sha256] for p in context.admitted_predecessors])
            or dict(streams) != captured_streams
            or captured["process_observation"]["state"] != "launched"
            or captured["terminal"]["termination_kind"] != "exited"
            or captured["terminal"]["exit_code"] != 0
            or not (captured["intent"]["started_at_unix_ms"] <= interval.started_at_unix_ms
                    <= interval.ended_at_unix_ms <= captured["terminal"]["ended_at_unix_ms"])):
        raise ValueError("fresh verification interval is outside captured command execution")
    source = BootstrapSourceAuthority(Path(inputs["repository_root"]), inputs["integration_ref"],
                                      context.candidate.source.commit, context.candidate.source.tree)
    proof, extra, observed_projection = verifier.revalidated_evidence(kind=kind, candidate=context.candidate,
        expected_source=source, bootstrap_root=original_root,
        admission_relative_path=Path(inputs["bootstrap_admission_path"]).relative_to(original_root).as_posix(),
        qualification_run=context.qualification_run)
    fresh_interval = {"started_at_unix_ms": interval.started_at_unix_ms,
                      "ended_at_unix_ms": interval.ended_at_unix_ms}
    if proof["original_execution_interval"]["ended_at_unix_ms"] > interval.started_at_unix_ms:
        raise ValueError("old qualification interval substituted into fresh verification")
    expected_semantic = verifier.semantic_document(kind=kind, candidate=context.candidate,
        qualification_run=context.qualification_run, predecessor=predecessor, proof=proof, extra=extra,
        interval=fresh_interval, projection_reference=references[2])
    # Canonical bytes also distinguish booleans from integer fields which Python
    # dict equality would otherwise consider equal.
    if canonical_bytes(semantic) != canonical_bytes(expected_semantic):
        raise ValueError("semantic report differs from fresh physical bootstrap authority")
    if canonical_bytes(projection) != canonical_bytes(observed_projection):
        raise ValueError("projection differs from original physical directory")
    return kind, canonical_bytes(observed_projection)


def validate_bootstrap_verifier_outputs(admission: ExecutorReceiptAdmission,
    admitted: AdmittedCommand, streams: Mapping[str, bytes]) -> tuple[dict, tuple[dict, ...]]:
    kind, _ = _validated(admission, admitted, streams)
    candidate = admission.capture.admission.candidate
    if kind == "products":
        return {"bundle_sha256": candidate.application.bundle_sha256,
                "closed_tree_sha256": candidate.application.closed_tree_sha256,
                "executable_sha256": candidate.application.executable_sha256}, ()
    record = admitted.record
    selectors = record.scenario_ids or (record.command_id,)
    count = len(selectors)
    authority = {"selector_catalog_sha256": candidate.selector_catalog_sha256,
                 "expected_selector_count": count, "executed_selector_count": count,
                 "passed_selector_count": count, "failed_selector_count": 0, "skipped_selector_count": 0}
    constituents = tuple({"selector_id": selector, "status": "passed", "evidence_layer": record.evidence_layer.value,
                          "candidate_identity_sha256": record.candidate_identity_sha256,
                          "artifact_ids": sorted(s.artifact_id for s in admission.owner_artifacts)} for selector in selectors)
    return authority, constituents


def validate_bootstrap_verifier_projection(admission: ExecutorReceiptAdmission,
    source: OwnerArtifactSource, streams: Mapping[str, bytes]) -> bytes:
    from .executor_request_adapter import _capture
    admitted, _, observed_streams, _, _, _ = _capture(admission)
    if dict(streams) != observed_streams:
        raise ValueError("supplied verifier streams differ from retained capture")
    kind, projection = _validated(admission, admitted, streams)
    marker = verifier.output_contract(kind)[2][1]
    if source not in admission.owner_artifacts or source.command_output != "artifact:stdout-path:" + marker:
        raise ValueError("source is not this verifier's projection")
    return projection
