"""Semantic scenario coverage does not multiply the physical XCTest selector."""
from __future__ import annotations

import copy
import hashlib
import unittest
from dataclasses import replace

from Scripts.reconstruction_gate_f import gate_specific_artifact_validator as validator
from Scripts.reconstruction_gate_f.command_compiler import compile_command_plan
from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
from Scripts.reconstruction_gate_f.prerequisite_dag import lane_c_receipt_scenario_ids
from Scripts.reconstruction_gate_f.schema import EvidenceStatus
from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs
from Scripts.reconstruction_gate_f.tests import test_executor_receipt as fixtures
from Scripts.reconstruction_gate_f.canonical_json import load_canonical_json, write_canonical_json


class SignedXPCSemanticCountsTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.GateFExecutorReceiptTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.command_id = "signed-xpc.error-cancellation"
        candidate = self.fixture.candidate
        self.fixture.candidate = replace(candidate, application=replace(candidate.application,
            qualification_executables=tuple(replace(item,
                sha256=hashlib.sha256(self.fixture.signed_worker_payload).hexdigest())
                if item.identity_id == "native-decompiler" else item
                for item in candidate.application.qualification_executables)))
        self.request = self.fixture._signed_xpc_request(command_id=self.command_id)
        self.inputs = command_inputs()
        plan = compile_command_plan(self.fixture.candidate,
            compile_scenario_catalog(self.fixture.candidate), repository_root=ROOT, inputs=self.inputs)
        self.record = next(item for item in plan.commands if item.command_id == self.command_id)
        self.assertEqual(len(self.record.scenario_ids), 2)
        self.request["authority"]["selector_count"] = 2

    def validate(self, request=None, result=EvidenceStatus.PASSED):
        request = request or self.request
        validator.validate_signed_xpc_artifacts(
            admitted_command_record=self.record, admitted_command_inputs=self.inputs,
            candidate=self.fixture.candidate, command_id=self.command_id,
            artifacts=request["artifacts"], artifact_root=self.fixture.root,
            execution_report_artifact_id="artifact-execution-report", result=result,
            authority=request["authority"], generated_artifacts=self.record.generated_artifacts,
            generated_logs=self.record.generated_logs)

    def refresh_test_descriptor(self, request):
        payload = (self.fixture.root / "test-results.json").read_bytes()
        artifact = next(item for item in request["artifacts"]
                        if item["artifact_id"] == "artifact-test-results")
        artifact.update(byte_count=len(payload), sha256=hashlib.sha256(payload).hexdigest())

    def test_one_physical_selected_test_covers_two_semantic_scenarios(self):
        self.validate()

    def test_scenarioless_receipt_coordinate_matches_capture_command_identity(self):
        record = replace(self.record, command_id="signed-xpc.supervision", scenario_ids=())
        self.assertEqual(lane_c_receipt_scenario_ids(record), (record.command_id,))
        self.assertEqual(lane_c_receipt_scenario_ids(self.record), self.record.scenario_ids)

    def test_semantic_count_must_match_admitted_catalogue_not_physical_count(self):
        for count in (0, 1, 3, True, 2.0):
            with self.subTest(count=count):
                request = copy.deepcopy(self.request)
                request["authority"]["selector_count"] = count
                with self.assertRaisesRegex(validator.GateSpecificArtifactError, "semantic scenario closure"):
                    self.validate(request)

    def test_two_scenarios_do_not_authorize_duplicate_physical_tests(self):
        path = self.fixture.root / "test-results.json"
        document = load_canonical_json(path)
        document["testNodes"] *= 2
        write_canonical_json(path, document)
        self.refresh_test_descriptor(self.request)
        with self.assertRaisesRegex(validator.GateSpecificArtifactError, "exactly one"):
            self.validate()

    def test_failed_semantic_counts_still_require_one_physical_failure(self):
        request = copy.deepcopy(self.request)
        request["authority"].update(failed_count=2, failure_stage="selected-test",
                                    failure_reason="selected-test-failed")
        with self.assertRaisesRegex(validator.GateSpecificArtifactError, "physical failure"):
            self.validate(request, EvidenceStatus.FAILED)
        path = self.fixture.root / "test-results.json"
        document = load_canonical_json(path)
        def fail(node):
            if "result" in node:
                node["result"] = "Failed"
            for child in node.get("children", []):
                fail(child)
        for node in document["testNodes"]:
            fail(node)
        write_canonical_json(path, document)
        self.refresh_test_descriptor(request)
        self.validate(request, EvidenceStatus.FAILED)
        request["authority"]["failed_count"] = 3
        with self.assertRaisesRegex(validator.GateSpecificArtifactError, "failure classification"):
            self.validate(request, EvidenceStatus.FAILED)


class DeterministicSemanticCountsTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.GateFExecutorReceiptTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.request = self.fixture._deterministic_evidence_request()
        self.inputs = command_inputs()
        plan = compile_command_plan(self.fixture.candidate,
            compile_scenario_catalog(self.fixture.candidate), repository_root=ROOT, inputs=self.inputs)
        self.record = next(item for item in plan.commands
                           if item.command_id == "reconstruction.deterministic-evidence")
        self.assertEqual(len(self.record.scenario_ids), 14)
        constituent = self.request["constituents"][0]
        self.request["constituents"] = [dict(constituent, selector_id=scenario)
                                        for scenario in self.record.scenario_ids]

    def validate(self):
        validator.validate_deterministic_evidence_artifacts(
            admitted_command_record=self.record, admitted_command_inputs=self.inputs,
            candidate=self.fixture.candidate, command_id=self.record.command_id,
            artifacts=self.request["artifacts"], artifact_root=self.fixture.root,
            execution_report_artifact_id=self.request["execution_report_artifact_id"],
            result=EvidenceStatus.PASSED, constituents=self.request["constituents"],
            generated_artifacts=self.record.generated_artifacts,
            generated_logs=self.record.generated_logs)

    def test_two_run_proof_covers_exact_fourteen_catalogued_scenarios(self):
        self.validate()

    def test_missing_duplicate_or_unproved_semantic_constituent_is_rejected(self):
        original = copy.deepcopy(self.request["constituents"])
        for change in ("missing", "duplicate", "artifact", "status"):
            self.request["constituents"] = copy.deepcopy(original)
            rows = self.request["constituents"]
            if change == "missing":
                rows.pop()
            elif change == "duplicate":
                rows[0]["selector_id"] = rows[1]["selector_id"]
            elif change == "artifact":
                rows[0]["artifact_ids"] = rows[0]["artifact_ids"][:-1]
            else:
                rows[0]["status"] = "failed"
            with self.subTest(change=change), self.assertRaisesRegex(
                    validator.GateSpecificArtifactError, "complete physical proof"):
                self.validate()


if __name__ == "__main__":
    unittest.main()
