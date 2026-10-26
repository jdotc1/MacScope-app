from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "Scripts/dependencies/verify_vendored_sleigh_native.py"


def load_helper():
    specification = importlib.util.spec_from_file_location("vendored_sleigh", HELPER)
    assert specification and specification.loader
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class VendoredSleighNativeTests(unittest.TestCase):
    def test_committed_closure_matches_accepted_materialization(self) -> None:
        load_helper().verify(ROOT / "ThirdParty/SleighNative")

    def test_verifier_rejects_a_symlinked_package_member(self) -> None:
        module = load_helper()
        with tempfile.TemporaryDirectory() as temporary_directory:
            package = Path(temporary_directory) / "package"
            package.mkdir()
            (package / "member").write_bytes(b"member")
            (package / "link").symlink_to(package / "member")
            with self.assertRaisesRegex(ValueError, "symlink"):
                module.tree_digest(package)

    def test_verifier_rejects_identity_drift(self) -> None:
        module = load_helper()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "package").mkdir()
            source = ROOT / "ThirdParty/SleighNative/MATERIALIZATION.json"
            altered = source.read_text(encoding="utf-8").replace(
                "bfd38a983b4aa53dd386365e1df5ed5499b7e2fb", "0" * 40
            )
            (root / "MATERIALIZATION.json").write_text(altered, encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "sleighGitRevision"):
                module.verify(root)


if __name__ == "__main__":
    unittest.main()
