#!/usr/bin/env python3
"""Host-independent guard for the installed stale Reveal Source TOCTOU fence."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "MacScope/Features/Workspace/WorkspaceRootView.swift"


def bounded_function(source: str, signature: str, next_signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise AssertionError(f"missing source contract: {signature}")
    end = source.find(next_signature, start)
    if end < 0:
        raise AssertionError(f"missing source boundary after {signature}: {next_signature}")
    return source[start:end]


class ReconstructionStaleSourceRevealContractTests(unittest.TestCase):
    def test_live_handler_re_resolves_authority_through_the_toctou_fence(self) -> None:
        source = SOURCE.read_text(encoding="utf-8")
        handler = bounded_function(
            source,
            "private func revealReconstructionEvidenceSource",
            "static func dispatchReconstructionSourceReveal",
        )
        dispatcher = bounded_function(
            source,
            "static func dispatchReconstructionSourceReveal",
            "static func reconstructionSourceNavigationRefusal",
        )

        self.assertIn("Self.dispatchReconstructionSourceReveal(", handler)
        self.assertIn("currentRequest: {", handler)
        self.assertIn("workspace: store.reconstructionState", handler)
        self.assertIn("snapshot: store.snapshot", handler)
        self.assertIn("reveal: { try store.revealReconstructionSource($0) }", handler)
        self.assertIn("guard let request = currentRequest() else", dispatcher)
        self.assertIn("return reconstructionSourceNavigationRefusal(for: nil)", dispatcher)
        self.assertNotIn("try?", dispatcher)



if __name__ == "__main__":
    unittest.main()
