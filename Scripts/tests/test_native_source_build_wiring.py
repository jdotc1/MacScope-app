from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import unittest.mock


ROOT = Path(__file__).resolve().parents[2]
MODULE_ROOT = ROOT / "Scripts/native-decompiler-direct"
TEST_ROOT = ROOT / "Scripts/tests"
sys.path.insert(0, str(MODULE_ROOT))
sys.path.insert(0, str(TEST_ROOT))

import sleigh_package  # noqa: E402
import verify_sleigh_package  # noqa: E402
from test_sleigh_native_package import SleighPackageFixture  # noqa: E402


def toolchain_value() -> dict[str, object]:
    return {
        "compiler": {
            "path": "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++",
            "sha256": "1" * 64,
            "version": "Apple clang version 21.0.0 (clang-2100.3.33.1)",
        },
        "cmake": {
            "path": "/opt/homebrew/bin/cmake",
            "sha256": "2" * 64,
            "version": "cmake version 4.4.3",
        },
        "ninja": {
            "path": "/opt/homebrew/bin/ninja",
            "sha256": "3" * 64,
            "version": "1.13.2",
        },
    }


class NativeSourceBuildIdentityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.package = self.root / "package-fixture"
        self.package.mkdir()
        SleighPackageFixture(self.package).create()

    def publish(self) -> tuple[Path, dict[str, object]]:
        materialization = self.root / "materialization"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        output = materialization / "MATERIALIZATION.json"
        value = sleigh_package.write_source_materialization(
            materialization / "package", toolchain_value(), output
        )
        return materialization, value

    def test_tool_identity_names_tool_behind_basename_dispatched_shim(self) -> None:
        dispatcher = self.root / "dispatch" / "command-wrapper"
        dispatcher.parent.mkdir()
        dispatcher.write_text(
            '#!/bin/sh\ncase "${0##*/}" in\n'
            'cmake) exec "$REAL_TOOLS/cmake" "$@" ;;\n'
            '*) exit 2 ;;\nesac\n', encoding="utf-8"
        )
        dispatcher.chmod(0o755)
        shims = self.root / "shims"
        shims.mkdir()
        (shims / "cmake").symlink_to(dispatcher)
        real_tools = self.root / "real"
        real_tools.mkdir()
        real = real_tools / "cmake"
        real.write_text('#!/bin/sh\necho "cmake version 4.4.4"\n', encoding="utf-8")
        real.chmod(0o755)
        environment = {"PATH": f"{shims}:{real_tools}:/usr/bin:/bin", "REAL_TOOLS": str(real_tools)}
        with unittest.mock.patch.dict("os.environ", environment):
            identity = verify_sleigh_package._tool_identity(shims / "cmake", "source CMake")
        self.assertEqual(identity, {
            "path": str(real.resolve()),
            "sha256": verify_sleigh_package._sha256(real),
            "version": "cmake version 4.4.4",
        })

    def test_schema_two_source_build_round_trips_without_release_artifact_claim(self) -> None:
        materialization, value = self.publish()
        self.assertEqual(sleigh_package.verify_materialization(materialization), value)
        self.assertEqual(value["schemaVersion"], 2)
        self.assertEqual(value["componentId"], "sleigh-native-source-dcp03b4")
        self.assertNotIn("artifact", value)
        source_build = value["sourceBuild"]
        self.assertEqual(
            source_build["sourceManifestSha256"],
            "e5525e857e0a3f88aa7f8550e0d6b1a72ef232eedb61e6b31d24c350420ff1d8",
        )
        self.assertEqual(len(source_build["patches"]), 8)
        self.assertIn("FETCHCONTENT_FULLY_DISCONNECTED=ON", source_build["buildOptions"])

    def test_source_evidence_and_xcode_toolchain_line_are_fail_closed(self) -> None:
        materialization, value = self.publish()
        value["sourceBuild"]["sourceManifestSha256"] = "0" * 64
        (materialization / "MATERIALIZATION.json").write_text(
            sleigh_package.canonical_json(value) + "\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "frozen contract"):
            sleigh_package.verify_materialization(materialization)

        bad_toolchain = toolchain_value()
        bad_toolchain["compiler"]["version"] = "Apple clang version 20.0.0"
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "Xcode 27"):
            sleigh_package.source_materialization_value(
                sleigh_package.analyze_package(materialization / "package"),
                bad_toolchain,
            )

    def test_materialize_source_cli_records_actual_tool_evidence(self) -> None:
        materialization = self.root / "cli-materialization"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        tools = self.root / "tools"
        tools.mkdir()
        versions = {
            "compiler": "Apple clang version 21.0.0 (fixture)",
            "cmake": "cmake version 4.4.3",
            "ninja": "1.13.2",
        }
        paths: dict[str, Path] = {}
        for name, version in versions.items():
            path = tools / name
            path.write_text(f"#!/bin/sh\necho '{version}'\n", encoding="utf-8")
            path.chmod(0o755)
            paths[name] = path
        completed = subprocess.run(
            [
                sys.executable,
                str(MODULE_ROOT / "verify_sleigh_package.py"),
                "materialize-source",
                "--package-root",
                str(materialization / "package"),
                "--source-manifest",
                str(ROOT / "ThirdParty/SleighNative/Source/MATERIALIZATION.json"),
                "--compiler",
                str(paths["compiler"]),
                "--cmake",
                str(paths["cmake"]),
                "--ninja",
                str(paths["ninja"]),
                "--output",
                str(materialization / "MATERIALIZATION.json"),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        value = sleigh_package.verify_materialization(materialization)
        self.assertEqual(value["sourceBuild"]["toolchain"]["compiler"]["version"], versions["compiler"])
        self.assertEqual(set(materialization.iterdir()), {
            materialization / "MATERIALIZATION.json",
            materialization / "package",
        })

    def test_schema_one_release_materialization_remains_a_valid_rollback(self) -> None:
        materialization = self.root / "release-materialization"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        value = sleigh_package.materialization_value(
            sleigh_package.APPROVED_ARTIFACTS["macos-arm64"],
            sleigh_package.analyze_package(materialization / "package"),
        )
        (materialization / "MATERIALIZATION.json").write_text(
            sleigh_package.canonical_json(value) + "\n", encoding="utf-8"
        )
        self.assertEqual(sleigh_package.verify_materialization(materialization), value)


class NativeSourceBuildWiringTests(unittest.TestCase):
    def test_bootstrap_uses_exact_two_line_reusable_source_producer_contract(self) -> None:
        bootstrap = (ROOT / "Scripts/bootstrap.sh").read_text(encoding="utf-8")
        self.assertIn("build_vendored_sleigh_native_source.sh", bootstrap)
        self.assertIn("MACSCOPE_SLEIGH_SOURCE_BUILD_WORK_ROOT", bootstrap)
        self.assertIn("MACSCOPE_SLEIGH_MATERIALIZATION_WORK_ROOT", bootstrap)
        self.assertIn(
            '"${SLEIGH_ROOT}" != "${SLEIGH_SOURCE_BUILD_ROOT}/materialization"',
            bootstrap,
        )
        self.assertIn(
            "MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT = ${SLEIGH_SOURCE_BUILD_ROOT}",
            bootstrap,
        )
        self.assertNotIn(
            '"${SCRIPT_DIR}/native-decompiler-xpc/prepare_repository_sleigh_materialization.py"',
            bootstrap,
        )

    def test_builder_reuses_only_after_both_source_and_strict_qualification(self) -> None:
        wrapper = (
            ROOT / "Scripts/dependencies/build_vendored_sleigh_native_source.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('published_materialization="${published_root}/materialization"', wrapper)
        self.assertIn("materialize-source", wrapper)
        self.assertIn("verify_published_root", wrapper)
        self.assertIn('if [[ -e "${published_root}" || -L "${published_root}" ]]', wrapper)
        self.assertIn("SOURCE_BUILD_MATERIALIZATION.json", wrapper)
        self.assertIn("verify_sleigh_package.py", wrapper)
        self.assertNotIn("APPROVED_ARTIFACTS", wrapper)
        lowered = wrapper.lower()
        for prohibited in ("curl ", "wget ", "git clone", "git fetch", "xcodebuild"):
            self.assertNotIn(prohibited, lowered)

    def test_xcode_keeps_strict_stage_and_link_boundary(self) -> None:
        dependency = (ROOT / "MacScope/DependencyRoots.xcconfig").read_text(
            encoding="utf-8"
        )
        include = dependency.index('#include? "DependencyRoots.local.xcconfig"')
        self.assertLess(dependency.index("MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT ="), include)
        self.assertLess(dependency.index("MACSCOPE_SLEIGH_MATERIALIZATION_ROOT ="), include)

        project = (ROOT / "MacScope/project.yml").read_text(encoding="utf-8")
        self.assertIn("NativeDecompilerPackage/package/lib/libdecomp.a", project)
        self.assertIn("NativeDecompilerPackage/package/lib/libsla.a", project)
        self.assertNotIn("ThirdParty/SleighNative/package/lib/libdecomp.a", project)
        self.assertNotIn("$(MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT)/package", project)


if __name__ == "__main__":
    unittest.main()
