from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
ENTRYPOINT = ROOT / "script" / "build_and_run.sh"


class FastIterationEntrypointTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)

    def make_fixture(self, *, fresh: bool = True) -> tuple[Path, Path, Path]:
        fixture = Path(self.temporary_directory.name) / "repository"
        fixture.mkdir()
        script_directory = fixture / "script"
        script_directory.mkdir()
        shutil.copy2(ENTRYPOINT, script_directory / "build_and_run.sh")
        macscope = fixture / "MacScope"
        (macscope / "MacScope.xcodeproj").mkdir(parents=True)
        (macscope / "script").mkdir()
        (macscope / "project.yml").write_text("name: MacScope\n", encoding="utf-8")
        (macscope / "DependencyRoots.local.xcconfig").write_text(
            "// fixture\n", encoding="utf-8"
        )
        scripts = fixture / "Scripts"
        scripts.mkdir()
        (scripts / "check_local_signing_policy.py").write_text(
            "def validate_generated_project_freshness(_path):\n"
            f"    return {[] if fresh else ['stale']!r}\n",
            encoding="utf-8",
        )
        (scripts / "xcode27_env.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        bootstrap_marker = fixture / "bootstrap-invocations"
        app_mode_marker = fixture / "app-mode-invocations"
        (macscope / "script/build_and_run.sh").write_text(
            "#!/usr/bin/env bash\n"
            f"printf '%s\\n' \"$*\" >> {str(app_mode_marker)!r}\n",
            encoding="utf-8",
        )
        (macscope / "script/build_and_run.sh").chmod(0o755)
        (scripts / "bootstrap.sh").write_text(
            "#!/usr/bin/env bash\n"
            f"printf 'bootstrap\\n' >> {str(bootstrap_marker)!r}\n",
            encoding="utf-8",
        )
        (scripts / "bootstrap.sh").chmod(0o755)
        fake_bin = fixture / "bin"
        fake_bin.mkdir()
        xcrun_arguments = fixture / "xcrun-arguments"
        (fake_bin / "xcrun").write_text(
            "#!/usr/bin/env bash\n"
            f"printf '%s\\n' \"$@\" > {str(xcrun_arguments)!r}\n",
            encoding="utf-8",
        )
        (fake_bin / "xcrun").chmod(0o755)
        return fixture, bootstrap_marker, xcrun_arguments

    def run_fixture(self, fixture: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["HOME"] = str(fixture.parent / "home")
        environment["PATH"] = f"{fixture / 'bin'}{os.pathsep}{environment['PATH']}"
        (fixture.parent / "home").mkdir()
        return subprocess.run(
            ["/bin/bash", str(fixture / "script/build_and_run.sh"), *arguments],
            cwd=fixture,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_help_exposes_build_test_and_no_build_diagnostic_paths(self) -> None:
        completed = subprocess.run(
            ["/bin/bash", str(ENTRYPOINT), "--help"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("--test [TEST]", completed.stderr)
        self.assertIn("--rerun-test [TEST]", completed.stderr)
        self.assertIn("--prepare", completed.stderr)
        self.assertIn("build, --build", completed.stderr)
        self.assertIn("stop, --stop", completed.stderr)

    def test_fast_test_path_skips_unconditional_bootstrap(self) -> None:
        script = ENTRYPOINT.read_text(encoding="utf-8")
        self.assertIn("generated_project_is_fresh", script)
        self.assertIn("validate_generated_project_freshness", script)
        self.assertIn('run_test test "${2:-CoreTests}"', script)
        self.assertIn("test-without-building", script)
        self.assertNotIn('exec "${ROOT_DIR}/Scripts/test.sh"', script)

    def test_fast_test_reuses_the_authoritative_focused_test_database(self) -> None:
        script = ENTRYPOINT.read_text(encoding="utf-8")
        self.assertIn("MacScopeFocusedTests-${worktree_id}", script)
        self.assertIn("MACSCOPE_TEST_DERIVED_DATA", script)
        self.assertIn("COMPILER_INDEX_STORE_ENABLE=NO", script)
        self.assertIn("-showBuildTimingSummary", script)

    def test_existing_app_modes_remain_forwarded(self) -> None:
        script = ENTRYPOINT.read_text(encoding="utf-8")
        self.assertIn('exec ./script/build_and_run.sh "$@"', script)

    def test_fresh_focused_test_performs_zero_bootstraps(self) -> None:
        fixture, bootstrap_marker, xcrun_arguments = self.make_fixture(fresh=True)
        completed = self.run_fixture(fixture, "--test", "CoreTests/FastSuite/testCase")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(bootstrap_marker.exists())
        arguments = xcrun_arguments.read_text(encoding="utf-8").splitlines()
        self.assertEqual(arguments[:2], ["xcodebuild", "test"])
        self.assertIn("-only-testing:CoreTests/FastSuite/testCase", arguments)

    def test_dangling_local_packages_rematerializes_even_when_project_is_fresh(self) -> None:
        fixture, bootstrap_marker, _ = self.make_fixture(fresh=True)
        wiped = fixture.parent / "wiped-tmpdir" / "MacScope" / "MachOKit" / "MachOKit-view"
        (fixture / "MacScope" / "LocalPackages").symlink_to(wiped, target_is_directory=True)
        completed = self.run_fixture(fixture, "--prepare")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            bootstrap_marker.read_text(encoding="utf-8").splitlines(),
            ["bootstrap"],
        )
        self.assertIn("LocalPackages target is missing", completed.stdout)
        self.assertNotIn("Reusing verified generated project", completed.stdout)

    def test_resolving_local_packages_link_keeps_the_fresh_fast_path(self) -> None:
        fixture, bootstrap_marker, _ = self.make_fixture(fresh=True)
        view = fixture.parent / "view"
        view.mkdir()
        (fixture / "MacScope" / "LocalPackages").symlink_to(view, target_is_directory=True)
        completed = self.run_fixture(fixture, "--prepare")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(bootstrap_marker.exists())

    def test_stale_focused_test_bootstraps_exactly_once(self) -> None:
        fixture, bootstrap_marker, _ = self.make_fixture(fresh=False)
        completed = self.run_fixture(fixture, "--test")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            bootstrap_marker.read_text(encoding="utf-8").splitlines(),
            ["bootstrap"],
        )

    def test_diagnostic_rerun_performs_no_build_action(self) -> None:
        fixture, bootstrap_marker, xcrun_arguments = self.make_fixture(fresh=True)
        completed = self.run_fixture(fixture, "--rerun-test", "CoreTests/FastSuite")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(bootstrap_marker.exists())
        arguments = xcrun_arguments.read_text(encoding="utf-8").splitlines()
        self.assertEqual(arguments[:2], ["xcodebuild", "test-without-building"])

    def test_no_build_app_diagnostic_skips_project_freshness_and_bootstrap(self) -> None:
        fixture, bootstrap_marker, xcrun_arguments = self.make_fixture(fresh=False)
        completed = self.run_fixture(fixture, "--verify")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(bootstrap_marker.exists())
        self.assertFalse(xcrun_arguments.exists())
        self.assertEqual(
            (fixture / "app-mode-invocations").read_text(encoding="utf-8").splitlines(),
            ["--verify"],
        )

    def test_unknown_mode_is_rejected_before_bootstrap_or_forwarding(self) -> None:
        fixture, bootstrap_marker, xcrun_arguments = self.make_fixture(fresh=False)
        completed = self.run_fixture(fixture, "not-a-mode")

        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertFalse(bootstrap_marker.exists())
        self.assertFalse(xcrun_arguments.exists())
        self.assertFalse((fixture / "app-mode-invocations").exists())


if __name__ == "__main__":
    unittest.main()
