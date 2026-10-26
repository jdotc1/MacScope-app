from __future__ import annotations

import pathlib
import unittest


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]
FEATURE_ROOT = REPOSITORY_ROOT / "MacScope" / "Features" / "Reconstruction"
STATUS_PROJECTION = FEATURE_ROOT / "ReconstructionStatusProjection.swift"
ROUTE_SOURCE = (
    REPOSITORY_ROOT
    / "MacScope"
    / "Models"
    / "Reconstruction"
    / "ReconstructionDestinationRoute.swift"
)


class ReconstructionTask10PresentationBoundaryTests(unittest.TestCase):
    """Freeze the Task 10 rule that presentation and routes own no execution authority."""

    def swift_sources(self) -> list[pathlib.Path]:
        self.assertTrue(FEATURE_ROOT.is_dir(), f"missing Reconstruction feature root: {FEATURE_ROOT}")
        sources = sorted(FEATURE_ROOT.glob("*.swift"))
        self.assertTrue(sources, "Reconstruction feature root contains no Swift sources")
        return sources

    def test_presentation_cannot_construct_runtime_or_database_authority(self) -> None:
        forbidden = {
            "NSXPCConnection": "raw XPC connection",
            "NativeDecompilerXPCClient": "raw native-decompiler client",
            "NativeDecompilerProcessRuntime": "native process runtime",
            "NativeDecompilerRuntimeRegistry": "app-owned native runtime registry",
            "ReconstructionBatchScheduler(": "headless batch scheduler",
            "ReconstructionDatabaseOwner(": "database owner",
            "WorkspaceDatabase(": "workspace database",
            "sqlite3_": "raw SQLite operation",
            "Process(": "child process",
        }
        violations: list[str] = []
        for source in self.swift_sources():
            text = source.read_text(encoding="utf-8")
            for token, authority in forbidden.items():
                if token in text:
                    violations.append(f"{source.relative_to(REPOSITORY_ROOT)}: {authority} ({token})")
        self.assertEqual([], violations, "presentation acquired execution authority:\n" + "\n".join(violations))

    def test_presentation_imports_are_platform_ui_only(self) -> None:
        forbidden_imports = {"import SQLite3", "import Network", "import Darwin"}
        violations: list[str] = []
        for source in self.swift_sources():
            text = source.read_text(encoding="utf-8")
            for token in forbidden_imports:
                if token in text:
                    violations.append(f"{source.relative_to(REPOSITORY_ROOT)}: {token}")
        self.assertEqual([], violations, "presentation imports a lower-layer authority:\n" + "\n".join(violations))

    def test_control_availability_is_derived_through_the_job_state_machine(self) -> None:
        self.assertTrue(STATUS_PROJECTION.is_file(), "missing Task 10 status projection")
        text = STATUS_PROJECTION.read_text(encoding="utf-8")
        self.assertIn("struct ReconstructionControlProjection", text)
        state_machine_markers = (
            "ReconstructionJobStateMachine.transition",
            "ReconstructionJobStateMachine.canTransition",
            "ReconstructionJobStateMachine.allowed",
        )
        self.assertTrue(
            any(marker in text for marker in state_machine_markers),
            "control availability bypasses ReconstructionJobStateMachine",
        )
        self.assertNotIn("state = .paused", text)
        self.assertNotIn("state = .cancelled", text)

    def test_destination_route_is_value_only(self) -> None:
        self.assertTrue(ROUTE_SOURCE.is_file(), "missing value-only Reconstruction route")
        text = ROUTE_SOURCE.read_text(encoding="utf-8")
        forbidden = (
            "NSXPCConnection",
            "NativeDecompiler",
            "ReconstructionBatchScheduler",
            "ReconstructionDatabaseOwner",
            "WorkspaceDatabase",
            "URL(fileURLWithPath:",
            "Process(",
        )
        violations = [token for token in forbidden if token in text]
        self.assertEqual([], violations, f"route carries authority: {violations}")


if __name__ == "__main__":
    unittest.main()
