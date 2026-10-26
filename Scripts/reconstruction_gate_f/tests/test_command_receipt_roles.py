"""Command-specific role admission without the expensive complete Gate fixture."""
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from Scripts.reconstruction_gate_f.command_catalog import command_templates
from Scripts.reconstruction_gate_f.gate_evaluator import _command_coverage_issues, _receipt_role_matches
from Scripts.reconstruction_gate_f.schema import EvidenceLayer, ReceiptType
from Scripts.reconstruction_gate_f import qualification_receipt_adapter as bridge
from Scripts.reconstruction_gate_f.executor_request_adapter import publish_capture_execution_report
from Scripts.reconstruction_gate_f.executor_receipt import ReceiptEmissionError
from Scripts.tests import test_gate_f_executor_request_adapter as captured_fixture


class CommandReceiptRoleTests(unittest.TestCase):
    def test_smoke_is_build_preparation_not_test_execution(self):
        layer = EvidenceLayer.XCODE_FOCUSED
        self.assertTrue(_receipt_role_matches("xcode.smoke", layer, ReceiptType.COMMAND_EXECUTION))
        self.assertFalse(_receipt_role_matches("xcode.smoke", layer, ReceiptType.TEST_RESULT))
        self.assertFalse(_receipt_role_matches("xcode.smoke", EvidenceLayer.HOSTED_PURE, ReceiptType.COMMAND_EXECUTION))

    def test_all_fourteen_focused_commands_still_require_test_results(self):
        commands = [item for item in command_templates() if item.command_id.startswith("xcode.focused.")]
        self.assertEqual(len(commands), 14)
        for command in commands:
            with self.subTest(command=command.command_id):
                self.assertTrue(_receipt_role_matches(command.command_id, command.evidence_layer, ReceiptType.TEST_RESULT))
                self.assertFalse(_receipt_role_matches(command.command_id, command.evidence_layer, ReceiptType.COMMAND_EXECUTION))

    def test_command_coverage_accepts_smoke_but_not_focused_invocation_substitution(self):
        layer = EvidenceLayer.XCODE_FOCUSED
        commands = {key: SimpleNamespace(evidence_layer=layer) for key in ("xcode.smoke", "xcode.focused.batch-scheduler")}
        smoke = SimpleNamespace(command_id="xcode.smoke", receipt_type=ReceiptType.COMMAND_EXECUTION)
        focused = SimpleNamespace(command_id="xcode.focused.batch-scheduler", receipt_type=ReceiptType.TEST_RESULT)
        claim = SimpleNamespace(layer=layer, receipt_outputs=[smoke, focused])
        self.assertEqual(_command_coverage_issues([claim], commands, [layer]), ())
        focused.receipt_type = ReceiptType.COMMAND_EXECUTION
        issues = _command_coverage_issues([claim], commands, [layer])
        self.assertEqual(len(issues), 1)
        self.assertIn("xcode.focused.batch-scheduler", issues[0].message)
        self.assertNotIn("xcode.smoke", issues[0].message)

    def test_smoke_receipt_requires_physical_build_preparation_proof(self):
        fixture = captured_fixture.CapturedReceiptTests(methodName="runTest")
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        admission = fixture._derived_admission("xcode.smoke")
        publish_capture_execution_report(admission)
        with patch.object(bridge, "validate_qualification_products", return_value={}) as proof:
            receipt, _ = fixture.emit(admission=admission)
            self.assertEqual(receipt["receipt_type"], ReceiptType.COMMAND_EXECUTION.value)
            self.assertEqual(proof.call_args.kwargs["mode"], "smoke")
            proof.side_effect = RuntimeError("missing build-for-testing products")
            with self.assertRaises(ReceiptEmissionError):
                fixture.emit(admission=admission)
