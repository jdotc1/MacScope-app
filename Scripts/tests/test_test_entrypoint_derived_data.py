from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
TEST_ENTRYPOINT = ROOT / "Scripts" / "test.sh"


class TestEntrypointDerivedDataTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.fixture_root = Path(self.temporary_directory.name)
        self.repository = self.fixture_root / "repository"
        self.scripts = self.repository / "Scripts"
        self.scripts.mkdir(parents=True)
        shutil.copy2(TEST_ENTRYPOINT, self.scripts / "test.sh")

        (self.scripts / "xcode27_env.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        bootstrap = self.scripts / "bootstrap.sh"
        bootstrap.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        bootstrap.chmod(0o755)

        self.fake_bin = self.fixture_root / "bin"
        self.fake_bin.mkdir()
        xcodebuild = self.fake_bin / "xcodebuild"
        xcodebuild.write_text(
            "#!/usr/bin/env bash\n"
            'printf \'%s\\n\' "$@" > "${MACSCOPE_TEST_XCODEBUILD_ARGUMENTS}"\n',
            encoding="utf-8",
        )
        xcodebuild.chmod(0o755)

        self.home = self.fixture_root / "home"
        self.home.mkdir()
        self.caller = self.fixture_root / "caller"
        self.caller.mkdir()
        self.arguments_file = self.fixture_root / "xcodebuild-arguments.txt"

    def run_entrypoint(
        self,
        selector: str,
        *,
        derived_data_override: Path | str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        self.arguments_file.unlink(missing_ok=True)
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(self.home),
                "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT": "/fixture/sleigh",
                "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT": "/fixture/machokit",
                "MACSCOPE_TEST_XCODEBUILD_ARGUMENTS": str(self.arguments_file),
                "PATH": f"{self.fake_bin}{os.pathsep}{environment['PATH']}",
            }
        )
        if derived_data_override is None:
            environment.pop("MACSCOPE_TEST_DERIVED_DATA", None)
        else:
            environment["MACSCOPE_TEST_DERIVED_DATA"] = str(derived_data_override)

        return subprocess.run(
            ["/bin/bash", str(self.scripts / "test.sh"), selector],
            cwd=self.caller,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

    def xcodebuild_arguments(self) -> list[str]:
        self.assertTrue(self.arguments_file.is_file(), "xcodebuild was not invoked")
        return self.arguments_file.read_text(encoding="utf-8").splitlines()

    def derived_data_argument(self) -> Path:
        arguments = self.xcodebuild_arguments()
        index = arguments.index("-derivedDataPath")
        return Path(arguments[index + 1])

    def test_default_is_stable_absolute_and_external_for_every_selector(self) -> None:
        first = self.run_entrypoint("CoreTests/FirstSuite")
        self.assertEqual(first.returncode, 0, first.stderr)
        first_derived_data = self.derived_data_argument()

        expected_key = hashlib.sha256(str(self.repository.resolve()).encode()).hexdigest()[:16]
        expected = (
            self.home
            / "Library/Developer/Xcode/DerivedData"
            / f"MacScopeFocusedTests-{expected_key}"
        )
        self.assertEqual(first_derived_data, expected.resolve())
        self.assertTrue(first_derived_data.is_absolute())
        self.assertNotEqual(first_derived_data, self.repository)
        self.assertNotIn(self.repository, first_derived_data.parents)

        second = self.run_entrypoint("CoreTests/SecondSuite")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.derived_data_argument(), first_derived_data)

    def test_absolute_override_is_forwarded_to_xcodebuild(self) -> None:
        override = self.fixture_root / "diagnostic-derived-data"
        completed = self.run_entrypoint(
            "CoreTests/DiagnosticSuite",
            derived_data_override=override,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(self.derived_data_argument(), override.resolve())
        arguments = self.xcodebuild_arguments()
        self.assertFalse(
            any(argument.startswith("MACSCOPE_GHOSTTY_VT_WORK_ROOT=") for argument in arguments)
        )
        self.assertIn(
            f"MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT={override.resolve()}/Dependencies/GhosttySurface",
            arguments,
        )
        self.assertNotIn("MACSCOPE_GHOSTTY_SOURCE_DIR=/fixture/ghostty", arguments)

    def test_nonexistent_repository_local_override_is_rejected_without_creation(self) -> None:
        override = self.repository / "DerivedData-must-not-exist"
        completed = self.run_entrypoint(
            "CoreTests/RejectedSuite",
            derived_data_override=override,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("must remain outside", completed.stderr)
        self.assertFalse(override.exists())
        self.assertFalse(self.arguments_file.exists())

    def test_symlink_resolved_repository_local_override_is_rejected_without_creation(self) -> None:
        repository_link = self.fixture_root / "repository-link"
        repository_link.symlink_to(self.repository, target_is_directory=True)
        target = self.repository / "SymlinkedDerivedData-must-not-exist"
        completed = self.run_entrypoint(
            "CoreTests/RejectedSuite",
            derived_data_override=repository_link / target.name,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("must remain outside", completed.stderr)
        self.assertFalse(target.exists())
        self.assertFalse(self.arguments_file.exists())

    def test_relative_override_is_rejected(self) -> None:
        completed = self.run_entrypoint(
            "CoreTests/RejectedSuite",
            derived_data_override="relative-DerivedData",
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("must be an absolute path", completed.stderr)
        self.assertFalse(self.arguments_file.exists())


if __name__ == "__main__":
    unittest.main()
