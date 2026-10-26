#!/usr/bin/env python3
"""Focused unittest contract for the installed stdio MCP smoke harness."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/smoke/mcp_operability_smoke.sh"
CANDIDATE = "a" * 40
TREE = "c" * 40


NAVIGATOR_TOOL_NAMES = (
    "navigator-facts",
    "navigator-frontier",
    "navigator-dependents",
    "navigator-primitives",
    "navigator-preview-revert",
    "navigator-revert",
    "navigator-accept",
    "navigator-toolchain",
    "navigator-resolve-provenance",
)
NAVIGATOR_MUTATING_NAMES = ("navigator-revert", "navigator-accept")


def canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


class MCPOperabilitySmokeTests(unittest.TestCase):
    def run_script(
        self,
        mode: str,
        fixture: "FakeMCPApp",
        *,
        timeout: float = 2.0,
        candidate: str = CANDIDATE,
        output: Path | None = None,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        arguments = [
            str(SCRIPT),
            "--mode",
            mode,
            "--app",
            str(fixture.app),
            "--binary",
            str(fixture.binary),
            "--timeout-seconds",
            str(timeout),
            "--candidate-commit",
            candidate,
        ]
        if output is not None:
            arguments.extend(["--output", str(output)])
        return subprocess.run(
            arguments,
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
            env=environment,
        )

    def test_invalid_top_level_provenance_is_rejected_before_launch(self) -> None:
        invalid_fields = (
            ("schema_version", None),
            ("schema_version", True),
            ("schema_version", 1.0),
            ("schema_version", 2),
            ("git_head_commit", None),
            ("git_head_commit", "b" * 40),
            ("git_head_tree", None),
            ("git_head_tree", "c" * 39),
            ("git_head_tree", int("1" * 40)),
            ("selected_build_inputs_sha256", None),
            ("selected_build_inputs_sha256", "d" * 63),
            ("selected_build_inputs_sha256", int("1" * 64)),
            ("qualification_eligible", False),
            ("repository_clean", False),
            ("configuration", "Debug"),
        )
        for field, value in invalid_fields:
            with self.subTest(field=field, value=value):
                with FakeMCPApp(FakeMCPApp.success_server_body(), marker=True) as fixture:
                    payload = json.loads(fixture.provenance.read_text(encoding="utf-8"))
                    if value is None:
                        payload.pop(field)
                    else:
                        payload[field] = value
                    # A fabricated nested identity must never rescue invalid real fields.
                    payload["source_identity"] = {"kind": "fixture"}
                    fixture.provenance.write_text(json.dumps(payload), encoding="utf-8")
                    result = self.run_script("installed", fixture)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("eligible sealed Release", result.stderr)
                    self.assertFalse(fixture.marker.exists())

    def test_preflight_is_filesystem_only_and_does_not_launch(self) -> None:
        with FakeMCPApp("raise SystemExit(99)\n", marker=True) as fixture:
            result = self.run_script("preflight", fixture)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(fixture.marker.exists())
            self.assertEqual(
                result.stdout,
                "PASS: MCP preflight passed without Xcode or launching MacScope\n",
            )

    def test_full_exchange_uses_exact_request_ids_and_initialized_notification(self) -> None:
        with FakeMCPApp(FakeMCPApp.success_server_body(), request_log=True) as fixture:
            result = self.run_script("installed", fixture)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertEqual(
                result.stdout,
                "PASS: installed MCP initialize, tools/list, and read-only info call\n",
            )
            requests = [
                json.loads(line)
                for line in fixture.request_log.read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(
                [(item.get("id"), item["method"]) for item in requests],
                [
                    (1, "initialize"),
                    (None, "notifications/initialized"),
                    (2, "tools/list"),
                    (3, "tools/call"),
                ],
            )
            self.assertEqual(requests[3]["params"], {"arguments": {}, "name": "info"})

    def test_missing_navigator_tool_fails_closed(self) -> None:
        body = FakeMCPApp.success_server_body(omit_tool="navigator-toolchain")
        with FakeMCPApp(body) as fixture:
            result = self.run_script("installed", fixture)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("navigator-toolchain", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_navigator_mutation_flag_mismatch_fails_closed(self) -> None:
        body = FakeMCPApp.success_server_body(flag_read_only_as_mutating="navigator-facts")
        with FakeMCPApp(body) as fixture:
            result = self.run_script("installed", fixture)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("mutation flag for navigator-facts", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_mismatched_response_id_fails_closed(self) -> None:
        body = (
            "import json, sys, time\n"
            "time.sleep(0.35)\n"
            "request = json.loads(sys.stdin.readline())\n"
            "print(json.dumps({'jsonrpc':'2.0','id':2,'result':{}}), flush=True)\n"
            "while True: pass\n"
        )
        with FakeMCPApp(body) as fixture:
            result = self.run_script("installed", fixture, timeout=0.1)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("id mismatch", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_partial_response_deadline_retires_exact_owned_group(self) -> None:
        body = (
            "import os, pathlib, sys, time\n"
            "time.sleep(0.35)\n"
            "pathlib.Path(" + repr("__PID_PATH__") + ").write_text(str(os.getpid()))\n"
            "sys.stdin.readline()\n"
            "sys.stdout.write('{')\n"
            "sys.stdout.flush()\n"
            "time.sleep(5)\n"
        )
        with FakeMCPApp(body, substitute_pid_path=True) as fixture:
            started = time.monotonic()
            result = self.run_script("installed", fixture, timeout=0.1)
            elapsed = time.monotonic() - started
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("timeout", result.stderr.lower())
            self.assertLess(elapsed, 2.5)
            pid = int(fixture.pid_path.read_text(encoding="utf-8"))
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_stderr_and_stdout_frames_are_strictly_bounded(self) -> None:
        stderr_body = (
            "import sys, time\n"
            "time.sleep(0.35)\n"
            "sys.stderr.write('x' * 70000)\n"
            "sys.stderr.flush()\n"
            "time.sleep(5)\n"
        )
        with FakeMCPApp(stderr_body) as fixture:
            result = self.run_script("installed", fixture, timeout=0.1)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("stderr exceeded", result.stderr)
            self.assertLessEqual(len(result.stderr.encode("utf-8")), 1024)

        stdout_body = (
            "import sys, time\n"
            "time.sleep(0.35)\n"
            "sys.stdin.readline()\n"
            "sys.stdout.write('x' * 70000)\n"
            "sys.stdout.flush()\n"
            "time.sleep(5)\n"
        )
        with FakeMCPApp(stdout_body) as fixture:
            result = self.run_script("installed", fixture, timeout=0.1)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("stdout exceeded", result.stderr)

    def test_stdout_contamination_after_final_response_is_rejected(self) -> None:
        with FakeMCPApp(
            FakeMCPApp.success_server_body(extra_stdout=True),
            request_log=True,
        ) as fixture:
            result = self.run_script("installed", fixture)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("contaminated stdout", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_bridge_report_is_exact_canonical_and_create_only(self) -> None:
        with FakeMCPApp(FakeMCPApp.success_server_body()) as fixture:
            authority_path, authority = fixture.authority()
            environment = dict(os.environ)
            environment["MACSCOPE_OPERABILITY_TEST_SEAMS"] = "1"
            environment["MACSCOPE_OPERABILITY_TEST_AUTHORITY"] = str(authority_path)
            report = fixture.root / "mcp-report.json"
            result = self.run_script(
                "installed",
                fixture,
                output=report,
                environment=environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = report.read_bytes()
            document = json.loads(payload)
            self.assertEqual(payload, canonical_json(document))
            self.assertEqual(report.stat().st_nlink, 1)
            self.assertEqual(
                set(document),
                {"authority", "probeResults", "reportKind", "schemaVersion", "status"},
            )
            self.assertEqual(document["authority"], authority)
            self.assertEqual(
                document["probeResults"],
                {"initialize": True, "readOnlyInfo": True, "toolsList": True},
            )
            self.assertEqual(document["reportKind"], "macscope-mcp-operability-report-v1")
            self.assertEqual(document["status"], "passed")

            repeated = self.run_script(
                "installed",
                fixture,
                output=report,
                environment=environment,
            )
            self.assertNotEqual(repeated.returncode, 0)
            self.assertIn("create-only", repeated.stderr)

    def test_stale_authority_and_unsealed_provenance_are_rejected_before_launch(self) -> None:
        with FakeMCPApp(FakeMCPApp.success_server_body(), marker=True) as fixture:
            authority_path, authority = fixture.authority()
            authority["sourceTree"] = "0" * 40
            authority_path.write_bytes(canonical_json(authority))
            environment = dict(os.environ)
            environment["MACSCOPE_OPERABILITY_TEST_SEAMS"] = "1"
            environment["MACSCOPE_OPERABILITY_TEST_AUTHORITY"] = str(authority_path)
            result = self.run_script(
                "installed",
                fixture,
                output=fixture.root / "report.json",
                environment=environment,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("stale, synthetic", result.stderr)
            self.assertFalse(fixture.marker.exists())

        with FakeMCPApp(FakeMCPApp.success_server_body()) as fixture:
            provenance = json.loads(fixture.provenance.read_text(encoding="utf-8"))
            provenance["configuration"] = "Debug"
            fixture.provenance.write_text(json.dumps(provenance), encoding="utf-8")
            result = self.run_script("installed", fixture)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("eligible sealed Release", result.stderr)

    def test_test_authority_override_requires_explicit_seam(self) -> None:
        with FakeMCPApp(FakeMCPApp.success_server_body()) as fixture:
            authority_path, _ = fixture.authority()
            environment = dict(os.environ)
            environment.pop("MACSCOPE_OPERABILITY_TEST_SEAMS", None)
            environment["MACSCOPE_OPERABILITY_TEST_AUTHORITY"] = str(authority_path)
            result = self.run_script("preflight", fixture, environment=environment)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("explicit test seam", result.stderr)

    def test_source_contract_is_stdio_loopback_only_and_has_no_online_surface(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('[str(executable), "--mcp", str(binary)]', source)
        self.assertIn("start_new_session=True", source)
        self.assertIn("MAX_LINE_BYTES", source)
        self.assertIn("127.0.0.1:9", source)
        for forbidden in ("curl", "wget", "http://localhost", "xcodebuild", "pkill", "killall"):
            self.assertNotIn(forbidden, source)
        for name in NAVIGATOR_TOOL_NAMES:
            self.assertIn(f'"{name}"', source)


class FakeMCPApp:
    def __init__(
        self,
        body: str,
        *,
        marker: bool = False,
        request_log: bool = False,
        substitute_pid_path: bool = False,
    ) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name).resolve()
        self.binary = self.root / "analysis-fixture.macho"
        # A bounded arm64 MH_EXECUTE header; transport is the fake app below.
        self.binary.write_bytes(struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0))
        self.app = self.root / "MacScope.app"
        self.executable = self.app / "Contents/MacOS/MacScope"
        self.provenance = self.app / "Contents/Resources/MacScopeBuildProvenance.json"
        self.marker = self.root / "launched"
        self.request_log = self.root / "requests.jsonl"
        self.pid_path = self.root / "pid"
        self.executable.parent.mkdir(parents=True)
        if request_log:
            body = body.replace("__REQUEST_LOG__", str(self.request_log))
        if substitute_pid_path:
            body = body.replace("__PID_PATH__", str(self.pid_path))
        marker_line = (
            f"from pathlib import Path\nPath({str(self.marker)!r}).touch()\n"
            if marker
            else ""
        )
        self.executable.write_text(
            "#!/usr/bin/python3\n" + marker_line + body,
            encoding="utf-8",
        )
        self.executable.chmod(self.executable.stat().st_mode | stat.S_IXUSR)
        self.provenance.parent.mkdir(parents=True)
        self.provenance.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "qualification_eligible": True,
                    "configuration": "Release",
                    "repository_clean": True,
                    "git_head_commit": CANDIDATE,
                    "git_head_tree": TREE,
                    "selected_build_inputs_sha256": "d" * 64,
                }
            ),
            encoding="utf-8",
        )

    def __enter__(self) -> "FakeMCPApp":
        return self

    def __exit__(self, *_: object) -> None:
        self.directory.cleanup()

    @staticmethod
    def success_server_body(
        *,
        extra_stdout: bool = False,
        omit_tool: str | None = None,
        flag_read_only_as_mutating: str | None = None,
    ) -> str:
        tools: list[dict[str, object]] = [
            {"name": "info", "description": "read-only", "inputSchema": {"type": "object"}}
        ]
        for name in NAVIGATOR_TOOL_NAMES:
            if name == omit_tool:
                continue
            mutating = name in NAVIGATOR_MUTATING_NAMES or name == flag_read_only_as_mutating
            tools.append({
                "name": name,
                "description": "navigator" + (" (mutates the workspace)" if mutating else ""),
                "inputSchema": {"type": "object"},
            })
        tools_literal = repr(json.dumps(tools))
        final_action = (
            "        print('contamination', flush=True)\n"
            if extra_stdout
            else "        pass\n"
        )
        return (
            "import json, pathlib, sys\n"
            "log_path = pathlib.Path('__REQUEST_LOG__')\n"
            "for line in sys.stdin:\n"
            "    request = json.loads(line)\n"
            "    if '__REQUEST_LOG__' != str(log_path) or log_path.name != '__REQUEST_LOG__':\n"
            "        with log_path.open('a', encoding='utf-8') as handle:\n"
            "            handle.write(json.dumps(request, sort_keys=True) + '\\n')\n"
            "    method = request.get('method')\n"
            "    if method == 'notifications/initialized':\n"
            "        continue\n"
            "    request_id = request.get('id')\n"
            "    if method == 'initialize':\n"
            "        result = {'protocolVersion':'2024-11-05','serverInfo':{'name':'macscope'}}\n"
            "    elif method == 'tools/list':\n"
            f"        result = {{'tools':json.loads({tools_literal})}}\n"
            "    elif method == 'tools/call':\n"
            "        result = {'isError':False,'content':[{'type':'text','text':json.dumps({'format':'Mach-O executable'})}]}\n"
            "    else:\n"
            "        print(json.dumps({'jsonrpc':'2.0','id':request_id,'error':{'code':-32601,'message':'Method not found'}}), flush=True)\n"
            "        continue\n"
            "    print(json.dumps({'jsonrpc':'2.0','id':request_id,'result':result}, separators=(',', ':')), flush=True)\n"
            "    if method == 'tools/call':\n"
            + final_action
        )

    def authority(self) -> tuple[Path, dict[str, object]]:
        executable_digest = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        provenance_digest = hashlib.sha256(self.provenance.read_bytes()).hexdigest()
        authority: dict[str, object] = {
            "applicationExecutableSHA256": executable_digest,
            "buildProvenanceSHA256": provenance_digest,
            "candidateFileSHA256": "1" * 64,
            "candidateIdentitySHA256": "2" * 64,
            "destinationIdentitySHA256": "3" * 64,
            "executionIdentitySHA256": "4" * 64,
            "exposedAtUnixNanoseconds": time.time_ns() - 1_000_000,
            "forcedLegacyGridReportSHA256": "5" * 64,
            "fullSurfaceReportSHA256": "6" * 64,
            "installedExecutableSHA256": executable_digest,
            "installationPendingStateSHA256": "7" * 64,
            "nativeLiveXPCReportSHA256": "8" * 64,
            "predecessorObservationsSHA256": "9" * 64,
            "qualificationRunID": "focused-operability-test",
            "shellBrokerExecutableSHA256": "a" * 64,
            "shellBrokerInfoPlistSHA256": "b" * 64,
            "sourceCommit": CANDIDATE,
            "sourceEqualitySHA256": "c" * 64,
            "sourceTree": TREE,
            "transactionID": "focused-transaction",
        }
        path = self.root / "authority.json"
        path.write_bytes(canonical_json(authority))
        return path, authority


if __name__ == "__main__":
    unittest.main()
