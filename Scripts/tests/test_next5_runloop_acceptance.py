from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Mapping, Sequence
from copy import deepcopy
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/next5_runloop_acceptance.py"
SPEC = importlib.util.spec_from_file_location("next5_runloop_acceptance", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load runloop acceptance producer")
acceptance = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = acceptance
SPEC.loader.exec_module(acceptance)


def canonical(value: object, *, newline: bool = False) -> bytes:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return payload + (b"\n" if newline else b"")


class FakeChild:
    def __init__(self, pid: int) -> None:
        self.pid = pid
        self.returncode: int | None = None
        self.signals: list[str] = []

    def poll(self) -> int | None:
        return self.returncode

    def wait(self, timeout: float | None = None) -> int:
        if self.returncode is None:
            raise subprocess.TimeoutExpired("fake-child", timeout)
        return self.returncode

    def terminate(self) -> None:
        self.signals.append("terminate")
        self.returncode = -15

    def kill(self) -> None:
        self.signals.append("kill")
        self.returncode = -9


class FakeRuntime:
    def __init__(self, configuration: acceptance.Configuration) -> None:
        self.configuration = configuration
        self.fd_count = 7
        self.current: list[acceptance.ProcessRecord] = []
        self.baseline_inventory = [
            {"pid": 91, "executablePath": "/Applications/OtherMacScope.app/Contents/MacOS/MacScope"}
        ]
        self.next_pid = 4100
        self.launch_number = 0
        self.repeat_identity = False
        self.keep_survivor = False
        self._survivors: list[acceptance.ProcessRecord] = []
        self.diagnostic_records: list[acceptance.ProcessRecord] = []
        self.keep_diagnostic_survivor = False

    def launch(self) -> acceptance.ProcessRecord:
        self.launch_number += 1
        if self.repeat_identity and self.launch_number > 1:
            pid = 4100
            start = 1_700_000_001
            microseconds = 1
        else:
            pid = self.next_pid
            self.next_pid += 10
            start = 1_700_000_000 + self.launch_number
            microseconds = self.launch_number
        root = acceptance.ProcessRecord(
            pid=pid,
            ppid=1,
            start_seconds=start,
            start_microseconds=microseconds,
            executable_path=str(self.configuration.executable),
            open_file_count=31,
        )
        child = acceptance.ProcessRecord(
            pid=pid + 1,
            ppid=pid,
            start_seconds=start,
            start_microseconds=self.launch_number + 100,
            executable_path=str(
                self.configuration.app_bundle
                / "Contents/XPCServices/AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService"
            ),
            open_file_count=12,
        )
        self.current = [root, child]
        return root

    def stop(self) -> None:
        if self.keep_survivor and self.current:
            self._survivors = [self.current[0]]
        self.current = []

    def snapshot(self) -> tuple[acceptance.ProcessRecord, ...]:
        return tuple(self.current + self._survivors + self.diagnostic_records)

    def coordinator_fd_count(self) -> int:
        return self.fd_count

    def application_inventory(self) -> list[dict[str, object]]:
        rows = list(self.baseline_inventory)
        if self.current:
            root = self.current[0]
            rows.append({"pid": root.pid, "executablePath": root.executable_path})
        return rows

    def sleep(self, seconds: float) -> None:
        return None


class FakeCommands:
    def __init__(
        self,
        configuration: acceptance.Configuration,
        authority: acceptance.CandidateAuthority,
        runtime: FakeRuntime,
    ) -> None:
        self.configuration = configuration
        self.authority = authority
        self.runtime = runtime
        self.calls: list[tuple[str, str]] = []
        self.children: list[FakeChild] = []
        self.generation_index = 0
        self.debug_returncode = 0
        self.debug_mentions_executable = True
        self.wrong_build_digest = False
        self.leave_recovery = False
        self.leak_fd = False
        self.leave_process_receipt = False
        self.verify_identity_mismatch = False

    @staticmethod
    def _option(argv: Sequence[str], name: str) -> Path:
        index = list(argv).index(name)
        return Path(argv[index + 1])

    def _write_build(self) -> None:
        self.generation_index += 1
        executable = self.configuration.executable
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_bytes(b"exact-final-executable")
        executable.chmod(0o755)
        (self.configuration.app_bundle / "Contents/Info.plist").write_bytes(b"fixture")
        digest = hashlib.sha256(executable.read_bytes()).hexdigest()
        if self.wrong_build_digest:
            digest = "f" * 64
        document = {
            "appBundlePath": str(self.configuration.app_bundle),
            "buildGeneration": f"{self.generation_index:032x}",
            "configuration": "Release",
            "dependencyContract": {"identitySha256": "4" * 64},
            "executableDevice": executable.stat().st_dev,
            "executableInode": executable.stat().st_ino,
            "executablePath": str(executable),
            "executableSha256": digest,
            "generatedProjectIdentitySha256": "3" * 64,
            "recordedAtUnixNs": 1_700_000_000_000_000_000,
            "repositoryRoot": str(self.configuration.repository),
            "schema": acceptance.BUILD_SCHEMA,
            "source": {
                "dirty": False,
                "head": self.authority.source_commit,
                "headTree": self.authority.source_tree,
                "identitySha256": "2" * 64,
                "repositoryRoot": str(self.configuration.repository),
                "worktreeSha256": "1" * 64,
            },
        }
        self.configuration.receipt_root.mkdir(parents=True, exist_ok=True)
        self.configuration.build_receipt.write_bytes(canonical(document, newline=True))
        self.configuration.build_receipt.chmod(0o600)

    def _write_process(self, receipt: Path) -> acceptance.ProcessRecord:
        root = self.runtime.launch()
        build = json.loads(self.configuration.build_receipt.read_text())
        document = {
            "activationPolicy": 0,
            "buildGeneration": build["buildGeneration"],
            "executablePath": root.executable_path,
            "finishedLaunching": True,
            "firstWindowReady": True,
            "launchedAtUnixNs": 1_700_000_000_000_000_100,
            "pid": root.pid,
            "schema": acceptance.PROCESS_SCHEMA,
            "startMicroseconds": root.start_microseconds,
            "startSeconds": root.start_seconds,
        }
        receipt.write_bytes(canonical(document, newline=True))
        receipt.chmod(0o600)
        return root

    def _proof(self, receipt: Path) -> bytes:
        process = json.loads(receipt.read_text())
        proof = {
            "buildGeneration": process["buildGeneration"],
            "executablePath": process["executablePath"],
            "pid": process["pid"],
            "startMicroseconds": process["startMicroseconds"],
            "startSeconds": process["startSeconds"],
            "windowCount": 1,
        }
        if self.verify_identity_mismatch:
            proof["pid"] += 1
        return canonical(proof, newline=True)

    def _stop(self, receipt: Path) -> None:
        self.runtime.stop()
        if receipt.exists() and not self.leave_process_receipt:
            receipt.unlink()
        if self.leave_recovery:
            self.configuration.recovery_receipt.write_bytes(b"stale")
        if self.leak_fd:
            self.runtime.fd_count += 1
        for child in self.children:
            if child.returncode is None:
                child.returncode = 0
        if not self.runtime.keep_diagnostic_survivor:
            self.runtime.diagnostic_records = []

    def run(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        env: Mapping[str, str],
        input_bytes: bytes | None = None,
        timeout: float,
    ) -> acceptance.CommandResult:
        if str(self.configuration.entrypoint) in argv:
            mode = argv[-1]
            self.calls.append(("entrypoint", mode))
            if mode == "debug":
                if self.debug_returncode == 0:
                    self._write_build()
                output = (
                    f'Current executable set to "{self.configuration.executable}"\n'.encode()
                    if self.debug_mentions_executable
                    else b"lldb target unavailable\n"
                )
                return acceptance.CommandResult(self.debug_returncode, output, b"")
            if mode == "run":
                self._write_build()
                self._write_process(self.configuration.entrypoint_process_receipt)
                return acceptance.CommandResult(0, b"MacScope ready: pid=fixture\n", b"")
            if mode == "verify":
                return acceptance.CommandResult(
                    0, self._proof(self.configuration.entrypoint_process_receipt), b""
                )
            if mode == "stop":
                self._stop(self.configuration.entrypoint_process_receipt)
                return acceptance.CommandResult(0, b"MacScope stopped\n", b"")
            raise AssertionError(f"unexpected synchronous entrypoint mode {mode}")

        helper_index = list(argv).index(str(self.configuration.helper))
        mode = argv[helper_index + 1]
        self.calls.append(("helper", mode))
        if mode == "verify-build":
            return acceptance.CommandResult(
                0, f"{self.configuration.executable}\n".encode(), b""
            )
        receipt = self._option(argv, "--process-receipt")
        if mode == "launch":
            self._write_process(receipt)
            return acceptance.CommandResult(0, b"MacScope ready: pid=fixture\n", b"")
        if mode == "verify":
            return acceptance.CommandResult(0, self._proof(receipt), b"")
        if mode == "stop":
            self._stop(receipt)
            return acceptance.CommandResult(0, b"MacScope stopped\n", b"")
        raise AssertionError(f"unexpected helper mode {mode}")

    def spawn(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        env: Mapping[str, str],
    ) -> FakeChild:
        mode = argv[-1]
        self.calls.append(("entrypoint", mode))
        child = FakeChild(9000 + len(self.children))
        self.children.append(child)
        self.runtime.diagnostic_records.extend(
            (
                acceptance.ProcessRecord(
                    pid=child.pid,
                    ppid=os.getpid(),
                    start_seconds=1_700_000_500 + len(self.children),
                    start_microseconds=1,
                    executable_path="/usr/bin/python3",
                    open_file_count=6,
                ),
                acceptance.ProcessRecord(
                    pid=child.pid + 100,
                    ppid=child.pid,
                    start_seconds=1_700_000_500 + len(self.children),
                    start_microseconds=2,
                    executable_path="/usr/bin/log",
                    open_file_count=5,
                ),
            )
        )
        return child


class RunloopAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        repository = self.root / "repository"
        (repository / "script").mkdir(parents=True)
        (repository / "Scripts").mkdir()
        entrypoint = repository / "script/build_and_run.sh"
        helper = repository / "Scripts/runloop_exact_app.py"
        entrypoint.write_text("#!/bin/bash\n", encoding="utf-8")
        helper.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        entrypoint.chmod(0o755)
        helper.chmod(0o755)

        authority_root = self.root / "authority"
        authority_root.mkdir()
        candidate_path = authority_root / "candidate.json"
        qualification_path = authority_root / "QUALIFICATION_INPUTS.json"
        final_path = authority_root / "FinalLocalCandidate.receipt.json"
        candidate_path.write_bytes(b"{}")
        qualification_path.write_bytes(b"{}\n")
        final_path.write_bytes(b"{}")
        for path in (candidate_path, qualification_path, final_path):
            path.chmod(0o600)

        executable_digest = hashlib.sha256(b"exact-final-executable").hexdigest()
        self.configuration = acceptance.Configuration(
            repository=repository,
            entrypoint=entrypoint,
            helper=helper,
            candidate_identity=candidate_path,
            qualification_receipt=qualification_path,
            final_receipt=final_path,
            derived_data=self.root / "runtime-derived-data",
            configuration="Release",
            output=self.root / "evidence/runloop-acceptance.json",
            command_timeout_seconds=30,
            diagnostic_start_seconds=0.01,
            diagnostic_exit_timeout_seconds=2,
        )
        self.configuration.output.parent.mkdir()
        self.authority = acceptance.CandidateAuthority(
            candidate_file=acceptance._stable_file(
                candidate_path, label="candidate", maximum_bytes=1024
            ),
            qualification_file=acceptance._stable_file(
                qualification_path, label="qualification", maximum_bytes=1024
            ),
            final_file=acceptance._stable_file(final_path, label="final", maximum_bytes=1024),
            identity_semantic_sha256="a" * 64,
            repository_label="next5-local:MacScope",
            branch_label="feature/next5-integration",
            source_commit="b" * 40,
            source_tree="c" * 40,
            integration_ref="refs/remotes/next5-local/feature/next5-integration",
            application_executable_sha256=executable_digest,
            qualification_source_identity_sha256="d" * 64,
            final_source_app_path=str(
                authority_root / "qualification/DerivedData/Build/Products/Release/MacScope.app"
            ),
            installed_app_path="/Applications/MacScope.app",
        )
        self.runtime = FakeRuntime(self.configuration)
        self.commands = FakeCommands(self.configuration, self.authority, self.runtime)

    def run_acceptance(self) -> dict[str, object]:
        return acceptance.run_acceptance(
            self.configuration,
            self.authority,
            commands=self.commands,
            runtime=self.runtime,
        )

    def test_success_proves_all_entrypoints_and_ten_distinct_identities(self) -> None:
        document = self.run_acceptance()

        self.assertEqual(
            set(document),
            {
                "authority",
                "baseline",
                "cycles",
                "entrypoints",
                "produced_at_unix_ns",
                "receipt_kind",
                "result",
                "schema_version",
                "terminal",
            },
        )
        self.assertEqual(set(document["entrypoints"]), acceptance.ENTRYPOINT_KEYS)
        self.assertEqual(len(document["cycles"]), 10)
        identities = {
            (
                row["process_identity"]["pid"],
                row["process_identity"]["start_seconds"],
                row["process_identity"]["start_microseconds"],
                row["process_identity"]["executable_path"],
            )
            for row in document["cycles"]
        }
        self.assertEqual(len(identities), 10)
        self.assertEqual(document["cycles"][0]["launch_route"], "entrypoint-run")
        self.assertTrue(
            all(
                row["launch_route"] == "runloop-helper-launch"
                for row in document["cycles"][1:]
            )
        )
        self.assertEqual(
            document["authority"]["application"]["executable_sha256"],
            self.authority.application_executable_sha256,
        )
        self.assertEqual(self.commands.calls.count(("entrypoint", "run")), 1)
        self.assertEqual(self.commands.calls.count(("helper", "launch")), 9)
        self.assertEqual(self.commands.calls.count(("helper", "verify")), 9)
        self.assertEqual(self.commands.calls.count(("helper", "stop")), 9)
        self.assertTrue(self.configuration.output.is_file())
        self.assertEqual(self.configuration.output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(
            self.configuration.output.read_bytes(), canonical(document, newline=False)
        )

    def test_pure_generated_receipt_validator_rejects_shape_and_sufficiency_drift(self) -> None:
        document = self.run_acceptance()
        acceptance._validate_generated_receipt(document)
        mutations = []

        missing_authority_field = deepcopy(document)
        del missing_authority_field["authority"]["build"]["receipt_sha256"]
        mutations.append(("authority", missing_authority_field))

        nine_cycles = deepcopy(document)
        nine_cycles["cycles"].pop()
        mutations.append(("ten cycles", nine_cycles))

        duplicate_identity = deepcopy(document)
        duplicate_identity["cycles"][1]["process_identity"] = deepcopy(
            duplicate_identity["cycles"][0]["process_identity"]
        )
        mutations.append(("distinct", duplicate_identity))

        missing_entrypoint = deepcopy(document)
        del missing_entrypoint["entrypoints"]["telemetry"]
        mutations.append(("entrypoints", missing_entrypoint))

        terminal_residue = deepcopy(document)
        terminal_residue["terminal"]["app_bundle_processes"] = [
            deepcopy(terminal_residue["cycles"][0]["process_identity"])
        ]
        mutations.append(("residue", terminal_residue))

        terminal_fd_drift = deepcopy(document)
        terminal_fd_drift["terminal"]["coordinator_fd_count"] += 1
        mutations.append(("descriptor", terminal_fd_drift))

        for label, changed in mutations:
            with self.subTest(label=label):
                with self.assertRaises(acceptance.AcceptanceError):
                    acceptance._validate_generated_receipt(changed)

    def test_build_candidate_digest_mismatch_fails_closed(self) -> None:
        self.commands.wrong_build_digest = True
        with self.assertRaisesRegex(acceptance.AcceptanceError, "final candidate authority"):
            self.run_acceptance()
        self.assertFalse(self.configuration.output.exists())

    def test_verify_and_process_receipt_identity_mismatch_fails_closed(self) -> None:
        self.commands.verify_identity_mismatch = True
        with self.assertRaisesRegex(acceptance.AcceptanceError, "verify and process receipt differ"):
            self.run_acceptance()
        self.assertFalse(self.configuration.output.exists())
        self.assertFalse(self.configuration.entrypoint_process_receipt.exists())

    def test_stale_process_receipt_refuses_before_any_command(self) -> None:
        self.configuration.receipt_root.mkdir(parents=True)
        self.configuration.entrypoint_process_receipt.write_bytes(b"stale")
        with self.assertRaisesRegex(acceptance.AcceptanceError, "initial attempt 1"):
            self.run_acceptance()
        self.assertEqual(self.commands.calls, [])

    def test_repeated_process_identity_is_rejected(self) -> None:
        self.runtime.repeat_identity = True
        with self.assertRaisesRegex(acceptance.AcceptanceError, "ten distinct"):
            self.run_acceptance()
        self.assertFalse(self.configuration.output.exists())

    def test_surviving_exact_process_is_rejected(self) -> None:
        self.runtime.keep_survivor = True
        with self.assertRaisesRegex(acceptance.AcceptanceError, "survived stop"):
            self.run_acceptance()
        self.assertFalse(self.configuration.output.exists())

    def test_surviving_diagnostic_log_child_is_rejected(self) -> None:
        self.runtime.keep_diagnostic_survivor = True
        with self.assertRaisesRegex(acceptance.AcceptanceError, "survived stop"):
            self.run_acceptance()
        self.assertFalse(self.configuration.output.exists())

    def test_descriptor_leak_is_rejected(self) -> None:
        self.commands.leak_fd = True
        with self.assertRaisesRegex(acceptance.AcceptanceError, "leaked coordinator descriptors"):
            self.run_acceptance()
        self.assertFalse(self.configuration.output.exists())

    def test_recovery_or_process_receipt_residue_is_rejected(self) -> None:
        self.commands.leave_recovery = True
        with self.assertRaisesRegex(acceptance.AcceptanceError, "recovery receipt"):
            self.run_acceptance()

        self.setUp()
        self.commands.leave_process_receipt = True
        with self.assertRaisesRegex(acceptance.AcceptanceError, "process receipt"):
            self.run_acceptance()

    def test_lldb_failure_and_wrong_target_are_rejected(self) -> None:
        self.commands.debug_returncode = 1
        with self.assertRaisesRegex(acceptance.AcceptanceError, "debug entrypoint exited"):
            self.run_acceptance()

        self.setUp()
        self.commands.debug_mentions_executable = False
        with self.assertRaisesRegex(acceptance.AcceptanceError, "LLDB did not report"):
            self.run_acceptance()

    def test_output_is_create_only(self) -> None:
        self.configuration.output.write_bytes(b"existing")
        with self.assertRaisesRegex(acceptance.AcceptanceError, "create-only"):
            self.run_acceptance()
        self.assertEqual(self.configuration.output.read_bytes(), b"existing")

    def test_authority_mutation_is_detected_before_publication(self) -> None:
        original_stop = self.commands._stop
        counter = 0

        def mutating_stop(receipt: Path) -> None:
            nonlocal counter
            counter += 1
            original_stop(receipt)
            if counter == 5:
                self.authority.final_file.path.write_bytes(b'{"changed":true}')
                self.authority.final_file.path.chmod(0o600)

        self.commands._stop = mutating_stop  # type: ignore[method-assign]
        with self.assertRaisesRegex(acceptance.AcceptanceError, "changed after admission"):
            self.run_acceptance()

    def test_candidate_qualification_and_final_authorities_are_cross_bound(self) -> None:
        from Scripts.reconstruction_gate_f.schema import (
            candidate_identity_sha256,
            parse_candidate_identity,
        )
        from Scripts.reconstruction_gate_f.tests import candidate_mapping

        candidate_document = candidate_mapping()
        parsed, issues = parse_candidate_identity(candidate_document)
        self.assertIsNotNone(parsed)
        self.assertEqual(issues, ())
        assert parsed is not None
        self.configuration.candidate_identity.write_bytes(canonical(candidate_document))
        self.configuration.candidate_identity.chmod(0o600)
        qualification_document = {
            "dependency_network_allowed": False,
            "dependency_network_used": False,
            "mode": "full-test",
            "schema_version": 4,
            "source_identity": {
                "canonical_integration_commit": parsed.source.commit,
                "canonical_integration_ref": "refs/remotes/next5-local/feature/next5-integration",
                "git_head_commit": parsed.source.commit,
                "git_head_tree": parsed.source.tree,
            },
        }
        self.configuration.qualification_receipt.write_bytes(
            canonical(qualification_document, newline=True)
        )
        self.configuration.qualification_receipt.chmod(0o600)

        def write_final(executable_sha256: str) -> None:
            candidate_file_sha = hashlib.sha256(
                self.configuration.candidate_identity.read_bytes()
            ).hexdigest()
            qualification_file_sha = hashlib.sha256(
                self.configuration.qualification_receipt.read_bytes()
            ).hexdigest()
            final_document = {
                "acceptance_gates": [],
                "candidate": {
                    "application_executable_sha256": executable_sha256,
                    "identity_file_sha256": candidate_file_sha,
                    "identity_path": str(self.configuration.candidate_identity),
                    "identity_sha256": candidate_identity_sha256(parsed),
                    "source_app_path": str(
                        self.root
                        / "qualification/DerivedData/Build/Products/Release/MacScope.app"
                    ),
                },
                "installation": {"installed_app_path": "/Applications/MacScope.app"},
                "integration": {
                    "commit": parsed.source.commit,
                    "ref": "refs/remotes/next5-local/feature/next5-integration",
                    "tree": parsed.source.tree,
                },
                "produced_at_unix_ns": 1_700_000_000_000_000_000,
                "qualification": {
                    "receipt_path": str(self.configuration.qualification_receipt),
                    "receipt_sha256": qualification_file_sha,
                },
                "receipt_kind": "macscope-final-local-candidate",
                "result": "passed",
                "schema_version": 1,
                "scope": {},
                "transaction_result": {},
            }
            self.configuration.final_receipt.write_bytes(canonical(final_document))
            self.configuration.final_receipt.chmod(0o600)

        write_final(parsed.application.executable_sha256)
        loaded = acceptance.load_candidate_authority(self.configuration)
        self.assertEqual(loaded.source_commit, parsed.source.commit)
        self.assertEqual(
            loaded.application_executable_sha256,
            parsed.application.executable_sha256,
        )

        write_final("f" * 64)
        with self.assertRaisesRegex(acceptance.AcceptanceError, "differs from candidate"):
            acceptance.load_candidate_authority(self.configuration)

        write_final(parsed.application.executable_sha256)
        qualification_document["source_identity"]["canonical_integration_commit"] = "9" * 40
        self.configuration.qualification_receipt.write_bytes(
            canonical(qualification_document, newline=True)
        )
        self.configuration.qualification_receipt.chmod(0o600)
        with self.assertRaisesRegex(acceptance.AcceptanceError, "source identities differ"):
            acceptance.load_candidate_authority(self.configuration)

    def test_source_has_no_name_wide_or_discovery_derived_signaling(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        for forbidden in ("pkill", "killall", "pgrep", "os.kill(", "process name"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, source)
        self.assertIn('_helper_argv(configuration, "stop"', source)
        self.assertIn("child.terminate()", source)

    def test_output_parent_rename_and_symlink_cannot_redirect_or_orphan_receipt(self) -> None:
        output_parent = self.root / "publish-parent"
        moved_parent = self.root / "publish-parent-moved"
        attacker_parent = self.root / "attacker-parent"
        output_parent.mkdir()
        attacker_parent.mkdir()
        output = output_parent / "receipt.json"
        original_link = os.link

        def swap_after_link(
            source: str,
            destination: str,
            *,
            src_dir_fd: int | None = None,
            dst_dir_fd: int | None = None,
            follow_symlinks: bool = True,
        ) -> None:
            original_link(
                source,
                destination,
                src_dir_fd=src_dir_fd,
                dst_dir_fd=dst_dir_fd,
                follow_symlinks=follow_symlinks,
            )
            output_parent.rename(moved_parent)
            output_parent.symlink_to(attacker_parent, target_is_directory=True)

        with mock.patch.object(acceptance.os, "link", side_effect=swap_after_link):
            with self.assertRaisesRegex(acceptance.AcceptanceError, "output parent changed"):
                acceptance._publish_create_only(output, {"result": "passed"})

        self.assertFalse((moved_parent / output.name).exists())
        self.assertFalse((attacker_parent / output.name).exists())
        self.assertEqual(list(moved_parent.iterdir()), [])

    def test_authority_inode_swap_during_link_withdraws_exact_output(self) -> None:
        output = self.root / "evidence/inode-fenced-output.json"
        final_path = self.authority.final_file.path
        original_link = os.link

        def swap_authority_after_link(
            source: str,
            destination: str,
            *,
            src_dir_fd: int | None = None,
            dst_dir_fd: int | None = None,
            follow_symlinks: bool = True,
        ) -> None:
            original_link(
                source,
                destination,
                src_dir_fd=src_dir_fd,
                dst_dir_fd=dst_dir_fd,
                follow_symlinks=follow_symlinks,
            )
            replacement = final_path.with_name("replacement-final.json")
            replacement.write_bytes(final_path.read_bytes())
            replacement.chmod(0o600)
            os.replace(replacement, final_path)

        with acceptance.StableFileFences(
            ((self.authority.final_file, "final local candidate receipt"),)
        ) as fences:
            with mock.patch.object(
                acceptance.os, "link", side_effect=swap_authority_after_link
            ):
                with self.assertRaisesRegex(
                    acceptance.AcceptanceError, "no longer names its admitted inode"
                ):
                    acceptance._publish_create_only(
                        output,
                        {"result": "passed"},
                        post_link_fence=fences.verify,
                    )

        self.assertFalse(output.exists())
        self.assertEqual(list(output.parent.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
