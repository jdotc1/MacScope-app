from __future__ import annotations

import tempfile
import unittest
from copy import deepcopy
from pathlib import Path

from Scripts.reconstruction_gate_f.canonical_json import canonical_sha256, load_canonical_json
from Scripts.reconstruction_gate_f.merge_authority_evidence import (
    MergeAuthorityEvidenceError,
    create_evidence,
    transition_to_postmerge_candidate,
    transition_to_prospective_candidate,
    validate_postmerge_evidence,
    validate_prospective_evidence,
)
from Scripts.reconstruction_gate_f.schema import candidate_to_mapping
from Scripts.reconstruction_gate_f.tests import git_object, parsed_candidate, sha


def prospective_fixture():
    candidate = transition_to_prospective_candidate(
        parsed_candidate(),
        base_commit=git_object("5"),
        base_tree=git_object("6"),
        merge_commit=git_object("7"),
        merge_tree=git_object("8"),
    )
    governed_diff = {
        "schema_version": 1,
        "base_commit": candidate.source.base_commit,
        "head_commit": candidate.source.commit,
        "merge_commit": candidate.prospective_merge_commit,
        "merge_tree": candidate.prospective_merge_tree,
        "files": [
            {
                "path": "MacScope/Stores/WorkspaceStore.swift",
                "status": "modified",
                "previous_path": None,
                "base_sha256": sha("1"),
                "head_sha256": sha("2"),
            }
        ],
    }
    observation = {
        "schema_version": 1,
        "evidence_kind": "prospective-merge",
        "observed_at_unix_ms": 1_000,
        "repository_id": "jdotc1/MacScope-app",
        "pull_request_number": 233,
        "base_ref": "main",
        "base_commit": candidate.source.base_commit,
        "base_tree": candidate.source.base_tree,
        "head_ref": candidate.source.branch_label,
        "head_commit": candidate.source.commit,
        "head_tree": candidate.source.tree,
        "merge_commit": candidate.prospective_merge_commit,
        "merge_tree": candidate.prospective_merge_tree,
        "parent_commits": [candidate.source.base_commit, candidate.source.commit],
        "mergeable": True,
        "merge_state": "clean",
        "review_decision": "approved",
        "reviews": [
            {
                "review_id": "review-1",
                "reviewer_id": "reviewer-1",
                "commit": candidate.source.commit,
                "state": "approved",
            }
        ],
        "checks": [
            {
                "workflow_name": "CI",
                "check_name": "Build + CoreTests (Xcode 27, arm64)",
                "run_id": "run-ci-1",
                "commit": candidate.source.commit,
                "status": "completed",
                "conclusion": "success",
            },
            {
                "workflow_name": "Governance",
                "check_name": "Host-independent governance suite",
                "run_id": "run-governance-1",
                "commit": candidate.source.commit,
                "status": "completed",
                "conclusion": "success",
            },
        ],
        "governed_diff_sha256": canonical_sha256(governed_diff),
        "governed_file_count": 1,
    }
    return candidate, observation, governed_diff


def postmerge_fixture():
    prospective, _, _ = prospective_fixture()
    candidate = transition_to_postmerge_candidate(
        prospective,
        postmerge_commit=git_object("9"),
        postmerge_tree=str(prospective.prospective_merge_tree),
    )
    workflow = {
        "schema_version": 1,
        "repository_id": "jdotc1/MacScope-app",
        "workflow_name": "CI",
        "job_name": "Build + CoreTests (Xcode 27, arm64)",
        "event": "push",
        "run_id": "run-postmerge-1",
        "run_attempt": 1,
        "status": "completed",
        "conclusion": "success",
        "commit": candidate.accepted_postmerge_commit,
        "tree": candidate.accepted_postmerge_tree,
    }
    observation = {
        "schema_version": 1,
        "evidence_kind": "postmerge",
        "observed_at_unix_ms": 2_000,
        "repository_id": "jdotc1/MacScope-app",
        "pull_request_number": 233,
        "base_ref": "main",
        "head_ref": candidate.source.branch_label,
        "prospective_merge_commit": candidate.prospective_merge_commit,
        "prospective_merge_tree": candidate.prospective_merge_tree,
        "postmerge_commit": candidate.accepted_postmerge_commit,
        "postmerge_tree": candidate.accepted_postmerge_tree,
        "merged": True,
        "merge_method": "merge",
        "workflow_observation_sha256": canonical_sha256(workflow),
    }
    return candidate, observation, workflow


class MergeAuthorityEvidenceTests(unittest.TestCase):
    def test_no_review_decision_or_reviews_creates_truthful_private_merge_evidence(self) -> None:
        for decision in (None, "", "review_required"):
            with self.subTest(decision=decision):
                candidate, observation, governed_diff = prospective_fixture()
                observation.update(review_decision=decision, reviews=[])
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary).resolve(strict=True)
                    create_evidence(
                        kind="prospective", candidate_value=candidate_to_mapping(candidate),
                        observation=observation, secondary=governed_diff, output_directory=root,
                        qualification_run_id="gate-f-qualification-20260828",
                        qualification_run_nonce=sha("9"),
                        predecessor_observations_sha256=canonical_sha256([]),
                    )
                    authority = load_canonical_json(root / "prospective-merge-authority.json")
                    self.assertEqual(authority["review_decision"], decision)
                    self.assertEqual(authority["approval_count"], 0)
                    self.assertEqual(authority["reviews_sha256"], canonical_sha256([]))
                    self.assertEqual(load_canonical_json(root / "prospective-merge-observation.json"), observation)

    def test_nonblocking_review_rows_are_retained_and_only_actual_approvals_count(self) -> None:
        candidate, observation, governed_diff = prospective_fixture()
        observation["review_decision"] = ""
        observation["reviews"] = [dict(observation["reviews"][0], review_id=f"review-{index}", state=state)
            for index, state in enumerate(("approved", "commented", "dismissed", "pending"))]
        before = deepcopy(observation)
        authority = validate_prospective_evidence(candidate, observation, governed_diff)
        self.assertEqual(authority["review_decision"], "")
        self.assertEqual(authority["approval_count"], 1)
        self.assertEqual(authority["reviews_sha256"], canonical_sha256(before["reviews"]))
        self.assertEqual(observation, before)

    def test_actual_blocking_or_unknown_review_states_remain_rejected(self) -> None:
        for decision, state in (("changes_requested", "approved"), (None, "changes_requested"),
                                ([], "approved"), ("unknown", "approved"), (None, "unknown")):
            candidate, observation, governed_diff = prospective_fixture()
            observation["review_decision"] = decision
            observation["reviews"][0]["state"] = state
            with self.subTest(decision=decision, state=state), self.assertRaises(MergeAuthorityEvidenceError):
                validate_prospective_evidence(candidate, observation, governed_diff)

    def test_no_approval_does_not_relax_clean_merge_checks_or_exact_source_binding(self) -> None:
        candidate, base, governed_diff = prospective_fixture()
        base.update(review_decision=None, reviews=[])
        mutations = (
            ("merge_state", "blocked"), ("mergeable", False),
            ("head_commit", git_object("a")), ("head_tree", git_object("a")),
            ("merge_tree", git_object("a")), ("parent_commits", list(reversed(base["parent_commits"]))),
            ("checks", []),
        )
        for field, value in mutations:
            observation = deepcopy(base)
            observation[field] = value
            with self.subTest(field=field), self.assertRaises(MergeAuthorityEvidenceError):
                validate_prospective_evidence(candidate, observation, governed_diff)
        for check_index in range(2):
            for field, value in (("conclusion", "failure"), ("commit", git_object("a"))):
                observation = deepcopy(base)
                observation["checks"][check_index][field] = value
                with self.subTest(check=check_index, field=field), self.assertRaises(MergeAuthorityEvidenceError):
                    validate_prospective_evidence(candidate, observation, governed_diff)

    def test_prospective_authority_is_derived_from_exact_governed_diff(self) -> None:
        candidate, observation, governed_diff = prospective_fixture()
        authority = validate_prospective_evidence(candidate, observation, governed_diff)
        self.assertEqual(authority["governed_diff_sha256"], canonical_sha256(governed_diff))
        self.assertEqual(authority["parent_commits"], [candidate.source.base_commit, candidate.source.commit])
        self.assertEqual(authority["required_check_count"], 2)
        self.assertEqual(authority["review_decision"], "approved")
        self.assertEqual(authority["approval_count"], 1)

    def test_rejects_governed_diff_whose_bytes_are_not_the_observed_diff(self) -> None:
        candidate, observation, governed_diff = prospective_fixture()
        governed_diff["files"][0]["head_sha256"] = sha("3")
        with self.assertRaisesRegex(MergeAuthorityEvidenceError, "physical diff"):
            validate_prospective_evidence(candidate, observation, governed_diff)

    def test_rejects_failed_authoritative_postmerge_workflow(self) -> None:
        candidate, observation, workflow = postmerge_fixture()
        workflow["conclusion"] = "failure"
        observation["workflow_observation_sha256"] = canonical_sha256(workflow)
        with self.assertRaisesRegex(MergeAuthorityEvidenceError, "successfully"):
            validate_postmerge_evidence(candidate, observation, workflow)

    def test_rejects_authoritative_workflow_for_another_commit(self) -> None:
        candidate, observation, workflow = postmerge_fixture()
        workflow["commit"] = git_object("a")
        observation["workflow_observation_sha256"] = canonical_sha256(workflow)
        with self.assertRaisesRegex(MergeAuthorityEvidenceError, "another commit"):
            validate_postmerge_evidence(candidate, observation, workflow)

    def test_create_only_builder_writes_canonical_validated_evidence(self) -> None:
        candidate, observation, governed_diff = prospective_fixture()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(strict=True)
            paths = create_evidence(
                kind="prospective",
                candidate_value=candidate_to_mapping(candidate),
                observation=observation,
                secondary=governed_diff,
                output_directory=root,
                qualification_run_id="gate-f-qualification-20260828",
                qualification_run_nonce=sha("9"),
                predecessor_observations_sha256=canonical_sha256([]),
            )
            self.assertEqual(len(paths), 4)
            self.assertEqual(
                load_canonical_json(root / "prospective-merge-authority.json"),
                validate_prospective_evidence(candidate, observation, governed_diff),
            )
            with self.assertRaisesRegex(MergeAuthorityEvidenceError, "already exists"):
                create_evidence(
                    kind="prospective",
                    candidate_value=candidate_to_mapping(candidate),
                    observation=deepcopy(observation),
                    secondary=deepcopy(governed_diff),
                    output_directory=root,
                    qualification_run_id="gate-f-qualification-20260828",
                    qualification_run_nonce=sha("9"),
                    predecessor_observations_sha256=canonical_sha256([]),
                )

    def test_postmerge_transition_refuses_a_tree_other_than_the_qualified_tree(self) -> None:
        prospective, _, _ = prospective_fixture()
        with self.assertRaisesRegex(MergeAuthorityEvidenceError, "differs"):
            transition_to_postmerge_candidate(
                prospective,
                postmerge_commit=git_object("9"),
                postmerge_tree=git_object("a"),
            )


if __name__ == "__main__":
    unittest.main()
