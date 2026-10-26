"""check_pin_changes.py refuses a stray ThirdParty/* gitlink change; the real pin matches its record."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "Scripts/check_pin_changes.py"
OLD, NEW = "1" * 40, "2" * 40


def git(repo: Path, *arguments: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *arguments], check=True, capture_output=True, text=True,
                          env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                               "GIT_COMMITTER_EMAIL": "t@t"}).stdout


class PinChangeGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.repo = Path(self.directory.name)
        git(self.repo, "init", "-q", "-b", "main")
        self.manifest(OLD)
        git(self.repo, "update-index", "--add", "--cacheinfo", f"160000,{OLD},ThirdParty/Lumen")
        git(self.repo, "add", "FIRST_PARTY_COMPONENTS.json")
        git(self.repo, "commit", "-q", "-m", "base")
        git(self.repo, "switch", "-q", "-c", "lane")

    def tearDown(self) -> None:
        self.directory.cleanup()

    def manifest(self, revision: str) -> None:
        (self.repo / "FIRST_PARTY_COMPONENTS.json").write_text(json.dumps({"components": [{"path": "ThirdParty/Lumen", "git_revision": revision}]}))

    def check(self, **environment: str) -> subprocess.CompletedProcess[str]:
        env = {key: value for key, value in os.environ.items() if key != "MACSCOPE_ALLOW_PIN_CHANGE"}
        return subprocess.run([sys.executable, "-B", str(CHECK), "--repo", str(self.repo), "--base", "main"],
                              capture_output=True, text=True, env={**env, **environment})

    def move_gitlink(self, with_manifest: bool) -> None:
        git(self.repo, "update-index", "--cacheinfo", f"160000,{NEW},ThirdParty/Lumen")
        if with_manifest:
            self.manifest(NEW)
            git(self.repo, "add", "FIRST_PARTY_COMPONENTS.json")
        git(self.repo, "commit", "-q", "-m", "change")

    def test_unrelated_branch_passes(self) -> None:
        (self.repo / "a.txt").write_text("x")
        git(self.repo, "add", "a.txt")
        git(self.repo, "commit", "-q", "-m", "unrelated")
        self.assertEqual(self.check().returncode, 0)

    def test_stray_gitlink_change_is_refused(self) -> None:
        self.move_gitlink(with_manifest=False)
        result = self.check()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("ThirdParty/Lumen gitlink but not FIRST_PARTY_COMPONENTS.json", result.stderr)
        self.assertEqual(self.check(MACSCOPE_ALLOW_PIN_CHANGE="1").returncode, 0)

    def test_deliberate_pin_bump_passes(self) -> None:
        self.move_gitlink(with_manifest=True)
        self.assertEqual(self.check().returncode, 0)


class RecordedPinTests(unittest.TestCase):
    def test_lumen_gitlink_equals_recorded_pin(self) -> None:
        # Backstop for a bypassed guard: HEAD's gitlink must be the pin FIRST_PARTY_COMPONENTS.json records.
        if not (ROOT / ".git").exists():
            self.skipTest("needs the Git checkout")
        recorded = {item["path"]: item["git_revision"]
                    for item in json.loads((ROOT / "FIRST_PARTY_COMPONENTS.json").read_text())["components"]}
        for path, revision in recorded.items():
            entry = subprocess.run(["git", "-C", str(ROOT), "ls-tree", "HEAD", path],
                                   capture_output=True, text=True, check=True).stdout.split()
            with self.subTest(path=path):
                self.assertEqual(entry[:3][1:], ["commit", revision], entry)


if __name__ == "__main__":
    unittest.main()
