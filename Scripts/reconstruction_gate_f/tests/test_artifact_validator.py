from __future__ import annotations

import hashlib
import errno
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from Scripts.reconstruction_gate_f.artifact_validator import (
    read_descriptor_relative_bytes,
    safe_relative_artifact_path,
    validate_artifact_record,
    validate_artifact_records,
)
from Scripts.reconstruction_gate_f import artifact_validator as artifact_reader
from Scripts.reconstruction_gate_f.schema import EvidenceLayer, candidate_identity_sha256
from Scripts.reconstruction_gate_f.tests import clone, parsed_candidate
from Scripts.reconstruction_gate_f.gate_specific_artifact_validator import (
    GateSpecificArtifactError, _replay_installed_network_attribution,
)
from Scripts.tests.test_network_attribution import fixture as network_fixture


class BootstrapVerifierArtifactTests(unittest.TestCase):
    def test_verifier_replay_revalidates_physical_inputs(self):
        from Scripts.tests.test_gate_f_bootstrap_verifier import BootstrapVerifierTests
        from Scripts.reconstruction_gate_f.bootstrap_verifier_adapter import validate_bootstrap_verifier_outputs
        from Scripts.reconstruction_gate_f.gate_specific_artifact_validator import validate_gate_specific_artifacts
        from Scripts.reconstruction_gate_f.schema import EvidenceStatus
        fixture = BootstrapVerifierTests(methodName="runTest")
        self.addCleanup(fixture.doCleanups)
        physical = fixture.fixture()
        for kind in ("fullsuite", "products"):
            admission, admitted, streams, _ = fixture.adapter_fixture(physical, kind)
            authority, constituents = validate_bootstrap_verifier_outputs(admission, admitted, streams)
            artifacts = []
            for source in admission.owner_artifacts:
                payload = (admission.artifact_root / source.relative_path).read_bytes()
                artifacts.append(dict(artifact_id=source.artifact_id, relative_path=source.relative_path,
                    kind=source.kind.value, media_type=source.media_type, command_output=source.command_output,
                    byte_count=len(payload), sha256=hashlib.sha256(payload).hexdigest()))
            args = dict(admitted_capture_semantics=dict(bootstrap_verifier_admission=admission,
                    bootstrap_verifier_admitted_command=admitted, bootstrap_verifier_streams=streams),
                admitted_command_record=admitted.resolved_command.record,
                admitted_command_inputs=admission.capture.admission.integrated_plan_input.inputs,
                receipt_type=admission.receipt_type, candidate=physical.candidate,
                command_id=admitted.record.command_id, artifacts=artifacts,
                artifact_root=admission.artifact_root, execution_report_artifact_id=admission.execution_report_artifact_id,
                result=EvidenceStatus.PASSED, stress=None, constituents=list(constituents), authority=authority,
                generated_artifacts=admitted.record.generated_artifacts, generated_logs=admitted.record.generated_logs,
                command_plan_sha256="a" * 64, command_record_sha256="b" * 64, prerequisite_receipts=())
            self.assertEqual(validate_gate_specific_artifacts(**args), authority)
            for field, value in (("authority", {}), ("constituents", [] if kind == "fullsuite" else [{}]),
                                 ("admitted_capture_semantics", None)):
                with self.subTest(kind=kind, field=field), self.assertRaises(GateSpecificArtifactError):
                    validate_gate_specific_artifacts(**{**args, field: value})
            for key in ("bootstrap_products_artifact_root", "bootstrap_fullsuite_artifact_root"):
                partial = dict(args["admitted_command_inputs"]); partial.pop(key)
                with self.subTest(kind=kind, partial=key), self.assertRaises(GateSpecificArtifactError):
                    validate_gate_specific_artifacts(**{**args, "admitted_command_inputs": partial})
            original = physical.fixture_build.app / "Contents/MacOS/MacScope"
            saved = original.read_bytes()
            original.write_bytes(saved + b"changed after restart")
            with self.subTest(kind=kind), self.assertRaises(GateSpecificArtifactError):
                validate_gate_specific_artifacts(**args)
            original.write_bytes(saved)



class GateFNetworkReplayTests(unittest.TestCase):
    """Synthetic replay checks do not assert that a kernel capture occurred."""

    def setUp(self):
        proofs, drains = network_fixture()
        self.ledger = dict(policy_id="prearmed-kqueue-path-v1", observer_spawn_ns=10,
                           observer_eof_ns=20, queue_closed_ns=30, proofs=proofs, drains=drains)
        self.paths = frozenset({"/Applications/MacScope.app/Contents/MacOS/MacScope"})
        self.payload = b",bytes_in,bytes_out,\nlaunchd.10,0,0,\n"

    def replay(self, ledger=None, payload=None):
        return _replay_installed_network_attribution(
            self.ledger if ledger is None else ledger,
            self.payload if payload is None else payload,
            candidate_paths=self.paths, candidate_pids=frozenset({100}),
        )

    def test_stable_foreign_row_retained_and_counted(self):
        summary = self.replay()
        self.assertEqual((summary.process_row_count, summary.foreign_row_count,
                          summary.candidate_row_count, summary.unresolved_row_count), (1, 1, 0, 0))

    def test_missing_proof_never_excludes_row(self):
        self.ledger["proofs"] = []
        self.assertEqual(self.replay().unresolved_row_count, 1)

    def test_candidate_zero_counter_and_unknown_rows_remain_classified(self):
        self.assertEqual(self.replay(payload=b",bytes_in,bytes_out,\napp.100,0,0,\n").candidate_row_count, 1)
        self.assertEqual(self.replay(payload=b",bytes_in,bytes_out,\nnew.101,0,0,\n").unresolved_row_count, 1)

    def test_closed_ledger_and_all_drains_are_replayed(self):
        mutations = []
        ledger = clone(self.ledger); ledger["trusted"] = True; mutations.append(ledger)
        ledger = clone(self.ledger); ledger["policy_id"] = "v3"; mutations.append(ledger)
        ledger = clone(self.ledger); ledger["observer_spawn_ns"] = True; mutations.append(ledger)
        ledger = clone(self.ledger); ledger["proofs"][0]["registration"]["receipt_token"] = 2; mutations.append(ledger)
        ledger = clone(self.ledger); ledger["proofs"][0]["final_probe"]["executable_path"] = "/bin/other"; mutations.append(ledger)
        ledger = clone(self.ledger); ledger["drains"][1]["events"] = [dict(watch_token=1, pid=10, filter=-5, flags=0, fflags=0x20000000, data=0)]; mutations.append(ledger)
        for ledger in mutations:
            with self.subTest(ledger=ledger), self.assertRaises(GateSpecificArtifactError):
                self.replay(ledger)

    def test_candidate_path_cannot_be_foreign_and_csv_cannot_be_truncated(self):
        self.ledger["proofs"][0]["initial_probe"]["executable_path"] = next(iter(self.paths))
        self.ledger["proofs"][0]["final_probe"]["executable_path"] = next(iter(self.paths))
        with self.assertRaises(GateSpecificArtifactError): self.replay()
        self.setUp()
        with self.assertRaises(GateSpecificArtifactError): self.replay(payload=self.payload[:-1])


class GateFNetworkArtifactIntegrationTests(unittest.TestCase):
    def setUp(self):
        from Scripts.reconstruction_gate_f.tests.test_executor_receipt import GateFExecutorReceiptTests
        self.fixture = GateFExecutorReceiptTests()
        self.fixture.setUp()
        self.root = self.fixture.root

    def tearDown(self):
        self.fixture.tearDown()

    def admit(self, mutate=None):
        from Scripts.reconstruction_gate_f.canonical_json import load_canonical_json, write_canonical_json
        from Scripts.reconstruction_gate_f.tests.test_executor_receipt import emit_executor_receipt
        request = self.fixture._installed_workflow_request()
        path = self.root / "InstalledNetworkAcquisition.audit.json"
        report = load_canonical_json(path)
        proofs, drains = network_fixture()
        report["attribution"].update(proofs=proofs, drains=drains)
        payload = b",bytes_in,bytes_out,\nlaunchd.10,0,0,\n" + b",bytes_in,bytes_out,\n" * 4
        if mutate is not None:
            payload = mutate(report, payload)
        csv = self.root / "InstalledNetworkAcquisition.nettop.csv"
        csv.write_bytes(payload)
        report["observer"].update(observation_byte_count=len(payload), observation_sha256=hashlib.sha256(payload).hexdigest())
        if mutate is None:
            report["observer"].update(observed_foreign_row_count=1, observed_process_row_count=1)
        write_canonical_json(path, report)
        self.fixture._refresh_descriptor(request, csv)
        self.fixture._refresh_descriptor(request, path)
        return emit_executor_receipt(request, artifact_root=self.root)

    def test_rehashed_stable_foreign_evidence_requires_capture_admission(self):
        receipt, context = self.admit()
        from Scripts.reconstruction_gate_f.receipt_validator import validate_receipt
        # This legacy request-only fixture exercises physical report replay.
        # It has no independently observed command capture and therefore cannot
        # pass public receipt admission, even when its attribution bytes are valid.
        self.assertEqual({issue.code for issue in validate_receipt(receipt, context=context)},
                         {"capture-admission-required"})

    def test_rehashed_mutations_cannot_gain_acceptance(self):
        from Scripts.reconstruction_gate_f.executor_receipt import ReceiptEmissionError
        def mutation(kind):
            def apply(report, payload):
                report["observer"].update(observed_foreign_row_count=1, observed_process_row_count=1)
                if kind == "schema": report["schema_version"] = 3
                elif kind == "scope": report["observer"]["evidence_scope"] = "universal"
                elif kind == "omitted-proof": report["attribution"]["proofs"] = []
                elif kind == "false-count": report["observer"]["observed_process_row_count"] = 0
                elif kind == "path": report["executables"][0]["executable_path"] = "/tmp/forged"
                elif kind == "intermediate-exec": report["attribution"]["drains"][1]["events"] = [dict(watch_token=1, pid=10, filter=-5, flags=0, fflags=0x20000000, data=0)]
                elif kind == "candidate-row":
                    payload = payload.replace(b"launchd.10,", b"app.100,")
                    report["observer"].update(observed_foreign_row_count=0, observed_candidate_row_count=1)
                elif kind == "unknown-row":
                    payload = payload.replace(b"launchd.10,", b"unknown.999,")
                    report["observer"].update(observed_foreign_row_count=0, observed_unresolved_row_count=1)
                elif kind == "truncated": payload = payload[:-1]
                elif kind == "oversized": report["diagnostic"] = "x" * (4 * 1024 * 1024)
                return payload
            return apply
        for kind in ("schema", "scope", "omitted-proof", "false-count", "path", "intermediate-exec", "candidate-row", "unknown-row", "truncated", "oversized"):
            with self.subTest(kind=kind), self.assertRaises(ReceiptEmissionError):
                self.admit(mutation(kind))


class GateFArtifactValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        (self.root / "results").mkdir()
        self.payload = b'{"result":"passed"}'
        (self.root / "results" / "hosted.json").write_bytes(self.payload)
        self.candidate_digest = candidate_identity_sha256(parsed_candidate())
        self.record = {
            "schema_version": 1,
            "artifact_id": "hosted-results",
            "candidate_identity_sha256": self.candidate_digest,
            "evidence_layer": EvidenceLayer.HOSTED_PURE.value,
            "root_id": "qualification-run",
            "relative_path": "results/hosted.json",
            "kind": "test-results",
            "media_type": "application/json",
            "byte_count": len(self.payload),
            "sha256": hashlib.sha256(self.payload).hexdigest(),
            "producer_receipt_id": "receipt-hosted",
            "command_id": "hosted-tests",
            "command_output": "artifact:results/hosted.json",
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def validate(self, record: object, *, root: Path | None = None):
        return validate_artifact_record(
            record,
            expected_candidate_sha256=self.candidate_digest,
            expected_layer=EvidenceLayer.HOSTED_PURE,
            expected_root_id="qualification-run",
            expected_receipt_id="receipt-hosted",
            expected_command_id="hosted-tests",
            root=self.root if root is None else root,
        )

    def test_valid_descriptor_relative_artifact(self) -> None:
        self.assertEqual(self.validate(self.record), ())

    def test_bounded_reader_rejects_growth_before_hashing_over_limit_chunk(self) -> None:
        path = self.root / "results" / "growing.bin"
        path.write_bytes(b"abcd")
        original_read = os.read
        requested = []
        digest = Mock(wraps=hashlib.sha256())

        def growing_read(descriptor, count):
            requested.append(count)
            if len(requested) == 1:
                return original_read(descriptor, min(count, 2))
            if len(requested) == 2:
                with path.open("ab") as output:
                    output.write(b"efgh")
            return original_read(descriptor, count)

        with patch.object(artifact_reader.os, "read", side_effect=growing_read), \
                patch.object(artifact_reader.hashlib, "sha256", return_value=digest):
            with self.assertRaises(OSError) as rejected:
                read_descriptor_relative_bytes(self.root, "results/growing.bin", maximum_bytes=4)
        self.assertEqual(rejected.exception.errno, errno.EFBIG)
        self.assertEqual(requested, [5, 3])
        digest.update.assert_called_once_with(b"ab")

    def test_bounded_reader_preserves_exact_limit_empty_and_unbounded_reads(self) -> None:
        cases = ((b"", 0), (b"abcd", 4), (b"abcd", None))
        path = self.root / "results" / "bounded.bin"
        for payload, bound in cases:
            with self.subTest(payload=payload, maximum_bytes=bound):
                path.write_bytes(payload)
                self.assertEqual(read_descriptor_relative_bytes(self.root, "results/bounded.bin", maximum_bytes=bound),
                                 (payload, len(payload), hashlib.sha256(payload).hexdigest()))

    def test_bounded_reader_preserves_initial_size_and_invalid_bound_rejection(self) -> None:
        with self.assertRaises(OSError) as oversized:
            read_descriptor_relative_bytes(self.root, "results/hosted.json", maximum_bytes=1)
        self.assertEqual(oversized.exception.errno, errno.EFBIG)
        with self.assertRaises(OSError) as negative:
            read_descriptor_relative_bytes(self.root, "results/hosted.json", maximum_bytes=-1)
        self.assertEqual(negative.exception.errno, errno.EFBIG)
        with self.assertRaises(TypeError):
            read_descriptor_relative_bytes(self.root, "results/hosted.json", maximum_bytes="1")

    def test_lexical_paths_reject_escape_and_noncanonical_forms(self) -> None:
        for path in ("../outside", "/tmp/outside", "./results/hosted.json", "results//hosted.json", "results/../hosted.json", "results\\hosted.json", ""):
            with self.subTest(path=path):
                self.assertFalse(safe_relative_artifact_path(path))

    def test_rejects_leaf_intermediate_and_root_symlinks(self) -> None:
        outside = self.root / "outside.json"
        outside.write_bytes(self.payload)
        leaf = self.root / "results" / "leaf.json"
        leaf.symlink_to(outside)
        record = clone(self.record)
        record["relative_path"] = "results/leaf.json"
        self.assertIn("artifact-symlink", {issue.code for issue in self.validate(record)})

        real = self.root / "real"
        real.mkdir()
        (real / "hosted.json").write_bytes(self.payload)
        (self.root / "linked").symlink_to(real, target_is_directory=True)
        record["relative_path"] = "linked/hosted.json"
        self.assertIn("artifact-symlink", {issue.code for issue in self.validate(record)})

        root_link = self.root.parent / f"{self.root.name}-link"
        root_link.symlink_to(self.root, target_is_directory=True)
        try:
            record["relative_path"] = "results/hosted.json"
            self.assertIn("artifact-symlink", {issue.code for issue in self.validate(record, root=root_link)})
        finally:
            root_link.unlink()

    def test_rejects_hash_size_candidate_layer_and_producer_drift(self) -> None:
        mutations = (
            ("artifact-sha256-mismatch", "sha256", "f" * 64),
            ("artifact-byte-count-mismatch", "byte_count", len(self.payload) + 1),
            ("artifact-candidate-mismatch", "candidate_identity_sha256", "f" * 64),
            ("artifact-layer-mismatch", "evidence_layer", EvidenceLayer.NATIVE_NORMAL.value),
            ("artifact-binding-mismatch", "producer_receipt_id", "another-receipt"),
            ("artifact-binding-mismatch", "command_id", "another-command"),
            ("artifact-binding-mismatch", "root_id", "another-root"),
        )
        for expected, field, value in mutations:
            with self.subTest(field=field):
                record = clone(self.record)
                record[field] = value
                self.assertIn(expected, {issue.code for issue in self.validate(record)})

    def test_rejects_unknown_fields_wrong_types_missing_and_nonregular(self) -> None:
        record = clone(self.record)
        record["unknown"] = True
        self.assertIn("unknown-field", {issue.code for issue in self.validate(record)})
        record = clone(self.record)
        record["byte_count"] = True
        self.assertIn("artifact-byte-count", {issue.code for issue in self.validate(record)})
        record = clone(self.record)
        record["relative_path"] = "results/missing.json"
        self.assertIn("artifact-missing", {issue.code for issue in self.validate(record)})
        directory = self.root / "results" / "directory"
        directory.mkdir()
        record["relative_path"] = "results/directory"
        self.assertIn("artifact-not-regular", {issue.code for issue in self.validate(record)})

    def test_collection_rejects_duplicate_ids_and_paths(self) -> None:
        duplicate = clone(self.record)
        issues = validate_artifact_records(
            [self.record, duplicate],
            expected_candidate_sha256=self.candidate_digest,
            expected_layer=EvidenceLayer.HOSTED_PURE,
            expected_root_id="qualification-run",
            expected_receipt_id="receipt-hosted",
            expected_command_id="hosted-tests",
            root=self.root,
        )
        codes = {issue.code for issue in issues}
        self.assertIn("duplicate-artifact-id", codes)
        self.assertIn("duplicate-artifact-path", codes)


if __name__ == "__main__":
    unittest.main()
