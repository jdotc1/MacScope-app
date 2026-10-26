#!/usr/bin/env python3
"""Create and validate physical Gate F merge-authority evidence.

The merge and post-merge commands remain external-authority operations.  This
module never contacts a forge, mutates Git, or performs a merge.  It consumes
already captured observations, validates their exact candidate binding, and
creates canonical evidence files without overwriting existing evidence.
"""

from __future__ import annotations

import argparse
import os
import re
import stat
import sys
from dataclasses import replace
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts.reconstruction_gate_f.artifact_validator import (  # noqa: E402
    safe_relative_artifact_path,
)
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    CanonicalJSONError,
    canonical_bytes,
    canonical_sha256,
    load_canonical_json,
)
from Scripts.reconstruction_gate_f.schema import (  # noqa: E402
    CandidateIdentity,
    CandidateSubjectKind,
    STABLE_ID_RE,
    candidate_to_mapping,
    is_git_object,
    is_integer,
    is_sha256,
    parse_candidate_identity,
)


MERGE_AUTHORITY_SCHEMA_VERSION = 1
MAX_GOVERNED_FILES = 10_000
REPOSITORY_ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,128}/[A-Za-z0-9_.-]{1,128}$")
REF_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$")
STABLE_EXTERNAL_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$")

EXPECTED_PR_CHECKS = frozenset(
    {
        ("Governance", "Host-independent governance suite"),
        ("CI", "Build + CoreTests (Xcode 27, arm64)"),
    }
)
EXPECTED_POSTMERGE_WORKFLOW_NAME = "CI"
EXPECTED_POSTMERGE_JOB_NAME = "Build + CoreTests (Xcode 27, arm64)"
EXPECTED_POSTMERGE_EVENT = "push"

# Private single-Mac delivery does not require a separate forge approval.
# Keep normalized observations truthful; actual requested changes still block.
NONBLOCKING_REVIEW_DECISIONS = (None, "", "approved", "review_required")
NONBLOCKING_REVIEW_STATES = ("approved", "commented", "dismissed", "pending")

PROSPECTIVE_OBSERVATION_FIELDS = frozenset(
    {
        "schema_version",
        "evidence_kind",
        "observed_at_unix_ms",
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
        "reviews",
        "checks",
        "governed_diff_sha256",
        "governed_file_count",
    }
)
REVIEW_FIELDS = frozenset({"review_id", "reviewer_id", "commit", "state"})
CHECK_FIELDS = frozenset(
    {"workflow_name", "check_name", "run_id", "commit", "status", "conclusion"}
)
GOVERNED_DIFF_FIELDS = frozenset(
    {
        "schema_version",
        "base_commit",
        "head_commit",
        "merge_commit",
        "merge_tree",
        "files",
    }
)
GOVERNED_FILE_FIELDS = frozenset(
    {"path", "status", "previous_path", "base_sha256", "head_sha256"}
)
POSTMERGE_OBSERVATION_FIELDS = frozenset(
    {
        "schema_version",
        "evidence_kind",
        "observed_at_unix_ms",
        "repository_id",
        "pull_request_number",
        "base_ref",
        "head_ref",
        "prospective_merge_commit",
        "prospective_merge_tree",
        "postmerge_commit",
        "postmerge_tree",
        "merged",
        "merge_method",
        "workflow_observation_sha256",
    }
)
WORKFLOW_OBSERVATION_FIELDS = frozenset(
    {
        "schema_version",
        "repository_id",
        "workflow_name",
        "job_name",
        "event",
        "run_id",
        "run_attempt",
        "status",
        "conclusion",
        "commit",
        "tree",
    }
)


class MergeAuthorityEvidenceError(ValueError):
    """External merge evidence is malformed or belongs to another candidate."""


def _fail(message: str) -> None:
    raise MergeAuthorityEvidenceError(message)


def _closed(value: object, fields: frozenset[str], *, label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        _fail(f"{label} must carry the exact closed field set")
    return value


def _positive_integer(value: object, *, label: str) -> int:
    if not is_integer(value) or value < 1:
        _fail(f"{label} must be a positive integer")
    return value


def _nonnegative_integer(value: object, *, label: str) -> int:
    if not is_integer(value) or value < 0:
        _fail(f"{label} must be a nonnegative integer")
    return value


def _repository_id(value: object, *, label: str) -> str:
    if not isinstance(value, str) or REPOSITORY_ID_RE.fullmatch(value) is None:
        _fail(f"{label} must be an owner/repository identifier")
    return value


def _ref(value: object, *, label: str) -> str:
    if (
        not isinstance(value, str)
        or REF_RE.fullmatch(value) is None
        or ".." in value
        or value.endswith("/")
        or "//" in value
    ):
        _fail(f"{label} must be a canonical branch ref")
    return value


def _external_id(value: object, *, label: str) -> str:
    if not isinstance(value, str) or STABLE_EXTERNAL_ID_RE.fullmatch(value) is None:
        _fail(f"{label} must be a bounded stable external identifier")
    return value


def _git(value: object, *, label: str) -> str:
    if not is_git_object(value):
        _fail(f"{label} must be a lowercase 40-hex Git object")
    return value


def _sha(value: object, *, label: str, nullable: bool = False) -> str | None:
    if value is None and nullable:
        return None
    if not is_sha256(value):
        _fail(f"{label} must be a lowercase SHA-256")
    return value


def _parse_candidate(value: object) -> CandidateIdentity:
    candidate, issues = parse_candidate_identity(value)
    if candidate is None or issues:
        rendered = "; ".join(
            f"{item.code} at {item.path}: {item.message}" for item in issues
        )
        _fail(f"candidate identity is invalid: {rendered}")
    return candidate


def transition_to_prospective_candidate(
    candidate: CandidateIdentity,
    *,
    base_commit: str,
    base_tree: str,
    merge_commit: str,
    merge_tree: str,
) -> CandidateIdentity:
    """Bind a qualified branch-head candidate to one prospective merge object."""

    if candidate.subject_kind is not CandidateSubjectKind.CANDIDATE:
        _fail("only a branch-head candidate may transition to prospective-merge")
    for label, value in (
        ("base commit", base_commit),
        ("base tree", base_tree),
        ("merge commit", merge_commit),
        ("merge tree", merge_tree),
    ):
        _git(value, label=label)
    prospective = replace(
        candidate,
        subject_kind=CandidateSubjectKind.PROSPECTIVE_MERGE,
        source=replace(candidate.source, base_commit=base_commit, base_tree=base_tree),
        prospective_merge_commit=merge_commit,
        prospective_merge_tree=merge_tree,
        accepted_postmerge_commit=None,
        accepted_postmerge_tree=None,
    )
    return _parse_candidate(candidate_to_mapping(prospective))


def transition_to_postmerge_candidate(
    prospective: CandidateIdentity,
    *,
    postmerge_commit: str,
    postmerge_tree: str,
) -> CandidateIdentity:
    """Bind a qualified prospective candidate to the accepted merge identity."""

    if prospective.subject_kind is not CandidateSubjectKind.PROSPECTIVE_MERGE:
        _fail("only a prospective candidate may transition to post-merge")
    _git(postmerge_commit, label="postmerge commit")
    _git(postmerge_tree, label="postmerge tree")
    if postmerge_tree != prospective.prospective_merge_tree:
        _fail("accepted postmerge tree differs from the qualified prospective tree")
    postmerge = replace(
        prospective,
        subject_kind=CandidateSubjectKind.POST_MERGE,
        accepted_postmerge_commit=postmerge_commit,
        accepted_postmerge_tree=postmerge_tree,
    )
    return _parse_candidate(candidate_to_mapping(postmerge))


def _validate_reviews(value: object, *, head_commit: str) -> tuple[list[dict[str, Any]], str]:
    if not isinstance(value, list):
        _fail("prospective reviews must be an array")
    reviews: list[dict[str, Any]] = []
    identities: set[str] = set()
    for index, item in enumerate(value):
        review = _closed(item, REVIEW_FIELDS, label=f"review[{index}]")
        review_id = _external_id(review["review_id"], label=f"review[{index}].review_id")
        _external_id(review["reviewer_id"], label=f"review[{index}].reviewer_id")
        if review_id in identities:
            _fail("prospective observation contains duplicate review IDs")
        identities.add(review_id)
        if _git(review["commit"], label=f"review[{index}].commit") != head_commit:
            _fail("prospective review belongs to another head commit")
        if review["state"] not in NONBLOCKING_REVIEW_STATES:
            _fail("prospective review state is blocking or unknown")
        reviews.append(dict(review))
    if reviews != sorted(reviews, key=lambda item: str(item["review_id"])):
        _fail("prospective reviews must be sorted by review_id")
    return reviews, canonical_sha256(reviews)


def _validate_checks(value: object, *, head_commit: str) -> tuple[list[dict[str, Any]], str]:
    if not isinstance(value, list):
        _fail("prospective checks must be an array")
    checks: list[dict[str, Any]] = []
    observed: set[tuple[str, str]] = set()
    for index, item in enumerate(value):
        check = _closed(item, CHECK_FIELDS, label=f"check[{index}]")
        workflow_name = _external_id(
            check["workflow_name"], label=f"check[{index}].workflow_name"
        )
        check_name = check["check_name"]
        if not isinstance(check_name, str) or not check_name or len(check_name) > 255:
            _fail(f"check[{index}].check_name must be bounded nonempty text")
        identity = (workflow_name, check_name)
        if identity in observed:
            _fail("prospective observation contains duplicate required checks")
        observed.add(identity)
        _external_id(check["run_id"], label=f"check[{index}].run_id")
        if _git(check["commit"], label=f"check[{index}].commit") != head_commit:
            _fail("prospective check belongs to another head commit")
        if check["status"] != "completed" or check["conclusion"] != "success":
            _fail("prospective required check is not completed successfully")
        checks.append(dict(check))
    if observed != EXPECTED_PR_CHECKS:
        _fail("prospective observation does not carry the exact required PR checks")
    if checks != sorted(
        checks, key=lambda item: (str(item["workflow_name"]), str(item["check_name"]))
    ):
        _fail("prospective checks must be sorted by workflow and check name")
    return checks, canonical_sha256(checks)


def _validate_governed_diff(
    value: object,
    *,
    candidate: CandidateIdentity,
    merge_commit: str,
    merge_tree: str,
) -> tuple[dict[str, Any], int]:
    record = _closed(value, GOVERNED_DIFF_FIELDS, label="governed diff")
    if record["schema_version"] != MERGE_AUTHORITY_SCHEMA_VERSION:
        _fail("governed diff has an unsupported schema version")
    expected = {
        "base_commit": candidate.source.base_commit,
        "head_commit": candidate.source.commit,
        "merge_commit": merge_commit,
        "merge_tree": merge_tree,
    }
    for field, expected_value in expected.items():
        if _git(record[field], label=f"governed diff {field}") != expected_value:
            _fail(f"governed diff {field} belongs to another merge")
    files = record["files"]
    if not isinstance(files, list) or not files or len(files) > MAX_GOVERNED_FILES:
        _fail("governed diff files must be a bounded nonempty array")
    normalized: list[dict[str, Any]] = []
    paths: set[str] = set()
    for index, item in enumerate(files):
        entry = _closed(item, GOVERNED_FILE_FIELDS, label=f"governed file[{index}]")
        path = entry["path"]
        previous_path = entry["previous_path"]
        if not safe_relative_artifact_path(path):
            _fail(f"governed file[{index}].path is unsafe")
        if path in paths:
            _fail("governed diff contains duplicate destination paths")
        paths.add(path)
        status = entry["status"]
        if status not in {"added", "modified", "deleted", "renamed"}:
            _fail(f"governed file[{index}].status is outside the closed vocabulary")
        base_sha = _sha(
            entry["base_sha256"], label=f"governed file[{index}].base_sha256", nullable=True
        )
        head_sha = _sha(
            entry["head_sha256"], label=f"governed file[{index}].head_sha256", nullable=True
        )
        if status == "added" and (base_sha is not None or head_sha is None):
            _fail("added governed file must have only a head digest")
        if status == "deleted" and (base_sha is None or head_sha is not None):
            _fail("deleted governed file must have only a base digest")
        if status == "modified" and (
            base_sha is None or head_sha is None or base_sha == head_sha
        ):
            _fail("modified governed file must have distinct base and head digests")
        if status == "renamed":
            if not safe_relative_artifact_path(previous_path) or previous_path == path:
                _fail("renamed governed file requires a distinct safe previous path")
            if base_sha is None or head_sha is None:
                _fail("renamed governed file requires both content digests")
        elif previous_path is not None:
            _fail("only a renamed governed file may carry previous_path")
        normalized.append(dict(entry))
    if normalized != sorted(normalized, key=lambda item: str(item["path"])):
        _fail("governed diff files must be sorted by destination path")
    return dict(record), len(normalized)


def validate_prospective_evidence(
    candidate: CandidateIdentity,
    observation: object,
    governed_diff: object,
) -> dict[str, Any]:
    """Return the only authority record admitted by prospective physical evidence."""

    if candidate.subject_kind is not CandidateSubjectKind.PROSPECTIVE_MERGE:
        _fail("prospective evidence requires a prospective candidate")
    record = _closed(
        observation, PROSPECTIVE_OBSERVATION_FIELDS, label="prospective observation"
    )
    if record["schema_version"] != MERGE_AUTHORITY_SCHEMA_VERSION:
        _fail("prospective observation has an unsupported schema version")
    if record["evidence_kind"] != "prospective-merge":
        _fail("prospective observation has the wrong evidence kind")
    _nonnegative_integer(record["observed_at_unix_ms"], label="observation time")
    repository_id = _repository_id(record["repository_id"], label="repository_id")
    pull_request_number = _positive_integer(
        record["pull_request_number"], label="pull_request_number"
    )
    base_ref = _ref(record["base_ref"], label="base_ref")
    head_ref = _ref(record["head_ref"], label="head_ref")
    expected = {
        "base_commit": candidate.source.base_commit,
        "base_tree": candidate.source.base_tree,
        "head_commit": candidate.source.commit,
        "head_tree": candidate.source.tree,
        "merge_commit": candidate.prospective_merge_commit,
        "merge_tree": candidate.prospective_merge_tree,
    }
    for field, expected_value in expected.items():
        if _git(record[field], label=field) != expected_value:
            _fail(f"prospective observation {field} belongs to another candidate")
    if head_ref != candidate.source.branch_label:
        _fail("prospective observation head ref differs from candidate branch label")
    if record["parent_commits"] != [candidate.source.base_commit, candidate.source.commit]:
        _fail("prospective merge parents must be the ordered base and head commits")
    if record["mergeable"] is not True or record["merge_state"] != "clean":
        _fail("prospective merge is not in a clean mergeable state")
    if record["review_decision"] not in NONBLOCKING_REVIEW_DECISIONS:
        _fail("prospective merge review decision is blocking or unknown")
    reviews, reviews_sha256 = _validate_reviews(
        record["reviews"], head_commit=candidate.source.commit
    )
    checks, checks_sha256 = _validate_checks(
        record["checks"], head_commit=candidate.source.commit
    )
    diff, governed_file_count = _validate_governed_diff(
        governed_diff,
        candidate=candidate,
        merge_commit=str(candidate.prospective_merge_commit),
        merge_tree=str(candidate.prospective_merge_tree),
    )
    diff_sha256 = canonical_sha256(diff)
    if record["governed_diff_sha256"] != diff_sha256:
        _fail("prospective observation governed diff digest differs from physical diff")
    if record["governed_file_count"] != governed_file_count:
        _fail("prospective observation governed file count differs from physical diff")
    return {
        "repository_id": repository_id,
        "pull_request_number": pull_request_number,
        "base_ref": base_ref,
        "base_commit": candidate.source.base_commit,
        "base_tree": candidate.source.base_tree,
        "head_ref": head_ref,
        "head_commit": candidate.source.commit,
        "head_tree": candidate.source.tree,
        "merge_commit": candidate.prospective_merge_commit,
        "merge_tree": candidate.prospective_merge_tree,
        "parent_commits": [candidate.source.base_commit, candidate.source.commit],
        "mergeable": True,
        "merge_state": "clean",
        "review_decision": record["review_decision"],
        "approval_count": sum(review["state"] == "approved" for review in reviews),
        "reviews_sha256": reviews_sha256,
        "required_check_count": len(EXPECTED_PR_CHECKS),
        "successful_check_count": len(checks),
        "checks_sha256": checks_sha256,
        "governed_diff_sha256": diff_sha256,
        "governed_file_count": governed_file_count,
        "observation_sha256": canonical_sha256(record),
    }


def validate_postmerge_evidence(
    candidate: CandidateIdentity,
    observation: object,
    workflow_observation: object,
) -> dict[str, Any]:
    """Return the only authority record admitted by exact postmerge evidence."""

    if candidate.subject_kind is not CandidateSubjectKind.POST_MERGE:
        _fail("postmerge evidence requires a postmerge candidate")
    record = _closed(
        observation, POSTMERGE_OBSERVATION_FIELDS, label="postmerge observation"
    )
    workflow = _closed(
        workflow_observation,
        WORKFLOW_OBSERVATION_FIELDS,
        label="postmerge workflow observation",
    )
    if (
        record["schema_version"] != MERGE_AUTHORITY_SCHEMA_VERSION
        or workflow["schema_version"] != MERGE_AUTHORITY_SCHEMA_VERSION
    ):
        _fail("postmerge evidence has an unsupported schema version")
    if record["evidence_kind"] != "postmerge":
        _fail("postmerge observation has the wrong evidence kind")
    _nonnegative_integer(record["observed_at_unix_ms"], label="observation time")
    repository_id = _repository_id(record["repository_id"], label="repository_id")
    if _repository_id(workflow["repository_id"], label="workflow repository_id") != repository_id:
        _fail("postmerge workflow belongs to another repository")
    pull_request_number = _positive_integer(
        record["pull_request_number"], label="pull_request_number"
    )
    base_ref = _ref(record["base_ref"], label="base_ref")
    head_ref = _ref(record["head_ref"], label="head_ref")
    if head_ref != candidate.source.branch_label:
        _fail("postmerge head ref differs from candidate branch label")
    expected = {
        "prospective_merge_commit": candidate.prospective_merge_commit,
        "prospective_merge_tree": candidate.prospective_merge_tree,
        "postmerge_commit": candidate.accepted_postmerge_commit,
        "postmerge_tree": candidate.accepted_postmerge_tree,
    }
    for field, expected_value in expected.items():
        if _git(record[field], label=field) != expected_value:
            _fail(f"postmerge observation {field} belongs to another candidate")
    if record["merged"] is not True or record["merge_method"] != "merge":
        _fail("postmerge observation does not prove an accepted merge commit")
    workflow_sha256 = canonical_sha256(workflow)
    if record["workflow_observation_sha256"] != workflow_sha256:
        _fail("postmerge workflow digest differs from the physical workflow observation")
    if workflow["workflow_name"] != EXPECTED_POSTMERGE_WORKFLOW_NAME:
        _fail("postmerge workflow name is not authoritative")
    if workflow["job_name"] != EXPECTED_POSTMERGE_JOB_NAME:
        _fail("postmerge workflow job is not authoritative")
    if workflow["event"] != EXPECTED_POSTMERGE_EVENT:
        _fail("postmerge workflow event is not the required main push")
    run_id = _external_id(workflow["run_id"], label="workflow run_id")
    run_attempt = _positive_integer(workflow["run_attempt"], label="workflow run_attempt")
    if workflow["status"] != "completed" or workflow["conclusion"] != "success":
        _fail("postmerge authoritative workflow did not complete successfully")
    if _git(workflow["commit"], label="workflow commit") != candidate.accepted_postmerge_commit:
        _fail("postmerge workflow belongs to another commit")
    if _git(workflow["tree"], label="workflow tree") != candidate.accepted_postmerge_tree:
        _fail("postmerge workflow belongs to another tree")
    return {
        "repository_id": repository_id,
        "pull_request_number": pull_request_number,
        "base_ref": base_ref,
        "head_ref": head_ref,
        "prospective_merge_commit": candidate.prospective_merge_commit,
        "prospective_merge_tree": candidate.prospective_merge_tree,
        "postmerge_commit": candidate.accepted_postmerge_commit,
        "postmerge_tree": candidate.accepted_postmerge_tree,
        "workflow_run_id": run_id,
        "workflow_commit": candidate.accepted_postmerge_commit,
        "workflow_tree": candidate.accepted_postmerge_tree,
        "workflow_name": EXPECTED_POSTMERGE_WORKFLOW_NAME,
        "workflow_job_name": EXPECTED_POSTMERGE_JOB_NAME,
        "workflow_event": EXPECTED_POSTMERGE_EVENT,
        "workflow_status": "completed",
        "workflow_conclusion": "success",
        "workflow_run_attempt": run_attempt,
        "workflow_observation_sha256": workflow_sha256,
        "observation_sha256": canonical_sha256(record),
    }


def _create_only_json(path: Path, value: object) -> None:
    payload = canonical_bytes(value)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        remaining = memoryview(payload)
        while remaining:
            written = os.write(descriptor, remaining)
            if written <= 0:
                raise OSError("short write while creating merge-authority evidence")
            remaining = remaining[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _require_output_directory(path: Path) -> Path:
    if not path.is_absolute() or path.resolve(strict=True) != path:
        _fail("output directory must be an existing canonical absolute path")
    metadata = path.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or path.is_symlink():
        _fail("output directory must be an ordinary directory")
    return path


def create_evidence(
    *,
    kind: str,
    candidate_value: object,
    observation: object,
    secondary: object,
    output_directory: Path,
    qualification_run_id: str,
    qualification_run_nonce: str,
    predecessor_observations_sha256: str,
) -> tuple[Path, ...]:
    if STABLE_ID_RE.fullmatch(qualification_run_id) is None:
        _fail("qualification run ID must be a canonical stable ID")
    if not is_sha256(qualification_run_nonce):
        _fail("qualification run nonce must be a lowercase SHA-256")
    if not is_sha256(predecessor_observations_sha256):
        _fail("predecessor observations digest must be a lowercase SHA-256")
    candidate = _parse_candidate(candidate_value)
    output_directory = _require_output_directory(output_directory)
    if kind == "prospective":
        authority = validate_prospective_evidence(candidate, observation, secondary)
        prefix = "prospective-merge"
        secondary_name = f"{prefix}-governed-diff.json"
    elif kind == "postmerge":
        authority = validate_postmerge_evidence(candidate, observation, secondary)
        prefix = "postmerge"
        secondary_name = f"{prefix}-workflow.json"
    else:
        _fail("evidence kind must be prospective or postmerge")
    observed_at = int(dict(observation)["observed_at_unix_ms"])
    outputs = (
        (output_directory / f"{prefix}-observation.json", observation),
        (output_directory / secondary_name, secondary),
        (output_directory / f"{prefix}-authority.json", authority),
        (
            output_directory / f"{prefix}-execution-report.json",
            {
                "schema_version": 2,
                "qualification_run": {
                    "run_id": qualification_run_id,
                    "nonce": qualification_run_nonce,
                },
                "predecessor_observations_sha256": (
                    predecessor_observations_sha256
                ),
                "started_at_unix_ms": observed_at,
                "ended_at_unix_ms": observed_at,
                "result": "passed",
                "exit_code": 0,
                "stress": None,
            },
        ),
    )
    if any(path.exists() or path.is_symlink() for path, _ in outputs):
        _fail("create-only evidence output already exists")
    created: list[Path] = []
    try:
        for path, value in outputs:
            _create_only_json(path, value)
            created.append(path)
    except OSError as error:
        for path in reversed(created):
            try:
                path.unlink()
            except OSError:
                pass
        _fail(f"cannot create merge-authority evidence: {error}")
    return tuple(path for path, _ in outputs)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Create validated Gate F merge-authority evidence without contacting a forge."
    )
    subparsers = parser.add_subparsers(dest="kind", required=True)
    for kind in ("prospective", "postmerge"):
        child = subparsers.add_parser(kind)
        child.add_argument("--candidate", required=True, type=Path)
        child.add_argument("--observation", required=True, type=Path)
        child.add_argument(
            "--governed-diff" if kind == "prospective" else "--workflow-observation",
            dest="secondary",
            required=True,
            type=Path,
        )
        child.add_argument("--output-directory", required=True, type=Path)
        child.add_argument("--qualification-run-id", required=True)
        child.add_argument("--qualification-run-nonce", required=True)
        child.add_argument("--predecessor-observations-sha256", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        paths = create_evidence(
            kind=arguments.kind,
            candidate_value=load_canonical_json(arguments.candidate),
            observation=load_canonical_json(arguments.observation),
            secondary=load_canonical_json(arguments.secondary),
            output_directory=arguments.output_directory,
            qualification_run_id=arguments.qualification_run_id,
            qualification_run_nonce=arguments.qualification_run_nonce,
            predecessor_observations_sha256=(
                arguments.predecessor_observations_sha256
            ),
        )
    except (CanonicalJSONError, MergeAuthorityEvidenceError, OSError) as error:
        print(f"Gate F merge-authority evidence creation failed: {error}", file=sys.stderr)
        return 1
    for path in paths:
        print(f"Gate F merge-authority artifact: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
