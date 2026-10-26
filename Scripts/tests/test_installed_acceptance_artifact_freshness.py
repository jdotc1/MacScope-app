from __future__ import annotations

import contextlib
import hashlib
import io
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

from Scripts import ws24_emit_installed_qualification_report as ws24
from Scripts.reconstruction import compile_installed_acceptance_gate_plan as compiler
from Scripts.reconstruction import run_installed_acceptance_transaction as transaction
from Scripts.reconstruction import validate_final_local_candidate as final_validator
from Scripts.reconstruction_gate_f.canonical_json import (
    canonical_bytes,
    decode_canonical_bytes,
)
from Scripts.tests.test_compile_installed_acceptance_gate_plan import CompilerFixture
from Scripts.tests import test_run_installed_acceptance_transaction as driver_tests
from Scripts.tests.test_validate_final_local_candidate import TransactionFixture
from Scripts.tests.test_ws24_emit_installed_qualification_report import (
    BridgeFixture,
    SOURCE_COMMIT,
    SOURCE_TREE,
)


def _replace_with_same_bytes(path: Path) -> None:
    replacement = path.with_name(f".{path.name}.replacement")
    replacement.write_bytes(path.read_bytes())
    replacement.chmod(stat.S_IMODE(path.lstat().st_mode))
    os.replace(replacement, path)


class InstalledAcceptanceArtifactFreshnessTests(unittest.TestCase):
    def assert_private_canonical_artifact(
        self,
        path: Path,
        *,
        maximum_bytes: int,
        exposed_at: int,
    ) -> bytes:
        metadata = path.lstat()
        payload = path.read_bytes()
        self.assertTrue(stat.S_ISREG(metadata.st_mode))
        self.assertFalse(stat.S_ISLNK(metadata.st_mode))
        self.assertEqual(path.resolve(strict=True), path)
        self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)
        self.assertEqual(metadata.st_nlink, 1)
        self.assertGreater(len(payload), 0)
        self.assertLessEqual(len(payload), maximum_bytes)
        self.assertGreaterEqual(metadata.st_mtime_ns, exposed_at)
        self.assertEqual(canonical_bytes(decode_canonical_bytes(payload)), payload)
        return payload

    def test_compiler_plan_is_fresh_reopenable_create_only_and_inode_bound(self) -> None:
        with CompilerFixture() as fixture:
            arguments = compiler.parse_arguments(fixture.arguments())
            output = compiler.compile_and_publish(arguments)
            self.assertEqual(output, fixture.output)
            payload = self.assert_private_canonical_artifact(
                output,
                maximum_bytes=compiler.MAXIMUM_PLAN_BYTES,
                exposed_at=fixture.bridge.state["exposed_at_unix_ns"],
            )
            document, digest = compiler.load_plan(output)
            self.assertEqual(canonical_bytes(document), payload)
            self.assertEqual(digest, hashlib.sha256(payload).hexdigest())

            with self.assertRaisesRegex(
                compiler.PlanCompilationError, "create-only|must be absent"
            ):
                compiler.compile_and_publish(arguments)

            snapshot = compiler._stable_file(
                output,
                maximum_bytes=compiler.MAXIMUM_PLAN_BYTES,
                label="compiled plan",
            )
            _replace_with_same_bytes(output)
            with self.assertRaisesRegex(
                compiler.PlanCompilationError, "changed during plan compilation"
            ):
                compiler._require_unchanged(
                    snapshot,
                    maximum_bytes=compiler.MAXIMUM_PLAN_BYTES,
                    label="compiled plan",
                )

    def test_ws24_publishes_fresh_aggregate_before_eight_distinct_envelopes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="macscope-ws24-freshness.") as root:
            fixture = BridgeFixture(Path(root))
            installed_digest = fixture.sha256(
                fixture.installed_app / "Contents/MacOS/MacScope"
            )
            evidence = [
                {
                    **ws24.evidence(
                        gate,
                        "passed",
                        SOURCE_COMMIT,
                        installed_digest,
                        accepted_attempts=ws24.MINIMUM_ACCEPTED_ATTEMPTS.get(gate, 1),
                    ),
                    "installedExecutableSHA256": installed_digest,
                }
                for gate in sorted(ws24.SUPPLIED_LIVE_GATES)
            ]
            stdout = io.StringIO()
            stderr = io.StringIO()
            with (
                mock.patch.object(
                    ws24, "normalize_input_evidence", return_value=evidence
                ),
                mock.patch.object(ws24, "run_signing_guard", return_value=True),
                mock.patch.object(
                    ws24, "git_tree_for_commit", return_value=SOURCE_TREE
                ),
                mock.patch.object(ws24.platform, "machine", return_value="arm64"),
                mock.patch.object(
                    ws24.platform,
                    "mac_ver",
                    return_value=("27.0", ("", "", ""), ""),
                ),
                mock.patch.object(
                    ws24, "developer_directory_uses_xcode27", return_value=True
                ),
                contextlib.redirect_stdout(stdout),
                contextlib.redirect_stderr(stderr),
            ):
                status = ws24.main(fixture.arguments())
            self.assertEqual(status, 0, stderr.getvalue())
            self.assertEqual(
                stdout.getvalue().splitlines(),
                [
                    f"{gate_id}={fixture.gate_outputs[gate_id]}"
                    for gate_id in ws24.REQUIRED_ACCEPTANCE_GATES
                ],
            )

            aggregate_payload = self.assert_private_canonical_artifact(
                fixture.output,
                maximum_bytes=ws24.MAXIMUM_INSTALLED_QUALIFICATION_OUTPUT_BYTES,
                exposed_at=fixture.state["exposed_at_unix_ns"],
            )
            aggregate_mtime = fixture.output.lstat().st_mtime_ns
            aggregate_digest = hashlib.sha256(aggregate_payload).hexdigest()
            physical_files = {
                (fixture.output.lstat().st_dev, fixture.output.lstat().st_ino)
            }
            for gate_id in ws24.REQUIRED_ACCEPTANCE_GATES:
                path = fixture.gate_outputs[gate_id]
                envelope_payload = self.assert_private_canonical_artifact(
                    path,
                    maximum_bytes=ws24.MAXIMUM_ACCEPTANCE_GATE_OUTPUT_BYTES,
                    exposed_at=fixture.state["exposed_at_unix_ns"],
                )
                metadata = path.lstat()
                self.assertGreaterEqual(metadata.st_mtime_ns, aggregate_mtime)
                physical = (metadata.st_dev, metadata.st_ino)
                self.assertNotIn(physical, physical_files)
                physical_files.add(physical)
                envelope = decode_canonical_bytes(envelope_payload)
                if gate_id in {"signing", "shellbroker-launchagent"}:
                    self.assertEqual(envelope["evidence_sha256"], aggregate_digest)

            with self.assertRaisesRegex(ws24.ReportError, "must be absent"):
                ws24.write_report(
                    decode_canonical_bytes(aggregate_payload), fixture.output
                )

            stale = Path(root) / "stale-evidence.json"
            stale.write_bytes(canonical_bytes({"result": "passed"}))
            stale.chmod(0o600)
            stale_ns = fixture.state["exposed_at_unix_ns"] - 1
            os.utime(stale, ns=(stale_ns, stale_ns))
            with self.assertRaisesRegex(
                ws24.ReportError, "predates candidate exposure"
            ):
                ws24._fresh_evidence_time(
                    stale,
                    digest=hashlib.sha256(stale.read_bytes()).hexdigest(),
                    exposed_at=fixture.state["exposed_at_unix_ns"],
                )

    def test_driver_result_appears_only_after_committed_state_validation(self) -> None:
        fixture_case = driver_tests.InstalledAcceptanceTransactionTests(
            methodName="test_happy_transaction_orders_begin_compiler_report_commit"
        )
        fixture_case.setUp()
        try:
            result_path = fixture_case.request.result_output.path
            committed_state_validated = False
            actual_publish_result = transaction._publish_result

            def validate_terminal(*_args: object, **_kwargs: object) -> object:
                nonlocal committed_state_validated
                self.assertFalse(result_path.exists())
                committed_state_validated = True
                return fixture_case.terminal

            def publish_result(*args: object, **kwargs: object) -> object:
                self.assertTrue(committed_state_validated)
                self.assertFalse(result_path.exists())
                return actual_publish_result(*args, **kwargs)

            runner = driver_tests.ScriptedRunner(
                fixture_case.request, fixture_case.pending
            )
            with (
                fixture_case._transaction_mocks() as patches,
                mock.patch.object(
                    transaction,
                    "_validate_task10_publication",
                    return_value=fixture_case.task10,
                ),
            ):
                patches["_validate_terminal_commit"].side_effect = validate_terminal
                patches["_publish_result"].side_effect = publish_result
                outcome = transaction.execute_transaction(
                    fixture_case.request,
                    runner=runner,
                    clock_ns=lambda: 10,
                )

            self.assertTrue(committed_state_validated)
            self.assertEqual(outcome.result_output, result_path)
            payload = self.assert_private_canonical_artifact(
                result_path,
                maximum_bytes=transaction.MAX_RESULT_BYTES,
                exposed_at=fixture_case.pending.state["exposed_at_unix_ns"],
            )
            self.assertEqual(canonical_bytes(outcome.document), payload)
            reopened = transaction._read_stable_file(
                result_path,
                label="transaction result",
                maximum_bytes=transaction.MAX_RESULT_BYTES,
            )
            self.assertEqual(reopened.payload, payload)
            self.assertGreaterEqual(
                reopened.metadata[5], fixture_case.terminal.commit_authority.metadata[5]
            )

            _replace_with_same_bytes(result_path)
            with self.assertRaisesRegex(transaction.TransactionError, "changed"):
                transaction._assert_snapshot_unchanged(
                    reopened, label="transaction result"
                )
        finally:
            fixture_case.tearDown()

    def test_final_validator_rejects_stale_and_same_byte_inode_swaps(self) -> None:
        stale_fixture = TransactionFixture()
        try:
            with mock.patch.object(final_validator, "_validate_frozen_plan_contract"):
                authority = stale_fixture.validate_result()
                self.assertEqual(
                    canonical_bytes(authority.document), authority.result_file.payload
                )
                self.assertGreaterEqual(
                    authority.result_file.mtime_ns,
                    authority.commit_authority.mtime_ns,
                )

                stale_output = stale_fixture.primary_outputs["cli"]
                stale_ns = stale_fixture.plan_path.lstat().st_mtime_ns - 1
                os.utime(stale_output, ns=(stale_ns, stale_ns))
                with self.assertRaisesRegex(
                    final_validator.FinalLocalCandidateError,
                    "predates its compiled plan",
                ):
                    stale_fixture.validate_result()
        finally:
            stale_fixture.cleanup()

        swap_fixture = TransactionFixture()
        try:
            with mock.patch.object(final_validator, "_validate_frozen_plan_contract"):
                closure = swap_fixture.closure()
            swapped = swap_fixture.gate_envelopes["cli"]
            _replace_with_same_bytes(swapped)
            with (
                mock.patch.object(
                    final_validator,
                    "_resolve_local_ref",
                    return_value=closure.local_ref,
                ),
                self.assertRaisesRegex(
                    final_validator.FinalLocalCandidateError, "changed"
                ),
            ):
                final_validator._revalidate_closure(closure)
        finally:
            swap_fixture.cleanup()


if __name__ == "__main__":
    unittest.main()
