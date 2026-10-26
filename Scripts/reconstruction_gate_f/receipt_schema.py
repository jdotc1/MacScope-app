"""Closed Gate F receipt and artifact record schemas."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from .canonical_json import canonical_sha256
from .schema import ArtifactKind, EvidenceLayer, ReceiptType

RECEIPT_SCHEMA_VERSION = 4
ARTIFACT_SCHEMA_VERSION = 1
MAX_DIAGNOSTIC_UTF8_BYTES = 1024

RECEIPT_FIELDS = frozenset(
    {
        "schema_version",
        "receipt_id",
        "receipt_type",
        "evidence_layer",
        "evidence_status",
        "qualification_phase",
        "qualification_run",
        "candidate_identity",
        "candidate_identity_sha256",
        "requirement_id",
        "command_id",
        "scenario_id",
        "command_plan_sha256",
        "command_record_sha256",
        "runtime_resolution",
        "qualified_premerge_authority_sha256",
        "attempt",
        "execution_interval",
        "executor",
        "command_authority",
        "artifacts",
        "constituents",
        "skips",
        "diagnostic",
        "authority",
        "canonical_sha256",
    }
)
EXECUTION_INTERVAL_FIELDS = frozenset(
    {"started_at_unix_ms", "ended_at_unix_ms"}
)
ARTIFACT_FIELDS = frozenset(
    {
        "schema_version",
        "artifact_id",
        "candidate_identity_sha256",
        "evidence_layer",
        "root_id",
        "relative_path",
        "kind",
        "media_type",
        "byte_count",
        "sha256",
        "producer_receipt_id",
        "command_id",
        "command_output",
    }
)
CONSTITUENT_FIELDS = frozenset(
    {"selector_id", "status", "evidence_layer", "candidate_identity_sha256", "artifact_ids"}
)
SKIP_FIELDS = frozenset(
    {
        "skip_id",
        "selector_id",
        "evidence_layer",
        "scenario_id",
        "reason_code",
        "reason_text_sha256",
        "source_commit",
        "source_tree",
        "source_contract_sha256",
        "selector_catalog_sha256",
        "authorization_sha256",
    }
)
EXECUTOR_FIELDS = frozenset(
    {"executor_id", "host", "platform", "architecture", "os_version"}
)
COMMAND_AUTHORITY_FIELDS = frozenset(
    {
        "host",
        "execution_mode",
        "argv_sha256",
        "working_directory_sha256",
        "environment_sha256",
        "generated_artifacts",
        "generated_logs",
        "prerequisite_receipts",
    }
)
COMMAND_PREREQUISITE_FIELDS = frozenset(
    {
        "command_id",
        "receipt_id",
        "canonical_sha256",
        "qualification_run_id",
        "qualification_run_nonce",
    }
)
QUALIFICATION_RUN_FIELDS = frozenset({"run_id", "nonce"})

AUTHORITY_FIELDS: Mapping[ReceiptType, frozenset[str]] = {
    ReceiptType.COMMAND_EXECUTION: frozenset({"run_id", "argv_sha256", "exit_code"}),
    ReceiptType.TEST_RESULT: frozenset(
        {
            "selector_catalog_sha256",
            "expected_selector_count",
            "executed_selector_count",
            "passed_selector_count",
            "failed_selector_count",
            "skipped_selector_count",
        }
    ),
    ReceiptType.ALLOWED_SKIP: frozenset({"skip_catalog_sha256", "skip_count"}),
    ReceiptType.ARTIFACT_MANIFEST: frozenset({"artifact_count", "artifact_manifest_sha256"}),
    ReceiptType.NATIVE_SANITIZER: frozenset({"sanitizer", "test_count", "failed_count"}),
    ReceiptType.SIGNED_XPC: frozenset(
        {
            "service_identity_id",
            "service_bundle_id",
            "service_executable_sha256",
            "selector_count",
            "failed_count",
            "failure_stage",
            "failure_reason",
        }
    ),
    ReceiptType.RELEASE_BUILD: frozenset(
        {"bundle_sha256", "closed_tree_sha256", "executable_sha256"}
    ),
    ReceiptType.STRICT_SIGNING: frozenset(
        {
            "signing_certificate_sha256",
            "signing_subject_sha256",
            "team_identifier",
            "entitlements_sha256",
            "designated_requirement_sha256",
            "hardened_runtime",
        }
    ),
    ReceiptType.INSTALLED_SOURCE_EQUALITY: frozenset(
        {
            "release_bundle_sha256",
            "release_closed_tree_sha256",
            "release_root_mode",
            "release_executable_sha256",
            "installed_bundle_sha256",
            "installed_closed_tree_sha256",
            "installed_root_mode",
            "installed_executable_sha256",
        }
    ),
    ReceiptType.INSTALLED_LAUNCH_LOG: frozenset(
        {"app_bundle_id", "app_executable_sha256", "launch_exit_code", "launch_log_sha256"}
    ),
    ReceiptType.INSTALLED_WORKFLOW: frozenset(
        {"app_bundle_id", "app_executable_sha256", "selector_count", "failed_count", "skipped_count"}
    ),
    ReceiptType.INSTALLED_ACCESSIBILITY: frozenset(
        {"app_bundle_id", "app_executable_sha256", "selector_count", "failed_count", "skipped_count"}
    ),
    ReceiptType.STRESS_RECOVERY: frozenset(
        {
            "expected_attempt_count",
            "observed_attempt_count",
            "attempt_seeds",
            "seed_catalog_sha256",
            "failed_count",
        }
    ),
    ReceiptType.INDEPENDENT_REVIEW: frozenset(
        {"review_commit", "review_tree", "p0_count", "p1_count", "p2_count", "p3_count", "unresolved_blocking_count"}
    ),
    ReceiptType.PROSPECTIVE_MERGE_TREE: frozenset(
        {
            "repository_id",
            "pull_request_number",
            "base_ref",
            "base_commit",
            "base_tree",
            "head_ref",
            "head_commit",
            "head_tree",
            "merge_commit",
            "merge_tree",
            "parent_commits",
            "mergeable",
            "merge_state",
            "review_decision",
            "approval_count",
            "reviews_sha256",
            "required_check_count",
            "successful_check_count",
            "checks_sha256",
            "governed_diff_sha256",
            "governed_file_count",
            "observation_sha256",
        }
    ),
    ReceiptType.POST_MERGE: frozenset(
        {
            "prospective_merge_commit",
            "prospective_merge_tree",
            "postmerge_commit",
            "postmerge_tree",
            "workflow_run_id",
            "workflow_commit",
            "workflow_tree",
            "workflow_name",
            "workflow_job_name",
            "workflow_event",
            "workflow_status",
            "workflow_conclusion",
            "workflow_run_attempt",
            "workflow_observation_sha256",
            "repository_id",
            "pull_request_number",
            "base_ref",
            "head_ref",
            "observation_sha256",
        }
    ),
    ReceiptType.FINAL_DECISION: frozenset(
        {
            "decision_status",
            "unresolved_p0_count",
            "unresolved_p1_count",
            "unresolved_p2_count",
            "required_receipt_count",
            "valid_receipt_count",
        }
    ),
}

ALL_LAYERS = frozenset(EvidenceLayer)
RECEIPT_LAYER_BINDINGS: Mapping[ReceiptType, frozenset[EvidenceLayer]] = {
    ReceiptType.COMMAND_EXECUTION: ALL_LAYERS,
    ReceiptType.TEST_RESULT: frozenset(
        {
            EvidenceLayer.HOSTED_PURE,
            EvidenceLayer.NATIVE_NORMAL,
            EvidenceLayer.XCODE_FOCUSED,
            EvidenceLayer.XCODE_FULL_CORETESTS,
            EvidenceLayer.SIGNED_XPC,
            EvidenceLayer.INSTALLED_WORKFLOW,
            EvidenceLayer.INSTALLED_ACCESSIBILITY,
            EvidenceLayer.STRESS_RECOVERY,
            EvidenceLayer.POST_MERGE,
        }
    ),
    ReceiptType.ALLOWED_SKIP: ALL_LAYERS,
    ReceiptType.ARTIFACT_MANIFEST: ALL_LAYERS,
    ReceiptType.NATIVE_SANITIZER: frozenset(
        {EvidenceLayer.NATIVE_ASAN, EvidenceLayer.NATIVE_UBSAN}
    ),
    ReceiptType.SIGNED_XPC: frozenset({EvidenceLayer.SIGNED_XPC}),
    ReceiptType.RELEASE_BUILD: frozenset({EvidenceLayer.RELEASE_BUILD}),
    ReceiptType.STRICT_SIGNING: frozenset({EvidenceLayer.STRICT_SIGNING}),
    ReceiptType.INSTALLED_SOURCE_EQUALITY: frozenset({EvidenceLayer.INSTALLED_SOURCE_EQUALITY}),
    ReceiptType.INSTALLED_LAUNCH_LOG: frozenset({EvidenceLayer.INSTALLED_LAUNCH_LOG}),
    ReceiptType.INSTALLED_WORKFLOW: frozenset({EvidenceLayer.INSTALLED_WORKFLOW}),
    ReceiptType.INSTALLED_ACCESSIBILITY: frozenset({EvidenceLayer.INSTALLED_ACCESSIBILITY}),
    ReceiptType.STRESS_RECOVERY: frozenset({EvidenceLayer.STRESS_RECOVERY}),
    ReceiptType.INDEPENDENT_REVIEW: frozenset({EvidenceLayer.INDEPENDENT_REVIEW}),
    ReceiptType.PROSPECTIVE_MERGE_TREE: frozenset({EvidenceLayer.PROSPECTIVE_MERGE_TREE}),
    ReceiptType.POST_MERGE: frozenset({EvidenceLayer.POST_MERGE}),
    ReceiptType.FINAL_DECISION: frozenset(
        {EvidenceLayer.PROSPECTIVE_MERGE_TREE, EvidenceLayer.POST_MERGE}
    ),
}

REQUIRED_ARTIFACT_KINDS: Mapping[EvidenceLayer, frozenset[ArtifactKind]] = {
    EvidenceLayer.SOURCE_GOVERNANCE: frozenset({ArtifactKind.JSON}),
    EvidenceLayer.HOSTED_PURE: frozenset({ArtifactKind.TEST_RESULTS}),
    EvidenceLayer.NATIVE_NORMAL: frozenset({ArtifactKind.TEST_RESULTS}),
    EvidenceLayer.NATIVE_ASAN: frozenset({ArtifactKind.SANITIZER_REPORT}),
    EvidenceLayer.NATIVE_UBSAN: frozenset({ArtifactKind.SANITIZER_REPORT}),
    EvidenceLayer.XCODE_FOCUSED: frozenset({ArtifactKind.XCRESULT}),
    EvidenceLayer.XCODE_FULL_CORETESTS: frozenset({ArtifactKind.XCRESULT}),
    EvidenceLayer.SIGNED_XPC: frozenset(
        {ArtifactKind.TEST_RESULTS, ArtifactKind.SIGNED_EXECUTABLE}
    ),
    EvidenceLayer.RELEASE_BUILD: frozenset({ArtifactKind.APP_BUNDLE}),
    EvidenceLayer.STRICT_SIGNING: frozenset({ArtifactKind.SIGNING_REPORT}),
    EvidenceLayer.INSTALLED_SOURCE_EQUALITY: frozenset(
        {ArtifactKind.SOURCE_EQUALITY_REPORT}
    ),
    EvidenceLayer.INSTALLED_LAUNCH_LOG: frozenset({ArtifactKind.LAUNCH_LOG}),
    EvidenceLayer.INSTALLED_WORKFLOW: frozenset({ArtifactKind.WORKFLOW_REPORT}),
    EvidenceLayer.INSTALLED_ACCESSIBILITY: frozenset(
        {ArtifactKind.ACCESSIBILITY_REPORT}
    ),
    EvidenceLayer.STRESS_RECOVERY: frozenset({ArtifactKind.STRESS_REPORT}),
    EvidenceLayer.INDEPENDENT_REVIEW: frozenset({ArtifactKind.REVIEW_REPORT}),
    EvidenceLayer.PROSPECTIVE_MERGE_TREE: frozenset({ArtifactKind.MERGE_PROOF}),
    EvidenceLayer.POST_MERGE: frozenset(
        {ArtifactKind.MERGE_PROOF, ArtifactKind.TEST_RESULTS}
    ),
}


def receipt_payload(receipt: Mapping[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in receipt.items() if key != "canonical_sha256"}


def seal_receipt(receipt: Mapping[str, Any]) -> dict[str, Any]:
    sealed = dict(receipt)
    sealed["canonical_sha256"] = canonical_sha256(receipt_payload(sealed))
    return sealed


def skip_payload(skip: Mapping[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in skip.items() if key != "authorization_sha256"}


def seal_skip(skip: Mapping[str, Any]) -> dict[str, Any]:
    sealed = dict(skip)
    sealed["authorization_sha256"] = canonical_sha256(skip_payload(sealed))
    return sealed
