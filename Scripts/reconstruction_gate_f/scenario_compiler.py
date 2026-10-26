"""Deterministic Gate F scenario-matrix compiler.

The commissioned catalog is explicit.  Pairwise authority closure is generated
by a deterministic greedy covering-array pass, while the named higher-order
races remain separate because their failures depend on three or more events
sharing one authority lifetime.
"""

from __future__ import annotations

import hashlib
import itertools
from collections.abc import Iterable, Sequence
from functools import lru_cache

from .canonical_json import canonical_sha256, to_primitive
from .scenario_model import (
    SCENARIO_SCHEMA_VERSION,
    PairwiseCoverage,
    PairwiseFactor,
    Scenario,
    ScenarioCatalog,
    ScenarioDomain,
    ScenarioOrigin,
    ScenarioParameter,
    validate_scenario_catalog,
)
from .schema import (
    CandidateIdentity,
    EvidenceLayer,
    candidate_identity_sha256,
    candidate_to_mapping,
    validate_candidate_identity,
)


class ScenarioCompilationError(ValueError):
    pass


RECONSTRUCTION_JOB_STATES = (
    "accepting-evidence",
    "awaiting-model",
    "cancelled",
    "checkpointing",
    "completed",
    "created",
    "executing-reads",
    "failed",
    "indexing",
    "ingesting",
    "paused",
    "retrieving",
)

TASK10_COMMANDS = ("cancel", "create", "pause", "resume", "start")


def _parameters(**values: str) -> tuple[ScenarioParameter, ...]:
    return tuple(sorted(ScenarioParameter(name, value) for name, value in values.items()))


PAIRWISE_FACTORS = (
    PairwiseFactor(
        "authority",
        ("exact-job", "foreign-job", "foreign-window", "stale-revision"),
    ),
    PairwiseFactor(
        "cancellation",
        ("after-enqueue", "before-enqueue", "during-release", "during-removal", "none"),
    ),
    PairwiseFactor(
        "publication",
        ("after-terminal", "before-terminal", "none"),
    ),
    PairwiseFactor(
        "resource",
        (
            "combined-extremes",
            "insufficient-memory",
            "memory-extreme",
            "nominal",
            "processor-extreme",
        ),
    ),
    PairwiseFactor(
        "session",
        ("concurrent-resolution", "existing", "reset-race"),
    ),
)


# This is the sole executable meaning of the commissioned durable scenarios.
# It intentionally lives beside the catalog rather than in the runner so a
# scenario cannot acquire a second, hand-transcribed execution definition.
# ``durable.conversion-overflow`` is absent: the production inputs bound
# ``selectedWidth`` to ``Int.max``, which makes the defensive conversion
# failure mathematically unconstructible.  It remains a focused adjudication
# scenario, but is not allowed to masquerade as executed stress evidence.
DURABLE_STRESS_PARAMETERS = {
    "durable.correct-job-bound-scheduling": _parameters(
        authority="exact-job", scheduler="batch"
    ),
    "durable.foreign-job-authority-rejected": _parameters(
        authority="foreign-job", scheduler="batch"
    ),
    "durable.pause-resume-retire-lifecycle": _parameters(
        lifecycle="pause-resume-retire"
    ),
    "durable.waiter-cancel-before-enqueue": _parameters(
        cancellation="before-enqueue"
    ),
    "durable.waiter-cancel-after-enqueue": _parameters(
        cancellation="after-enqueue"
    ),
    "durable.waiter-cancel-during-removal": _parameters(
        cancellation="during-removal"
    ),
    "durable.waiter-cancel-during-release": _parameters(
        cancellation="during-release"
    ),
    "durable.cancelled-waiter-skipped-delayed-removal": _parameters(
        cancellation="during-removal",
        release="concurrent",
        removal="delayed",
        waiter="cancelled",
    ),
    "durable.insufficient-memory": _parameters(resource="insufficient-memory"),
    "durable.provider-width-processor-extreme": _parameters(
        resource="processor-extreme"
    ),
    "durable.provider-width-memory-extreme": _parameters(
        resource="memory-extreme"
    ),
    "durable.cancel-before-terminal-publication": _parameters(
        cancellation="before-terminal", publication="before-terminal"
    ),
    "durable.cancel-after-terminal-publication": _parameters(
        cancellation="after-terminal", publication="terminal"
    ),
    "durable.concurrent-session-resolution-coalesces": _parameters(
        authority="exact-job", session="concurrent-resolution"
    ),
    "durable.one-window-one-session": _parameters(
        session="existing", window="session-owner"
    ),
    "durable.session-reset-fences-late-resolution": _parameters(
        session="reset-race"
    ),
}


def selector_catalog_identity_sha256() -> str:
    """Hash the candidate-independent commissioned selector definition.

    A compiled ``ScenarioCatalog`` contains the candidate digest and therefore
    cannot itself be embedded in that candidate without a circular identity.
    This digest closes the full commissioned/higher-order/pairwise definition
    while deliberately excluding candidate-bound execution state.
    """

    normalized, matrix, coverage = pairwise_scenarios(PAIRWISE_FACTORS)
    scenarios = tuple(
        sorted(
            commissioned_scenarios() + higher_order_scenarios() + matrix,
            key=lambda item: item.scenario_id,
        )
    )
    return canonical_sha256(
        {
            "pairwise_coverage": to_primitive(coverage),
            "pairwise_factors": to_primitive(normalized),
            "required_scenario_ids": list(REQUIRED_SCENARIO_IDS),
            "schema_version": SCENARIO_SCHEMA_VERSION,
            "scenarios": to_primitive(scenarios),
        }
    )


def _layers(*values: EvidenceLayer) -> tuple[EvidenceLayer, ...]:
    return tuple(sorted(set(values), key=lambda item: item.value))


def _ids(*values: str) -> tuple[str, ...]:
    return tuple(sorted(set(values)))


def _scenario(
    scenario_id: str,
    domain: ScenarioDomain,
    title: str,
    *,
    groups: tuple[str, ...],
    layers: tuple[EvidenceLayer, ...],
    parameters: tuple[ScenarioParameter, ...] = (),
    origin: ScenarioOrigin = ScenarioOrigin.COMMISSIONED,
    rationale: str | None = None,
) -> Scenario:
    return Scenario(
        schema_version=SCENARIO_SCHEMA_VERSION,
        scenario_id=scenario_id,
        domain=domain,
        title=title,
        requirement_ids=(f"gate-f.{scenario_id}",),
        parameters=tuple(sorted(parameters)),
        evidence_layers=tuple(sorted(set(layers), key=lambda item: item.value)),
        command_groups=_ids(*groups),
        origin=origin,
        higher_order_rationale=rationale,
    )


_BASE_COMMISSIONED = (
    # Durable authority and concurrency.
    ("durable.correct-job-bound-scheduling", ScenarioDomain.DURABLE_AUTHORITY, "Correct job-bound scheduling", ("reconstruction-concurrency",)),
    ("durable.foreign-job-authority-rejected", ScenarioDomain.DURABLE_AUTHORITY, "Foreign job authority is rejected", ("reconstruction-concurrency",)),
    ("durable.pause-resume-retire-lifecycle", ScenarioDomain.DURABLE_AUTHORITY, "Pause, resume, and internal retire lifecycle", ("reconstruction-concurrency",)),
    ("durable.waiter-cancel-before-enqueue", ScenarioDomain.DURABLE_AUTHORITY, "Queued waiter cancellation before enqueue", ("reconstruction-concurrency",)),
    ("durable.waiter-cancel-after-enqueue", ScenarioDomain.DURABLE_AUTHORITY, "Queued waiter cancellation after enqueue", ("reconstruction-concurrency",)),
    ("durable.waiter-cancel-during-removal", ScenarioDomain.DURABLE_AUTHORITY, "Queued waiter cancellation during removal", ("reconstruction-concurrency",)),
    ("durable.waiter-cancel-during-release", ScenarioDomain.DURABLE_AUTHORITY, "Queued waiter cancellation during release", ("reconstruction-concurrency",)),
    ("durable.cancelled-waiter-skipped-delayed-removal", ScenarioDomain.DURABLE_AUTHORITY, "Cancelled waiter is skipped while removal is delayed", ("reconstruction-concurrency",)),
    ("durable.insufficient-memory", ScenarioDomain.DURABLE_AUTHORITY, "Insufficient memory fails closed", ("reconstruction-concurrency",)),
    ("durable.conversion-overflow", ScenarioDomain.DURABLE_AUTHORITY, "Memory conversion overflow fails closed", ("reconstruction-concurrency",)),
    ("durable.provider-width-processor-extreme", ScenarioDomain.DURABLE_AUTHORITY, "Provider width is bounded at processor extreme", ("reconstruction-concurrency",)),
    ("durable.provider-width-memory-extreme", ScenarioDomain.DURABLE_AUTHORITY, "Provider width is bounded at memory extreme", ("reconstruction-concurrency",)),
    ("durable.cancel-before-terminal-publication", ScenarioDomain.DURABLE_AUTHORITY, "Cancellation before terminal publication is fenced", ("reconstruction-concurrency",)),
    ("durable.cancel-after-terminal-publication", ScenarioDomain.DURABLE_AUTHORITY, "Cancellation after terminal publication cannot replace authority", ("reconstruction-concurrency",)),
    ("durable.concurrent-session-resolution-coalesces", ScenarioDomain.DURABLE_AUTHORITY, "Concurrent session resolution coalesces", ("reconstruction-session",)),
    ("durable.one-window-one-session", ScenarioDomain.DURABLE_AUTHORITY, "One window owns one durable session", ("reconstruction-session",)),
    ("durable.session-reset-fences-late-resolution", ScenarioDomain.DURABLE_AUTHORITY, "Session reset fences late resolution", ("reconstruction-session",)),
    # Persistence and orchestration.
    ("persistence.atomic-initial-transaction", ScenarioDomain.PERSISTENCE, "Initial corpus, job, task, and checkpoint are atomic", ("reconstruction-persistence",)),
    ("persistence.creation-ordinal", ScenarioDomain.PERSISTENCE, "Creation ordinal is persisted", ("reconstruction-persistence",)),
    ("persistence.legacy-schema-compatibility", ScenarioDomain.PERSISTENCE, "Legacy schema preserves creation authority", ("reconstruction-persistence",)),
    ("persistence.task-identity-verification", ScenarioDomain.PERSISTENCE, "Task identity is reverified", ("reconstruction-persistence",)),
    ("persistence.checkpoint-frontier-revision-fencing", ScenarioDomain.PERSISTENCE, "Checkpoint, frontier, and revision fences agree", ("reconstruction-persistence",)),
    ("persistence.save-reopen-restore", ScenarioDomain.PERSISTENCE, "Save, reopen, and restore preserve the exact projection", ("reconstruction-persistence",)),
    ("persistence.crash-recovery", ScenarioDomain.PERSISTENCE, "Crash recovery does not replay terminal work", ("reconstruction-persistence",)),
    ("persistence.missing-model-pause-resume", ScenarioDomain.PERSISTENCE, "Missing model pauses and later resumes", ("reconstruction-rounds",)),
    ("persistence.terminal-success", ScenarioDomain.PERSISTENCE, "Terminal success is durable", ("reconstruction-rounds",)),
    ("persistence.terminal-failure", ScenarioDomain.PERSISTENCE, "Terminal failure is durable", ("reconstruction-rounds",)),
    ("persistence.terminal-cancel", ScenarioDomain.PERSISTENCE, "Terminal cancellation is durable", ("reconstruction-rounds",)),
    ("persistence.terminal-retire", ScenarioDomain.PERSISTENCE, "Internal retirement is durable lifecycle only", ("reconstruction-rounds",)),
    ("persistence.duplicate-command-suppression", ScenarioDomain.PERSISTENCE, "Duplicate commands are suppressed", ("reconstruction-rounds",)),
    ("persistence.task9-multi-round-regression", ScenarioDomain.PERSISTENCE, "Task 9 multi-round orchestration remains deterministic", ("reconstruction-rounds",)),
    # Task 8 closed protocol catalog and hostile sequencing.
    ("task8.request.round", ScenarioDomain.TASK8_PROTOCOL, "Round request discriminator", ("reconstruction-task8",)),
    ("task8.request.final-synthesis", ScenarioDomain.TASK8_PROTOCOL, "Final synthesis request discriminator", ("reconstruction-task8",)),
    ("task8.event.round-candidate", ScenarioDomain.TASK8_PROTOCOL, "Round candidate event discriminator", ("reconstruction-task8",)),
    ("task8.event.final-candidate", ScenarioDomain.TASK8_PROTOCOL, "Final candidate event discriminator", ("reconstruction-task8",)),
    ("task8.event.usage", ScenarioDomain.TASK8_PROTOCOL, "Usage event discriminator", ("reconstruction-task8",)),
    ("task8.event.completed", ScenarioDomain.TASK8_PROTOCOL, "Completed event discriminator", ("reconstruction-task8",)),
    ("task8.reply.accepted", ScenarioDomain.TASK8_PROTOCOL, "XPC event reply accepts the exact event", ("reconstruction-task8",)),
    ("task8.reply.rejected", ScenarioDomain.TASK8_PROTOCOL, "XPC event reply rejects invalid authority", ("reconstruction-task8",)),
    ("task8.mismatch.version", ScenarioDomain.TASK8_PROTOCOL, "Protocol version mismatch", ("reconstruction-task8",)),
    ("task8.mismatch.identity", ScenarioDomain.TASK8_PROTOCOL, "Protocol identity mismatch", ("reconstruction-task8",)),
    ("task8.mismatch.correlation", ScenarioDomain.TASK8_PROTOCOL, "Request correlation mismatch", ("reconstruction-task8",)),
    ("task8.event.malformed", ScenarioDomain.TASK8_PROTOCOL, "Malformed event", ("reconstruction-task8",)),
    ("task8.event.duplicate", ScenarioDomain.TASK8_PROTOCOL, "Duplicate event", ("reconstruction-task8",)),
    ("task8.event.stale", ScenarioDomain.TASK8_PROTOCOL, "Stale event", ("reconstruction-task8",)),
    ("task8.event.reordered", ScenarioDomain.TASK8_PROTOCOL, "Reordered event", ("reconstruction-task8",)),
    ("task8.event.post-terminal", ScenarioDomain.TASK8_PROTOCOL, "Post-terminal event", ("reconstruction-task8",)),
    ("task8.cancel.before-dispatch", ScenarioDomain.TASK8_PROTOCOL, "Cancellation before worker dispatch", ("reconstruction-task8",)),
    ("task8.cancel.during-stream", ScenarioDomain.TASK8_PROTOCOL, "Cancellation during worker stream", ("reconstruction-task8",)),
    ("task8.cancel.after-terminal", ScenarioDomain.TASK8_PROTOCOL, "Cancellation after terminal event", ("reconstruction-task8",)),
    ("task8.legacy-assistant-compatibility", ScenarioDomain.TASK8_PROTOCOL, "Legacy Assistant protocol remains unchanged", ("reconstruction-task8",)),
    ("task8.signed-worker-parity", ScenarioDomain.TASK8_PROTOCOL, "Signed worker matches pure protocol behavior", ("task8-signed-worker",)),
    # Task 10 non-state/command dimensions.
    ("task10.provider.ready-idle-valid-revision", ScenarioDomain.TASK10_PRESENTATION, "Ready idle provider with valid revision", ("reconstruction-task10",)),
    ("task10.provider.ready-busy", ScenarioDomain.TASK10_PRESENTATION, "Ready but busy provider disables execution", ("reconstruction-task10",)),
    ("task10.provider.ready-invalid-revision", ScenarioDomain.TASK10_PRESENTATION, "Invalid provider revision disables execution", ("reconstruction-task10",)),
    ("task10.provider.not-ready", ScenarioDomain.TASK10_PRESENTATION, "Unavailable provider is visible", ("reconstruction-task10",)),
    ("task10.restore.inactive", ScenarioDomain.TASK10_PRESENTATION, "Inactive restoration is unavailable", ("reconstruction-task10",)),
    ("task10.restore.activating", ScenarioDomain.TASK10_PRESENTATION, "Activating restoration blocks commands", ("reconstruction-task10",)),
    ("task10.restore.restoring", ScenarioDomain.TASK10_PRESENTATION, "Restoring durable state blocks commands", ("reconstruction-task10",)),
    ("task10.restore.failed-document-location", ScenarioDomain.TASK10_PRESENTATION, "Missing durable document location is explicit", ("reconstruction-task10",)),
    ("task10.restore.failed-sidecar", ScenarioDomain.TASK10_PRESENTATION, "Unavailable sidecar is explicit", ("reconstruction-task10",)),
    ("task10.restore.failed-restoration", ScenarioDomain.TASK10_PRESENTATION, "Restoration failure is explicit", ("reconstruction-task10",)),
    ("task10.restore.failed-stale-lifecycle", ScenarioDomain.TASK10_PRESENTATION, "Stale lifecycle restoration is fenced", ("reconstruction-task10",)),
    ("task10.restore.runtime-unavailable", ScenarioDomain.TASK10_PRESENTATION, "Missing runtime boundary fails closed", ("reconstruction-task10",)),
    ("task10.creation.empty-objective", ScenarioDomain.TASK10_PRESENTATION, "Empty creation objective is rejected", ("reconstruction-task10",)),
    ("task10.creation.whitespace-objective", ScenarioDomain.TASK10_PRESENTATION, "Whitespace creation objective is rejected", ("reconstruction-task10",)),
    ("task10.creation.objective-normalization", ScenarioDomain.TASK10_PRESENTATION, "Creation objective normalization is canonical", ("reconstruction-task10",)),
    ("task10.creation.objective-byte-bound", ScenarioDomain.TASK10_PRESENTATION, "Creation objective UTF-8 bound is enforced", ("reconstruction-task10",)),
    ("task10.creation.empty-roots", ScenarioDomain.TASK10_PRESENTATION, "Empty creation root selection is rejected", ("reconstruction-task10",)),
    ("task10.creation.two-roots-canonical", ScenarioDomain.TASK10_PRESENTATION, "Two selected roots preserve canonical set order", ("reconstruction-task10",)),
    ("task10.creation.budget-min-max", ScenarioDomain.TASK10_PRESENTATION, "Creation budget minimum and maximum are accepted", ("reconstruction-task10",)),
    ("task10.creation.budget-out-of-range", ScenarioDomain.TASK10_PRESENTATION, "Every out-of-policy creation budget is rejected", ("reconstruction-task10",)),
    ("task10.resume.exact-target", ScenarioDomain.TASK10_PRESENTATION, "Resume requires the exact durable target", ("reconstruction-task10",)),
    ("task10.resume.missing-target", ScenarioDomain.TASK10_PRESENTATION, "Missing resume target is rejected", ("reconstruction-task10",)),
    ("task10.resume.stale-target", ScenarioDomain.TASK10_PRESENTATION, "Stale resume target is rejected", ("reconstruction-task10",)),
    ("task10.diagnostic.reason-identity", ScenarioDomain.TASK10_PRESENTATION, "Terminal state is cause identity and diagnostic digest is detail identity", ("reconstruction-task10",)),
    ("task10.diagnostic.detail-bounds", ScenarioDomain.TASK10_PRESENTATION, "Diagnostic detail is privacy-safe and bounded", ("reconstruction-task10",)),
    ("task10.navigation.exact-source-coordinate", ScenarioDomain.TASK10_PRESENTATION, "Exact source-qualified evidence navigation", ("reconstruction-task10",)),
    ("task10.navigation.stale-selection", ScenarioDomain.TASK10_PRESENTATION, "Stale navigation selection is refused", ("reconstruction-task10",)),
    ("task10.navigation.sibling-selection", ScenarioDomain.TASK10_PRESENTATION, "Sibling navigation selection is refused", ("reconstruction-task10",)),
    ("task10.multi-window-isolation", ScenarioDomain.TASK10_PRESENTATION, "Window-local task, evidence, inspector, filter, and pending state is isolated", ("reconstruction-task10",)),
    ("task10.accessibility.catalog", ScenarioDomain.TASK10_PRESENTATION, "Accessibility identifier catalog is exact and unique", ("reconstruction-task10",)),
    ("task10.accessibility.roles-labels-values-actions", ScenarioDomain.TASK10_PRESENTATION, "Accessibility roles, labels, values, and actions remain semantic", ("reconstruction-task10",)),
    ("task10.status.blocked", ScenarioDomain.TASK10_PRESENTATION, "Blocked status is visible", ("reconstruction-task10",)),
    ("task10.status.unavailable", ScenarioDomain.TASK10_PRESENTATION, "Unavailable status is visible", ("reconstruction-task10",)),
    ("task10.status.failed", ScenarioDomain.TASK10_PRESENTATION, "Failed status is visible", ("reconstruction-task10",)),
    ("task10.status.completed", ScenarioDomain.TASK10_PRESENTATION, "Completed status is distinct from partial failure", ("reconstruction-task10",)),
    ("task10.status.restored", ScenarioDomain.TASK10_PRESENTATION, "Restored status reflects durable state", ("reconstruction-task10",)),
    ("task10.status.stale", ScenarioDomain.TASK10_PRESENTATION, "Stale status fails closed", ("reconstruction-task10",)),
    # Native, XPC, build, and installed qualification.
    ("native.governed-package-verification", ScenarioDomain.NATIVE_INSTALL, "Governed native package verification", ("native-normal",)),
    ("native.normal", ScenarioDomain.NATIVE_INSTALL, "Native normal selectors", ("native-normal",)),
    ("native.asan", ScenarioDomain.NATIVE_INSTALL, "Native AddressSanitizer selectors", ("native-asan",)),
    ("native.ubsan", ScenarioDomain.NATIVE_INSTALL, "Native UndefinedBehaviorSanitizer selectors", ("native-ubsan",)),
    ("native.golden", ScenarioDomain.NATIVE_INSTALL, "Native cross-language golden validation", ("native-golden",)),
    ("signed-xpc.complete", ScenarioDomain.NATIVE_INSTALL, "Signed XPC complete result path", ("signed-xpc-content",)),
    ("signed-xpc.truncated", ScenarioDomain.NATIVE_INSTALL, "Signed XPC valid truncated result path", ("signed-xpc-content",)),
    ("signed-xpc.error", ScenarioDomain.NATIVE_INSTALL, "Signed XPC error path", ("signed-xpc-error-cancellation",)),
    ("signed-xpc.cancellation", ScenarioDomain.NATIVE_INSTALL, "Signed XPC cancellation path", ("signed-xpc-error-cancellation",)),
    ("release.build", ScenarioDomain.NATIVE_INSTALL, "Release candidate build", ("release",)),
    ("release.strict-signing", ScenarioDomain.NATIVE_INSTALL, "Strict deep signing and entitlements", ("strict-signing",)),
    ("release.embedded-service-identities", ScenarioDomain.NATIVE_INSTALL, "Exact embedded service identities", ("strict-signing",)),
    ("installed.source-binary-equality", ScenarioDomain.NATIVE_INSTALL, "Installed source and binary equality", ("installed-equality",)),
    ("installed.launch-log", ScenarioDomain.NATIVE_INSTALL, "Installed launch and bounded log checks", ("installed-launch",)),
    ("installed.no-unauthorized-network-or-acquisition", ScenarioDomain.NATIVE_INSTALL, "Runtime performs no unauthorized network or dependency acquisition", ("installed-network-audit",)),
    ("installed.task10.create", ScenarioDomain.NATIVE_INSTALL, "Installed Create control", ("installed-task10",)),
    ("installed.task10.start", ScenarioDomain.NATIVE_INSTALL, "Installed Start control", ("installed-task10",)),
    ("installed.task10.pause", ScenarioDomain.NATIVE_INSTALL, "Installed Pause control", ("installed-task10",)),
    ("installed.task10.resume", ScenarioDomain.NATIVE_INSTALL, "Installed Resume control", ("installed-task10",)),
    ("installed.task10.cancel", ScenarioDomain.NATIVE_INSTALL, "Installed Cancel control", ("installed-task10",)),
    ("installed.accessibility", ScenarioDomain.NATIVE_INSTALL, "Installed accessibility semantics", ("installed-accessibility",)),
    # Merge and post-merge identity attacks.
    ("merge.candidate-head-differs-from-receipt", ScenarioDomain.MERGE_POSTMERGE, "Candidate head differs from receipt", ("merge-qualification",)),
    ("merge.prospective-tree-differs", ScenarioDomain.MERGE_POSTMERGE, "Prospective merge tree differs from accepted tree", ("merge-qualification",)),
    ("merge.workflow-success-wrong-sha", ScenarioDomain.MERGE_POSTMERGE, "Workflow success belongs to another SHA", ("merge-qualification",)),
    ("merge.governed-files-changed", ScenarioDomain.MERGE_POSTMERGE, "Merge introduces changed governed files", ("merge-qualification",)),
    ("postmerge.source-installed-binary-differs", ScenarioDomain.MERGE_POSTMERGE, "Post-merge source differs from installed binary", ("postmerge-qualification",)),
    ("postmerge.stale-after-dependency-toolchain-movement", ScenarioDomain.MERGE_POSTMERGE, "Evidence is stale after dependency or toolchain movement", ("postmerge-qualification",)),
)


_HIGHER_ORDER = (
    (
        "race.cancel-removal-release-skip",
        "Cancelled waiter remains skipped across delayed removal and concurrent release",
        _parameters(cancellation="during-removal", removal="delayed", release="concurrent", waiter="cancelled"),
        "Pairwise cancellation/removal and removal/release checks cannot prove that one cancelled waiter is still skipped after both overlapping transitions.",
    ),
    (
        "race.cancel-terminal-reset-stale-revision",
        "Cancellation after terminal publication races reset under a stale revision",
        _parameters(cancellation="after-terminal", publication="terminal", revision="stale", session="reset-race"),
        "Pairwise checks can each be locally valid while the three-event sequence lets a stale terminal completion reclaim the reset session.",
    ),
    (
        "race.concurrent-resolution-reset-foreign-window",
        "Concurrent session resolution is reset while a foreign window awaits it",
        _parameters(authority="foreign-window", resolution="concurrent", session="reset-race"),
        "Pairwise checks cannot prove coalescing does not transfer a late session across a reset into a sibling window during the three-way race.",
    ),
    (
        "race.protocol-duplicate-reordered-post-terminal",
        "Duplicate reordered protocol event arrives after terminal publication",
        _parameters(correlation="exact", event="duplicate", ordering="reordered", publication="post-terminal"),
        "Pairwise event checks cannot prove the accumulator remains terminal when duplicate and ordering defects coincide after publication.",
    ),
    (
        "race.task10-old-scope-late-completion",
        "Old command scope completes into a replacement window with repeated generation and revision",
        _parameters(completion="late", generation="repeated", revision="repeated", scope="old", window="replacement"),
        "Pairwise checks cannot expose this ABA defect because scope, window replacement, repeated generation, and repeated revision must coincide.",
    ),
    (
        "race.resource-memory-processor-extreme-width",
        "Extreme host memory and processor count remain bounded together",
        _parameters(memory="extreme", policy="bounded", processor="extreme"),
        "Pairwise resource checks do not prove simultaneous extreme memory and processor inputs remain within the configured provider-width bound.",
    ),
    (
        "race.merge-tool-movement-stale-evidence",
        "Candidate movement and tool movement invalidate evidence across a prospective merge",
        _parameters(candidate="moved", evidence="old", merge="prospective", toolchain="moved"),
        "Pairwise checks cannot expose the stale-evidence failure because candidate, merge tree, and tool identity must all move relative to one earlier receipt.",
    ),
)


BASE_REQUIRED_SCENARIO_IDS = tuple(sorted((
    "durable.cancel-after-terminal-publication",
    "durable.cancel-before-terminal-publication",
    "durable.cancelled-waiter-skipped-delayed-removal",
    "durable.concurrent-session-resolution-coalesces",
    "durable.conversion-overflow",
    "durable.correct-job-bound-scheduling",
    "durable.foreign-job-authority-rejected",
    "durable.insufficient-memory",
    "durable.one-window-one-session",
    "durable.pause-resume-retire-lifecycle",
    "durable.provider-width-memory-extreme",
    "durable.provider-width-processor-extreme",
    "durable.session-reset-fences-late-resolution",
    "durable.waiter-cancel-after-enqueue",
    "durable.waiter-cancel-before-enqueue",
    "durable.waiter-cancel-during-release",
    "durable.waiter-cancel-during-removal",
    "installed.accessibility",
    "installed.launch-log",
    "installed.no-unauthorized-network-or-acquisition",
    "installed.source-binary-equality",
    "installed.task10.cancel",
    "installed.task10.create",
    "installed.task10.pause",
    "installed.task10.resume",
    "installed.task10.start",
    "merge.candidate-head-differs-from-receipt",
    "merge.governed-files-changed",
    "merge.prospective-tree-differs",
    "merge.workflow-success-wrong-sha",
    "native.asan",
    "native.golden",
    "native.governed-package-verification",
    "native.normal",
    "native.ubsan",
    "persistence.atomic-initial-transaction",
    "persistence.checkpoint-frontier-revision-fencing",
    "persistence.crash-recovery",
    "persistence.creation-ordinal",
    "persistence.duplicate-command-suppression",
    "persistence.legacy-schema-compatibility",
    "persistence.missing-model-pause-resume",
    "persistence.save-reopen-restore",
    "persistence.task-identity-verification",
    "persistence.task9-multi-round-regression",
    "persistence.terminal-cancel",
    "persistence.terminal-failure",
    "persistence.terminal-retire",
    "persistence.terminal-success",
    "postmerge.source-installed-binary-differs",
    "postmerge.stale-after-dependency-toolchain-movement",
    "release.build",
    "release.embedded-service-identities",
    "release.strict-signing",
    "signed-xpc.cancellation",
    "signed-xpc.complete",
    "signed-xpc.error",
    "signed-xpc.truncated",
    "task10.accessibility.catalog",
    "task10.accessibility.roles-labels-values-actions",
    "task10.creation.budget-min-max",
    "task10.creation.budget-out-of-range",
    "task10.creation.empty-objective",
    "task10.creation.empty-roots",
    "task10.creation.objective-byte-bound",
    "task10.creation.objective-normalization",
    "task10.creation.two-roots-canonical",
    "task10.creation.whitespace-objective",
    "task10.diagnostic.detail-bounds",
    "task10.diagnostic.reason-identity",
    "task10.multi-window-isolation",
    "task10.navigation.exact-source-coordinate",
    "task10.navigation.sibling-selection",
    "task10.navigation.stale-selection",
    "task10.provider.not-ready",
    "task10.provider.ready-busy",
    "task10.provider.ready-idle-valid-revision",
    "task10.provider.ready-invalid-revision",
    "task10.restore.activating",
    "task10.restore.failed-document-location",
    "task10.restore.failed-restoration",
    "task10.restore.failed-sidecar",
    "task10.restore.failed-stale-lifecycle",
    "task10.restore.inactive",
    "task10.restore.restoring",
    "task10.restore.runtime-unavailable",
    "task10.resume.exact-target",
    "task10.resume.missing-target",
    "task10.resume.stale-target",
    "task10.status.blocked",
    "task10.status.completed",
    "task10.status.failed",
    "task10.status.restored",
    "task10.status.stale",
    "task10.status.unavailable",
    "task8.cancel.after-terminal",
    "task8.cancel.before-dispatch",
    "task8.cancel.during-stream",
    "task8.event.completed",
    "task8.event.duplicate",
    "task8.event.final-candidate",
    "task8.event.malformed",
    "task8.event.post-terminal",
    "task8.event.reordered",
    "task8.event.round-candidate",
    "task8.event.stale",
    "task8.event.usage",
    "task8.legacy-assistant-compatibility",
    "task8.mismatch.correlation",
    "task8.mismatch.identity",
    "task8.mismatch.version",
    "task8.reply.accepted",
    "task8.reply.rejected",
    "task8.request.final-synthesis",
    "task8.request.round",
    "task8.signed-worker-parity",
)))
TASK10_STATE_COMMAND_SCENARIO_IDS = tuple(
    sorted(
        f"task10.command.{state}.{command}"
        for state in RECONSTRUCTION_JOB_STATES
        for command in TASK10_COMMANDS
    )
)
HIGHER_ORDER_SCENARIO_IDS = tuple(sorted(item[0] for item in _HIGHER_ORDER))
REQUIRED_SCENARIO_IDS = tuple(
    sorted(BASE_REQUIRED_SCENARIO_IDS + TASK10_STATE_COMMAND_SCENARIO_IDS + HIGHER_ORDER_SCENARIO_IDS)
)


def required_scenario_shape_drift(
    scenarios: Iterable[Scenario],
) -> tuple[str, ...]:
    """Return required IDs whose supplied shape differs from the frozen compiler."""

    expected = {
        item.scenario_id: item
        for item in commissioned_scenarios() + higher_order_scenarios()
    }
    observed = {item.scenario_id: item for item in scenarios}
    return tuple(
        sorted(
            scenario_id
            for scenario_id in set(expected) & set(observed)
            if observed[scenario_id] != expected[scenario_id]
        )
    )


def commissioned_scenarios() -> tuple[Scenario, ...]:
    scenarios: list[Scenario] = []
    layer_by_domain = {
        ScenarioDomain.DURABLE_AUTHORITY: _layers(EvidenceLayer.XCODE_FOCUSED),
        ScenarioDomain.PERSISTENCE: _layers(EvidenceLayer.XCODE_FOCUSED),
        ScenarioDomain.TASK8_PROTOCOL: _layers(EvidenceLayer.XCODE_FOCUSED),
        ScenarioDomain.TASK10_PRESENTATION: _layers(EvidenceLayer.XCODE_FOCUSED),
        ScenarioDomain.NATIVE_INSTALL: _layers(EvidenceLayer.NATIVE_NORMAL),
        ScenarioDomain.MERGE_POSTMERGE: _layers(EvidenceLayer.PROSPECTIVE_MERGE_TREE, EvidenceLayer.POST_MERGE),
    }
    group_layers = {
        "native-asan": _layers(EvidenceLayer.NATIVE_ASAN),
        "native-ubsan": _layers(EvidenceLayer.NATIVE_UBSAN),
        "native-golden": _layers(EvidenceLayer.NATIVE_NORMAL),
        "signed-xpc-supervision": _layers(EvidenceLayer.SIGNED_XPC),
        "signed-xpc-content": _layers(EvidenceLayer.SIGNED_XPC),
        "signed-xpc-error-cancellation": _layers(EvidenceLayer.SIGNED_XPC),
        "task8-signed-worker": _layers(EvidenceLayer.SIGNED_XPC),
        "release": _layers(EvidenceLayer.RELEASE_BUILD),
        "strict-signing": _layers(EvidenceLayer.STRICT_SIGNING),
        "installed-equality": _layers(EvidenceLayer.INSTALLED_SOURCE_EQUALITY),
        "installed-launch": _layers(EvidenceLayer.INSTALLED_LAUNCH_LOG),
        "installed-network-audit": _layers(EvidenceLayer.INSTALLED_WORKFLOW),
        "installed-task10": _layers(EvidenceLayer.INSTALLED_WORKFLOW),
        "installed-accessibility": _layers(EvidenceLayer.INSTALLED_ACCESSIBILITY),
        "merge-qualification": _layers(EvidenceLayer.PROSPECTIVE_MERGE_TREE),
        "postmerge-qualification": _layers(EvidenceLayer.POST_MERGE),
    }
    for scenario_id, domain, title, groups in _BASE_COMMISSIONED:
        layers = group_layers.get(groups[0], layer_by_domain[domain])
        effective_groups = groups
        if scenario_id in DURABLE_STRESS_PARAMETERS:
            effective_groups = groups + ("stress-recovery",)
            layers = _layers(*layers, EvidenceLayer.STRESS_RECOVERY)
        scenarios.append(
            _scenario(
                scenario_id,
                domain,
                title,
                groups=effective_groups,
                layers=layers,
                parameters=DURABLE_STRESS_PARAMETERS.get(scenario_id, ()),
            )
        )

    for state in RECONSTRUCTION_JOB_STATES:
        for command in TASK10_COMMANDS:
            active = state in {
                "created",
                "ingesting",
                "indexing",
                "retrieving",
                "awaiting-model",
                "executing-reads",
                "accepting-evidence",
                "checkpointing",
            }
            if command == "create":
                expected = "available"
            elif command == "start":
                expected = "available" if state == "created" else "unavailable-job-state"
            elif command == "pause":
                expected = "available" if active else "unavailable-job-state"
            elif command == "resume":
                expected = "available" if state == "paused" else "unavailable-job-state"
            else:
                expected = "available" if active else "unavailable-job-state"
            scenarios.append(
                _scenario(
                    f"task10.command.{state}.{command}",
                    ScenarioDomain.TASK10_PRESENTATION,
                    f"Task 10 {command} availability from durable {state}",
                    groups=("reconstruction-task10",),
                    layers=_layers(EvidenceLayer.XCODE_FOCUSED),
                    parameters=_parameters(
                        command=command,
                        durable_state=state,
                        expected_availability=expected,
                    ),
                )
            )
    return tuple(sorted(scenarios, key=lambda item: item.scenario_id))


def higher_order_scenarios() -> tuple[Scenario, ...]:
    return tuple(
        sorted(
            (
                _scenario(
                    scenario_id,
                    ScenarioDomain.AUTHORITY_RACE,
                    title,
                    groups=("reconstruction-concurrency", "stress-recovery"),
                    layers=_layers(EvidenceLayer.STRESS_RECOVERY, EvidenceLayer.XCODE_FOCUSED),
                    parameters=parameters,
                    origin=ScenarioOrigin.HIGHER_ORDER,
                    rationale=rationale,
                )
                for scenario_id, title, parameters, rationale in _HIGHER_ORDER
            ),
            key=lambda item: item.scenario_id,
        )
    )


def _normalized_factors(factors: Iterable[PairwiseFactor]) -> tuple[PairwiseFactor, ...]:
    normalized = tuple(
        sorted(
            (
                PairwiseFactor(item.factor_id, tuple(sorted(set(item.values))))
                for item in factors
            ),
            key=lambda item: item.factor_id,
        )
    )
    if len(normalized) < 2 or len({item.factor_id for item in normalized}) != len(normalized):
        raise ScenarioCompilationError("pairwise factors must contain at least two unique IDs")
    if any(not item.values for item in normalized):
        raise ScenarioCompilationError("pairwise factor values must not be empty")
    return normalized


def _row_pairs(
    factors: Sequence[PairwiseFactor],
    row: tuple[str, ...],
) -> frozenset[tuple[str, str, str, str]]:
    return frozenset(
        (
            factors[left_index].factor_id,
            row[left_index],
            factors[right_index].factor_id,
            row[right_index],
        )
        for left_index in range(len(factors))
        for right_index in range(left_index + 1, len(factors))
    )


def compile_pairwise_rows(
    factors: Iterable[PairwiseFactor] = PAIRWISE_FACTORS,
) -> tuple[tuple[PairwiseFactor, ...], tuple[tuple[str, ...], ...]]:
    """Return deterministic greedy pairwise closure over a closed factor set."""

    normalized = _normalized_factors(factors)
    return normalized, _solve_pairwise_rows(normalized)


@lru_cache(maxsize=8)
def _solve_pairwise_rows(
    normalized: tuple[PairwiseFactor, ...],
) -> tuple[tuple[str, ...], ...]:
    """Reuse only pure closure over validated immutable factors, never authority."""

    candidates = tuple(itertools.product(*(item.values for item in normalized)))
    pairs_by_row = {row: _row_pairs(normalized, row) for row in candidates}
    uncovered = set().union(*(pairs_by_row.values()))
    selected: list[tuple[str, ...]] = []
    remaining = set(candidates)
    while uncovered:
        row = min(
            remaining,
            key=lambda candidate: (-len(pairs_by_row[candidate] & uncovered), candidate),
        )
        selected.append(row)
        uncovered.difference_update(pairs_by_row[row])
        remaining.remove(row)
    return tuple(selected)


def _pairwise_scenario_id(
    factors: Sequence[PairwiseFactor],
    row: tuple[str, ...],
) -> str:
    if len(factors) != len(row):
        raise ScenarioCompilationError("pairwise scenario row does not match its factor arity")
    encoded = "|".join(
        f"{factor.factor_id}={value}" for factor, value in zip(factors, row)
    ).encode("utf-8")
    return "matrix.pairwise." + hashlib.sha256(encoded).hexdigest()[:16]


def pairwise_scenarios(
    factors: Iterable[PairwiseFactor] = PAIRWISE_FACTORS,
) -> tuple[tuple[PairwiseFactor, ...], tuple[Scenario, ...], tuple[PairwiseCoverage, ...]]:
    normalized, rows = compile_pairwise_rows(factors)
    scenarios: list[Scenario] = []
    pair_owner: dict[tuple[str, str, str, str], str] = {}
    for row in rows:
        if len(normalized) != len(row):
            raise ScenarioCompilationError("pairwise scenario row does not match its factor arity")
        scenario_id = _pairwise_scenario_id(normalized, row)
        scenarios.append(
            _scenario(
                scenario_id,
                ScenarioDomain.AUTHORITY_RACE,
                "Pairwise authority closure: "
                + ", ".join(
                    f"{factor.factor_id}={value}"
                    for factor, value in zip(normalized, row)
                ),
                groups=("reconstruction-concurrency", "stress-recovery"),
                layers=_layers(EvidenceLayer.STRESS_RECOVERY, EvidenceLayer.XCODE_FOCUSED),
                parameters=tuple(
                    sorted(
                        ScenarioParameter(factor.factor_id, value)
                        for factor, value in zip(normalized, row)
                    )
                ),
                origin=ScenarioOrigin.PAIRWISE,
            )
        )
        for pair in sorted(_row_pairs(normalized, row)):
            pair_owner.setdefault(pair, scenario_id)
    coverage = tuple(
        sorted(
            PairwiseCoverage(*pair, scenario_id)
            for pair, scenario_id in pair_owner.items()
        )
    )
    return normalized, tuple(sorted(scenarios, key=lambda item: item.scenario_id)), coverage


def compile_scenario_catalog(
    candidate: CandidateIdentity,
    *,
    factors: Iterable[PairwiseFactor] = PAIRWISE_FACTORS,
    commissioned: Iterable[Scenario] | None = None,
    higher_order: Iterable[Scenario] | None = None,
) -> ScenarioCatalog:
    candidate_issues = validate_candidate_identity(candidate_to_mapping(candidate))
    if candidate_issues:
        raise ScenarioCompilationError(
            "invalid candidate input: "
            + "; ".join(f"{item.code}: {item.message}" for item in candidate_issues)
        )
    normalized, matrix, coverage = pairwise_scenarios(factors)
    frozen_factors = _normalized_factors(PAIRWISE_FACTORS)
    if normalized != frozen_factors:
        raise ScenarioCompilationError(
            "pairwise-factor-catalog: factors differ from the commissioned closed model"
        )
    selected_commissioned = tuple(
        commissioned_scenarios() if commissioned is None else commissioned
    )
    selected_higher_order = tuple(
        higher_order_scenarios() if higher_order is None else higher_order
    )
    all_scenarios = tuple(
        sorted(
            selected_commissioned + selected_higher_order + matrix,
            key=lambda item: item.scenario_id,
        )
    )
    catalog = ScenarioCatalog(
        schema_version=SCENARIO_SCHEMA_VERSION,
        candidate_identity_sha256=candidate_identity_sha256(candidate),
        scenarios=all_scenarios,
        pairwise_factors=normalized,
        pairwise_coverage=coverage,
        required_scenario_ids=REQUIRED_SCENARIO_IDS,
    )
    issues = validate_scenario_catalog(catalog)
    shape_drift = required_scenario_shape_drift(
        selected_commissioned + selected_higher_order
    )
    messages = [f"{item.code}: {item.message}" for item in issues]
    messages.extend(
        f"required-scenario-shape: required scenario differs from its frozen shape: {scenario_id}"
        for scenario_id in shape_drift
    )
    if messages:
        raise ScenarioCompilationError("; ".join(messages))
    return catalog
