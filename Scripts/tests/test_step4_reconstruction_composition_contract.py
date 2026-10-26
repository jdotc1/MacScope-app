#!/usr/bin/env python3
"""Host-independent source guards for Step-4 durable-composition authority."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PACKAGE_MODELS = (
    ROOT / "MacScope/Models/Reconstruction/ReconstructionPackageModels.swift"
)
DATABASE = ROOT / "MacScope/Stores/WorkspaceDatabase.swift"
COORDINATOR = (
    ROOT / "MacScope/Services/Reconstruction/ReconstructionJobCoordinator.swift"
)


def declaration_block(source: str, declaration: str) -> str:
    start = source.find(declaration)
    if start < 0:
        raise AssertionError(f"missing declaration: {declaration}")
    opening = source.find("{", start)
    if opening < 0:
        raise AssertionError(f"missing declaration body: {declaration}")
    depth = 0
    for offset in range(opening, len(source)):
        token = source[offset]
        if token == "{":
            depth += 1
        elif token == "}":
            depth -= 1
            if depth == 0:
                return source[start : offset + 1]
    raise AssertionError(f"unterminated declaration: {declaration}")


class Step4ReconstructionCompositionContractTests(unittest.TestCase):
    def test_package_and_database_reject_duplicate_tool_receipt_task_binding(self) -> None:
        package = PACKAGE_MODELS.read_text(encoding="utf-8")
        database = DATABASE.read_text(encoding="utf-8")
        guard = declaration_block(
            package,
            "static func validateUniqueToolReceiptTaskBindings(",
        )

        self.assertIn("receiptIDsByTaskID.updateValue(", guard)
        self.assertIn("forKey: receipt.taskID", guard)
        self.assertIn("== nil else", guard)
        self.assertIn('"duplicate tool receipt task binding"', guard)
        self.assertIn(
            "try validateUniqueToolReceiptTaskBindings(state.toolReceipts)",
            package,
            "package-v3 graph admission must invoke the per-task tool-receipt guard",
        )
        self.assertIn(
            "try ReconstructionPackageCodec.validateGraph(state)",
            database,
            "database graph admission must retain package-v3 graph validation",
        )

    def test_crash_recovery_guards_unique_tool_receipt_task_binding(self) -> None:
        coordinator = COORDINATOR.read_text(encoding="utf-8")
        recovery_wrapper = declaration_block(
            coordinator,
            "static func terminalReceiptStates(",
        )
        self.assertIn(
            "try terminalReceiptAuthority(toolReceipts: toolReceipts, modelReceipts: modelReceipts).states",
            recovery_wrapper,
            "the compatibility wrapper must use the same throwing recovery authority",
        )
        recovery_guard = declaration_block(
            coordinator,
            "static func terminalReceiptAuthority(",
        )

        self.assertIn("for receipt in toolReceipts", recovery_guard)
        self.assertIn(
            "guard terminalStates.updateValue(state, forKey: receipt.taskID) == nil else",
            recovery_guard,
        )
        self.assertIn("ReconstructionJobCoordinatorFailure.invalidCommitPlan", recovery_guard)


if __name__ == "__main__":
    unittest.main()
