#!/usr/bin/env python3
"""Compile and execute the deterministic Reconstruction authority stress plan.

The Gate F scenario compiler is the sole authority for scenario IDs and
parameters.  This module deliberately does not maintain a second list of the
closed stress scenarios.  It can compile a dry-run manifest on any host and can
execute the host-independent identity-movement adapter.  Swift/XCTest work is
described as an environment plus selector so the integrator can serialize the
actual Xcode invocation with the other build and signing lanes.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import tempfile
from collections.abc import Mapping
from dataclasses import dataclass, replace
from enum import Enum
from pathlib import Path
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    canonical_bytes,
    canonical_sha256,
    load_canonical_json,
)
from Scripts.reconstruction_gate_f.receipt_schema import (  # noqa: E402
    COMMAND_PREREQUISITE_FIELDS,
    RECEIPT_SCHEMA_VERSION,
    seal_receipt,
)
from Scripts.reconstruction_gate_f.receipt_validator import (  # noqa: E402
    ArtifactExpectation,
    CommandAuthorityExpectation,
    ExecutionIntervalExpectation,
    QualificationRunAuthority,
    ReceiptValidationContext,
    qualification_run_mapping,
    validate_receipt,
)
from Scripts.reconstruction_gate_f.scenario_compiler import (  # noqa: E402
    PAIRWISE_FACTORS,
    compile_scenario_catalog,
)
from Scripts.reconstruction_gate_f.scenario_model import (  # noqa: E402
    Scenario,
    ScenarioCatalog,
    ScenarioOrigin,
    scenario_catalog_sha256,
    validate_scenario_catalog,
)
from Scripts.reconstruction_gate_f.schema import (  # noqa: E402
    ArtifactKind,
    CandidateIdentity,
    CandidateSubjectKind,
    EvidenceLayer,
    QualificationPhase,
    ReceiptType,
    STABLE_ID_RE,
    candidate_identity_sha256,
    candidate_to_mapping,
    is_sha256,
    parse_candidate_identity,
)


STRESS_PLAN_SCHEMA_VERSION = 1
STRESS_COMMAND_GROUP = "stress-recovery"
SWIFT_TEST_SELECTOR = (
    "CoreTests/ReconstructionAuthorityRaceStressTests/"
    "testCompiledAuthorityRaceScenario"
)
MAX_REPETITIONS = 10_000
MAX_SEED = (1 << 63) - 1
STRESS_PREDECESSOR_COMMAND_ID = "xcode.full-coretests"


class StressHarnessError(ValueError):
    """Raised when compiler output cannot produce a closed stress plan."""


class StressAdapter(str, Enum):
    SWIFT_PRODUCT_RACE = "swift-product-race"
    SWIFT_PAIRWISE_COMPOSITE = "swift-pairwise-composite"
    PYTHON_EVIDENCE_MOVEMENT = "python-evidence-movement"


SWIFT_EXECUTABLE_ADAPTERS = frozenset(
    {
        StressAdapter.SWIFT_PRODUCT_RACE,
        StressAdapter.SWIFT_PAIRWISE_COMPOSITE,
    }
)


# Duplicate execution identities are rejected unless the compiler has recorded
# why two commissioned scenario names intentionally share one exact adapter.
# This higher-order race is the explicit form of the durable delayed-removal
# scenario, so their identical adapter is intentional and reviewable.
EXPLICIT_STRESS_SCENARIO_ALIASES = {
    "race.cancel-removal-release-skip":
        "durable.cancelled-waiter-skipped-delayed-removal",
}


PAIRWISE_PARAMETER_VALUES = {
    factor.factor_id: frozenset(factor.values)
    for factor in PAIRWISE_FACTORS
}


@dataclass(frozen=True)
class StressInvocation:
    scenario_id: str
    iteration: int
    seed: int
    adapter: StressAdapter
    parameters: tuple[tuple[str, str], ...]
    semantic_axes: tuple[str, ...]
    semantic_gaps: tuple[str, ...]


@dataclass(frozen=True)
class AuthorityStressPlan:
    schema_version: int
    candidate_identity_sha256: str
    scenario_catalog_sha256: str
    repetitions: int
    adapters: tuple[str, ...]
    invocations: tuple[StressInvocation, ...]


def parse_qualification_run_authority(
    run_id: object,
    nonce: object,
) -> QualificationRunAuthority:
    """Parse authority supplied by the qualification coordinator.

    The stress executor never generates, defaults, or derives these values.
    """

    if not isinstance(run_id, str) or STABLE_ID_RE.fullmatch(run_id) is None:
        raise StressHarnessError(
            "qualification run ID must be a canonical lowercase stable ID"
        )
    if not is_sha256(nonce):
        raise StressHarnessError(
            "qualification run nonce must be a lowercase 64-hex SHA-256"
        )
    return QualificationRunAuthority(run_id=run_id, nonce=nonce)


def load_predecessor_observations(
    path: Path,
    *,
    qualification_run: QualificationRunAuthority,
) -> tuple[dict[str, str], ...]:
    """Load the coordinator's closed, same-run pre-launch observations."""

    value = load_canonical_json(path)
    if not isinstance(value, list):
        raise StressHarnessError("predecessor observations must be an array")
    observations: list[dict[str, str]] = []
    for index, item in enumerate(value):
        if not isinstance(item, dict) or set(item) != COMMAND_PREREQUISITE_FIELDS:
            raise StressHarnessError(
                f"predecessor observation {index} is not a closed reference"
            )
        if any(not isinstance(field, str) for field in item.values()):
            raise StressHarnessError(
                f"predecessor observation {index} contains a non-string field"
            )
        if (
            STABLE_ID_RE.fullmatch(item["command_id"]) is None
            or STABLE_ID_RE.fullmatch(item["receipt_id"]) is None
            or not is_sha256(item["canonical_sha256"])
            or STABLE_ID_RE.fullmatch(item["qualification_run_id"]) is None
            or not is_sha256(item["qualification_run_nonce"])
        ):
            raise StressHarnessError(
                f"predecessor observation {index} has malformed authority"
            )
        if (
            item["qualification_run_id"] != qualification_run.run_id
            or item["qualification_run_nonce"] != qualification_run.nonce
        ):
            raise StressHarnessError(
                f"predecessor observation {index} belongs to another qualification run"
            )
        observations.append(dict(item))

    if [item["command_id"] for item in observations] != [
        STRESS_PREDECESSOR_COMMAND_ID
    ]:
        raise StressHarnessError(
            "authority stress requires exactly the same-run xcode.full-coretests predecessor"
        )
    if observations != sorted(
        observations,
        key=lambda item: (
            item["command_id"],
            item["receipt_id"],
            item["canonical_sha256"],
            item["qualification_run_id"],
            item["qualification_run_nonce"],
        ),
    ):
        raise StressHarnessError("predecessor observations are not stable-ID sorted")
    return tuple(observations)


SWIFT_PARAMETER_VALUE_SEAMS = {
    **{
        ("authority", value): "destination-session-authority"
        for value in ("exact-job", "foreign-job", "foreign-window", "stale-revision")
    },
    **{
        ("cancellation", value): "provider-pool-cancellation"
        for value in (
            "after-enqueue", "before-enqueue", "during-release", "during-removal", "none"
        )
    },
    ("cancellation", "after-terminal"): "xpc-event-sequencing",
    ("cancellation", "before-terminal"): "xpc-event-sequencing",
    ("completion", "late"): "presentation-command-aba",
    ("correlation", "exact"): "xpc-event-sequencing",
    ("event", "duplicate"): "xpc-event-sequencing",
    ("generation", "repeated"): "presentation-command-aba",
    ("lifecycle", "pause-resume-retire"): "provider-pool-lifecycle",
    ("memory", "extreme"): "provider-budget",
    ("ordering", "reordered"): "xpc-event-sequencing",
    ("policy", "bounded"): "provider-budget",
    ("processor", "extreme"): "provider-budget",
    **{
        ("publication", value): "xpc-event-sequencing"
        for value in ("after-terminal", "before-terminal", "none", "post-terminal", "terminal")
    },
    ("release", "concurrent"): "provider-pool-cancellation",
    ("removal", "delayed"): "provider-pool-cancellation",
    ("resolution", "concurrent"): "destination-session-authority",
    **{
        ("resource", value): "provider-budget"
        for value in (
            "combined-extremes", "insufficient-memory", "memory-extreme", "nominal", "processor-extreme"
        )
    },
    ("revision", "repeated"): "presentation-command-aba",
    ("revision", "stale"): "destination-session-authority",
    ("scope", "old"): "presentation-command-aba",
    **{
        ("session", value): "destination-session-authority"
        for value in ("concurrent-resolution", "existing", "reset-race")
    },
    ("waiter", "cancelled"): "provider-pool-cancellation",
    ("window", "replacement"): "presentation-command-aba",
    ("window", "session-owner"): "destination-session-authority",
}


def _semantic_contract(
    scenario: Scenario,
    adapter: StressAdapter,
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    if adapter is StressAdapter.PYTHON_EVIDENCE_MOVEMENT:
        return ("merge-evidence-identity",), ()

    if adapter is StressAdapter.SWIFT_PAIRWISE_COMPOSITE:
        parameters = {item.name: item.value for item in scenario.parameters}
        if set(parameters) != set(PAIRWISE_PARAMETER_VALUES):
            raise StressHarnessError(
                "pairwise composite adapter has an uncovered parameter shape: "
                f"{scenario.scenario_id}"
            )
        uncovered = tuple(
            sorted(
                f"{name}={value}"
                for name, value in parameters.items()
                if value not in PAIRWISE_PARAMETER_VALUES[name]
            )
        )
        if uncovered:
            raise StressHarnessError(
                "pairwise composite adapter has an uncovered combination: "
                f"{scenario.scenario_id}: {', '.join(uncovered)}"
            )
        return ("batch-scheduler-provider-pairwise-composite",), ()

    parameter_values = {
        item.name: item.value for item in scenario.parameters
    }
    if parameter_values.get("scheduler") == "batch":
        if set(parameter_values) != {"authority", "scheduler"} or (
            parameter_values["authority"] not in {"exact-job", "foreign-job"}
        ):
            raise StressHarnessError(
                "batch scheduler adapter has an uncovered job-authority shape: "
                f"{scenario.scenario_id}"
            )
        return ("batch-scheduler-job-authority",), ()

    if scenario.scenario_id == "race.cancel-terminal-reset-stale-revision":
        return ("terminal-reset-stale-resolution-composite",), ()

    if not scenario.parameters:
        raise StressHarnessError(
            f"compiled Swift stress scenario has no executable parameters: {scenario.scenario_id}"
        )

    axes: set[str] = set()
    gaps: set[str] = set()
    for parameter in scenario.parameters:
        seam = SWIFT_PARAMETER_VALUE_SEAMS.get((parameter.name, parameter.value))
        if seam is None:
            raise StressHarnessError(
                "compiled stress parameter has no closed Swift production seam: "
                f"{scenario.scenario_id}.{parameter.name}={parameter.value}"
            )
        axes.add(seam)
    return tuple(sorted(axes)), tuple(sorted(gaps))


def _stress_scenarios(catalog: ScenarioCatalog) -> tuple[Scenario, ...]:
    """Return the compiler-owned stress slice after validating its closure."""

    issues = validate_scenario_catalog(catalog)
    if issues:
        rendered = "; ".join(
            f"{item.code} at {item.path}: {item.message}" for item in issues
        )
        raise StressHarnessError(f"invalid compiled scenario catalog: {rendered}")

    scenarios = tuple(
        scenario
        for scenario in catalog.scenarios
        if STRESS_COMMAND_GROUP in scenario.command_groups
        or EvidenceLayer.STRESS_RECOVERY in scenario.evidence_layers
    )
    ids = tuple(item.scenario_id for item in scenarios)
    if not scenarios:
        raise StressHarnessError("compiled scenario catalog has no stress scenarios")
    if len(ids) != len(set(ids)):
        raise StressHarnessError("compiled stress scenario IDs are not unique")
    if ids != tuple(sorted(ids)):
        raise StressHarnessError("compiled stress scenarios are not stable-ID sorted")
    for scenario in scenarios:
        if STRESS_COMMAND_GROUP not in scenario.command_groups:
            raise StressHarnessError(
                f"stress evidence scenario lacks {STRESS_COMMAND_GROUP!r} command group: "
                f"{scenario.scenario_id}"
            )
        if EvidenceLayer.STRESS_RECOVERY not in scenario.evidence_layers:
            raise StressHarnessError(
                "stress command scenario lacks stress-recovery evidence layer: "
                f"{scenario.scenario_id}"
            )
    return scenarios


def _adapter_for(scenario: Scenario) -> StressAdapter:
    """Dispatch using a closed vocabulary and compiler-owned parameter shape."""

    parameter_names = frozenset(item.name for item in scenario.parameters)
    evidence_movement_shape = frozenset(
        {"candidate", "evidence", "merge", "toolchain"}
    )
    if parameter_names == evidence_movement_shape:
        return StressAdapter.PYTHON_EVIDENCE_MOVEMENT
    if scenario.origin is ScenarioOrigin.PAIRWISE:
        return StressAdapter.SWIFT_PAIRWISE_COMPOSITE
    return StressAdapter.SWIFT_PRODUCT_RACE


def _execution_adapter_identity(
    scenario: Scenario,
) -> tuple[str, tuple[tuple[str, str], ...], tuple[str, ...], tuple[str, ...]]:
    adapter = _adapter_for(scenario)
    axes, gaps = _semantic_contract(scenario, adapter)
    return (
        adapter.value,
        tuple((item.name, item.value) for item in scenario.parameters),
        axes,
        gaps,
    )


def _validate_duplicate_execution_adapters(
    scenarios: tuple[Scenario, ...],
) -> None:
    identities: dict[
        tuple[str, tuple[tuple[str, str], ...], tuple[str, ...], tuple[str, ...]],
        list[str],
    ] = {}
    for scenario in scenarios:
        identities.setdefault(_execution_adapter_identity(scenario), []).append(
            scenario.scenario_id
        )

    for scenario_ids in identities.values():
        if len(scenario_ids) < 2:
            continue
        observed = set(scenario_ids)
        canonical_ids = observed - set(EXPLICIT_STRESS_SCENARIO_ALIASES)
        if len(canonical_ids) == 1:
            canonical = next(iter(canonical_ids))
            if all(
                scenario_id == canonical
                or EXPLICIT_STRESS_SCENARIO_ALIASES.get(scenario_id) == canonical
                for scenario_id in observed
            ):
                continue
        raise StressHarnessError(
            "duplicate stress execution adapter without explicit alias: "
            + ", ".join(sorted(observed))
        )


def _seed_for(
    candidate_digest: str,
    catalog_digest: str,
    scenario_id: str,
    iteration: int,
) -> int:
    payload = b"\0".join(
        (
            b"macscope-reconstruction-authority-stress-v1",
            candidate_digest.encode("ascii"),
            catalog_digest.encode("ascii"),
            scenario_id.encode("utf-8"),
            str(iteration).encode("ascii"),
        )
    )
    return int.from_bytes(hashlib.sha256(payload).digest()[:8], "big") & MAX_SEED


def compile_authority_stress_plan(
    candidate: CandidateIdentity,
    *,
    repetitions: int = 1,
) -> AuthorityStressPlan:
    if isinstance(repetitions, bool) or not isinstance(repetitions, int):
        raise StressHarnessError("repetitions must be an integer")
    if not 1 <= repetitions <= MAX_REPETITIONS:
        raise StressHarnessError(
            f"repetitions must be in the closed range 1...{MAX_REPETITIONS}"
        )

    catalog = compile_scenario_catalog(candidate)
    scenarios = _stress_scenarios(catalog)
    _validate_duplicate_execution_adapters(scenarios)
    candidate_digest = candidate_identity_sha256(candidate)
    catalog_digest = scenario_catalog_sha256(catalog)
    invocations: list[StressInvocation] = []
    observed_seeds: dict[int, tuple[str, int]] = {}
    for iteration in range(repetitions):
        for scenario in scenarios:
            seed = _seed_for(
                candidate_digest,
                catalog_digest,
                scenario.scenario_id,
                iteration,
            )
            prior = observed_seeds.get(seed)
            if prior is not None:
                raise StressHarnessError(
                    "derived seed collision: "
                    f"{prior[0]} iteration {prior[1]} and "
                    f"{scenario.scenario_id} iteration {iteration} both use {seed}"
                )
            observed_seeds[seed] = (scenario.scenario_id, iteration)
            adapter = _adapter_for(scenario)
            semantic_axes, semantic_gaps = _semantic_contract(scenario, adapter)
            invocations.append(
                StressInvocation(
                    scenario_id=scenario.scenario_id,
                    iteration=iteration,
                    seed=seed,
                    adapter=adapter,
                    parameters=tuple(
                        (parameter.name, parameter.value)
                        for parameter in scenario.parameters
                    ),
                    semantic_axes=semantic_axes,
                    semantic_gaps=semantic_gaps,
                )
            )

    plan = AuthorityStressPlan(
        schema_version=STRESS_PLAN_SCHEMA_VERSION,
        candidate_identity_sha256=candidate_digest,
        scenario_catalog_sha256=catalog_digest,
        repetitions=repetitions,
        adapters=tuple(sorted(item.value for item in StressAdapter)),
        invocations=tuple(invocations),
    )
    validate_authority_stress_plan(plan, scenarios=scenarios)
    return plan


def validate_authority_stress_plan(
    plan: AuthorityStressPlan,
    *,
    scenarios: tuple[Scenario, ...],
) -> None:
    if plan.schema_version != STRESS_PLAN_SCHEMA_VERSION:
        raise StressHarnessError("unsupported authority stress plan schema")
    if plan.adapters != tuple(sorted(item.value for item in StressAdapter)):
        raise StressHarnessError("stress plan adapter vocabulary is not closed")

    _validate_duplicate_execution_adapters(scenarios)

    expected_ids = tuple(item.scenario_id for item in scenarios)
    scenarios_by_id = {item.scenario_id: item for item in scenarios}
    observed_by_iteration: dict[int, list[str]] = {}
    seen_pairs: set[tuple[str, int]] = set()
    seen_seeds: set[int] = set()
    for invocation in plan.invocations:
        if not isinstance(invocation.adapter, StressAdapter):
            raise StressHarnessError(
                f"unknown stress adapter for {invocation.scenario_id}: "
                f"{invocation.adapter!r}"
            )
        if not invocation.semantic_axes:
            raise StressHarnessError(
                f"stress invocation has no semantic production seam: {invocation.scenario_id}"
            )
        if invocation.semantic_gaps:
            raise StressHarnessError(
                f"stress invocation retains an unexecuted semantic gap: {invocation.scenario_id}"
            )
        scenario = scenarios_by_id.get(invocation.scenario_id)
        if scenario is None:
            raise StressHarnessError(
                f"stress invocation is absent from the compiled catalog: {invocation.scenario_id}"
            )
        expected_adapter = _adapter_for(scenario)
        expected_axes, expected_gaps = _semantic_contract(scenario, expected_adapter)
        expected_parameters = tuple(
            (parameter.name, parameter.value) for parameter in scenario.parameters
        )
        if (
            invocation.adapter is not expected_adapter
            or invocation.parameters != expected_parameters
            or invocation.semantic_axes != expected_axes
            or invocation.semantic_gaps != expected_gaps
        ):
            raise StressHarnessError(
                f"stress invocation differs from compiler-owned semantics: {invocation.scenario_id}"
            )
        pair = (invocation.scenario_id, invocation.iteration)
        if pair in seen_pairs:
            raise StressHarnessError(
                "duplicate stress invocation: "
                f"{invocation.scenario_id} iteration {invocation.iteration}"
            )
        seen_pairs.add(pair)
        if not 0 <= invocation.seed <= MAX_SEED:
            raise StressHarnessError(
                f"stress seed is outside the nonnegative signed range: {invocation.seed}"
            )
        if invocation.seed in seen_seeds:
            raise StressHarnessError(f"duplicate stress seed: {invocation.seed}")
        seen_seeds.add(invocation.seed)
        observed_by_iteration.setdefault(invocation.iteration, []).append(
            invocation.scenario_id
        )

    expected_iterations = set(range(plan.repetitions))
    if set(observed_by_iteration) != expected_iterations:
        raise StressHarnessError("stress plan is missing or adds an iteration")
    for iteration in range(plan.repetitions):
        if tuple(observed_by_iteration[iteration]) != expected_ids:
            raise StressHarnessError(
                f"stress plan iteration {iteration} does not exactly cover the compiled catalog"
            )


def _invocation_mapping(invocation: StressInvocation) -> dict[str, Any]:
    parameters = dict(invocation.parameters)
    base = {
        "adapter": invocation.adapter.value,
        "iteration": invocation.iteration,
        "parameters": parameters,
        "scenario_id": invocation.scenario_id,
        "seed": invocation.seed,
        "semantic_axes": list(invocation.semantic_axes),
        "semantic_gaps": list(invocation.semantic_gaps),
        "semantic_status": "fully-executable",
    }
    if invocation.adapter in SWIFT_EXECUTABLE_ADAPTERS:
        base["swift"] = {
            "environment": {
                "MACSCOPE_RECONSTRUCTION_STRESS_ADAPTER": invocation.adapter.value,
                "MACSCOPE_RECONSTRUCTION_STRESS_PARAMETERS_JSON": canonical_bytes(
                    parameters
                ).decode("utf-8"),
                "MACSCOPE_RECONSTRUCTION_STRESS_SEMANTIC_AXES_JSON": canonical_bytes(
                    list(invocation.semantic_axes)
                ).decode("utf-8"),
                "MACSCOPE_RECONSTRUCTION_STRESS_SCENARIO_ID": invocation.scenario_id,
                "MACSCOPE_RECONSTRUCTION_STRESS_SEED": str(invocation.seed),
            },
            "selector": SWIFT_TEST_SELECTOR,
        }
    return base


def plan_mapping(plan: AuthorityStressPlan) -> dict[str, Any]:
    return {
        "adapters": list(plan.adapters),
        "candidate_identity_sha256": plan.candidate_identity_sha256,
        "invocations": [
            _invocation_mapping(invocation) for invocation in plan.invocations
        ],
        "repetitions": plan.repetitions,
        "scenario_catalog_sha256": plan.scenario_catalog_sha256,
        "schema_version": plan.schema_version,
    }


def validate_swift_attempt_ledger(
    plan: Mapping[str, Any],
    ledger: Mapping[str, Any],
) -> tuple[dict[str, Any], ...]:
    """Return the exact passed Swift attempts or fail closed on any omission."""

    if set(ledger) != {"attempts", "schema_version"} or ledger.get("schema_version") != 1:
        raise StressHarnessError("unsupported or open authority stress attempt ledger")
    invocations = plan.get("invocations")
    attempts = ledger.get("attempts")
    if not isinstance(invocations, list) or not isinstance(attempts, list):
        raise StressHarnessError("authority stress plan and ledger require attempt arrays")

    expected: dict[tuple[str, int, int], tuple[str, ...]] = {}
    for invocation in invocations:
        if not isinstance(invocation, Mapping):
            raise StressHarnessError("malformed authority stress invocation")
        if invocation.get("adapter") not in {
            item.value for item in SWIFT_EXECUTABLE_ADAPTERS
        }:
            continue
        scenario_id = invocation.get("scenario_id")
        iteration = invocation.get("iteration")
        seed = invocation.get("seed")
        axes = invocation.get("semantic_axes")
        if (
            not isinstance(scenario_id, str)
            or isinstance(iteration, bool)
            or not isinstance(iteration, int)
            or isinstance(seed, bool)
            or not isinstance(seed, int)
            or not isinstance(axes, list)
            or not axes
            or not all(isinstance(axis, str) for axis in axes)
            or axes != sorted(set(axes))
            or invocation.get("semantic_gaps") != []
            or invocation.get("semantic_status") != "fully-executable"
        ):
            raise StressHarnessError("Swift stress invocation is not fully executable")
        key = (scenario_id, iteration, seed)
        if key in expected:
            raise StressHarnessError("duplicate Swift stress invocation identity")
        expected[key] = tuple(axes)

    observed: dict[tuple[str, int, int], dict[str, Any]] = {}
    attempt_fields = {
        "iteration", "observed_semantic_axes", "scenario_id", "seed", "status"
    }
    for attempt in attempts:
        if not isinstance(attempt, dict) or set(attempt) != attempt_fields:
            raise StressHarnessError("malformed or open Swift stress attempt")
        scenario_id = attempt.get("scenario_id")
        iteration = attempt.get("iteration")
        seed = attempt.get("seed")
        axes = attempt.get("observed_semantic_axes")
        if (
            not isinstance(scenario_id, str)
            or isinstance(iteration, bool)
            or not isinstance(iteration, int)
            or isinstance(seed, bool)
            or not isinstance(seed, int)
            or not isinstance(axes, list)
            or not all(isinstance(axis, str) for axis in axes)
            or axes != sorted(set(axes))
            or attempt.get("status") != "passed"
        ):
            raise StressHarnessError("Swift stress attempt did not pass exactly")
        key = (scenario_id, iteration, seed)
        if key in observed:
            raise StressHarnessError("duplicate Swift stress ledger identity")
        observed[key] = attempt

    if set(observed) != set(expected):
        missing = sorted(set(expected) - set(observed))
        added = sorted(set(observed) - set(expected))
        raise StressHarnessError(
            f"Swift stress ledger differs from compiled attempts; missing={missing!r}; added={added!r}"
        )
    for key, expected_axes in expected.items():
        if tuple(observed[key]["observed_semantic_axes"]) != expected_axes:
            raise StressHarnessError(
                f"Swift stress ledger reports the wrong production seams for {key!r}"
            )
    return tuple(observed[key] for key in sorted(observed))


@dataclass(frozen=True)
class _MovementReceiptFixture:
    receipt: dict[str, Any]
    context: ReceiptValidationContext
    temporary_root: tempfile.TemporaryDirectory


def _movement_digest(label: str, seed: int) -> str:
    return hashlib.sha256(
        b"\0".join(
            (
                b"macscope-authority-stress-movement-v1",
                label.encode("utf-8"),
                str(seed).encode("ascii"),
            )
        )
    ).hexdigest()


def _movement_git_object(label: str, seed: int) -> str:
    return hashlib.sha1(
        b"\0".join(
            (
                b"macscope-authority-stress-movement-v1",
                label.encode("utf-8"),
                str(seed).encode("ascii"),
            )
        )
    ).hexdigest()


def _prospective_moved_candidate(
    candidate: CandidateIdentity,
    *,
    seed: int,
) -> CandidateIdentity:
    if not candidate.tools:
        raise StressHarnessError("candidate has no tool identity to move")
    moved_tools = list(candidate.tools)
    moved_tools[0] = replace(
        moved_tools[0],
        identity_sha256=_movement_digest("toolchain", seed),
    )
    moved = replace(
        candidate,
        subject_kind=CandidateSubjectKind.PROSPECTIVE_MERGE,
        source=replace(
            candidate.source,
            commit=_movement_git_object("candidate-commit", seed),
            tree=_movement_git_object("candidate-tree", seed),
        ),
        tools=tuple(moved_tools),
        prospective_merge_commit=_movement_git_object("prospective-commit", seed),
        prospective_merge_tree=_movement_git_object("prospective-tree", seed),
        accepted_postmerge_commit=None,
        accepted_postmerge_tree=None,
    )
    reparsed, issues = parse_candidate_identity(candidate_to_mapping(moved))
    if reparsed is None or issues:
        rendered = "; ".join(
            f"{item.code} at {item.path}: {item.message}" for item in issues
        )
        raise StressHarnessError(
            f"movement fixture did not construct a valid prospective candidate: {rendered}"
        )
    return reparsed


def _movement_receipt_fixture(
    candidate: CandidateIdentity,
    *,
    seed: int,
    qualification_run: QualificationRunAuthority,
) -> _MovementReceiptFixture:
    candidate_digest = candidate_identity_sha256(candidate)
    receipt_id = "authority-stress-old-evidence"
    artifact_id = "authority-stress-old-results"
    relative_path = "artifacts/authority-stress-old-results.json"
    payload = canonical_bytes(
        {
            "candidate_identity_sha256": candidate_digest,
            "result": "passed",
            "seed": seed,
        }
    )
    temporary_root = tempfile.TemporaryDirectory(
        prefix="macscope-authority-stress-receipt."
    )
    artifact_root = Path(temporary_root.name).resolve()
    artifact_path = artifact_root / relative_path
    artifact_path.parent.mkdir(parents=True, exist_ok=True)
    artifact_path.write_bytes(payload)
    authority = CommandAuthorityExpectation(
        host="host-independent",
        execution_mode="runnable",
        argv_sha256=_movement_digest("argv", seed),
        working_directory_sha256=_movement_digest("working-directory", seed),
        environment_sha256=_movement_digest("environment", seed),
        generated_artifacts=(),
        generated_logs=(),
        prerequisite_receipts=(),
    )
    execution_interval = ExecutionIntervalExpectation(
        started_at_unix_ms=seed,
        ended_at_unix_ms=seed,
    )
    receipt = seal_receipt(
        {
            "schema_version": RECEIPT_SCHEMA_VERSION,
            "receipt_id": receipt_id,
            "receipt_type": ReceiptType.TEST_RESULT.value,
            "evidence_layer": EvidenceLayer.HOSTED_PURE.value,
            "evidence_status": "passed",
            "qualification_phase": QualificationPhase.PREMERGE.value,
            "qualification_run": qualification_run_mapping(qualification_run),
            "candidate_identity": candidate_to_mapping(candidate),
            "candidate_identity_sha256": candidate_digest,
            "requirement_id": "gate-f-authority-stress",
            "command_id": "authority-stress-hosted-fixture",
            "scenario_id": "race.merge-tool-movement-stale-evidence",
            "command_plan_sha256": _movement_digest("command-plan", seed),
            "command_record_sha256": _movement_digest("command-record", seed),
            "runtime_resolution": None,
            "qualified_premerge_authority_sha256": None,
            "attempt": 1,
            "execution_interval": {
                "started_at_unix_ms": execution_interval.started_at_unix_ms,
                "ended_at_unix_ms": execution_interval.ended_at_unix_ms,
            },
            "executor": {
                "executor_id": "hosted-runner",
                "host": authority.host,
                "platform": "linux",
                "architecture": "x86_64",
                "os_version": "host-independent-fixture-v1",
            },
            "command_authority": {
                "host": authority.host,
                "execution_mode": authority.execution_mode,
                "argv_sha256": authority.argv_sha256,
                "working_directory_sha256": authority.working_directory_sha256,
                "environment_sha256": authority.environment_sha256,
                "generated_artifacts": [],
                "generated_logs": [],
                "prerequisite_receipts": [],
            },
            "artifacts": [
                {
                    "schema_version": 1,
                    "artifact_id": artifact_id,
                    "candidate_identity_sha256": candidate_digest,
                    "evidence_layer": EvidenceLayer.HOSTED_PURE.value,
                    "root_id": "authority-stress-fixture",
                    "relative_path": relative_path,
                    "kind": ArtifactKind.TEST_RESULTS.value,
                    "media_type": "application/json",
                    "byte_count": len(payload),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "producer_receipt_id": receipt_id,
                    "command_id": "authority-stress-hosted-fixture",
                    "command_output": "semantic:test-results",
                }
            ],
            "constituents": [
                {
                    "selector_id": "authority-stress-fixture-selector",
                    "status": "passed",
                    "evidence_layer": EvidenceLayer.HOSTED_PURE.value,
                    "candidate_identity_sha256": candidate_digest,
                    "artifact_ids": [artifact_id],
                }
            ],
            "skips": [],
            "diagnostic": None,
            "authority": {
                "selector_catalog_sha256": candidate.selector_catalog_sha256,
                "expected_selector_count": 1,
                "executed_selector_count": 1,
                "passed_selector_count": 1,
                "failed_selector_count": 0,
                "skipped_selector_count": 0,
            },
        }
    )
    context = ReceiptValidationContext(
        expected_candidate=candidate,
        expected_qualification_run=qualification_run,
        qualification_phase=QualificationPhase.PREMERGE,
        expected_layer=EvidenceLayer.HOSTED_PURE,
        expected_receipt_type=ReceiptType.TEST_RESULT,
        expected_receipt_id=receipt_id,
        expected_requirement_id="gate-f-authority-stress",
        expected_command_id="authority-stress-hosted-fixture",
        expected_scenario_id="race.merge-tool-movement-stale-evidence",
        expected_command_plan_sha256=_movement_digest("command-plan", seed),
        expected_command_record_sha256=_movement_digest("command-record", seed),
        expected_command_authority=authority,
        expected_qualified_premerge_authority_sha256=None,
        expected_attempt=1,
        expected_execution_interval=execution_interval,
        expected_artifact_root_id="authority-stress-fixture",
        expected_artifacts=(
            ArtifactExpectation(
                artifact_id=artifact_id,
                relative_path=relative_path,
                kind=ArtifactKind.TEST_RESULTS,
                media_type="application/json",
                command_output="semantic:test-results",
            ),
        ),
        artifact_root=artifact_root,
        expected_executor_id="hosted-runner",
    )
    return _MovementReceiptFixture(
        receipt=receipt,
        context=context,
        temporary_root=temporary_root,
    )


def execute_python_evidence_movement(
    invocation: StressInvocation,
    *,
    candidate: CandidateIdentity,
    qualification_run: QualificationRunAuthority,
) -> dict[str, Any]:
    if invocation.adapter is not StressAdapter.PYTHON_EVIDENCE_MOVEMENT:
        raise StressHarnessError("Python executor received a non-Python stress adapter")
    parameters = dict(invocation.parameters)
    expected = {
        "candidate": "moved",
        "evidence": "old",
        "merge": "prospective",
        "toolchain": "moved",
    }
    if parameters != expected:
        raise StressHarnessError(
            "Python evidence-movement scenario differs from compiler-owned closed shape"
        )

    fixture = _movement_receipt_fixture(
        candidate,
        seed=invocation.seed,
        qualification_run=qualification_run,
    )
    try:
        original_issues = validate_receipt(fixture.receipt, context=fixture.context)
        if original_issues:
            rendered = "; ".join(
                f"{item.code} at {item.path}: {item.message}"
                for item in original_issues
            )
            raise StressHarnessError(
                f"old evidence fixture is not valid for its exact candidate: {rendered}"
            )

        moved_candidate = _prospective_moved_candidate(
            candidate,
            seed=invocation.seed,
        )
        movement_issues = validate_receipt(
            fixture.receipt,
            context=replace(fixture.context, expected_candidate=moved_candidate),
        )
        movement_issue_codes = tuple(sorted({item.code for item in movement_issues}))
        if "receipt-candidate-mismatch" not in movement_issue_codes:
            raise StressHarnessError(
                "Gate F receipt validator accepted old evidence after candidate, "
                "prospective-merge, and toolchain movement"
            )
        old_receipt_sha256 = fixture.receipt["canonical_sha256"]
    finally:
        fixture.temporary_root.cleanup()
    return {
        "adapter": invocation.adapter.value,
        "iteration": invocation.iteration,
        "moved_candidate_identity_sha256": candidate_identity_sha256(
            moved_candidate
        ),
        "old_receipt_canonical_sha256": old_receipt_sha256,
        "scenario_id": invocation.scenario_id,
        "seed": invocation.seed,
        "status": "passed",
        "observed_semantic_axes": list(invocation.semantic_axes),
        "validator_issue_codes": list(movement_issue_codes),
    }


def execute_python_adapters(
    plan: AuthorityStressPlan,
    *,
    candidate: CandidateIdentity,
    qualification_run: QualificationRunAuthority,
) -> tuple[dict[str, Any], ...]:
    if not isinstance(qualification_run, QualificationRunAuthority):
        raise StressHarnessError(
            "qualification run authority must be supplied by the coordinator"
        )
    if candidate_identity_sha256(candidate) != plan.candidate_identity_sha256:
        raise StressHarnessError(
            "Python stress executor candidate differs from the compiled plan"
        )
    return tuple(
        execute_python_evidence_movement(
            invocation,
            candidate=candidate,
            qualification_run=qualification_run,
        )
        for invocation in plan.invocations
        if invocation.adapter is StressAdapter.PYTHON_EVIDENCE_MOVEMENT
    )


def validate_python_results(
    plan: Mapping[str, Any],
    results: object,
) -> tuple[dict[str, Any], ...]:
    """Bind Python adapter results to every exact compiler-owned invocation."""

    invocations = plan.get("invocations")
    if not isinstance(invocations, list) or not isinstance(results, list):
        raise StressHarnessError(
            "authority stress plan and Python results require arrays"
        )
    expected: dict[tuple[str, int, int], tuple[str, ...]] = {}
    for invocation in invocations:
        if not isinstance(invocation, Mapping):
            raise StressHarnessError("malformed authority stress invocation")
        if invocation.get("adapter") != StressAdapter.PYTHON_EVIDENCE_MOVEMENT.value:
            continue
        scenario_id = invocation.get("scenario_id")
        iteration = invocation.get("iteration")
        seed = invocation.get("seed")
        axes = invocation.get("semantic_axes")
        if (
            not isinstance(scenario_id, str)
            or isinstance(iteration, bool)
            or not isinstance(iteration, int)
            or isinstance(seed, bool)
            or not isinstance(seed, int)
            or not isinstance(axes, list)
            or axes != ["merge-evidence-identity"]
            or invocation.get("semantic_gaps") != []
            or invocation.get("semantic_status") != "fully-executable"
        ):
            raise StressHarnessError(
                "Python movement invocation is not fully executable"
            )
        key = (scenario_id, iteration, seed)
        if key in expected:
            raise StressHarnessError("duplicate Python stress invocation identity")
        expected[key] = tuple(axes)

    observed: dict[tuple[str, int, int], dict[str, Any]] = {}
    result_fields = {
        "adapter",
        "iteration",
        "moved_candidate_identity_sha256",
        "observed_semantic_axes",
        "old_receipt_canonical_sha256",
        "scenario_id",
        "seed",
        "status",
        "validator_issue_codes",
    }
    for result in results:
        if not isinstance(result, dict) or set(result) != result_fields:
            raise StressHarnessError("malformed or open Python stress result")
        scenario_id = result.get("scenario_id")
        iteration = result.get("iteration")
        seed = result.get("seed")
        axes = result.get("observed_semantic_axes")
        issue_codes = result.get("validator_issue_codes")
        if (
            result.get("adapter")
            != StressAdapter.PYTHON_EVIDENCE_MOVEMENT.value
            or not isinstance(scenario_id, str)
            or isinstance(iteration, bool)
            or not isinstance(iteration, int)
            or isinstance(seed, bool)
            or not isinstance(seed, int)
            or not isinstance(axes, list)
            or axes != sorted(set(axes))
            or not isinstance(issue_codes, list)
            or issue_codes != sorted(set(issue_codes))
            or "receipt-candidate-mismatch" not in issue_codes
            or not is_sha256(result.get("old_receipt_canonical_sha256"))
            or not is_sha256(result.get("moved_candidate_identity_sha256"))
            or result.get("status") != "passed"
        ):
            raise StressHarnessError(
                "Python movement result did not prove exact Gate F rejection"
            )
        key = (scenario_id, iteration, seed)
        if key in observed:
            raise StressHarnessError("duplicate Python stress result identity")
        observed[key] = result

    if set(observed) != set(expected):
        missing = sorted(set(expected) - set(observed))
        added = sorted(set(observed) - set(expected))
        raise StressHarnessError(
            "Python stress results differ from compiled attempts; "
            f"missing={missing!r}; added={added!r}"
        )
    for key, expected_axes in expected.items():
        if tuple(observed[key]["observed_semantic_axes"]) != expected_axes:
            raise StressHarnessError(
                f"Python stress result reports the wrong production seams for {key!r}"
            )
    return tuple(observed[key] for key in sorted(observed))


def _parse_candidate(path: Path) -> CandidateIdentity:
    value = load_canonical_json(path)
    candidate, issues = parse_candidate_identity(value)
    if candidate is None or issues:
        rendered = "; ".join(
            f"{item.code} at {item.path}: {item.message}" for item in issues
        )
        raise StressHarnessError(f"invalid candidate identity: {rendered}")
    return candidate


def _arguments(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--candidate-identity",
        type=Path,
        required=True,
        help="canonical Gate F candidate identity JSON",
    )
    parser.add_argument(
        "--repetitions",
        type=int,
        default=1,
        help=f"number of complete catalog repetitions (1...{MAX_REPETITIONS})",
    )
    parser.add_argument(
        "--execute-python",
        action="store_true",
        help="execute host-independent adapters and append their results",
    )
    parser.add_argument(
        "--qualification-run-id",
        help="coordinator-issued stable ID (required with --execute-python)",
    )
    parser.add_argument(
        "--qualification-run-nonce",
        help="coordinator-issued SHA-256 nonce (required with --execute-python)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="write canonical JSON here instead of stdout",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        arguments = _arguments(argv)
        candidate = _parse_candidate(arguments.candidate_identity)
        plan = compile_authority_stress_plan(
            candidate,
            repetitions=arguments.repetitions,
        )
        payload = plan_mapping(plan)
        if arguments.execute_python:
            qualification_run = parse_qualification_run_authority(
                arguments.qualification_run_id,
                arguments.qualification_run_nonce,
            )
            payload["python_results"] = list(
                execute_python_adapters(
                    plan,
                    candidate=candidate,
                    qualification_run=qualification_run,
                )
            )
        encoded = canonical_bytes(payload)
        if arguments.output is None:
            sys.stdout.buffer.write(encoded + b"\n")
        else:
            arguments.output.parent.mkdir(parents=True, exist_ok=True)
            arguments.output.write_bytes(encoded)
        return 0
    except (OSError, ValueError) as error:
        print(f"authority stress harness failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
