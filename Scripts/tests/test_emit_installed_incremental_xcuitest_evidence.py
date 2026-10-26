#!/usr/bin/env python3

from __future__ import annotations

import argparse
import copy
from contextlib import ExitStack, redirect_stderr, redirect_stdout
import hashlib
import io
from pathlib import Path
import stat
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

from Scripts.reconstruction import emit_installed_incremental_xcuitest_evidence as emitter
from Scripts.reconstruction_gate_f.canonical_json import (
    canonical_bytes,
    canonical_sha256,
    decode_canonical_bytes,
)


class InstalledIncrementalXCUITestEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.receipt_path = self.root / emitter.MATRIX_RECEIPT_NAME
        self.receipt_path.write_bytes(canonical_bytes({"fixture": "receipt"}))
        self.receipt_sha256 = hashlib.sha256(self.receipt_path.read_bytes()).hexdigest()
        self.candidate_path = self.root / "candidate.json"
        self.candidate_path.write_bytes(canonical_bytes({"fixture": "candidate"}))
        self.installed_app = self.root / "Applications" / "MacScope.app"
        self.installed_app.mkdir(parents=True)
        self.installed_executable = self.installed_app / "Contents" / "MacOS" / "MacScope"
        self.installed_executable.parent.mkdir(parents=True)
        self.installed_executable.write_bytes(b"installed executable")
        self.xcresult = self.root / emitter.XCRESULT_NAME
        self.xcresult.mkdir()
        (self.xcresult / "Info.plist").write_bytes(b"xcresult fixture")
        self.semantic_path = self.root / emitter.SEMANTIC_MANIFEST_NAME
        self.network_root = self.root / emitter.NETWORK_ROOT_NAME
        self.network_root.mkdir()
        self.observer_tool = self.root / "nettop"
        self.observer_tool.write_bytes(b"governed nettop fixture")
        self.observer_tool_sha256 = hashlib.sha256(
            self.observer_tool.read_bytes()
        ).hexdigest()
        self.qualification_run_id = "installed-task10-run"
        self.qualification_run_nonce = "a" * 64
        self.predecessor_sha256 = "b" * 64
        self.identity_sha256 = "c" * 64
        self.candidate_document_sha256 = "9" * 64
        self.source_commit = "d" * 40
        self.source_tree = "e" * 40
        self.installed_sha256 = "f" * 64
        self.xcresult_bundle_sha256 = "1" * 64
        self.xcresult_closed_tree_sha256 = "2" * 64
        self.projection = emitter.ws24.installed_selector_projection(
            emitter.ws24.load_installed_selector_catalog()
        )
        self.selectors = [item["test_identifier"] for item in self.projection]
        self.observed_projection = [
            {
                "observed_identifiers": sorted(item["required_identifiers"]),
                "test_identifier": item["test_identifier"],
                "vector_id": item["vector_id"],
            }
            for item in self.projection
        ]
        self.receipt = {
            "candidate": {
                "identity_path": str(self.candidate_path),
                "identity_sha256": self.identity_sha256,
                "source_commit": self.source_commit,
                "source_tree": self.source_tree,
            },
            "execution": {
                "ended_at_unix_ms": 119,
                "result": "passed",
                "selectors": self.selectors,
                "started_at_unix_ms": 111,
            },
            "products": {
                "installed_app": {
                    "path": str(self.installed_app),
                    "executable_sha256": self.installed_sha256,
                },
                "xcresult": {
                    "path": str(self.xcresult),
                    "closed_tree_sha256": self.xcresult_closed_tree_sha256,
                },
            },
        }
        self.semantic = {
            "schema_version": 3,
            "candidate_identity_sha256": self.identity_sha256,
            "source_xcresult": {
                "bundle_sha256": self.xcresult_bundle_sha256,
                "closed_tree_sha256": self.xcresult_closed_tree_sha256,
            },
            "selector_catalog_sha256": canonical_sha256(self.selectors),
            "selector_projection": self.projection,
            "selector_projection_sha256": canonical_sha256(self.projection),
            "observed_selector_projection": self.observed_projection,
            "observed_selector_projection_sha256": canonical_sha256(
                self.observed_projection
            ),
            "expected_selector_count": 22,
            "executed_selector_count": 22,
            "passed_selector_count": 22,
            "failed_selector_count": 0,
            "skipped_selector_count": 0,
            "selectors": [
                {"test_identifier": identifier, "status": "passed"}
                for identifier in self.selectors
            ],
            "result": "passed",
        }
        self._write_canonical(self.semantic_path, self.semantic)
        self.semantic_sha256 = hashlib.sha256(self.semantic_path.read_bytes()).hexdigest()
        self.observation_path = self.network_root / emitter.network.OBSERVATION_NAME
        self.observation_path.write_bytes(b",bytes_in,bytes_out,\n")
        self.observation_sha256 = hashlib.sha256(
            self.observation_path.read_bytes()
        ).hexdigest()
        self.authorities = (
            SimpleNamespace(
                identity_id="app",
                executable_path=str(self.installed_executable),
                executable_sha256=self.installed_sha256,
            ),
        )
        self.execution_report_path = (
            self.network_root / emitter.network.EXECUTION_REPORT_NAME
        )
        self.execution_report = {
            "ended_at_unix_ms": 130,
            "exit_code": 0,
            "predecessor_observations_sha256": self.predecessor_sha256,
            "qualification_run": {
                "run_id": self.qualification_run_id,
                "nonce": self.qualification_run_nonce,
            },
            "result": "passed",
            "schema_version": 2,
            "started_at_unix_ms": 100,
            "stress": None,
        }
        self._write_canonical(self.execution_report_path, self.execution_report)
        self.network_report_path = self.network_root / emitter.network.REPORT_NAME
        self.network_report = self._network_report()
        self._write_canonical(self.network_report_path, self.network_report)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def _write_canonical(path: Path, value: object) -> None:
        path.write_bytes(canonical_bytes(value))

    def _network_report(self) -> dict[str, object]:
        return {
            "schema_version": 4,
            "attribution": {
                "policy_id": "prearmed-kqueue-path-v1",
                "observer_spawn_ns": 10, "observer_eof_ns": 20,
                "queue_closed_ns": 30, "proofs": [],
                "drains": [{"drain_id": 1, "begin_monotonic_ns": 5,
                            "end_monotonic_ns": 6, "completed_to_empty": True,
                            "events": []}],
            },
            "command_id": "installed.network-acquisition-audit",
            "evidence_layer": "installed-launch-log",
            "candidate": {
                "identity_sha256": self.identity_sha256,
                "document_sha256": self.candidate_document_sha256,
                "source_commit": self.source_commit,
                "source_tree": self.source_tree,
            },
            "workload": {
                "command_id": "installed.task10-workflow",
                "started_at_unix_ms": 110,
                "ended_at_unix_ms": 120,
                "observer_ready_at_unix_ms": 100,
                "observer_readiness_precedes_workload": True,
                "observation_contains_workload": True,
                "matrix_receipt_sha256": self.receipt_sha256,
                "xcresult_bundle_sha256": self.xcresult_bundle_sha256,
                "xcresult_closed_tree_sha256": self.xcresult_closed_tree_sha256,
                "selector_catalog_sha256": canonical_sha256(self.selectors),
                "selector_projection_sha256": canonical_sha256(self.projection),
                "xcresult_semantic_manifest_sha256": self.semantic_sha256,
                "expected_selector_count": 22,
                "executed_selector_count": 22,
                "passed_selector_count": 22,
                "failed_selector_count": 0,
                "skipped_selector_count": 0,
                "matrix_result": "passed",
            },
            "executables": [
                {
                    "identity_id": "app",
                    "executable_path": str(self.installed_executable),
                    "executable_sha256": self.installed_sha256,
                    "processes": [{"pid": 101, "start_time_unix_us": 1_000}],
                }
            ],
            "observer": {
                "observer_id": emitter.network.MATRIX_OBSERVER_ID,
                "evidence_scope": emitter.network.MATRIX_EVIDENCE_SCOPE,
                "limitations": list(emitter.network.MATRIX_LIMITATIONS),
                "tool_path": str(self.observer_tool),
                "tool_sha256": self.observer_tool_sha256,
                "interface_scope": ["external", "undefined"],
                "loopback_excluded": True,
                "observed_sample_count": 1,
                "observed_process_row_count": 0,
                "observed_candidate_row_count": 0,
                "observed_foreign_row_count": 0,
                "observed_unresolved_row_count": 0,
                "observer_invocation_count": 1,
                "continuous_interval_started_at_unix_ms": 100,
                "continuous_interval_ready_at_unix_ms": 100,
                "continuous_interval_ended_at_unix_ms": 130,
                "readiness_frame_sha256": hashlib.sha256(
                    emitter.network.MATRIX_OBSERVER_READY_FRAME
                ).hexdigest(),
                "readiness_proven": True,
                "stopped_by_auditor": True,
                "continuity_proven": True,
                "observation_byte_count": len(self.observation_path.read_bytes()),
                "observation_sha256": self.observation_sha256,
                "availability": "available",
            },
            "artifacts": [],
            "started_at_unix_ms": 100,
            "ended_at_unix_ms": 130,
            "result": "passed",
            "exit_code": 0,
            "diagnostic": None,
        }

    def arguments(self, **overrides: object) -> argparse.Namespace:
        values: dict[str, object] = {
            "matrix_receipt": self.receipt_path,
            "xcresult_semantic_manifest": self.semantic_path,
            "network_artifact_root": self.network_root,
            "qualification_run_id": self.qualification_run_id,
            "qualification_run_nonce": self.qualification_run_nonce,
            "predecessor_observations_sha256": self.predecessor_sha256,
        }
        values.update(overrides)
        return argparse.Namespace(**values)

    def _emit(self, *, load_receipt_side_effect: object | None = None):
        receipt_result = (self.receipt, self.receipt_sha256)
        with ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(
                    emitter.matrix,
                    "load_receipt_with_sha256",
                    side_effect=load_receipt_side_effect,
                    return_value=receipt_result,
                )
            )
            stack.enter_context(
                mock.patch.object(
                    emitter.matrix,
                    "validate_receipt",
                    return_value=self.receipt_sha256,
                )
            )
            stack.enter_context(
                mock.patch.object(
                    emitter.network,
                    "load_candidate",
                    return_value=(object(), self.candidate_document_sha256),
                )
            )
            stack.enter_context(
                mock.patch.object(
                    emitter.network,
                    "NETTOP_PATH",
                    self.observer_tool,
                )
            )
            stack.enter_context(
                mock.patch.object(
                    emitter,
                    "candidate_identity_sha256",
                    return_value=self.identity_sha256,
                )
            )
            stack.enter_context(
                mock.patch.object(
                    emitter.network,
                    "inspect_candidate_executables",
                    return_value=self.authorities,
                )
            )
            stack.enter_context(
                mock.patch.object(
                    emitter.ws24,
                    "result_bundle_sha256",
                    return_value=self.xcresult_bundle_sha256,
                )
            )
            stack.enter_context(
                mock.patch.object(
                    emitter.accessibility,
                    "validate_semantic_manifest",
                    return_value=self.semantic,
                )
            )
            return emitter.emit(self.arguments())

    def test_emits_the_closed_sha_bound_descriptor_at_the_fixed_path(self) -> None:
        output, output_sha256 = self._emit()

        self.assertEqual(output, self.network_root / emitter.OUTPUT_NAME)
        self.assertEqual(output.name, "InstalledTask10.incremental-xcuitest.evidence.json")
        self.assertEqual(self.receipt_path.name, "InstalledTask10.matrix-receipt.json")
        self.assertEqual(
            self.semantic_path.name, "InstalledTask10.xcresult-semantic.json"
        )
        self.assertEqual(self.xcresult.name, "InstalledTask10.xcresult")
        self.assertEqual(self.network_root.name, "installed-task10-network")
        payload = output.read_bytes()
        self.assertEqual(hashlib.sha256(payload).hexdigest(), output_sha256)
        self.assertLessEqual(len(payload), 64 * 1024)
        self.assertFalse(payload.endswith(b"\n"))
        metadata = output.lstat()
        self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)
        self.assertEqual(metadata.st_nlink, 1)
        document = decode_canonical_bytes(payload)
        self.assertEqual(set(document), {"evidence"})
        self.assertEqual(len(document["evidence"]), 1)
        item = document["evidence"][0]
        self.assertEqual(set(item), {"gate", "proofArtifacts"})
        self.assertEqual(item["gate"], "incremental-xcuitest")
        artifacts = item["proofArtifacts"]
        self.assertEqual(
            [artifact["kind"] for artifact in artifacts],
            [
                "installed-task10-matrix-receipt-v1",
                "installed-task10-network-audit-execution-report-v1",
                "installed-task10-network-audit-observation-v1",
                "installed-task10-network-audit-report-v1",
                "installed-task10-xcresult-semantic-manifest-v1",
                "xcresult",
            ],
        )
        xcresult_artifact = next(
            artifact for artifact in artifacts if artifact["kind"] == "xcresult"
        )
        self.assertEqual(xcresult_artifact, {"kind": "xcresult", "path": str(self.xcresult)})
        for artifact in artifacts:
            if artifact["kind"] == "xcresult":
                continue
            self.assertEqual(set(artifact), {"kind", "path", "sha256"})
            self.assertEqual(
                artifact["sha256"],
                hashlib.sha256(Path(artifact["path"]).read_bytes()).hexdigest(),
            )
        self.assertFalse(
            {"status", "sourceCommit", "sourceTree", "executedTestCount", "pid"}
            & set(item)
        )

    def test_rejects_failed_network_audit_even_with_a_passing_matrix_receipt(self) -> None:
        failed = copy.deepcopy(self.network_report)
        failed.update(result="unavailable", exit_code=1, diagnostic="observer gap")
        self._write_canonical(self.network_report_path, failed)

        with self.assertRaisesRegex(
            emitter.InstalledIncrementalEvidenceError,
            "network audit is not a closed passing execution",
        ):
            self._emit()
        self.assertFalse((self.network_root / emitter.OUTPUT_NAME).exists())

    def test_rejects_wrong_qualification_run_and_predecessor_authority(self) -> None:
        for field, value in (
            ("qualification_run", {"run_id": "other-run", "nonce": "9" * 64}),
            ("predecessor_observations_sha256", "8" * 64),
        ):
            with self.subTest(field=field):
                document = copy.deepcopy(self.execution_report)
                document[field] = value
                self._write_canonical(self.execution_report_path, document)
                with self.assertRaisesRegex(
                    emitter.InstalledIncrementalEvidenceError,
                    "qualification-run authority",
                ):
                    self._emit()
                self._write_canonical(self.execution_report_path, self.execution_report)

    def test_rejects_receipt_semantic_and_network_hash_substitution(self) -> None:
        cases = (
            ("matrix_receipt_sha256", "5" * 64),
            ("xcresult_semantic_manifest_sha256", "6" * 64),
            ("xcresult_bundle_sha256", "7" * 64),
        )
        for field, value in cases:
            with self.subTest(field=field):
                document = copy.deepcopy(self.network_report)
                document["workload"][field] = value
                self._write_canonical(self.network_report_path, document)
                with self.assertRaisesRegex(
                    emitter.InstalledIncrementalEvidenceError,
                    "exact passing 22-selector matrix",
                ):
                    self._emit()
                self._write_canonical(self.network_report_path, self.network_report)

    def test_rejects_network_observation_bytes_or_process_claims_that_drift(self) -> None:
        self.observation_path.write_bytes(b",bytes_in,bytes_out,\nMacScope.101,1,0,\n")
        with self.assertRaisesRegex(
            emitter.InstalledIncrementalEvidenceError,
            "bounded sampled-state result",
        ):
            self._emit()

    def _foreign_report(self):
        report = copy.deepcopy(self.network_report)
        attribution = report["attribution"]
        attribution["drains"] = [
            {"drain_id": index, "begin_monotonic_ns": begin,
             "end_monotonic_ns": end, "completed_to_empty": True, "events": []}
            for index, begin, end in ((1, 5, 6), (2, 21, 22), (3, 25, 26))
        ]
        attribution["proofs"] = [{
            "proof_kind": "prearmed-kqueue-path-v1", "observation_id": 1,
            "pid": 1, "watch_token": 1,
            "registration": {
                "requested_monotonic_ns": 1, "completed_monotonic_ns": 2,
                "receipt_ident": 1, "receipt_token": 1, "receipt_filter": -5,
                "receipt_flags": emitter.network_attribution.RECEIPT_FLAGS,
                "receipt_errno": 0,
            },
            "initial_probe": {"begin_monotonic_ns": 3, "end_monotonic_ns": 4,
                              "executable_path": "/sbin/launchd"},
            "final_probe": {"begin_monotonic_ns": 23, "end_monotonic_ns": 24,
                            "executable_path": "/sbin/launchd"},
            "initial_drain_id": 1, "pre_final_drain_id": 2, "post_final_drain_id": 3,
        }]
        report["observer"].update(observed_process_row_count=1, observed_foreign_row_count=1)
        return report

    def _publish_network_fixture(self, report, raw):
        self.observation_path.write_bytes(raw)
        report["observer"].update(observation_byte_count=len(raw),
                                  observation_sha256=hashlib.sha256(raw).hexdigest())
        self._write_canonical(self.network_report_path, report)

    def test_prearmed_foreign_row_is_retained_and_replayed_before_publication(self) -> None:
        raw = b",bytes_in,bytes_out,\nlaunchd.1,123,456,\n"
        self._publish_network_fixture(self._foreign_report(), raw)
        output, _ = self._emit()
        self.assertTrue(output.is_file())
        self.assertEqual(self.observation_path.read_bytes(), raw)

    def test_rehashed_foreign_ledger_and_raw_substitutions_fail_closed(self) -> None:
        raw = b",bytes_in,bytes_out,\nlaunchd.1,0,0,\n"
        def transition(report):
            report["attribution"]["drains"].insert(1, {
                "drain_id": 2, "begin_monotonic_ns": 12, "end_monotonic_ns": 13,
                "completed_to_empty": True, "events": [{
                    "watch_token": 1, "pid": 1, "filter": -5, "flags": 0,
                    "fflags": emitter.network_attribution.NOTE_EXEC, "data": 0,
                }],
            })
            for index, drain in enumerate(report["attribution"]["drains"], 1):
                drain["drain_id"] = index
            report["attribution"]["proofs"][0].update(pre_final_drain_id=3, post_final_drain_id=4)
        cases = {
            "intermediate-exec": (transition, raw),
            "missing-proof": (lambda r: r["attribution"].update(proofs=[]), raw),
            "token-substitution": (lambda r: r["attribution"]["proofs"][0].update(watch_token=2), raw),
            "late-registration": (lambda r: r["attribution"]["proofs"][0]["registration"].update(completed_monotonic_ns=11), raw),
            "candidate-path": (lambda r: r["attribution"]["proofs"][0]["initial_probe"].update(executable_path=str(self.installed_executable)), raw),
            "false-count": (lambda r: r["observer"].update(observed_foreign_row_count=0), raw),
            "boolean-count": (lambda r: r["observer"].update(observed_foreign_row_count=True), raw),
            "unknown-policy": (lambda r: r["attribution"].update(policy_id="future"), raw),
            "v3": (lambda r: r.update(schema_version=3), raw),
            "scope-overclaim": (lambda r: r["observer"].update(evidence_scope="no-network-ever"), raw),
            "unknown-row": (lambda r: None, raw.replace(b"launchd.1,", b"unknown.2,")),
            "candidate-zero-counters": (lambda r: None, raw.replace(b"launchd.1,", b"MacScope.101,")),
            "partial-tail": (lambda r: None, raw[:-1]),
            "extra-row": (lambda r: None, raw + b"launchd.1,0,0,\n"),
        }
        for label, (mutate, payload) in cases.items():
            with self.subTest(label=label):
                report = self._foreign_report()
                mutate(report)
                self._publish_network_fixture(report, payload)
                with self.assertRaises(emitter.InstalledIncrementalEvidenceError):
                    self._emit()
                self.assertFalse((self.network_root / emitter.OUTPUT_NAME).exists())

    def test_rehashed_float_schema_is_rejected_at_document_and_semantic_boundaries(self) -> None:
        report = self._foreign_report()
        self._publish_network_fixture(report, b",bytes_in,bytes_out,\nlaunchd.1,0,0,\n")
        # Retain the malicious bytes directly: the canonical writer itself
        # forbids floats, so it cannot construct this substituted artifact.
        self.network_report_path.write_bytes(
            self.network_report_path.read_bytes().replace(b'"schema_version":4',
                                                        b'"schema_version":4.0')
        )
        with self.assertRaises(emitter.InstalledIncrementalEvidenceError):
            self._emit()
        report["schema_version"] = 4.0
        with self.assertRaisesRegex(emitter.InstalledIncrementalEvidenceError,
                                    "another candidate authority"):
            emitter._validate_network_report(
                report, receipt=self.receipt, receipt_sha256=self.receipt_sha256,
                semantic=self.semantic, semantic_sha256=self.semantic_sha256,
                xcresult_bundle_sha256=self.xcresult_bundle_sha256,
                candidate_document_sha256=self.candidate_document_sha256,
                authorities=self.authorities, observation_bytes=self.observation_path.read_bytes(),
                observer_tool_sha256=self.observer_tool_sha256,
                execution_report=self.execution_report,
            )
        self.assertFalse((self.network_root / emitter.OUTPUT_NAME).exists())

    def test_entire_embedded_report_remains_four_mib_bounded(self) -> None:
        report = self._foreign_report()
        report["diagnostic"] = "x" * emitter.MAXIMUM_NETWORK_REPORT_BYTES
        self._publish_network_fixture(report, b",bytes_in,bytes_out,\nlaunchd.1,0,0,\n")
        with self.assertRaises(emitter.InstalledIncrementalEvidenceError):
            self._emit()
        self.assertFalse((self.network_root / emitter.OUTPUT_NAME).exists())

    def test_adapter_never_invokes_xcresulttool_or_the_full_ws24_normalizer(self) -> None:
        with (
            mock.patch.object(
                emitter.ws24,
                "normalize_input_evidence",
                side_effect=AssertionError("full normalizer is aggregate-owned"),
            ),
            mock.patch.object(
                emitter.ws24,
                "xcresult_test_summary",
                side_effect=AssertionError("xcresulttool summary is aggregate-owned"),
            ),
            mock.patch.object(
                emitter.ws24,
                "xcresult_test_nodes",
                side_effect=AssertionError("xcresulttool nodes are aggregate-owned"),
            ),
            mock.patch.object(
                emitter.ws24.subprocess,
                "run",
                side_effect=AssertionError("adapter must not launch subprocesses"),
            ),
        ):
            output, _ = self._emit()
        self.assertTrue(output.is_file())

    def test_rejects_evidence_that_changes_while_the_adapter_validates(self) -> None:
        with self.assertRaisesRegex(
            emitter.InstalledIncrementalEvidenceError,
            "canonical and physical digests disagree",
        ):
            self._emit(
                load_receipt_side_effect=[
                    (self.receipt, self.receipt_sha256),
                    (self.receipt, "0" * 64),
                ]
            )
        self.assertTrue((self.network_root / emitter.OUTPUT_NAME).is_file())

    def test_empty_candidate_pid_authority_cannot_authorize_classification(self) -> None:
        document = copy.deepcopy(self.network_report)
        document["executables"][0]["processes"] = []
        self._write_canonical(self.network_report_path, document)

        with self.assertRaisesRegex(emitter.InstalledIncrementalEvidenceError,
                                    "candidate/foreign authority is absent"):
            self._emit()

    def test_rejects_substituted_observer_tool_readiness_or_execution_window(self) -> None:
        cases = (
            (
                "tool-path",
                lambda report, receipt: report["observer"].update(
                    tool_path="/usr/bin/false"
                ),
            ),
            (
                "tool-digest",
                lambda report, receipt: report["observer"].update(
                    tool_sha256="7" * 64
                ),
            ),
            (
                "readiness-frame",
                lambda report, receipt: report["observer"].update(
                    readiness_frame_sha256="8" * 64
                ),
            ),
            (
                "execution-window",
                lambda report, receipt: receipt["execution"].update(
                    started_at_unix_ms=90
                ),
            ),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                report = copy.deepcopy(self.network_report)
                receipt = copy.deepcopy(self.receipt)
                mutate(report, receipt)
                self._write_canonical(self.network_report_path, report)
                original = self.receipt
                self.receipt = receipt
                try:
                    with self.assertRaises(emitter.InstalledIncrementalEvidenceError):
                        self._emit()
                finally:
                    self.receipt = original
                    self._write_canonical(
                        self.network_report_path, self.network_report
                    )

    def test_infrastructure_receipt_fails_boundedly_before_xcresult_dereference(self) -> None:
        infrastructure = copy.deepcopy(self.receipt)
        infrastructure["execution"]["result"] = "infrastructure"
        infrastructure["products"]["xcresult"] = {"state": "absent"}
        argv = [
            "--matrix-receipt",
            str(self.receipt_path),
            "--xcresult-semantic-manifest",
            str(self.semantic_path),
            "--network-artifact-root",
            str(self.network_root),
            "--qualification-run-id",
            self.qualification_run_id,
            "--qualification-run-nonce",
            self.qualification_run_nonce,
            "--predecessor-observations-sha256",
            self.predecessor_sha256,
        ]
        stderr = io.StringIO()
        with (
            mock.patch.object(
                emitter.matrix,
                "load_receipt_with_sha256",
                return_value=(infrastructure, self.receipt_sha256),
            ),
            mock.patch.object(
                emitter.matrix,
                "validate_receipt",
                side_effect=emitter.matrix.InstalledMatrixReceiptError(
                    "installed matrix receipt is not passing"
                ),
            ),
            redirect_stderr(stderr),
        ):
            returncode = emitter.main(argv)
        self.assertEqual(returncode, 2)
        self.assertIn("not passing", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())
        self.assertFalse((self.network_root / emitter.OUTPUT_NAME).exists())

    def test_output_is_create_only_and_network_root_must_be_canonical(self) -> None:
        output = self.network_root / emitter.OUTPUT_NAME
        output.write_bytes(b"preexisting")
        before = output.read_bytes()
        with self.assertRaisesRegex(
            emitter.InstalledIncrementalEvidenceError, "output must be absent"
        ):
            self._emit()
        self.assertEqual(output.read_bytes(), before)
        output.unlink()

        alias = self.root / "network-alias"
        alias.symlink_to(self.network_root, target_is_directory=True)
        with self.assertRaisesRegex(
            emitter.InstalledIncrementalEvidenceError,
            "canonical non-symlink directory",
        ):
            emitter.emit(self.arguments(network_artifact_root=alias))

    def test_cli_has_no_caller_authored_execution_or_xcresult_fields(self) -> None:
        arguments = emitter.parse_arguments(
            [
                "--matrix-receipt",
                str(self.receipt_path),
                "--xcresult-semantic-manifest",
                str(self.semantic_path),
                "--network-artifact-root",
                str(self.network_root),
                "--qualification-run-id",
                self.qualification_run_id,
                "--qualification-run-nonce",
                self.qualification_run_nonce,
                "--predecessor-observations-sha256",
                self.predecessor_sha256,
            ]
        )
        self.assertEqual(
            set(vars(arguments)),
            {
                "matrix_receipt",
                "network_artifact_root",
                "predecessor_observations_sha256",
                "qualification_run_id",
                "qualification_run_nonce",
                "xcresult_semantic_manifest",
            },
        )
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            emitter.parse_arguments(
                [
                    "--matrix-receipt",
                    str(self.receipt_path),
                    "--xcresult-semantic-manifest",
                    str(self.semantic_path),
                    "--network-artifact-root",
                    str(self.network_root),
                    "--qualification-run-id",
                    self.qualification_run_id,
                    "--qualification-run-nonce",
                    self.qualification_run_nonce,
                    "--predecessor-observations-sha256",
                    self.predecessor_sha256,
                    "--status",
                    "passed",
                ]
            )

    def test_stdout_is_only_a_path_and_digest_handoff_not_pass_authority(self) -> None:
        output = self.network_root / emitter.OUTPUT_NAME
        stdout = io.StringIO()
        with (
            mock.patch.object(
                emitter, "parse_arguments", return_value=self.arguments()
            ),
            mock.patch.object(
                emitter, "emit", return_value=(output, "9" * 64)
            ),
            redirect_stdout(stdout),
        ):
            returncode = emitter.main([])
        self.assertEqual(returncode, 0)
        self.assertNotIn("PASS", stdout.getvalue())
        self.assertEqual(
            stdout.getvalue().splitlines(),
            [
                f"MACSCOPE_INSTALLED_INCREMENTAL_XCUITEST_EVIDENCE={output}",
                "MACSCOPE_INSTALLED_INCREMENTAL_XCUITEST_EVIDENCE_SHA256="
                + "9" * 64,
            ],
        )


if __name__ == "__main__":
    unittest.main()
