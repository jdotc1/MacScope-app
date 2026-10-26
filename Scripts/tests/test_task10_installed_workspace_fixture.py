#!/usr/bin/env python3
"""Govern the real persisted workspace used by Task 10's installed-app UI proof."""

from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "MacScope" / "project.yml"
FIXTURES = ROOT / "MacScope" / "Tests" / "MacScopeInstalledAppUITests" / "Fixtures"
PACKAGE = FIXTURES / "Task10PersistedWorkspace.mscope"
SIDECAR = FIXTURES / "Task10PersistedWorkspace.fixture.json"


def package_tree_sha256(package: Path) -> str:
    hasher = hashlib.sha256()
    for path in sorted(candidate for candidate in package.rglob("*") if candidate.is_file() and not candidate.is_symlink()):
        hasher.update(path.relative_to(package).as_posix().encode("utf-8"))
        hasher.update(b"\0")
        hasher.update(path.read_bytes())
        hasher.update(b"\0")
    return hasher.hexdigest()


class Task10InstalledWorkspaceFixtureTests(unittest.TestCase):
    def test_product_generated_fixture_matches_its_recorded_integrity(self) -> None:
        sidecar = json.loads(SIDECAR.read_text(encoding="utf-8"))
        self.assertEqual(sidecar["schemaVersion"], 1)
        self.assertEqual(sidecar["generator"], "WorkspaceStore.writeDocumentPackage")
        self.assertEqual(sidecar["workspaceName"], "Task 10 persisted workspace")
        self.assertRegex(sidecar["packageTreeSHA256"], r"^[0-9a-f]{64}$")
        self.assertEqual(
            package_tree_sha256(PACKAGE),
            sidecar["packageTreeSHA256"],
            "Task 10's checked-in .mscope fixture must match the tree digest emitted by its production-persistence generator",
        )

    def test_xcodegen_preserves_the_workspace_as_a_folder_resource(self) -> None:
        project = PROJECT.read_text(encoding="utf-8")
        package_declaration = (
            "      - path: Tests/MacScopeInstalledAppUITests/Fixtures/Task10PersistedWorkspace.mscope\n"
            "        type: folder"
        )
        self.assertIn(
            package_declaration,
            project,
            "Task 10's persisted workspace must remain an opaque folder resource, not a flattened source glob",
        )
        self.assertIn(
            "      - path: Tests/MacScopeInstalledAppUITests/Fixtures/Task10PersistedWorkspace.fixture.json",
            project,
        )
        self.assertIn('          - "Fixtures/**"', project)


if __name__ == "__main__":
    unittest.main()
