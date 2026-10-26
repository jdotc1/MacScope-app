"""Synthetic owner artifacts and real plan recompilation, never live evidence."""
import base64
import copy
import hashlib
import plistlib
from dataclasses import replace
from pathlib import Path
import unittest
from unittest.mock import patch

from Scripts.reconstruction_gate_f import command_capture, command_execution, prerequisite_dag
from Scripts.reconstruction_gate_f.canonical_json import canonical_sha256, canonical_bytes, load_canonical_json, to_primitive
from Scripts.reconstruction_gate_f.runtime_resolution import resolve_command_record
from Scripts.reconstruction_gate_f.command_catalog import command_templates
from Scripts.reconstruction_gate_f.command_compiler import compile_command_plan, command_plan_sha256
from Scripts.reconstruction_gate_f.executor_receipt import emit_executor_receipt, ReceiptEmissionError
from Scripts.reconstruction_gate_f.executor_request_adapter import (
    ExecutorReceiptAdmission, OwnerArtifactSource, build_executor_request, CAPTURE_OUTPUT,
    capture_derived_report_policy, capture_execution_report_artifact_id,
    publish_capture_execution_report, CAPTURE_EXECUTION_REPORT_OUTPUT,
)
from Scripts.reconstruction_gate_f.receipt_validator import CommandPrerequisiteExpectation, validate_receipt
from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
from Scripts.reconstruction_gate_f.schema import ArtifactKind, QualificationPhase, ReceiptType
from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs
from Scripts.reconstruction_gate_f.tests import test_executor_receipt as owner_fixture
from Scripts.reconstruction_gate_f.tests.test_executor_receipt import QUALIFICATION_RUN


class CapturedReceiptTests(unittest.TestCase):
    def setUp(self):
        self.fixture = owner_fixture.GateFExecutorReceiptTests(methodName="runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.root = self.fixture.root
        self.fixture.candidate = replace(self.fixture.candidate, application=replace(
            self.fixture.candidate.application, qualification_executables=tuple(
                replace(item, sha256=hashlib.sha256(self.fixture.signed_worker_payload).hexdigest())
                if item.identity_id == "native-decompiler" else item
                for item in self.fixture.candidate.application.qualification_executables)))
        old = self.fixture._signed_xpc_request(command_id="signed-xpc.supervision")
        inputs = command_inputs()
        inputs.update(qualification_run_id=QUALIFICATION_RUN.run_id, qualification_run_nonce=QUALIFICATION_RUN.nonce)
        candidate = self.fixture.candidate
        scenarios = compile_scenario_catalog(candidate)
        plan = compile_command_plan(candidate, scenarios, repository_root=ROOT, inputs=inputs)
        record = next(item for item in plan.commands if item.command_id == old["command_id"])
        predecessors = tuple(CommandPrerequisiteExpectation(key, "prerequisite-"+str(index), "c"*64,
                             QUALIFICATION_RUN.run_id, QUALIFICATION_RUN.nonce)
                             for index, key in enumerate(record.prerequisite_ids))
        report_source = next(item for item in old["artifacts"] if item["artifact_id"] == old["execution_report_artifact_id"])
        report_path = self.root / report_source["relative_path"]
        report = load_canonical_json(report_path)
        report["predecessor_observations_sha256"] = canonical_sha256([vars(item) for item in predecessors])
        report_path.write_bytes(canonical_bytes(report))
        execution = command_execution.ExecutionAdmission(
            candidate, prerequisite_dag.LaneCIntegratedCommandPlanInput(
                plan, scenarios, ROOT, inputs, {item.command_id: item for item in command_templates()}),
            QUALIFICATION_RUN, candidate.source.commit, candidate.source.tree, predecessors)
        resolved = resolve_command_record(record, prerequisite_receipts=predecessors,
                                          qualification_run=QUALIFICATION_RUN)
        sources = tuple(OwnerArtifactSource(item["artifact_id"], item["relative_path"],
                         ArtifactKind(item["kind"]), item["media_type"], item["command_output"])
                        for item in old["artifacts"])
        stdout = b"".join((item.command_output.removeprefix("artifact:stdout-path:") + "=" +
                           str(self.root / item.relative_path) + "\n").encode()
                          for item in sources if item.command_output.startswith("artifact:stdout-path:"))
        for source in sources:
            if source.command_output.startswith("log:executor-captured:"):
                (self.root / source.relative_path).write_bytes(stdout)
        intent = dict(capture_id="synthetic-capture", run_id=QUALIFICATION_RUN.run_id, nonce=QUALIFICATION_RUN.nonce,
                      candidate_identity_sha256=record.candidate_identity_sha256,
                      command_plan_sha256=command_plan_sha256(plan), command_record_sha256=canonical_sha256(record),
                      command_id=record.command_id, scenario_id=record.scenario_ids[0] if record.scenario_ids else record.command_id,
                      producer_source_commit=candidate.source.commit, producer_source_tree=candidate.source.tree,
                      argv=list(resolved.record.argv), working_directory=record.working_directory,
                      environment=[list(item) for item in record.environment],
                      effective_environment=[list(item) for item in record.environment],
                      environment_policy_id="gatef-host-environment-v1",
                      prerequisite_receipts=sorted([[item.command_id, item.canonical_sha256] for item in predecessors]),
                      started_at_unix_ms=1)
        frames = [dict(sequence=0, stream="stdout", data_base64=base64.b64encode(stdout).decode(),
                       raw_length=len(stdout), raw_sha256=hashlib.sha256(stdout).hexdigest())]
        terminal = dict(intent_sha256=canonical_sha256(intent), frames_sha256=canonical_sha256(frames),
                        ended_at_unix_ms=3000, termination_kind="exited", exit_code=0, signal=None,
                        stdout_length=len(stdout), stdout_sha256=hashlib.sha256(stdout).hexdigest(),
                        stderr_length=0, stderr_sha256=hashlib.sha256(b"").hexdigest())
        self.document = dict(schema_version=2, intent=intent, output_frames=frames, terminal=terminal,
                             runtime_resolution=to_primitive(resolved.runtime_resolution),
                             process_observation=dict(state="launched", pid=123, spawn_observed_monotonic_ns=1,
                             os_start_time=dict(state="unavailable", reason="synthetic unit fixture")))
        path = self.root / "capture.json"
        payload = command_capture.serialize_capture(self.document)
        path.write_bytes(payload)
        capture = command_execution.ExecutionCapture(execution, record.command_id, intent["scenario_id"],
                  "synthetic-capture", record.environment, path, hashlib.sha256(payload).hexdigest())
        self.admission = ExecutorReceiptAdmission(capture, self.root, old["receipt_id"], old["requirement_id"],
            QualificationPhase(old["qualification_phase"]), ReceiptType(old["receipt_type"]),
            old["artifact_root_id"], old["execution_report_artifact_id"], sources, old["executor"],
            tuple(old["constituents"]), old["authority"])
        # Only synthetic repository identity is isolated; real compilation,
        # full DTO equality, capture binding and physical validators still run.
        self.source_patch = patch.object(prerequisite_dag, "_repository_source_issues", return_value=())
        self.source_patch.start()
        self.addCleanup(self.source_patch.stop)

    def emit(self, request=None, admission=None):
        admission = admission or self.admission
        return emit_executor_receipt(request if request is not None else build_executor_request(admission),
            artifact_root=self.root, qualification_run_authority=QUALIFICATION_RUN, admission=admission)

    def _derived_admission(self, command_id="source.create-sealed-export", *, receipt_type=ReceiptType.COMMAND_EXECUTION):
        from Scripts.reconstruction_gate_f.command_compiler import EXTERNAL_PREREQUISITE_IDS
        candidate = self.fixture.candidate
        inputs = command_inputs()
        inputs.update(source_export_root=str(self.root / "export"),
                      qualification_run_id=QUALIFICATION_RUN.run_id, qualification_run_nonce=QUALIFICATION_RUN.nonce)
        scenarios = compile_scenario_catalog(candidate)
        plan = compile_command_plan(candidate, scenarios, repository_root=ROOT, inputs=inputs)
        record = next(item for item in plan.commands if item.command_id == command_id)
        predecessors = tuple(CommandPrerequisiteExpectation(key, "prior-" + str(index), "c" * 64,
                             QUALIFICATION_RUN.run_id, QUALIFICATION_RUN.nonce)
                             for index, key in enumerate(record.prerequisite_ids)
                             if key not in EXTERNAL_PREREQUISITE_IDS)
        resolved = resolve_command_record(record, prerequisite_receipts=predecessors, qualification_run=QUALIFICATION_RUN)
        sources, stdout = [], b""
        run_root = self.root / "qualification-run"
        run_root.mkdir(exist_ok=True)
        for index, declaration in enumerate(record.generated_artifacts):
            kind = ArtifactKind.JSON
            if declaration == "stdout-path:MACSCOPE_TEST_RESULTS":
                kind = ArtifactKind.XCRESULT
                path = run_root / ("FocusedTestResults.xcresult" if command_id.startswith("xcode.focused.") else "TestResults.xcresult")
                path.mkdir(exist_ok=True)
                (path / "synthetic-test-data").write_bytes(b"immutable synthetic result bundle")
            elif declaration.startswith("receipt-derived-path:"):
                path = run_root / declaration.removeprefix("receipt-derived-path:")
                if path.name == "MacScope.app":
                    kind = ArtifactKind.APP_BUNDLE
                    (path / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
                    (path / "Contents/MacOS/MacScope").write_bytes(b"synthetic executable")
                    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "org.macscope.app"}))
            else:
                path = (run_root / ("qualification-receipt-" + str(index) + ".json") if declaration.startswith("stdout-path:")
                        else Path(declaration))
            path.parent.mkdir(parents=True, exist_ok=True)
            if kind not in {ArtifactKind.APP_BUNDLE, ArtifactKind.XCRESULT}:
                path.write_bytes(b'{"synthetic":"invocation-only"}\n')
            sources.append(OwnerArtifactSource("original-" + str(index), str(path.relative_to(self.root)),
                           kind, "application/json", "artifact:" + declaration))
            if declaration.startswith("stdout-path:"):
                stdout += (declaration.removeprefix("stdout-path:") + "=" + str(path) + "\n").encode()
        for index, declaration in enumerate(record.generated_logs):
            path = self.root / ("original-log-" + str(index))
            path.write_bytes(stdout)
            sources.append(OwnerArtifactSource("original-log-" + str(index), path.name,
                           ArtifactKind.LAUNCH_LOG, "text/plain", "log:" + declaration))
        execution = command_execution.ExecutionAdmission(candidate,
            prerequisite_dag.LaneCIntegratedCommandPlanInput(plan, scenarios, ROOT, inputs,
                {item.command_id: item for item in command_templates()}), QUALIFICATION_RUN,
            candidate.source.commit, candidate.source.tree, predecessors)
        document = copy.deepcopy(self.document)
        intent = document["intent"]
        intent.update(command_id=command_id, scenario_id=record.scenario_ids[0] if record.scenario_ids else command_id,
                      command_plan_sha256=command_plan_sha256(plan), command_record_sha256=canonical_sha256(record),
                      argv=list(resolved.record.argv), environment=[list(item) for item in record.environment],
                      effective_environment=[list(item) for item in record.environment],
                      working_directory=record.working_directory,
                      prerequisite_receipts=[[item.command_id, item.canonical_sha256] for item in predecessors])
        frames = [dict(sequence=0, stream="stdout", data_base64=base64.b64encode(stdout).decode(),
                       raw_length=len(stdout), raw_sha256=hashlib.sha256(stdout).hexdigest())]
        document.update(output_frames=frames, runtime_resolution=to_primitive(resolved.runtime_resolution))
        document["terminal"].update(intent_sha256=canonical_sha256(intent), frames_sha256=canonical_sha256(frames),
                                     stdout_length=len(stdout), stdout_sha256=hashlib.sha256(stdout).hexdigest())
        payload = command_capture.serialize_capture(document)
        path = self.root / "derived-capture.json"
        path.write_bytes(payload)
        capture = command_execution.ExecutionCapture(execution, command_id, intent["scenario_id"], intent["capture_id"],
                  record.environment, path, hashlib.sha256(payload).hexdigest())
        receipt_id = "derived-" + command_id
        admission = replace(self.admission, capture=capture, receipt_id=receipt_id,
                       receipt_type=receipt_type, owner_artifacts=tuple(sources),
                       execution_report_artifact_id=capture_execution_report_artifact_id(receipt_id),
                       executor=dict(self.admission.executor, host=record.host.value),
                       constituents=(), authority=None)
        from Scripts.reconstruction_gate_f.qualification_receipt_adapter import publish_qualification_artifact_projections
        return publish_qualification_artifact_projections(admission)

    def test_capture_derived_reports_prove_invocation_only_and_repeat_validation(self):
        for command in ("source.create-sealed-export", "source.verify-sealed-export", "xcode.full-coretests"):
            with self.subTest(command=command):
                admission = self._derived_admission(command)
                source = publish_capture_execution_report(admission)
                receipt, context = self.emit(admission=admission)
                self.assertEqual(receipt["receipt_type"], ReceiptType.COMMAND_EXECUTION.value)
                self.assertEqual(receipt["execution_interval"], {"started_at_unix_ms": 1, "ended_at_unix_ms": 3000})
                self.assertEqual(validate_receipt(receipt, context=context), ())
                with self.assertRaises(FileExistsError):
                    publish_capture_execution_report(admission)
                (self.root / source.relative_path).write_bytes(b"{}")
                self.assertTrue(validate_receipt(receipt, context=context))

    def test_derived_report_cannot_replace_native_report_or_semantic_proof(self):
        self.assertFalse(capture_derived_report_policy("signed-xpc.supervision"))
        with self.assertRaises(ReceiptEmissionError):
            publish_capture_execution_report(self.admission)
        admission = self._derived_admission()
        with self.assertRaises((ValueError, OSError)):
            build_executor_request(admission)
        for receipt_type in (ReceiptType.TEST_RESULT, ReceiptType.RELEASE_BUILD):
            with self.subTest(receipt_type=receipt_type), self.assertRaises(ReceiptEmissionError):
                publish_capture_execution_report(replace(admission, receipt_type=receipt_type))
        report = publish_capture_execution_report(admission)
        changed = load_canonical_json(self.root / report.relative_path)
        changed["started_at_unix_ms"] = 2
        (self.root / report.relative_path).write_bytes(canonical_bytes(changed))
        with self.assertRaises(ReceiptEmissionError):
            build_executor_request(admission)

    def test_source_semantic_receipt_requires_and_rechecks_verified_export(self):
        from Scripts.reconstruction_gate_f import qualification_artifact_validator as proof
        admission = replace(self._derived_admission(), receipt_type=ReceiptType.ARTIFACT_MANIFEST)
        publish_capture_execution_report(admission)
        with self.assertRaises((ValueError, RuntimeError, OSError)):
            build_executor_request(admission)
        # Isolate only the expensive export proof boundary; actual compiler,
        # capture, closure, manifest calculation and repeated receipt path run.
        with patch.object(proof, "validate_source_export", return_value={}) as validate:
            receipt, context = self.emit(admission=admission)
            self.assertEqual(receipt["receipt_type"], "artifact-manifest")
            self.assertEqual(receipt["authority"]["artifact_count"], len(receipt["artifacts"]))
            self.assertEqual(validate_receipt(receipt, context=context), ())
            self.assertGreaterEqual(validate.call_count, 4)
            validate.side_effect = proof.QualificationArtifactError("export changed")
            self.assertTrue(validate_receipt(receipt, context=context))
            from Scripts.source_export_provenance import SourceExportError
            validate.side_effect = SourceExportError("source export disappeared")
            self.assertTrue(validate_receipt(receipt, context=context))

    def test_test_semantics_are_bound_to_selected_scope_and_original_directory(self):
        from Scripts.reconstruction_gate_f import qualification_receipt_adapter as bridge
        from Scripts.reconstruction_gate_f import qualification_artifact_validator as proof
        with patch.object(bridge, "validate_qualification_products", return_value={}) as products, \
             patch.object(bridge, "validate_selected_xcresult", return_value={"skipped_selector_count": 0}) as results:
            admission = self._derived_admission("xcode.focused.batch-scheduler", receipt_type=ReceiptType.TEST_RESULT)
            publish_capture_execution_report(admission)
            record = next(item for item in admission.capture.admission.integrated_plan_input.plan.commands
                          if item.command_id == admission.capture.command_id)
            selector = record.argv[record.argv.index("--only-testing") + 1]
            receipt, context = self.emit(admission=admission)
            self.assertEqual({item["selector_id"] for item in receipt["constituents"]}, set(record.scenario_ids or (record.command_id,)))
            self.assertEqual(results.call_args.kwargs["selected_scope"], selector)
            self.assertEqual(results.call_args.kwargs["scratch_root"], self.root)
            self.assertEqual(validate_receipt(receipt, context=context), ())
            self.assertGreaterEqual(products.call_count, 2)
            results.side_effect = proof.QualificationArtifactError("physical test failed")
            self.assertTrue(validate_receipt(receipt, context=context))
            results.side_effect = None
            (self.root / "qualification-run/FocusedTestResults.xcresult/synthetic-test-data").write_bytes(b"changed")
            self.assertTrue(validate_receipt(receipt, context=context))

    def test_release_directory_projection_cannot_replace_physical_product_proof(self):
        from Scripts.reconstruction_gate_f import qualification_receipt_adapter as bridge
        from Scripts.reconstruction_gate_f import qualification_artifact_validator as proof
        admission = replace(self._derived_admission("release.build"), receipt_type=ReceiptType.RELEASE_BUILD)
        publish_capture_execution_report(admission)
        app = self.fixture.candidate.application
        with patch.object(bridge, "validate_qualification_products", return_value={
                "bundle_sha256": app.bundle_sha256, "closed_tree_sha256": app.closed_tree_sha256}) as products:
            receipt, context = self.emit(admission=admission)
            self.assertEqual(receipt["authority"]["bundle_sha256"], app.bundle_sha256)
            self.assertEqual(validate_receipt(receipt, context=context), ())
            products.side_effect = proof.QualificationArtifactError("product differs from candidate")
            self.assertTrue(validate_receipt(receipt, context=context))
            products.side_effect = None
            (self.root / "qualification-run/DerivedData/Build/Products/Release/MacScope.app/Contents/MacOS/MacScope").write_bytes(b"changed")
            self.assertTrue(validate_receipt(receipt, context=context))

    def test_full_suite_retains_skips_separately_in_receipt_bound_directory_proof(self):
        from Scripts.reconstruction_gate_f import qualification_receipt_adapter as bridge
        observations = {"selected_scope": "CoreTests", "passed_selector_count": 4,
                        "skipped_selector_count": 1,
                        "skips": [{"test_identifier": "CoreTests/Optional/testFixture",
                                   "observed_reason": "fixture absent", "reviewed_reason": "optional fixture"}],
                        "skip_policy": {"source_commit": self.fixture.candidate.source.commit}}
        with patch.object(bridge, "validate_qualification_products", return_value={}), \
             patch.object(bridge, "validate_full_coretests_xcresult", return_value=observations) as full:
            admission = self._derived_admission("xcode.full-coretests", receipt_type=ReceiptType.TEST_RESULT)
            publish_capture_execution_report(admission)
            receipt, context = self.emit(admission=admission)
            source = next(item for item in admission.owner_artifacts if item.kind is ArtifactKind.XCRESULT)
            projection = load_canonical_json(self.root / source.relative_path)
            self.assertEqual(projection["test_observations"], observations)
            self.assertEqual(full.call_args.kwargs["source_root"], self.root / "qualification-run/source")
            self.assertEqual(full.call_args.kwargs["candidate"], self.fixture.candidate)
            self.assertEqual(validate_receipt(receipt, context=context), ())
            changed = copy.deepcopy(projection)
            changed["test_observations"]["skipped_selector_count"] = 0
            (self.root / source.relative_path).write_bytes(canonical_bytes(changed))
            self.assertTrue(validate_receipt(receipt, context=context))

    def test_capture_and_real_owner_report_pass_and_repeat_validation(self):
        receipt, context = self.emit()
        self.assertEqual(receipt["evidence_status"], "passed")
        self.assertEqual(receipt["schema_version"], 4)
        self.assertEqual(receipt["runtime_resolution"], self.document["runtime_resolution"])
        self.assertEqual(receipt["command_record_sha256"], self.document["intent"]["command_record_sha256"])
        self.assertEqual(receipt["command_authority"]["argv_sha256"],
                         canonical_sha256(self.document["intent"]["argv"]))
        self.assertEqual(sum(item["command_output"] == CAPTURE_OUTPUT for item in receipt["artifacts"]), 1)
        self.assertEqual(validate_receipt(receipt, context=context), ())

    def test_resealed_resolution_cannot_replace_independent_capture_authority(self):
        from Scripts.reconstruction_gate_f.receipt_schema import seal_receipt
        receipt, context = self.emit()
        for resolution in (None, {}, [], {"schema_version": 1, "bindings": [],
                                       "resolved_command_record_sha256": "0" * 64}):
            with self.subTest(resolution=resolution):
                changed = seal_receipt(dict(receipt, runtime_resolution=resolution))
                # Even a caller altering the superficial expected mapping cannot
                # replace fresh resolution from the retained execution admission.
                altered_context = replace(context, expected_runtime_resolution=resolution)
                self.assertTrue(validate_receipt(changed, context=altered_context))

    def test_missing_admission_and_old_request_fail_closed(self):
        request = build_executor_request(self.admission)
        with self.assertRaises(ReceiptEmissionError):
            emit_executor_receipt(request, artifact_root=self.root, qualification_run_authority=QUALIFICATION_RUN)
        request["schema_version"] = 2
        with self.assertRaises(ReceiptEmissionError):
            self.emit(request)

    def test_capture_artifacts_are_unique_in_a_multi_receipt_evidence_closure(self):
        requests = [build_executor_request(replace(self.admission, receipt_id="receipt-owner-" + str(index)))
                    for index in range(7)]
        captures = [next(item for item in request["artifacts"] if item["command_output"] == CAPTURE_OUTPUT)
                    for request in requests]
        self.assertEqual(len({item["artifact_id"] for item in captures}), 7)
        repeated = build_executor_request(replace(self.admission, receipt_id="receipt-owner-0"))
        self.assertEqual(captures[0], next(item for item in repeated["artifacts"]
                                         if item["command_output"] == CAPTURE_OUTPUT))

    def test_request_forgery_never_supplies_expected_authority(self):
        request = build_executor_request(self.admission)
        for field, value in (("command_plan_sha256", "0"*64), ("command_record_sha256", "0"*64),
                             ("scenario_id", "forged"), ("qualification_run", {"run_id":"forged","nonce":"0"*64})):
            changed = copy.deepcopy(request); changed[field] = value
            with self.subTest(field=field), self.assertRaises(ReceiptEmissionError):
                self.emit(changed)

    def test_capture_missing_changed_or_resealed_process_observation_refused(self):
        request = build_executor_request(self.admission)
        path = self.admission.capture.capture_path
        original = path.read_bytes()
        changed = copy.deepcopy(self.document); changed["process_observation"]["pid"] = 456
        for payload in (b"", original+b" ", command_capture.serialize_capture(changed)):
            path.write_bytes(payload)
            with self.assertRaises(ReceiptEmissionError): self.emit(request)
        path.write_bytes(original)

    def test_failed_capture_cannot_use_passing_physical_report(self):
        changed = copy.deepcopy(self.document)
        changed["terminal"].update(termination_kind="timed-out", exit_code=0)
        payload = command_capture.serialize_capture(changed)
        self.admission.capture.capture_path.write_bytes(payload)
        admission = replace(self.admission, capture=replace(self.admission.capture, capture_sha256=hashlib.sha256(payload).hexdigest()))
        with self.assertRaises(ReceiptEmissionError): self.emit(admission=admission)

    def test_runtime_resolution_is_not_adopted_from_request_or_resealed_capture(self):
        request = build_executor_request(self.admission)
        changed_request = copy.deepcopy(request)
        changed_request["runtime_resolution"]["resolved_command_record_sha256"] = "0"*64
        with self.assertRaises(ReceiptEmissionError):
            self.emit(changed_request)
        document = copy.deepcopy(self.document)
        document["runtime_resolution"]["resolved_command_record_sha256"] = "0"*64
        payload = command_capture.serialize_capture(document)
        self.admission.capture.capture_path.write_bytes(payload)
        altered = replace(self.admission, capture=replace(self.admission.capture,
                          capture_sha256=hashlib.sha256(payload).hexdigest()))
        with self.assertRaises(ReceiptEmissionError):
            self.emit(admission=altered)

    def test_real_recompiler_rejects_self_consistent_forged_plan(self):
        execution = self.admission.capture.admission
        records = list(execution.integrated_plan_input.plan.commands)
        index = next(i for i,item in enumerate(records) if item.command_id == self.admission.capture.command_id)
        records[index] = replace(records[index], timeout_seconds=records[index].timeout_seconds+1)
        plan = replace(execution.integrated_plan_input.plan, commands=tuple(records))
        changed = replace(execution, integrated_plan_input=replace(execution.integrated_plan_input, plan=plan))
        with self.assertRaises(ValueError): self.emit(admission=replace(self.admission, capture=replace(self.admission.capture, admission=changed)))

    def test_separately_required_capture_does_not_weaken_owner_constituent_closure(self):
        from Scripts.reconstruction_gate_f.receipt_schema import seal_receipt
        receipt, context = self.emit()
        for changed in (dict(receipt, artifacts=receipt["artifacts"][:-1]),
                        dict(receipt, constituents=[])):
            self.assertTrue(validate_receipt(seal_receipt(changed), context=context))

    def test_original_owner_output_closure_is_mandatory(self):
        for sources in (self.admission.owner_artifacts[:-1],
                        self.admission.owner_artifacts + (replace(self.admission.owner_artifacts[0], command_output="log:arbitrary"),)):
            with self.assertRaisesRegex(ReceiptEmissionError, "exact original"):
                build_executor_request(replace(self.admission, owner_artifacts=sources))

    def test_public_validator_cannot_downgrade_to_physical_only_context(self):
        from Scripts.reconstruction_gate_f.receipt_schema import seal_receipt
        receipt, context = self.emit()
        stripped = seal_receipt(dict(receipt, artifacts=receipt["artifacts"][:-1]))
        legacy_context = replace(context, capture_admission=None,
                                 expected_artifacts=context.expected_artifacts[:-1])
        self.assertIn("capture-admission-required",
                      {item.code for item in validate_receipt(stripped, context=legacy_context)})

    def test_repeat_validation_rejects_resealed_receipt_with_changed_report_facts(self):
        from Scripts.reconstruction_gate_f.receipt_schema import seal_receipt
        receipt, context = self.emit()
        changed = seal_receipt(dict(receipt, evidence_status="failed"))
        self.assertIn("capture-admission", {item.code for item in validate_receipt(changed, context=context)})

    def test_malformed_command_identity_returns_issues_without_hashability_exception(self):
        receipt, context = self.emit()
        for value in ([], {}):
            with self.subTest(value=value):
                self.assertTrue(validate_receipt(dict(receipt, command_id=value), context=replace(context, capture_admission=None)))

    def test_readiness_requires_independent_run_candidate_and_capture(self):
        from Scripts.reconstruction_gate_f import next5_gatef_readiness as readiness
        request = build_executor_request(self.admission)
        path = self.root / "request.json"
        path.write_bytes(canonical_bytes(request))
        arguments = dict(command_id=request["command_id"], request_path=path, artifact_root=self.root,
                         candidate=self.admission.capture.admission.candidate,
                         qualification_run=QUALIFICATION_RUN, admission=self.admission)
        result, run = readiness._validate_executor_request(**arguments, inode_claims={})
        self.assertEqual(run, QUALIFICATION_RUN)
        self.assertEqual(result["command_id"], request["command_id"])
        for altered in (dict(arguments, qualification_run=None), dict(arguments, admission=None),
                        dict(arguments, qualification_run=replace(QUALIFICATION_RUN, nonce="0"*64)),
                        dict(arguments, candidate=replace(arguments["candidate"], source=replace(arguments["candidate"].source, tree="0"*40)))):
            with self.assertRaises(readiness.ReadinessError):
                readiness._validate_executor_request(**altered, inode_claims={})

    def test_live_orchestrator_retains_exact_producer_capture(self):
        from Scripts.reconstruction_gate_f.executor_request_adapter import execute_and_emit
        capture = self.admission.capture
        with patch.object(command_execution, "execute_admitted_command", return_value=capture) as execute:
            receipt, _ = execute_and_emit(capture.admission, command_id=capture.command_id,
                scenario_id=capture.scenario_id, capture_root=self.root, cancellation=None,
                receipt_admission_factory=lambda produced: self.admission)
            self.assertEqual(receipt["evidence_status"], "passed")
            self.assertEqual(execute.call_count, 1)
            with self.assertRaisesRegex(ReceiptEmissionError, "replaced"):
                execute_and_emit(capture.admission, command_id=capture.command_id,
                    scenario_id=capture.scenario_id, capture_root=self.root, cancellation=None,
                    receipt_admission_factory=lambda produced: replace(self.admission, capture=replace(produced)))
