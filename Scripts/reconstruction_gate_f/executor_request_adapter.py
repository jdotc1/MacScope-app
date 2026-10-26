"""Capture-backed receipt admission; never infer execution from a passed report.

The supplied admission is retained by the executing coordinator, not decoded
from the request. Python objects are not cryptographic same-user attestations.
Every consumer independently recompiles the full plan and rereads physical bytes.
"""
from __future__ import annotations

import base64
import hashlib
import os
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Mapping

from .artifact_validator import read_descriptor_relative_bytes
from .canonical_json import canonical_sha256, canonical_bytes, decode_canonical_bytes, to_primitive
from .command_capture import compare_bindings, parse_capture
from .command_catalog import CampaignProfile, campaign_profile_for_inputs
from .receipt_schema import seal_receipt
from .receipt_validator import QualificationRunAuthority
from .schema import ArtifactKind, QualificationPhase, ReceiptType, candidate_to_mapping

CAPTURE_OUTPUT = "log:gatef-command-capture"
CAPTURE_ARTIFACT_ID = "artifact-gatef-command-capture"
CAPTURE_EXECUTION_REPORT_OUTPUT = "artifact:gatef-capture-execution-report"
BOOTSTRAP_VERIFIER_COMMANDS = frozenset({"qualification.verify-bootstrap-fullsuite",
                                       "qualification.verify-bootstrap-products"})
NATIVE_PRODUCER_COMMANDS = frozenset({"native.normal", "native.asan", "native.ubsan", "native.golden"})
INSTALLED_PRODUCER_COMMANDS = frozenset({"signing.strict-release", "install.release-to-applications", "installed.source-equality",
    "installed.shell-smoke", "installed.xcuitest-preflight", "installed.emit-report"})
INSTALLED_PRODUCER_ROLES = {
    "signing.strict-release": ReceiptType.STRICT_SIGNING,
    "install.release-to-applications": ReceiptType.INSTALLED_SOURCE_EQUALITY,
    "installed.source-equality": ReceiptType.INSTALLED_SOURCE_EQUALITY,
    "installed.shell-smoke": ReceiptType.INSTALLED_LAUNCH_LOG,
    "installed.xcuitest-preflight": ReceiptType.COMMAND_EXECUTION,
    "installed.emit-report": ReceiptType.INSTALLED_WORKFLOW,
}
CAPTURE_DERIVED_REPORT_COMMANDS = frozenset({
    "source.create-sealed-export", "source.verify-sealed-export", "release.build",
    "xcode.focused.batch-scheduler", "xcode.focused.crash-resume",
    "xcode.focused.initial-transaction", "xcode.focused.installed-contracts",
    "xcode.focused.model-rounds", "xcode.focused.provider-cancellation-race",
    "xcode.focused.provider-pool", "xcode.focused.session-resolver",
    "xcode.focused.task10-projection", "xcode.focused.task10-state-machine",
    "xcode.focused.task8-bundle", "xcode.focused.task8-handler",
    "xcode.focused.task8-wire", "xcode.focused.workspace-database",
    "xcode.full-coretests", "xcode.smoke",
})


def capture_artifact_id(receipt_id: str) -> str:
    """Give each receipt a deterministic bounded ID in the global artifact set."""
    return CAPTURE_ARTIFACT_ID + "-" + hashlib.sha256(receipt_id.encode("utf-8")).hexdigest()


def capture_execution_report_artifact_id(receipt_id: str) -> str:
    return "artifact-gatef-execution-report-" + hashlib.sha256(receipt_id.encode("utf-8")).hexdigest()


def native_producer_policy(command_id, *, profile=CampaignProfile.EXISTING):
    return profile is CampaignProfile.BOOTSTRAP_VERIFIER and command_id in NATIVE_PRODUCER_COMMANDS


def installed_producer_policy(command_id, *, profile=CampaignProfile.EXISTING):
    return profile is CampaignProfile.BOOTSTRAP_VERIFIER and command_id in INSTALLED_PRODUCER_COMMANDS


def _admission_profile(admission):
    return campaign_profile_for_inputs(admission.capture.admission.integrated_plan_input.inputs)


def capture_derived_report_policy(command_id: str, *, profile=CampaignProfile.EXISTING) -> bool:
    """Closed applicability, never fallback from an absent native owner report."""
    if type(profile) is not CampaignProfile:
        _fail("capture policy requires a closed independently selected campaign profile")
    if (command_id not in CAPTURE_DERIVED_REPORT_COMMANDS
            and not native_producer_policy(command_id, profile=profile)
            and not installed_producer_policy(command_id, profile=profile)):
        return False
    from .command_catalog import command_templates
    template = next(item for item in command_templates(profile=profile) if item.command_id == command_id)
    if installed_producer_policy(command_id, profile=profile):
        from .command_catalog import installed_gate_output_slots
        expected = {
            "signing.strict-release": set(),
            "install.release-to-applications": {
                "@install_release_artifact_root@/GateFInstalledBegin.projection.json",
                "@install_release_artifact_root@/GateFInstalledBegin.source-equality.json",
            },
            "installed.source-equality": {"stdout-json:source-equality-report"},
            "installed.shell-smoke": {"@installed_shell_smoke_report@", "@installed_legacy_grid_report@"},
            "installed.xcuitest-preflight": {"stdout-json:xcuitest-preflight"},
            "installed.emit-report": {"@installed_report@", *("@" + name + "@" for _, name in installed_gate_output_slots())},
        }[command_id]
    elif command_id in NATIVE_PRODUCER_COMMANDS:
        expected = ({"stdout-path:MACSCOPE_NATIVE_GOLDEN_RESULT", "stdout-path:MACSCOPE_NATIVE_GOLDEN_STAGE_STAMP",
                     "stdout-path:MACSCOPE_NATIVE_GOLDEN_MATERIALIZATION"} if command_id == "native.golden"
                    else {"stdout-path:MACSCOPE_NATIVE_QUALIFICATION_REPORT"})
    elif command_id in {"source.create-sealed-export", "source.verify-sealed-export"}:
        expected = {"@source_export_root@/SOURCE_PROVENANCE.json", "@source_export_root@/SOURCE_FILES.json"}
    elif command_id == "release.build":
        expected = {"stdout-path:MACSCOPE_QUALIFICATION_RECEIPT",
                    "receipt-derived-path:DerivedData/Build/Products/Release/MacScope.app",
                    "receipt-derived-path:DerivedData/Build/Products/Release/MacScope.app/Contents/Resources/MacScopeBuildProvenance.json"}
    elif command_id == "xcode.full-coretests":
        expected = {"stdout-path:MACSCOPE_QUALIFICATION_RECEIPT", "stdout-path:MACSCOPE_COVERAGE_JSON",
                    "stdout-path:MACSCOPE_TEST_RESULTS"}
    elif command_id.startswith("xcode.focused."):
        expected = {"stdout-path:MACSCOPE_QUALIFICATION_RECEIPT", "stdout-path:MACSCOPE_TEST_RESULTS"}
    else:
        expected = {"stdout-path:MACSCOPE_QUALIFICATION_RECEIPT"}
    if set(template.generated_artifacts) != expected:
        _fail("capture-derived execution policy differs from frozen native output closure")
    return True


def capture_derived_report_receipt_type(command_id: str, *, profile=CampaignProfile.EXISTING) -> ReceiptType:
    """Semantic role required by the catalogue, not proved by a capture alone."""
    if not capture_derived_report_policy(command_id, profile=profile):
        _fail("command requires its native owner receipt policy")
    if installed_producer_policy(command_id, profile=profile):
        return INSTALLED_PRODUCER_ROLES[command_id]
    if command_id in {"source.create-sealed-export", "source.verify-sealed-export"}:
        return ReceiptType.ARTIFACT_MANIFEST
    if command_id == "release.build":
        return ReceiptType.RELEASE_BUILD
    if command_id == "xcode.smoke":
        return ReceiptType.COMMAND_EXECUTION
    if command_id in {"native.asan", "native.ubsan"}:
        return ReceiptType.NATIVE_SANITIZER
    return ReceiptType.TEST_RESULT


def _capture_execution_report(admission, admitted, document):
    profile = _admission_profile(admission)
    if not capture_derived_report_policy(admitted.record.command_id, profile=profile):
        _fail("command requires its native execution report")
    permitted_role = capture_derived_report_receipt_type(admitted.record.command_id, profile=profile)
    if (admission.receipt_type not in {ReceiptType.COMMAND_EXECUTION, permitted_role}
            or (admitted.record.command_id in NATIVE_PRODUCER_COMMANDS | INSTALLED_PRODUCER_COMMANDS
                and admission.receipt_type is not permitted_role)):
        _fail("capture-derived report proves command execution, not test or product qualification")
    artifact_id = capture_execution_report_artifact_id(admission.receipt_id)
    if admission.execution_report_artifact_id != artifact_id:
        _fail("capture-derived execution report ID differs from receipt identity")
    source = OwnerArtifactSource(artifact_id, "." + artifact_id + ".json", ArtifactKind.JSON,
                                 "application/json", CAPTURE_EXECUTION_REPORT_OUTPUT)
    run = admission.capture.admission.qualification_run
    report = {
        "schema_version": 2, "qualification_run": {"run_id": run.run_id, "nonce": run.nonce},
        "predecessor_observations_sha256": canonical_sha256([
            to_primitive(item) for item in admission.capture.admission.admitted_predecessors]),
        "started_at_unix_ms": document["intent"]["started_at_unix_ms"],
        "ended_at_unix_ms": document["terminal"]["ended_at_unix_ms"],
        "result": "passed", "exit_code": document["terminal"]["exit_code"], "stress": None,
    }
    return source, canonical_bytes(report)


def publish_capture_execution_report(admission: ExecutorReceiptAdmission) -> OwnerArtifactSource:
    """Explicit one-shot publication; repeat validation never creates evidence."""
    admitted, document, _, _, _, _ = _capture(admission)
    source, payload = _capture_execution_report(admission, admitted, document)
    root_fd = os.open(admission.artifact_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        descriptor = os.open(source.relative_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=root_fd)
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.fsync(root_fd)
    finally:
        os.close(root_fd)
    observed, _, _ = read_descriptor_relative_bytes(admission.artifact_root, source.relative_path)
    if observed != payload:
        _fail("capture-derived report changed during publication")
    return source


@dataclass(frozen=True)
class OwnerArtifactSource:
    artifact_id: str
    relative_path: str
    kind: ArtifactKind
    media_type: str
    command_output: str


@dataclass(frozen=True)
class ExecutorReceiptAdmission:
    capture: object
    artifact_root: Path
    receipt_id: str
    requirement_id: str
    qualification_phase: QualificationPhase
    receipt_type: ReceiptType
    artifact_root_id: str
    execution_report_artifact_id: str
    owner_artifacts: tuple[OwnerArtifactSource, ...]
    executor: Mapping[str, str]
    constituents: tuple[Mapping[str, Any], ...] = ()
    authority: Mapping[str, Any] | None = None
    attempt: int = 1
    qualified_premerge_authority_sha256: str | None = None
    # Retained local capture authority, never decoded from receipt/manifest JSON.
    installed_begin_admission: ExecutorReceiptAdmission | None = None


def _fail(message: str):
    from .executor_receipt import ReceiptEmissionError
    raise ReceiptEmissionError(message)


def _capture(admission: ExecutorReceiptAdmission):
    # Lazy import lets the receipt and execution owners develop independently.
    from .command_execution import ExecutionCapture, admit_command
    if not isinstance(admission, ExecutorReceiptAdmission):
        _fail("capture-backed emission requires independently supplied producer admission")
    capture = admission.capture
    if not isinstance(capture, ExecutionCapture):
        _fail("capture admission requires the retained execution capture")
    from .command_catalog import campaign_profile_for_inputs
    profile = campaign_profile_for_inputs(capture.admission.integrated_plan_input.inputs)
    admitted = admit_command(capture.admission, capture.command_id, capture.scenario_id, profile=profile)
    root = admission.artifact_root
    if not root.is_absolute() or root.resolve(strict=True) != root or root.is_symlink():
        _fail("capture artifact root must be canonical and ordinary")
    try:
        relative = capture.capture_path.relative_to(root).as_posix()
        payload, size, digest = read_descriptor_relative_bytes(root, relative)
        if digest != capture.capture_sha256:
            _fail("complete capture differs from producer-retained digest")
        envelope = parse_capture(payload)
        mismatch = compare_bindings(
            envelope, expected_record=admitted.record,
            expected_plan_sha256=admitted.validated_plan.command_plan_sha256,
            expected_run_id=capture.admission.qualification_run.run_id,
            expected_nonce=capture.admission.qualification_run.nonce,
            expected_source_commit=capture.admission.producer_source_commit,
            expected_source_tree=capture.admission.producer_source_tree,
            expected_capture_id=capture.capture_id,
            expected_scenario_id=capture.scenario_id,
            expected_effective_environment=capture.effective_environment,
            expected_prerequisite_receipts=capture.admission.admitted_predecessors,
            profile=profile,
        )
        if mismatch:
            _fail("capture differs from independently admitted context: " + ", ".join(mismatch))
    except (OSError, ValueError) as error:
        _fail(f"capture admission failed: {error}")
    document = envelope.to_mapping()
    terminal = document["terminal"]
    if terminal["termination_kind"] != "exited" or terminal["exit_code"] != 0:
        _fail("capture does not prove successful owned execution")
    if document["process_observation"]["state"] != "launched":
        _fail("capture does not contain a launched process observation")
    streams = {name: b"".join(
        base64.b64decode(frame["data_base64"], validate=True)
        for frame in document["output_frames"] if frame["stream"] == name
    ) for name in ("stdout", "stderr")}
    return admitted, document, streams, relative, size, digest


def _artifact(admission, record, source, *, size, digest):
    return {
        "schema_version": 1, "artifact_id": source.artifact_id,
        "candidate_identity_sha256": record.candidate_identity_sha256,
        "evidence_layer": record.evidence_layer.value,
        "root_id": admission.artifact_root_id,
        "relative_path": source.relative_path, "kind": source.kind.value,
        "media_type": source.media_type, "byte_count": size, "sha256": digest,
        "producer_receipt_id": admission.receipt_id, "command_id": record.command_id,
        "command_output": source.command_output,
    }


def build_executor_request(admission: ExecutorReceiptAdmission) -> dict[str, Any]:
    try:
        return _build_executor_request(admission)
    except (OSError, RuntimeError) as error:
        # Source-export, product-identity and xcresult readers expose bounded
        # RuntimeError subclasses. Public repeat validation must turn missing
        # or changed physical evidence into rejection issues, not escape.
        _fail("physical qualification admission failed: " + str(error))


def _build_executor_request(admission: ExecutorReceiptAdmission) -> dict[str, Any]:
    admitted, document, streams, relative, size, digest = _capture(admission)
    record = admitted.record
    resolved = admitted.resolved_command
    profile = _admission_profile(admission)
    authority = admitted.validated_plan.command_records_by_id[record.command_id]
    expected_outputs = {*("artifact:" + item for item in record.generated_artifacts),
                        *("log:" + item for item in record.generated_logs)}
    if {source.command_output for source in admission.owner_artifacts} != expected_outputs:
        _fail("owner artifacts do not preserve the exact original command output closure")
    native_semantics = None
    if native_producer_policy(record.command_id, profile=profile):
        from .native_receipt_adapter import validate_native_outputs
        native_semantics = validate_native_outputs(admission)
    installed_semantics = None
    if installed_producer_policy(record.command_id, profile=profile):
        from .installed_capture_adapter import validate_installed_outputs
        installed_semantics = validate_installed_outputs(admission)
    capture_id = capture_artifact_id(admission.receipt_id)
    if any(source.artifact_id in {CAPTURE_ARTIFACT_ID, capture_id} for source in admission.owner_artifacts):
        _fail("owner artifact collides with reserved capture artifact")
    artifacts = []
    directory_proofs = {}
    for source in admission.owner_artifacts:
        payload, count, sha = read_descriptor_relative_bytes(admission.artifact_root, source.relative_path)
        declaration = source.command_output.split(":", 1)[1]
        actual = admission.artifact_root / source.relative_path
        if native_semantics is not None and record.command_id == "native.golden" and source.command_output == "artifact:stdout-path:MACSCOPE_NATIVE_GOLDEN_MATERIALIZATION":
            from .native_receipt_adapter import golden_materialization_projection, golden_projection_relative_path
            if source.relative_path != golden_projection_relative_path(admission) or source.kind is not ArtifactKind.JSON:
                _fail("golden materialization is not its native-owned JSON projection")
            if payload != golden_materialization_projection(admission):
                _fail("golden materialization projection differs from physical evidence")
        elif record.command_id in BOOTSTRAP_VERIFIER_COMMANDS and source.kind in {ArtifactKind.APP_BUNDLE, ArtifactKind.XCRESULT}:
            from .bootstrap_verifier_adapter import validate_bootstrap_verifier_projection
            fresh_projection = validate_bootstrap_verifier_projection(admission, source, streams)
            if payload != fresh_projection:
                _fail("verifier projection differs from independently revalidated physical evidence")
        elif source.kind in {ArtifactKind.APP_BUNDLE, ArtifactKind.XCRESULT}:
            from .qualification_receipt_adapter import directory_projection, projection_relative_path
            if source.relative_path != projection_relative_path(admission, source) or source.media_type != "application/json":
                _fail("directory artifact is not its deterministic receipt-bound projection")
            fresh_projection = directory_projection(admission, source, streams)
            if payload != fresh_projection:
                _fail("directory projection differs from the original physical directory")
            directory_proofs[source.command_output] = decode_canonical_bytes(fresh_projection)
        elif declaration.startswith("receipt-derived-path:"):
            from .qualification_receipt_adapter import qualification_receipt_path
            expected_path = qualification_receipt_path(admission, streams).parent / declaration.removeprefix("receipt-derived-path:")
            if actual != expected_path:
                _fail("receipt-derived artifact differs from the admitted qualifier run")
        elif declaration.startswith("/"):
            if actual != Path(declaration):
                _fail("artifact path differs from compiled physical output")
        elif declaration.startswith("stdout-path:"):
            marker = declaration.removeprefix("stdout-path:") + "="
            lines = streams["stdout"].decode("utf-8", errors="strict").splitlines()
            values = [line[len(marker):] for line in lines if line.startswith(marker)]
            if values != [str(actual)]:
                _fail("captured stdout does not contain one exact owner path marker")
        elif declaration.startswith("stdout-json:"):
            if payload != streams["stdout"]:
                _fail("stdout JSON artifact is not the exact captured stdout")
        elif declaration.startswith("executor-captured:"):
            if payload != streams["stdout"] + streams["stderr"]:
                _fail("owner log differs from exact captured stream bytes")
        else:
            _fail("unsupported owner output declaration; no guessed artifact path")
        artifact = _artifact(admission, record, source, size=count, digest=sha)
        if native_semantics is not None:
            from .native_receipt_adapter import native_semantic_kind
            artifact["kind"] = native_semantic_kind(record.command_id, source).value
        if installed_semantics is not None:
            from .installed_capture_adapter import installed_semantic_kind
            artifact["kind"] = installed_semantic_kind(record.command_id, source,
                inputs=admission.capture.admission.integrated_plan_input.inputs).value
        artifacts.append(artifact)
    capture_source = OwnerArtifactSource(capture_id, relative, ArtifactKind.JSON, "application/json", CAPTURE_OUTPUT)
    artifacts.append(_artifact(admission, record, capture_source, size=size, digest=digest))
    if capture_derived_report_policy(record.command_id, profile=profile):
        source, expected_report = _capture_execution_report(admission, admitted, document)
        if any(item["artifact_id"] == source.artifact_id for item in artifacts):
            _fail("owner artifact collides with reserved capture execution report")
        report, count, report_digest = read_descriptor_relative_bytes(admission.artifact_root, source.relative_path)
        if report != expected_report:
            _fail("execution report differs from independently admitted capture")
        artifacts.append(_artifact(admission, record, source, size=count, digest=report_digest))
    run = admission.capture.admission.qualification_run
    execution_authority = (dict(admission.authority) if admission.authority is not None else None)
    if installed_semantics is not None:
        execution_authority = installed_semantics["authority"]
    elif capture_derived_report_policy(record.command_id, profile=profile) and admission.receipt_type is ReceiptType.COMMAND_EXECUTION:
        if record.command_id == "xcode.smoke":
            from .qualification_receipt_adapter import semantic_qualification
            semantic_qualification(admission, admitted, streams, directory_proofs)
        execution_authority = {"run_id": run.run_id,
                               "argv_sha256": canonical_sha256(list(resolved.record.argv)),
                               "exit_code": document["terminal"]["exit_code"]}
    elif native_semantics is not None:
        execution_authority = native_semantics["authority"]
    elif capture_derived_report_policy(record.command_id, profile=profile):
        if admission.receipt_type is ReceiptType.ARTIFACT_MANIFEST:
            from .qualification_artifact_validator import validate_source_export
            inputs = admission.capture.admission.integrated_plan_input.inputs
            validate_source_export(admission.capture.admission.candidate, Path(inputs["source_export_root"]),
                                   inputs["integration_ref"])
            execution_authority = _manifest_authority(artifacts)
        else:
            from .qualification_receipt_adapter import semantic_qualification
            observations, selected_scope = semantic_qualification(admission, admitted, streams, directory_proofs)
            if admission.receipt_type is ReceiptType.RELEASE_BUILD:
                execution_authority = observations
            else:
                # These are declared semantic scenario obligations, not an
                # invented expected catalogue of source-discovered test cases.
                count = len(record.scenario_ids or (record.command_id,))
                execution_authority = {"selector_catalog_sha256": admission.capture.admission.candidate.selector_catalog_sha256,
                    "expected_selector_count": count, "executed_selector_count": count,
                    "passed_selector_count": count, "failed_selector_count": 0, "skipped_selector_count": 0}
    constituents = list(admission.constituents)
    if installed_semantics is not None:
        constituents = installed_semantics["constituents"]
    if native_semantics is not None:
        constituents = native_semantics["constituents"]
    if record.command_id in BOOTSTRAP_VERIFIER_COMMANDS:
        from .bootstrap_verifier_adapter import validate_bootstrap_verifier_outputs
        execution_authority, derived_constituents = validate_bootstrap_verifier_outputs(admission, admitted, streams)
        constituents = list(derived_constituents)
    if (capture_derived_report_policy(record.command_id, profile=profile) and admission.receipt_type is ReceiptType.TEST_RESULT
            and native_semantics is None):
        owner_ids = sorted(item["artifact_id"] for item in artifacts if item["command_output"] != CAPTURE_OUTPUT)
        constituents = [{"selector_id": selector, "status": "passed", "evidence_layer": record.evidence_layer.value,
                         "candidate_identity_sha256": record.candidate_identity_sha256, "artifact_ids": owner_ids}
                        for selector in record.scenario_ids or (record.command_id,)]
    return {
        "schema_version": 4,
        "candidate_identity": candidate_to_mapping(admission.capture.admission.candidate),
        "qualification_run": {"run_id": run.run_id, "nonce": run.nonce},
        "qualification_phase": admission.qualification_phase.value,
        "evidence_layer": record.evidence_layer.value, "receipt_type": admission.receipt_type.value,
        "receipt_id": admission.receipt_id, "requirement_id": admission.requirement_id,
        "command_id": record.command_id, "scenario_id": admission.capture.scenario_id,
        "command_plan_sha256": admitted.validated_plan.command_plan_sha256,
        "command_record_sha256": admitted.validated_plan.command_record_sha256_by_id[record.command_id],
        "runtime_resolution": to_primitive(resolved.runtime_resolution),
        "qualified_premerge_authority_sha256": admission.qualified_premerge_authority_sha256,
        "attempt": admission.attempt, "artifact_root_id": admission.artifact_root_id,
        "execution_report_artifact_id": admission.execution_report_artifact_id,
        "executor": dict(admission.executor),
        "command_authority": {
            "host": authority.host, "execution_mode": authority.execution_mode,
            "argv_sha256": canonical_sha256(list(resolved.record.argv)),
            "working_directory_sha256": authority.working_directory_sha256,
            "environment_sha256": authority.environment_sha256,
            "generated_artifacts": list(authority.generated_artifacts),
            "generated_logs": list(authority.generated_logs),
            "prerequisite_receipts": [vars(item) for item in admission.capture.admission.admitted_predecessors],
        },
        "artifacts": artifacts, "constituents": constituents,
        "skips": [], "diagnostic": None,
        "authority": execution_authority,
    }


def _manifest_authority(artifacts):
    return {"artifact_count": len(artifacts),
            "artifact_manifest_sha256": canonical_sha256(sorted(artifacts, key=lambda item: item["artifact_id"]))}


def _physical_request(expected):
    physical = dict(expected, schema_version=2)
    physical.pop("runtime_resolution")
    physical["artifacts"] = [item for item in expected["artifacts"] if item["command_output"] != CAPTURE_OUTPUT]
    if expected["receipt_type"] == ReceiptType.ARTIFACT_MANIFEST.value:
        physical["authority"] = _manifest_authority(physical["artifacts"])
    return physical


def _captured_receipt(fresh, expected):
    authority = (expected["authority"] if expected["receipt_type"] == ReceiptType.ARTIFACT_MANIFEST.value
                 else fresh["authority"])
    return seal_receipt(dict(fresh, artifacts=expected["artifacts"], authority=authority,
                            runtime_resolution=expected["runtime_resolution"]))


def _admitted_capture_semantics(admission, admitted, streams, physical):
    semantics = {"authority": physical["authority"], "constituents": physical["constituents"]}
    if admitted.record.command_id in BOOTSTRAP_VERIFIER_COMMANDS:
        # Local physical-validation context only; never serialized in a receipt.
        semantics.update(bootstrap_verifier_admission=admission,
                         bootstrap_verifier_admitted_command=admitted,
                         bootstrap_verifier_streams=streams)
    if native_producer_policy(admitted.record.command_id, profile=_admission_profile(admission)):
        semantics.update(native_producer_admission=admission,
                         native_producer_admitted_command=admitted)
    if installed_producer_policy(admitted.record.command_id, profile=_admission_profile(admission)):
        semantics.update(installed_producer_admission=admission,
                         installed_producer_admitted_command=admitted)
    return semantics


def emit_captured_receipt(request, *, artifact_root, qualification_run_authority, admission):
    from .executor_receipt import _validate_legacy_physical_evidence
    if not isinstance(admission, ExecutorReceiptAdmission):
        _fail("capture-backed emission requires independently supplied producer admission")
    if artifact_root != admission.artifact_root or qualification_run_authority != admission.capture.admission.qualification_run:
        _fail("receipt root/run differs from independent admission")
    expected = build_executor_request(admission)
    if request != expected:
        _fail("request differs from independently admitted capture and physical outputs")
    physical = _physical_request(expected)
    admitted, document, streams, _, _, _ = _capture(admission)
    receipt, context = _validate_legacy_physical_evidence(
        physical, artifact_root=artifact_root, qualification_run_authority=qualification_run_authority,
        admitted_command_record=admitted.resolved_command.record,
        admitted_command_inputs=admission.capture.admission.integrated_plan_input.inputs,
        capture_derived_execution=capture_derived_report_policy(admitted.record.command_id, profile=_admission_profile(admission)),
        admitted_capture_semantics=_admitted_capture_semantics(admission, admitted, streams, physical),
    )
    interval = receipt["execution_interval"]
    if not (document["intent"]["started_at_unix_ms"] <= interval["started_at_unix_ms"]
            <= interval["ended_at_unix_ms"] <= document["terminal"]["ended_at_unix_ms"]):
        _fail("physical owner report interval is outside captured execution")
    from .executor_receipt import _parse_artifact_expectations
    context = replace(context, capture_admission=admission,
                      expected_runtime_resolution=expected["runtime_resolution"],
                      expected_artifacts=_parse_artifact_expectations(expected["artifacts"]))
    receipt = _captured_receipt(receipt, expected)
    from .receipt_validator import validate_receipt
    issues = validate_receipt(receipt, context=context)
    if issues:
        _fail("; ".join(f"{issue.code}: {issue.message}" for issue in issues))
    return receipt, context


def validate_capture_receipt(receipt, *, context):
    from .executor_receipt import _validate_legacy_physical_evidence
    expected = build_executor_request(context.capture_admission)
    for key in ("candidate_identity", "qualification_run", "command_id", "scenario_id",
                "command_plan_sha256", "command_record_sha256", "runtime_resolution", "command_authority", "artifacts"):
        if receipt.get(key) != expected[key]:
            _fail("receipt differs from fresh independent capture admission: " + key)
    physical = _physical_request(expected)
    admitted, document, streams, _, _, _ = _capture(context.capture_admission)
    fresh, _ = _validate_legacy_physical_evidence(
        physical, artifact_root=context.capture_admission.artifact_root,
        qualification_run_authority=context.expected_qualification_run,
        admitted_command_record=admitted.resolved_command.record,
        admitted_command_inputs=context.capture_admission.capture.admission.integrated_plan_input.inputs,
        capture_derived_execution=capture_derived_report_policy(admitted.record.command_id, profile=_admission_profile(context.capture_admission)),
        admitted_capture_semantics=_admitted_capture_semantics(context.capture_admission, admitted, streams, physical),
    )
    interval = fresh["execution_interval"]
    if not (document["intent"]["started_at_unix_ms"] <= interval["started_at_unix_ms"]
            <= interval["ended_at_unix_ms"] <= document["terminal"]["ended_at_unix_ms"]):
        _fail("physical owner report interval is outside captured execution")
    if receipt != _captured_receipt(fresh, expected):
        _fail("receipt differs from independently revalidated physical owner report")


def execute_and_emit(execution_admission, *, command_id, scenario_id, capture_root,
                     cancellation, receipt_admission_factory):
    """Governed live orchestration path, distinct from request-only ingestion.

    The factory supplies owner artifact locations/receipt metadata after execution;
    it cannot substitute another capture or invent success/report facts.
    """
    from .command_execution import execute_admitted_command
    capture = execute_admitted_command(
        execution_admission, command_id=command_id, scenario_id=scenario_id,
        capture_root=capture_root, cancellation=cancellation,
    )
    admission = receipt_admission_factory(capture)
    if not isinstance(admission, ExecutorReceiptAdmission) or admission.capture is not capture:
        _fail("receipt factory replaced the producer-owned capture")
    request = build_executor_request(admission)
    return emit_captured_receipt(request, artifact_root=admission.artifact_root,
                                 qualification_run_authority=execution_admission.qualification_run,
                                 admission=admission)
