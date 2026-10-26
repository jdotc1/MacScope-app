"""Closed, immutable source contract for Gate F prerequisite compilation.

The contract is deliberately supplied by the caller.  In particular, this
module never reads Git, the working tree, a branch name, or live program-state
files to manufacture authority for a Task 10 candidate.  Lane A's parsed
``CandidateIdentity`` remains the sole candidate identity authority.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from enum import Enum
from typing import Any

from .canonical_json import canonical_sha256, to_primitive
from .schema import (
    CandidateIdentity,
    STABLE_ID_RE,
    ValidationIssue,
    candidate_authority_mapping,
    candidate_identity_sha256,
    candidate_to_mapping,
    closed_record,
    enum_value,
    is_integer,
    is_sha256,
    parse_candidate_identity,
)

SOURCE_CONTRACT_SCHEMA_VERSION = 1


class PrerequisiteStatus(str, Enum):
    """Closed state vocabulary for a source-authority prerequisite."""

    NOT_RUN = "not-run"
    RUNNING = "running"
    UNAVAILABLE = "unavailable"
    FAILED = "failed"
    INVALID = "invalid"
    ACCEPTED = "accepted"


@dataclass(frozen=True)
class PrerequisiteAuthority:
    """Exact authority supplied for one prerequisite subject.

    ``identity_sha256`` binds the source/result identity adjudicated for the
    subject.  ``receipt_sha256`` binds the acceptance or failure receipt.  A
    reason is mandatory for an unavailable or non-success terminal state and
    forbidden for an accepted state, so absence cannot be disguised as a pass.
    """

    subject_id: str
    owner_id: str
    status: PrerequisiteStatus
    identity_sha256: str | None
    receipt_sha256: str | None
    reason_code: str | None


@dataclass(frozen=True)
class SourceContract:
    schema_version: int
    candidate: CandidateIdentity
    prospective_candidate: CandidateIdentity | None
    compiler_identity_sha256: str
    subjects: tuple[PrerequisiteAuthority, ...]


SOURCE_CONTRACT_FIELDS = frozenset(
    {
        "schema_version",
        "candidate_identity",
        "prospective_candidate_identity",
        "compiler_identity_sha256",
        "subjects",
    }
)
SUBJECT_FIELDS = frozenset(
    {
        "subject_id",
        "owner_id",
        "status",
        "identity_sha256",
        "receipt_sha256",
        "reason_code",
    }
)


def _stable_id(value: object, *, path: str) -> list[ValidationIssue]:
    if not isinstance(value, str) or STABLE_ID_RE.fullmatch(value) is None:
        return [
            ValidationIssue(
                "stable-id",
                path,
                "must be a canonical lowercase stable ID",
            )
        ]
    return []


def _nullable_sha256(value: object, *, path: str) -> list[ValidationIssue]:
    if value is None or is_sha256(value):
        return []
    return [ValidationIssue("sha256", path, "must be null or a lowercase 64-hex SHA-256")]


def _nullable_reason(value: object, *, path: str) -> list[ValidationIssue]:
    if value is None:
        return []
    if isinstance(value, str) and STABLE_ID_RE.fullmatch(value) is not None:
        return []
    return [
        ValidationIssue(
            "reason-code",
            path,
            "must be null or a canonical lowercase stable reason code",
        )
    ]


def _parse_subject(
    value: object,
    *,
    path: str,
) -> tuple[PrerequisiteAuthority | None, list[ValidationIssue]]:
    record, issues = closed_record(value, SUBJECT_FIELDS, path=path)
    if record is None or issues:
        return None, issues
    issues.extend(_stable_id(record["subject_id"], path=f"{path}.subject_id"))
    issues.extend(_stable_id(record["owner_id"], path=f"{path}.owner_id"))
    status, nested = enum_value(
        PrerequisiteStatus,
        record["status"],
        path=f"{path}.status",
    )
    issues.extend(nested)
    issues.extend(
        _nullable_sha256(record["identity_sha256"], path=f"{path}.identity_sha256")
    )
    issues.extend(
        _nullable_sha256(record["receipt_sha256"], path=f"{path}.receipt_sha256")
    )
    issues.extend(_nullable_reason(record["reason_code"], path=f"{path}.reason_code"))

    identity = record["identity_sha256"]
    receipt = record["receipt_sha256"]
    reason = record["reason_code"]
    if status is PrerequisiteStatus.ACCEPTED:
        if identity is None or receipt is None:
            issues.append(
                ValidationIssue(
                    "accepted-authority-incomplete",
                    path,
                    "accepted subject requires exact identity and receipt digests",
                )
            )
        if reason is not None:
            issues.append(
                ValidationIssue(
                    "accepted-authority-contradiction",
                    f"{path}.reason_code",
                    "accepted subject cannot carry a failure reason",
                )
            )
    elif status is PrerequisiteStatus.RUNNING:
        if identity is None or receipt is not None or reason is not None:
            issues.append(
                ValidationIssue(
                    "running-authority-contradiction",
                    path,
                    "running subject requires identity but no terminal receipt or reason",
                )
            )
    elif status in {PrerequisiteStatus.FAILED, PrerequisiteStatus.INVALID}:
        if identity is None or receipt is None or reason is None:
            issues.append(
                ValidationIssue(
                    "terminal-authority-incomplete",
                    path,
                    "failed or invalid subject requires identity, receipt, and reason",
                )
            )
    elif status is PrerequisiteStatus.UNAVAILABLE:
        if identity is not None or receipt is not None or reason is None:
            issues.append(
                ValidationIssue(
                    "unavailable-authority-contradiction",
                    path,
                    "unavailable subject requires only a reason",
                )
            )
    elif status is PrerequisiteStatus.NOT_RUN:
        if identity is not None or receipt is not None or reason is not None:
            issues.append(
                ValidationIssue(
                    "not-run-authority-contradiction",
                    path,
                    "not-run subject cannot carry identity, receipt, or reason",
                )
            )

    if issues or status is None:
        return None, issues
    return (
        PrerequisiteAuthority(
            subject_id=record["subject_id"],
            owner_id=record["owner_id"],
            status=status,
            identity_sha256=identity,
            receipt_sha256=receipt,
            reason_code=reason,
        ),
        [],
    )


def _validate_unique_subjects(
    subjects: Sequence[PrerequisiteAuthority],
    *,
    path: str,
) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    subject_ids: set[str] = set()
    owner_ids: set[str] = set()
    for index, subject in enumerate(subjects):
        if subject.subject_id in subject_ids:
            issues.append(
                ValidationIssue(
                    "duplicate-subject",
                    f"{path}[{index}].subject_id",
                    "subject ID must be unique",
                )
            )
        subject_ids.add(subject.subject_id)
        if subject.owner_id in owner_ids:
            issues.append(
                ValidationIssue(
                    "duplicate-ownership",
                    f"{path}[{index}].owner_id",
                    "one authority owner cannot own multiple prerequisite subjects",
                )
            )
        owner_ids.add(subject.owner_id)
    if not subjects:
        issues.append(
            ValidationIssue(
                "empty-prerequisites",
                path,
                "source contract must declare prerequisite subjects",
            )
        )
    return issues


def parse_source_contract(
    value: object,
    *,
    path: str = "$.source_contract",
) -> tuple[SourceContract | None, tuple[ValidationIssue, ...]]:
    record, issues = closed_record(value, SOURCE_CONTRACT_FIELDS, path=path)
    if record is None or issues:
        return None, tuple(sorted(set(issues)))

    if (
        not is_integer(record["schema_version"])
        or record["schema_version"] != SOURCE_CONTRACT_SCHEMA_VERSION
    ):
        issues.append(
            ValidationIssue(
                "schema-version",
                f"{path}.schema_version",
                "unsupported source-contract schema",
            )
        )

    candidate, nested = parse_candidate_identity(
        record["candidate_identity"],
        path=f"{path}.candidate_identity",
    )
    issues.extend(nested)
    prospective_candidate: CandidateIdentity | None = None
    raw_prospective_candidate = record["prospective_candidate_identity"]
    if raw_prospective_candidate is not None:
        prospective_candidate, nested = parse_candidate_identity(
            raw_prospective_candidate,
            path=f"{path}.prospective_candidate_identity",
        )
        issues.extend(nested)
    if not is_sha256(record["compiler_identity_sha256"]):
        issues.append(
            ValidationIssue(
                "sha256",
                f"{path}.compiler_identity_sha256",
                "must be a lowercase 64-hex SHA-256",
            )
        )

    subjects: list[PrerequisiteAuthority] = []
    raw_subjects = record["subjects"]
    if not isinstance(raw_subjects, list):
        issues.append(
            ValidationIssue("array-type", f"{path}.subjects", "must be an array")
        )
    else:
        for index, raw_subject in enumerate(raw_subjects):
            subject, nested = _parse_subject(
                raw_subject,
                path=f"{path}.subjects[{index}]",
            )
            issues.extend(nested)
            if subject is not None:
                subjects.append(subject)
        issues.extend(_validate_unique_subjects(subjects, path=f"{path}.subjects"))

    if candidate is not None:
        if candidate.subject_kind.value == "post-merge":
            if prospective_candidate is None:
                issues.append(
                    ValidationIssue(
                        "missing-prospective-candidate",
                        f"{path}.prospective_candidate_identity",
                        "post-merge source contract requires the validated prospective candidate",
                    )
                )
            else:
                if prospective_candidate.subject_kind.value != "prospective-merge":
                    issues.append(
                        ValidationIssue(
                            "prospective-candidate-phase",
                            f"{path}.prospective_candidate_identity.subject_kind",
                            "carry-forward candidate must be prospective-merge",
                        )
                    )
                prospective_lineage = candidate_authority_mapping(prospective_candidate)
                postmerge_lineage = candidate_authority_mapping(candidate)
                for mapping in (prospective_lineage, postmerge_lineage):
                    mapping.pop("subject_kind", None)
                    mapping.pop("accepted_postmerge_commit", None)
                    mapping.pop("accepted_postmerge_tree", None)
                if prospective_lineage != postmerge_lineage:
                    issues.append(
                        ValidationIssue(
                            "prospective-candidate-lineage-drift",
                            f"{path}.prospective_candidate_identity",
                            "prospective and post-merge candidates differ outside accepted-merge identity",
                        )
                    )
            if candidate.prospective_merge_tree != candidate.accepted_postmerge_tree:
                issues.append(
                    ValidationIssue(
                        "merge-tree-drift",
                        f"{path}.candidate_identity.accepted_postmerge_tree",
                        "accepted post-merge tree must equal the qualified prospective merge tree",
                    )
                )
        elif prospective_candidate is not None:
            issues.append(
                ValidationIssue(
                    "unexpected-prospective-candidate",
                    f"{path}.prospective_candidate_identity",
                    "only a post-merge contract may carry a prior prospective candidate",
                )
            )

    if issues or candidate is None:
        return None, tuple(sorted(set(issues)))
    return (
        SourceContract(
            schema_version=record["schema_version"],
            candidate=candidate,
            prospective_candidate=prospective_candidate,
            compiler_identity_sha256=record["compiler_identity_sha256"],
            subjects=tuple(sorted(subjects, key=lambda item: item.subject_id)),
        ),
        (),
    )


def source_contract_to_mapping(contract: SourceContract) -> dict[str, Any]:
    subjects: object = contract.subjects
    if isinstance(subjects, tuple) and all(
        isinstance(subject, PrerequisiteAuthority) for subject in subjects
    ):
        subjects = tuple(sorted(subjects, key=lambda subject: subject.subject_id))
    return {
        "schema_version": contract.schema_version,
        "candidate_identity": candidate_to_mapping(contract.candidate),
        "prospective_candidate_identity": (
            candidate_to_mapping(contract.prospective_candidate)
            if contract.prospective_candidate is not None
            else None
        ),
        "compiler_identity_sha256": contract.compiler_identity_sha256,
        "subjects": [to_primitive(subject) for subject in subjects]
        if isinstance(subjects, (tuple, list))
        else subjects,
    }


def source_contract_sha256(contract: SourceContract) -> str:
    """Return the canonical digest, including the supplied prerequisite states."""

    return canonical_sha256(source_contract_to_mapping(contract))


def source_contract_candidate_sha256(contract: SourceContract) -> str:
    """Return Lane A's mutable-branch-independent candidate authority digest."""

    return candidate_identity_sha256(contract.candidate)


def make_source_contract(
    candidate: CandidateIdentity,
    *,
    prospective_candidate: CandidateIdentity | None = None,
    compiler_identity_sha256: str,
    subjects: Sequence[PrerequisiteAuthority],
) -> tuple[SourceContract | None, tuple[ValidationIssue, ...]]:
    """Build through the closed parser so direct callers receive identical checks."""

    if not isinstance(subjects, (tuple, list)):
        return None, (
            ValidationIssue(
                "source-contract-subjects-type",
                "$.source_contract.subjects",
                "subjects must be a tuple or list of prerequisite authorities",
            ),
        )
    if any(not isinstance(subject, PrerequisiteAuthority) for subject in subjects):
        return None, (
            ValidationIssue(
                "source-contract-subject-type",
                "$.source_contract.subjects",
                "every subject must be a PrerequisiteAuthority",
            ),
        )
    try:
        mapping = {
            "schema_version": SOURCE_CONTRACT_SCHEMA_VERSION,
            "candidate_identity": candidate_to_mapping(candidate),
            "prospective_candidate_identity": (
                candidate_to_mapping(prospective_candidate)
                if prospective_candidate is not None
                else None
            ),
            "compiler_identity_sha256": compiler_identity_sha256,
            "subjects": [to_primitive(subject) for subject in subjects],
        }
    except (AttributeError, KeyError, RecursionError, TypeError, ValueError):
        return None, (
            ValidationIssue(
                "source-contract-construction",
                "$.source_contract",
                "source contract contains malformed public DTO values",
            ),
        )
    return parse_source_contract(mapping)


def subject_authorities(contract: SourceContract) -> Mapping[str, PrerequisiteAuthority]:
    if not isinstance(contract.subjects, tuple):
        return {}
    return {
        subject.subject_id: subject
        for subject in contract.subjects
        if isinstance(subject, PrerequisiteAuthority)
        and isinstance(subject.subject_id, str)
    }


__all__ = [
    "SOURCE_CONTRACT_SCHEMA_VERSION",
    "PrerequisiteAuthority",
    "PrerequisiteStatus",
    "SourceContract",
    "make_source_contract",
    "parse_source_contract",
    "source_contract_candidate_sha256",
    "source_contract_sha256",
    "source_contract_to_mapping",
    "subject_authorities",
]
