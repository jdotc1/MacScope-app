#!/usr/bin/env python3

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/preflight_self_contained_build.sh"


class PreflightSelfContainedBuildTests(unittest.TestCase):
    def write_stub(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "#!/usr/bin/env python3\n"
            "import os\n"
            "from pathlib import Path\n"
            "log = Path(os.environ['PREFLIGHT_STUB_LOG'])\n"
            "with log.open('a', encoding='utf-8') as stream:\n"
            "    stream.write(Path(__file__).name + '\\n')\n",
            encoding="utf-8",
        )
        path.chmod(0o755)

    def make_fixture(self, root: Path) -> Path:
        for relative in (
            "Scripts/dependencies/validate_policy_consistency.py",
            "Scripts/dependencies/validate_third_party_components.py",
            "Scripts/dependencies/validate_offline_build_surface.py",
            "Scripts/check_local_signing_policy.py",
            "Scripts/native-decompiler-xpc/prepare_repository_sleigh_materialization.py",
            "Scripts/machokit_source_identity.py",
            "Scripts/build_ghostty_vt.sh",
            "Scripts/dependencies/build_vendored_ghostty_surface.sh",
        ):
            path = root / relative
            if path.suffix == ".sh":
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(
                    "#!/usr/bin/env bash\n"
                    "printf '%s\\n' \"$(basename \"$0\")\" >> \"$PREFLIGHT_STUB_LOG\"\n",
                    encoding="utf-8",
                )
                path.chmod(0o755)
            else:
                self.write_stub(path)
        return root

    def run_preflight(self, repo: Path, work: Path, log: Path) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PREFLIGHT_STUB_LOG"] = str(log)
        return subprocess.run(
            [str(SCRIPT), "--repo-root", str(repo), "--work-root", str(work)],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_runs_each_stage_once_in_order_without_xcode_or_network(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.make_fixture(Path(temporary) / "repo")
            work = Path(temporary) / "work"
            stub_log = Path(temporary) / "stubs.log"
            result = self.run_preflight(fixture, work, stub_log)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS (9 stages)", result.stdout)
            self.assertEqual(
                stub_log.read_text(encoding="utf-8").splitlines(),
                [
                    "validate_policy_consistency.py",
                    "validate_third_party_components.py",
                    "validate_offline_build_surface.py",
                    "check_local_signing_policy.py",
                    "build_ghostty_vt.sh",
                    "build_vendored_ghostty_surface.sh",
                    "prepare_repository_sleigh_materialization.py",
                    "machokit_source_identity.py",
                ],
            )
            self.assertTrue((work / "preflight.log").is_file())
            source = SCRIPT.read_text(encoding="utf-8")
            self.assertNotIn("xcodebuild", source)
            self.assertNotIn("curl", source)
            self.assertNotIn("git clone", source)
            self.assertIn("machokit_source_identity.py\" publish-read-only", source)
            self.assertIn('--source-root "${REPO_ROOT}/ThirdParty/MachOKit/materialization"', source)
            self.assertIn('--work-root "${WORK_ROOT}/MachOKit"', source)
            self.assertIn("prepare_repository_sleigh_materialization.py", source)
            self.assertIn('--work-root "${WORK_ROOT}/SleighNative"', source)

    def test_rejects_repository_work_root_before_running_stages(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.make_fixture(Path(temporary) / "repo")
            result = self.run_preflight(fixture, fixture / "DerivedData", Path(temporary) / "stubs.log")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("outside the repository", result.stderr)


if __name__ == "__main__":
    unittest.main()
