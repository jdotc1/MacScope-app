from __future__ import annotations

import importlib.util
import json
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (
    ROOT
    / "Scripts/native-decompiler-xpc/prepare_repository_sleigh_materialization.py"
)
DIRECT_MODULE_ROOT = ROOT / "Scripts/native-decompiler-direct"
sys.path.insert(0, str(DIRECT_MODULE_ROOT))
sys.path.insert(0, str(ROOT / "Scripts/tests"))

import sleigh_package  # noqa: E402
from test_sleigh_native_package import SleighPackageFixture, canonical_manifest  # noqa: E402


def load_module():
    specification = importlib.util.spec_from_file_location(
        "prepare_repository_sleigh_materialization", SCRIPT
    )
    assert specification and specification.loader
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class RepositorySleighMaterializationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.component = self.root / "component"
        package = self.component / "package"
        package.mkdir(parents=True)
        SleighPackageFixture(package).create()
        manifest = canonical_manifest(package)
        (self.component / "MATERIALIZATION.json").write_text(
            sleigh_package.canonical_json(manifest) + "\n", encoding="utf-8"
        )
        (self.component / "README.md").write_text("component provenance\n", encoding="utf-8")
        (self.component / "AARCH64").mkdir()
        (self.component / "AARCH64/profile.record").write_text("record\n", encoding="utf-8")
        self.module = load_module()
        overlay = self.root / "overlay-package"
        shutil.copytree(package, overlay)
        shutil.copyfile(self.component / "AARCH64/profile.record",
                        overlay / self.module.LANGUAGES_RELATIVE / "profile.record")
        overlay_identity = sleigh_package.analyze_package(overlay)
        self.record = {
            "schemaVersion": 1,
            "componentId": "sleigh-native-dcp03b4-aarch64-patched-resources",
            "baseline": {
                "artifactSha256": manifest["artifact"]["sha256"],
                "packageTreeSha256": manifest["package"]["treeSha256"],
            },
            "patched": {
                "packageTreeSha256WithResourceOverlay": overlay_identity["treeSha256"],
                "packageFileCountWithResourceOverlay": overlay_identity["fileCount"],
                "packageTotalBytesWithResourceOverlay": overlay_identity["totalBytes"],
            },
        }
        (self.component / "PATCHED_RESOURCES.json").write_text(json.dumps(self.record))
        self.work_root = self.root / "external-work"
        self.destination = self.work_root / ("materialization-" +
            self.record["patched"]["packageTreeSha256WithResourceOverlay"][:16])

    def run_script(self, *, component: Path | None = None, work_root: Path | None = None):
        return subprocess.run(
            [
                sys.executable,
                "-B",
                str(SCRIPT),
                "--component-root",
                str(component or self.component),
                "--work-root",
                str(work_root or self.work_root),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_publishes_only_the_strict_runtime_closure(self) -> None:
        completed = self.run_script()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        destination = self.destination
        self.assertEqual(
            {path.name for path in destination.iterdir()},
            {"MATERIALIZATION.json", "package", "PATCHED_RESOURCES.json"},
        )
        self.module._verify_overlay(destination, self.record)
        identity = json.loads((destination / "MATERIALIZATION.json").read_text())
        self.assertEqual(identity, json.loads((self.component / "MATERIALIZATION.json").read_text()))
        self.assertIn(
            f"MACSCOPE_SLEIGH_MATERIALIZATION_ROOT={destination.resolve(strict=True)}",
            completed.stdout,
        )

    def test_prepare_output_is_admitted_by_the_package_consumer(self) -> None:
        completed = self.run_script()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        identity = sleigh_package.verify_materialization(self.destination)
        self.assertEqual(identity, json.loads(
            (self.component / "MATERIALIZATION.json").read_text()))

    def test_repeated_preparation_reuses_the_verified_publication(self) -> None:
        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        destination = self.destination
        identity_before = (destination.stat().st_dev, destination.stat().st_ino)
        second = self.run_script()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(identity_before, (destination.stat().st_dev, destination.stat().st_ino))

    def test_rejects_relative_or_repository_work_roots(self) -> None:
        module = load_module()
        with self.assertRaisesRegex(module.RepositoryMaterializationError, "absolute external"):
            module.prepare(self.component, Path("relative-work"))
        with self.assertRaisesRegex(module.RepositoryMaterializationError, "outside the repository"):
            module.prepare(self.component, ROOT / "generated-native-materialization")

    def test_invalid_source_or_existing_destination_is_never_replaced(self) -> None:
        (self.component / "package/linked").symlink_to("lib/libdecomp.a")
        rejected_source = self.run_script()
        self.assertNotEqual(rejected_source.returncode, 0)
        self.assertFalse(self.destination.exists())
        (self.component / "package/linked").unlink()

        destination = self.destination
        destination.mkdir(parents=True)
        poison = destination / "poison"
        poison.write_text("preserve\n", encoding="utf-8")
        rejected_existing = self.run_script()
        self.assertNotEqual(rejected_existing.returncode, 0)
        self.assertEqual(poison.read_text(encoding="utf-8"), "preserve\n")

    def test_reuse_rejects_links_and_extra_members(self) -> None:
        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        for name in ("package", "PATCHED_RESOURCES.json"):
            member = self.destination / name
            saved = self.root / ("saved-" + name)
            member.rename(saved)
            member.symlink_to(saved, target_is_directory=saved.is_dir())
            rejected = self.run_script()
            self.assertNotEqual(rejected.returncode, 0, name)
            member.unlink()
            saved.rename(member)
        extra = self.destination / "unadmitted"
        extra.write_text("preserve")
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(extra.read_text(), "preserve")

    def test_overlay_digest_must_be_canonical_hex(self) -> None:
        self.record["patched"]["packageTreeSha256WithResourceOverlay"] = "../" + "a" * 61
        (self.component / "PATCHED_RESOURCES.json").write_text(json.dumps(self.record))
        rejected = self.run_script()
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("record is malformed", rejected.stderr)

    def test_test_driver_uses_the_external_producer_only_for_the_default(self) -> None:
        driver = (ROOT / "Scripts/test.sh").read_text(encoding="utf-8")
        self.assertIn('if [[ -z "${MACSCOPE_SLEIGH_MATERIALIZATION_ROOT:-}" ]]', driver)
        self.assertIn("prepare_repository_sleigh_materialization.py", driver)
        self.assertIn("${TEST_DERIVED_DATA}/Dependencies/SleighNative", driver)
        self.assertIn("export MACSCOPE_SLEIGH_MATERIALIZATION_ROOT", driver)
        self.assertIn("${TEST_DERIVED_DATA}/Dependencies/GhosttySurface", driver)
        self.assertIn("export MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT", driver)

    def test_native_xcfilelists_close_every_static_and_generated_input(self) -> None:
        list_root = ROOT / "Scripts/native-decompiler-xpc"
        substitutions = {
            "$(SRCROOT)": str(ROOT / "MacScope"),
            "$(MACSCOPE_SLEIGH_MATERIALIZATION_ROOT)": str(
                ROOT / "ThirdParty/SleighNative"
            ),
        }
        generated_outputs = set()
        for name in (
            "NativeDecompilerBridgeOutputs.xcfilelist",
            "NativeDecompilerPackageOutputs.xcfilelist",
        ):
            generated_outputs.update((list_root / name).read_text().splitlines())

        static_inputs = []
        generated_inputs = []
        for name in (
            "NativeDecompilerBridgeInputs.xcfilelist",
            "NativeDecompilerPackageInputs.xcfilelist",
            "NativeDecompilerBridgeGoldenInputs.xcfilelist",
        ):
            for line in (list_root / name).read_text().splitlines():
                expanded = line
                for token, replacement in substitutions.items():
                    expanded = expanded.replace(token, replacement)
                if "$(" in expanded:
                    generated_inputs.append(line)
                    continue
                static_inputs.append(Path(expanded))

        missing = [path for path in static_inputs if not path.exists()]
        self.assertEqual(missing, [])
        for line in generated_inputs:
            self.assertTrue(
                line.startswith("$(SDKROOT)/") or line in generated_outputs,
                f"generated native input lacks a declared producer: {line}",
            )
        self.assertGreater(len(static_inputs), 100)
        self.assertGreater(len(generated_inputs), 0)


if __name__ == "__main__":
    unittest.main()
