#!/usr/bin/env python3
"""Keep Reconstruction batch analysis detached from interactive window authority."""

from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
HEADLESS_SOURCES = (
    ROOT
    / "MacScope"
    / "Services"
    / "Reconstruction"
    / "ReconstructionHeadlessAnalysisExecutor.swift",
    ROOT
    / "MacScope"
    / "Services"
    / "Reconstruction"
    / "ReconstructionBatchTaskExecutor.swift",
)
PRODUCTION_COMPOSITION = (
    ROOT
    / "MacScope"
    / "Services"
    / "Reconstruction"
    / "ReconstructionProductionComposition.swift"
)


class ReconstructionHeadlessUIBoundaryTests(unittest.TestCase):
    def test_headless_execution_sources_do_not_depend_on_interactive_authority(self) -> None:
        forbidden = (
            "WorkspaceStore",
            "NativeDecompilerPresentationModel",
            "NativeDecompilerPresentationState",
        )
        for path in HEADLESS_SOURCES:
            source = path.read_text(encoding="utf-8")
            for identifier in forbidden:
                with self.subTest(path=path.name, identifier=identifier):
                    self.assertNotIn(
                        identifier,
                        source,
                        f"{path.name} must return detached results instead of mutating "
                        f"interactive authority through {identifier}",
                    )

    def test_production_batch_builder_does_not_capture_interactive_authority(self) -> None:
        source = PRODUCTION_COMPOSITION.read_text(encoding="utf-8")
        start_marker = "builder: { basis, _ in"
        end_marker = "retireJobAuthority:"
        self.assertEqual(source.count(start_marker), 1)
        self.assertEqual(source.count(end_marker), 1)
        builder = source.split(start_marker, 1)[1].split(end_marker, 1)[0]
        self.assertIn("ReconstructionBatchTaskExecutor(", builder)
        self.assertIn("resolver: resolver", builder)
        self.assertIn("headless: ReconstructionHeadlessAnalysisExecutor(pool: pool)", builder)
        self.assertIn("native: native", builder)
        for forbidden in (
            "store",
            "WorkspaceStore",
            "NativeDecompilerPresentationModel",
            "NativeDecompilerPresentationState",
        ):
            with self.subTest(identifier=forbidden):
                self.assertNotIn(
                    forbidden,
                    builder,
                    "the production batch builder must construct its executor exclusively "
                    "from detached corpus authority and must not capture window state",
                )


if __name__ == "__main__":
    unittest.main()
