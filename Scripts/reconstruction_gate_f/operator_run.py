"""Restartable local Gate F orchestration, not same-user authentication.

The closed manifest is explicit operator configuration. It cannot override the
catalogue, command vectors, static plan hashes, or predecessor observations.
Changing it invalidates all completed records. A user able to replace this
Python source and every local record remains outside this integrity boundary.
"""
from __future__ import annotations

import base64
import os
from pathlib import Path
from dataclasses import dataclass, replace

from .artifact_validator import (read_descriptor_relative_bytes,
                                 safe_relative_artifact_path,
                                 _open_root_without_symlinks)
from .canonical_json import canonical_bytes, canonical_sha256, decode_canonical_bytes, to_primitive
from .command_capture import parse_capture
from .command_catalog import CampaignProfile, campaign_profile_for_inputs, command_templates
from .command_compiler import compile_command_plan, EXTERNAL_PREREQUISITE_IDS
from .command_execution import (ExecutionAdmission, ExecutionCapture, admit_command,
                                execute_admitted_command)
from .executor_request_adapter import (ExecutorReceiptAdmission, OwnerArtifactSource,
                                       build_executor_request, emit_captured_receipt)
from .prerequisite_dag import (LaneCIntegratedCommandPlanInput,
                               validate_integrated_lane_c_command_plan)
from .receipt_validator import (CommandPrerequisiteExpectation, QualificationRunAuthority,
                                validate_qualification_run_authority)
from .scenario_compiler import compile_scenario_catalog
from .schema import (ArtifactKind, QualificationPhase, ReceiptType, STABLE_ID_RE,
                     CandidateSubjectKind, candidate_to_mapping, parse_candidate_identity)

MAX_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_COMPLETION_BYTES = 16 * 1024 * 1024
MAX_CAPTURE_BYTES = 64 * 1024 * 1024
MANIFEST_FIELDS = frozenset({"schema_version", "candidate_identity", "repository_root",
                             "command_inputs", "qualification_run", "commands"})
COMMAND_FIELDS = frozenset({"receipt_id", "requirement_id", "qualification_phase",
                            "receipt_type", "artifact_root_id", "execution_report_artifact_id",
                            "owner_artifacts", "executor", "constituents", "authority",
                            "qualified_premerge_authority_sha256"})
ARTIFACT_FIELDS = frozenset({"artifact_id", "relative_path", "kind", "media_type", "command_output"})
COMPLETION_FIELDS = frozenset({"schema_version", "manifest_sha256", "capture_path", "receipt"})
EXTERNAL_COMPLETION_FIELDS = frozenset({"schema_version", "manifest_sha256", "command_id", "receipt"})
PROJECTED_COMPLETION_FIELDS = COMPLETION_FIELDS | {"owner_artifacts"}
VERIFIER_COMMAND_IDS = frozenset({"qualification.verify-bootstrap-fullsuite",
                                  "qualification.verify-bootstrap-products"})
CAPTURED_OUTPUT_LOCATOR = "@captured-output@"
RELEASE_APP_OUTPUT = "artifact:receipt-derived-path:DerivedData/Build/Products/Release/MacScope.app"
RELEASE_PROVENANCE_SUFFIX = "Contents/Resources/MacScopeBuildProvenance.json"
RELEASE_PROVENANCE_OUTPUT = RELEASE_APP_OUTPUT + "/" + RELEASE_PROVENANCE_SUFFIX


def _receipt_derived_kind(command_id, command_output):
    if command_id != "release.build":
        raise OperatorError("receipt-derived output requires the frozen Release command")
    kinds = {RELEASE_APP_OUTPUT: ArtifactKind.APP_BUNDLE,
             RELEASE_PROVENANCE_OUTPUT: ArtifactKind.JSON}
    if command_output not in kinds:
        raise OperatorError("unknown receipt-derived output suffix")
    return kinds[command_output]


class OperatorError(ValueError):
    pass


def _check_external_qualified_seal(command_id, configured_seal, request, admission):
    """Bind metadata only after the full external request has been validated."""
    from .gate_evaluator import QualifiedPremergeAuthority
    observed_seal = request["qualified_premerge_authority_sha256"]
    if observed_seal == configured_seal:
        return
    # A qualified decision includes predecessor receipts sealed against the
    # immutable run manifest. Its seal therefore cannot be configured before
    # those receipts exist. Only the two governed merge commands may bind this
    # late value, and only from the typed authority build_external_request has
    # already validated. An explicit frozen seal is never a wildcard.
    authority = admission.qualified_premerge_authority
    if (configured_seal is None and observed_seal is not None
            and command_id in {"merge.prospective-tree", "postmerge.exact-tree-proof"}
            and isinstance(authority, QualifiedPremergeAuthority)
            and observed_seal == authority.canonical_sha256):
        return
    raise OperatorError("external qualified authority differs from operator metadata")


def _closed(value, fields, label):
    if type(value) is not dict or set(value) != fields:
        raise OperatorError(label + " must have the exact closed fields")
    return value


def _id(value):
    if type(value) is not str or not STABLE_ID_RE.fullmatch(value):
        raise OperatorError("invalid stable identifier")
    return value


def _read(root, relative, maximum):
    if not safe_relative_artifact_path(relative):
        raise OperatorError("unsafe run-relative path")
    payload, _, _ = read_descriptor_relative_bytes(root, relative, maximum_bytes=maximum)
    return payload


def _publish(root, relative, payload):
    """Create only, through a no-follow parent chain; failed bytes are retained."""
    if not safe_relative_artifact_path(relative):
        raise OperatorError("unsafe publication path")
    relative = Path(relative)
    descriptors = []
    fd = None
    try:
        parent = _open_root_without_symlinks(root / relative.parent, descriptors)
        fd = os.open(relative.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=parent)
        view = memoryview(payload)
        while view:
            count = os.write(fd, view)
            if count <= 0:
                raise OperatorError("publication made no progress")
            view = view[count:]
        os.fsync(fd)
        os.fsync(parent)
    finally:
        if fd is not None:
            os.close(fd)
        for descriptor in reversed(descriptors):
            os.close(descriptor)
    if _read(root, str(relative), max(len(payload), 1)) != payload:
        raise OperatorError("published bytes changed")


def _metadata(value):
    value = _closed(value, COMMAND_FIELDS, "command metadata")
    for key in ("receipt_id", "requirement_id", "artifact_root_id", "execution_report_artifact_id"):
        _id(value[key])
    QualificationPhase(value["qualification_phase"])
    ReceiptType(value["receipt_type"])
    if type(value["owner_artifacts"]) is not list or type(value["constituents"]) is not list:
        raise OperatorError("artifact and constituent metadata must be lists")
    _closed(value["executor"], {"executor_id", "host", "platform", "architecture", "os_version"}, "executor")
    if any(type(item) is not str or not item for item in value["executor"].values()):
        raise OperatorError("executor fields must be nonempty text")
    paths, ids, outputs = set(), set(), set()
    for artifact in value["owner_artifacts"]:
        _closed(artifact, ARTIFACT_FIELDS, "owner artifact")
        _id(artifact["artifact_id"])
        ArtifactKind(artifact["kind"])
        if not safe_relative_artifact_path(artifact["relative_path"]):
            raise OperatorError("unsafe owner artifact path")
        for key, seen in (("relative_path", paths), ("artifact_id", ids), ("command_output", outputs)):
            item = artifact[key]
            repeated_locator = key == "relative_path" and item == CAPTURED_OUTPUT_LOCATOR
            if type(item) is not str or not item or (item in seen and not repeated_locator):
                raise OperatorError("duplicate or invalid owner artifact " + key)
            seen.add(item)
        if type(artifact["media_type"]) is not str:
            raise OperatorError("invalid artifact media type")
    return value


@dataclass(frozen=True)
class CompletedCommand:
    """Freshly revalidated completion and its independently derived inputs."""

    request: dict
    receipt: dict
    admission: object
    context: object = None


@dataclass(frozen=True)
class ProspectivePredecessorAdmission:
    """Earlier run and raw/context authority, retained outside every JSON record."""
    operator_run: OperatorRun
    receipt_input: object


@dataclass(frozen=True)
class OperatorRun:
    root: Path
    manifest_relative_path: str
    manifest_sha256: str
    candidate: object
    integrated_plan_input: LaneCIntegratedCommandPlanInput
    qualification_run: QualificationRunAuthority
    commands: dict
    campaign_profile: CampaignProfile = CampaignProfile.EXISTING
    # Retained by the coordinator; never decoded from run/completion JSON.
    external_admissions: tuple = ()
    prospective_predecessor: ProspectivePredecessorAdmission | None = None

    def with_prospective_predecessor(self, earlier_run, receipt_input):
        """Retain the sole allowed earlier-subject edge for a postmerge run."""
        from .evidence_model import EvidenceReceiptInput
        from .receipt_validator import ReceiptValidationContext
        if (not isinstance(earlier_run, OperatorRun) or earlier_run is self
                or not isinstance(receipt_input, EvidenceReceiptInput)
                or not isinstance(receipt_input.context, ReceiptValidationContext)):
            raise OperatorError("prospective predecessor requires its actual earlier run and raw receipt/context")
        retained = ProspectivePredecessorAdmission(earlier_run, receipt_input)
        result = replace(self, prospective_predecessor=retained)
        result._check_prospective_run(earlier_run)
        return result

    def _check_prospective_run(self, earlier):
        if self.candidate.subject_kind is not CandidateSubjectKind.POST_MERGE:
            raise OperatorError("earlier prospective authority is only allowed for the postmerge transition")
        prospective = replace(self.candidate, subject_kind=CandidateSubjectKind.PROSPECTIVE_MERGE,
                              accepted_postmerge_commit=None, accepted_postmerge_tree=None)
        if (canonical_bytes(candidate_to_mapping(earlier.candidate)) != canonical_bytes(candidate_to_mapping(prospective))
                or earlier.campaign_profile is not self.campaign_profile
                or earlier.qualification_run != self.qualification_run
                or earlier.prospective_predecessor is not None):
            raise OperatorError("earlier prospective run differs from exact candidate/profile/run transition")

    def _retained_external_admission(self, command_id):
        from .external_authority_adapter import ExternalAuthorityAdmission
        retained = [item for item in self.external_admissions
                    if isinstance(item, ExternalAuthorityAdmission) and item.command_id == command_id]
        if len(retained) != 1:
            raise OperatorError("external completion requires one independently retained typed admission")
        return retained[0]

    def _prospective_receipt(self):
        from .command_compiler import command_plan_sha256
        from .evidence_model import EvidenceReceiptInput
        from .external_authority_adapter import ExternalAuthorityAdmission
        from .gate_evaluator import QualifiedPremergeAuthority
        from .receipt_validator import ReceiptValidationContext
        retained = self.prospective_predecessor
        if (not isinstance(retained, ProspectivePredecessorAdmission)
                or not isinstance(retained.operator_run, OperatorRun)
                or not isinstance(retained.receipt_input, EvidenceReceiptInput)
                or not isinstance(retained.receipt_input.context, ReceiptValidationContext)):
            raise OperatorError("postmerge requires independently retained prospective operator authority")
        earlier = retained.operator_run
        self._check_prospective_run(earlier)
        # This reads the earlier manifest and completion, replays its original
        # complete plan/predecessors/admission, and fences its physical outputs.
        fresh = earlier.completed_result("merge.prospective-tree")
        current = self._retained_external_admission("postmerge.exact-tree-proof")
        authority = current.qualified_premerge_authority
        if (not isinstance(fresh.admission, ExternalAuthorityAdmission)
                or not isinstance(authority, QualifiedPremergeAuthority)
                or canonical_bytes(authority) != canonical_bytes(fresh.admission.qualified_premerge_authority)
                or authority.command_plan_sha256 != command_plan_sha256(earlier.integrated_plan_input.plan)
                or fresh.receipt.get("command_plan_sha256") != authority.command_plan_sha256
                or fresh.receipt.get("qualified_premerge_authority_sha256") != authority.canonical_sha256
                or canonical_bytes(fresh.receipt) != canonical_bytes(retained.receipt_input.receipt)
                or fresh.context != retained.receipt_input.context
                or len(current.predecessor_inputs) != 1
                or not isinstance(current.predecessor_inputs[0], EvidenceReceiptInput)
                or canonical_bytes(current.predecessor_inputs[0].receipt) != canonical_bytes(retained.receipt_input.receipt)
                or current.predecessor_inputs[0].context != retained.receipt_input.context):
            raise OperatorError("postmerge substituted earlier plan, qualified authority, receipt or context")
        return fresh.receipt

    def with_external_admissions(self, admissions):
        """Attach actual authority objects for later replay, without serialization."""
        from .external_authority_adapter import ExternalAuthorityAdmission
        values = tuple(admissions)
        if (any(not isinstance(item, ExternalAuthorityAdmission) for item in values)
                or len({item.command_id for item in values}) != len(values)):
            raise OperatorError("external admissions must be unique typed authority objects")
        for item in values:
            self._record(item.command_id)
        return replace(self, external_admissions=values)

    def _external_result(self, command_id, execution):
        from .external_authority_adapter import build_external_request, emit_external_receipt
        admission = self._retained_external_admission(command_id)
        if (admission.execution != execution or admission.profile is not self.campaign_profile
                or admission.artifact_root != self.root):
            raise OperatorError("external admission differs from current operator source/run/predecessors")
        metadata = self.commands[command_id]
        observed = {key: to_primitive(getattr(admission, key)) for key in (
            "receipt_id", "requirement_id", "qualification_phase", "receipt_type",
            "artifact_root_id", "execution_report_artifact_id", "owner_artifacts", "executor")}
        if any(observed[key] != metadata[key] for key in observed):
            raise OperatorError("external admission differs from independently configured owner metadata")
        request = build_external_request(admission)
        _check_external_qualified_seal(command_id, metadata["qualified_premerge_authority_sha256"], request, admission)
        receipt, context = emit_external_receipt(request, admission=admission)
        if command_id == "postmerge.exact-tree-proof":
            self._prospective_receipt()
        self._unchanged()
        return CompletedCommand(request, receipt, admission, context)

    def import_external(self, command_id):
        """Create-only persistence of actual retained observations, including failures."""
        execution = self.admission(command_id)
        result = self._external_result(command_id, execution)
        _publish(self.root, command_id + ".completed.json", canonical_bytes({
            "schema_version": 3, "manifest_sha256": self.manifest_sha256,
            "command_id": command_id, "receipt": result.receipt}))
        # Repeat the physical fence after publication; a mutation retains the
        # failed record and never retries or silently replaces observed bytes.
        fresh = self._external_result(command_id, execution)
        persisted = canonical_bytes({"schema_version": 3, "manifest_sha256": self.manifest_sha256,
                                     "command_id": command_id, "receipt": result.receipt})
        if (canonical_bytes(fresh.receipt) != canonical_bytes(result.receipt)
                or _read(self.root, command_id + ".completed.json", MAX_COMPLETION_BYTES) != persisted):
            raise OperatorError("external evidence changed during completion publication")
        return fresh

    def _unchanged(self):
        current = decode_canonical_bytes(_read(self.root, self.manifest_relative_path, MAX_MANIFEST_BYTES))
        if canonical_sha256(current) != self.manifest_sha256:
            raise OperatorError("run manifest changed after admission")

    def _record(self, command_id):
        _id(command_id)
        if command_id not in self.commands:
            raise OperatorError("command has no operator metadata")
        records = [item for item in self.integrated_plan_input.plan.commands if item.command_id == command_id]
        if len(records) != 1:
            raise OperatorError("command is absent from frozen catalogue")
        return records[0]

    def _preflight_outputs(self, command_id):
        record = self._record(command_id)
        sources = self.commands[command_id]["owner_artifacts"]
        expected = {*("artifact:" + item for item in record.generated_artifacts),
                    *("log:" + item for item in record.generated_logs)}
        if {item["command_output"] for item in sources} != expected:
            raise OperatorError("owner descriptors differ from exact compiled output closure")
        for item in sources:
            declaration = item["command_output"].split(":", 1)[1]
            if item["relative_path"] == CAPTURED_OUTPUT_LOCATOR and not declaration.startswith(
                    ("stdout-path:", "receipt-derived-path:")):
                raise OperatorError("captured locator requires a frozen captured path output")
            if declaration == "stdout-path:MACSCOPE_TEST_RESULTS":
                expected_kind = (ArtifactKind.TEST_RESULTS if command_id == "source.hosted-governance"
                                 else ArtifactKind.XCRESULT)
                if item["kind"] != expected_kind.value:
                    raise OperatorError("test result output differs from its command-specific governed kind")
            if declaration.startswith("receipt-derived-path:") and item["kind"] != _receipt_derived_kind(
                    command_id, item["command_output"]).value:
                raise OperatorError("receipt-derived output differs from its governed artifact kind")
            if declaration.startswith("/") and self.root / item["relative_path"] != Path(declaration):
                raise OperatorError("owner path differs from compiled output")
            if self._captured_stream_kind(command_id, item["command_output"]) is not None:
                path = self.root / item["relative_path"]
                if path.exists() or path.is_symlink():
                    raise OperatorError("captured stream output already exists")

    def _captured_stream_kind(self, command_id, command_output):
        declaration = command_output.split(":", 1)[-1]
        if declaration.startswith("executor-captured:"):
            return "combined"
        if declaration.startswith("stdout-json:"):
            return "stdout"
        if (self.campaign_profile is CampaignProfile.BOOTSTRAP_VERIFIER
                and command_id in {"installed.shell-smoke", "installed.emit-report"}
                and command_output.startswith("log:") and declaration.startswith("/")
                and declaration in self._record(command_id).generated_logs):
            return "combined"
        return None

    def _publish_captured_streams(self, command_id, streams):
        record = self._record(command_id)
        outputs = {*("artifact:" + item for item in record.generated_artifacts),
                   *("log:" + item for item in record.generated_logs)}
        for artifact in self.commands[command_id]["owner_artifacts"]:
            output = artifact["command_output"]
            if output not in outputs:
                raise OperatorError("captured stream output is absent from the compiled command")
            kind = self._captured_stream_kind(command_id, output)
            if kind is None:
                continue
            declaration = output.split(":", 1)[-1]
            if declaration.startswith("/") and self.root / artifact["relative_path"] != Path(declaration):
                raise OperatorError("captured stream path differs from the compiled output")
            payload = streams["stdout"] + streams["stderr"] if kind == "combined" else streams["stdout"]
            _publish(self.root, artifact["relative_path"], payload)

    def admission(self, command_id, _stack=(), _validated=None):
        self._unchanged()
        if _validated is None:
            _validated = {}
        if command_id in _stack:
            raise OperatorError("cyclic predecessor admission")
        record = self._record(command_id)
        predecessors = []
        for predecessor in sorted(set(record.prerequisite_ids) - EXTERNAL_PREREQUISITE_IDS):
            if command_id == "postmerge.exact-tree-proof" and predecessor == "merge.prospective-tree":
                # Never adopt an ordinary cache entry under a different subject.
                receipt = self._prospective_receipt()
            else:
                receipt = _validated.get(predecessor)
            if receipt is None:
                receipt = self.completed(predecessor, _stack + (command_id,), _validated)
                _validated[predecessor] = receipt
            predecessors.append(CommandPrerequisiteExpectation(
                predecessor, receipt["receipt_id"], receipt["canonical_sha256"],
                self.qualification_run.run_id, self.qualification_run.nonce))
        source = self.candidate.source
        return ExecutionAdmission(self.candidate, self.integrated_plan_input,
                                  self.qualification_run, source.commit, source.tree, tuple(predecessors))

    def receipt_admission(self, capture):
        metadata = self.commands[capture.command_id]
        admission = ExecutorReceiptAdmission(
            capture, self.root, metadata["receipt_id"], metadata["requirement_id"],
            QualificationPhase(metadata["qualification_phase"]), ReceiptType(metadata["receipt_type"]),
            metadata["artifact_root_id"], metadata["execution_report_artifact_id"],
            tuple(OwnerArtifactSource(**dict(item, kind=ArtifactKind(item["kind"])))
                  for item in metadata["owner_artifacts"]), metadata["executor"],
            tuple(metadata["constituents"]), metadata["authority"],
            qualified_premerge_authority_sha256=metadata["qualified_premerge_authority_sha256"])
        admission = self._captured_output_admission(admission)
        if (self.campaign_profile is CampaignProfile.BOOTSTRAP_VERIFIER
                and capture.command_id == "installed.emit-report"):
            admission = replace(admission,
                installed_begin_admission=self._installed_begin_capture_admission(capture))
        return admission

    def _installed_begin_capture_admission(self, capture):
        """Replay the compiled ancestor, never recover authority from report JSON."""
        begin_id = "install.release-to-applications"
        if (not isinstance(capture, ExecutionCapture)
                or capture.command_id != "installed.emit-report"
                or self.campaign_profile is not CampaignProfile.BOOTSTRAP_VERIFIER):
            raise OperatorError("installed BEGIN retention requires bootstrap aggregate capture")
        records = {record.command_id: record for record in self.integrated_plan_input.plan.commands}
        pending = list(self._record(capture.command_id).prerequisite_ids)
        ancestors = set()
        while pending:
            command_id = pending.pop()
            if command_id in ancestors:
                continue
            ancestors.add(command_id)
            if command_id in records:
                pending.extend(records[command_id].prerequisite_ids)
        if begin_id not in ancestors:
            raise OperatorError("installed BEGIN is not a compiled aggregate ancestor")
        completed = self.completed_result(begin_id)
        retained = completed.admission
        if (not isinstance(retained, ExecutorReceiptAdmission)
                or not isinstance(retained.capture, ExecutionCapture)
                or retained.capture.command_id != begin_id
                or retained.artifact_root != self.root
                or retained.capture.admission.candidate != capture.admission.candidate
                or retained.capture.admission.qualification_run != capture.admission.qualification_run
                or retained.capture.admission.integrated_plan_input != capture.admission.integrated_plan_input
                or completed.receipt.get("command_id") != begin_id
                or completed.receipt.get("evidence_status") != "passed"):
            raise OperatorError("retained BEGIN capture differs from aggregate candidate/run/plan")
        return retained

    @staticmethod
    def _captured_output_admission(admission):
        """Resolve only frozen output locators, never command/runtime arguments.

        A qualifier chooses its run directory with mktemp. Its emitted paths are
        observed output locations, not values a static manifest can preselect.
        The same independent capture and original manifest drive restart replay.
        """
        if not any(source.relative_path == CAPTURED_OUTPUT_LOCATOR for source in admission.owner_artifacts):
            return admission
        from .executor_request_adapter import _capture
        from .qualification_receipt_adapter import captured_path, directory_path
        admitted, _, streams, _, _, _ = _capture(admission)
        declared = {*("artifact:" + item for item in admitted.record.generated_artifacts),
                    *("log:" + item for item in admitted.record.generated_logs)}
        if {source.command_output for source in admission.owner_artifacts} != declared:
            raise OperatorError("captured output locator differs from frozen output closure")

        def relative(path):
            try:
                result = path.relative_to(admission.artifact_root).as_posix()
            except ValueError as error:
                raise OperatorError("captured output escapes the run artifact root") from error
            if not safe_relative_artifact_path(result):
                raise OperatorError("captured output has an unsafe relative path")
            return result

        sources = []
        # Resolve emitted paths first so Release's fixed path can be derived
        # from the already-bound physical qualification receipt location.
        for source in admission.owner_artifacts:
            if source.relative_path == CAPTURED_OUTPUT_LOCATOR:
                declaration = source.command_output.split(":", 1)[1]
                if declaration.startswith("stdout-path:"):
                    source = replace(source, relative_path=relative(captured_path(
                        streams, declaration.removeprefix("stdout-path:"))))
                elif not declaration.startswith("receipt-derived-path:"):
                    raise OperatorError("unsupported captured output locator")
            sources.append(source)
        admission = replace(admission, owner_artifacts=tuple(sources))
        def receipt_derived_path(source):
            expected_kind = _receipt_derived_kind(admission.capture.command_id, source.command_output)
            if source.kind is not expected_kind:
                raise OperatorError("receipt-derived output differs from its governed artifact kind")
            if expected_kind is ArtifactKind.APP_BUNDLE:
                return directory_path(admission, source, streams)
            apps = [item for item in admission.owner_artifacts if item.command_output == RELEASE_APP_OUTPUT
                    and item.kind is ArtifactKind.APP_BUNDLE]
            if len(apps) != 1:
                raise OperatorError("Release provenance requires its original frozen app output")
            # Reuse the receipt-bound canonical directory resolver; provenance
            # is the one ordinary JSON child governed by the Release catalogue.
            path = directory_path(admission, apps[0], streams) / RELEASE_PROVENANCE_SUFFIX
            if path.resolve(strict=True) != path or path.is_symlink() or not path.is_file():
                raise OperatorError("Release provenance must be an ordinary canonical file")
            return path

        sources = tuple(replace(source, relative_path=relative(receipt_derived_path(source)))
                        if source.relative_path == CAPTURED_OUTPUT_LOCATOR else source
                        for source in admission.owner_artifacts)
        if len({source.relative_path for source in sources}) != len(sources):
            raise OperatorError("captured output locators resolve to duplicate physical artifacts")
        return replace(admission, owner_artifacts=sources)

    @staticmethod
    def _projected_admission(admission, persisted_sources=None, *, publish=False):
        """Derive from original manifest, never reconstruct authority from receipt.

        Only directory source metadata can change. Original output/kind/ID and
        every other admission field remain independently configured. Physical
        directory contents are still verified by the receipt adapter on replay.
        """
        if (admission.capture.command_id == "native.golden" and
                campaign_profile_for_inputs(admission.capture.admission.integrated_plan_input.inputs) is CampaignProfile.BOOTSTRAP_VERIFIER):
            from .native_receipt_adapter import native_projection_sources, publish_native_projection
            expected = replace(admission, owner_artifacts=native_projection_sources(admission))
            if persisted_sources is not None and persisted_sources != to_primitive(expected.owner_artifacts):
                raise OperatorError("persisted native projection differs from fixed golden owner bindings")
            if publish:
                observed = publish_native_projection(admission)
                if observed != expected:
                    raise OperatorError("native projection publisher changed independent admission")
            return expected
        if admission.capture.command_id in VERIFIER_COMMAND_IDS:
            # Verifiers create their own physical projection files. Persist and
            # revalidate those ordinary outputs; never run the qualifier publisher.
            if persisted_sources is not None and persisted_sources != to_primitive(admission.owner_artifacts):
                raise OperatorError("persisted projections differ from original manifest directory bindings")
            return admission
        directory_sources = any(source.kind in {ArtifactKind.APP_BUNDLE, ArtifactKind.XCRESULT}
                                for source in admission.owner_artifacts)
        if directory_sources:
            from .qualification_receipt_adapter import (qualification_artifact_projection_sources,
                                                          publish_qualification_artifact_projections)
            sources = qualification_artifact_projection_sources(admission)
        else:
            sources = admission.owner_artifacts
        expected = replace(admission, owner_artifacts=sources)
        if persisted_sources is not None and persisted_sources != to_primitive(sources):
            raise OperatorError("persisted projections differ from original manifest directory bindings")
        if publish and directory_sources:
            observed = publish_qualification_artifact_projections(admission)
            if observed != expected:
                raise OperatorError("projection publisher changed independent admission")
        return expected

    def completed(self, command_id, _stack=(), _validated=None):
        return self.completed_result(command_id, _stack, _validated).receipt

    def completed_result(self, command_id, _stack=(), _validated=None):
        """Replay physical validation without publishing or adopting stored authority."""
        admission = self.admission(command_id, _stack, _validated)
        persisted = _read(self.root, command_id + ".completed.json", MAX_COMPLETION_BYTES)
        value = decode_canonical_bytes(persisted)
        if type(value) is not dict or type(value.get("schema_version")) is not int or value["schema_version"] not in {1, 2, 3}:
            raise OperatorError("unsupported completed command schema")
        version = value["schema_version"]
        if version == 3:
            _closed(value, EXTERNAL_COMPLETION_FIELDS, "external completed command")
            if value["manifest_sha256"] != self.manifest_sha256 or value["command_id"] != command_id:
                raise OperatorError("external completion belongs to another manifest or command")
            fresh = self._external_result(command_id, admission)
            if (canonical_bytes(fresh.receipt) != canonical_bytes(value["receipt"])
                    or fresh.receipt["evidence_status"] != "passed"
                    or _read(self.root, command_id + ".completed.json", MAX_COMPLETION_BYTES) != persisted):
                raise OperatorError("persisted external receipt differs from fresh passed physical validation")
            return fresh
        _closed(value, COMPLETION_FIELDS if version == 1 else PROJECTED_COMPLETION_FIELDS, "completed command")
        if value["manifest_sha256"] != self.manifest_sha256:
            raise OperatorError("completed command belongs to another static run manifest")
        payload = _read(self.root, value["capture_path"], MAX_CAPTURE_BYTES)
        envelope = parse_capture(payload).to_mapping()
        intent = envelope["intent"]
        if intent["command_id"] != command_id:
            raise OperatorError("completed capture belongs to another command")
        import hashlib
        capture = ExecutionCapture(admission, command_id, intent["scenario_id"], intent["capture_id"],
                                   tuple(tuple(item) for item in intent["effective_environment"]),
                                   self.root / value["capture_path"], hashlib.sha256(payload).hexdigest())
        receipt_admission = self.receipt_admission(capture)
        if version == 1 and any(source.kind in {ArtifactKind.APP_BUNDLE, ArtifactKind.XCRESULT}
                                for source in receipt_admission.owner_artifacts):
            raise OperatorError("directory artifacts require persisted projection bindings")
        if version == 2:
            if type(value["owner_artifacts"]) is not list:
                raise OperatorError("persisted owner artifacts must be a closed list")
            receipt_admission = self._projected_admission(receipt_admission, value["owner_artifacts"])
        request = build_executor_request(receipt_admission)
        fresh, context = emit_captured_receipt(request, artifact_root=self.root,
                                       qualification_run_authority=self.qualification_run,
                                       admission=receipt_admission)
        if fresh != value["receipt"] or fresh["evidence_status"] != "passed":
            raise OperatorError("persisted receipt differs from fresh physical validation")
        return CompletedCommand(request, fresh, receipt_admission, context)

    def execute(self, command_id, scenario_id, cancellation):
        _id(command_id)
        completion = command_id + ".completed.json"
        completed_path = self.root / completion
        if completed_path.exists() or completed_path.is_symlink():
            raise OperatorError("command already has a completed record; execution is not repeated")
        admission = self.admission(command_id)
        admit_command(admission, command_id, scenario_id, profile=self.campaign_profile)
        self._preflight_outputs(command_id)
        from .executor_request_adapter import (capture_derived_report_policy,
                                               publish_capture_execution_report,
                                               capture_execution_report_artifact_id,
                                               capture_derived_report_receipt_type)
        if capture_derived_report_policy(command_id, profile=self.campaign_profile):
            metadata = self.commands[command_id]
            if (metadata["receipt_type"] != capture_derived_report_receipt_type(command_id, profile=self.campaign_profile).value
                    or metadata["execution_report_artifact_id"] !=
                    capture_execution_report_artifact_id(metadata["receipt_id"])):
                raise OperatorError("capture-derived report metadata differs from frozen policy")
        # Reserve the command before launching. A failed attempt remains explicit
        # and cannot silently be rerun over mutable products in this run.
        _publish(self.root, command_id + ".started.json", canonical_bytes({
            "schema_version": 1, "manifest_sha256": self.manifest_sha256,
            "command_id": command_id, "scenario_id": scenario_id}))
        capture = execute_admitted_command(admission, command_id=command_id, scenario_id=scenario_id,
                                           capture_root=self.root, cancellation=cancellation,
                                           profile=self.campaign_profile)
        document = parse_capture(_read(self.root, capture.capture_path.relative_to(self.root).as_posix(),
                                       MAX_CAPTURE_BYTES)).to_mapping()
        streams = {name: b"".join(base64.b64decode(frame["data_base64"], validate=True)
                                 for frame in document["output_frames"] if frame["stream"] == name)
                   for name in ("stdout", "stderr")}
        self._publish_captured_streams(command_id, streams)
        self._unchanged()
        receipt_admission = self.receipt_admission(capture)
        receipt_admission = self._projected_admission(receipt_admission, publish=True)
        if capture_derived_report_policy(command_id, profile=self.campaign_profile):
            publish_capture_execution_report(receipt_admission)
        request = build_executor_request(receipt_admission)
        receipt, _ = emit_captured_receipt(request, artifact_root=self.root,
                                         qualification_run_authority=self.qualification_run,
                                         admission=receipt_admission)
        _publish(self.root, completion, canonical_bytes({"schema_version": 2,
                 "manifest_sha256": self.manifest_sha256,
                 "owner_artifacts": to_primitive(receipt_admission.owner_artifacts),
                 "capture_path": capture.capture_path.relative_to(self.root).as_posix(), "receipt": receipt}))
        return self.completed(command_id)


def load_run(root: Path, manifest_relative_path: str = "run.json") -> OperatorRun:
    if not root.is_absolute() or root.resolve(strict=True) != root:
        raise OperatorError("run root must be existing and canonical")
    value = decode_canonical_bytes(_read(root, manifest_relative_path, MAX_MANIFEST_BYTES))
    if type(value) is not dict or type(value.get("schema_version")) is not int or value["schema_version"] not in {1, 2, 3}:
        raise OperatorError("unsupported run manifest schema")
    _closed(value, MANIFEST_FIELDS | {"campaign_profile"} if value["schema_version"] == 3 else MANIFEST_FIELDS,
            "run manifest")
    try:
        profile = CampaignProfile(value["campaign_profile"]) if value["schema_version"] == 3 else CampaignProfile.EXISTING
    except ValueError as error:
        raise OperatorError("unsupported campaign profile") from error
    candidate, issues = parse_candidate_identity(value["candidate_identity"])
    if candidate is None or issues:
        raise OperatorError("invalid run candidate")
    run_mapping = _closed(value["qualification_run"], {"run_id", "nonce"}, "qualification run")
    run = QualificationRunAuthority(**run_mapping)
    if validate_qualification_run_authority(run_mapping, expected=run, path="$.qualification_run"):
        raise OperatorError("invalid qualification run")
    inputs = value["command_inputs"]
    if type(inputs) is not dict or any(type(k) is not str or type(v) is not str for k, v in inputs.items()):
        raise OperatorError("command inputs must be a text mapping")
    if campaign_profile_for_inputs(inputs) is not profile:
        raise OperatorError("campaign inputs differ from independently selected profile")
    if (inputs.get("qualification_run_id"), inputs.get("qualification_run_nonce")) != (run.run_id, run.nonce):
        raise OperatorError("compiled run differs from manifest run")
    if type(value["repository_root"]) is not str:
        raise OperatorError("repository root must be a canonical absolute path")
    repository = Path(value["repository_root"])
    if not repository.is_absolute() or repository.resolve(strict=True) != repository:
        raise OperatorError("repository root must be a canonical absolute path")
    scenarios = compile_scenario_catalog(candidate)
    templates = {item.command_id: item for item in command_templates(profile=profile)}
    plan = compile_command_plan(candidate, scenarios, repository_root=repository, inputs=inputs, profile=profile)
    integrated = LaneCIntegratedCommandPlanInput(plan, scenarios, repository, inputs, templates)
    validated, issues = validate_integrated_lane_c_command_plan(integrated, candidate=candidate, profile=profile)
    if validated is None or issues:
        raise OperatorError("candidate source/full plan admission failed: " + "; ".join(item.code for item in issues))
    # Running a different operator copy against a clean candidate checkout must
    # not silently borrow that checkout's source identity.
    for name in ("operator_run.py", "operator_cli.py"):
        active = Path(__file__).parent / name
        governed = repository / "Scripts/reconstruction_gate_f" / name
        if active.read_bytes() != governed.read_bytes():
            raise OperatorError("active operator differs from admitted source")
    if type(value["commands"]) is not dict or not value["commands"]:
        raise OperatorError("commands must be a nonempty metadata mapping")
    receipt_ids = set()
    for command_id, metadata in value["commands"].items():
        if _id(command_id) not in templates:
            raise OperatorError("unknown operator command")
        _metadata(metadata)
        if value["schema_version"] == 1 and any(item["relative_path"] == CAPTURED_OUTPUT_LOCATOR
                                               for item in metadata["owner_artifacts"]):
            raise OperatorError("captured output locators require run manifest schema two")
        if metadata["receipt_id"] in receipt_ids:
            raise OperatorError("receipt identities must be unique across the run")
        receipt_ids.add(metadata["receipt_id"])
    return OperatorRun(root, manifest_relative_path, canonical_sha256(value), candidate,
                       integrated, run, value["commands"], profile)
