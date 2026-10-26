"""Synthetic persisted operator admission; no real owner commands are run."""
import contextlib
from dataclasses import replace
import io
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from Scripts.reconstruction_gate_f import operator_run as operator
from Scripts.reconstruction_gate_f import prerequisite_dag
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes, canonical_sha256, to_primitive
from Scripts.reconstruction_gate_f.tests import candidate_mapping
from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs


def metadata(command_id="source.create-sealed-export"):
    return dict(receipt_id="receipt-source", requirement_id="source-governance",
                qualification_phase="premerge", receipt_type="command-execution",
                artifact_root_id="run-artifacts", execution_report_artifact_id="execution-report",
                owner_artifacts=[], executor=dict(executor_id="local-operator", host="localhost",
                platform="macos", architecture="arm64", os_version="27.2"),
                constituents=[], authority=None, qualified_premerge_authority_sha256=None)


class ExternalQualifiedSealPolicyTests(unittest.TestCase):
    """Metadata policy only; these values are not campaign qualification proof.

    Public external admission validates the full authority before this policy
    runs. The adapter's physical/source tests cover that separate boundary.
    """

    def setUp(self):
        from Scripts.reconstruction_gate_f.gate_evaluator import QualifiedPremergeAuthority
        fields = dict(schema_version=2, qualification_run_id="policy-run",
            qualification_run_nonce="a" * 64, prospective_candidate_identity_sha256="b" * 64,
            source_contract_sha256="c" * 64, prerequisite_dag_sha256="d" * 64,
            evidence_partial_order_sha256="e" * 64, evidence_root_sha256="f" * 64,
            receipt_digests=(("review-receipt", "1" * 64),), command_plan_sha256="2" * 64,
            decision_status="qualified-premerge")
        self.authority = QualifiedPremergeAuthority(**fields, canonical_sha256=canonical_sha256(fields))

    def check(self, command, configured=None, *, authority=None, observed=None):
        authority = self.authority if authority is None else authority
        observed = self.authority.canonical_sha256 if observed is None else observed
        operator._check_external_qualified_seal(command, configured,
            {"qualified_premerge_authority_sha256": observed},
            SimpleNamespace(qualified_premerge_authority=authority))

    def test_empty_frozen_seal_can_bind_validated_typed_merge_authority(self):
        for command in ("merge.prospective-tree", "postmerge.exact-tree-proof"):
            with self.subTest(command=command):
                self.check(command)

    def test_explicit_frozen_seal_remains_exact(self):
        for command in ("merge.prospective-tree", "postmerge.exact-tree-proof"):
            with self.subTest(command=command):
                self.check(command, self.authority.canonical_sha256)
                with self.assertRaisesRegex(operator.OperatorError, "differs from operator metadata"):
                    self.check(command, "9" * 64)

    def test_late_binding_is_closed_to_exact_two_merge_commands(self):
        for command in ("review.independent", "review.decompiler-soundness",
                        "review.t10c-current-source", "merge.prospective-tree-extra",
                        "postmerge.exact-tree-proof-extra", "source.create-sealed-export"):
            with self.subTest(command=command), self.assertRaises(operator.OperatorError):
                self.check(command)

    def test_dictionary_or_digest_only_authority_is_not_late_binding(self):
        for authority in (to_primitive(self.authority), self.authority.canonical_sha256,
                          SimpleNamespace(canonical_sha256=self.authority.canonical_sha256)):
            with self.subTest(authority=type(authority)), self.assertRaises(operator.OperatorError):
                self.check("merge.prospective-tree", authority=authority)

    def test_request_seal_must_equal_retained_typed_authority(self):
        for command in ("merge.prospective-tree", "postmerge.exact-tree-proof"):
            with self.subTest(command=command), self.assertRaises(operator.OperatorError):
                self.check(command, observed="9" * 64)

    def test_unsealed_initial_observation_preserves_exact_none_match(self):
        operator._check_external_qualified_seal("merge.prospective-tree", None,
            {"qualified_premerge_authority_sha256": None},
            SimpleNamespace(qualified_premerge_authority=None))

    def test_fixed_seal_cannot_be_replaced_by_unsealed_request(self):
        with self.assertRaises(operator.OperatorError):
            operator._check_external_qualified_seal("merge.prospective-tree", self.authority.canonical_sha256,
                {"qualified_premerge_authority_sha256": None},
                SimpleNamespace(qualified_premerge_authority=self.authority))

    def test_late_seal_does_not_bypass_real_full_plan_admission(self):
        from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile
        from Scripts.reconstruction_gate_f.command_execution import ExecutionAdmission
        from Scripts.reconstruction_gate_f.external_authority_adapter import ExternalAuthorityAdmission
        from Scripts.reconstruction_gate_f.executor_receipt import ReceiptEmissionError
        from Scripts.reconstruction_gate_f.receipt_validator import QualificationRunAuthority
        from Scripts.reconstruction_gate_f.schema import QualificationPhase, ReceiptType
        from Scripts.reconstruction_gate_f.tests import parsed_candidate
        candidate = parsed_candidate()
        root = Path(__file__).resolve().parent
        # Real adapter admission must reject this incomplete plan before the
        # late-seal metadata policy is reached. No validator is patched.
        integrated = SimpleNamespace(inputs={})
        qualification = QualificationRunAuthority("policy-run", "a" * 64)
        execution = ExecutionAdmission(candidate, integrated, qualification,
            candidate.source.commit, candidate.source.tree, ())
        admission = ExternalAuthorityAdmission(execution, CampaignProfile.EXISTING,
            "merge.prospective-tree", "merge.prospective-tree", root, "receipt-merge",
            "merge-authority", QualificationPhase.PREMERGE, ReceiptType.PROSPECTIVE_MERGE_TREE,
            "root", "report", (), (), {}, (), (), self.authority, None)
        configured = {key: to_primitive(getattr(admission, key)) for key in (
            "receipt_id", "requirement_id", "qualification_phase", "receipt_type",
            "artifact_root_id", "execution_report_artifact_id", "owner_artifacts", "executor")}
        configured["qualified_premerge_authority_sha256"] = None
        run = operator.OperatorRun(root, "unused.json", "0" * 64, candidate, integrated,
            qualification, {admission.command_id: configured}, external_admissions=(admission,))
        with self.assertRaisesRegex(ReceiptEmissionError, "external full plan admission failed"):
            run._external_result(admission.command_id, execution)


class OperatorRunTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        inputs = command_inputs()
        self.manifest = dict(schema_version=1, candidate_identity=candidate_mapping(),
                             repository_root=str(ROOT), command_inputs=inputs,
                             qualification_run=dict(run_id=inputs["qualification_run_id"],
                                                    nonce=inputs["qualification_run_nonce"]),
                             commands={"source.create-sealed-export": metadata()})
        # Only test candidate's synthetic Git identity is isolated. Actual full
        # scenario/command compilation and DTO validation run on every load.
        self.patch = patch.object(prerequisite_dag, "_repository_source_issues", return_value=())
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def load(self):
        (self.root / "run.json").write_bytes(canonical_bytes(self.manifest))
        return operator.load_run(self.root)

    def test_load_recompiles_complete_plan_not_caller_plan(self):
        run = self.load()
        self.assertGreater(len(run.integrated_plan_input.plan.commands), 30)
        admission = run.admission("source.create-sealed-export")
        self.assertEqual(admission.admitted_predecessors, ())
        self.assertEqual(admission.qualification_run.run_id, self.manifest["qualification_run"]["run_id"])

    def bootstrap_manifest(self):
        from Scripts.reconstruction_gate_f.tests.bootstrap_repository_fixture import bootstrap_repository
        repository, inputs = bootstrap_repository(self)
        for name in ("operator_run.py", "operator_cli.py"):
            (repository / "Scripts/reconstruction_gate_f" / name).write_bytes(
                (ROOT / "Scripts/reconstruction_gate_f" / name).read_bytes())
        self.manifest.update(schema_version=3, campaign_profile="bootstrap-verifier-campaign-v1",
                             repository_root=str(repository), command_inputs=inputs,
                             commands={"qualification.verify-bootstrap-fullsuite": metadata()})

    def test_schema_three_selects_independent_profile_and_exact_verifier_graph(self):
        from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile
        self.bootstrap_manifest()
        run = self.load()
        self.assertIs(run.campaign_profile, CampaignProfile.BOOTSTRAP_VERIFIER)
        commands = {item.command_id: item for item in run.integrated_plan_input.plan.commands}
        self.assertNotIn("xcode.full-coretests", commands)
        self.assertNotIn("release.build", commands)
        self.assertEqual(len(commands["qualification.verify-bootstrap-fullsuite"].prerequisite_ids), 14)
        self.assertIn("qualification.verify-bootstrap-fullsuite",
                      commands["qualification.verify-bootstrap-products"].prerequisite_ids)

    def test_profile_selection_rejects_downgrade_partial_inputs_and_old_schema(self):
        self.bootstrap_manifest()
        self.manifest["campaign_profile"] = "existing-command-campaign-v1"
        with self.assertRaises(ValueError):
            self.load()
        self.manifest["campaign_profile"] = "bootstrap-verifier-campaign-v1"
        del self.manifest["command_inputs"]["bootstrap_products_artifact_root"]
        with self.assertRaises(ValueError):
            self.load()
        self.bootstrap_manifest()
        self.manifest.update(schema_version=2)
        del self.manifest["campaign_profile"]
        with self.assertRaises(ValueError):
            self.load()

    def test_verifier_projection_bypasses_only_qualifier_specific_adapter(self):
        from Scripts.reconstruction_gate_f.executor_request_adapter import ExecutorReceiptAdmission, OwnerArtifactSource
        from Scripts.reconstruction_gate_f.schema import ArtifactKind, QualificationPhase, ReceiptType
        for command in ("qualification.verify-bootstrap-fullsuite", "qualification.verify-bootstrap-products"):
            admission = ExecutorReceiptAdmission(SimpleNamespace(command_id=command), self.root,
                "receipt-verifier", "requirement", QualificationPhase.PREMERGE, ReceiptType.TEST_RESULT,
                "root", "report", (OwnerArtifactSource("projection", "owned.json", ArtifactKind.XCRESULT,
                "application/json", "artifact:stdout-path:MACSCOPE_BOOTSTRAP_FULLSUITE_XCRESULT_PROJECTION"),), {})
            self.assertIs(operator.OperatorRun._projected_admission(admission, publish=True), admission)
            self.assertIs(operator.OperatorRun._projected_admission(admission,
                          to_primitive(admission.owner_artifacts)), admission)
            altered = to_primitive(admission.owner_artifacts)
            altered[0]["relative_path"] = "substitute.json"
            with self.assertRaises(ValueError):
                operator.OperatorRun._projected_admission(admission, altered)
        admission = replace(admission, capture=SimpleNamespace(command_id="qualification.verify-bootstrap-fullsuite-extra"))
        with self.assertRaises(ValueError):
            operator.OperatorRun._projected_admission(admission, publish=True)

    def test_closed_manifest_rejects_injected_plan_and_argv(self):
        for key in ("argv", "command_plan_sha256", "templates", "admitted_predecessors"):
            with self.subTest(key=key):
                self.manifest[key] = []
                with self.assertRaises(ValueError):
                    self.load()
                del self.manifest[key]

    def test_mutated_manifest_rejected_on_repeat_admission(self):
        run = self.load()
        self.manifest["commands"]["source.create-sealed-export"]["receipt_id"] = "replacement-receipt"
        (self.root / "run.json").write_bytes(canonical_bytes(self.manifest))
        with self.assertRaisesRegex(operator.OperatorError, "changed"):
            run.admission("source.create-sealed-export")

    def test_run_mismatch_rejected(self):
        self.manifest["qualification_run"]["nonce"] = "a" * 64
        with self.assertRaisesRegex(operator.OperatorError, "compiled run"):
            self.load()

    def test_former_dynamic_hash_input_rejected(self):
        self.manifest["command_inputs"]["installed_task10_predecessor_observations_sha256"] = "a" * 64
        with self.assertRaises(ValueError):
            self.load()

    def test_unknown_command_rejected(self):
        self.manifest["commands"]["invented.command"] = metadata()
        with self.assertRaisesRegex(operator.OperatorError, "unknown"):
            self.load()

    def test_unsafe_owner_path_rejected(self):
        self.manifest["commands"]["source.create-sealed-export"]["owner_artifacts"] = [dict(
            artifact_id="log", relative_path="../outside", kind="json", media_type="application/json",
            command_output="log:executor-captured:source-export-create-stdout-stderr")]
        with self.assertRaisesRegex(operator.OperatorError, "unsafe"):
            self.load()

    def test_captured_locator_requires_versioned_manifest(self):
        self.manifest["commands"]["source.create-sealed-export"]["owner_artifacts"] = [dict(
            artifact_id="result", relative_path=operator.CAPTURED_OUTPUT_LOCATOR, kind="json",
            media_type="application/json", command_output="artifact:stdout-path:RESULT")]
        with self.assertRaisesRegex(operator.OperatorError, "schema two"):
            self.load()

    def test_missing_physical_predecessor_prevents_admission(self):
        self.manifest["commands"]["source.verify-sealed-export"] = dict(metadata(), receipt_id="receipt-verify")
        run = self.load()
        with self.assertRaises(FileNotFoundError):
            run.admission("source.verify-sealed-export")

    def test_duplicate_receipt_id_rejected_across_run(self):
        self.manifest["commands"]["source.verify-sealed-export"] = metadata()
        with self.assertRaisesRegex(operator.OperatorError, "unique across"):
            self.load()

    def test_frozen_release_outputs_resolve_app_and_provenance_with_exact_kinds(self):
        from Scripts.reconstruction_gate_f import executor_request_adapter as adapter
        from Scripts.reconstruction_gate_f.schema import ArtifactKind
        # Use the actual frozen, fully compiled Release record, not a reduced
        # hand-written output catalogue. No app or native command is executed.
        plan = self.load().integrated_plan_input.plan
        record = next(item for item in plan.commands if item.command_id == "release.build")
        sources = []
        for index, declaration in enumerate(record.generated_artifacts):
            output = "artifact:" + declaration
            kind = ArtifactKind.APP_BUNDLE if output == operator.RELEASE_APP_OUTPUT else ArtifactKind.JSON
            sources.append(dict(artifact_id="release-output-" + str(index),
                                relative_path=operator.CAPTURED_OUTPUT_LOCATOR, kind=kind.value,
                                media_type="application/json", command_output=output))
        for index, declaration in enumerate(record.generated_logs):
            sources.append(dict(artifact_id="release-log-" + str(index), relative_path="release.log",
                                kind=ArtifactKind.JSON.value, media_type="application/json",
                                command_output="log:" + declaration))
        meta = dict(metadata(), receipt_type="release-build", owner_artifacts=sources)
        self.manifest.update(schema_version=2, commands={"release.build": meta})
        run = self.load()
        run._preflight_outputs("release.build")
        with tempfile.TemporaryDirectory(prefix="run.", dir=self.root) as temporary:
            directory = Path(temporary).resolve()
            receipt = directory / "qualification-receipt.json"
            receipt.write_bytes(b"{}")
            app = directory / "DerivedData/Build/Products/Release/MacScope.app"
            provenance = app / operator.RELEASE_PROVENANCE_SUFFIX
            provenance.parent.mkdir(parents=True)
            provenance.write_bytes(b"{}")
            streams = dict(stdout=("MACSCOPE_QUALIFICATION_RECEIPT=" + str(receipt) + "\n").encode(), stderr=b"")
            captured = (SimpleNamespace(record=record), {}, streams, "capture.json", 0, "a" * 64)
            with patch.object(adapter, "_capture", return_value=captured):
                admission = run.receipt_admission(SimpleNamespace(command_id="release.build"))
                resolved = {item.command_output: item for item in admission.owner_artifacts}
                self.assertEqual(self.root / resolved[operator.RELEASE_APP_OUTPUT].relative_path, app)
                self.assertEqual(resolved[operator.RELEASE_APP_OUTPUT].kind, ArtifactKind.APP_BUNDLE)
                self.assertEqual(self.root / resolved[operator.RELEASE_PROVENANCE_OUTPUT].relative_path, provenance)
                self.assertEqual(resolved[operator.RELEASE_PROVENANCE_OUTPUT].kind, ArtifactKind.JSON)
                # The JSON child can never be substituted with a directory, an
                # alias, or a non-governed suffix, even under the same app root.
                provenance.unlink()
                provenance.mkdir()
                with self.assertRaisesRegex(operator.OperatorError, "ordinary canonical file"):
                    run.receipt_admission(SimpleNamespace(command_id="release.build"))
            for output, wrong_kind in ((operator.RELEASE_APP_OUTPUT, ArtifactKind.JSON.value),
                                       (operator.RELEASE_PROVENANCE_OUTPUT, ArtifactKind.APP_BUNDLE.value)):
                selected = next(item for item in sources if item["command_output"] == output)
                original_kind = selected["kind"]
                selected["kind"] = wrong_kind
                # Reload makes the changed metadata part of explicit operator
                # configuration; the frozen Release policy still refuses it.
                with self.subTest(output=output), self.assertRaisesRegex(operator.OperatorError, "governed artifact kind"):
                    self.load()._preflight_outputs("release.build")
                selected["kind"] = original_kind
            selected = next(item for item in sources if item["command_output"] == operator.RELEASE_PROVENANCE_OUTPUT)
            selected["command_output"] += ".other"
            with self.assertRaisesRegex(operator.OperatorError, "output closure"):
                self.load()._preflight_outputs("release.build")

    def test_wrong_output_closure_prevents_launch(self):
        run = self.load()
        with patch.object(operator, "admit_command"), patch.object(operator, "execute_admitted_command") as execute:
            with self.assertRaisesRegex(operator.OperatorError, "output closure"):
                run.execute("source.create-sealed-export", "source.create-sealed-export", threading.Event())
        execute.assert_not_called()

    def test_completed_record_prevents_launch_even_without_started_record(self):
        run = self.load()
        (self.root / "source.create-sealed-export.completed.json").write_bytes(b"{}")
        with patch.object(operator, "execute_admitted_command") as execute:
            with self.assertRaisesRegex(operator.OperatorError, "not repeated"):
                run.execute("source.create-sealed-export", "source.create-sealed-export", threading.Event())
        execute.assert_not_called()

    def test_create_only_publication_and_symlink_rejection(self):
        operator._publish(self.root, "receipt.json", b"first")
        with self.assertRaises(FileExistsError):
            operator._publish(self.root, "receipt.json", b"replacement")
        self.assertEqual((self.root / "receipt.json").read_bytes(), b"first")
        (self.root / "link").symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError):
            operator._publish(self.root, "link/escape.json", b"bad")
        self.assertFalse((self.root / "escape.json").exists())

    def test_descriptor_read_rejects_alias_traversal_and_size(self):
        (self.root / "bytes").write_bytes(b"1234")
        (self.root / "alias").symlink_to(self.root / "bytes")
        for name, size in (("../bytes", 4), ("alias", 4), ("bytes", 2)):
            with self.subTest(name=name), self.assertRaises((OSError, ValueError)):
                operator._read(self.root, name, size)

    def test_boolean_schema_version_rejected(self):
        self.manifest["schema_version"] = True
        with self.assertRaisesRegex(operator.OperatorError, "schema"):
            self.load()

    def test_recursive_predecessors_are_revalidated_once_per_admission(self):
        run = self.load()
        self.manifest["commands"]["source.verify-sealed-export"] = dict(metadata(), receipt_id="receipt-verify")
        run = self.load()
        receipt = dict(receipt_id="source-create", canonical_sha256="a" * 64)
        with patch.object(operator.OperatorRun, "completed", return_value=receipt) as completed:
            first = run.admission("source.verify-sealed-export")
            second = run.admission("source.verify-sealed-export")
        self.assertEqual(completed.call_count, 2)
        self.assertEqual(first.admitted_predecessors, second.admitted_predecessors)
        self.assertEqual(first.admitted_predecessors[0].canonical_sha256, "a" * 64)


class PersistedCaptureTests(unittest.TestCase):
    def setUp(self):
        from Scripts.tests.test_gate_f_executor_request_adapter import CapturedReceiptTests
        from Scripts.reconstruction_gate_f.executor_request_adapter import build_executor_request, emit_captured_receipt
        self.fixture = CapturedReceiptTests(methodName="runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        admission = self.fixture.admission
        execution = admission.capture.admission
        self.root = admission.artifact_root
        meta = dict(receipt_id=admission.receipt_id, requirement_id=admission.requirement_id,
                    qualification_phase=admission.qualification_phase.value,
                    receipt_type=admission.receipt_type.value, artifact_root_id=admission.artifact_root_id,
                    execution_report_artifact_id=admission.execution_report_artifact_id,
                    owner_artifacts=[dict(vars(item), kind=item.kind.value) for item in admission.owner_artifacts],
                    executor=dict(admission.executor), constituents=list(admission.constituents),
                    authority=admission.authority,
                    qualified_premerge_authority_sha256=admission.qualified_premerge_authority_sha256)
        self.command = admission.capture.command_id
        manifest = {"synthetic_fixture_only": True}
        (self.root / "run.json").write_bytes(canonical_bytes(manifest))
        self.run = operator.OperatorRun(self.root, "run.json", canonical_sha256(manifest),
                    execution.candidate, execution.integrated_plan_input, execution.qualification_run,
                    {self.command: meta})
        # Predecessor transport is isolated here, while the real capture,
        # compiler, output mapping and specialized report validators all run.
        self.admission_patch = patch.object(operator.OperatorRun, "admission", return_value=execution)
        self.admission_patch.start()
        self.addCleanup(self.admission_patch.stop)
        request = build_executor_request(admission)
        receipt, _ = emit_captured_receipt(request, artifact_root=self.root,
                    qualification_run_authority=execution.qualification_run, admission=admission)
        self.receipt = receipt
        self.completion = dict(schema_version=1, manifest_sha256=self.run.manifest_sha256,
                    capture_path=admission.capture.capture_path.relative_to(self.root).as_posix(), receipt=receipt)
        self.path = self.root / (self.command + ".completed.json")
        self.path.write_bytes(canonical_bytes(self.completion))

    def test_fresh_physical_revalidation_of_persisted_capture(self):
        self.assertEqual(self.run.completed(self.command), self.receipt)

    def test_completed_result_derives_request_and_admission_without_writes(self):
        from Scripts.reconstruction_gate_f.executor_request_adapter import build_executor_request
        before = {path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()}
        result = self.run.completed_result(self.command)
        self.assertEqual(result.receipt, self.receipt)
        self.assertEqual(result.request, build_executor_request(result.admission))
        self.assertEqual(result.admission.capture.admission, self.fixture.admission.capture.admission)
        self.assertEqual(before, {path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()})

    def test_mutated_receipt_is_not_a_new_authority(self):
        self.completion["receipt"] = dict(self.receipt, receipt_id="forged")
        self.path.write_bytes(canonical_bytes(self.completion))
        with self.assertRaisesRegex(operator.OperatorError, "fresh physical"):
            self.run.completed(self.command)

    def test_changed_capture_report_or_manifest_binding_rejected(self):
        self.completion["manifest_sha256"] = "f" * 64
        self.path.write_bytes(canonical_bytes(self.completion))
        with self.assertRaisesRegex(operator.OperatorError, "another static run"):
            self.run.completed(self.command)

    def test_changed_physical_owner_report_is_rejected(self):
        artifact = next(item for item in self.fixture.admission.owner_artifacts
                        if item.artifact_id == self.fixture.admission.execution_report_artifact_id)
        (self.root / artifact.relative_path).write_bytes(b"{}")
        with self.assertRaises(ValueError):
            self.run.completed(self.command)

    def test_schema_two_replays_without_adopting_persisted_artifact_authority(self):
        self.completion.update(schema_version=2,
                               owner_artifacts=to_primitive(self.fixture.admission.owner_artifacts))
        self.path.write_bytes(canonical_bytes(self.completion))
        self.assertEqual(self.run.completed(self.command), self.receipt)
        self.completion["owner_artifacts"][0]["relative_path"] = "arbitrary-substitute.json"
        self.path.write_bytes(canonical_bytes(self.completion))
        with self.assertRaisesRegex(operator.OperatorError, "original manifest"):
            self.run.completed(self.command)

    def test_projection_mapping_is_derived_without_reading_or_writing_directory(self):
        from Scripts.reconstruction_gate_f.schema import ArtifactKind
        from Scripts.reconstruction_gate_f import qualification_receipt_adapter as projection
        original = self.fixture.admission
        directory = replace(original.owner_artifacts[0], kind=ArtifactKind.XCRESULT,
                            command_output="artifact:stdout-path:MACSCOPE_TEST_RESULTS",
                            relative_path="original-results.xcresult")
        original = replace(original, owner_artifacts=(directory,) + original.owner_artifacts[1:])
        sources = projection.qualification_artifact_projection_sources(original)
        with patch.object(projection, "publish_qualification_artifact_projections") as publish:
            admitted = self.run._projected_admission(original, to_primitive(sources))
        publish.assert_not_called()
        self.assertEqual(admitted, replace(original, owner_artifacts=sources))
        self.assertIs(admitted.capture, original.capture)
        for key, value in (("artifact_id", "substitute"), ("kind", "json"),
                           ("relative_path", "arbitrary.json"), ("command_output", "artifact:other")):
            altered = to_primitive(sources)
            altered[0][key] = value
            with self.subTest(field=key), self.assertRaisesRegex(operator.OperatorError, "original manifest"):
                self.run._projected_admission(original, altered)

    def test_projection_publisher_cannot_change_capture_or_receipt_admission(self):
        from Scripts.reconstruction_gate_f.schema import ArtifactKind
        from Scripts.reconstruction_gate_f import qualification_receipt_adapter as projection
        original = self.fixture.admission
        directory = replace(original.owner_artifacts[0], kind=ArtifactKind.XCRESULT)
        original = replace(original, owner_artifacts=(directory,) + original.owner_artifacts[1:])
        with patch.object(projection, "publish_qualification_artifact_projections",
                          return_value=replace(original, receipt_id="different-receipt")):
            with self.assertRaisesRegex(operator.OperatorError, "changed independent admission"):
                self.run._projected_admission(original, publish=True)

    def test_captured_locator_rejects_duplicate_relative_aliased_and_external_paths(self):
        from Scripts.reconstruction_gate_f import executor_request_adapter as adapter
        original = self.fixture.admission
        source = next(item for item in original.owner_artifacts
                      if item.command_output.startswith("artifact:stdout-path:"))
        admission = replace(original, owner_artifacts=tuple(
            replace(item, relative_path=operator.CAPTURED_OUTPUT_LOCATOR)
            if item == source else item for item in original.owner_artifacts))
        admitted = adapter._capture(admission)
        marker = source.command_output.removeprefix("artifact:stdout-path:")
        prefix = marker + "="
        actual = self.root / source.relative_path
        alias = self.root / "captured-alias"
        alias.symlink_to(actual)
        with tempfile.TemporaryDirectory() as external:
            outside = Path(external).resolve() / "result.json"
            outside.write_bytes(b"{}")
            variants = ((str(actual) + "\n" + prefix + str(actual)), "relative.json",
                        str(alias), str(outside))
            for value in variants:
                streams = dict(admitted[2], stdout=(prefix + value + "\n").encode())
                # Isolate only observed stream bytes for negative parser tests;
                # production always obtains them from independent _capture.
                with self.subTest(path=value), patch.object(adapter, "_capture",
                        return_value=admitted[:2] + (streams,) + admitted[3:]):
                    with self.assertRaises((ValueError, OSError)):
                        self.run._captured_output_admission(admission)
        multiple = replace(original, owner_artifacts=tuple(
            replace(item, relative_path=operator.CAPTURED_OUTPUT_LOCATOR)
            if item.command_output.startswith("artifact:stdout-path:") else item
            for item in original.owner_artifacts))
        same_path = "".join(item.command_output.removeprefix("artifact:stdout-path:") + "=" + str(actual) + "\n"
                            for item in multiple.owner_artifacts
                            if item.command_output.startswith("artifact:stdout-path:"))
        streams = dict(admitted[2], stdout=same_path.encode())
        with patch.object(adapter, "_capture", return_value=admitted[:2] + (streams,) + admitted[3:]):
            with self.assertRaisesRegex(operator.OperatorError, "duplicate physical"):
                self.run._captured_output_admission(multiple)

    def test_cli_dispatches_one_command_and_replays_real_validators(self):
        from Scripts.reconstruction_gate_f import operator_cli
        from Scripts.reconstruction_gate_f.schema import candidate_to_mapping
        execution = self.fixture.admission.capture.admission
        manifest = dict(schema_version=2, candidate_identity=candidate_to_mapping(execution.candidate),
                        repository_root=str(execution.integrated_plan_input.repository_root),
                        command_inputs=dict(execution.integrated_plan_input.inputs),
                        qualification_run=dict(run_id=execution.qualification_run.run_id,
                                               nonce=execution.qualification_run.nonce),
                        commands=self.run.commands)
        # No random run-root pathname is prespecified in the manifest. Resolve
        # each governed stdout path from the independently admitted capture.
        for item in manifest["commands"][self.command]["owner_artifacts"]:
            if item["command_output"].startswith("artifact:stdout-path:"):
                item["relative_path"] = operator.CAPTURED_OUTPUT_LOCATOR
        (self.root / "run.json").write_bytes(canonical_bytes(manifest))
        self.path.unlink()
        for artifact in self.fixture.admission.owner_artifacts:
            if artifact.command_output.startswith("log:executor-captured:"):
                (self.root / artifact.relative_path).unlink()
        # Only live command transport/predecessor fixture identity is isolated;
        # CLI parsing, closed loader/full compiler, publication, capture binding,
        # specialized physical owner validation and repeated replay are real.
        args = ["--run-root", str(self.root), "--command-id", self.command,
                "--scenario-id", self.fixture.admission.capture.scenario_id]
        with patch.object(operator, "execute_admitted_command", return_value=self.fixture.admission.capture) as execute, \
             contextlib.redirect_stdout(io.StringIO()) as output, contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(operator_cli.main(args), 0, errors.getvalue())
            self.assertEqual(operator_cli.main(args), 1)
        execute.assert_called_once()
        self.assertIn("Gate F command receipt:", output.getvalue())


class BootstrapVerifierRequestTests(unittest.TestCase):
    def test_operator_executes_both_verifiers_as_ordinary_commands(self):
        import shutil
        import subprocess
        import sys
        import re
        from Scripts.reconstruction_gate_f.canonical_json import decode_canonical_bytes
        from Scripts.tests.test_gate_f_bootstrap_qualification import BootstrapPhysicalAdmissionTests
        from Scripts.reconstruction_gate_f.tests.bootstrap_repository_fixture import bootstrap_repository
        from Scripts.reconstruction_gate_f import bootstrap_qualification, bootstrap_verifier, command_execution
        from Scripts.reconstruction_gate_f.schema import candidate_to_mapping
        from Scripts.reconstruction_gate_f.command_capture import parse_capture
        from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile
        fixture = BootstrapPhysicalAdmissionTests(methodName="runTest")
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        source, _ = bootstrap_repository(self)
        # Freeze a complete physical source before bootstrap capture. Only the
        # native signing/Xcode tool responses remain the shared fixture doubles.
        for path in source.rglob("*"):
            if path.is_file():
                relative = path.relative_to(source)
                target = fixture.repository / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, target)
                if relative.suffix == ".swift":
                    methods = sorted(set(re.findall(r"func\s+(test\w+)\s*\(", target.read_text())))
                    target.write_text("class " + target.stem + ": XCTestCase {\n" +
                                      "\n".join("func " + name + "() {}" for name in methods) + "\n}\n")
        for name in ("operator_run.py", "operator_cli.py"):
            shutil.copy2(ROOT / "Scripts/reconstruction_gate_f" / name,
                         fixture.repository / "Scripts/reconstruction_gate_f" / name)
        fixture.fixture(skipped=True)
        bootstrap_qualification.admit_bootstrap_qualification(fixture.retained, fixture.candidate,
                                                             output=fixture.artifacts / "admission.json")
        candidate_path = fixture.root / "candidate.json"
        candidate_path.write_bytes(canonical_bytes(candidate_to_mapping(fixture.candidate)))
        inputs = command_inputs(profile=CampaignProfile.BOOTSTRAP_VERIFIER, repository_root=fixture.repository, output_root=fixture.root)
        inputs.update(repository_root=str(fixture.repository), candidate_identity_path=str(candidate_path), integration_ref=fixture.source.integration_ref,
            qualification_run_id=fixture.run.run_id, qualification_run_nonce=fixture.run.nonce,
            bootstrap_artifact_root=str(fixture.artifacts), bootstrap_admission_path=str(fixture.artifacts / "admission.json"),
            bootstrap_fullsuite_artifact_root=str(fixture.root / "verify-fullsuite"),
            bootstrap_products_artifact_root=str(fixture.root / "verify-products"))
        commands = {}
        for kind in ("fullsuite", "products"):
            command_id = "qualification.verify-bootstrap-" + kind
            sources = [dict(artifact_id="artifact-" + kind + "-" + str(i),
                relative_path=operator.CAPTURED_OUTPUT_LOCATOR,
                kind="json" if i < 2 else ("xcresult" if kind == "fullsuite" else "app-bundle"),
                media_type="application/json", command_output="artifact:stdout-path:" + marker)
                for i, (_, marker) in enumerate(bootstrap_verifier.output_contract(kind))]
            sources.append(dict(artifact_id="artifact-" + kind + "-log", relative_path=kind + ".log",
                kind="launch-log", media_type="text/plain",
                command_output="log:executor-captured:bootstrap-" + kind + "-verifier-stdout-stderr"))
            commands[command_id] = dict(metadata(), receipt_id="receipt-" + kind,
                receipt_type="test-result" if kind == "fullsuite" else "release-build",
                executor=dict(metadata()["executor"], host="macos-arm64-xcode27"),
                execution_report_artifact_id=sources[0]["artifact_id"], owner_artifacts=sources)
        manifest = dict(schema_version=3, campaign_profile="bootstrap-verifier-campaign-v1",
            candidate_identity=candidate_to_mapping(fixture.candidate), repository_root=str(fixture.repository),
            command_inputs=inputs, qualification_run=dict(run_id=fixture.run.run_id, nonce=fixture.run.nonce),
            commands=commands)
        (fixture.root / "run.json").write_bytes(canonical_bytes(manifest))
        run = operator.load_run(fixture.root)
        original_completed = operator.OperatorRun.completed
        def completed(instance, command_id, *args):
            if command_id in commands:
                return original_completed(instance, command_id, *args)
            # The fourteen/native prerequisite receipts are fixture authority;
            # exact closure, identities and runtime digest remain production code.
            return dict(receipt_id="prior-" + command_id, canonical_sha256=canonical_sha256(command_id))
        original_transport = command_execution._capture_owned_process
        def transport(argv, **kwargs):
            def spawn(observed_argv, **spawn_kwargs):
                self.assertEqual(tuple(observed_argv), tuple(argv))
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(bootstrap_verifier.main(list(argv[4:])), 0)
                # Real owned child and real stream/capture transport. The
                # producer runs under native-tool fixture responses above.
                return subprocess.Popen([sys.executable, "-c", "import sys; sys.stdout.write(" +
                                         repr(output.getvalue()) + ")"], **spawn_kwargs)
            return original_transport(argv, **kwargs, spawn=spawn)
        receipts = []
        with patch.object(operator.OperatorRun, "completed", completed), \
             patch.object(command_execution, "_capture_owned_process", side_effect=transport):
            for kind in ("fullsuite", "products"):
                command_id = "qualification.verify-bootstrap-" + kind
                record = run._record(command_id)
                receipts.append(run.execute(command_id, record.scenario_ids[0], threading.Event()))
            restarted = operator.load_run(fixture.root)
            outputs = (*fixture.root.glob("*.json"), *fixture.root.glob("verify-*/*.json"))
            before = {path: (path.read_bytes(), path.stat().st_mtime_ns)
                      for path in outputs}
            for receipt in receipts:
                self.assertEqual(restarted.completed(receipt["command_id"]), receipt)
            self.assertEqual(before, {path: (path.read_bytes(), path.stat().st_mtime_ns)
                                     for path in outputs})
            original = fixture.fixture_build.app / "Contents/MacOS/MacScope"
            original.write_bytes(original.read_bytes() + b"changed")
            with self.assertRaises(ValueError):
                restarted.completed("qualification.verify-bootstrap-products")
        self.assertEqual([receipt["command_id"] for receipt in receipts],
                         ["qualification.verify-bootstrap-fullsuite", "qualification.verify-bootstrap-products"])
        self.assertEqual(len({receipt["receipt_id"] for receipt in receipts}), 2)
        self.assertFalse((fixture.root / "xcode.full-coretests.completed.json").exists())
        self.assertFalse((fixture.root / "release.build.completed.json").exists())
        for receipt in receipts:
            completion = decode_canonical_bytes((fixture.root / (receipt["command_id"] + ".completed.json")).read_bytes())
            capture = parse_capture((fixture.root / completion["capture_path"]).read_bytes()).to_mapping()
            self.assertGreater(capture["process_observation"]["pid"], 0)
            self.assertEqual(capture["terminal"]["exit_code"], 0)

    def test_capture_readmission_uses_independently_admitted_input_profile(self):
        import copy
        import hashlib
        from Scripts.tests.test_gate_f_executor_request_adapter import CapturedReceiptTests
        from Scripts.reconstruction_gate_f.tests.bootstrap_repository_fixture import bootstrap_repository
        from Scripts.reconstruction_gate_f import executor_request_adapter as adapter, command_execution, command_capture
        from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile, command_templates
        from Scripts.reconstruction_gate_f.command_compiler import compile_command_plan
        from Scripts.reconstruction_gate_f.receipt_validator import CommandPrerequisiteExpectation
        from Scripts.reconstruction_gate_f.runtime_resolution import resolve_command_record
        fixture = CapturedReceiptTests(methodName="runTest")
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        repository, inputs = bootstrap_repository(self)
        candidate = fixture.admission.capture.admission.candidate
        run = fixture.admission.capture.admission.qualification_run
        inputs.update(qualification_run_id=run.run_id, qualification_run_nonce=run.nonce)
        scenarios = fixture.admission.capture.admission.integrated_plan_input.scenario_catalog
        plan = compile_command_plan(candidate, scenarios, repository_root=repository,
                                    inputs=inputs, profile=CampaignProfile.BOOTSTRAP_VERIFIER)
        record = next(item for item in plan.commands if item.command_id == "qualification.verify-bootstrap-fullsuite")
        predecessors = tuple(CommandPrerequisiteExpectation(key, "prior-" + str(i), "c" * 64,
            run.run_id, run.nonce) for i, key in enumerate(record.prerequisite_ids))
        resolved = resolve_command_record(record, prerequisite_receipts=predecessors,
                                         qualification_run=run, profile=CampaignProfile.BOOTSTRAP_VERIFIER)
        execution = command_execution.ExecutionAdmission(candidate,
            prerequisite_dag.LaneCIntegratedCommandPlanInput(plan, scenarios, repository, inputs,
                {item.command_id: item for item in command_templates(profile=CampaignProfile.BOOTSTRAP_VERIFIER)}),
            run, candidate.source.commit, candidate.source.tree, predecessors)
        document = copy.deepcopy(fixture.document)
        document["intent"].update(command_id=record.command_id, scenario_id=record.scenario_ids[0],
            command_plan_sha256=canonical_sha256(plan), command_record_sha256=canonical_sha256(record),
            argv=list(resolved.record.argv), working_directory=str(repository),
            prerequisite_receipts=sorted([[item.command_id, item.canonical_sha256] for item in predecessors]))
        document["terminal"]["intent_sha256"] = canonical_sha256(document["intent"])
        document["runtime_resolution"] = to_primitive(resolved.runtime_resolution)
        payload = command_capture.serialize_capture(document)
        path = fixture.root / "bootstrap-capture.json"
        path.write_bytes(payload)
        capture = replace(fixture.admission.capture, admission=execution, command_id=record.command_id,
            scenario_id=record.scenario_ids[0], capture_path=path, capture_sha256=hashlib.sha256(payload).hexdigest())
        admission = replace(fixture.admission, capture=capture)
        self.assertEqual(adapter._capture(admission)[0].record.command_id, record.command_id)
        del inputs["bootstrap_products_artifact_root"]
        with self.assertRaises(ValueError):
            adapter._capture(admission)

    def test_verifier_request_uses_physical_adapter_and_rejects_original_mutation(self):
        from Scripts.tests.test_gate_f_bootstrap_verifier import BootstrapVerifierTests
        from Scripts.reconstruction_gate_f import executor_request_adapter as adapter
        from Scripts.reconstruction_gate_f.command_capture import parse_capture
        from Scripts.reconstruction_gate_f.schema import ReceiptType
        helper = BootstrapVerifierTests(methodName="runTest")
        self.addCleanup(helper.doCleanups)
        fixture = helper.fixture()
        for kind in ("fullsuite", "products"):
            admission, admitted, streams, paths = helper.adapter_fixture(fixture, kind)
            record = admitted.record
            authority = SimpleNamespace(host=record.host, execution_mode=record.execution_mode.value,
                working_directory_sha256=canonical_sha256(record.working_directory),
                environment_sha256=canonical_sha256(record.environment),
                generated_artifacts=record.generated_artifacts, generated_logs=record.generated_logs)
            validated = SimpleNamespace(command_records_by_id={record.command_id: authority},
                command_plan_sha256="e" * 64,
                command_record_sha256_by_id={record.command_id: canonical_sha256(record)})
            admitted = replace(admitted, validated_plan=validated)
            payload = admission.capture.capture_path.read_bytes()
            document = parse_capture(payload).to_mapping()
            captured = (admitted, document, streams, admission.capture.capture_path.name,
                        len(payload), admission.capture.capture_sha256)
            # Isolate the synthetic outer compiler authority only. The adapter
            # reparses capture, reports, products and original retained evidence.
            with patch.object(adapter, "_capture", return_value=captured):
                request = adapter.build_executor_request(admission)
                self.assertEqual(request["command_id"], "qualification.verify-bootstrap-" + kind)
                self.assertEqual(request["schema_version"], 4)
                self.assertNotEqual(request["command_id"], "xcode.full-coretests")
                if kind == "fullsuite":
                    self.assertEqual(request["receipt_type"], ReceiptType.TEST_RESULT.value)
                    self.assertEqual(request["authority"]["expected_selector_count"],
                                     len(record.scenario_ids or (record.command_id,)))
                    self.assertEqual([item["selector_id"] for item in request["constituents"]],
                                     list(record.scenario_ids or (record.command_id,)))
                else:
                    self.assertEqual(request["authority"], dict(
                        bundle_sha256=fixture.candidate.application.bundle_sha256,
                        closed_tree_sha256=fixture.candidate.application.closed_tree_sha256,
                        executable_sha256=fixture.candidate.application.executable_sha256))
                before = {path: (path.read_bytes(), path.stat().st_mtime_ns)
                          for path in paths}
                forged = replace(admission, authority={"forged": True}, constituents=({"forged": True},))
                self.assertEqual(adapter.build_executor_request(forged), request)
                self.assertEqual(before, {path: (path.read_bytes(), path.stat().st_mtime_ns)
                                         for path in paths})
                original = fixture.fixture_build.app / "Contents/MacOS/MacScope"
                saved = original.read_bytes()
                original.write_bytes(saved + b"mutated")
                with self.assertRaises(ValueError):
                    adapter.build_executor_request(admission)
                original.write_bytes(saved)


if __name__ == "__main__":
    unittest.main()
