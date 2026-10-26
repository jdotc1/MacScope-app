from pathlib import Path
import os
import tempfile
import unittest

from Scripts.reconstruction.qualification_xctestrun import resolve_xctestrun


class QualificationXctestrunTests(unittest.TestCase):
    def test_adaptive_execution_overlays_require_and_preserve_exact_base_plan(self):
        scheme = "MacScopeInstalledAppUITests"
        base = self.root / f"{scheme}_macosx27.2-arm64.xctestrun"
        for suffix in ("AdaptivePaneOptIn", "AdaptivePaneOptIn-Retry1", "AdaptivePaneOptIn-Retry12"):
            base.with_name(f"{base.stem}-{suffix}.xctestrun").write_bytes(b"execution overlay")
        for allow_missing in (False, True):
            with self.assertRaises(ValueError):
                resolve_xctestrun(self.root, scheme, "27.2", allow_missing=allow_missing)
        base.write_bytes(b"prepared plan")
        self.assertEqual(resolve_xctestrun(self.root, scheme, "27.2"), base)

    def test_adaptive_overlay_near_matches_and_indirection_remain_rejected(self):
        scheme = "MacScopeInstalledAppUITests"
        stem = f"{scheme}_macosx27.2-arm64"
        base = self.root / f"{stem}.xctestrun"
        base.write_bytes(b"prepared")
        for name in (
            f"{stem}-AdaptivePaneOptIn-Retry0.xctestrun",
            f"{stem}-AdaptivePaneOptIn-Retry01.xctestrun",
            f"{stem}-AdaptivePaneOptIn-Retry.xctestrun",
            f"{stem}-AdaptivePaneOptIn-Retry-1.xctestrun",
            f"{scheme}_macosx27.0-arm64-AdaptivePaneOptIn.xctestrun",
            f"{scheme}_macosx27.2-x86_64-AdaptivePaneOptIn.xctestrun",
        ):
            other = self.root / name
            other.write_bytes(b"other")
            with self.subTest(name=name), self.assertRaises(ValueError):
                resolve_xctestrun(self.root, scheme, "27.2")
            other.unlink()
        overlay = self.root / f"{stem}-AdaptivePaneOptIn.xctestrun"
        for kind in ("symlink", "hardlink"):
            overlay.symlink_to(base) if kind == "symlink" else os.link(base, overlay)
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                resolve_xctestrun(self.root, scheme, "27.2")
            overlay.unlink()
        native_stem = "MacScopeApp_macosx27.2-arm64"
        (self.root / f"{native_stem}.xctestrun").write_bytes(b"prepared")
        (self.root / f"{native_stem}-AdaptivePaneOptIn.xctestrun").write_bytes(b"wrong scheme")
        with self.assertRaises(ValueError):
            resolve_xctestrun(self.root, "MacScopeApp", "27.2")

    def test_exact_task10_execution_overlay_does_not_replace_or_ambiguate_base_plan(self):
        scheme = "MacScopeInstalledAppUITests"
        base = self.root / f"{scheme}_macosx27.2-arm64.xctestrun"
        overlay = base.with_name(f"{base.stem}-Task10OptIn-{'a' * 64}.xctestrun")
        overlay.write_bytes(b"separately receipt-validated execution overlay")
        for allow_missing in (False, True):
            with self.assertRaises(ValueError):
                resolve_xctestrun(self.root, scheme, "27.2", allow_missing=allow_missing)
        base.write_bytes(b"prepared plan")
        self.assertEqual(resolve_xctestrun(self.root, scheme, "27.2"), base)

    def test_overlay_near_matches_and_indirection_remain_rejected(self):
        scheme = "MacScopeInstalledAppUITests"
        stem = f"{scheme}_macosx27.2-arm64"
        base = self.root / f"{stem}.xctestrun"
        base.write_bytes(b"prepared")
        for name in (
            f"{stem}-Task10OptIn-{'a' * 63}.xctestrun",
            f"{stem}-Task10OptIn-{'A' * 64}.xctestrun",
            f"{stem}-Unregistered-{'a' * 64}.xctestrun",
            f"{scheme}_macosx27.0-arm64-Task10OptIn-{'a' * 64}.xctestrun",
            f"{scheme}_macosx27.2-x86_64-Task10OptIn-{'a' * 64}.xctestrun",
        ):
            other = self.root / name
            other.write_bytes(b"other")
            with self.subTest(name=name), self.assertRaises(ValueError):
                resolve_xctestrun(self.root, scheme, "27.2")
            other.unlink()
        overlay = self.root / f"{stem}-Task10OptIn-{'a' * 64}.xctestrun"
        overlay.symlink_to(base)
        with self.assertRaises(ValueError):
            resolve_xctestrun(self.root, scheme, "27.2")

    def test_native_scheme_does_not_admit_task10_overlay_lookalike(self):
        stem = "MacScopeApp_macosx27.2-arm64"
        (self.root / f"{stem}.xctestrun").write_bytes(b"prepared")
        (self.root / f"{stem}-Task10OptIn-{'a' * 64}.xctestrun").write_bytes(b"not a governed UI overlay")
        with self.assertRaises(ValueError):
            resolve_xctestrun(self.root, "MacScopeApp", "27.2")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def test_current_minor_sdk_and_patch_are_exact_not_deployment_target(self):
        for sdk in ("27.0", "27.2", "27.2.1"):
            with self.subTest(sdk=sdk):
                product = self.root / f"MacScopeApp_macosx{sdk}-arm64.xctestrun"
                product.write_bytes(b"prepared")
                self.assertEqual(resolve_xctestrun(self.root, "MacScopeApp", sdk), product)
                product.unlink()

    def test_missing_is_only_permitted_for_prebuild_inventory(self):
        with self.assertRaises(ValueError):
            resolve_xctestrun(self.root, "MacScopeApp", "27.2")
        result = resolve_xctestrun(self.root, "MacScopeApp", "27.2", allow_missing=True)
        self.assertFalse(result.exists())

    def test_wrong_sdk_architecture_and_ambiguous_products_fail_closed(self):
        expected = self.root / "MacScopeApp_macosx27.2-arm64.xctestrun"
        for name in ("MacScopeApp_macosx27.0-arm64.xctestrun", "MacScopeApp_macosx27.2-x86_64.xctestrun"):
            other = self.root / name
            other.write_bytes(b"other")
            for present in (False, True):
                if present:
                    expected.write_bytes(b"expected")
                with self.assertRaises(ValueError):
                    resolve_xctestrun(self.root, "MacScopeApp", "27.2", allow_missing=True)
            expected.unlink()
            other.unlink()

    def test_rejects_symlink_hardlink_directory_and_empty_file(self):
        expected = self.root / "MacScopeApp_macosx27.2-arm64.xctestrun"
        target = self.root / "target"
        target.write_bytes(b"target")
        for kind in ("symlink", "hardlink", "directory", "empty"):
            if kind == "symlink":
                expected.symlink_to(target)
            elif kind == "hardlink":
                os.link(target, expected)
            elif kind == "directory":
                expected.mkdir()
            else:
                expected.touch()
            with self.assertRaises(ValueError):
                resolve_xctestrun(self.root, "MacScopeApp", "27.2")
            expected.rmdir() if kind == "directory" else expected.unlink()

    def test_rejects_root_indirection_unknown_scheme_and_sdk(self):
        alias = self.root / "alias"
        actual = self.root / "actual"
        actual.mkdir()
        alias.symlink_to(actual, target_is_directory=True)
        for root, scheme, sdk in ((alias, "MacScopeApp", "27.2"), (Path("relative"), "MacScopeApp", "27.2"), (self.root, "Unknown", "27.2"), (self.root, "MacScopeApp", "28.0"), (self.root, "MacScopeApp", "27.2/../27.0")):
            with self.subTest(root=root, scheme=scheme, sdk=sdk), self.assertRaises(ValueError):
                resolve_xctestrun(root, scheme, sdk, allow_missing=True)
