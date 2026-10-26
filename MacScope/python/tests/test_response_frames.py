"""DOT-65: tiny new response-frame witnesses over the real owned-child transport.

No fake _PipeTransport, native MacScope, old suite replay, or production-sized stress input.
The private cap is lowered to 512 bytes only for these fixtures. Instrumented os.read calls
use the real OS; all fake-owned-child response writes are smaller than POSIX PIPE_BUF.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import macscope

CAP = 512
REQUEST_TIMEOUT = 2.0
STARTUP_TIMEOUT = 3.0
TERMINATE_TIMEOUT = 0.2
FAILURE_BUDGET = 1.5

# Independent protocol witness: builds physical bytes and records an applied mutation
# before producing its oversized response. It does not emulate client framing internals.
RESPONDER = r'''
import json
import os
import sys
import time
with open(sys.argv[2], encoding="utf-8") as handle:
    config = json.load(handle)
cap = config["cap"]
mode = config["mode"]


def log(event):
    with open(config["log"], "a", encoding="utf-8") as handle:
        handle.write(json.dumps(event) + "\n")


def encode(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def padded_result(request_id, size, unicode_text=False):
    empty = encode({"jsonrpc": "2.0", "id": request_id, "result": ""})
    if unicode_text:
        # EURO SIGN starts at byte 63: a 64-byte real read splits its three-byte encoding.
        prefix = empty.index(b'"result":"') + len(b'"result":"')
        text = "a" * (63 - prefix) + "\u20ac"
        text += "b" * (size - len(empty) - len(text.encode("utf-8")))
    else:
        text = "x" * (size - len(empty))
    payload = encode({"jsonrpc": "2.0", "id": request_id, "result": text})
    assert len(payload) == size
    return payload


def hang():
    while True:
        time.sleep(60)


request = json.loads(sys.stdin.buffer.readline())
log({"received": request})
if mode == "startup-overflow":
    os.write(1, b"!" * (cap + 1) + b"\n")
    hang()
os.write(1, encode({"jsonrpc": "2.0", "id": request["id"], "result": {}}) + b"\n")
log({"received": json.loads(sys.stdin.buffer.readline())})
request = json.loads(sys.stdin.buffer.readline())
log({"received": request})
request_id = request["id"]

if mode == "mutation-overflow":
    log({"applied": request["params"]["arguments"]["name"]})
    payload = padded_result(request_id, cap + 1)
elif mode == "no-newline":
    payload = b"!" * (cap + 1)
    log({"payload_bytes": len(payload), "terminated": False})
    for offset in range(0, len(payload), 64):
        os.write(1, payload[offset:offset + 64])
    hang()
elif mode == "noise-overflow":
    payload = b"\xff" * (cap + 1)
elif mode == "notification-overflow":
    notification = {"jsonrpc": "2.0", "method": "notifications/progress", "params": ""}
    notification["params"] = "n" * (cap + 1 - len(encode(notification)))
    payload = encode(notification)
elif mode == "coalesced":
    notification = encode({"jsonrpc": "2.0", "method": "tick"}) + b"\n"
    payload = padded_result(request_id, cap)
    # First 1024-byte read has complete short frames plus an incomplete response suffix.
    wire = b"\nnot-json\n" + notification * 20 + payload + b"\n"
    assert 1024 < len(wire) < 4096
    log({"payload_bytes": len(payload), "wire_bytes": len(wire), "coalesced": True})
    os.write(1, wire)
    hang()
else:
    payload = padded_result(request_id, config["size"], mode.startswith("utf8"))
log({"payload_bytes": len(payload), "terminated": True})
assert len(payload) + 1 < 4096
os.write(1, payload + b"\n")
hang()
'''


class ResponseFrameTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.name != "posix":
            raise unittest.SkipTest("real responder fixtures require POSIX pipes/shebangs")
        cls.directory = Path(tempfile.mkdtemp(prefix="macscope-dot65-"))
        cls.responder = cls.directory / "responder"
        cls.responder.write_text("#!" + sys.executable + "\n" + RESPONDER, encoding="utf-8")
        cls.responder.chmod(stat.S_IRWXU)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.directory)

    def setUp(self):
        self.evidence = {"cap_bytes": CAP}
        patcher = mock.patch.object(macscope, "_MAX_RESPONSE_BYTES", CAP)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.log = self.directory / (self._testMethodName + ".jsonl")
        self.config = self.directory / (self._testMethodName + ".json")

    @staticmethod
    def clean_child(proc):
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=1)
        for stream in (proc.stdin, proc.stdout, proc.stderr):
            if stream is not None:
                stream.close()

    def make_client(self, mode, size=CAP, read_chunk=None):
        if read_chunk is not None:
            patcher = mock.patch.object(macscope, "_READ_CHUNK", read_chunk)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.config.write_text(json.dumps({
            "mode": mode, "size": size, "cap": CAP, "log": str(self.log),
        }), encoding="utf-8")
        real_popen = subprocess.Popen
        self.spawned = []

        def spawn(*args, **kwargs):
            proc = real_popen(*args, **kwargs)
            self.spawned.append(proc)
            self.addCleanup(self.clean_child, proc)
            return proc

        with mock.patch.object(macscope.subprocess, "Popen", side_effect=spawn):
            client = macscope._MCPClient(
                str(self.responder), str(self.config), startup_timeout=STARTUP_TIMEOUT,
                request_timeout=REQUEST_TIMEOUT, terminate_timeout=TERMINATE_TIMEOUT,
            )
        self.addCleanup(client.close)
        self.evidence["mode"] = mode
        return client

    def read_events(self):
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]

    def observe_reads(self, client):
        self.reads = []
        real_read = os.read

        def read(fd, count):
            data = real_read(fd, count)
            if fd == client._transport._in_fd:
                self.reads.append(data)
                self.assertLessEqual(count, macscope._READ_CHUNK)
                self.assertLessEqual(len(client._transport._buffer), CAP)
                self.assertLessEqual(len(client._transport._chunk), macscope._READ_CHUNK)
            return data

        patcher = mock.patch.object(macscope.os, "read", side_effect=read)
        patcher.start()
        self.addCleanup(patcher.stop)

    def assert_retired(self, client, error):
        self.assertEqual(error.phase, "request")
        self.assertEqual(error.stage, "read")
        self.assertEqual(error.request_id, 2)
        self.assertTrue(error.outcome_unknown and error.retired and client._retired)
        self.assertIsNotNone(client._proc.poll())
        self.assertEqual(client._proc.wait(timeout=0), client._proc.returncode)
        self.assertTrue(client._proc.stdin.closed and client._proc.stdout.closed)
        self.assertLessEqual(len(client._transport._buffer), CAP)
        self.assertLessEqual(len(client._transport._chunk), macscope._READ_CHUNK)
        self.evidence.update({
            "retired": True, "reaped": True, "pipes_closed": True,
            "outcome_unknown": error.outcome_unknown,
            "buffer_bytes_at_failure": len(client._transport._buffer),
            "chunk_bytes_at_failure": len(client._transport._chunk),
            "read_sizes": [len(data) for data in self.reads],
        })

    def overflow(self, mode, *, read_chunk=None, mutation=False):
        client = self.make_client(mode, size=CAP + 1, read_chunk=read_chunk)
        self.observe_reads(client)
        real_loads = json.loads
        started = time.monotonic()
        with mock.patch.object(macscope.json, "loads", wraps=real_loads) as decoder:
            with self.assertRaises(macscope.MacScopeTransportError) as caught:
                if mutation:
                    client.call("rename", {"address": "0x1000", "name": "after"})
                else:
                    client._request("probe")
            self.assertEqual(decoder.call_count, 0, "overflow must precede decode/noise skipping")
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, FAILURE_BUDGET)
        self.assertNotIsInstance(caught.exception, macscope.MacScopeTimeoutError)
        self.assertIn("exceeds 512 bytes", str(caught.exception))
        self.assert_retired(client, caught.exception)
        self.evidence.update({"overflow_elapsed_seconds": elapsed, "decode_calls": 0})
        return client, caught.exception

    def success(self, mode, size=CAP, read_chunk=None):
        client = self.make_client(mode, size=size, read_chunk=read_chunk)
        self.observe_reads(client)
        result = client._request("probe")
        self.assertIsInstance(result, str)
        self.assertFalse(client._retired)
        self.assertEqual(client._transport._buffer, b"")
        self.assertEqual(self.read_events()[-1]["payload_bytes"], size)
        self.evidence.update({"payload_bytes": size, "read_sizes": [len(data) for data in self.reads]})
        client.close()
        self.assertIsNotNone(client._proc.poll())
        return result

    def test_cap_minus_one(self):
        result = self.success("valid", CAP - 1)
        self.assertTrue(result and set(result) == {"x"})

    def test_exact_cap_excludes_lf(self):
        self.success("valid", CAP)
        self.assertEqual(len(b"".join(self.reads)), CAP + 1)
        self.assertTrue(b"".join(self.reads).endswith(b"\n"))

    def test_cap_plus_one_mutation_single_chunk_retires_without_retry(self):
        client, error = self.overflow("mutation-overflow", mutation=True)
        self.assertEqual(error.method, "tools/call")
        self.assertEqual(error.tool, "rename")
        self.assertEqual([len(data) for data in self.reads], [CAP + 2])
        events = self.read_events()
        requests = [event["received"] for event in events if "received" in event]
        self.assertEqual(sum(request["method"] == "tools/call" for request in requests), 1)
        self.assertIn({"applied": "after"}, events)
        with mock.patch.object(client._transport, "write_line", wraps=client._transport.write_line) as writer:
            with self.assertRaises(macscope.MacScopeTransportError) as refused:
                client.call("rename", {"address": "0x1000", "name": "again"})
            self.assertEqual(writer.call_count, 0)
        self.assertEqual(refused.exception.stage, "queue")
        self.assertFalse(refused.exception.outcome_unknown)
        self.assertTrue(refused.exception.retired)
        self.assertEqual(self.read_events(), events)
        self.evidence.update({"applied_before_overflow": True, "mutation_requests_seen": 1,
                              "later_write_calls": 0, "later_outcome_unknown": False})

    def test_no_newline_overflow_across_bounded_chunks(self):
        client, _ = self.overflow("no-newline", read_chunk=64)
        self.assertGreater(len(self.reads), 1)
        self.assertEqual(sum(map(len, self.reads)), CAP + 1)
        self.assertTrue(all(b"\n" not in data for data in self.reads))
        self.assertEqual(len(client._transport._buffer), CAP)
        self.assertEqual(len(client._transport._chunk), 1)

    def test_coalesced_frames_and_incomplete_suffix(self):
        self.success("coalesced", CAP, read_chunk=1024)
        self.assertEqual(len(self.reads[0]), 1024)
        self.assertGreater(self.reads[0].count(b"\n"), 2)
        self.assertFalse(self.reads[0].endswith(b"\n"))
        self.assertGreater(len(self.reads), 1)
        self.assertGreater(len(self.reads[0]), CAP)

    def test_utf8_split_exact_byte_cap(self):
        result = self.success("utf8-valid", CAP, read_chunk=64)
        self.assertIn("\u20ac", result)
        self.assertTrue(self.reads[0].endswith(b"\xe2"))
        self.assertTrue(self.reads[1].startswith(b"\x82\xac"))
        wire = b"".join(self.reads)
        self.assertEqual(len(wire) - 1, CAP)
        self.assertEqual(len(wire[:-1].decode("utf-8")), CAP - 2)
        self.evidence["split_utf8_observed"] = True

    def test_utf8_under_character_cap_but_over_byte_cap(self):
        self.overflow("utf8-overflow")
        payload = b"".join(self.reads)[:-1]
        self.assertEqual(len(payload), CAP + 1)
        self.assertEqual(len(payload.decode("utf-8")), CAP - 1)

    def test_oversized_nonjson_noise_cannot_bypass_bound(self):
        self.overflow("noise-overflow")

    def test_oversized_notification_cannot_bypass_bound(self):
        self.overflow("notification-overflow")

    def test_startup_overflow_reaps_owned_child(self):
        started = time.monotonic()
        with self.assertRaises(macscope.MacScopeTransportError) as caught:
            self.make_client("startup-overflow")
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, FAILURE_BUDGET)
        self.assertEqual(len(self.spawned), 1)
        proc = self.spawned[0]
        self.assertIsNotNone(proc.poll())
        self.assertEqual(proc.wait(timeout=0), proc.returncode)
        self.assertTrue(proc.stdin.closed and proc.stdout.closed)
        self.assertEqual(caught.exception.phase, "startup")
        self.assertEqual(caught.exception.method, "initialize")
        self.assertEqual(caught.exception.request_id, 1)
        self.assertEqual(caught.exception.stage, "read")
        self.assertTrue(caught.exception.outcome_unknown and caught.exception.retired)
        self.assertNotIsInstance(caught.exception, macscope.MacScopeTimeoutError)
        self.evidence.update({"retired": True, "reaped": True, "pipes_closed": True,
                              "outcome_unknown": True, "overflow_elapsed_seconds": elapsed})


class TimedResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.records = []

    def startTest(self, test):
        self.started = time.monotonic()
        super().startTest(test)

    def stopTest(self, test):
        elapsed = time.monotonic() - self.started
        failed = any(case is test for case, _ in self.failures + self.errors)
        skipped = any(case is test for case, _ in self.skipped)
        self.records.append({"test": test.id(), "elapsed_seconds": elapsed,
                             "status": "failed" if failed else "skipped" if skipped else "passed",
                             "evidence": test.evidence})
        super().stopTest(test)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path)
    args = parser.parse_args()
    started = time.monotonic()
    result = unittest.TextTestRunner(verbosity=2, resultclass=TimedResult).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(ResponseFrameTests)
    )
    record = {"topic": "DOT-65 response frames", "elapsed_seconds": time.monotonic() - started,
              "tests_run": result.testsRun, "failures": len(result.failures),
              "errors": len(result.errors), "skipped": len(result.skipped),
              "cases": result.records}
    if args.results:
        args.results.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    raise SystemExit(0 if result.wasSuccessful() else 1)
