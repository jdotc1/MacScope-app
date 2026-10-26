"""Shared admission boundaries; physical success fixtures live with each adapter."""
from __future__ import annotations

import hashlib
import tempfile
import unittest
from dataclasses import dataclass, replace
from pathlib import Path
from types import SimpleNamespace

from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes
from Scripts.lib.work_root import existing_work_root, work_root as macscope_work_root
from Scripts.reconstruction_gate_f.executor_receipt import (
    ReceiptEmissionError, _validate_legacy_physical_evidence,
)
from Scripts.reconstruction_gate_f.executor_request_adapter import (
    INSTALLED_PRODUCER_COMMANDS, INSTALLED_PRODUCER_ROLES, installed_producer_policy,
)
from Scripts.reconstruction_gate_f.receipt_validator import (
    EXTERNAL_AUTHORITY_COMMANDS, _validate_physical_receipt, validate_receipt,
)
from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile
from Scripts.reconstruction_gate_f.schema import ReceiptType
from Scripts.reconstruction_gate_f.tests import test_executor_receipt as physical_fixture
from Scripts.reconstruction_gate_f.tests import test_receipt_validator as receipt_fixture
from Scripts.reconstruction_gate_f.operator_run import OperatorRun, OperatorError, CompletedCommand


@dataclass(frozen=True)
class _PhysicalStageOperatorRun(OperatorRun):
    """Isolate the full-campaign adapter, but replay genuine physical semantics.

    These focused operator tests do not claim a public all-ancestor campaign.
    The production external adapter/source validators are tested separately;
    no physical semantic validator is replaced with a favorable Boolean.
    """
    physical_request: object = None
    review_request: object = None

    def completed(self, command_id, *args):
        if command_id == "review.independent":
            return _validate_legacy_physical_evidence(self.review_request, artifact_root=self.root,
                qualification_run_authority=self.qualification_run)[0]
        return super().completed(command_id, *args)

    def _external_result(self, command_id, execution):
        admission = self.external_admissions[0]
        if (admission.execution != execution or admission.command_id != command_id
                or admission.profile is not self.campaign_profile or admission.artifact_root != self.root):
            raise OperatorError("physical-stage fixture rejected changed execution authority")
        receipt, context = _validate_legacy_physical_evidence(self.physical_request,
            artifact_root=self.root, qualification_run_authority=self.qualification_run)
        return CompletedCommand(self.physical_request, receipt, admission,
                                replace(context, external_admission=admission))


@dataclass(frozen=True)
class _PhysicalReviewOperatorRun(_PhysicalStageOperatorRun):
    """Serialization-only fixture; retain the review's existing raw admission."""
    def admission(self, command_id, *args):
        self._unchanged()
        return self.external_admissions[0].execution


class OperatorReplayRepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=existing_work_root())
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def _run(self, *, postmerge=False, predecessor=None, authority=None):
        from Scripts.reconstruction_gate_f.canonical_json import canonical_sha256, decode_canonical_bytes, to_primitive
        from Scripts.reconstruction_gate_f.command_catalog import command_templates
        from Scripts.reconstruction_gate_f.command_compiler import compile_command_plan, command_plan_sha256
        from Scripts.reconstruction_gate_f.command_execution import ExecutionAdmission
        from Scripts.reconstruction_gate_f.evidence_model import EvidenceReceiptInput
        from Scripts.reconstruction_gate_f.external_authority_adapter import ExternalAuthorityAdmission
        from Scripts.reconstruction_gate_f.executor_request_adapter import OwnerArtifactSource
        from Scripts.reconstruction_gate_f.gate_evaluator import QualifiedPremergeAuthority
        from Scripts.reconstruction_gate_f.prerequisite_dag import LaneCIntegratedCommandPlanInput
        from Scripts.reconstruction_gate_f.receipt_validator import CommandPrerequisiteExpectation
        from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
        from Scripts.reconstruction_gate_f.schema import ArtifactKind, QualificationPhase, parse_candidate_identity, candidate_identity_sha256
        from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs
        root = self.root / ("postmerge" if postmerge else "prospective")
        root.mkdir()
        fixture = physical_fixture.GateFExecutorReceiptTests(methodName="runTest")
        fixture.root = root
        fixture.templates = {item.command_id: item for item in command_templates()}
        request = fixture._merge_authority_request(postmerge=postmerge)
        candidate, issues = parse_candidate_identity(request["candidate_identity"])
        self.assertFalse(issues)
        fixture.candidate = candidate
        review_request = None
        if predecessor is None:
            review_request = fixture._independent_review_request()
            raw, context = _validate_legacy_physical_evidence(review_request, artifact_root=root,
                qualification_run_authority=physical_fixture.QUALIFICATION_RUN)
            predecessor = EvidenceReceiptInput(raw, context)
        prior = predecessor.receipt
        expectations = (CommandPrerequisiteExpectation(prior["command_id"], prior["receipt_id"],
            prior["canonical_sha256"], prior["qualification_run"]["run_id"], prior["qualification_run"]["nonce"]),)
        inputs = command_inputs()
        inputs.update(qualification_run_id=physical_fixture.QUALIFICATION_RUN.run_id,
                      qualification_run_nonce=physical_fixture.QUALIFICATION_RUN.nonce)
        scenarios = compile_scenario_catalog(candidate)
        plan = compile_command_plan(candidate, scenarios, repository_root=ROOT, inputs=inputs)
        integrated = LaneCIntegratedCommandPlanInput(plan, scenarios, ROOT, inputs, fixture.templates)
        if authority is None:
            fields = dict(schema_version=2, qualification_run_id=physical_fixture.QUALIFICATION_RUN.run_id,
                qualification_run_nonce=physical_fixture.QUALIFICATION_RUN.nonce,
                prospective_candidate_identity_sha256=candidate_identity_sha256(candidate),
                source_contract_sha256="1" * 64, prerequisite_dag_sha256="2" * 64,
                evidence_partial_order_sha256="3" * 64, evidence_root_sha256="4" * 64,
                receipt_digests=((prior["receipt_id"], prior["canonical_sha256"]),),
                command_plan_sha256=command_plan_sha256(plan), decision_status="qualified-premerge")
            authority = QualifiedPremergeAuthority(**fields, canonical_sha256=canonical_sha256(fields))
        request["command_plan_sha256"] = command_plan_sha256(plan)
        request["qualified_premerge_authority_sha256"] = authority.canonical_sha256
        request["command_authority"]["prerequisite_receipts"] = [vars(item) for item in expectations]
        report_artifact = next(item for item in request["artifacts"]
                               if item["artifact_id"] == request["execution_report_artifact_id"])
        path = root / report_artifact["relative_path"]
        report = decode_canonical_bytes(path.read_bytes())
        report["predecessor_observations_sha256"] = canonical_sha256([vars(item) for item in expectations])
        payload = canonical_bytes(report)
        path.write_bytes(payload)
        report_artifact.update(byte_count=len(payload), sha256=hashlib.sha256(payload).hexdigest())
        execution = ExecutionAdmission(candidate, integrated, physical_fixture.QUALIFICATION_RUN,
            candidate.source.commit, candidate.source.tree, expectations)
        sources = tuple(OwnerArtifactSource(item["artifact_id"], item["relative_path"], ArtifactKind(item["kind"]),
            item["media_type"], item["command_output"]) for item in request["artifacts"])
        admission = ExternalAuthorityAdmission(execution, CampaignProfile.EXISTING, request["command_id"],
            request["scenario_id"], root, request["receipt_id"], request["requirement_id"],
            QualificationPhase(request["qualification_phase"]), ReceiptType(request["receipt_type"]),
            request["artifact_root_id"], request["execution_report_artifact_id"], sources, (predecessor,),
            request["executor"], (), tuple((s.command_output, (root / s.relative_path).read_bytes()) for s in sources),
            authority, None)
        manifest = dict(candidate=request["candidate_identity"], plan_sha256=command_plan_sha256(plan),
                        qualification_run=request["qualification_run"])
        (root / "run.json").write_bytes(canonical_bytes(manifest))
        run = _PhysicalStageOperatorRun(root, "run.json", canonical_sha256(manifest), candidate,
            integrated, physical_fixture.QUALIFICATION_RUN, {request["command_id"]: {}},
            external_admissions=(admission,), physical_request=request, review_request=review_request)
        return run

    def test_transition_replays_original_prospective_manifest_plan_and_context(self):
        from Scripts.reconstruction_gate_f.evidence_model import EvidenceReceiptInput
        earlier = self._run()
        completed = earlier.import_external("merge.prospective-tree")
        raw = EvidenceReceiptInput(completed.receipt, completed.context)
        current = self._run(postmerge=True, predecessor=raw,
            authority=completed.admission.qualified_premerge_authority)
        current = current.with_prospective_predecessor(earlier, raw)
        result = current.import_external("postmerge.exact-tree-proof")
        self.assertNotEqual(earlier.candidate, current.candidate)
        self.assertNotEqual(earlier.integrated_plan_input.plan, current.integrated_plan_input.plan)
        self.assertEqual(current.completed_result("postmerge.exact-tree-proof").receipt, result.receipt)
        self.assertEqual(earlier.completed_result("merge.prospective-tree").receipt, completed.receipt)
        (earlier.root / "run.json").write_bytes(b"{}")
        with self.assertRaises(OperatorError):
            current.completed_result("postmerge.exact-tree-proof")

    def test_persisted_external_integer_boolean_mutations_reject_original_and_resealed_digest(self):
        from copy import deepcopy
        from Scripts.reconstruction_gate_f.canonical_json import decode_canonical_bytes
        from Scripts.reconstruction_gate_f.receipt_schema import seal_receipt
        run = self._run()
        run.import_external("merge.prospective-tree")
        path = run.root / "merge.prospective-tree.completed.json"
        original = decode_canonical_bytes(path.read_bytes())
        for field in ("attempt", "approval_count"):
            for reseal in (False, True):
                value = deepcopy(original)
                if field == "attempt":
                    value["receipt"][field] = True
                else:
                    # The genuine prospective fixture has integer approval_count=1.
                    value["receipt"]["authority"][field] = True
                if reseal:
                    value["receipt"] = seal_receipt(value["receipt"])
                path.write_bytes(canonical_bytes(value))
                with self.subTest(field=field, reseal=reseal), self.assertRaises(OperatorError):
                    run.completed_result("merge.prospective-tree")

    def test_zero_review_count_cannot_be_false_with_original_or_resealed_digest(self):
        from copy import deepcopy
        from Scripts.reconstruction_gate_f.canonical_json import decode_canonical_bytes
        from Scripts.reconstruction_gate_f.receipt_schema import seal_receipt
        base = self._run()
        request = base.review_request
        admission = replace(base.external_admissions[0], command_id=request["command_id"])
        run = _PhysicalReviewOperatorRun(base.root, base.manifest_relative_path, base.manifest_sha256,
            base.candidate, base.integrated_plan_input, base.qualification_run,
            {request["command_id"]: {}}, external_admissions=(admission,), physical_request=request)
        run.import_external("review.independent")
        path = run.root / "review.independent.completed.json"
        original = decode_canonical_bytes(path.read_bytes())
        self.assertEqual(type(original["receipt"]["authority"]["p0_count"]), int)
        for reseal in (False, True):
            value = deepcopy(original)
            value["receipt"]["authority"]["p0_count"] = False
            if reseal:
                value["receipt"] = seal_receipt(value["receipt"])
            path.write_bytes(canonical_bytes(value))
            with self.subTest(reseal=reseal), self.assertRaises(OperatorError):
                run.completed_result("review.independent")

    def test_transition_rejects_foreign_earlier_authority_and_retained_inputs(self):
        from Scripts.reconstruction_gate_f.evidence_model import EvidenceReceiptInput
        from Scripts.reconstruction_gate_f.canonical_json import canonical_sha256, to_primitive
        from Scripts.reconstruction_gate_f.receipt_schema import seal_receipt
        earlier = self._run()
        completed = earlier.import_external("merge.prospective-tree")
        raw = EvidenceReceiptInput(completed.receipt, completed.context)
        current = self._run(postmerge=True, predecessor=raw,
            authority=completed.admission.qualified_premerge_authority)
        foreign_runs = (
            replace(earlier, candidate=replace(earlier.candidate,
                source=replace(earlier.candidate.source, commit="a" * 40))),
            replace(earlier, qualification_run=replace(earlier.qualification_run, nonce="b" * 64)),
            replace(earlier, campaign_profile=CampaignProfile.BOOTSTRAP_VERIFIER),
            replace(earlier, integrated_plan_input=replace(earlier.integrated_plan_input,
                plan=replace(earlier.integrated_plan_input.plan, candidate_identity_sha256="c" * 64))),
        )
        for foreign in foreign_runs:
            with self.subTest(foreign=foreign.campaign_profile), self.assertRaises(OperatorError):
                current.with_prospective_predecessor(foreign, raw).admission("postmerge.exact-tree-proof")
        substituted = (
            replace(raw, receipt=seal_receipt(dict(raw.receipt, attempt=2))),
            replace(raw, context=replace(raw.context, expected_attempt=2)),
        )
        for value in substituted:
            with self.assertRaises(OperatorError):
                current.with_prospective_predecessor(earlier, value).admission("postmerge.exact-tree-proof")
        authority = current.external_admissions[0].qualified_premerge_authority
        fields = to_primitive(replace(authority, evidence_root_sha256="e" * 64))
        fields.pop("canonical_sha256")
        foreign = replace(authority, evidence_root_sha256="e" * 64, canonical_sha256=canonical_sha256(fields))
        changed = replace(current, external_admissions=(replace(current.external_admissions[0],
                          qualified_premerge_authority=foreign),))
        with self.assertRaises(OperatorError):
            changed.with_prospective_predecessor(earlier, raw).admission("postmerge.exact-tree-proof")
        # A valid cache entry must not bypass the retained earlier-run fence.
        current = current.with_prospective_predecessor(earlier, raw)
        (earlier.root / "merge.prospective-tree.completed.json").write_bytes(b"{}")
        with self.assertRaises(OperatorError):
            current.admission("postmerge.exact-tree-proof", _validated={"merge.prospective-tree": raw.receipt})


class OperatorOutputBindingTests(unittest.TestCase):
    def setUp(self):
        from Scripts.reconstruction_gate_f.command_catalog import command_templates
        from Scripts.reconstruction_gate_f.command_compiler import compile_command_plan
        from Scripts.reconstruction_gate_f.prerequisite_dag import LaneCIntegratedCommandPlanInput
        from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
        from Scripts.reconstruction_gate_f.tests import parsed_candidate
        from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs
        self.temp = tempfile.TemporaryDirectory(dir=existing_work_root())
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        candidate = parsed_candidate()
        scenarios = compile_scenario_catalog(candidate)
        inputs = command_inputs(profile=CampaignProfile.BOOTSTRAP_VERIFIER,
                                repository_root=ROOT, output_root=self.root)
        from Scripts.reconstruction_gate_f.command_catalog import installed_gate_output_slots
        for name in ("installed_report",
                     *(name for _, name in installed_gate_output_slots())):
            inputs[name] = str(self.root / (name + ".json"))
        shell_report = self.root / "installed_shell_smoke_report.json"
        inputs.update(
            installed_shell_smoke_report=str(shell_report),
            installed_full_surface_report=str(shell_report),
            installed_legacy_grid_report=str(shell_report.with_name(
                shell_report.stem + ".legacy-grid" + shell_report.suffix)),
        )
        plan = compile_command_plan(candidate, scenarios, repository_root=ROOT, inputs=inputs,
                                    profile=CampaignProfile.BOOTSTRAP_VERIFIER)
        integrated = LaneCIntegratedCommandPlanInput(plan, scenarios, ROOT, inputs,
            {item.command_id: item for item in command_templates(profile=CampaignProfile.BOOTSTRAP_VERIFIER)})
        self.run = OperatorRun(self.root, "run.json", "a" * 64, candidate, integrated,
                               physical_fixture.QUALIFICATION_RUN, {}, CampaignProfile.BOOTSTRAP_VERIFIER)

    def command(self, command_id, result_kind="xcresult"):
        record = next(item for item in self.run.integrated_plan_input.plan.commands if item.command_id == command_id)
        sources = []
        for index, output in enumerate((*('artifact:' + item for item in record.generated_artifacts),
                                        *('log:' + item for item in record.generated_logs))):
            declaration = output.split(":", 1)[1]
            relative = (Path(declaration).relative_to(self.root).as_posix() if declaration.startswith("/")
                        else "owned-" + str(index) + ".json")
            kind = "launch-log" if output.startswith("log:") else "json"
            if declaration == "stdout-path:MACSCOPE_TEST_RESULTS":
                kind = result_kind
            sources.append(dict(artifact_id="artifact-" + str(index), relative_path=relative,
                kind=kind, media_type="text/plain" if kind == "launch-log" else "application/json",
                command_output=output))
        return replace(self.run, commands={command_id: {"owner_artifacts": sources}})

    def test_hosted_result_is_json_but_native_result_remains_xcresult(self):
        hosted = self.command("source.hosted-governance", result_kind="test-results")
        hosted._preflight_outputs("source.hosted-governance")
        with self.assertRaises(OperatorError):
            self.command("source.hosted-governance")._preflight_outputs("source.hosted-governance")
        native = self.command("xcode.focused.batch-scheduler")
        native._preflight_outputs("xcode.focused.batch-scheduler")
        with self.assertRaises(OperatorError):
            self.command("xcode.focused.batch-scheduler", result_kind="test-results")._preflight_outputs(
                "xcode.focused.batch-scheduler")

    def test_exact_installed_absolute_logs_publish_streams_create_only(self):
        for command in ("installed.shell-smoke", "installed.emit-report"):
            run = self.command(command)
            run._preflight_outputs(command)
            streams = {"stdout": b"retained stdout\n", "stderr": b"retained stderr\n"}
            run._publish_captured_streams(command, streams)
            logs = [item for item in run.commands[command]["owner_artifacts"] if item["command_output"].startswith("log:")]
            self.assertTrue(logs)
            for item in logs:
                self.assertEqual((run.root / item["relative_path"]).read_bytes(), streams["stdout"] + streams["stderr"])
            with self.assertRaises(OperatorError):
                run._preflight_outputs(command)
            with self.assertRaises(FileExistsError):
                run._publish_captured_streams(command, streams)
        ordinary = self.command("source.hosted-governance", result_kind="test-results")
        self.assertIsNone(ordinary._captured_stream_kind("source.hosted-governance", "log:" + str(self.root / "foreign.log")))

    def test_existing_stdout_json_and_combined_logs_preserve_exact_bytes(self):
        run = self.command("installed.source-equality")
        streams = {"stdout": b'{"observed":true}\n', "stderr": b"bounded diagnostic\n"}
        run._preflight_outputs("installed.source-equality")
        run._publish_captured_streams("installed.source-equality", streams)
        for item in run.commands["installed.source-equality"]["owner_artifacts"]:
            expected = streams["stdout"] + streams["stderr"] if item["command_output"].startswith("log:") else streams["stdout"]
            self.assertEqual((run.root / item["relative_path"]).read_bytes(), expected)

    def test_installed_absolute_log_scope_and_path_cannot_expand(self):
        command = "installed.shell-smoke"
        run = self.command(command)
        item = next(item for item in run.commands[command]["owner_artifacts"] if item["command_output"].startswith("log:"))
        declaration = item["command_output"]
        self.assertIsNone(replace(run, campaign_profile=CampaignProfile.EXISTING)._captured_stream_kind(command, declaration))
        self.assertIsNone(run._captured_stream_kind(command, "log:" + str(self.root / "foreign.log")))
        sources = [dict(source, relative_path="redirected.log") if source is item else source
                   for source in run.commands[command]["owner_artifacts"]]
        changed = replace(run, commands={command: {"owner_artifacts": sources}})
        with self.assertRaises(OperatorError):
            changed._publish_captured_streams(command, {"stdout": b"out", "stderr": b"err"})
        self.assertFalse((self.root / "redirected.log").exists())


class CompletionHooksTests(unittest.TestCase):
    def setUp(self):
        self.fixture = receipt_fixture.GateFReceiptValidatorTests(methodName="runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)

    def test_exact_eight_external_ids_require_admission_from_both_id_axes(self):
        from Scripts.reconstruction_gate_f.external_authority_adapter import EXTERNAL_COMMAND_IDS
        self.assertEqual(len(EXTERNAL_AUTHORITY_COMMANDS), 8)
        self.assertEqual(EXTERNAL_AUTHORITY_COMMANDS, EXTERNAL_COMMAND_IDS)
        for command in EXTERNAL_AUTHORITY_COMMANDS:
            with self.subTest(command=command):
                for raw, expected in ((command, "hosted-tests"), ("hosted-tests", command), (command, command)):
                    issues = validate_receipt({"command_id": raw}, context=replace(
                        self.fixture._context(), expected_command_id=expected))
                    self.assertEqual([item.code for item in issues], ["external-admission-required"])

    def test_external_context_cannot_replace_runnable_capture(self):
        context = replace(self.fixture._context(), expected_command_id="source.create-sealed-export",
                          external_admission=object())
        issues = validate_receipt({"command_id": context.expected_command_id}, context=context)
        self.assertEqual([item.code for item in issues], ["external-admission"])
        context = replace(context, external_admission=None)
        issues = validate_receipt({"command_id": context.expected_command_id}, context=context)
        self.assertEqual([item.code for item in issues], ["capture-admission-required"])

    def test_external_context_wrong_type_is_rejected(self):
        context = replace(self.fixture._context(), expected_command_id="review.independent",
                          external_admission={"passed": True})
        issues = validate_receipt({"command_id": context.expected_command_id}, context=context)
        self.assertEqual([item.code for item in issues], ["external-admission"])

    def test_installed_roles_are_bootstrap_only_and_preflight_has_no_selectors(self):
        for command in INSTALLED_PRODUCER_COMMANDS:
            self.assertFalse(installed_producer_policy(command))
            self.assertTrue(installed_producer_policy(command, profile=CampaignProfile.BOOTSTRAP_VERIFIER))
            context = replace(self.fixture._context(), expected_command_id=command,
                              capture_derived_execution=True)
            self.assertEqual([issue.code for issue in validate_receipt({"command_id": command}, context=context)],
                             ["capture-admission-required"])
        self.assertIs(INSTALLED_PRODUCER_ROLES["installed.xcuitest-preflight"], ReceiptType.COMMAND_EXECUTION)
        receipt = self.fixture._make_receipt()
        receipt["command_id"] = "installed.xcuitest-preflight"
        context = replace(self.fixture._context(), expected_command_id=receipt["command_id"],
                          capture_derived_execution=True)
        codes = {item.code for item in _validate_physical_receipt(receipt, context=context)}
        self.assertIn("installed-receipt-role", codes)
        self.assertIn("installed-preflight-constituents", codes)

    def test_bootstrap_begin_uses_installed_capture_policy_not_legacy_install_reports(self):
        from Scripts.reconstruction_gate_f.executor_request_adapter import (
            capture_derived_report_policy, capture_derived_report_receipt_type,
        )
        command = "install.release-to-applications"
        self.assertFalse(installed_producer_policy(command))
        self.assertFalse(capture_derived_report_policy(command))
        self.assertTrue(installed_producer_policy(command, profile=CampaignProfile.BOOTSTRAP_VERIFIER))
        self.assertTrue(capture_derived_report_policy(command, profile=CampaignProfile.BOOTSTRAP_VERIFIER))
        self.assertIs(capture_derived_report_receipt_type(
            command, profile=CampaignProfile.BOOTSTRAP_VERIFIER), ReceiptType.INSTALLED_SOURCE_EQUALITY)
        context = replace(self.fixture._context(), expected_command_id=command,
                          capture_derived_execution=True)
        self.assertEqual([issue.code for issue in validate_receipt({"command_id": command}, context=context)],
                         ["capture-admission-required"])

    def test_bootstrap_command_coverage_uses_exact_installed_roles(self):
        from Scripts.reconstruction_gate_f.command_catalog import command_templates
        from Scripts.reconstruction_gate_f.gate_evaluator import _command_receipt_role_matches
        from Scripts.reconstruction_gate_f.installed_capture_adapter import ROLES
        from Scripts.reconstruction_gate_f.executor_request_adapter import capture_derived_report_policy
        self.assertEqual(ROLES, INSTALLED_PRODUCER_ROLES)
        templates = {item.command_id: item for item in command_templates(profile=CampaignProfile.BOOTSTRAP_VERIFIER)}
        for command, role in INSTALLED_PRODUCER_ROLES.items():
            layer = templates[command].evidence_layer
            self.assertFalse(capture_derived_report_policy(command))
            self.assertTrue(_command_receipt_role_matches(command, layer, role,
                                                 campaign_profile=CampaignProfile.BOOTSTRAP_VERIFIER))
            for other_role in ReceiptType:
                if other_role is not role:
                    self.assertFalse(_command_receipt_role_matches(command, layer, other_role,
                        campaign_profile=CampaignProfile.BOOTSTRAP_VERIFIER))

    def test_preflight_completion_cannot_discharge_node_accessibility_authority(self):
        from Scripts.reconstruction_gate_f.evidence_model import (
            EvidenceArtifactOutput, EvidenceReceiptOutput, ValidatedEvidenceClaim,
        )
        from Scripts.reconstruction_gate_f.gate_evaluator import (
            _command_coverage_issues, _required_output_issues,
        )
        from Scripts.reconstruction_gate_f.prerequisite_dag import (
            compile_prerequisite_dag, lane_c_command_authorities,
        )
        from Scripts.reconstruction_gate_f.schema import EvidenceLayer, EvidenceStatus
        from Scripts.reconstruction_gate_f.tests.test_prerequisite_dag import contract_for_specs

        # Semantic-stage projections exercise the real compiled node and role
        # dispatch. They do not claim public capture or receipt admission.
        profile = CampaignProfile.BOOTSTRAP_VERIFIER
        layer = EvidenceLayer.INSTALLED_ACCESSIBILITY
        contract = contract_for_specs()
        dag, issues = compile_prerequisite_dag(contract)
        self.assertEqual(issues, ())
        node = dag.by_id()["exact-head-full-tests"]
        context = self.fixture._context()
        preflight = EvidenceReceiptOutput(
            receipt_id=node.spec.receipt_output_ids[0],
            canonical_sha256=node.authority.receipt_sha256,
            qualification_run=context.expected_qualification_run,
            receipt_type=ReceiptType.COMMAND_EXECUTION,
            command_id="installed.xcuitest-preflight",
            requirement_id=node.authority.identity_sha256,
            scenario_id="installed.accessibility",
            command_plan_sha256=context.expected_command_plan_sha256,
            command_record_sha256=context.expected_command_record_sha256,
            command_authority=context.expected_command_authority,
            execution_interval=context.expected_execution_interval,
            qualified_premerge_authority_sha256=None,
            constituent_selector_ids=(), runtime_resolution=None,
        )
        accessibility_elsewhere = replace(
            preflight, receipt_id="receipt-accessibility-elsewhere",
            command_id="installed.accessibility-semantics",
            receipt_type=ReceiptType.INSTALLED_ACCESSIBILITY,
            requirement_id="different-prerequisite-identity",
        )
        artifact = EvidenceArtifactOutput(
            artifact_id=node.spec.artifact_output_ids[0],
            sha256="1" * 64, producer_receipt_id=preflight.receipt_id,
            command_output="stdout-json:xcuitest-preflight",
        )
        claim = ValidatedEvidenceClaim(
            layer=layer, status=EvidenceStatus.PASSED, candidate_identity_sha256=None,
            receipt_outputs=(preflight, accessibility_elsewhere),
            artifact_outputs=(artifact,), artifact_kinds=(), authorized_skip_ids=(),
            failed_constituent_count=0,
        )
        catalog = {item.command_id: item for item in lane_c_command_authorities(profile=profile)}
        focused_catalog = {item: catalog[item] for item in (
            "installed.xcuitest-preflight", "installed.accessibility-semantics")}
        # Both commands completed in their legitimate receipt roles. The
        # unrelated semantic receipt cannot authorize the node-bound preflight.
        self.assertEqual(_command_coverage_issues(
            (claim,), focused_catalog, (layer,), campaign_profile=profile), ())
        issues = _required_output_issues(
            dag, (claim,), (node.spec.node_id,), catalog, campaign_profile=profile)
        self.assertIn("prerequisite-receipt-type-mismatch", {item.code for item in issues})
        self.assertTrue(any(item.code == "missing-node-required-layer-receipt"
                            and item.message.endswith(layer.value) for item in issues))

        bound_accessibility = replace(
            preflight, command_id="installed.accessibility-semantics",
            receipt_type=ReceiptType.INSTALLED_ACCESSIBILITY,
        )
        accepted = replace(claim, receipt_outputs=(bound_accessibility, accessibility_elsewhere))
        issues = _required_output_issues(
            dag, (accepted,), (node.spec.node_id,), catalog, campaign_profile=profile)
        self.assertNotIn("prerequisite-receipt-type-mismatch", {item.code for item in issues})
        self.assertFalse(any(item.code == "missing-node-required-layer-receipt"
                             and item.message.endswith(layer.value) for item in issues))

    def _historical(self):
        fixture = physical_fixture.GateFExecutorReceiptTests(methodName="runTest")
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        return fixture, fixture._t10c_current_source_request()

    def test_historical_schema_one_stays_failed_and_publicly_requires_admission(self):
        fixture, request = self._historical()
        receipt, context = _validate_legacy_physical_evidence(request, artifact_root=fixture.root,
            qualification_run_authority=physical_fixture.QUALIFICATION_RUN)
        self.assertEqual(receipt["evidence_status"], "failed")
        self.assertEqual(receipt["authority"]["unresolved_blocking_count"], 3)
        self.assertEqual(_validate_physical_receipt(receipt, context=context), ())
        self.assertEqual([item.code for item in validate_receipt(receipt, context=context)],
                         ["external-admission-required"])

    def test_schema_two_cannot_enter_physical_parser_without_typed_semantics(self):
        fixture, request = self._historical()
        artifact = next(item for item in request["artifacts"]
                        if item["relative_path"] == "FINDING_ADJUDICATION.json")
        import json
        path = fixture.root / artifact["relative_path"]
        value = json.loads(path.read_bytes())
        value["schemaVersion"] = 2
        payload = canonical_bytes(value) + b"\n"
        path.write_bytes(payload)
        artifact.update(byte_count=len(payload), sha256=hashlib.sha256(payload).hexdigest())
        with self.assertRaisesRegex(ReceiptEmissionError, "requires independently retained closure admission"):
            _validate_legacy_physical_evidence(request, artifact_root=fixture.root,
                qualification_run_authority=physical_fixture.QUALIFICATION_RUN)

    def test_persisted_external_completion_cannot_supply_its_own_admission(self):
        from Scripts.reconstruction_gate_f.operator_run import OperatorRun, OperatorError
        from Scripts.reconstruction_gate_f.canonical_json import canonical_sha256
        from Scripts.reconstruction_gate_f.tests import parsed_candidate
        command = "review.independent"
        manifest = {"fixture": "completion-rejection-only"}
        (self.fixture.root / "run.json").write_bytes(canonical_bytes(manifest))
        # A deliberately minimal local plan tests only persistence rejection.
        # No favorable external validation or plan qualification is asserted.
        record = SimpleNamespace(command_id=command, prerequisite_ids=())
        run = OperatorRun(self.fixture.root, "run.json", canonical_sha256(manifest),
            parsed_candidate(), SimpleNamespace(plan=SimpleNamespace(commands=(record,))),
            self.fixture.qualification_run, {command: {}})
        persisted = {"schema_version": 3, "manifest_sha256": run.manifest_sha256,
                     "command_id": command, "receipt": {"evidence_status": "passed"}}
        path = self.fixture.root / (command + ".completed.json")
        path.write_bytes(canonical_bytes(persisted))
        for stored in (persisted, dict(persisted, external_admission={"passed": True})):
            path.write_bytes(canonical_bytes(stored))
            with self.assertRaises(OperatorError):
                run.completed_result(command)
        with self.assertRaisesRegex(OperatorError, "unique typed"):
            run.with_external_admissions(({"command_id": command, "passed": True},))
        self.assertEqual(run.external_admissions, ())

    def test_completion_publication_is_create_only_and_no_follow(self):
        from Scripts.reconstruction_gate_f.operator_run import _publish, _read
        root = self.fixture.root
        _publish(root, "external.completed.json", b"{\"passed\":false}")
        with self.assertRaises(FileExistsError):
            _publish(root, "external.completed.json", b"{\"passed\":true}")
        self.assertEqual(_read(root, "external.completed.json", 1024), b"{\"passed\":false}")
        (root / "alias.completed.json").symlink_to(root / "external.completed.json")
        with self.assertRaises(OSError):
            _publish(root, "alias.completed.json", b"{\"passed\":true}")
        (root / "external.completed.json").write_bytes(b"changed after publication")
        self.assertNotEqual(_read(root, "external.completed.json", 1024), b"{\"passed\":false}")


if __name__ == "__main__":
    unittest.main()
