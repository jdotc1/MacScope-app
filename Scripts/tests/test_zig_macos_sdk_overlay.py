import json
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = ROOT / "Scripts" / "prepare_zig_macos_sdk_overlay.py"


class ZigMacOSSDKOverlayTests(unittest.TestCase):
    def make_sdk(self, root: pathlib.Path, *, include_arm64: bool) -> pathlib.Path:
        sdk = root / "MacOSX27.0.sdk"
        library = sdk / "usr/lib"
        library.mkdir(parents=True)
        targets = "arm64-macos, arm64e-macos" if include_arm64 else "arm64e-macos"
        (library / "libSystem.B.tbd").write_text(
            "--- !tapi-tbd\n"
            "tbd-version: 4\n"
            f"targets: [ x86_64-macos, {targets} ]\n"
            "install-name: '/usr/lib/libSystem.B.dylib'\n"
            "exports:\n"
            f"  - targets: [ x86_64-macos, {targets} ]\n"
            "    symbols: [ _abort ]\n"
            + (
                "--- !tapi-tbd\n"
                "tbd-version: 4\n"
                "targets: [ x86_64-macos, arm64-macos, arm64e-macos ]\n"
                "install-name: '/usr/lib/system/libauxiliary.dylib'\n"
                if not include_arm64
                else ""
            ),
            encoding="utf-8",
        )
        (library / "libSystem.tbd").symlink_to("libSystem.B.tbd")
        (sdk / "System/Library/Frameworks").mkdir(parents=True)
        (sdk / "usr/include").mkdir(parents=True)
        return sdk

    def run_helper(
        self, sdk: pathlib.Path, output: pathlib.Path
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "/usr/bin/python3",
                "-B",
                str(HELPER),
                "prepare",
                "--sdk-root",
                str(sdk),
                "--output-root",
                str(output),
                "--xcrun",
                "/usr/bin/xcrun",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_arm64e_only_sdk_gets_closed_compatibility_overlay(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            sdk = self.make_sdk(root, include_arm64=False)
            result = self.run_helper(sdk, root / "compatibility")

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            record = json.loads(result.stdout)
            self.assertTrue(record["compatibility_applied"])
            effective = pathlib.Path(record["effective_sdk_root"])
            libsystem = (effective / "usr/lib/libSystem.B.tbd").read_text()
            self.assertIn("arm64-macos", libsystem)
            self.assertIn("arm64e-macos", libsystem)
            self.assertEqual(record["sdk_root"], str(sdk.resolve()))
            self.assertEqual(len(record["source_libsystem_sha256"]), 64)

            shim = pathlib.Path(record["xcrun_shim_dir"]) / "xcrun"
            shown = subprocess.run(
                [str(shim), "--sdk", "macosx", "--show-sdk-path"],
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertEqual(shown.stdout.strip(), str(effective))

    def test_native_arm64_sdk_is_used_without_overlay(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            sdk = self.make_sdk(root, include_arm64=True)
            output = root / "unused-compatibility"
            result = self.run_helper(sdk, output)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            record = json.loads(result.stdout)
            self.assertFalse(record["compatibility_applied"])
            self.assertEqual(record["effective_sdk_root"], str(sdk.resolve()))
            self.assertIsNone(record["xcrun_shim_dir"])
            self.assertFalse(output.exists())

    def test_existing_overlay_is_verified_before_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            sdk = self.make_sdk(root, include_arm64=False)
            output = root / "compatibility"
            first = self.run_helper(sdk, output)
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)

            generated = output / "sdk/usr/lib/libSystem.B.tbd"
            generated.chmod(0o644)
            generated.write_text("forged")
            second = self.run_helper(sdk, output)

            self.assertNotEqual(second.returncode, 0)
            self.assertIn("existing SDK compatibility overlay failed verification", second.stderr)

    def test_existing_overlay_rejects_unmanifested_entries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            sdk = self.make_sdk(root, include_arm64=False)
            output = root / "compatibility"
            first = self.run_helper(sdk, output)
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)

            (output / "sdk/unmanifested").write_text("forged")
            second = self.run_helper(sdk, output)

            self.assertNotEqual(second.returncode, 0)
            self.assertIn("existing SDK compatibility overlay failed verification", second.stderr)


if __name__ == "__main__":
    unittest.main()
