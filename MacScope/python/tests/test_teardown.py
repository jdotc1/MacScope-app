"""Teardown tests that drive real responder subprocesses (no MacScope binary needed).

Each responder is a tiny Python script launched through the client's normal
``[executable, "--mcp", binary]`` command line; the ``binary`` argument selects its mode.
Every case asserts that the client closes all pipes it holds and reaps the child.
"""
from __future__ import annotations

import gc
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import macscope  # noqa: E402

FAST_TIMEOUT = 0.2

RESPONDER = r'''
import json
import signal
import sys
import time

mode = sys.argv[2]
if mode == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
if mode == "exit-before-init":
    sys.exit(3)

request = json.loads(sys.stdin.readline())
sys.stdout.write(json.dumps({
    "jsonrpc": "2.0",
    "id": request["id"],
    "result": {"protocolVersion": "2024-11-05", "capabilities": {}},
}) + "\n")
sys.stdout.flush()
sys.stdin.readline()  # notifications/initialized

if mode == "exit-after-init":
    sys.exit(0)
if mode == "ignore-term":
    sys.stdin.read()  # ignore EOF as well as SIGTERM
    while True:
        time.sleep(60)
for _ in sys.stdin:  # "normal": serve until stdin EOF, then exit cleanly
    pass
sys.exit(0)
'''


class ResponderTeardownTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if os.name != "posix":
            raise unittest.SkipTest("responder fixtures use POSIX signals and shebangs")
        cls._directory = tempfile.mkdtemp(prefix="macscope-responder-")
        cls.responder = os.path.join(cls._directory, "responder")
        with open(cls.responder, "w", encoding="utf-8") as handle:
            handle.write("#!" + sys.executable + "\n" + RESPONDER)
        os.chmod(cls.responder, stat.S_IRWXU)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls._directory, ignore_errors=True)

    def client(self, mode: str) -> "macscope._MCPClient":
        client = macscope._MCPClient(self.responder, mode, terminate_timeout=FAST_TIMEOUT)
        self.addCleanup(self._kill_leftover, client._proc)
        return client

    @staticmethod
    def _kill_leftover(proc: subprocess.Popen) -> None:
        # Safety net so a failing assertion never leaks a responder.
        if proc.poll() is None:
            proc.kill()
            proc.wait()

    def assert_closed_and_reaped(self, proc: subprocess.Popen) -> None:
        for name in ("stdin", "stdout", "stderr"):
            stream = getattr(proc, name)
            if stream is not None:
                self.assertTrue(stream.closed, f"{name} pipe left open")
        self.assertIsNotNone(proc.returncode, "child was not reaped")
        # The kernel no longer has a zombie for this pid: it was waited for.
        with self.assertRaises(ChildProcessError):
            os.waitpid(proc.pid, os.WNOHANG)

    def test_normal_exit_on_stdin_eof(self) -> None:
        client = self.client("normal")
        proc = client._proc
        self.assertIsNone(proc.poll())
        client.close()
        self.assert_closed_and_reaped(proc)
        self.assertEqual(proc.returncode, 0, "EOF should let the server exit by itself")

    def test_already_exited_child_still_closes_pipes(self) -> None:
        client = self.client("exit-after-init")
        proc = client._proc
        self.assertEqual(proc.wait(timeout=5), 0)
        self.assertFalse(proc.stdin.closed)
        self.assertFalse(proc.stdout.closed)
        client.close()
        self.assert_closed_and_reaped(proc)

    def test_sigterm_resistant_child_is_killed_and_reaped(self) -> None:
        client = self.client("ignore-term")
        proc = client._proc
        started = time.monotonic()
        client.close()
        elapsed = time.monotonic() - started
        self.assert_closed_and_reaped(proc)
        self.assertEqual(proc.returncode, -signal.SIGKILL)
        self.assertLess(elapsed, 10 * FAST_TIMEOUT + 2, "teardown must stay bounded")

    def test_piped_stderr_is_closed_too(self) -> None:
        proc = subprocess.Popen(
            [self.responder, "--mcp", "ignore-term"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self._kill_leftover, proc)
        macscope._MCPClient._terminate(proc, FAST_TIMEOUT)
        self.assert_closed_and_reaped(proc)
        self.assertTrue(proc.stderr.closed)

    def test_close_is_idempotent(self) -> None:
        client = self.client("normal")
        proc = client._proc
        client.close()
        client.close()
        self.assertFalse(client._finalizer.alive)
        self.assert_closed_and_reaped(proc)
        with self.assertRaises(macscope.MacScopeError):
            client.call("info")

    def test_dropped_reference_is_finalized(self) -> None:
        client = self.client("normal")
        proc = client._proc
        finalizer = client._finalizer
        del client
        gc.collect()
        self.assertFalse(finalizer.alive)
        self.assert_closed_and_reaped(proc)

    def test_handshake_failure_closes_and_reaps(self) -> None:
        spawned = []
        real_popen = subprocess.Popen

        def recording_popen(*args, **kwargs):
            proc = real_popen(*args, **kwargs)
            spawned.append(proc)
            return proc

        with mock.patch.object(macscope.subprocess, "Popen", side_effect=recording_popen):
            with self.assertRaises(macscope.MacScopeError):
                macscope._MCPClient(
                    self.responder, "exit-before-init", terminate_timeout=FAST_TIMEOUT
                )
        self.assertEqual(len(spawned), 1)
        self.assert_closed_and_reaped(spawned[0])
        self.assertEqual(spawned[0].returncode, 3)

    def test_document_context_manager_tears_down(self) -> None:
        with macscope.open("normal", executable=self.responder) as document:
            proc = document._client._proc
            self.assertIsNone(proc.poll())
        self.assert_closed_and_reaped(proc)
        document.close()  # idempotent at the public layer too


if __name__ == "__main__":
    unittest.main()
