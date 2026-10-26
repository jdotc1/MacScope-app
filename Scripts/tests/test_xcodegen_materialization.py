from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "dependencies" / "materialize_xcodegen.py"
VENDOR = ROOT / "ThirdParty" / "XcodeGen"
BOOTSTRAP = ROOT / "Scripts" / "bootstrap.sh"


def load_module():
    specification = importlib.util.spec_from_file_location("materialize_xcodegen_test", SCRIPT)
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


MODULE = load_module()


class XcodeGenMaterializationTests(unittest.TestCase):
    def test_hosted_tests_build_lumen_without_becoming_a_second_link_owner(self) -> None:
        # Parse the actual project spec with the governed generator. Linking the
        # package into both the host and its tests promotes automatic products
        # to dynamic frameworks, violating the ordinary prepared-product tree.
        # Dumping does not require bootstrap's machine-local dependency links.
        parsed = subprocess.run([
            str(MODULE.verify_tool(VENDOR / "bin" / "xcodegen")), "dump",
            "--spec", str(ROOT / "MacScope/project.yml"), "--type", "json", "--no-env",
        ], check=False, capture_output=True, text=True)
        self.assertEqual(parsed.returncode, 0, parsed.stdout + parsed.stderr)
        targets = json.loads(parsed.stdout)["targets"]
        expected = {"LumenTokens", "LumenUI", "LumenConformance"}
        for target_name in ("MacScopeApp", "CoreTests"):
            dependencies = [item for item in targets[target_name]["dependencies"]
                            if item.get("package") == "Lumen"]
            self.assertEqual({item["product"] for item in dependencies}, expected)
            self.assertEqual(len(dependencies), len(expected))
            for dependency in dependencies:
                if target_name == "CoreTests":
                    self.assertIs(dependency.get("link"), False,
                                  "Hosted tests must not relink the host-owned Lumen products")
                    self.assertIs(dependency.get("embed"), False,
                                  "Hosted tests must not embed Lumen frameworks")
                else:
                    self.assertTrue(dependency.get("link", True),
                                    "The app remains the Lumen product link owner")
        tests = targets["CoreTests"]
        self.assertIn("MacScopeApp", {item.get("target") for item in tests["dependencies"]})
        settings = tests["settings"]["base"]
        self.assertEqual(settings["BUNDLE_LOADER"], "$(TEST_HOST)")
        self.assertEqual(settings["TEST_HOST"], "$(BUILT_PRODUCTS_DIR)/MacScope.app/Contents/MacOS/MacScope")

    def test_live_materialization_is_exact_and_offline_verifiable(self) -> None:
        self.assertEqual(MODULE.verify_root(VENDOR), VENDOR)
        self.assertEqual(
            MODULE.verify_tool(VENDOR / "bin" / "xcodegen"),
            VENDOR / "bin" / "xcodegen",
        )

    def test_tool_override_requires_exact_governed_root_member(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            copied = root / "xcodegen"
            shutil.copy2(VENDOR / "bin" / "xcodegen", copied)
            with self.assertRaisesRegex(MODULE.VerificationError, "bin/xcodegen"):
                MODULE.verify_tool(copied)

            link = root / "linked-xcodegen"
            link.symlink_to(VENDOR / "bin" / "xcodegen")
            with self.assertRaisesRegex(MODULE.VerificationError, "symbolic link"):
                MODULE.verify_tool(link)

    def test_bootstrap_has_no_ambient_xcodegen_authority(self) -> None:
        bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
        self.assertIn("verify-tool --binary", bootstrap)
        self.assertNotIn("command -v xcodegen", bootstrap)

    def test_rejects_binary_drift_and_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "vendor"
            shutil.copytree(VENDOR, root, symlinks=True)
            binary = root / "bin" / "xcodegen"
            binary.write_bytes(binary.read_bytes() + b"drift")
            with self.assertRaisesRegex(MODULE.VerificationError, "executable checksum"):
                MODULE.verify_root(root)

            shutil.rmtree(root)
            shutil.copytree(VENDOR, root, symlinks=True)
            binary.unlink()
            binary.symlink_to(VENDOR / "bin" / "xcodegen")
            with self.assertRaisesRegex(MODULE.VerificationError, "symbolic link"):
                MODULE.verify_root(root)

    def test_rejects_archive_identity_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "vendor"
            shutil.copytree(VENDOR, root)
            archive = root / "source" / MODULE.ARCHIVE_NAME
            archive.write_bytes(archive.read_bytes() + b"drift")
            with self.assertRaisesRegex(MODULE.VerificationError, "archive checksum"):
                MODULE.verify_root(root)

    def test_explicit_replacement_requires_new_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "replacement"
            MODULE.materialize(VENDOR / "source" / MODULE.ARCHIVE_NAME, VENDOR / "bin" / "xcodegen", destination)
            self.assertEqual(MODULE.verify_root(destination), destination)
            with self.assertRaisesRegex(MODULE.VerificationError, "already exists"):
                MODULE.materialize(VENDOR / "source" / MODULE.ARCHIVE_NAME, VENDOR / "bin" / "xcodegen", destination)


if __name__ == "__main__":
    unittest.main()
