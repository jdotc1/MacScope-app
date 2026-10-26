"""Debug-only reuse stamps for always-run Xcode verification phases."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "Scripts" / "build_phase_stamp.py"
PROJECT = ROOT / "MacScope" / "project.yml"


def load_helper():
    specification = importlib.util.spec_from_file_location("build_phase_stamp_under_test", HELPER)
    module = importlib.util.module_from_spec(specification)
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        specification.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


class BuildPhaseStampTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_helper()
        self.temporary = tempfile.TemporaryDirectory(prefix="macscope-phase-stamp-")
        self.root = Path(self.temporary.name)
        self.input_file = self.root / "input.txt"
        self.input_file.write_text("one\n", encoding="utf-8")
        self.input_tree = self.root / "tree"
        (self.input_tree / "nested").mkdir(parents=True)
        (self.input_tree / "nested" / "leaf").write_text("leaf\n", encoding="utf-8")
        self.output_tree = self.root / "out"
        self.output_tree.mkdir()
        (self.output_tree / "product").write_text("product\n", encoding="utf-8")
        self.environment = {
            "CONFIGURATION": "Debug",
            "MACSCOPE_DEBUG_SOURCE_IDENTITY": "runtime-only",
            "DERIVED_FILE_DIR": str(self.root / "derived"),
            "TARGET_NAME": "Example",
        }

        def spec(_environment):
            return self.module.PhaseSpec(
                files=(self.input_file,),
                trees=(self.input_tree,),
                output_trees=(self.output_tree,),
            )

        patcher = mock.patch.dict(self.module.PHASES, {"example": spec})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.temporary.cleanup)

    def verified_run(self, environment=None) -> bool:
        environment = environment or self.environment
        if self.module.check("example", environment):
            return True
        self.module.record("example", environment)
        return False

    def touch(self, path: Path, text: str) -> None:
        # Guarantee a distinct timestamp even on coarse clocks.
        time.sleep(0.01)
        path.write_text(text, encoding="utf-8")

    def test_first_run_misses_then_unchanged_inputs_hit(self) -> None:
        self.assertFalse(self.verified_run())
        self.assertTrue(self.module.check("example", self.environment))

    def test_release_and_qualification_builds_never_use_stamps(self) -> None:
        for override in (
            {"CONFIGURATION": "Release"},
            {"MACSCOPE_DEBUG_SOURCE_IDENTITY": "source-qualified"},
            {"MACSCOPE_DISABLE_PHASE_STAMPS": "YES"},
            {"DERIVED_FILE_DIR": ""},
        ):
            with self.subTest(override=override):
                environment = {**self.environment, **override}
                self.assertFalse(self.verified_run(environment))
                self.assertFalse(self.module.check("example", environment))
        # Ineligible runs never wrote a stamp an eligible run could reuse.
        self.assertFalse(self.module.check("example", self.environment))

    def test_input_file_tree_environment_and_output_changes_invalidate(self) -> None:
        mutations = {
            "file": lambda: self.touch(self.input_file, "two\n"),
            "tree-leaf": lambda: self.touch(self.input_tree / "nested" / "leaf", "changed\n"),
            "tree-added": lambda: self.touch(self.input_tree / "added", "new\n"),
            "tree-removed": lambda: (self.input_tree / "added").unlink(),
            "mode": lambda: os.chmod(self.input_file, 0o600),
            "output-changed": lambda: self.touch(self.output_tree / "product", "tampered\n"),
            "output-removed": lambda: (self.output_tree / "product").unlink(),
        }
        for name, mutate in mutations.items():
            with self.subTest(mutation=name):
                if name == "output-removed":
                    self.touch(self.output_tree / "product", "product\n")
                self.verified_run()
                self.assertTrue(self.module.check("example", self.environment))
                self.module.record("example", self.environment)
                mutate()
                self.assertFalse(self.module.check("example", self.environment))
                if name == "output-removed":
                    self.touch(self.output_tree / "product", "product\n")
                self.module.record("example", self.environment)
        changed_environment = {**self.environment, "EXPANDED_CODE_SIGN_IDENTITY": "OTHER"}
        self.verified_run()
        self.assertFalse(self.module.check("example", changed_environment))

    def test_git_authority_resolves_every_governed_path(self) -> None:
        # The REA phase keys on two governed paths; rev-parse --verify takes one at a time.
        paths = ("ThirdParty/REA", "Scripts/dependencies/rea_build.mjs")
        if not (self.module.REPOSITORY_ROOT / ".git").exists():
            self.skipTest("needs the Git checkout")
        object_ids = self.module._git_records(paths)
        self.assertEqual(len(object_ids), 2)
        self.assertTrue(all(len(value) == 40 for value in object_ids), object_ids)

    def test_per_build_scheduler_ids_do_not_invalidate(self) -> None:
        first = {**self.environment, "LLBUILD_BUILD_ID": "2427779152",
                 "LLBUILD_LANE_ID": "0", "LLBUILD_TASK_ID": "f8500000000d"}
        self.assertFalse(self.verified_run(first))  # first run records
        second = {**self.environment, "LLBUILD_BUILD_ID": "3649745597",
                  "LLBUILD_LANE_ID": "2", "LLBUILD_TASK_ID": "b2bd00020009"}
        self.assertTrue(self.module.check("example", second))
        # Any other environment change still invalidates.
        self.assertFalse(self.module.check("example", {**second, "SDK_VERSION": "99.0"}))

    def test_inputs_changed_while_the_body_ran_are_never_certified(self) -> None:
        self.assertFalse(self.module.check("example", self.environment))
        self.touch(self.input_file, "edited during the phase\n")
        self.assertFalse(self.module.record("example", self.environment))
        self.assertFalse(self.module.check("example", self.environment))

    def test_failed_body_leaves_no_reusable_stamp(self) -> None:
        self.verified_run()
        self.touch(self.input_file, "invalid\n")
        # The body fails, so record is never called.
        self.assertFalse(self.module.check("example", self.environment))
        self.touch(self.input_file, "one\n")
        self.assertFalse(self.module.check("example", self.environment))

    def test_malformed_stamp_is_a_miss(self) -> None:
        self.verified_run()
        stamp = Path(self.environment["DERIVED_FILE_DIR"]) / "MacScopePhaseStamps" / "example.json"
        stamp.write_text("{not json", encoding="utf-8")
        self.assertFalse(self.module.check("example", self.environment))
        self.module.record("example", self.environment)
        self.assertTrue(self.module.check("example", self.environment))

    def test_cli_errors_are_misses_and_never_fail_a_verified_body(self) -> None:
        environment = {
            **os.environ,
            "CONFIGURATION": "Debug",
            "MACSCOPE_DEBUG_SOURCE_IDENTITY": "runtime-only",
            "DERIVED_FILE_DIR": str(self.root / "derived-cli"),
        }
        environment.pop("MACSCOPE_GHOSTTY_VT_BUILD_ROOT", None)
        for command, expected in (("check", 1), ("record", 0)):
            with self.subTest(command=command):
                result = subprocess.run(
                    [sys.executable, "-B", str(HELPER), command, "ghostty-vt"],
                    env=environment,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, expected, result.stderr)
        usage = subprocess.run(
            [sys.executable, "-B", str(HELPER), "check", "unknown"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(usage.returncode, 2)

    def test_every_production_phase_spec_resolves(self) -> None:
        environment = {
            **self.environment,
            "MACSCOPE_GHOSTTY_VT_BUILD_ROOT": str(self.root / "vt"),
            "TARGET_BUILD_DIR": str(self.root / "products"),
            "FRAMEWORKS_FOLDER_PATH": "MacScope.app/Contents/Frameworks",
            "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT": str(self.root / "machokit"),
            "SRCROOT": str(ROOT / "MacScope"),
            "EXECUTABLE_PATH": "Worker.xpc/Contents/MacOS/Worker",
            "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT": str(self.root / "sleigh"),
            "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Worker.xpc/Contents/Resources",
            "TARGET_TEMP_DIR": str(self.root / "target-temp"),
        }
        for phase in (
            "signing-environment",
            "ghostty-vt",
            "rea-resource",
            "machokit-source",
            "machokit-compiled",
            "native-package-stage",
        ):
            with self.subTest(phase=phase):
                spec = self.module.PHASES[phase](environment)
                for path in spec.files + spec.trees:
                    self.assertTrue(path.is_absolute(), path)


class GitTreeKeyTests(unittest.TestCase):
    """Large tracked trees key on HEAD's tree id only while the working copy equals HEAD."""

    def setUp(self) -> None:
        self.module = load_helper()
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        environment = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        def git(*arguments: str) -> None:
            subprocess.run(["git", "-C", str(self.root), *arguments], check=True, capture_output=True, env=environment)
        git("init", "-q")
        (self.root / "tree").mkdir()
        (self.root / "tree" / "a.txt").write_text("a", encoding="utf-8")
        git("add", "tree")
        git("commit", "-q", "-m", "base")
        patcher = mock.patch.object(self.module, "REPOSITORY_ROOT", self.root)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_clean_tree_is_keyed_by_its_tree_id(self) -> None:
        record = self.module._git_tree_record(self.root / "tree")
        self.assertEqual(record[:2], ["git-clean", "tree"])
        self.assertEqual(len(record[2]), 40)

    def test_modified_or_untracked_content_falls_back_to_the_walk(self) -> None:
        (self.root / "tree" / "a.txt").write_text("changed", encoding="utf-8")
        self.assertEqual(self.module._git_tree_record(self.root / "tree")[0], "walk")
        subprocess.run(["git", "-C", str(self.root), "checkout", "--", "tree"], check=True)
        (self.root / "tree" / "new.txt").write_text("x", encoding="utf-8")
        self.assertEqual(self.module._git_tree_record(self.root / "tree")[0], "walk")


class ProjectPhaseStampWiringTests(unittest.TestCase):
    """Every stamped phase stays always-run and gates reuse on routine Debug."""

    PHASES = {
        "Build repository-owned Ghostty VT": "ghostty-vt",
        "Verify canonical embedded REA resource": "rea-resource",
        "Verify exact MachOKit source materialization": "machokit-source",
        "Verify compiled MachOKit identity in AnalysisWorker": "machokit-compiled",
        "Stage verified native decompiler package": "native-package-stage",
    }
    GUARD = (
        'if [ "${CONFIGURATION:-}" = Debug ] && '
        '[ "${MACSCOPE_DEBUG_SOURCE_IDENTITY:-}" = runtime-only ]; then'
    )

    def phase_text(self, name: str) -> str:
        lines = PROJECT.read_text(encoding="utf-8").splitlines()
        marker = f"      - name: {name}"
        self.assertEqual(lines.count(marker), 1, name)
        start = lines.index(marker) + 1
        end = start
        while end < len(lines):
            line = lines[end]
            indentation = len(line) - len(line.lstrip(" "))
            if line.strip() and (line.startswith("      - ") or indentation <= 4):
                break
            end += 1
        return "\n".join(lines[start:end]) + "\n"

    def test_stamped_phases_remain_always_run_and_record_after_the_full_check(self) -> None:
        for name, phase in self.PHASES.items():
            with self.subTest(phase=name):
                text = self.phase_text(name)
                self.assertIn("basedOnDependencyAnalysis: false", text)
                self.assertEqual(text.count(self.GUARD), 1)
                check = f'/usr/bin/python3 -B "$PHASE_STAMP" check {phase}; then'
                record = f'/usr/bin/python3 -B "$PHASE_STAMP" record {phase}'
                self.assertEqual(text.count(check), 1)
                self.assertEqual(text.count(record), 1)
                self.assertLess(text.index(check), text.index(record))
                body = text[text.index(check):text.index(record)]
                self.assertIn("    exit 0", body)
                # The stamped phase must fail closed: errexit precedes the check.
                self.assertRegex(text.split(self.GUARD, 1)[0], r"set -eu")

    def test_signing_guard_reuses_only_the_exact_routine_debug_invocation(self) -> None:
        source = (ROOT / "Scripts" / "check_local_signing_policy.py").read_text(encoding="utf-8")
        self.assertIn('arguments == ["--build-environment", "--target", environment_target]', source)
        self.assertIn('os.environ.get("CONFIGURATION") == "Debug"', source)
        self.assertIn('os.environ.get("MACSCOPE_DEBUG_SOURCE_IDENTITY") == "runtime-only"', source)
        self.assertLess(
            source.index("_DEBUG_SIGNING_STAMP.check("),
            source.index("from Scripts.xcode_project_json import read_project"),
        )
        self.assertLess(
            source.index("build_errors = validate_build_environment("),
            source.index('_DEBUG_SIGNING_STAMP.record("signing-environment"'),
        )

    def test_debug_link_settings_leave_release_unchanged(self) -> None:
        text = PROJECT.read_text(encoding="utf-8")
        configs = text[text.index("  configs:\n"):text.index("\ntargets:\n")]
        debug = configs[configs.index("    Debug:\n"):configs.index("    Release:\n")]
        release = configs[configs.index("    Release:\n"):]
        self.assertIn("      DEAD_CODE_STRIPPING: NO\n", debug)
        self.assertIn("      DEBUG_INFORMATION_FORMAT: dwarf\n", debug)
        self.assertIn("      DEAD_CODE_STRIPPING: YES\n", release)
        self.assertNotIn("DEBUG_INFORMATION_FORMAT", release)


if __name__ == "__main__":
    unittest.main()
