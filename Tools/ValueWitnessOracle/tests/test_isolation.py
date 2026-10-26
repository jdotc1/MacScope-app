import json
import os
import subprocess
import unittest


class IsolationTests(unittest.TestCase):
    def run_check(self, mode):
        binary = os.environ.get("VWO_ISOLATION_TEST_BINARY")
        self.assertTrue(binary, "build IsolationChecks.swift with IsolatedQuery.swift and set VWO_ISOLATION_TEST_BINARY")
        result = subprocess.run([binary, mode], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_success_returns_witness_from_a_child(self):
        self.assertEqual(self.run_check("success"),
                         {"child": True, "vwt": {"size": 16}, "mangled": "4Test5ValueV"})

    def test_large_result_drains_pipe_before_waiting(self):
        self.assertEqual(self.run_check("large"), {"payload": "x" * 262144})

    def test_crash_keeps_identity_and_continues_and_reaps(self):
        result = self.run_check("crash")
        self.assertEqual(result["reason"], "host-crash")
        self.assertEqual(result["mangled"], "4Test5ValueV")
        self.assertEqual(result["signal"], 11)
        self.assertEqual(result["next"], {"vwt": {"size": 8}})
        self.assertTrue(result["reaped"])

    def test_transport_failure_is_not_a_runtime_answer(self):
        self.assertEqual(self.run_check("exit"), {"caught": True, "code": 74})

    def test_nonisolated_mode_uses_calling_process(self):
        self.assertEqual(self.run_check("direct"), {"sameProcess": True})

    def test_host_pinned_witness_self_test(self):
        host = os.environ.get("VWO_HOST")
        self.assertTrue(host, "set VWO_HOST to the built oracle")
        result = subprocess.run([host, "--self-test"], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS SSSg size=16 stride=16 flags=0x2210007", result.stdout)
