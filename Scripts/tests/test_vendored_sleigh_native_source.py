from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "Scripts/dependencies/verify_vendored_sleigh_source.py"
WRAPPER = ROOT / "Scripts/dependencies/build_vendored_sleigh_native_source.sh"
SOURCE = ROOT / "ThirdParty/SleighNative/Source"


def load_verifier():
    specification = importlib.util.spec_from_file_location("vendored_sleigh_source", VERIFIER)
    assert specification and specification.loader
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class VendoredSleighNativeSourceTests(unittest.TestCase):
    def test_committed_source_closure_matches_exact_upstream_identities(self) -> None:
        module = load_verifier()
        analysis = module.verify_source(SOURCE)
        self.assertEqual(analysis["sleigh"]["treeSha256"], module.SLEIGH_TREE_SHA256)
        self.assertEqual(analysis["ghidra"]["treeSha256"], module.GHIDRA_TREE_SHA256)
        self.assertEqual(module.SLEIGH_REVISION, "bfd38a983b4aa53dd386365e1df5ed5499b7e2fb")
        self.assertEqual(module.GHIDRA_REVISION, "c0f584bf229fffba61b36431f3ce30c0c3e4e682")

    def test_source_tree_rejects_symlinks(self) -> None:
        module = load_verifier()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            member = root / "member"
            member.write_bytes(b"member")
            link = root / "link"
            link.symlink_to(member)
            with self.assertRaisesRegex(module.SourceContractError, "symlink"):
                module.analyze_tree(root)

    def test_manifest_rejects_duplicate_keys_and_non_object_values(self) -> None:
        module = load_verifier()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            duplicate = root / "duplicate.json"
            duplicate.write_text('{"schemaVersion":1,"schemaVersion":2}\n', encoding="utf-8")
            with self.assertRaisesRegex(module.SourceContractError, "duplicate key"):
                module.load_manifest(duplicate)
            non_object = root / "array.json"
            non_object.write_text("[]\n", encoding="utf-8")
            with self.assertRaisesRegex(module.SourceContractError, "must be an object"):
                module.load_manifest(non_object)

    def test_optional_bfd_bridge_is_absent_but_required_parser_output_is_present(self) -> None:
        module = load_verifier()
        ghidra = SOURCE / "ghidra"
        for relative in module.FORBIDDEN_OPTIONAL_GHIDRA_PATHS:
            self.assertFalse((ghidra / relative).exists(), relative)
        parser = ghidra / "Ghidra/Features/Decompiler/src/decompile/cpp/slghparse.cc"
        self.assertTrue(parser.is_file())
        self.assertFalse(parser.is_symlink())

    def test_wrapper_is_explicit_offline_and_not_part_of_normal_builds(self) -> None:
        wrapper = WRAPPER.read_text(encoding="utf-8")
        self.assertIn("-DFETCHCONTENT_FULLY_DISCONNECTED=ON", wrapper)
        self.assertIn("-DFETCHCONTENT_SOURCE_DIR_GHIDRASOURCE=", wrapper)
        self.assertIn("--work-root must be absolute", wrapper)
        lowered = wrapper.lower()
        for prohibited in ("curl ", "wget ", "git clone", "git fetch", "xcodebuild"):
            self.assertNotIn(prohibited, lowered)
        bootstrap = (ROOT / "Scripts/bootstrap.sh").read_text(encoding="utf-8")
        self.assertIn(WRAPPER.name, bootstrap)
        self.assertNotIn(WRAPPER.name, (ROOT / "Scripts/test.sh").read_text(encoding="utf-8"))

    def test_wrapper_rejects_relative_and_repository_work_roots(self) -> None:
        for work_root, diagnostic in (
            ("relative-work-root", "must be absolute"),
            (str(ROOT), "outside the repository"),
        ):
            completed = subprocess.run(
                [str(WRAPPER), "--work-root", work_root],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(diagnostic, completed.stderr)

    def test_package_qualification_rejects_missing_members(self) -> None:
        module = load_verifier()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            package = root / "package"
            governed = root / "governed"
            package.mkdir()
            governed.mkdir()
            with self.assertRaisesRegex(module.SourceContractError, "package member is missing"):
                module.qualify_package(package, governed)


if __name__ == "__main__":
    unittest.main()
