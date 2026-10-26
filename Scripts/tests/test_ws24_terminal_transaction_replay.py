"""Portable physical transaction replay; never claims native qualification."""

from __future__ import annotations

import contextlib
import hashlib
import io
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes, decode_canonical_bytes
from Scripts.tests.test_ws24_emit_installed_qualification_report import (
    BridgeFixture,
    PREDECESSOR_SHA256,
    RUN_ID,
    RUN_NONCE,
    SOURCE_COMMIT,
    SOURCE_TREE,
    ws24_report,
)


class TerminalTransactionReplayTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.fixture = BridgeFixture(Path(self.temporary.name))
        self.retained = installer._stable_file(
            self.fixture.pending_state,
            maximum_bytes=installer.MAX_PENDING_TRANSACTION_BYTES,
        )

    def load(self, **changes):
        arguments = {
            "pending_state": self.fixture.pending_state,
            "installed_app": self.fixture.installed_app,
            "source_app": self.fixture.source_app,
            "candidate_identity": self.fixture.candidate_identity,
            "expected_source_commit": SOURCE_COMMIT,
            "qualification_run_id": RUN_ID,
            "qualification_run_nonce": RUN_NONCE,
            "retained_pending_state": self.retained,
        }
        arguments.update(changes)
        return ws24_report._load_pending_transaction(**arguments)

    def commit(self) -> Path:
        fixture = self.fixture
        for gate, output in fixture.gate_outputs.items():
            # Real installer gate-input grammar, confined to this portable fixture.
            # These synthetic gate observations are not app/GUI acceptance.
            document = ws24_report.acceptance_gate_document(
                gate_id=gate,
                state=fixture.state,
                evidence_sha256=hashlib.sha256(("portable:" + gate).encode()).hexdigest(),
                started_at_unix_ns=3_000_000_000,
                ended_at_unix_ns=3_500_000_000,
            )
            output.write_bytes(canonical_bytes(document))
            output.chmod(0o600)
        argv = [
            "--phase", "commit", "--transaction-token", fixture.candidate_digest,
            "--candidate-identity", str(fixture.candidate_identity),
            "--source-app", str(fixture.source_app),
            "--installed-app", str(fixture.installed_app),
            "--artifact-root", str(fixture.artifact_root),
            "--qualification-run-id", RUN_ID,
            "--qualification-run-nonce", RUN_NONCE,
            "--predecessor-observations-sha256", PREDECESSOR_SHA256,
        ]
        for gate, output in fixture.gate_outputs.items():
            argv.extend(("--acceptance-gate-input", f"{gate}={output}"))
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = installer.main(
                argv,
                _allow_test_destination=True,
                _atomic_rename=fixture._atomic_rename,
                _clock_ns=lambda: 4_000_000_000,
            )
        self.assertEqual(result, 0, stderr.getvalue())
        self.assertIn("MACSCOPE_INSTALL_RELEASE_PHASE=committed", stdout.getvalue())
        self.assertFalse(fixture.pending_state.parent.exists())
        return installer._committed_root(
            fixture.installed_app, fixture.candidate_digest, fixture.state["transaction_id"]
        )

    def test_retained_begin_replays_actual_committed_file_without_rebinding(self) -> None:
        committed = self.commit()
        try:
            state, observed = self.load()
        except TypeError as error:
            self.fail(f"loader does not support explicit retained BEGIN replay: {error}")
        self.assertEqual(state, self.fixture.state)
        self.assertEqual(observed.path, committed / "transaction.json")
        self.assertEqual(observed.payload, self.retained.payload)
        self.assertEqual(observed.metadata, self.retained.metadata)

    def test_installed_byte_mutation_during_terminal_validation_is_rejected(self) -> None:
        self.commit()
        original = installer._require_source_unchanged
        executable = self.fixture.installed_app / "Contents/MacOS/MacScope"

        def change_installed_after_source_validation(*args, **kwargs):
            original(*args, **kwargs)
            executable.write_bytes(executable.read_bytes() + b"mutation")

        with mock.patch.object(installer, "_require_source_unchanged", side_effect=change_installed_after_source_validation):
            with self.assertRaises(ws24_report.ReportError):
                self.load()

    def test_existing_pending_producer_default_stays_available(self) -> None:
        state, observed = self.load(retained_pending_state=None)
        self.assertEqual(state, self.fixture.state)
        self.assertEqual(observed, self.retained)

    def test_explicit_retained_begin_also_replays_before_commit(self) -> None:
        state, observed = self.load()
        self.assertEqual(state, self.fixture.state)
        self.assertEqual(observed, self.retained)

    def test_committed_replay_requires_explicit_retained_begin(self) -> None:
        self.commit()
        with self.assertRaises(ws24_report.ReportError):
            self.load(retained_pending_state=None)

    def test_same_bytes_copied_to_new_transaction_inode_are_rejected(self) -> None:
        committed = self.commit()
        path = committed / "transaction.json"
        original = committed / "original-transaction.json"
        path.rename(original)
        shutil.copy2(original, path)
        self.assertEqual(path.read_bytes(), self.retained.payload)
        self.assertNotEqual(path.stat().st_ino, self.retained.metadata[1])
        with self.assertRaises(ws24_report.ReportError):
            self.load()

    def test_marker_acceptance_hash_must_equal_actual_validated_receipt(self) -> None:
        committed = self.commit()
        marker = committed / installer.COMMIT_AUTHORITY_NAME
        value = decode_canonical_bytes(marker.read_bytes())
        value["acceptance_receipt_sha256"] = "e" * 64
        marker.write_bytes(canonical_bytes(value))
        with self.assertRaisesRegex(ws24_report.ReportError, "physical acceptance receipt"):
            self.load()

    def test_resealed_acceptance_time_cannot_bypass_committed_marker_hash(self) -> None:
        self.commit()
        receipt = self.fixture.artifact_root / installer.ACCEPTANCE_RECEIPT_NAME
        value = decode_canonical_bytes(receipt.read_bytes())
        value["produced_at_unix_ns"] += 1
        receipt.write_bytes(canonical_bytes(value))
        with self.assertRaisesRegex(ws24_report.ReportError, "physical acceptance receipt"):
            self.load()

    def test_missing_or_failed_terminal_authority_is_rejected(self) -> None:
        committed = self.commit()
        marker = committed / installer.COMMIT_AUTHORITY_NAME
        original = marker.read_bytes()
        marker.unlink()
        with self.assertRaises(ws24_report.ReportError):
            self.load()
        marker.write_bytes(original)
        marker.chmod(0o600)
        receipt = self.fixture.artifact_root / installer.ACCEPTANCE_RECEIPT_NAME
        value = decode_canonical_bytes(receipt.read_bytes())
        value["result"] = "failed"
        receipt.write_bytes(canonical_bytes(value))
        with self.assertRaises(ws24_report.ReportError):
            self.load()

    def test_foreign_source_run_and_nonce_are_rejected(self) -> None:
        self.commit()
        for changes in (
            {"expected_source_commit": "f" * 40},
            {"qualification_run_id": "foreign-run"},
            {"qualification_run_nonce": "f" * 64},
        ):
            with self.subTest(changes=changes), self.assertRaises(ws24_report.ReportError):
                self.load(**changes)

    def test_wrong_and_ambiguous_terminal_roots_are_rejected(self) -> None:
        committed = self.commit()
        wrong = installer._committed_root(
            self.fixture.installed_app, self.fixture.candidate_digest, "f" * 64
        )
        wrong.mkdir(mode=0o700)
        with self.assertRaises(ws24_report.ReportError):
            self.load()
        wrong.rmdir()
        committed.rename(wrong)
        with self.assertRaises(ws24_report.ReportError):
            self.load()

    def test_active_pending_or_committing_root_rejects_terminal_replay(self) -> None:
        self.commit()
        pending = self.fixture.pending_state.parent
        committing = self.fixture.applications / f".MacScope.committing-{self.fixture.candidate_digest}"
        for root in (pending, committing):
            root.mkdir(mode=0o700)
            with self.subTest(root=root.name), self.assertRaises(ws24_report.ReportError):
                self.load()
            root.rmdir()

    def test_rolled_back_transaction_is_not_committed_authority(self) -> None:
        fixture = self.fixture
        argv = [
            "--phase", "rollback", "--transaction-token", fixture.candidate_digest,
            "--candidate-identity", str(fixture.candidate_identity),
            "--source-app", str(fixture.source_app),
            "--installed-app", str(fixture.installed_app),
            "--artifact-root", str(fixture.artifact_root),
            "--qualification-run-id", RUN_ID, "--qualification-run-nonce", RUN_NONCE,
            "--predecessor-observations-sha256", PREDECESSOR_SHA256,
        ]
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = installer.main(argv, _allow_test_destination=True, _atomic_rename=fixture._atomic_rename)
        self.assertEqual(result, 0, stderr.getvalue())
        self.assertIn("MACSCOPE_INSTALL_RELEASE_PHASE=rolled-back", stdout.getvalue())
        with self.assertRaises(ws24_report.ReportError):
            self.load()

    def test_committed_root_symlink_and_state_hardlink_are_rejected(self) -> None:
        committed = self.commit()
        moved = committed.with_name(committed.name + "-moved")
        committed.rename(moved)
        committed.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(ws24_report.ReportError):
            self.load()
        committed.unlink()
        moved.rename(committed)
        os.link(committed / "transaction.json", committed / "hardlink.json")
        with self.assertRaises(ws24_report.ReportError):
            self.load()

    def test_current_installed_and_source_bundle_mutation_are_rejected(self) -> None:
        self.commit()
        for app in (self.fixture.installed_app, self.fixture.source_app):
            executable = app / "Contents/MacOS/MacScope"
            original = executable.read_bytes()
            executable.write_bytes(original + b"mutation")
            with self.subTest(app=app), self.assertRaises(ws24_report.ReportError):
                self.load()
            executable.write_bytes(original)

    def test_final_terminal_marker_mutation_is_rejected(self) -> None:
        committed = self.commit()
        marker = committed / installer.COMMIT_AUTHORITY_NAME
        original = installer._require_source_unchanged

        def change_marker_after_source_validation(*args, **kwargs):
            original(*args, **kwargs)
            marker.write_bytes(marker.read_bytes() + b" ")

        with mock.patch.object(installer, "_require_source_unchanged", side_effect=change_marker_after_source_validation):
            with self.assertRaises(ws24_report.ReportError):
                self.load()

    def test_real_operability_authority_is_identical_after_exact_commit(self) -> None:
        expected = self.fixture.authority()
        self.commit()
        observed = ws24_report.validate_operability_authority(
            installed_app=self.fixture.installed_app,
            source_app=self.fixture.source_app,
            candidate_identity=self.fixture.candidate_identity,
            expected_source_commit=SOURCE_COMMIT,
            qualification_run_id=RUN_ID,
            qualification_run_nonce=RUN_NONCE,
            installation_pending_state=self.fixture.pending_state,
            full_surface_report=self.fixture.full_surface_report,
            legacy_grid_report=self.fixture.legacy_grid_report,
            native_xpc_execution_report=self.fixture.native_xpc_report,
            retained_pending_state=self.retained,
        )
        self.assertEqual(observed, expected)

    def test_aggregate_both_fences_replay_same_report_after_commit(self) -> None:
        arguments = ws24_report.parse_arguments(self.fixture.arguments())
        # Only external OS/Git observations are isolated; evidence normalization,
        # installer validation and aggregate composition stay real. Empty live
        # evidence truthfully leaves this portable aggregate unaccepted.
        with (
            mock.patch.object(ws24_report, "run_signing_guard", return_value=False),
            mock.patch.object(ws24_report, "git_tree_for_commit", return_value=SOURCE_TREE),
            mock.patch.object(ws24_report, "developer_directory_uses_xcode27", return_value=False),
        ):
            expected = ws24_report.build_report(arguments)
            self.assertFalse(expected[0]["accepted"])
            self.commit()
            with self.assertRaises(ws24_report.ReportError):
                ws24_report.build_report(arguments)
            observed = ws24_report.build_report(arguments, retained_pending_state=self.retained)
        self.assertEqual(observed, expected)


if __name__ == "__main__":
    unittest.main()
