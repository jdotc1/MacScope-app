from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from Scripts.dependencies.audit_dependency_census import DependencyCensusError, audit_dependency_census
from Scripts.dependencies.validate_third_party_components import InventoryValidationError
from Scripts.tests.test_dependency_governance import (
    GovernanceFixture, UNMATERIALIZED_LUMEN_ERROR, hosted_unmaterialized_lumen,
)


ROOT = Path(__file__).resolve().parents[2]


class DependencyCensusTests(unittest.TestCase):
    def test_repository_census_is_complete_and_ordered(self) -> None:
        if hosted_unmaterialized_lumen(ROOT):
            with self.assertRaisesRegex(InventoryValidationError, UNMATERIALIZED_LUMEN_ERROR):
                audit_dependency_census(ROOT)
            temporary = tempfile.TemporaryDirectory()
            self.addCleanup(temporary.cleanup)
            fixture = GovernanceFixture(Path(temporary.name))
            result = audit_dependency_census(fixture.root)
        else:
            result = audit_dependency_census(ROOT)
        self.assertEqual(result["surface_count"], 3)
        self.assertEqual(result["repository_input_count"], 5)
        self.assertEqual(result["source_dependency_count"], 3)
        self.assertEqual(result["external_input_count"], 2)
        self.assertEqual(result["component_count"], 17)
        census = json.loads((ROOT / "docs/dependencies/DEPENDENCY_CENSUS.md").read_text())
        self.assertIn("entitlements-comparison", census["approved_source_components"])
        self.assertEqual(result["blockers"][0]["id"], "DEP-REPOSITORY-SOURCE-AUTHORITY")
        self.assertEqual(result["blockers"][0]["status"], "closed")

    def _surface_fixture(self) -> tuple[tempfile.TemporaryDirectory[str], Path, dict]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        contents = {
            "Scripts/bootstrap.sh": (
                "ThirdParty/GhosttyVT/Source "
                "dependencies/build_vendored_ghostty_surface.sh "
                "ThirdParty/SleighNative ThirdParty/MachOKit/materialization "
                "ThirdParty/XcodeGen/bin/xcodegen xcode27_env.sh"
            ),
            "Scripts/test.sh": "bootstrap.sh xcode27_env.sh",
            "MacScope/Services/Phase2/QualificationGate/Phase2QualificationGateRuntimeCollector.swift": (
                "http://127.0.0.1:1234"
            ),
        }
        for relative, text in contents.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        census = json.loads(
            (ROOT / "docs/dependencies/DEPENDENCY_CENSUS.md").read_text(encoding="utf-8")
        )
        census_path = root / "docs/dependencies/DEPENDENCY_CENSUS.md"
        census_path.parent.mkdir(parents=True)
        return temporary, root, census

    def _write_census(self, root: Path, census: dict) -> None:
        (root / "docs/dependencies/DEPENDENCY_CENSUS.md").write_text(
            json.dumps(census), encoding="utf-8"
        )

    def test_unrecorded_resolution_fails_closed(self) -> None:
        temporary, root, census = self._surface_fixture()
        with temporary:
            census["surfaces"][0]["inputs"][0]["resolution"] = "UNRECORDED_ROOT"
            self._write_census(root, census)
            with self.assertRaisesRegex(DependencyCensusError, "does not evidence resolution"):
                audit_dependency_census(root)

    def test_scattered_resolution_tokens_fail_closed(self) -> None:
        temporary, root, census = self._surface_fixture()
        with temporary:
            bootstrap = root / "Scripts/bootstrap.sh"
            bootstrap.write_text(
                bootstrap.read_text(encoding="utf-8").replace(
                    "ThirdParty/GhosttyVT/Source",
                    "ThirdParty elsewhere GhosttyVT elsewhere Source",
                ),
                encoding="utf-8",
            )
            self._write_census(root, census)
            with self.assertRaisesRegex(DependencyCensusError, "does not evidence resolution"):
                audit_dependency_census(root)

    def test_duplicate_bootstrap_manifest_component_fails_closed(self) -> None:
        temporary, root, census = self._surface_fixture()
        with temporary:
            census["surfaces"][0]["inputs"][1]["manifest_component"] = "ghostty-vt"
            self._write_census(root, census)
            with self.assertRaisesRegex(DependencyCensusError, "duplicate manifest_component"):
                audit_dependency_census(root)

    def test_duplicate_finding_id_fails_closed(self) -> None:
        temporary, root, census = self._surface_fixture()
        with temporary:
            duplicate = dict(census["ordered_blockers"][-1])
            duplicate["priority"] = census["ordered_blockers"][-1]["priority"] + 1
            census["ordered_blockers"].append(duplicate)
            self._write_census(root, census)
            with self.assertRaisesRegex(DependencyCensusError, "duplicate id"):
                audit_dependency_census(root)

    def test_legacy_external_ghostty_root_fails_closed(self) -> None:
        temporary, root, census = self._surface_fixture()
        with temporary:
            census["surfaces"][0]["inputs"][0][
                "resolution"
            ] = "MACSCOPE_GHOSTTY_SOURCE_DIR"
            self._write_census(root, census)
            with self.assertRaisesRegex(DependencyCensusError, "legacy dependency authority"):
                audit_dependency_census(root)

    def test_path_xcodegen_authority_fails_closed(self) -> None:
        temporary, root, census = self._surface_fixture()
        with temporary:
            census["surfaces"][0]["inputs"][4]["resolution"] = "command -v/xcodegen"
            self._write_census(root, census)
            with self.assertRaisesRegex(DependencyCensusError, "legacy dependency authority"):
                audit_dependency_census(root)


if __name__ == "__main__":
    unittest.main()
