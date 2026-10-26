#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import os
import subprocess
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "Scripts/qualification/restore_build_source.py"
SPEC = importlib.util.spec_from_file_location("restore_build_source", TOOL)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RestoreBuildSourceTests(unittest.TestCase):
    def _fixture(self, root: Path, name: str = "fixture") -> tuple[Path, Path, Path]:
        self.cache = root / "shared parser cache.noindex"
        self.cache.mkdir()
        run = root / "runs" / f"run.{name}"
        source = run / "source"
        macscope = source / "MacScope"
        machokit = run / "private-machokit-input"
        project = macscope / "MacScope.xcodeproj"
        project.mkdir(parents=True)
        machokit.mkdir()
        (macscope / "project.yml").write_text("name: Fixture\n", encoding="utf-8")
        (macscope / "DependencyRoots.local.xcconfig").write_bytes(
            self._bootstrap_xcconfig(source, machokit)
        )
        (macscope / "DependencyRoots.local.xcconfig").chmod(0o600)
        for relative in MODULE.GENERATED_PROJECT_DIRECTORIES:
            (project / relative).mkdir(parents=True, exist_ok=True)
        for relative in MODULE.GENERATED_PROJECT_FILES:
            generated = project / relative
            generated.parent.mkdir(parents=True, exist_ok=True)
            generated.write_text(f"// generated {relative}\n", encoding="utf-8")
        (macscope / "LocalPackages").symlink_to(machokit, target_is_directory=True)
        return source, machokit, macscope

    def _bootstrap_xcconfig(
        self, source: Path, machokit: Path, pattern_adapter_root: Path | None = None,
    ) -> bytes:
        # Exercise the real producer template only: never run bootstrap,
        # dependency verification, a sealed export or Xcode in these fixtures.
        bootstrap = (ROOT / "Scripts/bootstrap.sh").read_text()
        template = bootstrap.split("<<XCCONFIG\n", 1)[1].split("\nXCCONFIG", 1)[0]
        run = source.parent
        surface = run / "dependencies/ghostty-surface"
        artifact = surface / "GhosttySurface/macos/GhosttyKit.xcframework"
        sleigh = run / "dependencies/sleigh-native-source/SleighNativeSource"
        values = {
            "GHOSTTY_SURFACE_WORK_ROOT": surface,
            "GHOSTTY_SURFACE_SOURCE_DIR": surface / "GhosttySurface",
            "GHOSTTY_SURFACE_ARTIFACT_ROOT": artifact,
            "GHOSTTY_SURFACE_FRAMEWORK": artifact / "macos-arm64/libghostty-internal.a",
            "SLEIGH_COMPONENT_ROOT": source / "ThirdParty/SleighNative",
            "SLEIGH_SOURCE_BUILD_ROOT": sleigh,
            "SLEIGH_ROOT": sleigh / "materialization",
            "MACHOKIT_ROOT": machokit,
            "PARSER_ENGINE_CACHE_ROOT": self.cache,
            "PATTERN_ADAPTER_ROOT": pattern_adapter_root or "",
        }
        return subprocess.run(
            ["/bin/bash", "-eu", "-c", "cat <<XCCONFIG\n" + template + "\nXCCONFIG\n"],
            env={**os.environ, **{key: str(value) for key, value in values.items()}},
            check=True, capture_output=True,
        ).stdout

    def test_bootstrap_template_matches_fresh_and_persistent_roots(self) -> None:
        for name in ("random-fresh", "tier2rel"):
            with self.subTest(run=name), tempfile.TemporaryDirectory() as temporary:
                source, machokit, macscope = self._fixture(Path(temporary).resolve(), name)
                identity = MODULE.generated_project_identity(source, machokit)
                result = subprocess.run(
                    ["/usr/bin/python3", "-B", str(TOOL),
                     "--build-source-root", str(source), "--machokit-root", str(machokit),
                     "--dependency-cache-root", str(self.cache),
                     "--expected-project-identity", identity],
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((macscope / "DependencyRoots.local.xcconfig").exists())
                self.assertTrue((macscope / "project.yml").is_file())

    def test_qualifier_binds_admitted_cache_despite_ambient_override(self) -> None:
        script = (ROOT / "Scripts/qualify_local_private_build.sh").read_text()
        exports = script.split('export MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR=', 1)[1]
        exports = 'export MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR=' + exports.split(
            "# Bootstrap's governance checks", 1)[0]
        restore_args = "BUILD_SOURCE_RESTORE_ARGUMENTS=(" + script.split(
            "BUILD_SOURCE_RESTORE_ARGUMENTS=(", 1)[1].split("\n)", 1)[0] + "\n)\n"
        bootstrap = (ROOT / "Scripts/bootstrap.sh").read_text()
        parser_assignment = next(line for line in bootstrap.splitlines()
                                 if line.startswith("PARSER_ENGINE_CACHE_ROOT="))
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, _ = self._fixture(Path(temporary).resolve(), "tier2rel")
            result = subprocess.run(
                ["/bin/bash", "-e", "-c", exports + restore_args + parser_assignment
                 + '\nprintf "%s\n" "$PARSER_ENGINE_CACHE_ROOT" "${BUILD_SOURCE_RESTORE_ARGUMENTS[@]}"'],
                env={**os.environ, "DEPENDENCY_CACHE_ROOT": str(self.cache),
                     "MACSCOPE_DEPENDENCY_CACHE_ROOT": "/wrong/ambient-cache",
                     "BUILD_SOURCE_ROOT": str(source), "PRIVATE_MACHOKIT_ROOT": str(machokit)},
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [str(self.cache),
                "--build-source-root", str(source), "--machokit-root", str(machokit),
                "--dependency-cache-root", str(self.cache)])
        self.assertIn('--binding "parser-engine-cache-root=${DEPENDENCY_CACHE_ROOT}"', script)
        self.assertLess(script.index(exports), script.index('BOOTSTRAP_KEY_ARGUMENTS=('))

    def test_qualifier_forwards_only_its_explicit_retained_adapter(self) -> None:
        script = (ROOT / "Scripts/qualify_local_private_build.sh").read_text()
        start = script.index("BUILD_SOURCE_RESTORE_ARGUMENTS=(")
        fragment = script[start:script.index("\nfor QUALIFICATION_HELPER", start)]
        for adapter in ("", "/verified/retained adapter"):
            with self.subTest(pattern_adapter_root=adapter):
                result = subprocess.run(
                    ["/bin/bash", "-euc", fragment + '\nprintf "%s\\n" "${BUILD_SOURCE_RESTORE_ARGUMENTS[@]}"'],
                    env={**os.environ, "BUILD_SOURCE_ROOT": "/verified/source",
                         "PRIVATE_MACHOKIT_ROOT": "/verified/private-machokit-input",
                         "DEPENDENCY_CACHE_ROOT": "/verified/cache",
                         "PATTERN_ADAPTER_ROOT": adapter,
                         "MACSCOPE_PATTERN_ADAPTER_ROOT": "/wrong/ambient-adapter"},
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = ["--build-source-root", "/verified/source",
                            "--machokit-root", "/verified/private-machokit-input",
                            "--dependency-cache-root", "/verified/cache"]
                if adapter:
                    expected += ["--pattern-adapter-root", adapter]
                self.assertEqual(result.stdout.splitlines(), expected)

    def test_retained_adapter_requires_explicit_matching_canonical_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, macscope = self._fixture(Path(temporary).resolve())
            adapter = source.parent / "retained adapter"
            adapter.mkdir()
            retained = adapter / "MacScopePatternAdapter.a"
            retained.write_bytes(b"retained producer-owned input")
            xcconfig = macscope / "DependencyRoots.local.xcconfig"
            xcconfig.write_bytes(self._bootstrap_xcconfig(source, machokit, adapter))
            with self.assertRaisesRegex(MODULE.BuildSourceRestoreError, "differs from canonical run roots"):
                MODULE.restore_build_source(source, machokit, self.cache)
            alias = source.parent / "adapter-alias"
            alias.symlink_to(adapter, target_is_directory=True)
            with self.assertRaisesRegex(MODULE.BuildSourceRestoreError, "pattern adapter root must be an ordinary directory"):
                MODULE.restore_build_source(source, machokit, self.cache, pattern_adapter_root=alias)
            self.assertTrue(xcconfig.is_file())
            self.assertTrue((macscope / "MacScope.xcodeproj").is_dir())
            result = subprocess.run(
                ["/usr/bin/python3", "-B", str(TOOL),
                 "--build-source-root", str(source), "--machokit-root", str(machokit),
                 "--dependency-cache-root", str(self.cache), "--pattern-adapter-root", str(adapter)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(xcconfig.exists())
            self.assertEqual(retained.read_bytes(), b"retained producer-owned input")

    def test_rejects_parser_cache_drift_without_mutating_scaffold(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, macscope = self._fixture(Path(temporary).resolve())
            xcconfig = macscope / "DependencyRoots.local.xcconfig"
            xcconfig.write_bytes(xcconfig.read_bytes().replace(
                str(self.cache).encode(), b"/wrong/parser-cache"))
            with self.assertRaisesRegex(MODULE.BuildSourceRestoreError, "differs from canonical run roots"):
                MODULE.restore_build_source(source, machokit, self.cache)
            self.assertTrue(xcconfig.is_file())
            self.assertTrue((macscope / "LocalPackages").is_symlink())
            self.assertTrue((macscope / "MacScope.xcodeproj").is_dir())

    def test_rejects_missing_or_extra_dependency_settings(self) -> None:
        for setting in ("MACSCOPE_PARSER_ENGINE_CACHE_ROOT", "MACSCOPE_PATTERN_ADAPTER_ROOT"):
            for mutation in ("missing", "extra"):
                with self.subTest(setting=setting, mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                    source, machokit, macscope = self._fixture(Path(temporary).resolve())
                    xcconfig = macscope / "DependencyRoots.local.xcconfig"
                    lines = xcconfig.read_text().splitlines(keepends=True)
                    if mutation == "missing":
                        lines = [line for line in lines if not line.startswith(setting + " = ")]
                    else:
                        lines.append(setting + " = /override\n")
                    xcconfig.write_text("".join(lines))
                    with self.assertRaisesRegex(MODULE.BuildSourceRestoreError, "differs from canonical run roots"):
                        MODULE.restore_build_source(source, machokit, self.cache)
                    self.assertTrue(xcconfig.is_file())
                    self.assertTrue((macscope / "LocalPackages").is_symlink())

    def test_rejects_previous_run_paths_in_persistent_config(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, macscope = self._fixture(Path(temporary).resolve(), "tier2rel")
            xcconfig = macscope / "DependencyRoots.local.xcconfig"
            xcconfig.write_bytes(xcconfig.read_bytes().replace(b"run.tier2rel", b"run.previous"))
            with self.assertRaisesRegex(MODULE.BuildSourceRestoreError, "differs from canonical run roots"):
                MODULE.restore_build_source(source, machokit, self.cache)
            self.assertTrue(xcconfig.is_file())
            self.assertTrue((macscope / "LocalPackages").is_symlink())

    def test_rejects_noncanonical_cache_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, macscope = self._fixture(Path(temporary).resolve())
            alias = self.cache.parent / "cache-alias"
            alias.symlink_to(self.cache, target_is_directory=True)
            with self.assertRaisesRegex(MODULE.BuildSourceRestoreError, "dependency cache root must be an ordinary directory"):
                MODULE.restore_build_source(source, machokit, alias)
            self.assertTrue((macscope / "DependencyRoots.local.xcconfig").is_file())

    def test_removes_only_validated_generated_scaffold(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, macscope = self._fixture(Path(temporary).resolve())
            retained = macscope / "Retained.swift"
            retained.write_text("// retained\n", encoding="utf-8")

            MODULE.restore_build_source(source, machokit, self.cache)

            self.assertTrue(retained.is_file())
            self.assertFalse((macscope / "LocalPackages").exists())
            self.assertFalse((macscope / "LocalPackages").is_symlink())
            self.assertFalse((macscope / "DependencyRoots.local.xcconfig").exists())
            self.assertFalse((macscope / "MacScope.xcodeproj").exists())

    def test_rejects_wrong_local_packages_target_without_removing_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, macscope = self._fixture(Path(temporary).resolve())
            wrong = Path(temporary) / "wrong-machokit"
            wrong.mkdir()
            local_packages = macscope / "LocalPackages"
            local_packages.unlink()
            local_packages.symlink_to(wrong, target_is_directory=True)

            with self.assertRaisesRegex(
                MODULE.BuildSourceRestoreError,
                "does not target the run-owned MachOKit root",
            ):
                MODULE.restore_build_source(source, machokit, self.cache)

            self.assertTrue(local_packages.is_symlink())
            self.assertEqual(local_packages.resolve(strict=True), wrong.resolve(strict=True))

    def test_rejects_symlink_inside_generated_project(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, macscope = self._fixture(Path(temporary).resolve())
            project = macscope / "MacScope.xcodeproj"
            (project / "unsafe").symlink_to(macscope / "project.yml")

            with self.assertRaisesRegex(
                MODULE.BuildSourceRestoreError,
                "generated Xcode project contains a symlink",
            ):
                MODULE.restore_build_source(source, machokit, self.cache)

            self.assertTrue(project.is_dir())
            self.assertTrue((macscope / "LocalPackages").is_symlink())
            self.assertTrue((macscope / "DependencyRoots.local.xcconfig").is_file())

    def test_unexpected_source_path_remains_for_closed_tree_verifier(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, macscope = self._fixture(Path(temporary).resolve())
            unexpected = source / "unexpected.txt"
            unexpected.write_text("not generated\n", encoding="utf-8")

            MODULE.restore_build_source(source, machokit, self.cache)

            self.assertTrue(unexpected.is_file())

    def test_rejects_noncanonical_xcconfig_without_mutating_scaffold(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, macscope = self._fixture(Path(temporary).resolve())
            xcconfig = macscope / "DependencyRoots.local.xcconfig"
            xcconfig.write_bytes(xcconfig.read_bytes().replace(b"ghostty-surface", b"other-surface", 1))

            with self.assertRaisesRegex(
                MODULE.BuildSourceRestoreError,
                "differs from canonical run roots",
            ):
                MODULE.restore_build_source(source, machokit, self.cache)

            self.assertTrue((macscope / "LocalPackages").is_symlink())
            self.assertTrue(xcconfig.is_file())
            self.assertTrue((macscope / "MacScope.xcodeproj").is_dir())

    def test_rejects_unexpected_generated_project_file_without_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, macscope = self._fixture(Path(temporary).resolve())
            project = macscope / "MacScope.xcodeproj"
            (project / "Unexpected.txt").write_text("unexpected\n", encoding="utf-8")

            with self.assertRaisesRegex(
                MODULE.BuildSourceRestoreError,
                "contains an unexpected file",
            ):
                MODULE.restore_build_source(source, machokit, self.cache)

            self.assertTrue((macscope / "LocalPackages").is_symlink())
            self.assertTrue((macscope / "DependencyRoots.local.xcconfig").is_file())
            self.assertTrue(project.is_dir())

    def test_rejects_project_json_drift_against_pre_xcode_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, macscope = self._fixture(Path(temporary).resolve())
            project = macscope / "MacScope.xcodeproj"
            identity = MODULE.generated_project_identity(source, machokit)
            (project / "project.xcproj").write_text(
                "// semantically altered project\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.BuildSourceRestoreError,
                "differs from its bound pre-Xcode identity",
            ):
                MODULE.restore_build_source(
                    source,
                    machokit,
                    self.cache,
                    expected_project_identity=identity,
                )

            self.assertTrue(project.is_dir())
            self.assertTrue((macscope / "LocalPackages").is_symlink())
            self.assertTrue((macscope / "DependencyRoots.local.xcconfig").is_file())

    def test_rejects_scheme_drift_against_pre_xcode_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, macscope = self._fixture(Path(temporary).resolve())
            project = macscope / "MacScope.xcodeproj"
            identity = MODULE.generated_project_identity(source, machokit)
            scheme = project / "xcshareddata/xcschemes/MacScopeApp.xcscheme"
            scheme.write_text(
                "<!-- semantically altered launch action -->\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.BuildSourceRestoreError,
                "differs from its bound pre-Xcode identity",
            ):
                MODULE.restore_build_source(
                    source,
                    machokit,
                    self.cache,
                    expected_project_identity=identity,
                )

            self.assertTrue(project.is_dir())
            self.assertTrue(scheme.is_file())
            self.assertTrue((macscope / "LocalPackages").is_symlink())
            self.assertTrue((macscope / "DependencyRoots.local.xcconfig").is_file())

    def test_rejects_malformed_expected_project_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, macscope = self._fixture(Path(temporary).resolve())

            with self.assertRaisesRegex(
                MODULE.BuildSourceRestoreError,
                "expected generated-project identity is malformed",
            ):
                MODULE.restore_build_source(
                    source,
                    machokit,
                    self.cache,
                    expected_project_identity="not-a-sha256",
                )

            self.assertTrue((macscope / "MacScope.xcodeproj").is_dir())
            self.assertTrue((macscope / "LocalPackages").is_symlink())
            self.assertTrue((macscope / "DependencyRoots.local.xcconfig").is_file())

    def test_absent_scaffold_is_an_idempotent_noop(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, machokit, macscope = self._fixture(Path(temporary).resolve())
            MODULE.restore_build_source(source, machokit, self.cache)

            MODULE.restore_build_source(source, machokit, self.cache)

            self.assertTrue((macscope / "project.yml").is_file())


if __name__ == "__main__":
    unittest.main()
