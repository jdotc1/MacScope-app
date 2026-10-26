"""Portable physical/semantic boundaries; no patched validator or native run.

Private-stage tests explicitly do not claim end-to-end campaign admission.
The retained campaign fixture supplies full predecessor positives separately.
"""
from __future__ import annotations

from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
import os
import shutil
from Scripts.lib.work_root import existing_work_root, work_root as macscope_work_root
import subprocess
import sys
import tempfile
import unittest

from Scripts.reconstruction_gate_f import external_authority_adapter as adapter
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes, canonical_sha256, decode_canonical_bytes
from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile, INDEPENDENT_REVIEW_COMMAND_LENSES
from Scripts.reconstruction_gate_f.command_execution import ExecutionAdmission
from Scripts.reconstruction_gate_f.executor_receipt import ReceiptEmissionError, _validate_legacy_physical_evidence
from Scripts.reconstruction_gate_f.executor_request_adapter import OwnerArtifactSource
from Scripts.reconstruction_gate_f.receipt_validator import ExecutionIntervalExpectation
from Scripts.reconstruction_gate_f.schema import (ArtifactKind, CandidateSubjectKind, QualificationPhase,
                                                  ReceiptType, candidate_identity_sha256)
from Scripts.reconstruction_gate_f.tests import test_executor_receipt as physical_fixtures

QUALIFICATION_RUN = physical_fixtures.QUALIFICATION_RUN


class ExternalAuthorityAdapterTests(unittest.TestCase):
    def setUp(self):
        # Existing fixture writes genuine canonical physical reports used by the
        # production semantic validators. Keep temporary files under the work root.
        base = existing_work_root()
        self.temp = tempfile.TemporaryDirectory(prefix="external-authority-", dir=str(base) if base else None)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.fixture = physical_fixtures.GateFExecutorReceiptTests(methodName="runTest")
        self.fixture.root = self.root
        from Scripts.reconstruction_gate_f.tests import parsed_candidate
        from Scripts.reconstruction_gate_f.command_catalog import command_templates
        self.fixture.candidate = parsed_candidate()
        self.fixture.templates = {item.command_id: item for item in command_templates()}

    def admission(self, request):
        candidate = self.fixture.candidate
        from Scripts.reconstruction_gate_f.schema import parse_candidate_identity
        candidate, issues = parse_candidate_identity(request["candidate_identity"])
        self.assertFalse(issues)
        # Deliberately no integrated plan here: private physical-stage tests
        # must not accidentally become favorable public admission fixtures.
        execution = ExecutionAdmission(candidate, None, QUALIFICATION_RUN,
                                       candidate.source.commit, candidate.source.tree, ())
        sources = tuple(OwnerArtifactSource(a["artifact_id"], a["relative_path"], ArtifactKind(a["kind"]),
                                            a["media_type"], a["command_output"]) for a in request["artifacts"])
        labels = ()
        if request["command_id"] in INDEPENDENT_REVIEW_COMMAND_LENSES:
            lens = INDEPENDENT_REVIEW_COMMAND_LENSES[request["command_id"]]
            labels = ((request["command_id"], "reviewer-" + lens),)
        return adapter.ExternalAuthorityAdmission(execution, CampaignProfile.EXISTING,
            request["command_id"], request["scenario_id"], self.root, request["receipt_id"], request["requirement_id"],
            QualificationPhase(request["qualification_phase"]), ReceiptType(request["receipt_type"]),
            request["artifact_root_id"], request["execution_report_artifact_id"], sources, (), request["executor"],
            labels, tuple((s.command_output, (self.root / s.relative_path).read_bytes()) for s in sources), None, None)

    def outputs(self, admission):
        template = self.fixture.templates[admission.command_id]
        record = SimpleNamespace(command_id=admission.command_id, generated_artifacts=template.generated_artifacts,
            generated_logs=template.generated_logs, evidence_layer=template.evidence_layer,
            candidate_identity_sha256=__import__("Scripts.reconstruction_gate_f.schema", fromlist=["candidate_identity_sha256"]).candidate_identity_sha256(admission.execution.candidate))
        return adapter._owned_outputs(admission, record)

    def lens(self):
        request = self.fixture._independent_review_lens_request(next(iter(INDEPENDENT_REVIEW_COMMAND_LENSES)))
        return request, self.admission(request)

    def test_exact_eight_closed_commands(self):
        self.assertEqual(len(adapter.EXTERNAL_COMMAND_IDS), 8)
        for command in ("xcode.smoke", "installed.source-equality", "review.unknown", "signing.strict-release"):
            request, admission = self.lens()
            with self.assertRaisesRegex(ReceiptEmissionError, "eight external"):
                adapter.build_external_request(replace(admission, command_id=command))

    def test_public_entry_rejects_digest_only_or_missing_integrated_plan(self):
        _, admission = self.lens()
        for value in ({"validated": True}, admission):
            with self.assertRaises(ReceiptEmissionError):
                adapter.build_external_request(value)

    def test_lens_physical_reports_derive_counts_and_constituent(self):
        request, admission = self.lens()
        artifacts, documents, snapshots = self.outputs(admission)
        authority, constituents = adapter._review_semantics(admission, artifacts, documents, ExecutionIntervalExpectation(1000, 2000))
        self.assertEqual(authority, request["authority"])
        self.assertEqual(constituents, request["constituents"])
        receipt, _ = _validate_legacy_physical_evidence(request, artifact_root=self.root, qualification_run_authority=QUALIFICATION_RUN)
        self.assertEqual(receipt["evidence_status"], "passed")
        self.assertEqual(len(snapshots), 2)

    def test_wrong_reviewer_and_outside_interval_rejected(self):
        _, admission = self.lens()
        artifacts, documents, _ = self.outputs(admission)
        with self.assertRaisesRegex(ReceiptEmissionError, "reviewer assignment"):
            adapter._review_semantics(replace(admission, reviewer_assignments=((admission.command_id, "someone-else"),)),
                artifacts, documents, ExecutionIntervalExpectation(1000, 2000))
        with self.assertRaisesRegex(ReceiptEmissionError, "interval"):
            adapter._review_semantics(admission, artifacts, documents, ExecutionIntervalExpectation(1100, 2000))

    def test_retained_observation_is_independent_of_rehashed_physical_report(self):
        request, admission = self.lens()
        source = next(s for s in admission.owner_artifacts if s.kind is ArtifactKind.REVIEW_REPORT)
        path = self.root / source.relative_path
        document = decode_canonical_bytes(path.read_bytes())
        document["reviewer_id"] = "new-favorable-reviewer"
        path.write_bytes(canonical_bytes(document))
        self.fixture._refresh_descriptor(request, path)
        with self.assertRaisesRegex(ReceiptEmissionError, "retained observation"):
            self.outputs(admission)

    def test_missing_extra_duplicate_and_rekeyed_observations_rejected(self):
        _, admission = self.lens()
        for rows in (admission.retained_observations[:-1], admission.retained_observations * 2,
                     (admission.retained_observations[0],) * 2,
                     (("artifact:wrong", b"{}"),) + admission.retained_observations[1:]):
            with self.subTest(rows=len(rows)), self.assertRaisesRegex(ReceiptEmissionError, "output declarations"):
                self.outputs(replace(admission, retained_observations=rows))

    def test_owner_paths_and_ids_are_unique(self):
        _, admission = self.lens()
        first, second = admission.owner_artifacts
        for source in (replace(second, artifact_id=first.artifact_id), replace(second, relative_path=first.relative_path),
                       replace(second, command_output=first.command_output)):
            with self.assertRaisesRegex(ReceiptEmissionError, "unique declaration"):
                self.outputs(replace(admission, owner_artifacts=(first, source)))

    def test_no_path_escape_symlink_directory_or_hardlink(self):
        _, admission = self.lens()
        source = admission.owner_artifacts[0]
        actual = self.root / source.relative_path
        with self.assertRaisesRegex(ReceiptEmissionError, "escapes"):
            adapter._snapshot(self.root, "../outside")
        link = self.root / "alias.json"
        link.symlink_to(actual)
        with self.assertRaisesRegex(ReceiptEmissionError, "singly-linked"):
            adapter._snapshot(self.root, link.name)
        link.unlink()
        link.mkdir()
        with self.assertRaisesRegex(ReceiptEmissionError, "singly-linked"):
            adapter._snapshot(self.root, link.name)
        link.rmdir()
        os.link(actual, link)
        with self.assertRaisesRegex(ReceiptEmissionError, "singly-linked"):
            adapter._snapshot(self.root, actual.name)

    def test_snapshot_detects_same_bytes_inode_replacement(self):
        _, admission = self.lens()
        source = admission.owner_artifacts[0]
        before = adapter._snapshot(self.root, source.relative_path)
        replacement = self.root / "replacement"
        replacement.write_bytes(before[0])
        replacement.replace(self.root / source.relative_path)
        after = adapter._snapshot(self.root, source.relative_path)
        self.assertEqual(before[:3], after[:3])
        self.assertNotEqual(before, after)

    def test_final_fence_rejects_artifact_change_before_any_rebinding(self):
        _, admission = self.lens()
        _, _, snapshots = self.outputs(admission)
        source = admission.owner_artifacts[0]
        path = self.root / source.relative_path
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(ReceiptEmissionError, "mutated at final fence"):
            adapter._fence(admission, snapshots, {})

    def test_snapshot_fences_ancestor_identity_even_when_file_inode_survives(self):
        parent = self.root / "nested"
        parent.mkdir()
        file = parent / "proof.json"
        file.write_bytes(b"{}")
        before = adapter._snapshot(self.root, "nested/proof.json")
        former = self.root / "former"
        parent.rename(former)
        parent.mkdir()
        (former / "proof.json").rename(file)
        after = adapter._snapshot(self.root, "nested/proof.json")
        self.assertEqual(before[:3], after[:3])
        self.assertEqual(before[3][0][:2], after[3][0][:2])
        self.assertNotEqual(before, after)

    def test_noncanonical_json_is_not_admitted(self):
        _, admission = self.lens()
        source = admission.owner_artifacts[0]
        path = self.root / source.relative_path
        path.write_bytes(path.read_bytes() + b"\n")
        observations = tuple((s.command_output, (self.root / s.relative_path).read_bytes()) for s in admission.owner_artifacts)
        with self.assertRaisesRegex(ValueError, "not canonical"):
            self.outputs(replace(admission, retained_observations=observations))

    def test_forged_zero_counts_wrong_topics_and_wrong_lens_are_semantically_rejected(self):
        for mutation in ("findings", "scope_topics", "lens_id", "candidate_tree"):
            request, admission = self.lens()
            source = next(s for s in admission.owner_artifacts if s.kind is ArtifactKind.REVIEW_REPORT)
            path = self.root / source.relative_path
            document = decode_canonical_bytes(path.read_bytes())
            document[mutation] = {"findings": [{"finding_id": "blocking", "severity": "P1", "state": "open"}],
                                  "scope_topics": ["unrelated"], "lens_id": "unrelated", "candidate_tree": "0" * 40}[mutation]
            path.write_bytes(canonical_bytes(document))
            self.fixture._refresh_descriptor(request, path)
            with self.subTest(mutation=mutation), self.assertRaises(ReceiptEmissionError):
                _validate_legacy_physical_evidence(request, artifact_root=self.root, qualification_run_authority=QUALIFICATION_RUN)

    def test_real_aggregate_physical_validator_checks_four_lens_receipts(self):
        request = self.fixture._independent_review_request()
        receipt, _ = _validate_legacy_physical_evidence(request, artifact_root=self.root, qualification_run_authority=QUALIFICATION_RUN)
        self.assertEqual(len(receipt["constituents"]), 4)
        # Physical parser alone is deliberately insufficient: external aggregate
        # semantics also require independently replayed retained lens inputs.
        admission = self.admission(request)
        admission = replace(admission, reviewer_assignments=tuple((command, "reviewer-" + lens)
            for command, lens in INDEPENDENT_REVIEW_COMMAND_LENSES.items()))
        artifacts, documents, _ = self.outputs(admission)
        with self.assertRaisesRegex(ReceiptEmissionError, "independently replayed"):
            adapter._review_semantics(admission, artifacts, documents, ExecutionIntervalExpectation(1000, 3000))

    def test_prospective_and_postmerge_physical_fixtures_use_real_semantic_validators(self):
        for postmerge in (False, True):
            request = self.fixture._merge_authority_request(postmerge=postmerge)
            admission = self.admission(request)
            artifacts, documents, snapshots = self.outputs(admission)
            self.assertEqual(len(artifacts), 4)
            receipt, _ = _validate_legacy_physical_evidence(request, artifact_root=self.root, qualification_run_authority=QUALIFICATION_RUN)
            self.assertEqual(receipt["evidence_status"], "passed")
            if postmerge:
                with self.assertRaisesRegex(ReceiptEmissionError, "complete qualified"):
                    adapter._qualified_authority(admission)
            else:
                # Prospective observation precedes the decision whose source
                # root will include this receipt's digest. It cannot seal that
                # not-yet-created decision, and is not merge authorization.
                self.assertIsNone(adapter._qualified_authority(admission))
                self.assertIsNone(receipt["qualified_premerge_authority_sha256"])

    def test_prospective_physical_receipt_retains_empty_review_state_without_approval(self):
        request = self.fixture._merge_authority_request(postmerge=False)
        observation_path = self.root / "prospective-merge-observation.json"
        authority_path = self.root / "prospective-merge-authority.json"
        original_authority = decode_canonical_bytes(authority_path.read_bytes())
        observation = decode_canonical_bytes(observation_path.read_bytes())
        observation["reviews"] = []
        for decision in (None, "", "review_required"):
            with self.subTest(decision=decision):
                observation["review_decision"] = decision
                authority = dict(original_authority, review_decision=decision, approval_count=0,
                    reviews_sha256=canonical_sha256([]), observation_sha256=canonical_sha256(observation))
                for path, value in ((observation_path, observation), (authority_path, authority)):
                    path.write_bytes(canonical_bytes(value))
                    self.fixture._refresh_descriptor(request, path)
                receipt, _ = _validate_legacy_physical_evidence(request, artifact_root=self.root,
                    qualification_run_authority=QUALIFICATION_RUN)
                self.assertEqual(receipt["authority"]["review_decision"], decision)
                self.assertEqual(receipt["authority"]["approval_count"], 0)
                self.assertEqual(receipt["evidence_status"], "passed")

    def test_initial_unsealed_prospective_policy_is_closed_to_existing_subject_role_phase(self):
        request = self.fixture._merge_authority_request(postmerge=False)
        admission = self.admission(request)
        candidate = admission.execution.candidate
        alternatives = (
            replace(admission, qualification_phase=QualificationPhase.POSTMERGE),
            replace(admission, receipt_type=ReceiptType.POST_MERGE),
            replace(admission, execution=replace(admission.execution, candidate=replace(
                candidate, subject_kind=CandidateSubjectKind.CANDIDATE))),
            replace(admission, qualified_premerge_authority={"decision_status": "qualified-premerge"}),
        )
        for changed in alternatives:
            with self.subTest(phase=changed.qualification_phase, role=changed.receipt_type), \
                    self.assertRaisesRegex(ReceiptEmissionError, "complete qualified"):
                adapter._qualified_authority(changed)

    def test_postmerge_policy_rejects_unsealed_predecessor_even_with_retained_authority(self):
        from Scripts.reconstruction_gate_f.evidence_model import EvidenceReceiptInput
        from Scripts.reconstruction_gate_f.gate_evaluator import QualifiedPremergeAuthority
        request = self.fixture._merge_authority_request(postmerge=True)
        admission = self.admission(request)
        prospective = replace(admission.execution.candidate, subject_kind=CandidateSubjectKind.PROSPECTIVE_MERGE,
                              accepted_postmerge_commit=None, accepted_postmerge_tree=None)
        # A structurally valid retained expectation isolates the sealing policy;
        # this is not a favorable final qualification or public emission fixture.
        payload = dict(schema_version=2, qualification_run_id=QUALIFICATION_RUN.run_id,
            qualification_run_nonce=QUALIFICATION_RUN.nonce,
            prospective_candidate_identity_sha256=candidate_identity_sha256(prospective),
            source_contract_sha256="a" * 64, prerequisite_dag_sha256="b" * 64,
            evidence_partial_order_sha256="c" * 64, evidence_root_sha256="d" * 64,
            receipt_digests=(("receipt-review", "e" * 64),), command_plan_sha256="f" * 64,
            decision_status="qualified-premerge")
        authority = QualifiedPremergeAuthority(**payload, canonical_sha256=canonical_sha256(payload))
        self.assertEqual(canonical_sha256(payload), authority.canonical_sha256)
        predecessor = EvidenceReceiptInput({"qualified_premerge_authority_sha256": None}, None)
        with self.assertRaisesRegex(ReceiptEmissionError, "substituted the qualified"):
            adapter._qualified_authority(replace(admission, qualified_premerge_authority=authority,
                                                  predecessor_inputs=(predecessor,)))

    def test_postmerge_wrong_workflow_rejected_after_rehash(self):
        request = self.fixture._merge_authority_request(postmerge=True)
        path = self.root / "postmerge-workflow.json"
        workflow = decode_canonical_bytes(path.read_bytes())
        workflow["commit"] = "0" * 40
        path.write_bytes(canonical_bytes(workflow))
        self.fixture._refresh_descriptor(request, path)
        with self.assertRaises(ReceiptEmissionError):
            _validate_legacy_physical_evidence(request, artifact_root=self.root, qualification_run_authority=QUALIFICATION_RUN)

    def test_historical_t10c_remains_failed(self):
        request = self.fixture._t10c_current_source_request()
        receipt, _ = _validate_legacy_physical_evidence(request, artifact_root=self.root, qualification_run_authority=QUALIFICATION_RUN)
        self.assertEqual(receipt["evidence_status"], "failed")
        self.assertEqual(receipt["authority"]["unresolved_blocking_count"], 3)

    def test_genuine_sealed_source_closure_then_physical_mutation(self):
        from Scripts.source_export_provenance import create_export
        runtime = Path(adapter.__file__).resolve().parents[2]
        repository = self.root / "repository"
        repository.mkdir()
        for module in tuple(sys.modules.values()):
            filename = getattr(module, "__file__", None)
            if not filename or not str(filename).endswith(".py"):
                continue
            try:
                relative = Path(filename).resolve().relative_to(runtime)
            except ValueError:
                continue
            path = relative.as_posix()
            if not path.startswith("Scripts/") or "/tests/" in path or "/test_" in path:
                continue
            target = repository / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(runtime / relative, target)
        (repository / "THIRD_PARTY_COMPONENTS.yml").write_bytes(b'{"components":[]}\n')
        (repository / "THIRD_PARTY_NOTICES.md").write_bytes(b"Synthetic portable fixture notices\n")
        def git(*args):
            return subprocess.run(["git", *args], cwd=repository, check=True,
                                  capture_output=True, text=True).stdout.strip()
        git("init", "-q", "-b", "fixture")
        git("remote", "add", "github", "https://github.com/jdotc1/MacScope-app.git")
        git("add", ".")
        git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
        git("update-ref", "refs/remotes/github/fixture", "HEAD")
        export = self.root / "sealed"
        provenance = create_export(repository, export, "refs/remotes/github/fixture")
        _, admission = self.lens()
        candidate = replace(admission.execution.candidate, source=replace(admission.execution.candidate.source,
            commit=provenance["git_head_commit"], tree=provenance["git_head_tree"], dirty=False))
        execution = replace(admission.execution, candidate=candidate,
            integrated_plan_input=SimpleNamespace(inputs={"source_export_root": str(export),
                "integration_ref": "refs/remotes/github/fixture"}))
        snapshot = adapter._source_fence(execution)
        self.assertIn("Scripts/reconstruction_gate_f/external_authority_adapter.py", snapshot)
        target = export / "Scripts/reconstruction_gate_f/external_authority_adapter.py"
        target.write_bytes(target.read_bytes() + b"\n# changed source\n")
        with self.assertRaises((ValueError, RuntimeError)):
            adapter._source_fence(execution)


if __name__ == "__main__":
    unittest.main()
