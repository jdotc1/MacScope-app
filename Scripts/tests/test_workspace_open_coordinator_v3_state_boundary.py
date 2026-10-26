#!/usr/bin/env python3
"""Freeze the package-v3 state handoff at the document-open boundary."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
COORDINATOR = ROOT / "MacScope/App/WorkspaceOpenCoordinator.swift"


def bounded_section(text: str, start: str, end: str) -> str:
    start_index = text.find(start)
    if start_index < 0:
        raise AssertionError(f"missing source boundary start: {start}")
    end_index = text.find(end, start_index + len(start))
    if end_index < 0:
        raise AssertionError(f"missing source boundary end: {end}")
    return text[start_index:end_index]


class WorkspaceOpenCoordinatorVersion3StateBoundaryTests(unittest.TestCase):
    def test_open_preflight_and_behavioral_test_bind_the_reader_validated_state(self) -> None:
        coordinator = COORDINATOR.read_text(encoding="utf-8")
        preflight = bounded_section(
            coordinator,
            "let package = try await io.readValidated(from: observed.location)",
            "let currentEpoch = try await publicationAdmissionEpochWhenQuiescent()",
        )
        self.assertEqual(preflight.count("MacScopeDocumentPackage.validatedContents("), 1)
        self.assertEqual(
            preflight.count("reconstructionState: package.reconstructionState"),
            1,
            "the complete reader-validated v3 state must cross the redundant preflight",
        )



if __name__ == "__main__":
    unittest.main()
