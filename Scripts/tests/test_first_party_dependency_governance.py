from __future__ import annotations

import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

from Scripts.tests.test_dependency_governance import GovernanceFixture, inventory, offline
from Scripts.tests.test_source_export_provenance import SourceRepository, canonical_json


ROOT = Path(__file__).resolve().parents[2]
MODULE = "ThirdParty/Lumen"
URL = "https://github.com/jdotc1/Lumen.git"
MATERIALIZER = "Scripts/dependencies/materialize_lumen_submodule.py"


class FirstPartyFixture:
    """Real local Git objects; only the tiny fixture's immutable revision differs."""

    def __init__(self, base: Path) -> None:
        self.source = SourceRepository(base / "source")
        self.dependency = SourceRepository(base / "dependency")
        self.dependency.write("Package.swift", "// swift-tools-version: 6.1\n")
        self.dependency.write("Sources/LumenTokens/Token.swift", "public let token = 1\n")
        self.dependency.write(".gitignore", ".build/\nignored.txt\n")
        self.dependency.git("add", ".")
        self.dependency.git("commit", "-m", "immutable first-party fixture")
        self.pin = self.dependency.git("rev-parse", "HEAD")
        self.source.git("-c", "protocol.file.allow=always", "submodule", "add",
                        str(self.dependency.root), MODULE)
        self.source.git("config", "-f", ".gitmodules", f"submodule.{MODULE}.url", URL)
        self.source.write(MATERIALIZER, "#!/usr/bin/env python3\n# Explicit offline fixture.\n")
        self.declaration = {
            "schema_version": 1,
            "components": [{
                "id": "lumen", "path": MODULE, "canonical_repository": URL,
                "git_revision": self.pin, "materialization_script": MATERIALIZER,
            }],
        }
        self.write_declaration()
        self.source.write("Scripts/bootstrap.sh", "#!/bin/sh\nexit 0\n")
        self.source.write("Scripts/test.sh", "#!/bin/sh\nexit 0\n")
        self.source.write("MacScope/project.yml", "name: Fixture\n")
        self.commit()

    @property
    def root(self) -> Path:
        return self.source.root

    def write_declaration(self) -> None:
        (self.root / "FIRST_PARTY_COMPONENTS.json").write_bytes(canonical_json(self.declaration))

    def commit(self) -> None:
        self.source.git("add", ".")
        self.source.git("commit", "-m", "bind first-party declaration")
        self.source.git("update-ref", "refs/remotes/gitfox-local/feature/task11-local-premerge-current", "HEAD")

    def export(self, destination: Path) -> Path:
        result = self.source.export(destination)
        if result.returncode:
            raise AssertionError(result.stderr)
        return destination


class FirstPartyDependencyGovernanceTests(unittest.TestCase):
    def setUp(self) -> None:
        # Fixture commits must not leave asynchronous Git maintenance in temporary trees.
        environment = mock.patch.dict(os.environ, {
            "GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "gc.auto", "GIT_CONFIG_VALUE_0": "0",
            "GIT_CONFIG_KEY_1": "maintenance.auto", "GIT_CONFIG_VALUE_1": "false",
        })
        environment.start()
        self.addCleanup(environment.stop)

    def fixture(self) -> FirstPartyFixture:
        temporary = tempfile.TemporaryDirectory(prefix="lumen-governance-", dir=ROOT.parent)
        self.addCleanup(temporary.cleanup)
        return FirstPartyFixture(Path(temporary.name))

    def test_registered_module_is_not_misclassified_as_external_license_inventory(self) -> None:
        fixture = self.fixture()
        fixture.source.write("ThirdParty/Unlisted/payload.bin", "unreviewed\n")
        discovered = inventory._discover_governed_files(fixture.root)
        self.assertEqual(discovered, {"ThirdParty/Unlisted/payload.bin"})

    def test_module_admin_and_ignored_debris_are_not_first_party_payload(self) -> None:
        fixture = self.fixture()
        module = fixture.root / MODULE
        (module / "ignored.txt").write_text("not source\n")
        (module / ".build").mkdir()
        (module / ".build/cache.bin").write_bytes(b"cache")
        fixture.source.write("MacScope/App/Main.swift", "unrelated development edit\n")
        self.assertEqual(inventory._discover_governed_files(fixture.root), set())

    def test_gitless_export_uses_the_same_first_party_ownership(self) -> None:
        fixture = self.fixture()
        exported = fixture.export(fixture.root.parent / "export")
        shutil.rmtree(fixture.root)
        shutil.rmtree(fixture.dependency.root)
        self.assertFalse((exported / ".git").exists())
        self.assertEqual(inventory._discover_governed_files(exported), set())

    def test_gitless_module_tampering_is_rejected(self) -> None:
        fixture = self.fixture()
        exported = fixture.export(fixture.root.parent / "export")
        (exported / MODULE / "Sources/LumenTokens/Token.swift").write_text("forged\n")
        with self.assertRaises(inventory.InventoryValidationError):
            inventory._discover_governed_files(exported)

    def test_gitless_unmanifested_module_file_is_rejected(self) -> None:
        fixture = self.fixture()
        exported = fixture.export(fixture.root.parent / "export")
        (exported / MODULE / "extra.swift").write_text("unexpected\n")
        with self.assertRaises(inventory.InventoryValidationError):
            inventory._discover_governed_files(exported)

    def test_git_index_flags_cannot_hide_modified_first_party_payload(self) -> None:
        fixture = self.fixture()
        module = fixture.root / MODULE
        relative = "Sources/LumenTokens/Token.swift"
        fixture.source.git("-C", str(module), "update-index", "--skip-worktree", relative)
        (module / relative).write_text("hidden modification\n")
        with self.assertRaisesRegex(inventory.InventoryValidationError,
                                    f"{MODULE}/{relative}: content differs$"):
            inventory._discover_governed_files(fixture.root)

    def test_payload_mismatch_names_mode_when_content_matches(self) -> None:
        fixture = self.fixture()
        relative = "Sources/LumenTokens/Token.swift"
        (fixture.root / MODULE / relative).chmod(0o600)
        with self.assertRaisesRegex(
                inventory.InventoryValidationError,
                f"{MODULE}/{relative}: mode is 0600, pinned 100644 requires 0644 \\(content matches\\)$"):
            inventory._discover_governed_files(fixture.root)

    def test_uncommitted_first_party_declaration_is_rejected(self) -> None:
        fixture = self.fixture()
        fixture.declaration["components"][0]["git_revision"] = "0" * 40
        fixture.write_declaration()
        with self.assertRaises(inventory.InventoryValidationError):
            inventory._discover_governed_files(fixture.root)

    def test_staged_declaration_cannot_be_hidden_by_restored_worktree(self) -> None:
        fixture = self.fixture()
        original = (fixture.root / "FIRST_PARTY_COMPONENTS.json").read_bytes()
        fixture.declaration["components"][0]["git_revision"] = "0" * 40
        fixture.write_declaration()
        fixture.source.git("add", "FIRST_PARTY_COMPONENTS.json")
        (fixture.root / "FIRST_PARTY_COMPONENTS.json").write_bytes(original)
        with self.assertRaises(inventory.InventoryValidationError):
            inventory._discover_governed_files(fixture.root)

    def test_wrong_registered_pin_or_url_is_rejected(self) -> None:
        for key, value in (("git_revision", "0" * 40),
                           ("canonical_repository", "https://example.invalid/other.git")):
            with self.subTest(key=key):
                fixture = self.fixture()
                fixture.declaration["components"][0][key] = value
                fixture.write_declaration()
                fixture.commit()
                with self.assertRaises(inventory.InventoryValidationError):
                    inventory._discover_governed_files(fixture.root)

    def test_dirty_or_missing_module_is_rejected_without_repair(self) -> None:
        for mutation in ("dirty", "missing"):
            with self.subTest(mutation=mutation):
                fixture = self.fixture()
                module = fixture.root / MODULE
                if mutation == "dirty":
                    (module / "Sources/LumenTokens/Token.swift").write_text("user edit\n")
                else:
                    module.rename(fixture.root.parent / "preserved-module")
                with self.assertRaises(inventory.InventoryValidationError):
                    inventory._discover_governed_files(fixture.root)
                if mutation == "dirty":
                    self.assertEqual((module / "Sources/LumenTokens/Token.swift").read_text(), "user edit\n")
                else:
                    self.assertFalse(module.exists())

    def test_undeclared_gitmodule_is_rejected(self) -> None:
        fixture = self.fixture()
        with (fixture.root / ".gitmodules").open("a") as stream:
            stream.write('[submodule "extra"]\npath = ThirdParty/Extra\nurl = https://example.invalid/extra.git\n')
        fixture.commit()
        with self.assertRaises(inventory.InventoryValidationError):
            inventory._discover_governed_files(fixture.root)

    def test_first_party_materializer_is_registered_as_explicit_offline_acquisition(self) -> None:
        fixture = self.fixture()
        materializers, ignored = offline._materializers(fixture.root, {"components": []})
        self.assertEqual(materializers, {MATERIALIZER: False})
        self.assertEqual(ignored, set())
        self.assertEqual(offline._validate_materializer_inventory(fixture.root, materializers), (MATERIALIZER,))
        fixture.source.write("Scripts/bootstrap.sh", f"#!/bin/sh\npython3 {MATERIALIZER}\n")
        with self.assertRaises(offline.OfflineBuildValidationError):
            offline._validate_normal_entrypoints(fixture.root, materializers)

    def test_first_party_offline_materializer_cannot_download_or_delegate_acquisition(self) -> None:
        for body in ("import urllib.request\nurllib.request.urlopen('https://example.invalid/source')\n",
                     "#!/bin/sh\n./Scripts/dependencies/materialize_network.py\n"):
            with self.subTest(body=body):
                fixture = self.fixture()
                fixture.source.write(MATERIALIZER, body)
                fixture.source.write("Scripts/dependencies/materialize_network.py", "#!/bin/sh\ncurl https://example.invalid/source\n")
                materializers = {MATERIALIZER: False, "Scripts/dependencies/materialize_network.py": True}
                with self.assertRaises(offline.OfflineBuildValidationError):
                    offline._validate_materializer_inventory(fixture.root, materializers)

    def release_inventory_fixture(self, source: str) -> Path:
        temporary = tempfile.TemporaryDirectory(prefix="lumen-release-governance-", dir=ROOT.parent)
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        GovernanceFixture(root)
        (root / "FIRST_PARTY_COMPONENTS.json").write_bytes((ROOT / "FIRST_PARTY_COMPONENTS.json").read_bytes())
        (root / MATERIALIZER).write_text("#!/usr/bin/env python3\n# Explicit offline fixture.\n")
        (root / "Scripts/generate_release_build_provenance.py").write_text(source)
        return root

    @staticmethod
    def release_inventory_source() -> str:
        return (
            "def selected_source_paths(repository_root):\n"
            "    selected: set[str] = set()\n"
            "    selected.update((\n"
            "        'FIRST_PARTY_COMPONENTS.json',\n"
            "        'Scripts/dependencies/first_party_components.py',\n"
            "        'Scripts/dependencies/materialize_lumen_submodule.py',\n"
            "    ))\n"
            "    return selected\n"
        )

    def test_release_inventory_can_record_first_party_acquisition_source_without_executing(self) -> None:
        root = self.release_inventory_fixture(self.release_inventory_source())
        try:
            summary = offline.validate_offline_build_surface(root)
        except offline.OfflineBuildValidationError as error:
            self.fail(f"declarative Release source selection is not acquisition: {error}")
        self.assertIn("Scripts/generate_release_build_provenance.py", summary.scanned_files)

    def test_release_inventory_allowance_does_not_hide_direct_or_indirect_acquisition(self) -> None:
        for invocation in (
            f"subprocess.run(['python3', '{MATERIALIZER}'])\n",
            f"script = '{MATERIALIZER}'\nsubprocess.run(['python3', script])\n",
            self.release_inventory_source().replace("selected_source_paths", "unrelated_execution"),
        ):
            with self.subTest(invocation=invocation):
                root = self.release_inventory_fixture(self.release_inventory_source() + invocation)
                with self.assertRaisesRegex(offline.OfflineBuildValidationError, "ordinary build helper.*dependency acquisition"):
                    offline.validate_offline_build_surface(root)

    def test_no_first_party_declaration_preserves_external_inventory_checks(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="lumen-legacy-governance-", dir=ROOT.parent)
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "ThirdParty/Unlisted").mkdir(parents=True)
        (root / "ThirdParty/Unlisted/payload.bin").write_bytes(b"external")
        self.assertEqual(inventory._discover_governed_files(root), {"ThirdParty/Unlisted/payload.bin"})


if __name__ == "__main__":
    unittest.main()
