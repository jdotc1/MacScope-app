#!/usr/bin/env python3

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DependencyRootConfigurationTests(unittest.TestCase):
    def test_defaults_name_actual_repository_owned_inputs(self) -> None:
        config = (ROOT / "MacScope/DependencyRoots.xcconfig").read_text(encoding="utf-8")
        self.assertNotIn("MACSCOPE_GHOSTTY_SOURCE_DIR", config)
        self.assertIn(
            "MACSCOPE_SLEIGH_COMPONENT_ROOT = $(SRCROOT)/../ThirdParty/SleighNative",
            config,
        )
        self.assertIn("MACSCOPE_SLEIGH_MATERIALIZATION_ROOT =\n", config)
        self.assertIn(
            "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT = $(SRCROOT)/../ThirdParty/MachOKit/materialization",
            config,
        )
        self.assertIn("MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR =\n", config)
        self.assertIn("MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT =\n", config)
        self.assertIn("fail-closed", config)

    def test_bootstrap_keeps_overrides_and_uses_repository_xcodegen(self) -> None:
        script = (ROOT / "Scripts/bootstrap.sh").read_text(encoding="utf-8")
        self.assertIn('GHOSTTY_SOURCE_DIR="${REPO_ROOT}/ThirdParty/GhosttyVT/Source"', script)
        self.assertIn(
            'SLEIGH_COMPONENT_ROOT="${MACSCOPE_SLEIGH_COMPONENT_ROOT:-${REPO_ROOT}/ThirdParty/SleighNative}"',
            script,
        )
        self.assertIn('SLEIGH_ROOT="${MACSCOPE_SLEIGH_MATERIALIZATION_ROOT:-}"', script)
        self.assertIn("prepare_repository_sleigh_materialization.py", script)
        self.assertIn(
            'MACSCOPE_SLEIGH_COMPONENT_ROOT = ${SLEIGH_COMPONENT_ROOT}',
            script,
        )
        self.assertIn('MACHOKIT_ROOT="${MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT:-}"', script)
        self.assertIn('MACHOKIT_SOURCE_ROOT="${REPO_ROOT}/ThirdParty/MachOKit/materialization"', script)
        self.assertIn("publish-read-only", script)
        self.assertIn('XCODEGEN="${MACSCOPE_XCODEGEN:-${REPO_ROOT}/ThirdParty/XcodeGen/bin/xcodegen}"', script)
        self.assertIn("verify-tool --binary", script)
        self.assertNotIn("command -v xcodegen", script)
        self.assertIn(
            '"${SCRIPT_DIR}/generate_xcode_json_project.py" --source "${MACSCOPE_DIR}" --xcodegen "${XCODEGEN}"',
            script,
        )
        self.assertNotIn('MACSCOPE_GHOSTTY_SOURCE_DIR', script)
        self.assertNotIn("MACSCOPE_GHOSTTY_VT_WORK_ROOT", script)

    def test_prepare_refreshes_explicit_dependency_roots_and_refuses_unpublished_root(self) -> None:
        # Execute the real --prepare caller with only freshness and publication
        # stubs: no bootstrap body, dependency read, hashing or Xcode invocation.
        mappings = {
            "MACSCOPE_PATTERN_ADAPTER_ROOT": "MACSCOPE_PATTERN_ADAPTER_ROOT",
            "MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT": "MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT",
            "MACSCOPE_SLEIGH_COMPONENT_ROOT": "MACSCOPE_SLEIGH_COMPONENT_ROOT",
            "MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT": "MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT",
            "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT": "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT",
            "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT": "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT",
            "MACSCOPE_DEPENDENCY_CACHE_ROOT": "MACSCOPE_PARSER_ENGINE_CACHE_ROOT",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "fixture with spaces"
            (root / "script").mkdir(parents=True)
            (root / "Scripts").mkdir()
            (root / "MacScope/MacScope.xcodeproj").mkdir(parents=True)
            entrypoint = root / "script/build_and_run.sh"
            shutil.copyfile(ROOT / "script/build_and_run.sh", entrypoint)
            (root / "Scripts/check_local_signing_policy.py").write_text(
                "def validate_generated_project_freshness(project): return []\n")
            bootstrap = root / "Scripts/bootstrap.sh"
            bootstrap.write_text(
                '#!/bin/bash\nset -eu\n'
                'printf "called\\n" >> "${FIXTURE_BOOTSTRAP_LOG}"\n'
                'if [[ "${FIXTURE_PUBLISH}" == 1 ]]; then\n'
                '  printf "%s" "${FIXTURE_XCCONFIG}" > "${FIXTURE_CONFIG}"\n'
                'fi\n')
            bootstrap.chmod(0o755)
            configuration = root / "MacScope/DependencyRoots.local.xcconfig"
            calls = root / "bootstrap-calls"
            base = {key: value for key, value in os.environ.items()
                    if not key.startswith("MACSCOPE_")}
            base.update(FIXTURE_BOOTSTRAP_LOG=str(calls), FIXTURE_CONFIG=str(configuration))

            def prepare(overrides, published="", publish=True):
                calls.unlink(missing_ok=True)
                environment = dict(base, FIXTURE_PUBLISH="1" if publish else "0",
                                   FIXTURE_XCCONFIG=published, **overrides)
                result = subprocess.run(["/bin/bash", str(entrypoint), "--prepare"],
                                        env=environment, text=True, capture_output=True, timeout=10)
                count = len(calls.read_text().splitlines()) if calls.exists() else 0
                return result, count

            requested = "/verified/root with spaces"
            for environment_name, setting in mappings.items():
                with self.subTest(environment=environment_name):
                    configuration.write_text(f"{setting} = \n")
                    result, count = prepare({environment_name: requested},
                                            f"{setting} = {requested}\n")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(count, 1)
                    self.assertIn(setting, result.stderr)
                    self.assertIn("empty or missing", result.stderr)
                    # Exact published input is reusable, not a repeated bootstrap.
                    result, count = prepare({environment_name: requested})
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(count, 0)

            configuration.write_text("MACSCOPE_PATTERN_ADAPTER_ROOT = /old/adapter\n")
            result, count = prepare({"MACSCOPE_PATTERN_ADAPTER_ROOT": requested},
                                    f"MACSCOPE_PATTERN_ADAPTER_ROOT = {requested}\n")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(count, 1)
            self.assertIn("/old/adapter", result.stderr)

            # Unset/empty retain bootstrap's default/discovery semantics.
            for overrides in ({}, {"MACSCOPE_PATTERN_ADAPTER_ROOT": ""}):
                result, count = prepare(overrides)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(count, 0)

            configuration.write_text("MACSCOPE_PATTERN_ADAPTER_ROOT = \n")
            result, count = prepare({"MACSCOPE_PATTERN_ADAPTER_ROOT": requested}, publish=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(count, 1, "never retry bootstrap after a failed publication")
            self.assertIn("MACSCOPE_PATTERN_ADAPTER_ROOT", result.stderr)
            self.assertIn("refusing to build", result.stderr)

    def test_ci_supplies_the_retained_pattern_adapter_and_the_phase_fails_closed(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        cache = "$MACSCOPE_WORK_ROOT/MacScopeQualificationCache-20260920"
        self.assertEqual(workflow.count('echo "MACSCOPE_PATTERN_ADAPTER_ROOT=' + cache + "/pattern-adapter/"), 1)
        self.assertEqual(workflow.count('echo "MACSCOPE_PATTERN_ADAPTER_RECEIPT=' + cache + "/pattern-adapter/"), 1)
        self.assertEqual(workflow.count('--pattern-adapter-root "$MACSCOPE_PATTERN_ADAPTER_ROOT" \\\n'), 1)
        self.assertEqual(workflow.count('--pattern-adapter-receipt "$MACSCOPE_PATTERN_ADAPTER_RECEIPT" \\\n'), 1)
        script = (ROOT / "Scripts/qualify_local_private_build.sh").read_text(encoding="utf-8")
        self.assertIn('export MACSCOPE_PATTERN_ADAPTER_ROOT="${PATTERN_ADAPTER_ROOT}"', script)
        # The export must precede bootstrap so DependencyRoots.local.xcconfig carries it.
        self.assertLess(script.index('export MACSCOPE_PATTERN_ADAPTER_ROOT='),
                        script.index("./Scripts/bootstrap.sh"))
        project = (ROOT / "MacScope/project.yml").read_text(encoding="utf-8")
        phase = project[project.index("name: Require retained pattern adapter"):
                        project.index("name: Stage cached parser engines")]
        # Fail closed, never skipped, and the diagnostic names the root and its location.
        self.assertIn('if [ -z "${MACSCOPE_PATTERN_ADAPTER_ROOT:-}" ]; then', phase)
        self.assertIn("expected at $expected", phase)
        self.assertIn("<dependency cache root>/pattern-adapter/<content key>", phase)
        self.assertIn("is missing or unreachable", phase)
        self.assertEqual(phase.count("exit 1"), 3)
        self.assertNotIn("exit 0", phase)

    def test_qualifier_refuses_unreachable_or_unowned_pattern_adapter_roots(self) -> None:
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("MACSCOPE_")}
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            receipt = base / "receipt.md"
            receipt.write_text("accepted producer receipt")
            partial = base / "partial"
            partial.mkdir()

            def qualify(*arguments):
                return subprocess.run(
                    ["/bin/bash", str(ROOT / "Scripts/qualify_local_private_build.sh"),
                     "--work-root", str(base / "work"), *arguments],
                    env=environment, text=True, capture_output=True, timeout=30)

            for arguments, message in (
                (("--pattern-adapter-root", "relative/root", "--pattern-adapter-receipt", str(receipt)),
                 "must be absolute"),
                (("--pattern-adapter-root", str(base / "absent"), "--pattern-adapter-receipt", str(receipt)),
                 "missing or unreachable"),
                (("--pattern-adapter-root", str(partial), "--pattern-adapter-receipt", str(receipt)),
                 "missing MacScopePatternAdapter.a"),
                (("--pattern-adapter-root", str(partial)), "requires --pattern-adapter-receipt"),
            ):
                with self.subTest(arguments=arguments):
                    result = qualify(*arguments)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn(message, result.stderr)
            self.assertFalse((base / "work").exists())

    def test_qualification_defaults_match_repository_inputs_and_external_run_roots(self) -> None:
        script = (ROOT / "Scripts/qualify_local_private_build.sh").read_text(encoding="utf-8")
        self.assertIn('MACHOKIT_INPUT_ROOT="${BUILD_SOURCE_ROOT}/ThirdParty/MachOKit/materialization"', script)
        self.assertIn('GHOSTTY_SOURCE_DIR="${GHOSTTY_QUALIFICATION_ROOT}"', script)
        self.assertIn('ZIG="${BUILD_SOURCE_ROOT}/ThirdParty/Zig/zig-0.16.0/zig"', script)
        self.assertIn("build_vendored_ghostty_surface.sh", script)
        self.assertIn("build_vendored_sleigh_native_source.sh", script)
        self.assertIn('RUN_ROOT="$(/usr/bin/mktemp -d "${RUNS_ROOT}/run.XXXXXX")"', script)
        self.assertIn('DEPENDENCY_WORK_ROOT="${RUN_ROOT}/dependencies"', script)
        self.assertIn('PRIVATE_MACHOKIT_ROOT="${RUN_ROOT}/private-machokit-input"', script)


if __name__ == "__main__":
    unittest.main()
