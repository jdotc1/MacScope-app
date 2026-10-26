"""Startup/request deadline tests (MS-11) that drive real responder subprocesses.

Each responder is a tiny Python script launched through the client's normal
``[executable, "--mcp", binary]`` command line; the ``binary`` argument selects how it
misbehaves. Every failure case asserts that the call returns within a monotonic budget,
that the client is retired (child reaped, every pipe closed) and that the typed error
names the phase, method, request id and whether the outcome is unknown. No MacScope
binary is needed. Budgets are short so the module stays well under ten seconds.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import macscope  # noqa: E402

STARTUP = 0.5     # startup budget for the case that never acknowledges
REQUEST = 0.5     # request budget for the hung-request cases
HANDSHAKE = 10.0  # generous startup budget where the handshake itself is healthy
TERMINATE = 0.2   # per-stage teardown budget
MARGIN = 1.5      # scheduling slack for loaded CI hosts

RESPONDER = r'''
import json
import os
import signal
import sys
import time

mode = sys.argv[2]
log_path = os.environ.get("MACSCOPE_TEST_RESPONDER_LOG")


def log(line):
    if log_path:
        with open(log_path, "a") as handle:
            handle.write(line if line.endswith("\n") else line + "\n")


def send(text):
    sys.stdout.write(text)
    sys.stdout.flush()


def hang():
    while True:
        time.sleep(60)


if mode == "exit-immediately":
    os._exit(4)  # exits before reading anything (the flaky `false` stand-in, made explicit)
if mode == "never-ack":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)  # retirement must escalate to SIGKILL
    log(sys.stdin.readline())
    hang()

request = json.loads(sys.stdin.readline())
send(json.dumps({"jsonrpc": "2.0", "id": request["id"],
                 "result": {"protocolVersion": "2024-11-05", "capabilities": {}}}) + "\n")
sys.stdin.readline()  # notifications/initialized

if mode == "blocked-stdin":
    hang()  # never reads stdin again
if mode == "close-stdin":
    os.close(0)  # alive, but no reader is left on its stdin: the next write gets EPIPE
    log('{"closed": "stdin"}')
    hang()

for line in sys.stdin:
    log(line)
    request = json.loads(line)
    if mode == "partial-line":
        send('{"jsonrpc": "2.0", "id": %d, "result": {"content": [' % request["id"])
        hang()
    if mode == "notification-only":
        while True:
            send(json.dumps({"jsonrpc": "2.0", "method": "notifications/progress",
                             "params": {"progress": 1}}) + "\n")
            time.sleep(0.005)
    if mode == "exit-mid-request":
        send('{"jsonrpc": "2.0", "id": %d, "res' % request["id"])
        os._exit(7)
    if mode == "hang-request":
        hang()
    if mode == "slow":
        time.sleep(0.15)
    text = json.dumps({"echo": request["params"]["arguments"]})
    send(json.dumps({"jsonrpc": "2.0", "id": request["id"],
                     "result": {"content": [{"type": "text", "text": text}]}}) + "\n")
'''


class DeadlineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if os.name != "posix":
            raise unittest.SkipTest("responder fixtures use POSIX pipes, signals and shebangs")
        cls._directory = tempfile.mkdtemp(prefix="macscope-deadline-")
        cls.responder = os.path.join(cls._directory, "responder")
        with open(cls.responder, "w", encoding="utf-8") as handle:
            handle.write("#!" + sys.executable + "\n" + RESPONDER)
        os.chmod(cls.responder, stat.S_IRWXU)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls._directory, ignore_errors=True)

    def setUp(self) -> None:
        self.log = os.path.join(self._directory, f"{self.id()}.log")
        patcher = mock.patch.dict(os.environ, {"MACSCOPE_TEST_RESPONDER_LOG": self.log})
        patcher.start()
        self.addCleanup(patcher.stop)

    # -- helpers --
    def spawn_recorder(self):
        spawned = []
        real_popen = subprocess.Popen

        def recording_popen(*args, **kwargs):
            proc = real_popen(*args, **kwargs)
            spawned.append(proc)
            self.addCleanup(self._kill_leftover, proc)
            return proc

        patcher = mock.patch.object(macscope.subprocess, "Popen", side_effect=recording_popen)
        patcher.start()
        self.addCleanup(patcher.stop)
        return spawned

    def client(self, mode: str, **timeouts) -> "macscope._MCPClient":
        timeouts.setdefault("startup_timeout", HANDSHAKE)
        timeouts.setdefault("request_timeout", REQUEST)
        client = macscope._MCPClient(self.responder, mode, terminate_timeout=TERMINATE, **timeouts)
        self.addCleanup(self._kill_leftover, client._proc)
        return client

    @staticmethod
    def _kill_leftover(proc: subprocess.Popen) -> None:
        if proc.poll() is None:  # safety net: a failing assertion never leaks a responder
            proc.kill()
            proc.wait()

    def assert_retired(self, proc: subprocess.Popen) -> None:
        for name in ("stdin", "stdout", "stderr"):
            stream = getattr(proc, name)
            if stream is not None:
                self.assertTrue(stream.closed, f"{name} pipe left open")
        self.assertIsNotNone(proc.returncode, "child was not reaped")
        with self.assertRaises(ChildProcessError):
            os.waitpid(proc.pid, os.WNOHANG)

    def assert_error(self, error, cls, **fields) -> None:
        self.assertIs(type(error), cls)
        for key, value in fields.items():
            self.assertEqual(getattr(error, key), value, key)
        message = str(error)
        self.assertIn(error.phase, message)
        self.assertIn(repr(error.method), message)
        if error.request_id is not None:
            self.assertIn(f"id {error.request_id}", message)
        if error.outcome_unknown:
            self.assertIn("outcome is unknown", message)
            self.assertIn("not retried", message)

    def logged_requests(self, method: str) -> list:
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as handle:
            messages = [json.loads(line) for line in handle if line.strip()]
        return [m for m in messages if m.get("method") == method]

    def assert_no_retry_and_fails_fast(self, client, proc) -> None:
        """Exactly one copy reached the server, and the retired client refuses new work
        immediately instead of resending or respawning."""
        self.assertEqual(len(self.logged_requests("tools/call")), 1)
        started = time.monotonic()
        with self.assertRaises(macscope.MacScopeTransportError) as raised:
            client.call("info")
        self.assertLess(time.monotonic() - started, 0.1)
        self.assertEqual(raised.exception.stage, "queue")
        self.assertFalse(raised.exception.outcome_unknown)
        self.assertEqual(len(self.logged_requests("tools/call")), 1)
        self.assertEqual(proc.returncode, proc.poll())

    # -- the five required fixtures --
    def test_never_acknowledged_handshake_times_out_in_startup(self) -> None:
        spawned = self.spawn_recorder()
        started = time.monotonic()
        with self.assertRaises(macscope.MacScopeTimeoutError) as raised:
            macscope._MCPClient(
                self.responder, "never-ack",
                startup_timeout=STARTUP, request_timeout=REQUEST, terminate_timeout=TERMINATE,
            )
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, STARTUP)
        self.assertLess(elapsed, STARTUP + 2 * TERMINATE + MARGIN)
        error = raised.exception
        self.assert_error(
            error, macscope.MacScopeTimeoutError,
            phase="startup", method="initialize", request_id=1, tool=None, stage="read",
            outcome_unknown=True, retired=True, timeout=STARTUP,
        )
        self.assertGreaterEqual(error.elapsed, STARTUP)
        self.assertEqual(len(spawned), 1)
        self.assert_retired(spawned[0])
        self.assertEqual(spawned[0].returncode, -signal.SIGKILL, "SIGTERM was ignored")

    def test_child_exiting_before_reading_raises_typed_startup_error(self) -> None:
        spawned = self.spawn_recorder()
        for _ in range(5):
            with self.assertRaises(macscope.MacScopeTransportError) as raised:
                macscope._MCPClient(
                    self.responder, "exit-immediately",
                    startup_timeout=HANDSHAKE, request_timeout=REQUEST,
                    terminate_timeout=TERMINATE,
                )
            error = raised.exception
            self.assertIs(type(error), macscope.MacScopeTransportError)
            self.assertEqual((error.phase, error.method, error.request_id),
                             ("startup", "initialize", 1))
            self.assertTrue(error.retired)
            self.assertIn(error.stage, ("queue", "write", "read"))
        self.assertEqual(len(spawned), 5)
        for proc in spawned:
            self.assert_retired(proc)
            self.assertEqual(proc.returncode, 4)

    def test_broken_stdin_pipe_is_a_typed_write_error(self) -> None:
        client = self.client("close-stdin")
        proc = client._proc
        deadline = time.monotonic() + 5
        while not os.path.exists(self.log) and time.monotonic() < deadline:
            time.sleep(0.01)  # wait until the live responder has closed its stdin
        self.assertTrue(os.path.exists(self.log))
        self.assertIsNone(proc.poll(), "responder must still be alive (EPIPE, not exit)")
        started = time.monotonic()
        with self.assertRaises(macscope.MacScopeTransportError) as raised:
            client.call("rename", {"address": "0x1", "name": "x"})
        self.assertLess(time.monotonic() - started, 2 * TERMINATE + MARGIN)
        self.assert_error(
            raised.exception, macscope.MacScopeTransportError,
            phase="request", method="tools/call", request_id=2, tool="rename",
            stage="write", outcome_unknown=False, retired=True,
        )
        self.assertIn("stdin closed by server", str(raised.exception))
        self.assert_retired(proc)
        self.assertEqual(proc.returncode, -signal.SIGTERM)

    def test_dead_child_mid_session_fails_before_sending(self) -> None:
        client = self.client("normal")
        proc = client._proc
        os.kill(proc.pid, signal.SIGKILL)
        proc_wait = proc.wait(5)
        self.assertEqual(proc_wait, -signal.SIGKILL)
        with self.assertRaises(macscope.MacScopeTransportError) as raised:
            client.call("rename", {"address": "0x1", "name": "x"})
        self.assertEqual((raised.exception.phase, raised.exception.request_id), ("request", 2))
        self.assertFalse(raised.exception.outcome_unknown)
        self.assert_retired(proc)

    def test_partial_line_times_out_and_retires(self) -> None:
        client = self.client("partial-line")
        proc = client._proc
        started = time.monotonic()
        with self.assertRaises(macscope.MacScopeTimeoutError) as raised:
            client.call("rename", {"address": "0x1000", "name": "_start"})
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, REQUEST)
        self.assertLess(elapsed, REQUEST + 2 * TERMINATE + MARGIN)
        self.assert_error(
            raised.exception, macscope.MacScopeTimeoutError,
            phase="request", method="tools/call", request_id=2, tool="rename", stage="read",
            outcome_unknown=True, retired=True, timeout=REQUEST,
        )
        self.assertIn("'rename'", str(raised.exception))
        self.assert_retired(proc)
        self.assert_no_retry_and_fails_fast(client, proc)

    def test_blocked_stdin_bounds_the_write(self) -> None:
        client = self.client("blocked-stdin")
        proc = client._proc
        payload = "x" * (4 * 1024 * 1024)  # far beyond any pipe buffer
        started = time.monotonic()
        with self.assertRaises(macscope.MacScopeTimeoutError) as raised:
            client.call("set-comment", {"address": "0x1000", "comment": payload})
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, REQUEST)
        self.assertLess(elapsed, REQUEST + 2 * TERMINATE + MARGIN)
        self.assert_error(
            raised.exception, macscope.MacScopeTimeoutError,
            phase="request", method="tools/call", request_id=2, tool="set-comment",
            stage="write", outcome_unknown=True, retired=True,
        )
        self.assert_retired(proc)

    def test_notification_flood_does_not_extend_the_deadline(self) -> None:
        client = self.client("notification-only")
        proc = client._proc
        started = time.monotonic()
        with self.assertRaises(macscope.MacScopeTimeoutError) as raised:
            client.call("functions", {"limit": 1})
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, REQUEST)
        self.assertLess(elapsed, REQUEST + 2 * TERMINATE + MARGIN)
        self.assert_error(
            raised.exception, macscope.MacScopeTimeoutError,
            phase="request", method="tools/call", request_id=2, tool="functions",
            stage="read", outcome_unknown=True, retired=True,
        )
        self.assert_retired(proc)
        self.assert_no_retry_and_fails_fast(client, proc)

    def test_exit_mid_request_reports_unknown_outcome_without_waiting(self) -> None:
        client = self.client("exit-mid-request", request_timeout=5.0)
        proc = client._proc
        started = time.monotonic()
        with self.assertRaises(macscope.MacScopeTransportError) as raised:
            client.call("define-type", {"name": "T", "kind": "struct"})
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 2 * TERMINATE + MARGIN, "EOF must not wait for the deadline")
        error = raised.exception
        self.assert_error(
            error, macscope.MacScopeTransportError,
            phase="request", method="tools/call", request_id=2, tool="define-type",
            stage="read", outcome_unknown=True, retired=True,
        )
        self.assertIn("middle of a message", str(error))
        self.assertIn("exit status 7", str(error))
        self.assert_retired(proc)
        self.assertEqual(proc.returncode, 7)
        self.assert_no_retry_and_fails_fast(client, proc)

    # -- defaults, overrides and concurrency policy --
    def test_healthy_requests_are_unaffected(self) -> None:
        client = self.client("normal")
        self.assertEqual(client.call("info", {"n": 1}), {"echo": {"n": 1}})
        self.assertEqual(client.call("info", {"n": 2}), {"echo": {"n": 2}})
        proc = client._proc
        client.close()
        self.assert_retired(proc)
        self.assertEqual(proc.returncode, 0)

    def test_timeout_resolution_order_and_validation(self) -> None:
        resolve = macscope._resolve_timeout
        env = "MACSCOPE_REQUEST_TIMEOUT"
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop(env, None)
            self.assertEqual(resolve(macscope._UNSET, env, 120.0), 120.0)
            os.environ[env] = "2.5"
            self.assertEqual(resolve(macscope._UNSET, env, 120.0), 2.5)
            self.assertEqual(resolve(7, env, 120.0), 7.0)  # explicit argument wins
            self.assertIsNone(resolve(None, env, 120.0))   # explicit opt-out
            os.environ[env] = "none"
            self.assertIsNone(resolve(macscope._UNSET, env, 120.0))
            for bad in ("abc", "0", "-1", "inf", "nan"):
                os.environ[env] = bad
                with self.assertRaises(macscope.MacScopeError):
                    resolve(macscope._UNSET, env, 120.0)
        for bad in (0, -1, float("inf"), float("nan"), True, "5"):
            with self.assertRaises(macscope.MacScopeError):
                resolve(bad, env, 120.0)
        self.assertEqual(macscope.DEFAULT_STARTUP_TIMEOUT > macscope.DEFAULT_REQUEST_TIMEOUT, True)

    def test_env_override_reaches_the_client(self) -> None:
        with mock.patch.dict(os.environ, {"MACSCOPE_REQUEST_TIMEOUT": "0.3",
                                          "MACSCOPE_STARTUP_TIMEOUT": "9"}):
            with macscope.open("hang-request", executable=self.responder) as document:
                self.assertEqual(document._client._request_timeout, 0.3)
                self.assertEqual(document._client._startup_timeout, 9.0)
                started = time.monotonic()
                with self.assertRaises(macscope.MacScopeTimeoutError) as raised:
                    document.info()
                self.assertLess(time.monotonic() - started, 0.3 + 2 * 5.0 + MARGIN)
                self.assertEqual(raised.exception.timeout, 0.3)

    def test_concurrent_callers_are_serialized(self) -> None:
        client = self.client("slow", request_timeout=5.0)
        results, errors = [], []

        def worker(n: int) -> None:
            try:
                results.append(client.call("info", {"n": n}))
            except Exception as exc:  # pragma: no cover - reported below
                errors.append(exc)

        threads = [threading.Thread(target=worker, args=(n,)) for n in range(3)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(10)
        self.assertEqual(errors, [])
        self.assertEqual(sorted(r["echo"]["n"] for r in results), [0, 1, 2])
        client.close()

    def test_queue_wait_counts_against_the_request_deadline(self) -> None:
        client = self.client("normal", request_timeout=0.3)
        proc = client._proc
        client._lock.acquire()  # another request is "in flight"
        try:
            started = time.monotonic()
            with self.assertRaises(macscope.MacScopeTimeoutError) as raised:
                client.call("info")
            self.assertLess(time.monotonic() - started, 0.3 + MARGIN)
        finally:
            client._lock.release()
        self.assert_error(
            raised.exception, macscope.MacScopeTimeoutError,
            phase="request", method="tools/call", request_id=None, tool="info",
            stage="queue", outcome_unknown=False, retired=False,
        )
        self.assertIsNone(proc.poll(), "a queue timeout sent nothing, so the client stays up")
        self.assertEqual(client.call("info", {"n": 1}), {"echo": {"n": 1}})
        client.close()
        self.assert_retired(proc)

    def test_close_from_another_thread_interrupts_an_in_flight_request(self) -> None:
        client = self.client("hang-request", request_timeout=30.0)
        proc = client._proc
        caught = []

        def worker() -> None:
            try:
                client.call("rename", {"address": "0x1", "name": "x"})
            except Exception as exc:
                caught.append(exc)

        thread = threading.Thread(target=worker)
        thread.start()
        time.sleep(0.2)
        started = time.monotonic()
        client.close()
        thread.join(5)
        self.assertLess(time.monotonic() - started, 2 * TERMINATE + MARGIN)
        self.assertFalse(thread.is_alive())
        self.assertEqual(len(caught), 1)
        self.assertIsInstance(caught[0], macscope.MacScopeTransportError)
        self.assertTrue(caught[0].outcome_unknown)
        self.assert_retired(proc)


if __name__ == "__main__":
    unittest.main()
