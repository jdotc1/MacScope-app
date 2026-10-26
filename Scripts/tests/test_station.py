"""Scripts/station.sh: build-station claims (D12)."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
STATION = ROOT / "Scripts/station.sh"


class StationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.station = Path(self.temporary.name).resolve() / "s1"
        subprocess.run(["/usr/bin/git", "init", "-q", "-b", "main", str(self.station)], check=True)
        self.environment = {**os.environ, "MACSCOPE_STATIONS": f"S1={self.station}"}

    def run_station(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["/bin/bash", str(STATION), *arguments], capture_output=True,
                              text=True, env=self.environment, check=False)

    def test_claim_is_exclusive_until_released(self) -> None:
        claimed = self.run_station("claim", "S1", "--owner", "lane-a", "--branch", "feature")
        self.assertEqual(claimed.returncode, 0, claimed.stderr)
        record = json.loads((self.station / ".station-claim").read_text())
        self.assertEqual((record["owner"], record["branch"], record["station"]), ("lane-a", "feature", "S1"))
        # Re-claiming by the same owner is idempotent; another owner is refused.
        self.assertEqual(self.run_station("claim", "S1", "--owner", "lane-a").returncode, 0)
        other = self.run_station("claim", str(self.station), "--owner", "lane-b")
        self.assertEqual(other.returncode, 3)
        self.assertIn("claimed by lane-a", other.stderr)
        listing = self.run_station("list")
        self.assertIn("claimed by lane-a", listing.stdout)
        self.assertEqual(self.run_station("release", "S1", "--owner", "lane-b").returncode, 3)
        self.assertEqual(self.run_station("release", "S1", "--owner", "lane-a").returncode, 0)
        self.assertFalse((self.station / ".station-claim").exists())
        self.assertIn("free", self.run_station("list").stdout)
        self.assertEqual(self.run_station("claim", "S1", "--owner", "lane-b").returncode, 0)
        self.assertEqual(self.run_station("release", "S1", "--owner", "lead", "--force").returncode, 0)

    def test_claim_file_is_ignored_by_git(self) -> None:
        ignored = subprocess.run(["/usr/bin/git", "-C", str(ROOT), "check-ignore", "-q", ".station-claim"],
                                 check=False)
        self.assertEqual(ignored.returncode, 0)

    def test_non_station_is_rejected(self) -> None:
        result = self.run_station("claim", self.temporary.name)
        self.assertEqual(result.returncode, 2)


LUMEN_URL = "https://github.com/jdotc1/Lumen.git"


class StationLumenSyncTests(unittest.TestCase):
    """claim/sync move a stale ThirdParty/Lumen to the gitlink, offline, from the seed."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name).resolve()
        self.station, self.seed = root / "s1", root / "lumen-seed"
        self.target = self.station / "ThirdParty/Lumen"
        for repository in (self.station, self.seed):
            self.git(root, "init", "-q", "-b", "main", str(repository))
        self.git(self.seed, "remote", "add", "origin", LUMEN_URL)
        (self.seed / ".gitignore").write_text(".build/\n.swiftpm/\n")
        self.old_pin = self.commit_seed("// old pin\n")
        (self.station / ".gitmodules").write_text(
            '[submodule "ThirdParty/Lumen"]\n\tpath = ThirdParty/Lumen\n\turl = ' + LUMEN_URL + "\n")
        self.pin_station(self.old_pin)
        self.environment = {**os.environ, "MACSCOPE_STATIONS": f"S1={self.station}",
                            "MACSCOPE_LUMEN_SEED": str(self.seed)}
        self.environment.pop("MACSCOPE_LUMEN_SYNC", None)

    def git(self, repository: Path, *arguments: str) -> str:
        result = subprocess.run(
            ["/usr/bin/git", "-C", str(repository), "-c", "user.name=Fixture",
             "-c", "user.email=fixture@example.invalid", *arguments],
            capture_output=True, text=True, check=True,
            env={**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull})
        return result.stdout.strip()

    def commit_seed(self, package: str) -> str:
        (self.seed / "Package.swift").write_text(package)
        self.git(self.seed, "add", ".")
        self.git(self.seed, "commit", "-q", "-m", "Lumen")
        return self.git(self.seed, "rev-parse", "HEAD")

    def pin_station(self, pin: str) -> None:
        self.git(self.station, "add", ".gitmodules")
        self.git(self.station, "update-index", "--add", "--cacheinfo", "160000", pin, "ThirdParty/Lumen")
        self.git(self.station, "commit", "-q", "-m", "Pin Lumen")

    def run_station(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["/bin/bash", str(STATION), *arguments], capture_output=True,
                              text=True, env=self.environment, check=False)

    def test_claim_refreshes_a_stale_submodule_and_sync_is_cheap_when_aligned(self) -> None:
        # A fresh worktree has an empty, uninitialised submodule directory.
        self.target.mkdir(parents=True)
        first = self.run_station("sync", "S1")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn(f"uninitialised -> gitlink {self.old_pin[:7]}", first.stdout)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.old_pin)
        # The branch moves the gitlink; the station keeps the old checkout plus Xcode state.
        new_pin = self.commit_seed("// new pin\n")
        self.pin_station(new_pin)
        (self.target / ".swiftpm/xcode").mkdir(parents=True)
        claimed = self.run_station("claim", "S1", "--owner", "lane-a")
        self.assertEqual(claimed.returncode, 0, claimed.stderr)
        self.assertIn(f"{self.old_pin[:7]} -> gitlink {new_pin[:7]}", claimed.stdout)
        self.assertIn("removed Xcode .swiftpm/.build state", claimed.stdout)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), new_pin)
        self.assertEqual((self.target / "Package.swift").read_text(), "// new pin\n")
        self.assertEqual(self.git(self.station, "status", "--porcelain", "--", "ThirdParty/Lumen"), "")
        aligned = self.run_station("sync", str(self.station))
        self.assertEqual(aligned.stdout.strip(), f"lumen: ThirdParty/Lumen already at gitlink {new_pin[:7]}")

    def test_sync_keeps_real_local_changes_and_never_fails_the_caller(self) -> None:
        self.target.mkdir(parents=True)
        self.assertEqual(self.run_station("sync", "S1").returncode, 0)
        self.pin_station(self.commit_seed("// new pin\n"))
        (self.target / "Package.swift").write_text("// local Lumen edit\n")
        result = self.run_station("claim", "S1", "--owner", "lane-a")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARNING", result.stderr)
        self.assertIn("dirty", result.stderr)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.old_pin)
        self.assertEqual((self.target / "Package.swift").read_text(), "// local Lumen edit\n")
        self.environment["MACSCOPE_LUMEN_SYNC"] = "0"
        self.assertIn("skipped", self.run_station("sync", "S1").stdout)

    def test_inherited_git_environment_does_not_mislead_the_sync(self) -> None:
        """`git bisect run` exports GIT_DIR; dev_loop.sh drops it before the Lumen sync."""
        self.target.mkdir(parents=True)
        self.assertEqual(self.run_station("sync", "S1").returncode, 0)
        inherited = {**self.environment, "GIT_DIR": str(self.station / ".git"), "GIT_WORK_TREE": str(self.station)}
        # Control: with the variables inherited, the sync reads the superproject's HEAD as Lumen's.
        misled = subprocess.run(["/bin/bash", str(STATION), "sync", "S1"], capture_output=True, text=True,
                                env=inherited, check=False)
        self.assertNotIn("already at gitlink", misled.stdout)
        # The line dev_loop.sh runs before the sync restores the correct reading.
        dev_loop = (ROOT / "Scripts/dev_loop.sh").read_text(encoding="utf-8")
        unset_line = next(line for line in dev_loop.splitlines() if line.startswith("unset GIT_"))
        self.assertLess(dev_loop.index(unset_line), dev_loop.index('"${SCRIPT_DIR}/station.sh" sync'))
        self.run_station("claim", "S1", "--owner", "lane-a")
        self.pin_station(self.commit_seed("// moved pin\n"))
        fixed = subprocess.run(["/bin/bash", "-c", unset_line + f'; exec /bin/bash "{STATION}" sync S1'],
                               capture_output=True, text=True, env=inherited, check=False)
        self.assertEqual(fixed.returncode, 0, fixed.stderr)
        self.assertIn("-> gitlink", fixed.stdout)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.git(self.station, "rev-parse", "HEAD:ThirdParty/Lumen"))
        self.assertEqual(self.git(self.station, "status", "--porcelain", "--", "ThirdParty/Lumen"), "")


class DevLoopSchedulingTests(unittest.TestCase):
    def test_dev_loop_slots_priority_and_memory_guard(self) -> None:
        script = (ROOT / "Scripts/dev_loop.sh").read_text(encoding="utf-8")
        self.assertIn('if [[ ! "${DEV_SLOTS}" =~ ^[123]$ ]]; then', script)
        self.assertIn('DEV_SLOTS="${MACSCOPE_DEV_SLOTS:-2}"', script)
        self.assertIn("  /usr/bin/nice -n 5\n  /usr/bin/xcodebuild", script)
        self.assertIn("XCODE_JOBS=3", script)
        self.assertIn('MIN_FREE_GB="${MACSCOPE_DEV_MIN_FREE_GB:-8}"', script)
        self.assertLess(script.index("\nwait_for_memory\n"), script.index('heavy_gate_lock.py" acquire'))
        # A lane that skipped `station.sh claim` still builds against the gitlinked Lumen.
        self.assertLess(script.index('"${SCRIPT_DIR}/station.sh" sync "${ROOT_DIR}" >&2 || true'),
                        script.index('"${ROOT_DIR}/script/build_and_run.sh" --prepare'))

    def test_dev_loop_opens_one_slot_descriptor_per_slot(self) -> None:
        script = (ROOT / "Scripts/dev_loop.sh").read_text(encoding="utf-8")
        for slots, expected in ((2, "8,9"), (3, "8,9,10")):
            with self.subTest(slots=slots), tempfile.TemporaryDirectory() as temporary:
                lock = Path(temporary) / "gate.lock"
                block = script[script.index("    SLOT_FDS=()"):script.index("    SHARED_ARGS=(--shared")]
                program = (f'set -euo pipefail\nDEV_SLOTS={slots}\nLOCK_PATH="{lock}"\n'
                           "if (( DEV_SLOTS > 1 )); then\n" + block +
                           '    echo "$(IFS=,; echo "${SLOT_FDS[*]}")"\nfi\n')
                result = subprocess.run(["/bin/bash", "-c", program], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)
                self.assertEqual(len(list(Path(temporary).glob("gate.lock.slot-*"))), slots)


if __name__ == "__main__":
    unittest.main()
