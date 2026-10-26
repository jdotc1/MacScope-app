"""Deterministic Gate F prerequisite DAG compiler.

The graph is a program contract, not an inference over Git history.  Every
node is paired with one supplied ``PrerequisiteAuthority`` and carries the
exact identity axes that must exist before that authority may claim progress.
"""

from __future__ import annotations

import heapq
import os
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, replace
from enum import Enum
from pathlib import Path
from types import MappingProxyType
from typing import Any

from .canonical_json import canonical_sha256
from .command_catalog import CampaignProfile, campaign_command_id
from .schema import (
    CandidateIdentity,
    CandidateSubjectKind,
    EvidenceLayer,
    STABLE_ID_RE,
    ValidationIssue,
    candidate_identity_sha256,
    is_sha256,
)
from .source_contract import (
    SOURCE_CONTRACT_SCHEMA_VERSION,
    PrerequisiteAuthority,
    PrerequisiteStatus,
    SourceContract,
    parse_source_contract,
    source_contract_sha256,
    source_contract_to_mapping,
    subject_authorities,
)

PREREQUISITE_NODE_SCHEMA_VERSION = 1

# Frozen independent projection of the Task 11 Lane C command authority.
# These are command *groups*, not invented command IDs.  The integrated
# compiler cross-checks them against ``CommandTemplate.command_groups``.
LANE_C_COMMAND_GROUP_IDS = frozenset(
    {
        "installed-accessibility",
        "installed-equality",
        "installed-launch",
        "installed-network-audit",
        "installed-task10",
        "merge-qualification",
        "native-asan",
        "native-golden",
        "native-normal",
        "native-ubsan",
        "postmerge-qualification",
        "reconstruction-concurrency",
        "reconstruction-persistence",
        "reconstruction-rounds",
        "reconstruction-session",
        "reconstruction-task10",
        "reconstruction-task8",
        "release",
        "signed-xpc-content",
        "signed-xpc-error-cancellation",
        "signed-xpc-supervision",
        "source-governance",
        "stress-recovery",
        "strict-signing",
        "task8-signed-worker",
    }
)
# Frozen independent projection of the Task 11 Lane C scenario/group
# authority.  Scenario semantics remain Lane C-owned; Lane B freezes the exact
# public axes that its evidence evaluator must authenticate before accepting
# scenario receipts.
LANE_C_SCENARIO_GROUPS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("durable.cancel-after-terminal-publication", ("reconstruction-concurrency", "stress-recovery")),
    ("durable.cancel-before-terminal-publication", ("reconstruction-concurrency", "stress-recovery")),
    ("durable.cancelled-waiter-skipped-delayed-removal", ("reconstruction-concurrency", "stress-recovery")),
    ("durable.concurrent-session-resolution-coalesces", ("reconstruction-session", "stress-recovery")),
    ("durable.conversion-overflow", ("reconstruction-concurrency",)),
    ("durable.correct-job-bound-scheduling", ("reconstruction-concurrency", "stress-recovery")),
    ("durable.foreign-job-authority-rejected", ("reconstruction-concurrency", "stress-recovery")),
    ("durable.insufficient-memory", ("reconstruction-concurrency", "stress-recovery")),
    ("durable.one-window-one-session", ("reconstruction-session", "stress-recovery")),
    ("durable.pause-resume-retire-lifecycle", ("reconstruction-concurrency", "stress-recovery")),
    ("durable.provider-width-memory-extreme", ("reconstruction-concurrency", "stress-recovery")),
    ("durable.provider-width-processor-extreme", ("reconstruction-concurrency", "stress-recovery")),
    ("durable.session-reset-fences-late-resolution", ("reconstruction-session", "stress-recovery")),
    ("durable.waiter-cancel-after-enqueue", ("reconstruction-concurrency", "stress-recovery")),
    ("durable.waiter-cancel-before-enqueue", ("reconstruction-concurrency", "stress-recovery")),
    ("durable.waiter-cancel-during-release", ("reconstruction-concurrency", "stress-recovery")),
    ("durable.waiter-cancel-during-removal", ("reconstruction-concurrency", "stress-recovery")),
    ("installed.accessibility", ("installed-accessibility",)),
    ("installed.launch-log", ("installed-launch",)),
    ("installed.no-unauthorized-network-or-acquisition", ("installed-network-audit",)),
    ("installed.source-binary-equality", ("installed-equality",)),
    ("installed.task10.cancel", ("installed-task10",)),
    ("installed.task10.create", ("installed-task10",)),
    ("installed.task10.pause", ("installed-task10",)),
    ("installed.task10.resume", ("installed-task10",)),
    ("installed.task10.start", ("installed-task10",)),
    ("matrix.pairwise.028869220a9f4870", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.06a4c0aa8d2761f3", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.072854cf468256a4", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.0cd6242276bb06e3", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.103d2b9ebee288d2", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.1b2b41f8797249dd", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.27abcc083a9d39d5", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.43af92c8f89f5f98", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.63ae34f37dc89b16", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.63c533d6e7c4ac17", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.69171215932fa289", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.79317e0805613a93", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.79a27b4dcf4f6e39", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.7dbc46434833af46", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.8d3389efc6490535", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.93090890967b6c1c", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.a02979f621f70123", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.aa55dc741bf123cf", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.b4288df86dccb0c7", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.b4b4d797bdc8224f", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.c19adf91d80cd19f", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.c6c496bb6289bc1e", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.eac612fc3d2daae3", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.eb47b61eea332a74", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.f492768863aeb19a", ("reconstruction-concurrency", "stress-recovery")),
    ("matrix.pairwise.fa3376b0a10485fd", ("reconstruction-concurrency", "stress-recovery")),
    ("merge.candidate-head-differs-from-receipt", ("merge-qualification",)),
    ("merge.governed-files-changed", ("merge-qualification",)),
    ("merge.prospective-tree-differs", ("merge-qualification",)),
    ("merge.workflow-success-wrong-sha", ("merge-qualification",)),
    ("native.asan", ("native-asan",)),
    ("native.golden", ("native-golden",)),
    ("native.governed-package-verification", ("native-normal",)),
    ("native.normal", ("native-normal",)),
    ("native.ubsan", ("native-ubsan",)),
    ("persistence.atomic-initial-transaction", ("reconstruction-persistence",)),
    ("persistence.checkpoint-frontier-revision-fencing", ("reconstruction-persistence",)),
    ("persistence.crash-recovery", ("reconstruction-persistence",)),
    ("persistence.creation-ordinal", ("reconstruction-persistence",)),
    ("persistence.duplicate-command-suppression", ("reconstruction-rounds",)),
    ("persistence.legacy-schema-compatibility", ("reconstruction-persistence",)),
    ("persistence.missing-model-pause-resume", ("reconstruction-rounds",)),
    ("persistence.save-reopen-restore", ("reconstruction-persistence",)),
    ("persistence.task-identity-verification", ("reconstruction-persistence",)),
    ("persistence.task9-multi-round-regression", ("reconstruction-rounds",)),
    ("persistence.terminal-cancel", ("reconstruction-rounds",)),
    ("persistence.terminal-failure", ("reconstruction-rounds",)),
    ("persistence.terminal-retire", ("reconstruction-rounds",)),
    ("persistence.terminal-success", ("reconstruction-rounds",)),
    ("postmerge.source-installed-binary-differs", ("postmerge-qualification",)),
    ("postmerge.stale-after-dependency-toolchain-movement", ("postmerge-qualification",)),
    ("race.cancel-removal-release-skip", ("reconstruction-concurrency", "stress-recovery")),
    ("race.cancel-terminal-reset-stale-revision", ("reconstruction-concurrency", "stress-recovery")),
    ("race.concurrent-resolution-reset-foreign-window", ("reconstruction-concurrency", "stress-recovery")),
    ("race.merge-tool-movement-stale-evidence", ("reconstruction-concurrency", "stress-recovery")),
    ("race.protocol-duplicate-reordered-post-terminal", ("reconstruction-concurrency", "stress-recovery")),
    ("race.resource-memory-processor-extreme-width", ("reconstruction-concurrency", "stress-recovery")),
    ("race.task10-old-scope-late-completion", ("reconstruction-concurrency", "stress-recovery")),
    ("release.build", ("release",)),
    ("release.embedded-service-identities", ("strict-signing",)),
    ("release.strict-signing", ("strict-signing",)),
    ("signed-xpc.cancellation", ("signed-xpc-error-cancellation",)),
    ("signed-xpc.complete", ("signed-xpc-content",)),
    ("signed-xpc.error", ("signed-xpc-error-cancellation",)),
    ("signed-xpc.truncated", ("signed-xpc-content",)),
    ("task10.accessibility.catalog", ("reconstruction-task10",)),
    ("task10.accessibility.roles-labels-values-actions", ("reconstruction-task10",)),
    ("task10.command.accepting-evidence.cancel", ("reconstruction-task10",)),
    ("task10.command.accepting-evidence.create", ("reconstruction-task10",)),
    ("task10.command.accepting-evidence.pause", ("reconstruction-task10",)),
    ("task10.command.accepting-evidence.resume", ("reconstruction-task10",)),
    ("task10.command.accepting-evidence.start", ("reconstruction-task10",)),
    ("task10.command.awaiting-model.cancel", ("reconstruction-task10",)),
    ("task10.command.awaiting-model.create", ("reconstruction-task10",)),
    ("task10.command.awaiting-model.pause", ("reconstruction-task10",)),
    ("task10.command.awaiting-model.resume", ("reconstruction-task10",)),
    ("task10.command.awaiting-model.start", ("reconstruction-task10",)),
    ("task10.command.cancelled.cancel", ("reconstruction-task10",)),
    ("task10.command.cancelled.create", ("reconstruction-task10",)),
    ("task10.command.cancelled.pause", ("reconstruction-task10",)),
    ("task10.command.cancelled.resume", ("reconstruction-task10",)),
    ("task10.command.cancelled.start", ("reconstruction-task10",)),
    ("task10.command.checkpointing.cancel", ("reconstruction-task10",)),
    ("task10.command.checkpointing.create", ("reconstruction-task10",)),
    ("task10.command.checkpointing.pause", ("reconstruction-task10",)),
    ("task10.command.checkpointing.resume", ("reconstruction-task10",)),
    ("task10.command.checkpointing.start", ("reconstruction-task10",)),
    ("task10.command.completed.cancel", ("reconstruction-task10",)),
    ("task10.command.completed.create", ("reconstruction-task10",)),
    ("task10.command.completed.pause", ("reconstruction-task10",)),
    ("task10.command.completed.resume", ("reconstruction-task10",)),
    ("task10.command.completed.start", ("reconstruction-task10",)),
    ("task10.command.created.cancel", ("reconstruction-task10",)),
    ("task10.command.created.create", ("reconstruction-task10",)),
    ("task10.command.created.pause", ("reconstruction-task10",)),
    ("task10.command.created.resume", ("reconstruction-task10",)),
    ("task10.command.created.start", ("reconstruction-task10",)),
    ("task10.command.executing-reads.cancel", ("reconstruction-task10",)),
    ("task10.command.executing-reads.create", ("reconstruction-task10",)),
    ("task10.command.executing-reads.pause", ("reconstruction-task10",)),
    ("task10.command.executing-reads.resume", ("reconstruction-task10",)),
    ("task10.command.executing-reads.start", ("reconstruction-task10",)),
    ("task10.command.failed.cancel", ("reconstruction-task10",)),
    ("task10.command.failed.create", ("reconstruction-task10",)),
    ("task10.command.failed.pause", ("reconstruction-task10",)),
    ("task10.command.failed.resume", ("reconstruction-task10",)),
    ("task10.command.failed.start", ("reconstruction-task10",)),
    ("task10.command.indexing.cancel", ("reconstruction-task10",)),
    ("task10.command.indexing.create", ("reconstruction-task10",)),
    ("task10.command.indexing.pause", ("reconstruction-task10",)),
    ("task10.command.indexing.resume", ("reconstruction-task10",)),
    ("task10.command.indexing.start", ("reconstruction-task10",)),
    ("task10.command.ingesting.cancel", ("reconstruction-task10",)),
    ("task10.command.ingesting.create", ("reconstruction-task10",)),
    ("task10.command.ingesting.pause", ("reconstruction-task10",)),
    ("task10.command.ingesting.resume", ("reconstruction-task10",)),
    ("task10.command.ingesting.start", ("reconstruction-task10",)),
    ("task10.command.paused.cancel", ("reconstruction-task10",)),
    ("task10.command.paused.create", ("reconstruction-task10",)),
    ("task10.command.paused.pause", ("reconstruction-task10",)),
    ("task10.command.paused.resume", ("reconstruction-task10",)),
    ("task10.command.paused.start", ("reconstruction-task10",)),
    ("task10.command.retrieving.cancel", ("reconstruction-task10",)),
    ("task10.command.retrieving.create", ("reconstruction-task10",)),
    ("task10.command.retrieving.pause", ("reconstruction-task10",)),
    ("task10.command.retrieving.resume", ("reconstruction-task10",)),
    ("task10.command.retrieving.start", ("reconstruction-task10",)),
    ("task10.creation.budget-min-max", ("reconstruction-task10",)),
    ("task10.creation.budget-out-of-range", ("reconstruction-task10",)),
    ("task10.creation.empty-objective", ("reconstruction-task10",)),
    ("task10.creation.empty-roots", ("reconstruction-task10",)),
    ("task10.creation.objective-byte-bound", ("reconstruction-task10",)),
    ("task10.creation.objective-normalization", ("reconstruction-task10",)),
    ("task10.creation.two-roots-canonical", ("reconstruction-task10",)),
    ("task10.creation.whitespace-objective", ("reconstruction-task10",)),
    ("task10.diagnostic.detail-bounds", ("reconstruction-task10",)),
    ("task10.diagnostic.reason-identity", ("reconstruction-task10",)),
    ("task10.multi-window-isolation", ("reconstruction-task10",)),
    ("task10.navigation.exact-source-coordinate", ("reconstruction-task10",)),
    ("task10.navigation.sibling-selection", ("reconstruction-task10",)),
    ("task10.navigation.stale-selection", ("reconstruction-task10",)),
    ("task10.provider.not-ready", ("reconstruction-task10",)),
    ("task10.provider.ready-busy", ("reconstruction-task10",)),
    ("task10.provider.ready-idle-valid-revision", ("reconstruction-task10",)),
    ("task10.provider.ready-invalid-revision", ("reconstruction-task10",)),
    ("task10.restore.activating", ("reconstruction-task10",)),
    ("task10.restore.failed-document-location", ("reconstruction-task10",)),
    ("task10.restore.failed-restoration", ("reconstruction-task10",)),
    ("task10.restore.failed-sidecar", ("reconstruction-task10",)),
    ("task10.restore.failed-stale-lifecycle", ("reconstruction-task10",)),
    ("task10.restore.inactive", ("reconstruction-task10",)),
    ("task10.restore.restoring", ("reconstruction-task10",)),
    ("task10.restore.runtime-unavailable", ("reconstruction-task10",)),
    ("task10.resume.exact-target", ("reconstruction-task10",)),
    ("task10.resume.missing-target", ("reconstruction-task10",)),
    ("task10.resume.stale-target", ("reconstruction-task10",)),
    ("task10.status.blocked", ("reconstruction-task10",)),
    ("task10.status.completed", ("reconstruction-task10",)),
    ("task10.status.failed", ("reconstruction-task10",)),
    ("task10.status.restored", ("reconstruction-task10",)),
    ("task10.status.stale", ("reconstruction-task10",)),
    ("task10.status.unavailable", ("reconstruction-task10",)),
    ("task8.cancel.after-terminal", ("reconstruction-task8",)),
    ("task8.cancel.before-dispatch", ("reconstruction-task8",)),
    ("task8.cancel.during-stream", ("reconstruction-task8",)),
    ("task8.event.completed", ("reconstruction-task8",)),
    ("task8.event.duplicate", ("reconstruction-task8",)),
    ("task8.event.final-candidate", ("reconstruction-task8",)),
    ("task8.event.malformed", ("reconstruction-task8",)),
    ("task8.event.post-terminal", ("reconstruction-task8",)),
    ("task8.event.reordered", ("reconstruction-task8",)),
    ("task8.event.round-candidate", ("reconstruction-task8",)),
    ("task8.event.stale", ("reconstruction-task8",)),
    ("task8.event.usage", ("reconstruction-task8",)),
    ("task8.legacy-assistant-compatibility", ("reconstruction-task8",)),
    ("task8.mismatch.correlation", ("reconstruction-task8",)),
    ("task8.mismatch.identity", ("reconstruction-task8",)),
    ("task8.mismatch.version", ("reconstruction-task8",)),
    ("task8.reply.accepted", ("reconstruction-task8",)),
    ("task8.reply.rejected", ("reconstruction-task8",)),
    ("task8.request.final-synthesis", ("reconstruction-task8",)),
    ("task8.request.round", ("reconstruction-task8",)),
    ("task8.signed-worker-parity", ("task8-signed-worker",)),
)
LANE_C_SCENARIO_GROUPS_BY_ID: Mapping[str, tuple[str, ...]] = MappingProxyType(
    dict(LANE_C_SCENARIO_GROUPS)
)



@dataclass(frozen=True, order=True)
class LaneCCommandAuthority:
    """The exact command axes Lane B consumes from Lane C.

    Lane B does not duplicate argv, host, timeout, or execution policy.  It
    freezes only the command ID, exact group ownership, scenario bindings, and evidence layer
    needed to prevent an unrelated command receipt from satisfying a
    prerequisite node.  ``validate_lane_c_command_catalog`` accepts Lane C's
    real ``CommandTemplate``/``CommandRecord`` values structurally and rejects
    every missing, extra, or reassigned command.
    """

    command_id: str
    evidence_layer: EvidenceLayer
    command_groups: tuple[str, ...]
    scenario_ids: tuple[str, ...]
    prerequisite_ids: tuple[str, ...]


@dataclass(frozen=True, order=True)
class LaneCCommandRecordAuthority:
    """Candidate-bound public projection of one Lane C CommandRecord."""

    candidate_identity_sha256: str
    command_id: str
    evidence_layer: EvidenceLayer
    command_groups: tuple[str, ...]
    scenario_ids: tuple[str, ...]
    prerequisite_ids: tuple[str, ...]


@dataclass(frozen=True, order=True)
class LaneCScenarioBindingAuthority:
    """Exact scenario-to-command projection consumed from Lane C."""

    scenario_id: str
    command_ids: tuple[str, ...]


@dataclass(frozen=True)
class LaneCScenarioPlanAuthority:
    """Candidate-bound public projection of Lane C's scenario plan."""

    candidate_identity_sha256: str
    scenario_catalog_sha256: str
    commands: tuple[LaneCCommandRecordAuthority, ...]
    scenario_bindings: tuple[LaneCScenarioBindingAuthority, ...]


@dataclass(frozen=True)
class LaneCIntegratedCommandPlanInput:
    """Actual Lane C inputs required to recompile and authenticate one plan."""

    plan: object
    scenario_catalog: object
    repository_root: Path
    inputs: Mapping[str, str]
    templates: Mapping[str, object]


@dataclass(frozen=True)
class _ValidatedLaneCCommandRecord:
    """Closed primitive projection of one authenticated Lane C command."""

    command_id: str
    evidence_layer: EvidenceLayer
    host: str
    execution_mode: str
    argv_sha256: str
    working_directory_sha256: str
    environment_sha256: str
    generated_artifacts: tuple[str, ...]
    generated_logs: tuple[str, ...]
    prerequisite_ids: tuple[str, ...]
    receipt_fields: tuple[str, ...]


@dataclass(frozen=True)
class _ValidatedLaneCCommandPlan:
    """Internal authority emitted only after Lane C recompilation succeeds."""

    candidate_identity_sha256: str
    command_plan_sha256: str
    scenario_catalog_sha256: str
    command_record_sha256_by_id: Mapping[str, str]
    command_records_by_id: Mapping[str, _ValidatedLaneCCommandRecord]
    raw_command_records_by_id: Mapping[str, object]
    projection: LaneCScenarioPlanAuthority


# The evaluator and its public test fixtures share this immutable projection.  The
# leading-underscore spelling remains the implementation detail used internally;
# this alias preserves the established import surface without creating a second
# authority type.
ValidatedLaneCCommandPlan = _ValidatedLaneCCommandPlan
# Test fixtures need the exact immutable per-command projection in order to
# construct receipts that are indistinguishable from compiler-authenticated
# records.  This remains a projection, not a second authority type.
ValidatedLaneCCommandRecord = _ValidatedLaneCCommandRecord


def _git_output(repository_root: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ("/usr/bin/git", "-C", str(repository_root), *arguments),
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
        timeout=30,
    )
    return completed.stdout.strip()


def _repository_source_issues(
    repository_root: Path,
    candidate: CandidateIdentity,
) -> tuple[ValidationIssue, ...]:
    """Bind plan compilation to the descriptor-stable clean candidate checkout."""

    try:
        lexical = Path(os.path.abspath(repository_root))
        resolved = repository_root.resolve(strict=True)
        if lexical != resolved or repository_root.is_symlink():
            raise ValueError("repository root traverses a symbolic link")
        before = resolved.stat()
        observed_commit = _git_output(resolved, "rev-parse", "--verify", "HEAD^{commit}")
        observed_tree = _git_output(resolved, "rev-parse", "--verify", "HEAD^{tree}")
        observed_base_tree = _git_output(
            resolved,
            "rev-parse",
            "--verify",
            f"{candidate.source.base_commit}^{{tree}}",
        )
        dirty = _git_output(
            resolved,
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
        )
        after = resolved.stat()
    except (
        OSError,
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
        UnicodeError,
        ValueError,
    ) as error:
        return (
            ValidationIssue(
                "lane-c-repository-source-authority",
                "$.lane_c_command_plan.repository_root",
                f"candidate checkout authority is unavailable: {type(error).__name__}",
            ),
        )
    issues: list[ValidationIssue] = []
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        issues.append(
            ValidationIssue(
                "lane-c-repository-root-moved",
                "$.lane_c_command_plan.repository_root",
                "repository root changed while its Git authority was measured",
            )
        )
    if dirty:
        issues.append(
            ValidationIssue(
                "lane-c-repository-dirty",
                "$.lane_c_command_plan.repository_root",
                "command plans require a clean checkout with no untracked inputs",
            )
        )
    if observed_commit != candidate.source.commit:
        issues.append(
            ValidationIssue(
                "lane-c-repository-commit-mismatch",
                "$.lane_c_command_plan.repository_root",
                "repository HEAD differs from the candidate source commit",
            )
        )
    if observed_tree != candidate.source.tree:
        issues.append(
            ValidationIssue(
                "lane-c-repository-tree-mismatch",
                "$.lane_c_command_plan.repository_root",
                "repository HEAD tree differs from the candidate source tree",
            )
        )
    if observed_base_tree != candidate.source.base_tree:
        issues.append(
            ValidationIssue(
                "lane-c-repository-base-tree-mismatch",
                "$.lane_c_command_plan.repository_root",
                "candidate base commit does not resolve to its declared tree",
            )
        )
    return tuple(sorted(set(issues)))


def _scenario_ids_for_groups(groups: Sequence[str]) -> tuple[str, ...]:
    selected = set(groups)
    return tuple(
        scenario_id
        for scenario_id, scenario_groups in LANE_C_SCENARIO_GROUPS
        if selected & set(scenario_groups)
    )


def lane_c_receipt_scenario_ids(
    command: LaneCCommandAuthority,
) -> tuple[str, ...]:
    """Return exact receipt coordinates for a Lane C command.

    Five infrastructure commands intentionally have no matrix scenario in
    Lane C.  Their one deterministic command-local coordinate prevents an
    arbitrary caller-selected scenario from becoming evidence authority.
    """

    if command.scenario_ids:
        return command.scenario_ids
    return (command.command_id,)


# These aggregate execution commands are valid only when their passed receipt
# carries every scenario assigned by Lane C as an exact constituent. The
# scenario IDs still come exclusively from the compiled Lane C plan.
EXACT_SCENARIO_CONSTITUENT_COMMAND_IDS = frozenset(
    {
        "signed-xpc.error-cancellation",
        "stress.reconstruction-authority-races",
        "task8.signed-worker-parity",
    }
)


_LANE_C_FOCUSED_COMMAND_IDS: tuple[str, ...] = (
    "xcode.focused.batch-scheduler",
    "xcode.focused.crash-resume",
    "xcode.focused.initial-transaction",
    "xcode.focused.installed-contracts",
    "xcode.focused.model-rounds",
    "xcode.focused.provider-cancellation-race",
    "xcode.focused.provider-pool",
    "xcode.focused.session-resolver",
    "xcode.focused.task10-projection",
    "xcode.focused.task10-state-machine",
    "xcode.focused.task8-bundle",
    "xcode.focused.task8-handler",
    "xcode.focused.task8-wire",
    "xcode.focused.workspace-database",
)

_LANE_C_INDEPENDENT_REVIEW_COMMAND_IDS = (
    "review.independent.ai-protocol-signed-xpc",
    "review.independent.corpus-package-persistence",
    "review.independent.evidence-retrieval-scheduling",
    "review.independent.scope-installed-ui-governance",
)

_LANE_C_INDEPENDENT_REVIEW_PREREQUISITES = (
    "evidence.t10c-current-source-adjudication",
    "installed.emit-report",
    "native.golden",
    "reconstruction.deterministic-evidence",
    "release.build",
    "signed-xpc.complete-truncated-content",
    "signed-xpc.error-cancellation",
    "signed-xpc.supervision",
    "source.hosted-governance",
    "stress.reconstruction-authority-races",
    "task8.signed-worker-parity",
    "xcode.full-coretests",
)

# Exact prerequisite closure for the Task 11 Lane C authority.  The late
# current-source adjudication remains strictly before independent review,
# prospective merge qualification, and post-merge proof.
LANE_C_COMMAND_PREREQUISITES: Mapping[str, tuple[str, ...]] = MappingProxyType(
    {
        "source.create-sealed-export": ("candidate-identity-accepted",),
        "source.verify-sealed-export": ("source.create-sealed-export",),
        "source.hosted-governance": ("source.verify-sealed-export",),
        "xcode.smoke": ("source.hosted-governance",),
        **{
            command_id: ("xcode.smoke",)
            for command_id in _LANE_C_FOCUSED_COMMAND_IDS
        },
        "xcode.full-coretests": _LANE_C_FOCUSED_COMMAND_IDS,
        "reconstruction.deterministic-evidence": ("xcode.full-coretests",),
        "native.normal": ("source.hosted-governance",),
        "native.asan": ("native.normal",),
        "native.ubsan": ("native.normal",),
        "native.golden": ("native.asan", "native.normal", "native.ubsan"),
        "task8.signed-worker-parity": (
            "xcode.focused.task8-bundle",
            "xcode.focused.task8-handler",
            "xcode.focused.task8-wire",
        ),
        "signed-xpc.supervision": ("native.golden", "xcode.full-coretests"),
        "signed-xpc.complete-truncated-content": (
            "native.golden",
            "xcode.full-coretests",
        ),
        "signed-xpc.error-cancellation": (
            "native.golden",
            "xcode.full-coretests",
        ),
        "release.build": (
            "native.golden",
            "signed-xpc.complete-truncated-content",
            "signed-xpc.error-cancellation",
            "signed-xpc.supervision",
            "task8.signed-worker-parity",
            "xcode.full-coretests",
        ),
        "signing.strict-release": ("release.build",),
        "install.release-to-applications": ("signing.strict-release",),
        "installed.source-equality": ("install.release-to-applications",),
        "installed.shell-smoke": ("installed.source-equality",),
        "installed.xcuitest-preflight": ("install.release-to-applications",),
        "installed.task10-workflow": (
            "installed.source-equality",
            "installed.xcuitest-preflight",
        ),
        "installed.accessibility-semantics": (
            "installed.task10-workflow",
        ),
        "installed.emit-report": (
            "installed.accessibility-semantics",
            "installed.shell-smoke",
            "installed.source-equality",
            "installed.task10-workflow",
        ),
        "stress.reconstruction-authority-races": ("xcode.full-coretests",),
        "evidence.t10c-current-source-adjudication": (
            "xcode.focused.task10-projection",
            "xcode.focused.task10-state-machine",
            "xcode.full-coretests",
        ),
        **{
            command_id: _LANE_C_INDEPENDENT_REVIEW_PREREQUISITES
            for command_id in _LANE_C_INDEPENDENT_REVIEW_COMMAND_IDS
        },
        "review.independent": _LANE_C_INDEPENDENT_REVIEW_COMMAND_IDS,
        "merge.prospective-tree": ("review.independent",),
        "postmerge.exact-tree-proof": ("merge.prospective-tree",),
    }
)


LANE_C_COMMAND_AUTHORITIES: tuple[LaneCCommandAuthority, ...] = tuple(
    LaneCCommandAuthority(
        command_id,
        layer,
        tuple(groups),
        _scenario_ids_for_groups(groups),
        LANE_C_COMMAND_PREREQUISITES[command_id],
    )
    for command_id, layer, groups in (
        ("evidence.t10c-current-source-adjudication", EvidenceLayer.INDEPENDENT_REVIEW, ("reconstruction-task10",)),
        ("install.release-to-applications", EvidenceLayer.INSTALLED_SOURCE_EQUALITY, ("installed-accessibility", "installed-equality", "installed-launch", "installed-task10")),
        ("installed.accessibility-semantics", EvidenceLayer.INSTALLED_ACCESSIBILITY, ("installed-accessibility",)),
        ("installed.emit-report", EvidenceLayer.INSTALLED_WORKFLOW, ("installed-accessibility", "installed-equality", "installed-launch", "installed-task10")),
        ("installed.shell-smoke", EvidenceLayer.INSTALLED_LAUNCH_LOG, ("installed-launch",)),
        ("installed.source-equality", EvidenceLayer.INSTALLED_SOURCE_EQUALITY, ("installed-equality",)),
        ("installed.task10-workflow", EvidenceLayer.INSTALLED_WORKFLOW, ("installed-network-audit", "installed-task10")),
        ("installed.xcuitest-preflight", EvidenceLayer.INSTALLED_ACCESSIBILITY, ("installed-accessibility", "installed-task10")),
        ("merge.prospective-tree", EvidenceLayer.PROSPECTIVE_MERGE_TREE, ("merge-qualification",)),
        ("native.asan", EvidenceLayer.NATIVE_ASAN, ("native-asan",)),
        ("native.golden", EvidenceLayer.NATIVE_NORMAL, ("native-golden",)),
        ("native.normal", EvidenceLayer.NATIVE_NORMAL, ("native-normal",)),
        ("native.ubsan", EvidenceLayer.NATIVE_UBSAN, ("native-ubsan",)),
        ("postmerge.exact-tree-proof", EvidenceLayer.POST_MERGE, ("postmerge-qualification",)),
        ("reconstruction.deterministic-evidence", EvidenceLayer.XCODE_FOCUSED, ("reconstruction-persistence", "reconstruction-rounds")),
        ("release.build", EvidenceLayer.RELEASE_BUILD, ("release",)),
        ("review.independent", EvidenceLayer.INDEPENDENT_REVIEW, ("merge-qualification",)),
        *(
            (command_id, EvidenceLayer.INDEPENDENT_REVIEW, ("merge-qualification",))
            for command_id in _LANE_C_INDEPENDENT_REVIEW_COMMAND_IDS
        ),
        ("signed-xpc.complete-truncated-content", EvidenceLayer.SIGNED_XPC, ("signed-xpc-content",)),
        ("signed-xpc.error-cancellation", EvidenceLayer.SIGNED_XPC, ("signed-xpc-error-cancellation",)),
        ("signed-xpc.supervision", EvidenceLayer.SIGNED_XPC, ("signed-xpc-supervision",)),
        ("signing.strict-release", EvidenceLayer.STRICT_SIGNING, ("strict-signing",)),
        ("source.create-sealed-export", EvidenceLayer.SOURCE_GOVERNANCE, ("source-governance",)),
        ("source.hosted-governance", EvidenceLayer.HOSTED_PURE, ("source-governance",)),
        ("source.verify-sealed-export", EvidenceLayer.SOURCE_GOVERNANCE, ("source-governance",)),
        ("stress.reconstruction-authority-races", EvidenceLayer.STRESS_RECOVERY, ("stress-recovery",)),
        ("task8.signed-worker-parity", EvidenceLayer.SIGNED_XPC, ("task8-signed-worker",)),
        ("xcode.focused.batch-scheduler", EvidenceLayer.XCODE_FOCUSED, ("reconstruction-concurrency",)),
        ("xcode.focused.crash-resume", EvidenceLayer.XCODE_FOCUSED, ("reconstruction-persistence",)),
        ("xcode.focused.initial-transaction", EvidenceLayer.XCODE_FOCUSED, ("reconstruction-persistence",)),
        ("xcode.focused.installed-contracts", EvidenceLayer.XCODE_FOCUSED, ("installed-accessibility", "installed-equality", "installed-launch", "installed-task10")),
        ("xcode.focused.model-rounds", EvidenceLayer.XCODE_FOCUSED, ("reconstruction-rounds",)),
        ("xcode.focused.provider-cancellation-race", EvidenceLayer.XCODE_FOCUSED, ("reconstruction-concurrency",)),
        ("xcode.focused.provider-pool", EvidenceLayer.XCODE_FOCUSED, ("reconstruction-concurrency",)),
        ("xcode.focused.session-resolver", EvidenceLayer.XCODE_FOCUSED, ("reconstruction-concurrency", "reconstruction-session")),
        ("xcode.focused.task10-projection", EvidenceLayer.XCODE_FOCUSED, ("reconstruction-task10",)),
        ("xcode.focused.task10-state-machine", EvidenceLayer.XCODE_FOCUSED, ("reconstruction-task10",)),
        ("xcode.focused.task8-bundle", EvidenceLayer.XCODE_FOCUSED, ("reconstruction-task8",)),
        ("xcode.focused.task8-handler", EvidenceLayer.XCODE_FOCUSED, ("reconstruction-task8",)),
        ("xcode.focused.task8-wire", EvidenceLayer.XCODE_FOCUSED, ("reconstruction-task8",)),
        ("xcode.focused.workspace-database", EvidenceLayer.XCODE_FOCUSED, ("reconstruction-persistence",)),
        ("xcode.full-coretests", EvidenceLayer.XCODE_FULL_CORETESTS, ("reconstruction-concurrency", "reconstruction-persistence", "reconstruction-rounds", "reconstruction-session", "reconstruction-task10", "reconstruction-task8", "source-governance")),
        ("xcode.smoke", EvidenceLayer.XCODE_FOCUSED, ("source-governance",)),
    )
)
LANE_C_COMMAND_AUTHORITIES_BY_ID: Mapping[str, LaneCCommandAuthority] = MappingProxyType(
    {authority.command_id: authority for authority in LANE_C_COMMAND_AUTHORITIES}
)


def lane_c_command_records(
    candidate_digest: str,
    *, profile: CampaignProfile = CampaignProfile.EXISTING,
) -> tuple[LaneCCommandRecordAuthority, ...]:
    """Create the exact candidate-bound public command-plan projection."""

    return tuple(
        LaneCCommandRecordAuthority(
            candidate_identity_sha256=candidate_digest,
            command_id=authority.command_id,
            evidence_layer=authority.evidence_layer,
            command_groups=authority.command_groups,
            scenario_ids=authority.scenario_ids,
            prerequisite_ids=authority.prerequisite_ids,
        )
        for authority in lane_c_command_authorities(profile=profile)
    )
LANE_C_COMMAND_AUTHORITY_SHA256 = canonical_sha256(
    [
        {
            "command_id": authority.command_id,
            "command_groups": list(authority.command_groups),
            "evidence_layer": authority.evidence_layer.value,
            "scenario_ids": list(authority.scenario_ids),
            "prerequisite_ids": list(authority.prerequisite_ids),
        }
        for authority in LANE_C_COMMAND_AUTHORITIES
    ]
)

LANE_C_SCENARIO_BINDINGS: tuple[LaneCScenarioBindingAuthority, ...] = tuple(
    LaneCScenarioBindingAuthority(
        scenario_id=scenario_id,
        command_ids=tuple(
            authority.command_id
            for authority in LANE_C_COMMAND_AUTHORITIES
            if scenario_id in authority.scenario_ids
        ),
    )
    for scenario_id, _ in LANE_C_SCENARIO_GROUPS
)
LANE_C_SCENARIO_BINDINGS_BY_ID: Mapping[
    str, LaneCScenarioBindingAuthority
] = MappingProxyType(
    {binding.scenario_id: binding for binding in LANE_C_SCENARIO_BINDINGS}
)
LANE_C_SCENARIO_BINDING_SHA256 = canonical_sha256(
    [
        {
            "command_ids": list(binding.command_ids),
            "scenario_id": binding.scenario_id,
        }
        for binding in LANE_C_SCENARIO_BINDINGS
    ]
)


def lane_c_command_authorities(*, profile: CampaignProfile = CampaignProfile.EXISTING) -> tuple[LaneCCommandAuthority, ...]:
    def predecessors(authority):
        values = authority.prerequisite_ids
        if profile is CampaignProfile.BOOTSTRAP_VERIFIER and authority.command_id == "evidence.t10c-current-source-adjudication":
            values += ("installed.task10-workflow", "installed.accessibility-semantics", "installed.source-equality",
                       "installed.shell-smoke", "installed.emit-report")
        return values
    return tuple(sorted((replace(authority,
        command_id=campaign_command_id(authority.command_id, profile=profile),
        prerequisite_ids=tuple(sorted(campaign_command_id(value, profile=profile)
                                     for value in predecessors(authority))))
        for authority in LANE_C_COMMAND_AUTHORITIES), key=lambda item: item.command_id))


def lane_c_scenario_bindings(*, profile: CampaignProfile = CampaignProfile.EXISTING) -> tuple[LaneCScenarioBindingAuthority, ...]:
    return tuple(replace(binding, command_ids=tuple(sorted(campaign_command_id(value, profile=profile)
        for value in binding.command_ids))) for binding in LANE_C_SCENARIO_BINDINGS)


def validate_lane_c_command_catalog(
    values: Sequence[object],
    *,
    expected_candidate_identity_sha256: str | None = None,
    profile: CampaignProfile = CampaignProfile.EXISTING,
) -> tuple[Mapping[str, LaneCCommandAuthority] | None, tuple[ValidationIssue, ...]]:
    """Project and authenticate Lane C's exact public command catalog."""

    issues: list[ValidationIssue] = []
    if not isinstance(values, (tuple, list)):
        return None, (
            ValidationIssue(
                "command-catalog-type",
                "$.command_catalog",
                "Lane C command catalog must be a tuple or list",
            ),
        )
    observed: dict[str, LaneCCommandAuthority] = {}
    observed_order: list[str] = []
    for index, value in enumerate(values):
        path = f"$.command_catalog[{index}]"
        try:
            command_id = value.command_id
            evidence_layer = value.evidence_layer
            command_groups = value.command_groups
            scenario_ids = value.scenario_ids
            prerequisite_ids = value.prerequisite_ids
        except AttributeError:
            issues.append(
                ValidationIssue(
                    "command-catalog-entry-type",
                    path,
                    "entry must expose Lane C command_id, evidence_layer, command_groups, scenario_ids, and prerequisite_ids",
                )
            )
            continue
        if expected_candidate_identity_sha256 is not None:
            candidate_digest = getattr(value, "candidate_identity_sha256", None)
            if candidate_digest != expected_candidate_identity_sha256:
                issues.append(
                    ValidationIssue(
                        "command-candidate-mismatch",
                        f"{path}.candidate_identity_sha256",
                        "command record belongs to another candidate",
                    )
                )
        if (
            not isinstance(command_id, str)
            or STABLE_ID_RE.fullmatch(command_id) is None
            or not isinstance(evidence_layer, EvidenceLayer)
            or not isinstance(command_groups, tuple)
            or not isinstance(scenario_ids, tuple)
            or not isinstance(prerequisite_ids, tuple)
            or any(
                not isinstance(group, str)
                or STABLE_ID_RE.fullmatch(group) is None
                for group in command_groups
            )
            or any(
                not isinstance(scenario_id, str)
                or STABLE_ID_RE.fullmatch(scenario_id) is None
                for scenario_id in scenario_ids
            )
            or scenario_ids != tuple(sorted(set(scenario_ids)))
            or any(
                not isinstance(prerequisite_id, str)
                or STABLE_ID_RE.fullmatch(prerequisite_id) is None
                for prerequisite_id in prerequisite_ids
            )
            or prerequisite_ids != tuple(sorted(set(prerequisite_ids)))
        ):
            issues.append(
                ValidationIssue(
                    "command-catalog-entry-shape",
                    path,
                    "command authority axes are malformed",
                )
            )
            continue
        authority = LaneCCommandAuthority(
            command_id=command_id,
            evidence_layer=evidence_layer,
            command_groups=command_groups,
            scenario_ids=scenario_ids,
            prerequisite_ids=prerequisite_ids,
        )
        observed_order.append(command_id)
        if command_id in observed:
            issues.append(
                ValidationIssue(
                    "duplicate-command",
                    f"{path}.command_id",
                    "command ID is duplicated",
                )
            )
        observed[command_id] = authority

    authorities = lane_c_command_authorities(profile=profile)
    expected = {authority.command_id: authority for authority in authorities}
    expected_order = tuple(
        authority.command_id for authority in authorities
    )
    if tuple(observed_order) != expected_order:
        issues.append(
            ValidationIssue(
                "lane-c-command-order",
                "$.command_catalog",
                "commands must retain Lane C's canonical stable-ID order",
            )
        )
    if observed != expected:
        missing = sorted(set(expected) - set(observed))
        extra = sorted(set(observed) - set(expected))
        drifted = sorted(
            command_id
            for command_id in set(expected) & set(observed)
            if expected[command_id] != observed[command_id]
        )
        issues.append(
            ValidationIssue(
                "lane-c-command-catalog-mismatch",
                "$.command_catalog",
                "catalog differs from Lane C authority"
                f"; missing={missing}; extra={extra}; drifted={drifted}",
            )
        )
    if issues:
        return None, tuple(sorted(set(issues)))
    return MappingProxyType(observed), ()


def validate_lane_c_command_plan(
    value: object,
    *,
    expected_candidate_identity_sha256: str,
    profile: CampaignProfile = CampaignProfile.EXISTING,
) -> tuple[LaneCScenarioPlanAuthority | None, tuple[ValidationIssue, ...]]:
    """Authenticate Lane C's candidate-bound exact command plan projection."""

    issues: list[ValidationIssue] = []
    try:
        candidate_digest = value.candidate_identity_sha256
        scenario_catalog_digest = value.scenario_catalog_sha256
        commands = value.commands
        bindings = value.scenario_bindings
    except AttributeError:
        return None, (
            ValidationIssue(
                "scenario-plan-type",
                "$.scenario_plan",
                "Lane C command plan must expose candidate, catalog, commands, and bindings",
            ),
        )
    if candidate_digest != expected_candidate_identity_sha256:
        issues.append(
            ValidationIssue(
                "scenario-plan-candidate-mismatch",
                "$.scenario_plan.candidate_identity_sha256",
                "scenario plan belongs to another candidate",
            )
        )
    if not is_sha256(scenario_catalog_digest):
        issues.append(
            ValidationIssue(
                "scenario-plan-catalog-digest",
                "$.scenario_plan.scenario_catalog_sha256",
                "scenario catalog digest must be lowercase SHA-256",
            )
        )
    canonical_commands, command_issues = validate_lane_c_command_catalog(
        commands,
        expected_candidate_identity_sha256=expected_candidate_identity_sha256,
        profile=profile,
    )
    issues.extend(command_issues)
    if not isinstance(bindings, (tuple, list)):
        issues.append(
            ValidationIssue(
                "scenario-plan-bindings-type",
                "$.scenario_plan.scenario_bindings",
                "scenario bindings must be a tuple or list",
            )
        )
        return None, tuple(sorted(set(issues)))
    projected: list[LaneCScenarioBindingAuthority] = []
    for index, binding in enumerate(bindings):
        path = f"$.scenario_plan.scenario_bindings[{index}]"
        try:
            scenario_id = binding.scenario_id
            command_ids = binding.command_ids
        except AttributeError:
            issues.append(
                ValidationIssue(
                    "scenario-binding-type",
                    path,
                    "binding must expose scenario_id and command_ids",
                )
            )
            continue
        if (
            not isinstance(scenario_id, str)
            or STABLE_ID_RE.fullmatch(scenario_id) is None
            or not isinstance(command_ids, tuple)
            or any(
                not isinstance(command_id, str)
                or STABLE_ID_RE.fullmatch(command_id) is None
                for command_id in command_ids
            )
            or not command_ids
            or command_ids != tuple(sorted(set(command_ids)))
        ):
            issues.append(
                ValidationIssue(
                    "scenario-binding-shape",
                    path,
                    "scenario binding axes are malformed",
                )
            )
            continue
        projected.append(LaneCScenarioBindingAuthority(scenario_id, command_ids))
    projected_tuple = tuple(projected)
    if projected_tuple != lane_c_scenario_bindings(profile=profile):
        issues.append(
            ValidationIssue(
                "lane-c-scenario-plan-mismatch",
                "$.scenario_plan.scenario_bindings",
                "scenario bindings differ from Lane C authority",
            )
        )
    if issues:
        return None, tuple(sorted(set(issues)))
    assert canonical_commands is not None
    return (
        LaneCScenarioPlanAuthority(
            candidate_identity_sha256=candidate_digest,
            scenario_catalog_sha256=scenario_catalog_digest,
            commands=lane_c_command_records(candidate_digest, profile=profile),
            scenario_bindings=projected_tuple,
        ),
        (),
    )


def validate_integrated_lane_c_command_plan(
    value: object,
    *,
    candidate: CandidateIdentity,
    profile: CampaignProfile = CampaignProfile.EXISTING,
) -> tuple[_ValidatedLaneCCommandPlan | None, tuple[ValidationIssue, ...]]:
    """Recompile and authenticate an actual Lane C command plan.

    The adapter deliberately imports Lane C lazily: Lane B remains independently
    testable, but its public evaluator fails closed until the real command and
    scenario compilers are integrated.  No caller-supplied plan digest is
    accepted.  The digest returned here is derived only after Lane C recompiles
    the plan from the exact candidate, scenario catalog, repository, inputs,
    and frozen template catalog and proves byte-for-byte DTO equality.
    """

    if not isinstance(value, LaneCIntegratedCommandPlanInput):
        return None, (
            ValidationIssue(
                "lane-c-command-plan-input-type",
                "$.lane_c_command_plan",
                "integrated plan input must carry the actual Lane C plan, scenario catalog, repository root, inputs, and templates",
            ),
        )
    try:
        from .command_compiler import (
            CommandPlan,
            command_plan_sha256,
            compile_command_plan,
            validate_command_plan,
        )
        from .scenario_model import ScenarioCatalog, scenario_catalog_sha256
    except ImportError:
        return None, (
            ValidationIssue(
                "lane-c-validator-unavailable",
                "$.lane_c_command_plan",
                "Lane C command/scenario validation is not integrated",
            ),
        )

    if not isinstance(value.plan, CommandPlan) or not isinstance(
        value.scenario_catalog, ScenarioCatalog
    ):
        return None, (
            ValidationIssue(
                "lane-c-command-plan-type",
                "$.lane_c_command_plan",
                "plan and scenario catalog must be actual Lane C compiler DTOs",
            ),
        )
    if (
        not isinstance(value.repository_root, Path)
        or not isinstance(value.inputs, Mapping)
        or not isinstance(value.templates, Mapping)
    ):
        return None, (
            ValidationIssue(
                "lane-c-command-plan-authority-shape",
                "$.lane_c_command_plan",
                "repository, inputs, and template authorities are malformed",
            ),
        )

    repository_issues = _repository_source_issues(value.repository_root, candidate)
    if repository_issues:
        return None, repository_issues

    try:
        recompiled = compile_command_plan(
            candidate,
            value.scenario_catalog,
            repository_root=value.repository_root,
            inputs=dict(value.inputs),
            templates=tuple(value.templates.values()),
            profile=profile,
        )
        lane_c_issues = validate_command_plan(
            value.plan,
            candidate=candidate,
            scenario_catalog=value.scenario_catalog,
            repository_root=value.repository_root,
            templates=value.templates,
            profile=profile,
        )
    except (
        AttributeError,
        KeyError,
        OSError,
        RecursionError,
        RuntimeError,
        TypeError,
        ValueError,
    ) as error:
        return None, (
            ValidationIssue(
                "lane-c-command-plan-validation",
                "$.lane_c_command_plan",
                f"Lane C rejected command-plan authority: {type(error).__name__}",
            ),
        )
    issues = list(lane_c_issues)
    if recompiled != value.plan:
        issues.append(
            ValidationIssue(
                "lane-c-command-plan-recompile-mismatch",
                "$.lane_c_command_plan.plan",
                "supplied plan differs from Lane C's deterministic recompilation",
            )
        )
    projection, projection_issues = validate_lane_c_command_plan(
        value.plan,
        expected_candidate_identity_sha256=candidate_identity_sha256(candidate),
        profile=profile,
    )
    issues.extend(projection_issues)
    if issues or projection is None:
        return None, tuple(sorted(set(issues)))
    try:
        plan_digest = command_plan_sha256(value.plan)
        scenario_digest = scenario_catalog_sha256(value.scenario_catalog)
        record_digests = MappingProxyType(
            {
                record.command_id: canonical_sha256(record)
                for record in value.plan.commands
            }
        )
        record_authorities = MappingProxyType(
            {
                record.command_id: _ValidatedLaneCCommandRecord(
                    command_id=record.command_id,
                    evidence_layer=record.evidence_layer,
                    host=record.host.value,
                    execution_mode=record.execution_mode.value,
                    argv_sha256=canonical_sha256(list(record.argv)),
                    working_directory_sha256=canonical_sha256(
                        record.working_directory
                    ),
                    environment_sha256=canonical_sha256(
                        [list(item) for item in record.environment]
                    ),
                    generated_artifacts=record.generated_artifacts,
                    generated_logs=record.generated_logs,
                    prerequisite_ids=record.prerequisite_ids,
                    receipt_fields=record.receipt_fields,
                )
                for record in value.plan.commands
            }
        )
    except (AttributeError, KeyError, RecursionError, TypeError, ValueError):
        return None, (
            ValidationIssue(
                "lane-c-command-plan-canonicalization",
                "$.lane_c_command_plan",
                "validated Lane C plan cannot be canonically hashed",
            ),
        )
    if projection.scenario_catalog_sha256 != scenario_digest:
        return None, (
            ValidationIssue(
                "lane-c-scenario-catalog-digest-mismatch",
                "$.lane_c_command_plan.scenario_catalog",
                "plan does not seal the locally derived scenario-catalog digest",
            ),
        )
    return (
        _ValidatedLaneCCommandPlan(
            candidate_identity_sha256=candidate_identity_sha256(candidate),
            command_plan_sha256=plan_digest,
            scenario_catalog_sha256=scenario_digest,
            command_record_sha256_by_id=record_digests,
            command_records_by_id=record_authorities,
            raw_command_records_by_id=MappingProxyType({
                record.command_id: record for record in value.plan.commands
            }),
            projection=projection,
        ),
        (),
    )


class PrerequisiteStage(str, Enum):
    PREMERGE = "premerge"
    MERGE = "merge"
    POSTMERGE = "postmerge"


class BlockingSeverity(str, Enum):
    P0 = "p0"
    P1 = "p1"
    P2 = "p2"
    P3 = "p3"


@dataclass(frozen=True)
class PrerequisiteNodeSpec:
    schema_version: int
    node_id: str
    owner_id: str
    stage: PrerequisiteStage
    prerequisites: tuple[str, ...]
    source_authority: str
    required_identity_paths: tuple[str, ...]
    required_evidence_layers: tuple[EvidenceLayer, ...]
    allowed_skip_ids: tuple[str, ...]
    blocking_severity: BlockingSeverity
    command_group_ids: tuple[str, ...]
    receipt_output_ids: tuple[str, ...]
    artifact_output_ids: tuple[str, ...]
    invalidation_rules: tuple[str, ...]
    stop_condition: str | None


@dataclass(frozen=True)
class CompiledPrerequisiteNode:
    spec: PrerequisiteNodeSpec
    authority: PrerequisiteAuthority


@dataclass(frozen=True)
class PrerequisiteDAG:
    source_contract_sha256: str
    nodes: tuple[CompiledPrerequisiteNode, ...]
    topological_order: tuple[str, ...]

    def by_id(self) -> Mapping[str, CompiledPrerequisiteNode]:
        return {node.spec.node_id: node for node in self.nodes}

    def required_node_ids(self, subject_kind: CandidateSubjectKind) -> tuple[str, ...]:
        allowed_stages = {PrerequisiteStage.PREMERGE}
        if subject_kind is CandidateSubjectKind.POST_MERGE:
            allowed_stages.update({PrerequisiteStage.MERGE, PrerequisiteStage.POSTMERGE})
        return tuple(
            node_id
            for node_id in self.topological_order
            if self.by_id()[node_id].spec.stage in allowed_stages
        )


def _spec(
    node_id: str,
    *,
    prerequisites: Sequence[str] = (),
    stage: PrerequisiteStage = PrerequisiteStage.PREMERGE,
    identities: Sequence[str] = (),
    layers: Sequence[EvidenceLayer] = (EvidenceLayer.SOURCE_GOVERNANCE,),
    severity: BlockingSeverity = BlockingSeverity.P1,
    commands: Sequence[str] = (),
    receipts: Sequence[str] = (),
    artifacts: Sequence[str] = (),
    invalidation: Sequence[str] = (
        "candidate-authority-moved",
        "required-identity-moved",
        "receipt-invalid-or-superseded",
    ),
    stop_condition: str | None = None,
) -> PrerequisiteNodeSpec:
    return PrerequisiteNodeSpec(
        schema_version=PREREQUISITE_NODE_SCHEMA_VERSION,
        node_id=node_id,
        owner_id=f"owner-{node_id}",
        stage=stage,
        prerequisites=tuple(prerequisites),
        source_authority=f"authority-{node_id}",
        required_identity_paths=(
            "candidate.identity_sha256",
            *identities,
        ),
        required_evidence_layers=tuple(layers),
        allowed_skip_ids=(),
        blocking_severity=severity,
        command_group_ids=tuple(commands),
        receipt_output_ids=tuple(receipts or (f"receipt-{node_id}",)),
        artifact_output_ids=tuple(artifacts or (f"artifact-{node_id}",)),
        invalidation_rules=tuple(invalidation),
        stop_condition=stop_condition,
    )


# This is the smallest coherent frozen graph that represents every subject the
# Task 11 commission says may not be inferred from an aggregate green result.
DEFAULT_PREREQUISITE_SPECS: tuple[PrerequisiteNodeSpec, ...] = (
    _spec(
        "task6-remediation-accepted",
        identities=(
            "source.base_commit",
            "source.base_tree",
            "semantic-prerequisite.task-6-remediation.commit",
            "semantic-prerequisite.task-6-remediation.tree",
            "semantic-prerequisite.task-6-remediation.evidence_sha256",
        ),
        layers=(EvidenceLayer.XCODE_FOCUSED,),
        commands=("reconstruction-persistence", "reconstruction-session"),
        severity=BlockingSeverity.P0,
    ),
    _spec(
        "task8-evidence-integrated",
        identities=(
            "source.commit",
            "source.tree",
            "semantic-prerequisite.task-8.commit",
            "semantic-prerequisite.task-8.tree",
            "semantic-prerequisite.task-8.evidence_sha256",
            "protocol.reconstruction-round-output.manifest_sha256",
        ),
        layers=(EvidenceLayer.XCODE_FOCUSED, EvidenceLayer.SIGNED_XPC),
        commands=("reconstruction-task8", "task8-signed-worker"),
        severity=BlockingSeverity.P0,
    ),
    _spec(
        "task9-regression-ready",
        identities=(
            "source.commit",
            "source.tree",
            "semantic-prerequisite.task-9.commit",
            "semantic-prerequisite.task-9.tree",
            "semantic-prerequisite.task-9.evidence_sha256",
            "selector_catalog.sha256",
        ),
        layers=(EvidenceLayer.HOSTED_PURE, EvidenceLayer.XCODE_FOCUSED),
        commands=("reconstruction-rounds", "source-governance"),
    ),
    _spec(
        "t10a-archive-verified",
        identities=(
            "source.commit",
            "source.tree",
            "semantic-prerequisite.t10a.commit",
            "semantic-prerequisite.t10a.tree",
            "semantic-prerequisite.t10a.evidence_sha256",
        ),
        layers=(EvidenceLayer.SOURCE_GOVERNANCE, EvidenceLayer.NATIVE_NORMAL),
        commands=("native-normal", "source-governance"),
        severity=BlockingSeverity.P0,
    ),
    _spec(
        "t10c-current-source-adjudicated",
        prerequisites=("t10a-archive-verified",),
        identities=(
            "source.commit",
            "source.tree",
            "semantic-prerequisite.t10c.commit",
            "semantic-prerequisite.t10c.tree",
            "semantic-prerequisite.t10c.evidence_sha256",
            "project.generated.sha256",
        ),
        # This early source adjudication is satisfied only by the focused
        # Task10 compiler surface.  Lane C's distinct
        # evidence.t10c-current-source-adjudication command remains late
        # independent-review evidence and is a prerequisite of
        # review.independent; it cannot substitute here and create a cycle.
        layers=(EvidenceLayer.XCODE_FOCUSED,),
        commands=("reconstruction-task10",),
        severity=BlockingSeverity.P0,
    ),
    _spec(
        "task10-rebased-corrected-task6",
        prerequisites=("task6-remediation-accepted",),
        identities=(
            "source.base_commit",
            "source.base_tree",
            "source.commit",
            "source.tree",
            "semantic-prerequisite.task-10.commit",
            "semantic-prerequisite.task-10.tree",
            "semantic-prerequisite.task-10.evidence_sha256",
        ),
        commands=("reconstruction-session", "source-governance"),
        severity=BlockingSeverity.P0,
    ),
    _spec(
        "task10-final-composition",
        prerequisites=(
            "task8-evidence-integrated",
            "task9-regression-ready",
            "t10c-current-source-adjudicated",
            "task10-rebased-corrected-task6",
        ),
        identities=(
            "source.commit",
            "source.tree",
            "semantic-prerequisite.task-10.commit",
            "semantic-prerequisite.task-10.tree",
            "semantic-prerequisite.task-10.evidence_sha256",
            "application.bundle_sha256",
            "application.closed_tree_sha256",
            "protocol.reconstruction-round-output.manifest_sha256",
        ),
        layers=(EvidenceLayer.XCODE_FOCUSED, EvidenceLayer.XCODE_FULL_CORETESTS),
        commands=(
            "reconstruction-concurrency",
            "reconstruction-persistence",
            "reconstruction-rounds",
            "reconstruction-session",
            "reconstruction-task10",
        ),
        severity=BlockingSeverity.P0,
    ),
    _spec(
        "gatef-compiler-identity",
        identities=("compiler.identity_sha256", "schema.gate-f-compiler.content_sha256"),
        commands=("source-governance",),
        severity=BlockingSeverity.P0,
    ),
    _spec(
        "exact-head-focused-tests",
        prerequisites=(
            "gatef-compiler-identity",
            "task10-final-composition",
        ),
        identities=(
            "source.commit",
            "source.tree",
            "tool.xcode.identity_sha256",
            "tool.swift.identity_sha256",
            "selector_catalog.sha256",
        ),
        layers=(
            EvidenceLayer.HOSTED_PURE,
            EvidenceLayer.NATIVE_NORMAL,
            EvidenceLayer.XCODE_FOCUSED,
        ),
        commands=(
            "native-normal",
            "reconstruction-concurrency",
            "reconstruction-persistence",
            "reconstruction-rounds",
            "reconstruction-session",
            "reconstruction-task10",
            "reconstruction-task8",
            "source-governance",
        ),
        severity=BlockingSeverity.P0,
    ),
    _spec(
        "exact-head-full-tests",
        prerequisites=("exact-head-focused-tests",),
        identities=(
            "source.commit",
            "source.tree",
            "tool.xcode.identity_sha256",
            "tool.swift.identity_sha256",
            "dependency.ghostty-vt.artifact_sha256",
            "dependency.sleigh-native.artifact_sha256",
        ),
        layers=(
            EvidenceLayer.NATIVE_ASAN,
            EvidenceLayer.NATIVE_UBSAN,
            EvidenceLayer.XCODE_FULL_CORETESTS,
            EvidenceLayer.SIGNED_XPC,
            EvidenceLayer.RELEASE_BUILD,
            EvidenceLayer.STRICT_SIGNING,
            EvidenceLayer.INSTALLED_SOURCE_EQUALITY,
            EvidenceLayer.INSTALLED_LAUNCH_LOG,
            EvidenceLayer.INSTALLED_WORKFLOW,
            EvidenceLayer.INSTALLED_ACCESSIBILITY,
            EvidenceLayer.STRESS_RECOVERY,
        ),
        commands=(
            "installed-accessibility",
            "installed-equality",
            "installed-launch",
            "installed-network-audit",
            "installed-task10",
            "native-asan",
            "native-golden",
            "native-normal",
            "native-ubsan",
            "reconstruction-concurrency",
            "reconstruction-persistence",
            "reconstruction-rounds",
            "reconstruction-session",
            "reconstruction-task10",
            "reconstruction-task8",
            "release",
            "signed-xpc-content",
            "signed-xpc-error-cancellation",
            "signed-xpc-supervision",
            "source-governance",
            "stress-recovery",
            "strict-signing",
            "task8-signed-worker",
        ),
        severity=BlockingSeverity.P0,
    ),
    _spec(
        "independent-review-remediated",
        prerequisites=("exact-head-full-tests",),
        identities=("source.commit", "source.tree"),
        layers=(EvidenceLayer.INDEPENDENT_REVIEW,),
        commands=("merge-qualification",),
        severity=BlockingSeverity.P0,
    ),
    _spec(
        "prospective-merge-qualified",
        prerequisites=("independent-review-remediated",),
        identities=("merge.prospective.commit", "merge.prospective.tree"),
        layers=(EvidenceLayer.PROSPECTIVE_MERGE_TREE,),
        commands=("merge-qualification",),
        severity=BlockingSeverity.P0,
    ),
    _spec(
        "merge-authorized",
        prerequisites=("prospective-merge-qualified",),
        stage=PrerequisiteStage.MERGE,
        identities=("merge.prospective.commit", "merge.prospective.tree"),
        layers=(EvidenceLayer.PROSPECTIVE_MERGE_TREE,),
        commands=("merge-qualification",),
        severity=BlockingSeverity.P0,
    ),
    _spec(
        "accepted-merge",
        prerequisites=("merge-authorized",),
        stage=PrerequisiteStage.MERGE,
        identities=("merge.accepted.commit", "merge.accepted.tree"),
        # Acceptance exists only after the merge result is known.  Lane A
        # correctly forbids prospective-layer receipts in the postmerge phase,
        # so this proof belongs to the exact post-merge layer rather than being
        # retroactively inserted into the earlier prospective proof.
        layers=(EvidenceLayer.POST_MERGE,),
        commands=("postmerge-qualification",),
        severity=BlockingSeverity.P0,
    ),
    _spec(
        "postmerge-proof",
        prerequisites=("accepted-merge",),
        stage=PrerequisiteStage.POSTMERGE,
        identities=(
            "merge.prospective.commit",
            "merge.prospective.tree",
            "merge.accepted.commit",
            "merge.accepted.tree",
            "application.bundle_sha256",
            "application.executable_sha256",
        ),
        layers=(EvidenceLayer.POST_MERGE,),
        commands=("postmerge-qualification",),
        severity=BlockingSeverity.P0,
    ),
    _spec(
        "increment2-stop-boundary",
        prerequisites=("postmerge-proof",),
        stage=PrerequisiteStage.POSTMERGE,
        identities=("merge.accepted.commit", "merge.accepted.tree"),
        layers=(EvidenceLayer.POST_MERGE,),
        commands=("postmerge-qualification",),
        severity=BlockingSeverity.P0,
        stop_condition="stop-before-reconstruction-increment-2",
    ),
)

MANDATORY_NODE_IDS = frozenset(spec.node_id for spec in DEFAULT_PREREQUISITE_SPECS)
MANDATORY_SPECS_BY_ID: Mapping[str, PrerequisiteNodeSpec] = MappingProxyType(
    {spec.node_id: spec for spec in DEFAULT_PREREQUISITE_SPECS}
)
MANDATORY_PREREQUISITE_EDGES = frozenset(
    (prerequisite, spec.node_id)
    for spec in DEFAULT_PREREQUISITE_SPECS
    for prerequisite in spec.prerequisites
)


def _catalog_value(items: Sequence[Any], identifier_name: str, identifier: str) -> Any | None:
    return next((item for item in items if getattr(item, identifier_name) == identifier), None)


def resolve_required_identity(
    contract: SourceContract,
    path: str,
    *,
    candidate: CandidateIdentity | None = None,
) -> object | None:
    """Resolve one frozen identity path without consulting mutable external state."""

    candidate = candidate or contract.candidate
    authorities = subject_authorities(contract)
    if path == "candidate.identity_sha256":
        return candidate_identity_sha256(candidate)
    if path == "compiler.identity_sha256":
        return contract.compiler_identity_sha256
    if path == "selector_catalog.sha256":
        return candidate.selector_catalog_sha256
    if path == "project.generated.sha256":
        return candidate.source.generated_project_sha256
    if path.startswith("source."):
        return getattr(candidate.source, path.removeprefix("source."), None)
    if path.startswith("application."):
        return getattr(candidate.application, path.removeprefix("application."), None)
    if path.startswith("merge.prospective."):
        suffix = path.removeprefix("merge.prospective.")
        return getattr(candidate, f"prospective_merge_{suffix}", None)
    if path.startswith("merge.accepted."):
        suffix = path.removeprefix("merge.accepted.")
        return getattr(candidate, f"accepted_postmerge_{suffix}", None)

    components = path.split(".")
    if len(components) == 3 and components[0] == "subject":
        authority = authorities.get(components[1])
        return getattr(authority, components[2], None) if authority is not None else None
    if len(components) == 3 and components[0] == "tool":
        item = _catalog_value(candidate.tools, "tool_id", components[1])
        return getattr(item, components[2], None) if item is not None else None
    if len(components) == 3 and components[0] == "dependency":
        item = _catalog_value(candidate.dependencies, "dependency_id", components[1])
        return getattr(item, components[2], None) if item is not None else None
    if len(components) == 3 and components[0] == "protocol":
        item = _catalog_value(candidate.protocols, "protocol_id", components[1])
        return getattr(item, components[2], None) if item is not None else None
    if len(components) == 3 and components[0] == "package":
        item = _catalog_value(candidate.packages, "package_id", components[1])
        return getattr(item, components[2], None) if item is not None else None
    if len(components) == 3 and components[0] == "schema":
        item = _catalog_value(candidate.schemas, "schema_id", components[1])
        return getattr(item, components[2], None) if item is not None else None
    if len(components) == 3 and components[0] == "semantic-prerequisite":
        item = _catalog_value(
            candidate.source.semantic_prerequisites,
            "prerequisite_id",
            components[1],
        )
        return getattr(item, components[2], None) if item is not None else None
    return None


def required_identity_path_is_known(
    contract: SourceContract,
    path: str,
    *,
    candidate: CandidateIdentity | None = None,
) -> bool:
    candidate = candidate or contract.candidate
    if path in {
        "candidate.identity_sha256",
        "compiler.identity_sha256",
        "selector_catalog.sha256",
        "project.generated.sha256",
        "merge.prospective.commit",
        "merge.prospective.tree",
        "merge.accepted.commit",
        "merge.accepted.tree",
    }:
        return True
    if path.startswith("source."):
        return hasattr(candidate.source, path.removeprefix("source."))
    if path.startswith("application."):
        return hasattr(candidate.application, path.removeprefix("application."))
    components = path.split(".")
    catalogs: Mapping[str, tuple[Sequence[Any], str]] = {
        "tool": (candidate.tools, "tool_id"),
        "dependency": (candidate.dependencies, "dependency_id"),
        "protocol": (candidate.protocols, "protocol_id"),
        "package": (candidate.packages, "package_id"),
        "schema": (candidate.schemas, "schema_id"),
        "semantic-prerequisite": (
            candidate.source.semantic_prerequisites,
            "prerequisite_id",
        ),
    }
    if len(components) != 3 or components[0] not in catalogs:
        return False
    values, identifier_name = catalogs[components[0]]
    item = _catalog_value(values, identifier_name, components[1])
    return item is not None and hasattr(item, components[2])


def prerequisite_identity_sha256(
    contract: SourceContract,
    spec: PrerequisiteNodeSpec,
) -> str | None:
    """Commit the node's exact candidate/tool/product identity axes.

    The supplied prerequisite receipt is independent evidence.  Its declared
    identity digest must nevertheless be reproducible from the node's frozen
    axis list, preventing an opaque digest from drifting away from the
    candidate it purports to adjudicate.
    """

    identity_candidate = contract.candidate
    if (
        contract.candidate.subject_kind is CandidateSubjectKind.POST_MERGE
        and (
            spec.stage is PrerequisiteStage.PREMERGE
            or spec.node_id == "merge-authorized"
        )
    ):
        if contract.prospective_candidate is None:
            return None
        identity_candidate = contract.prospective_candidate

    resolved = {
        identity_path: resolve_required_identity(
            contract,
            identity_path,
            candidate=identity_candidate,
        )
        for identity_path in spec.required_identity_paths
    }
    if any(value is None for value in resolved.values()):
        return None
    authorities = subject_authorities(contract)
    prerequisite_authorities: list[dict[str, object]] = []
    for prerequisite_id in sorted(spec.prerequisites):
        authority = authorities.get(prerequisite_id)
        if (
            authority is None
            or authority.status is not PrerequisiteStatus.ACCEPTED
            or authority.identity_sha256 is None
            or authority.receipt_sha256 is None
        ):
            return None
        prerequisite_authorities.append(
            {
                "subject_id": prerequisite_id,
                "identity_sha256": authority.identity_sha256,
                "receipt_sha256": authority.receipt_sha256,
            }
        )
    return canonical_sha256(
        {
            "schema_version": spec.schema_version,
            "node_id": spec.node_id,
            "source_authority": spec.source_authority,
            "required_identities": resolved,
            "prerequisite_authorities": prerequisite_authorities,
        }
    )


def _valid_stable_id(value: object) -> bool:
    return isinstance(value, str) and STABLE_ID_RE.fullmatch(value) is not None


def _validate_specs(specs: Sequence[PrerequisiteNodeSpec]) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    if not isinstance(specs, (tuple, list)):
        return [
            ValidationIssue(
                "prerequisite-specs-type",
                "$.prerequisite_nodes",
                "node specs must be a tuple or list",
            )
        ]
    node_ids: set[str] = set()
    owner_ids: set[str] = set()
    for index, spec in enumerate(specs):
        path = f"$.prerequisite_nodes[{index}]"
        if not isinstance(spec, PrerequisiteNodeSpec):
            issues.append(
                ValidationIssue(
                    "prerequisite-node-type",
                    path,
                    "node must be a PrerequisiteNodeSpec",
                )
            )
            continue
        if not isinstance(spec.schema_version, int) or isinstance(
            spec.schema_version, bool
        ):
            issues.append(
                ValidationIssue(
                    "prerequisite-node-scalar-shape",
                    f"{path}.schema_version",
                    "node scalar fields must retain their closed immutable types",
                )
            )
        if spec.schema_version != PREREQUISITE_NODE_SCHEMA_VERSION:
            issues.append(ValidationIssue("schema-version", f"{path}.schema_version", "unsupported node schema"))
        node_id_is_valid = _valid_stable_id(spec.node_id)
        if not node_id_is_valid:
            issues.append(ValidationIssue("stable-id", f"{path}.node_id", "invalid node ID"))
            issues.append(
                ValidationIssue(
                    "prerequisite-node-identity-shape",
                    f"{path}.node_id",
                    "node and owner IDs must be hashable canonical stable IDs",
                )
            )
        else:
            if spec.node_id in node_ids:
                issues.append(ValidationIssue("duplicate-node", f"{path}.node_id", "node ID must be unique"))
            node_ids.add(spec.node_id)
            canonical_spec = MANDATORY_SPECS_BY_ID.get(spec.node_id)
            if canonical_spec is not None and spec != canonical_spec:
                issues.append(
                    ValidationIssue(
                        "mandatory-prerequisite-contract-drift",
                        path,
                        "mandatory node semantics differ from the frozen Gate F contract",
                    )
                )
        owner_id_is_valid = _valid_stable_id(spec.owner_id)
        if not owner_id_is_valid:
            issues.append(ValidationIssue("stable-id", f"{path}.owner_id", "invalid owner ID"))
            issues.append(
                ValidationIssue(
                    "prerequisite-node-identity-shape",
                    f"{path}.owner_id",
                    "node and owner IDs must be hashable canonical stable IDs",
                )
            )
        else:
            if spec.owner_id in owner_ids:
                issues.append(
                    ValidationIssue(
                        "duplicate-ownership",
                        f"{path}.owner_id",
                        "one owner cannot own multiple DAG nodes",
                    )
                )
            owner_ids.add(spec.owner_id)
        if not isinstance(spec.stage, PrerequisiteStage):
            issues.append(ValidationIssue("prerequisite-stage", f"{path}.stage", "stage is outside the closed prerequisite-stage enum"))
            issues.append(
                ValidationIssue(
                    "prerequisite-node-scalar-shape",
                    f"{path}.stage",
                    "node scalar fields must retain their closed immutable types",
                )
            )
        if not isinstance(spec.blocking_severity, BlockingSeverity):
            issues.append(ValidationIssue("blocking-severity", f"{path}.blocking_severity", "severity is outside the closed P0-P3 enum"))
            issues.append(
                ValidationIssue(
                    "prerequisite-node-scalar-shape",
                    f"{path}.blocking_severity",
                    "node scalar fields must retain their closed immutable types",
                )
            )
        if not _valid_stable_id(spec.source_authority):
            issues.append(ValidationIssue("stable-id", f"{path}.source_authority", "invalid source-authority ID"))
            issues.append(
                ValidationIssue(
                    "prerequisite-node-scalar-shape",
                    f"{path}.source_authority",
                    "node scalar fields must retain their closed immutable types",
                )
            )
        node_fields = (
            ("prerequisites", spec.prerequisites),
            ("required_identity_paths", spec.required_identity_paths),
            ("required_evidence_layers", spec.required_evidence_layers),
            ("allowed_skip_ids", spec.allowed_skip_ids),
            ("command_group_ids", spec.command_group_ids),
            ("receipt_output_ids", spec.receipt_output_ids),
            ("artifact_output_ids", spec.artifact_output_ids),
            ("invalidation_rules", spec.invalidation_rules),
        )
        malformed_fields: set[str] = set()
        for field_name, values in node_fields:
            if not isinstance(values, tuple):
                malformed_fields.add(field_name)
                issues.append(
                    ValidationIssue(
                        "prerequisite-node-field-type",
                        f"{path}.{field_name}",
                        "node collection fields must be immutable tuples",
                    )
                )
                continue
            try:
                unique_count = len(set(values))
            except TypeError:
                malformed_fields.add(field_name)
                issues.append(
                    ValidationIssue(
                        "prerequisite-node-field-shape",
                        f"{path}.{field_name}",
                        "node field contains an unhashable malformed value",
                    )
                )
                continue
            if len(values) != unique_count:
                issues.append(
                    ValidationIssue(
                        "duplicate-node-field",
                        f"{path}.{field_name}",
                        "node field values must be unique",
                    )
                )
            if field_name == "required_evidence_layers":
                if any(not isinstance(value, EvidenceLayer) for value in values):
                    malformed_fields.add(field_name)
                    issues.append(
                        ValidationIssue(
                            "unknown-evidence-layer",
                            f"{path}.{field_name}",
                            "node references a layer outside the frozen evidence vocabulary",
                        )
                    )
                    issues.append(
                        ValidationIssue(
                            "prerequisite-node-field-shape",
                            f"{path}.{field_name}",
                            "node field contains a malformed evidence-layer value",
                        )
                    )
            else:
                for value_index, value in enumerate(values):
                    if not _valid_stable_id(value):
                        malformed_fields.add(field_name)
                        issues.append(
                            ValidationIssue(
                                "stable-id",
                                f"{path}.{field_name}[{value_index}]",
                                "value must be a canonical stable ID",
                            )
                        )
                        issues.append(
                            ValidationIssue(
                                "prerequisite-node-field-shape",
                                f"{path}.{field_name}[{value_index}]",
                                "node field contains a malformed identity value",
                            )
                        )
        if malformed_fields:
            continue
        if not spec.required_identity_paths:
            issues.append(ValidationIssue("empty-node-field", f"{path}.required_identity_paths", "must not be empty"))
        if not spec.required_evidence_layers:
            issues.append(ValidationIssue("empty-node-field", f"{path}.required_evidence_layers", "must not be empty"))
        if not spec.command_group_ids or not spec.receipt_output_ids or not spec.artifact_output_ids:
            issues.append(ValidationIssue("empty-node-output", path, "commands and receipt/artifact outputs are required"))
        unknown_command_groups = set(spec.command_group_ids) - LANE_C_COMMAND_GROUP_IDS
        if unknown_command_groups:
            issues.append(
                ValidationIssue(
                    "unknown-command-group",
                    f"{path}.command_group_ids",
                    "node references command groups outside Lane C: "
                    + ", ".join(sorted(unknown_command_groups)),
                )
            )
        missing_command_layers = tuple(
            layer
            for layer in spec.required_evidence_layers
            if not any(
                authority.evidence_layer is layer
                and bool(
                    set(authority.command_groups) & set(spec.command_group_ids)
                )
                for authority in LANE_C_COMMAND_AUTHORITIES
            )
        )
        if missing_command_layers:
            issues.append(
                ValidationIssue(
                    "prerequisite-command-authority-unavailable",
                    f"{path}.command_group_ids",
                    "no exact Lane C command has both a node-owned group and each required layer: "
                    + ", ".join(layer.value for layer in missing_command_layers),
                )
            )
        if not spec.invalidation_rules:
            issues.append(ValidationIssue("empty-invalidation-rules", f"{path}.invalidation_rules", "must not be empty"))
        if spec.stop_condition is not None and not _valid_stable_id(spec.stop_condition):
            issues.append(ValidationIssue("stable-id", f"{path}.stop_condition", "invalid stop condition"))
            issues.append(
                ValidationIssue(
                    "prerequisite-node-scalar-shape",
                    f"{path}.stop_condition",
                    "node scalar fields must retain their closed immutable types",
                )
            )
    missing_nodes = MANDATORY_NODE_IDS - node_ids
    if missing_nodes:
        issues.append(
            ValidationIssue(
                "missing-mandatory-prerequisite",
                "$.prerequisite_nodes",
                "required Gate F subjects are absent: " + ", ".join(sorted(missing_nodes)),
            )
        )
    if any(
        issue.code
        in {
            "prerequisite-node-field-type",
            "prerequisite-node-field-shape",
            "prerequisite-node-identity-shape",
            "prerequisite-node-scalar-shape",
        }
        for issue in issues
    ):
        return issues
    valid_specs = tuple(
        spec for spec in specs if isinstance(spec, PrerequisiteNodeSpec)
    )
    for index, spec in enumerate(valid_specs):
        for dependency in spec.prerequisites:
            if dependency not in node_ids:
                issues.append(
                    ValidationIssue(
                        "unknown-prerequisite-edge",
                        f"$.prerequisite_nodes[{index}].prerequisites",
                        f"unknown prerequisite node {dependency}",
                    )
                )
    by_id = {spec.node_id: spec for spec in valid_specs}
    observed_edges = {
        (prerequisite, spec.node_id)
        for spec in valid_specs
        for prerequisite in spec.prerequisites
    }
    missing_edges = MANDATORY_PREREQUISITE_EDGES - observed_edges
    if missing_edges:
        issues.append(
            ValidationIssue(
                "missing-mandatory-prerequisite-edge",
                "$.prerequisite_nodes",
                "required Gate F edges are absent: "
                + ", ".join(
                    f"{prerequisite}->{dependent}"
                    for prerequisite, dependent in sorted(missing_edges)
                ),
            )
        )
    stage_rank = {
        PrerequisiteStage.PREMERGE: 0,
        PrerequisiteStage.MERGE: 1,
        PrerequisiteStage.POSTMERGE: 2,
    }
    for index, spec in enumerate(valid_specs):
        if not isinstance(spec.stage, PrerequisiteStage):
            continue
        for dependency in spec.prerequisites:
            prerequisite = by_id.get(dependency)
            if prerequisite is None or not isinstance(prerequisite.stage, PrerequisiteStage):
                continue
            if stage_rank[prerequisite.stage] > stage_rank[spec.stage]:
                issues.append(
                    ValidationIssue(
                        "prerequisite-stage-order",
                        f"$.prerequisite_nodes[{index}].prerequisites",
                        "a node cannot depend on a later qualification stage",
                    )
                )
    return issues


def _topological_order(
    specs: Sequence[PrerequisiteNodeSpec],
) -> tuple[tuple[str, ...], list[ValidationIssue]]:
    by_id = {spec.node_id: spec for spec in specs}
    indegree = {node_id: 0 for node_id in by_id}
    dependents: dict[str, set[str]] = {node_id: set() for node_id in by_id}
    for spec in specs:
        for prerequisite in spec.prerequisites:
            if prerequisite not in by_id:
                continue
            indegree[spec.node_id] += 1
            dependents[prerequisite].add(spec.node_id)
    ready = [node_id for node_id, degree in indegree.items() if degree == 0]
    heapq.heapify(ready)
    ordered: list[str] = []
    while ready:
        node_id = heapq.heappop(ready)
        ordered.append(node_id)
        for dependent in sorted(dependents[node_id]):
            indegree[dependent] -= 1
            if indegree[dependent] == 0:
                heapq.heappush(ready, dependent)
    if len(ordered) != len(by_id):
        cyclic = sorted(node_id for node_id, degree in indegree.items() if degree > 0)
        return (), [
            ValidationIssue(
                "prerequisite-cycle",
                "$.prerequisite_nodes",
                f"cycle involves: {', '.join(cyclic)}",
            )
        ]
    return tuple(ordered), []


def compile_prerequisite_dag(
    contract: SourceContract,
    specs: Sequence[PrerequisiteNodeSpec] = DEFAULT_PREREQUISITE_SPECS,
) -> tuple[PrerequisiteDAG | None, tuple[ValidationIssue, ...]]:
    """Compile and validate a DAG against the supplied immutable contract."""

    issues = _validate_specs(specs)
    if any(
        issue.code
        in {
            "prerequisite-node-type",
            "prerequisite-specs-type",
            "prerequisite-node-field-type",
            "prerequisite-node-field-shape",
            "prerequisite-node-identity-shape",
            "prerequisite-node-scalar-shape",
        }
        for issue in issues
    ):
        return None, tuple(sorted(set(issues)))
    if not isinstance(contract, SourceContract):
        issues.append(
            ValidationIssue(
                "source-contract-type",
                "$.source_contract",
                "contract must be a SourceContract",
            )
        )
        return None, tuple(sorted(set(issues)))
    try:
        contract_mapping = source_contract_to_mapping(contract)
    except (AttributeError, KeyError, RecursionError, TypeError, ValueError):
        issues.append(
            ValidationIssue(
                "source-contract-canonicalization",
                "$.source_contract",
                "contract contains malformed public DTO values",
            )
        )
        return None, tuple(sorted(set(issues)))
    canonical_contract, contract_issues = parse_source_contract(contract_mapping)
    issues.extend(contract_issues)
    if canonical_contract is None:
        return None, tuple(sorted(set(issues)))
    contract = canonical_contract
    if contract.schema_version != SOURCE_CONTRACT_SCHEMA_VERSION:
        issues.append(
            ValidationIssue(
                "schema-version",
                "$.source_contract.schema_version",
                "unsupported source-contract schema",
            )
        )
    if not is_sha256(contract.compiler_identity_sha256):
        issues.append(
            ValidationIssue(
                "sha256",
                "$.source_contract.compiler_identity_sha256",
                "compiler identity must be a lowercase 64-hex SHA-256",
            )
        )
    order, nested = _topological_order(specs)
    issues.extend(nested)

    authorities = subject_authorities(contract)
    specs_by_id = {spec.node_id: spec for spec in specs}
    compiled: list[CompiledPrerequisiteNode] = []
    for index, spec in enumerate(specs):
        path = f"$.prerequisite_nodes[{index}]"
        authority = authorities.get(spec.node_id)
        if authority is None:
            issues.append(
                ValidationIssue(
                    "missing-subject-authority",
                    path,
                    f"source contract has no authority for {spec.node_id}",
                )
            )
            continue
        if authority.owner_id != spec.owner_id:
            issues.append(
                ValidationIssue(
                    "ownership-mismatch",
                    f"{path}.owner_id",
                    "DAG owner does not equal supplied subject owner",
                )
            )

        identity_candidate = contract.candidate
        if (
            contract.candidate.subject_kind is CandidateSubjectKind.POST_MERGE
            and (
                spec.stage is PrerequisiteStage.PREMERGE
                or spec.node_id == "merge-authorized"
            )
            and contract.prospective_candidate is not None
        ):
            identity_candidate = contract.prospective_candidate
        for identity_path in spec.required_identity_paths:
            if not required_identity_path_is_known(
                contract,
                identity_path,
                candidate=identity_candidate,
            ):
                issues.append(
                    ValidationIssue(
                        "unknown-required-identity",
                        f"{path}.required_identity_paths",
                        f"required identity path is not in the candidate schema: {identity_path}",
                    )
                )

        claims_identity = authority.status in {
            PrerequisiteStatus.RUNNING,
            PrerequisiteStatus.FAILED,
            PrerequisiteStatus.INVALID,
            PrerequisiteStatus.ACCEPTED,
        }
        if claims_identity:
            missing_identity = False
            for identity_path in spec.required_identity_paths:
                if resolve_required_identity(
                    contract,
                    identity_path,
                    candidate=identity_candidate,
                ) is None:
                    missing_identity = True
                    issues.append(
                        ValidationIssue(
                            "unavailable-required-identity",
                            f"{path}.required_identity_paths",
                            f"required identity is unavailable: {identity_path}",
                        )
                    )
            expected_identity_sha256 = prerequisite_identity_sha256(contract, spec)
            if (
                not missing_identity
                and expected_identity_sha256 is not None
                and authority.identity_sha256 != expected_identity_sha256
            ):
                issues.append(
                    ValidationIssue(
                        "required-identity-digest-mismatch",
                        f"{path}.required_identity_paths",
                        "subject identity digest does not commit the node's exact required axes",
                    )
                )

        if claims_identity:
            for prerequisite_id in spec.prerequisites:
                prerequisite_authority = authorities.get(prerequisite_id)
                if (
                    prerequisite_authority is None
                    or prerequisite_authority.status is not PrerequisiteStatus.ACCEPTED
                ):
                    issues.append(
                        ValidationIssue(
                            "contradictory-prerequisite-state",
                            path,
                            f"accepted node depends on non-accepted {prerequisite_id}",
                        )
                    )
        compiled.append(CompiledPrerequisiteNode(spec=spec, authority=authority))

    known_subjects = set(specs_by_id)
    for subject in contract.subjects:
        if subject.subject_id not in known_subjects:
            issues.append(
                ValidationIssue(
                    "unknown-source-subject",
                    "$.source_contract.subjects",
                    f"source subject is not owned by the Gate F DAG: {subject.subject_id}",
                )
            )

    if issues:
        return None, tuple(sorted(set(issues)))
    return (
        PrerequisiteDAG(
            source_contract_sha256=source_contract_sha256(contract),
            nodes=tuple(sorted(compiled, key=lambda item: item.spec.node_id)),
            topological_order=order,
        ),
        (),
    )


def accepted_node_ids(dag: PrerequisiteDAG) -> frozenset[str]:
    return frozenset(
        node.spec.node_id
        for node in dag.nodes
        if node.authority.status is PrerequisiteStatus.ACCEPTED
    )


__all__ = [
    "EXACT_SCENARIO_CONSTITUENT_COMMAND_IDS",
    "LANE_C_COMMAND_AUTHORITIES",
    "LANE_C_COMMAND_AUTHORITIES_BY_ID",
    "LANE_C_COMMAND_AUTHORITY_SHA256",
    "LANE_C_COMMAND_GROUP_IDS",
    "LANE_C_COMMAND_PREREQUISITES",
    "LANE_C_SCENARIO_BINDINGS",
    "LANE_C_SCENARIO_BINDINGS_BY_ID",
    "LANE_C_SCENARIO_BINDING_SHA256",
    "LANE_C_SCENARIO_GROUPS",
    "LANE_C_SCENARIO_GROUPS_BY_ID",
    "PREREQUISITE_NODE_SCHEMA_VERSION",
    "BlockingSeverity",
    "CompiledPrerequisiteNode",
    "DEFAULT_PREREQUISITE_SPECS",
    "MANDATORY_NODE_IDS",
    "MANDATORY_PREREQUISITE_EDGES",
    "MANDATORY_SPECS_BY_ID",
    "LaneCCommandAuthority",
    "LaneCCommandRecordAuthority",
    "LaneCIntegratedCommandPlanInput",
    "LaneCScenarioBindingAuthority",
    "LaneCScenarioPlanAuthority",
    "PrerequisiteDAG",
    "PrerequisiteNodeSpec",
    "PrerequisiteStage",
    "accepted_node_ids",
    "compile_prerequisite_dag",
    "prerequisite_identity_sha256",
    "lane_c_command_records",
    "lane_c_receipt_scenario_ids",
    "required_identity_path_is_known",
    "resolve_required_identity",
    "validate_lane_c_command_catalog",
    "validate_lane_c_command_plan",
    "validate_integrated_lane_c_command_plan",
]
