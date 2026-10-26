from __future__ import annotations

import hashlib
import io
import os
import stat
import tempfile
import time
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from Scripts.reconstruction import emit_installed_live_evidence as emitter
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes


class EmitInstalledLiveEvidenceTests(unittest.TestCase):
    source_commit = "1" * 40
    source_tree = "2" * 40
    installed_digest = "a" * 64

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.evidence_root = self.root / "evidence"
        self.evidence_root.mkdir()
        self.exposed_at = time.time_ns() - 5_000_000_000
        self.authority = SimpleNamespace(
            candidate_identity=self.root / "candidate-root/candidate.json",
            candidate_root=self.root / "candidate-root",
            source_app=self.root / "source/MacScope.app",
            installed_app=emitter.CANONICAL_INSTALLED_APP,
            evidence_root=self.evidence_root,
            source_authority=SimpleNamespace(
                candidate=SimpleNamespace(
                    source=SimpleNamespace(
                        commit=self.source_commit,
                        tree=self.source_tree,
                    )
                )
            ),
            pending_state_path=self.root / "pending/transaction.json",
            pending_state={"predecessor_observations_sha256": "b" * 64},
            qualification_run_id="qualification-run",
            qualification_run_nonce="c" * 64,
            exposed_at_unix_ns=self.exposed_at,
            installed_executable_sha256=self.installed_digest,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def _private_file(path: Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(canonical_bytes(value))
        path.chmod(0o600)

    def _attempt(
        self,
        *,
        index: int,
        scenario: str,
        seed: int | None,
        peak: int | None,
        exit_code: int = 0,
        started: int | None = None,
    ) -> dict[str, object]:
        exposure_ms = (self.exposed_at + 999_999) // 1_000_000
        start = exposure_ms + index if started is None else started
        return {
            "attemptIndex": index,
            "endedAtUnixMilliseconds": start + 10,
            "exitCode": exit_code,
            "failure": None if exit_code == 0 else "physical failure",
            "peakResidentMemoryMegabytes": peak,
            "scenario": scenario,
            "seed": seed,
            "startedAtUnixMilliseconds": start,
            "timedOut": False,
        }

    def _report_document(self, gate: str) -> dict[str, object]:
        if gate in {"installed-launch-smoke", "direct-debugger-transport-contracts"}:
            attempts = [
                self._attempt(index=1, scenario=gate, seed=None, peak=None)
            ]
        elif gate in emitter.ws24.STRESS_GATES:
            attempts = [
                self._attempt(index=index, scenario=gate, seed=index, peak=None)
                for index in range(1, 11)
            ]
        else:
            attempts = [
                self._attempt(
                    index=index,
                    scenario=scenario,
                    seed=(scenario_index * 100) + index,
                    peak=128,
                )
                for scenario_index, scenario in enumerate(
                    sorted(emitter.ws24.STRESS_GATES), start=1
                )
                for index in range(1, 11)
            ]
        return {
            "attempts": attempts,
            "gate": gate,
            "installedExecutableSHA256": self.installed_digest,
            "schemaVersion": 1,
            "sourceCommit": self.source_commit,
            "sourceTree": self.source_tree,
        }

    def _write_live_reports(self) -> Path:
        report_root = self.evidence_root / emitter.LIVE_REPORT_ROOT_NAME
        report_root.mkdir()
        report_root.chmod(0o700)
        for gate, name in emitter.LIVE_REPORT_FILE_BY_GATE.items():
            self._private_file(report_root / name, self._report_document(gate))
        return report_root

    def _fixed_incremental_inputs(self) -> tuple[Path, Path, Path, Path]:
        receipt = self.evidence_root / emitter.MATRIX_RECEIPT_NAME
        semantic = self.evidence_root / emitter.MATRIX_SEMANTIC_MANIFEST_NAME
        network = self.evidence_root / emitter.MATRIX_NETWORK_ROOT_NAME
        descriptor = network / emitter.INCREMENTAL_DESCRIPTOR_NAME
        self._private_file(receipt, {})
        self._private_file(semantic, {})
        network.mkdir()
        network.chmod(0o700)
        self._private_file(descriptor, {})
        return receipt, semantic, network, descriptor

    def test_cli_freezes_only_one_bounded_execution_timeout(self) -> None:
        values = [
            "--candidate-identity", str(self.root / "candidate-root/candidate.json"),
            "--source-app", str(self.root / "source/MacScope.app"),
            "--installed-app", "/Applications/MacScope.app",
            "--installation-pending-state", str(self.root / "pending/transaction.json"),
            "--native-preparation-receipt", str(self.root / "candidate-root/NativeLivePreparation.receipt.json"),
            "--matrix-receipt", str(self.evidence_root / emitter.MATRIX_RECEIPT_NAME),
            "--xcresult-semantic-manifest", str(self.evidence_root / emitter.MATRIX_SEMANTIC_MANIFEST_NAME),
            "--network-artifact-root", str(self.evidence_root / emitter.MATRIX_NETWORK_ROOT_NAME),
            "--qualification-run-id", "qualification-run",
            "--qualification-run-nonce", "c" * 64,
            "--evidence-root", str(self.evidence_root),
        ]

        arguments = emitter.parse_arguments(values)

        self.assertEqual(arguments.live_gates_timeout_seconds, 1800)
        self.assertFalse(hasattr(arguments, "matrix_timeout_seconds"))
        self.assertFalse(hasattr(arguments, "installed_ui_preparation_receipt"))
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            emitter.parse_arguments([*values, "--live-gates-timeout-seconds", "3601"])
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            emitter.parse_arguments([*values, "--status", "passed"])

    def test_live_runner_argv_is_exact_and_ordered(self) -> None:
        preparation = SimpleNamespace(path=self.root / "candidate-root/NativeLivePreparation.receipt.json")
        observed: list[list[str]] = []

        def main(argv: list[str]) -> int:
            observed.append(argv)
            return 0

        with mock.patch.object(
            emitter.importlib,
            "import_module",
            return_value=SimpleNamespace(main=main),
        ):
            emitter._invoke_live_runner(self.authority, preparation, timeout_seconds=1800)

        self.assertEqual(
            observed,
            [[
                "--candidate-identity", str(self.authority.candidate_identity),
                "--source-app", str(self.authority.source_app),
                "--installed-app", "/Applications/MacScope.app",
                "--installation-pending-state", str(self.authority.pending_state_path),
                "--preparation-receipt", str(preparation.path),
                "--qualification-run-id", "qualification-run",
                "--qualification-run-nonce", "c" * 64,
                "--output-root", str(self.evidence_root / emitter.LIVE_REPORT_ROOT_NAME),
                "--timeout-seconds", "1800",
            ]],
        )

    def test_live_runner_nonzero_status_is_not_converted_to_evidence(self) -> None:
        preparation = SimpleNamespace(path=self.root / "NativeLivePreparation.receipt.json")
        with mock.patch.object(
            emitter.importlib,
            "import_module",
            return_value=SimpleNamespace(main=lambda argv: 1),
        ), self.assertRaisesRegex(emitter.LiveEvidenceError, "exit status 1"):
            emitter._invoke_live_runner(
                self.authority, preparation, timeout_seconds=1800
            )

    def test_preflight_requires_frozen_task10_paths_and_existing_descriptor(self) -> None:
        receipt, semantic, network, descriptor = self._fixed_incremental_inputs()

        observed = emitter._preflight_outputs(
            self.authority,
            matrix_receipt=receipt,
            semantic_manifest=semantic,
            network_root=network,
        )

        self.assertEqual(observed, network)
        self.assertTrue(descriptor.is_file())
        with self.assertRaisesRegex(emitter.LiveEvidenceError, "exact governed"):
            emitter._preflight_outputs(
                self.authority,
                matrix_receipt=self.root / "decoy.json",
                semantic_manifest=semantic,
                network_root=network,
            )

    def test_preflight_rejects_missing_incremental_descriptor(self) -> None:
        receipt, semantic, network, descriptor = self._fixed_incremental_inputs()
        descriptor.unlink()

        with self.assertRaisesRegex(emitter.LiveEvidenceError, "descriptor is unavailable"):
            emitter._preflight_outputs(
                self.authority,
                matrix_receipt=receipt,
                semantic_manifest=semantic,
                network_root=network,
            )

    def test_six_canonical_live_reports_are_consumed_as_sha_bound_files(self) -> None:
        self._write_live_reports()

        entries, snapshots = emitter._load_live_reports(self.authority)

        self.assertEqual(tuple(entries), emitter.LIVE_GATE_ORDER)
        self.assertEqual(set(snapshots), set(emitter.LIVE_GATE_ORDER))
        for gate, entry in entries.items():
            self.assertEqual(entry["gate"], gate)
            artifact = entry["proofArtifacts"][0]
            self.assertEqual(artifact["sha256"], snapshots[gate].sha256)
            self.assertEqual(artifact["kind"], emitter.ws24.LIVE_EXECUTION_REPORT_KIND)

    def test_live_report_root_rejects_unknown_files(self) -> None:
        report_root = self._write_live_reports()
        self._private_file(report_root / "PASS.txt", {"status": "passed"})

        with self.assertRaisesRegex(emitter.LiveEvidenceError, "not closed"):
            emitter._load_live_reports(self.authority)

    def test_live_report_rejects_noncanonical_trailing_line_feed(self) -> None:
        report_root = self._write_live_reports()
        gate = "installed-launch-smoke"
        path = report_root / emitter.LIVE_REPORT_FILE_BY_GATE[gate]
        path.write_bytes(path.read_bytes() + b"\n")

        with self.assertRaisesRegex(emitter.LiveEvidenceError, "not canonical JSON"):
            emitter._load_live_reports(self.authority)

    def test_live_report_rejects_nonprivate_mode(self) -> None:
        report_root = self._write_live_reports()
        gate = "direct-debugger-transport-contracts"
        (report_root / emitter.LIVE_REPORT_FILE_BY_GATE[gate]).chmod(0o644)

        with self.assertRaisesRegex(emitter.LiveEvidenceError, "exactly 0600"):
            emitter._load_live_reports(self.authority)

    def test_live_report_rejects_hardlink(self) -> None:
        report_root = self._write_live_reports()
        gate = "installed-launch-smoke"
        path = report_root / emitter.LIVE_REPORT_FILE_BY_GATE[gate]
        os.link(path, self.root / "second-link.json")

        with self.assertRaisesRegex(emitter.LiveEvidenceError, "singly linked"):
            emitter._load_live_reports(self.authority)

    def test_live_report_rejects_attempt_before_pending_exposure(self) -> None:
        report_root = self._write_live_reports()
        gate = "installed-launch-smoke"
        document = self._report_document(gate)
        document["attempts"][0]["startedAtUnixMilliseconds"] = (
            self.exposed_at // 1_000_000
        ) - 1
        path = report_root / emitter.LIVE_REPORT_FILE_BY_GATE[gate]
        self._private_file(path, document)

        with self.assertRaisesRegex(emitter.LiveEvidenceError, "predates"):
            emitter._load_live_reports(self.authority)

    def test_live_report_rejects_physical_mtime_before_pending_exposure(self) -> None:
        report_root = self._write_live_reports()
        gate = "installed-launch-smoke"
        path = report_root / emitter.LIVE_REPORT_FILE_BY_GATE[gate]
        stale_seconds = (self.exposed_at - 1_000_000_000) / 1_000_000_000
        os.utime(path, (stale_seconds, stale_seconds))

        with self.assertRaisesRegex(emitter.LiveEvidenceError, "modification time predates"):
            emitter._load_live_reports(self.authority)

    def test_live_report_rejects_failed_physical_attempt(self) -> None:
        report_root = self._write_live_reports()
        gate = "direct-debugger-transport-contracts"
        document = self._report_document(gate)
        document["attempts"][0]["exitCode"] = 7
        document["attempts"][0]["failure"] = "real failure"
        self._private_file(report_root / emitter.LIVE_REPORT_FILE_BY_GATE[gate], document)

        with self.assertRaisesRegex(emitter.LiveEvidenceError, "not favorable"):
            emitter._load_live_reports(self.authority)

    def _incremental_fixture(self) -> tuple[Path, Path, Path, Path, dict[str, object]]:
        receipt_path = self.evidence_root / emitter.MATRIX_RECEIPT_NAME
        semantic_path = self.evidence_root / emitter.MATRIX_SEMANTIC_MANIFEST_NAME
        network_root = self.evidence_root / emitter.MATRIX_NETWORK_ROOT_NAME
        descriptor_path = network_root / emitter.INCREMENTAL_DESCRIPTOR_NAME
        xcresult_path = self.evidence_root / emitter.MATRIX_XCRESULT_NAME
        receipt_value: dict[str, object] = {}
        self._private_file(receipt_path, receipt_value)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()
        projection = [{"test_identifier": "suite/test", "vector_id": "v", "required_identifiers": ["id"]}]
        receipt = {
            "schema_version": emitter.installed_matrix_receipt.SCHEMA_VERSION,
            "candidate": {"identity_sha256": "d" * 64},
            "products": {
                "xcresult": {"path": str(xcresult_path), "closed_tree_sha256": "e" * 64}
            },
            "execution": {
                "started_at_unix_ms": (self.exposed_at + 999_999) // 1_000_000,
                "selector_projection": projection,
                "selector_projection_sha256": "f" * 64,
            },
        }
        semantic = {
            "schema_version": 3,
            "result": "passed",
            "candidate_identity_sha256": "d" * 64,
            "source_xcresult": {
                "bundle_sha256": "0" * 64,
                "closed_tree_sha256": "e" * 64,
            },
            "selector_projection": projection,
            "selector_projection_sha256": "f" * 64,
        }
        self._private_file(semantic_path, semantic)
        network_root.mkdir()
        network_root.chmod(0o700)
        execution_path = network_root / emitter.network_audit.EXECUTION_REPORT_NAME
        observation_path = network_root / emitter.network_audit.OBSERVATION_NAME
        network_report_path = network_root / emitter.network_audit.REPORT_NAME
        self._private_file(execution_path, {"result": "passed"})
        observation_path.write_bytes(b"nettop-observation\n")
        observation_path.chmod(0o600)
        self._private_file(network_report_path, {"result": "passed"})
        descriptor = {
            "evidence": [
                {
                    "gate": "incremental-xcuitest",
                    "proofArtifacts": [
                        {
                            "kind": emitter.installed_matrix_receipt.PROOF_ARTIFACT_KIND,
                            "path": str(receipt_path),
                            "sha256": receipt_sha,
                        },
                        {
                            "kind": emitter.NETWORK_EXECUTION_ARTIFACT_KIND,
                            "path": str(execution_path),
                            "sha256": hashlib.sha256(execution_path.read_bytes()).hexdigest(),
                        },
                        {
                            "kind": emitter.NETWORK_OBSERVATION_ARTIFACT_KIND,
                            "path": str(observation_path),
                            "sha256": hashlib.sha256(observation_path.read_bytes()).hexdigest(),
                        },
                        {
                            "kind": emitter.NETWORK_REPORT_ARTIFACT_KIND,
                            "path": str(network_report_path),
                            "sha256": hashlib.sha256(network_report_path.read_bytes()).hexdigest(),
                        },
                        {
                            "kind": emitter.SEMANTIC_MANIFEST_ARTIFACT_KIND,
                            "path": str(semantic_path),
                            "sha256": hashlib.sha256(semantic_path.read_bytes()).hexdigest(),
                        },
                        {"kind": "xcresult", "path": str(xcresult_path)},
                    ],
                }
            ]
        }
        self._private_file(descriptor_path, descriptor)
        return receipt_path, semantic_path, network_root, descriptor_path, receipt

    def _load_incremental_with_stubs(
        self,
        receipt_path: Path,
        semantic_path: Path,
        network_root: Path,
        descriptor_path: Path,
        receipt: dict[str, object],
    ) -> emitter.IncrementalEvidence:
        tree = emitter.TreeSnapshot(
            path=self.evidence_root / emitter.MATRIX_XCRESULT_NAME,
            metadata=((".",),),
            total_bytes=1,
            result_bundle_sha256="0" * 64,
        )
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()
        with (
            mock.patch.object(
                emitter.installed_matrix_receipt,
                "parse_document",
                return_value=receipt,
            ),
            mock.patch.object(
                emitter.installed_matrix_receipt,
                "load_receipt_with_sha256",
                return_value=(receipt, receipt_sha),
            ),
            mock.patch.object(
                emitter.installed_matrix_receipt,
                "validate_receipt",
                return_value="digest",
            ),
            mock.patch.object(emitter, "_capture_xcresult", return_value=tree),
            mock.patch.object(emitter.ws24, "installed_selector_projection", return_value=[]),
        ):
            return emitter._load_incremental_evidence(
                self.authority,
                descriptor_path=descriptor_path,
                receipt_path=receipt_path,
                semantic_manifest_path=semantic_path,
                network_root=network_root,
            )

    def test_incremental_descriptor_is_consumed_verbatim(self) -> None:
        receipt_path, semantic_path, network_root, descriptor_path, receipt = (
            self._incremental_fixture()
        )
        expected = emitter.decode_canonical_bytes(descriptor_path.read_bytes())

        observed = self._load_incremental_with_stubs(
            receipt_path, semantic_path, network_root, descriptor_path, receipt
        )

        self.assertEqual(observed.descriptor, expected)
        self.assertEqual(observed.entry, expected["evidence"][0])
        self.assertEqual(
            observed.entry["proofArtifacts"], expected["evidence"][0]["proofArtifacts"]
        )

    def test_incremental_descriptor_rejects_unhashed_file_artifact(self) -> None:
        receipt_path, semantic_path, network_root, descriptor_path, receipt = (
            self._incremental_fixture()
        )
        descriptor = emitter.decode_canonical_bytes(descriptor_path.read_bytes())
        del descriptor["evidence"][0]["proofArtifacts"][1]["sha256"]
        self._private_file(descriptor_path, descriptor)

        with self.assertRaisesRegex(emitter.LiveEvidenceError, "frozen row"):
            self._load_incremental_with_stubs(
                receipt_path, semantic_path, network_root, descriptor_path, receipt
            )

    def test_incremental_descriptor_rejects_substituted_receipt(self) -> None:
        receipt_path, semantic_path, network_root, descriptor_path, receipt = (
            self._incremental_fixture()
        )
        decoy = network_root / "decoy-receipt.json"
        self._private_file(decoy, {})
        descriptor = emitter.decode_canonical_bytes(descriptor_path.read_bytes())
        descriptor["evidence"][0]["proofArtifacts"][0].update(
            {
                "path": str(decoy),
                "sha256": hashlib.sha256(decoy.read_bytes()).hexdigest(),
            }
        )
        self._private_file(descriptor_path, descriptor)

        with self.assertRaisesRegex(emitter.LiveEvidenceError, "frozen row"):
            self._load_incremental_with_stubs(
                receipt_path, semantic_path, network_root, descriptor_path, receipt
            )

    def test_incremental_descriptor_rejects_semantic_mismatch(self) -> None:
        receipt_path, semantic_path, network_root, descriptor_path, receipt = (
            self._incremental_fixture()
        )
        semantic = emitter.decode_canonical_bytes(semantic_path.read_bytes())
        semantic["source_xcresult"]["bundle_sha256"] = "9" * 64
        self._private_file(semantic_path, semantic)

        with self.assertRaisesRegex(
            emitter.LiveEvidenceError,
            "descriptor semantic manifest SHA-256 differs",
        ):
            self._load_incremental_with_stubs(
                receipt_path, semantic_path, network_root, descriptor_path, receipt
            )

    def test_xcresult_snapshot_rejects_hardlinked_files(self) -> None:
        xcresult = self.evidence_root / emitter.MATRIX_XCRESULT_NAME
        xcresult.mkdir()
        artifact = xcresult / "database.sqlite"
        artifact.write_bytes(b"result")
        os.link(artifact, self.root / "second-result-link")

        with self.assertRaisesRegex(emitter.LiveEvidenceError, "non-ordinary file"):
            emitter._capture_xcresult(
                xcresult, exposed_at_unix_ns=self.exposed_at
            )

    def test_xcresult_snapshot_rejects_symlinks(self) -> None:
        xcresult = self.evidence_root / emitter.MATRIX_XCRESULT_NAME
        xcresult.mkdir()
        target = self.root / "target"
        target.write_bytes(b"result")
        (xcresult / "link").symlink_to(target)

        with self.assertRaisesRegex(emitter.LiveEvidenceError, "contains a symlink"):
            emitter._capture_xcresult(
                xcresult, exposed_at_unix_ns=self.exposed_at
            )

    def test_xcresult_snapshot_rejects_stale_entries(self) -> None:
        xcresult = self.evidence_root / emitter.MATRIX_XCRESULT_NAME
        xcresult.mkdir()
        artifact = xcresult / "database.sqlite"
        artifact.write_bytes(b"result")
        stale_seconds = (self.exposed_at - 1_000_000_000) / 1_000_000_000
        os.utime(artifact, (stale_seconds, stale_seconds))

        with self.assertRaisesRegex(emitter.LiveEvidenceError, "predates exposure"):
            emitter._capture_xcresult(
                xcresult, exposed_at_unix_ns=self.exposed_at
            )

    def test_manifest_is_closed_and_sorted_with_every_gate_once(self) -> None:
        live_entries = {
            gate: {"gate": gate, "proofArtifacts": [{"kind": "k", "path": "/p"}]}
            for gate in emitter.LIVE_GATE_ORDER
        }
        incremental = {
            "gate": "incremental-xcuitest",
            "proofArtifacts": [{"kind": "xcresult", "path": "/result.xcresult"}],
        }

        document = emitter._manifest_document(live_entries, incremental)

        self.assertEqual(set(document), {"evidence"})
        self.assertEqual(
            tuple(item["gate"] for item in document["evidence"]),
            emitter.MANIFEST_GATE_ORDER,
        )
        self.assertFalse(canonical_bytes(document).endswith(b"\n"))

    def test_manifest_normalization_rejects_duplicate_or_reordered_gates(self) -> None:
        items = [
            {"gate": gate, "proofArtifacts": [{"kind": "k", "path": "/p"}]}
            for gate in emitter.MANIFEST_GATE_ORDER
        ]
        items[1] = dict(items[0])

        with self.assertRaisesRegex(emitter.LiveEvidenceError, "exactly once in order"):
            emitter._normalize_manifest({"evidence": items}, self.authority)

    def test_secure_manifest_publication_is_create_only_private_and_no_lf(self) -> None:
        output = self.evidence_root / emitter.MANIFEST_NAME
        document = {"evidence": []}
        publication = emitter.secure_file.write_create_only(output, document)

        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        self.assertEqual(output.stat().st_nlink, 1)
        self.assertEqual(output.read_bytes(), canonical_bytes(document))
        self.assertFalse(output.read_bytes().endswith(b"\n"))
        with self.assertRaisesRegex(
            emitter.secure_file.ExecutionReportError, "absent absolute path"
        ):
            emitter.secure_file.write_create_only(output, document)
        emitter.secure_file.remove_published_file(publication)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
