from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BUILD_AND_RUN = ROOT / "MacScope" / "script" / "build_and_run.sh"


class BuildAndRunDerivedDataTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.fixture_root = Path(self.temporary_directory.name)
        self.repository = self.fixture_root / "repository"
        self.script_directory = self.repository / "MacScope" / "script"
        self.script_directory.mkdir(parents=True)
        shutil.copy2(BUILD_AND_RUN, self.script_directory / "build_and_run.sh")
        self.generated_project = self.repository / "MacScope/MacScope.xcodeproj"
        self.generated_project.mkdir()
        self.project_file = self.generated_project / "project.xcproj"
        self.project_file.write_text("// fixture project\n", encoding="utf-8")

        support_directory = self.repository / "Scripts"
        support_directory.mkdir()
        (support_directory / "xcode27_env.sh").write_text(
            "#!/usr/bin/env bash\n", encoding="utf-8"
        )
        (support_directory / "check_local_signing_policy.py").write_text(
            "raise SystemExit(0)\n", encoding="utf-8"
        )
        (support_directory / "runloop_exact_app.py").write_text(
            "import hashlib, os, pathlib, sys\n"
            "with open(os.environ['MACSCOPE_RUN_HELPER_ARGUMENTS'], 'a', encoding='utf-8') as handle:\n"
            "    handle.write('\\0'.join(sys.argv[1:]) + '\\n')\n"
            "command = sys.argv[1]\n"
            "def option(name): return sys.argv[sys.argv.index(name) + 1]\n"
            "repository = pathlib.Path(option('--repository')) if '--repository' in sys.argv else None\n"
            "project = repository / 'MacScope/MacScope.xcodeproj/project.xcproj' if repository else None\n"
            "project_identity = hashlib.sha256(project.read_bytes()).hexdigest() if project else None\n"
            "if command == 'source-identity': print('a' * 64)\n"
            "elif command == 'verify-dependencies': print('b' * 64)\n"
            "elif command == 'generated-project-identity': print(project_identity)\n"
            "elif command == 'record-build':\n"
            "    if option('--expected-project-identity') != project_identity:\n"
            "        print('generated project identity changed', file=sys.stderr)\n"
            "        raise SystemExit(1)\n"
            "    print('fixture-build-generation')\n"
            "elif command == 'verify-build': print('/fixture/MacScope')\n"
            "elif command == 'verify': print('{\"pid\":42}')\n"
            "elif command == 'launch': print('MacScope ready: pid=42')\n"
            "elif command == 'stop': print('MacScope stopped')\n",
            encoding="utf-8",
        )

        self.fake_bin = self.fixture_root / "bin"
        self.fake_bin.mkdir()
        xcrun = self.fake_bin / "xcrun"
        xcrun.write_text(
            "#!/usr/bin/env bash\n"
            'printf \'%s\\n\' "$@" > "${MACSCOPE_RUN_XCRUN_ARGUMENTS}"\n'
            'if [[ "${MACSCOPE_RUN_MUTATE_PROJECT:-0}" == "1" ]]; then\n'
            '  printf \'// mutated by fake Xcode\\n\' >> "${MACSCOPE_RUN_PROJECT_FILE}"\n'
            "fi\n",
            encoding="utf-8",
        )
        xcrun.chmod(0o755)

        self.home = self.fixture_root / "home"
        self.home.mkdir()
        self.caller = self.fixture_root / "caller"
        self.caller.mkdir()
        self.arguments_file = self.fixture_root / "xcrun-arguments.txt"
        self.helper_arguments_file = self.fixture_root / "helper-arguments.txt"

    def run_entrypoint(
        self,
        *arguments: str,
        derived_data_override: Path | str | None = None,
        mutate_project: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        self.arguments_file.unlink(missing_ok=True)
        self.helper_arguments_file.unlink(missing_ok=True)
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(self.home),
                "MACSCOPE_RUN_XCRUN_ARGUMENTS": str(self.arguments_file),
                "MACSCOPE_RUN_HELPER_ARGUMENTS": str(self.helper_arguments_file),
                "MACSCOPE_RUN_MUTATE_PROJECT": "1" if mutate_project else "0",
                "MACSCOPE_RUN_PROJECT_FILE": str(self.project_file),
                "PATH": f"{self.fake_bin}{os.pathsep}{environment['PATH']}",
            }
        )
        if derived_data_override is None:
            environment.pop("MACSCOPE_DERIVED_DATA", None)
        else:
            environment["MACSCOPE_DERIVED_DATA"] = str(derived_data_override)

        return subprocess.run(
            ["/bin/bash", str(self.script_directory / "build_and_run.sh"), *arguments],
            cwd=self.caller,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

    def xcrun_arguments(self) -> list[str]:
        self.assertTrue(self.arguments_file.is_file(), "xcrun was not invoked")
        return self.arguments_file.read_text(encoding="utf-8").splitlines()

    def derived_data_argument(self) -> Path:
        arguments = self.xcrun_arguments()
        index = arguments.index("-derivedDataPath")
        return Path(arguments[index + 1])

    def test_default_is_stable_absolute_and_unique_to_the_worktree(self) -> None:
        first = self.run_entrypoint()
        self.assertEqual(first.returncode, 0, first.stderr)
        first_derived_data = self.derived_data_argument()

        expected_key = hashlib.sha256(
            str(self.repository.resolve()).encode()
        ).hexdigest()[:16]
        expected = (
            self.home
            / "Library/Developer/Xcode/DerivedData"
            / f"MacScopeRun-{expected_key}"
        )
        self.assertEqual(first_derived_data, expected.resolve())
        self.assertTrue(first_derived_data.is_absolute())
        self.assertNotIn(self.repository, first_derived_data.parents)

        second = self.run_entrypoint()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.derived_data_argument(), first_derived_data)
        self.assertIn("-showBuildTimingSummary", self.xcrun_arguments())

    def test_absolute_external_override_is_forwarded(self) -> None:
        override = self.fixture_root / "diagnostic-derived-data"
        completed = self.run_entrypoint(derived_data_override=override)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(self.derived_data_argument(), override.resolve())

    def test_repository_local_override_is_rejected_without_creation(self) -> None:
        override = self.repository / "DerivedData-must-not-exist"
        completed = self.run_entrypoint(derived_data_override=override)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("must remain outside", completed.stderr)
        self.assertFalse(override.exists())
        self.assertFalse(self.arguments_file.exists())

    def test_exact_repository_root_override_is_rejected(self) -> None:
        completed = self.run_entrypoint(derived_data_override=self.repository)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("outside the repository", completed.stderr)
        self.assertFalse(self.arguments_file.exists())

    def test_filesystem_root_override_is_rejected(self) -> None:
        completed = self.run_entrypoint(derived_data_override=Path("/"))

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("dedicated external directory", completed.stderr)
        self.assertFalse(self.arguments_file.exists())

    def test_home_root_override_is_rejected_but_home_subdirectory_is_allowed(self) -> None:
        rejected = self.run_entrypoint(derived_data_override=self.home)

        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("dedicated external directory", rejected.stderr)
        self.assertFalse(self.arguments_file.exists())

        allowed = self.home / "Library/Developer/Xcode/DerivedData/ExplicitMacScopeRun"
        completed = self.run_entrypoint(derived_data_override=allowed)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(self.derived_data_argument(), allowed.resolve())

    def test_symlinked_repository_local_override_is_rejected_without_creation(self) -> None:
        repository_link = self.fixture_root / "repository-link"
        repository_link.symlink_to(self.repository, target_is_directory=True)
        target = self.repository / "SymlinkedDerivedData-must-not-exist"
        completed = self.run_entrypoint(
            derived_data_override=repository_link / target.name
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("must remain outside", completed.stderr)
        self.assertFalse(target.exists())
        self.assertFalse(self.arguments_file.exists())

    def test_relative_override_is_rejected(self) -> None:
        completed = self.run_entrypoint(
            derived_data_override="relative-DerivedData"
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("must be an absolute path", completed.stderr)
        self.assertFalse(self.arguments_file.exists())

    def test_legacy_global_root_is_absent(self) -> None:
        script = BUILD_AND_RUN.read_text(encoding="utf-8")
        self.assertNotIn("/private/tmp/MacScopeRunDerivedData", script)

    def test_help_and_unknown_mode_never_invoke_helper_or_xcode(self) -> None:
        help_result = self.run_entrypoint("--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("Build-capable modes", help_result.stderr)
        self.assertFalse(self.arguments_file.exists())
        self.assertFalse(self.helper_arguments_file.exists())

        unknown = self.run_entrypoint("not-a-mode")
        self.assertEqual(unknown.returncode, 2, unknown.stderr)
        self.assertFalse(self.arguments_file.exists())
        self.assertFalse(self.helper_arguments_file.exists())

    def test_no_build_modes_never_invoke_xcodebuild(self) -> None:
        completed = self.run_entrypoint("verify")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(self.arguments_file.exists())
        helper_commands = [
            line.split("\0", 1)[0]
            for line in self.helper_arguments_file.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(helper_commands, ["verify"])

    def test_build_does_not_stop_or_launch_and_run_does_both(self) -> None:
        built = self.run_entrypoint("build")
        self.assertEqual(built.returncode, 0, built.stderr)
        build_commands = [
            line.split("\0", 1)[0]
            for line in self.helper_arguments_file.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(
            build_commands,
            [
                "verify-dependencies",
                "source-identity",
                "generated-project-identity",
                "record-build",
            ],
        )

        launched = self.run_entrypoint("run")
        self.assertEqual(launched.returncode, 0, launched.stderr)
        run_commands = [
            line.split("\0", 1)[0]
            for line in self.helper_arguments_file.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(
            run_commands,
            [
                "stop",
                "verify-dependencies",
                "source-identity",
                "generated-project-identity",
                "record-build",
                "launch",
            ],
        )

    def test_fake_xcode_project_mutation_blocks_build_receipt(self) -> None:
        completed = self.run_entrypoint("build", mutate_project=True)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("generated project identity changed", completed.stderr)
        self.assertTrue(self.arguments_file.exists(), "fake Xcode must have run")
        helper_commands = [
            line.split("\0", 1)[0]
            for line in self.helper_arguments_file.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(
            helper_commands,
            [
                "verify-dependencies",
                "source-identity",
                "generated-project-identity",
                "record-build",
            ],
        )

    def test_debug_uses_the_executable_returned_by_verified_build_receipt(self) -> None:
        completed = self.run_entrypoint("debug")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            self.xcrun_arguments(),
            ["lldb", "--", "/fixture/MacScope"],
        )
        helper_commands = [
            line.split("\0", 1)[0]
            for line in self.helper_arguments_file.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(
            helper_commands,
            [
                "stop",
                "verify-dependencies",
                "source-identity",
                "generated-project-identity",
                "record-build",
                "verify-build",
            ],
        )

    def test_script_has_no_name_wide_process_discovery_or_termination(self) -> None:
        source = BUILD_AND_RUN.read_text(encoding="utf-8")
        for forbidden in ("pgrep", "pkill", "killall", "lsof"):
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
