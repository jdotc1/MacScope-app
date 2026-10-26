#!/usr/bin/env python3
"""Keep provider-controlled token accounting on checked arithmetic boundaries."""

from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
PRODUCTION_SOURCES = (
    ROOT / "MacScope/AIAgentWorkerCore/Phase2ReconstructionRoundAccumulator.swift",
    ROOT / "MacScope/AIWorkerProtocol/Phase2ReconstructionAIWorkerWireCodec.swift",
    ROOT
    / "MacScope/Services/Phase2/QualificationGate/Phase2QualificationGateCanaryBarrier.swift",
)


class ReconstructionUsageOverflowBoundaryTests(unittest.TestCase):
    def test_every_reconstruction_usage_sum_uses_checked_arithmetic(self) -> None:
        unchecked = re.compile(r"promptTokens\s*\+\s*[^\n]*completionTokens")
        for path in PRODUCTION_SOURCES:
            source = path.read_text(encoding="utf-8")
            with self.subTest(path=path.name):
                self.assertIsNone(
                    unchecked.search(source),
                    f"{path.name} must not trap on provider-controlled token counts",
                )
                self.assertIn("addingReportingOverflow", source)
                self.assertIn("tokenCountOverflow", source)



if __name__ == "__main__":
    unittest.main()
