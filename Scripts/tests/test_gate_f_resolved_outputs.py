"""Resolved output semantics from real compiler DTOs, not physical acceptance."""
from dataclasses import replace
import unittest
from unittest.mock import patch

from Scripts.reconstruction_gate_f import gate_specific_artifact_validator as subject
from Scripts.reconstruction_gate_f.command_catalog import command_templates
from Scripts.reconstruction_gate_f.command_compiler import compile_command_plan, _validate_input_mapping
from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
from Scripts.reconstruction_gate_f.tests import parsed_candidate
from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs
from Scripts.reconstruction_gate_f.schema import ReceiptType, EvidenceStatus


class ResolvedOutputTests(unittest.TestCase):
    def setUp(self):
        self.candidate = parsed_candidate()
        self.inputs = command_inputs()
        # Deliberately reverse lexical role order after placeholder substitution.
        self.inputs.update(installed_matrix_receipt="/tmp/z-matrix.json",
                           installed_matrix_xcresult_semantic_manifest="/tmp/a-semantic.json")
        self.normalized = _validate_input_mapping(self.inputs, command_templates(), self.candidate)
        self.plan = compile_command_plan(self.candidate, compile_scenario_catalog(self.candidate),
                                         repository_root=ROOT, inputs=self.inputs)
        self.records = {item.command_id: item for item in self.plan.commands}

    def template(self, command_id="installed.task10-workflow", **overrides):
        record = overrides.pop("record", self.records[command_id])
        return subject._template(command_id, record.evidence_layer,
            admitted_command_record=record, admitted_command_inputs=overrides.pop("inputs", self.normalized), **overrides)

    def test_logical_role_resolution_survives_reversed_physical_sort_order(self):
        template = self.template()
        self.assertEqual(subject._generated_output(template, "@installed_matrix_receipt@"), "artifact:/tmp/z-matrix.json")
        self.assertEqual(subject._generated_output(template, "@installed_matrix_xcresult_semantic_manifest@"), "artifact:/tmp/a-semantic.json")
        self.assertEqual(subject._generated_output(template, "stdout-json:installed-task10-matrix-summary"),
                         "artifact:stdout-json:installed-task10-matrix-summary")

    def test_all_seven_owner_output_closures_use_actual_compiler_outputs(self):
        commands = ("installed.task10-workflow", "installed.accessibility-semantics",
                    "reconstruction.deterministic-evidence", "signed-xpc.supervision",
                    "signed-xpc.complete-truncated-content", "signed-xpc.error-cancellation",
                    "stress.reconstruction-authority-races")
        for command in commands:
            with self.subTest(command=command):
                record = self.records[command]
                template = self.template(command)
                artifacts = [{"command_output": "artifact:" + item} for item in record.generated_artifacts]
                artifacts += [{"command_output": "log:" + item} for item in record.generated_logs]
                subject._validate_command_outputs(template, artifacts=artifacts,
                    generated_artifacts=record.generated_artifacts, generated_logs=record.generated_logs)
                raw = next(item for item in command_templates() if item.command_id == command)
                for logical in raw.generated_artifacts:
                    self.assertIn(subject._generated_output(template, logical),
                                  {item["command_output"] for item in artifacts})
                with self.assertRaises(subject.GateSpecificArtifactError):
                    subject._validate_command_outputs(template, artifacts=artifacts[:-1],
                        generated_artifacts=record.generated_artifacts, generated_logs=record.generated_logs)

    def test_changed_inputs_record_or_request_labels_do_not_supply_authority(self):
        record = self.records["installed.task10-workflow"]
        changed = dict(self.normalized, installed_matrix_receipt="/tmp/forged.json")
        for kwargs in ({"inputs": changed}, {"inputs": None},
                       {"record": replace(record, generated_artifacts=tuple(reversed(record.generated_artifacts)))},
                       {"record": replace(record, command_id="installed.accessibility-semantics")}):
            with self.subTest(kwargs=kwargs), self.assertRaises(subject.GateSpecificArtifactError):
                self.template(**kwargs)
        template = self.template()
        raw = next(item for item in command_templates() if item.command_id == record.command_id)
        with self.assertRaises(subject.GateSpecificArtifactError):
            subject._validate_command_outputs(template, artifacts=[], generated_artifacts=raw.generated_artifacts,
                                              generated_logs=raw.generated_logs)

    def test_dispatch_forwards_only_explicit_admitted_inputs(self):
        record = self.records["installed.task10-workflow"]
        with patch.object(subject, "validate_installed_task10_workflow_artifacts") as validate:
            subject.validate_gate_specific_artifacts(receipt_type=ReceiptType.INSTALLED_WORKFLOW,
                candidate=self.candidate, command_id=record.command_id, artifacts=[], artifact_root=ROOT,
                execution_report_artifact_id="report", result=EvidenceStatus.PASSED, stress=None,
                constituents=[], authority=None, generated_artifacts=record.generated_artifacts,
                generated_logs=record.generated_logs, command_plan_sha256="a" * 64,
                command_record_sha256="b" * 64, prerequisite_receipts=[],
                admitted_command_record=record, admitted_command_inputs=self.inputs)
        self.assertIs(validate.call_args.kwargs["admitted_command_record"], record)
        self.assertEqual(validate.call_args.kwargs["admitted_command_inputs"], self.normalized)

    def test_every_specialized_entrypoint_accepts_explicit_admission_context(self):
        import inspect
        for name, function in vars(subject).items():
            if name.startswith("validate_") and inspect.isfunction(function) and function.__module__ == subject.__name__:
                with self.subTest(name=name):
                    fields = inspect.signature(function).parameters
                    self.assertIn("admitted_command_record", fields)
                    self.assertIn("admitted_command_inputs", fields)


if __name__ == "__main__":
    unittest.main()
