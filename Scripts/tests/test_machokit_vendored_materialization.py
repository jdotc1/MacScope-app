from __future__ import annotations

import json
import os
import stat
import shutil
import tempfile
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
COMPONENT = ROOT / "ThirdParty" / "MachOKit"
MATERIALIZATION = COMPONENT / "materialization"
WRAPPER = COMPONENT / "verify_materialization.sh"
MANIFEST = MATERIALIZATION / "MATERIALIZATION.json"


class VendoredMachOKitMaterializationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        # Git tracks executable bits, not read-only modes. Verify the frozen
        # external view consumed by builds, never chmod the source checkout.
        cls.temporary = tempfile.TemporaryDirectory()
        cls.materialization = Path(cls.temporary.name).resolve() / "materialization"
        for path in [MATERIALIZATION, *MATERIALIZATION.rglob("*")]:
            if path.is_symlink() or (path.is_file() and path.stat().st_nlink != 1):
                raise AssertionError(f"source materialization contains a link: {path}")
        shutil.copytree(MATERIALIZATION, cls.materialization, symlinks=True)
        for path in [*cls.materialization.rglob("*"), cls.materialization]:
            path.chmod(path.stat().st_mode & ~0o222)

    @classmethod
    def tearDownClass(cls) -> None:
        for path in [cls.materialization, *cls.materialization.rglob("*")]:
            path.chmod(path.stat().st_mode | 0o200)
        cls.temporary.cleanup()

    def test_committed_payload_passes_component_wrapper(self) -> None:
        completed = subprocess.run(
            [str(WRAPPER), "--materialization-root", str(self.materialization), "--quiet"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, "")

    def test_payload_has_reviewed_identity_and_no_links(self) -> None:
        manifest = json.loads((self.materialization / "MATERIALIZATION.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["provider"]["version"], "0.52.2")
        self.assertEqual(
            manifest["provider"]["revision"],
            "773e10797abc53914b94c2ee8c6f40f5da0b06eb",
        )
        self.assertEqual(
            manifest["tree_sha256"],
            "e6796548485d32a183c3e1641989d637f5f6344c9e5af5a9cfbb83f549007950",
        )
        for path in [MATERIALIZATION, *MATERIALIZATION.rglob("*"), self.materialization, *self.materialization.rglob("*")]:
            self.assertFalse(path.is_symlink(), path)
            if path.is_file():
                self.assertEqual(path.stat().st_nlink, 1, path)

    def test_payload_and_wrapper_are_network_independent_and_frozen(self) -> None:
        wrapper_source = WRAPPER.read_text(encoding="utf-8")
        self.assertNotIn("curl", wrapper_source)
        self.assertNotIn("git ", wrapper_source)
        self.assertNotIn("http://", wrapper_source)
        self.assertNotIn("https://", wrapper_source)
        for path in [self.materialization, *self.materialization.rglob("*")]:
            self.assertEqual(path.lstat().st_mode & 0o222, 0, path)
        self.assertTrue(WRAPPER.stat().st_mode & stat.S_IXUSR)


if __name__ == "__main__":
    unittest.main()
