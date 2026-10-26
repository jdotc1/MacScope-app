"""Shared dev-loop slots on the heavy-gate lock.

Dev loops hold LOCK_SH on the lock plus one slot; heavy phases stay exclusive,
and a waiting heavy phase stops new dev loops from starting.
"""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


HELPER = Path(__file__).resolve().parents[1] / "qualification/heavy_gate_lock.py"


class SharedSlotTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.lock = Path(self.directory.name) / "gate.lock"
        self.holders: list[subprocess.Popen[str]] = []

    def tearDown(self) -> None:
        for holder in self.holders:
            holder.kill()
            holder.wait()
        self.directory.cleanup()

    def script(self, shared: bool, timeout: int, hold: bool, ignore_waiter: bool = False) -> str:
        lock = str(self.lock)
        opens = f'exec 7>>"{lock}"'
        extra = ""
        if shared:
            opens += f' 8>>"{lock}.slot-0" 9>>"{lock}.slot-1"'
            extra = "--shared --slot-fds 8,9" + (" --ignore-exclusive-waiter" if ignore_waiter else "")
        acquire = (
            f'"{sys.executable}" -B "{HELPER}" acquire --fd 7 --lock "{lock}" --pid $$ '
            f"--timeout {timeout} --work-root w --integration-ref r --mode m --run-root rr {extra}"
        )
        tail = 'echo acquired; exec sleep 300' if hold else "echo acquired"
        return f"{opens}\n{acquire} || exit $?\n{tail}\n"

    def hold(self, shared: bool) -> subprocess.Popen[str]:
        holder = subprocess.Popen(
            ["/bin/bash", "-c", self.script(shared, 30, True)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.holders.append(holder)
        self.assertEqual(holder.stdout.readline().strip(), "acquired")
        return holder

    def attempt(self, shared: bool, timeout: int = 2, ignore_waiter: bool = False) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", "-c", self.script(shared, timeout, False, ignore_waiter)],
            capture_output=True,
            text=True,
            timeout=60,
        )

    def test_two_dev_loops_share_and_a_third_waits(self) -> None:
        self.hold(shared=True)
        self.hold(shared=True)
        third = self.attempt(shared=True)
        self.assertEqual(third.returncode, 4, third.stderr)
        self.assertIn("waiting for a shared heavy-gate slot", third.stderr)

    def test_exclusive_holder_blocks_dev_loops(self) -> None:
        self.hold(shared=False)
        blocked = self.attempt(shared=True)
        self.assertEqual(blocked.returncode, 4, blocked.stderr)

    def test_dev_loop_blocks_exclusive_phase(self) -> None:
        self.hold(shared=True)
        blocked = self.attempt(shared=False)
        self.assertEqual(blocked.returncode, 4, blocked.stderr)
        self.assertFalse(Path(str(self.lock) + ".waiting").exists())

    def test_waiting_heavy_phase_stops_new_dev_loops(self) -> None:
        self.hold(shared=True)
        heavy = subprocess.Popen(
            ["/bin/bash", "-c", self.script(False, 30, True)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.holders.append(heavy)
        marker = Path(str(self.lock) + ".waiting")
        deadline = time.monotonic() + 10
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertEqual(json.loads(marker.read_text())["pid"], heavy.pid)
        # A slot is free, but the waiting heavy phase has priority.
        blocked = self.attempt(shared=True)
        self.assertEqual(blocked.returncode, 4, blocked.stderr)
        self.assertIn("backing off: an exclusive heavy phase is queued", blocked.stderr)
        # The escape hatch takes the free slot anyway.
        self.assertEqual(self.attempt(shared=True, ignore_waiter=True).returncode, 0)

    def test_marker_of_a_dead_waiter_is_dropped(self) -> None:
        marker = Path(str(self.lock) + ".waiting")
        dead = subprocess.Popen(["/usr/bin/true"]); dead.wait()
        marker.write_text(json.dumps({"pid": dead.pid, "mode": "full-test"}))
        self.assertEqual(self.attempt(shared=True, timeout=5).returncode, 0)
        self.assertFalse(marker.exists())

    def test_released_slots_are_reusable_after_holder_dies(self) -> None:
        first = self.hold(shared=True)
        self.hold(shared=True)
        first.kill()
        first.wait()
        self.assertEqual(self.attempt(shared=True, timeout=5).returncode, 0)

    def test_shared_requires_slot_descriptors(self) -> None:
        result = subprocess.run(
            [sys.executable, "-B", str(HELPER), "acquire", "--fd", "0", "--lock", str(self.lock),
             "--pid", "1", "--work-root", "w", "--integration-ref", "r", "--mode", "m",
             "--run-root", "rr", "--shared"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)


class DevLoopLockCoverageTests(unittest.TestCase):
    def test_prepare_and_build_run_under_the_lock(self) -> None:
        script = (Path(__file__).resolve().parents[1] / "dev_loop.sh").read_text(encoding="utf-8")
        acquire = script.index("heavy_gate_lock.py\" acquire")
        prepare = script.index('"${ROOT_DIR}/script/build_and_run.sh" --prepare')
        build = script.index("build-for-testing ||")
        release = script.rindex("\nrelease_lock\n")
        # Bootstrap, staging and XcodeGen are minutes of CPU on a cold lane (R10.3).
        self.assertLess(acquire, prepare)
        self.assertLess(prepare, build)
        self.assertLess(build, release)


if __name__ == "__main__":
    unittest.main()
