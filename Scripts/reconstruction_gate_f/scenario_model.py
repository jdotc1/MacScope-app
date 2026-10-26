"""Closed, deterministic Gate F scenario-catalog model.

The catalog is a value-only compiler input/output boundary.  It deliberately
contains no test implementation, filesystem path, subprocess, or mutable
runtime authority.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from enum import Enum

from .canonical_json import canonical_sha256, to_primitive
from .schema import EvidenceLayer, SHA256_RE, STABLE_ID_RE, ValidationIssue

SCENARIO_SCHEMA_VERSION = 1
MAX_SCENARIO_TEXT_BYTES = 512


class ScenarioDomain(str, Enum):
    DURABLE_AUTHORITY = "durable-authority"
    PERSISTENCE = "persistence"
    TASK8_PROTOCOL = "task8-protocol"
    TASK10_PRESENTATION = "task10-presentation"
    NATIVE_INSTALL = "native-install"
    MERGE_POSTMERGE = "merge-postmerge"
    AUTHORITY_RACE = "authority-race"


class ScenarioOrigin(str, Enum):
    COMMISSIONED = "commissioned"
    PAIRWISE = "pairwise"
    HIGHER_ORDER = "higher-order"


@dataclass(frozen=True, order=True)
class ScenarioParameter:
    name: str
    value: str


@dataclass(frozen=True)
class Scenario:
    schema_version: int
    scenario_id: str
    domain: ScenarioDomain
    title: str
    requirement_ids: tuple[str, ...]
    parameters: tuple[ScenarioParameter, ...]
    evidence_layers: tuple[EvidenceLayer, ...]
    command_groups: tuple[str, ...]
    origin: ScenarioOrigin
    higher_order_rationale: str | None


@dataclass(frozen=True)
class PairwiseFactor:
    factor_id: str
    values: tuple[str, ...]


@dataclass(frozen=True, order=True)
class PairwiseCoverage:
    left_factor: str
    left_value: str
    right_factor: str
    right_value: str
    scenario_id: str


@dataclass(frozen=True)
class ScenarioCatalog:
    schema_version: int
    candidate_identity_sha256: str
    scenarios: tuple[Scenario, ...]
    pairwise_factors: tuple[PairwiseFactor, ...]
    pairwise_coverage: tuple[PairwiseCoverage, ...]
    required_scenario_ids: tuple[str, ...]


def scenario_catalog_sha256(catalog: ScenarioCatalog) -> str:
    return canonical_sha256(to_primitive(catalog))


def _text_issues(value: object, *, path: str, identifier: bool = False) -> list[ValidationIssue]:
    if not isinstance(value, str) or not value:
        return [ValidationIssue("text-type", path, "must be nonempty text")]
    try:
        size = len(value.encode("utf-8"))
    except UnicodeEncodeError:
        size = MAX_SCENARIO_TEXT_BYTES + 1
    if size > MAX_SCENARIO_TEXT_BYTES:
        return [ValidationIssue("text-bounds", path, "text exceeds the closed UTF-8 bound")]
    if identifier and STABLE_ID_RE.fullmatch(value) is None:
        return [ValidationIssue("stable-id", path, "must be a canonical stable ID")]
    return []


def validate_scenario_catalog(catalog: ScenarioCatalog) -> tuple[ValidationIssue, ...]:
    """Validate ordering, closure, identity binding, and pairwise completeness."""

    issues: list[ValidationIssue] = []
    if catalog.schema_version != SCENARIO_SCHEMA_VERSION:
        issues.append(ValidationIssue("schema-version", "$.schema_version", "unsupported scenario schema"))
    if SHA256_RE.fullmatch(catalog.candidate_identity_sha256) is None:
        issues.append(
            ValidationIssue(
                "candidate-sha256",
                "$.candidate_identity_sha256",
                "must bind one exact candidate identity",
            )
        )

    scenario_ids = tuple(item.scenario_id for item in catalog.scenarios)
    if not scenario_ids:
        issues.append(
            ValidationIssue(
                "empty-scenario-catalog",
                "$.scenarios",
                "the qualification scenario catalog must not be empty",
            )
        )
    if scenario_ids != tuple(sorted(scenario_ids)):
        issues.append(ValidationIssue("scenario-order", "$.scenarios", "scenarios must be stable-ID sorted"))
    if len(scenario_ids) != len(set(scenario_ids)):
        issues.append(ValidationIssue("duplicate-scenario", "$.scenarios", "scenario IDs must be unique"))

    known_ids = set(scenario_ids)
    scenarios_by_id = {item.scenario_id: item for item in catalog.scenarios}
    for index, scenario in enumerate(catalog.scenarios):
        path = f"$.scenarios[{index}]"
        if scenario.schema_version != SCENARIO_SCHEMA_VERSION:
            issues.append(ValidationIssue("schema-version", path, "unsupported scenario schema"))
        issues.extend(_text_issues(scenario.scenario_id, path=f"{path}.scenario_id", identifier=True))
        issues.extend(_text_issues(scenario.title, path=f"{path}.title"))
        if not isinstance(scenario.domain, ScenarioDomain):
            issues.append(ValidationIssue("scenario-domain", f"{path}.domain", "unknown scenario domain"))
        if not isinstance(scenario.origin, ScenarioOrigin):
            issues.append(ValidationIssue("scenario-origin", f"{path}.origin", "unknown scenario origin"))
        if not scenario.requirement_ids:
            issues.append(ValidationIssue("missing-requirement", f"{path}.requirement_ids", "must not be empty"))
        if not scenario.evidence_layers:
            issues.append(ValidationIssue("missing-evidence-layer", f"{path}.evidence_layers", "must not be empty"))
        if not scenario.command_groups:
            issues.append(ValidationIssue("missing-command-group", f"{path}.command_groups", "must not be empty"))
        for field_name, values in (
            ("requirement_ids", scenario.requirement_ids),
            ("command_groups", scenario.command_groups),
        ):
            if values != tuple(sorted(set(values))):
                issues.append(
                    ValidationIssue(
                        "catalog-order",
                        f"{path}.{field_name}",
                        "values must be unique and sorted",
                    )
                )
            for value_index, value in enumerate(values):
                issues.extend(
                    _text_issues(value, path=f"{path}.{field_name}[{value_index}]", identifier=True)
                )
        parameter_names = tuple(item.name for item in scenario.parameters)
        if (
            scenario.parameters != tuple(sorted(scenario.parameters))
            or len(parameter_names) != len(set(parameter_names))
        ):
            issues.append(
                ValidationIssue(
                    "parameter-order",
                    f"{path}.parameters",
                    "parameter names must be unique and parameters sorted",
                )
            )
        for parameter_index, parameter in enumerate(scenario.parameters):
            issues.extend(
                _text_issues(
                    parameter.name,
                    path=f"{path}.parameters[{parameter_index}].name",
                    identifier=True,
                )
            )
            issues.extend(
                _text_issues(
                    parameter.value,
                    path=f"{path}.parameters[{parameter_index}].value",
                    identifier=True,
                )
            )
        evidence_layers_are_closed = all(
            isinstance(item, EvidenceLayer) for item in scenario.evidence_layers
        )
        if not evidence_layers_are_closed:
            issues.append(
                ValidationIssue(
                    "evidence-layer",
                    f"{path}.evidence_layers",
                    "evidence layers must use the closed vocabulary",
                )
            )
        elif scenario.evidence_layers != tuple(
            sorted(set(scenario.evidence_layers), key=lambda item: item.value)
        ):
            issues.append(
                ValidationIssue(
                    "evidence-layer-order",
                    f"{path}.evidence_layers",
                    "evidence layers must be unique and sorted",
                )
            )
        if scenario.origin is ScenarioOrigin.HIGHER_ORDER:
            if not scenario.higher_order_rationale:
                issues.append(
                    ValidationIssue(
                        "missing-higher-order-rationale",
                        f"{path}.higher_order_rationale",
                        "higher-order scenarios must explain why pairwise coverage is insufficient",
                    )
                )
            else:
                issues.extend(
                    _text_issues(
                        scenario.higher_order_rationale,
                        path=f"{path}.higher_order_rationale",
                    )
                )
        elif scenario.higher_order_rationale is not None:
            issues.append(
                ValidationIssue(
                    "unexpected-higher-order-rationale",
                    f"{path}.higher_order_rationale",
                    "only higher-order scenarios carry a rationale",
                )
            )

    required_ids = catalog.required_scenario_ids
    if not required_ids:
        issues.append(
            ValidationIssue(
                "empty-required-scenarios",
                "$.required_scenario_ids",
                "the required scenario catalog must not be empty",
            )
        )
    if required_ids != tuple(sorted(set(required_ids))):
        issues.append(
            ValidationIssue("required-order", "$.required_scenario_ids", "required IDs must be unique and sorted")
        )
    missing = sorted(set(required_ids) - known_ids)
    for scenario_id in missing:
        issues.append(
            ValidationIssue(
                "missing-required-scenario",
                "$.required_scenario_ids",
                f"required scenario is absent: {scenario_id}",
            )
        )

    factors = catalog.pairwise_factors
    if len(factors) < 2:
        issues.append(
            ValidationIssue(
                "missing-pairwise-factors",
                "$.pairwise_factors",
                "the closed pairwise model requires at least two factors",
            )
        )
    factor_ids = tuple(item.factor_id for item in factors)
    if factor_ids != tuple(sorted(factor_ids)) or len(factor_ids) != len(set(factor_ids)):
        issues.append(ValidationIssue("factor-order", "$.pairwise_factors", "factors must be unique and sorted"))
    expected_pairs: set[tuple[str, str, str, str]] = set()
    factor_values: dict[str, set[str]] = {}
    for index, left in enumerate(factors):
        factor_values[left.factor_id] = set(left.values)
        issues.extend(
            _text_issues(
                left.factor_id,
                path=f"$.pairwise_factors[{index}].factor_id",
                identifier=True,
            )
        )
        if left.values != tuple(sorted(set(left.values))) or not left.values:
            issues.append(
                ValidationIssue(
                    "factor-value-order",
                    f"$.pairwise_factors[{index}].values",
                    "factor values must be nonempty, unique, and sorted",
                )
            )
        for value_index, value in enumerate(left.values):
            issues.extend(
                _text_issues(
                    value,
                    path=f"$.pairwise_factors[{index}].values[{value_index}]",
                    identifier=True,
                )
            )
        for right in factors[index + 1 :]:
            for left_value in left.values:
                for right_value in right.values:
                    expected_pairs.add((left.factor_id, left_value, right.factor_id, right_value))

    pairwise_scenario_ids: set[str] = set()
    factor_id_set = set(factor_ids)
    for scenario in catalog.scenarios:
        if scenario.origin is not ScenarioOrigin.PAIRWISE:
            continue
        pairwise_scenario_ids.add(scenario.scenario_id)
        parameters = {item.name: item.value for item in scenario.parameters}
        if set(parameters) != factor_id_set:
            issues.append(
                ValidationIssue(
                    "pairwise-row-shape",
                    f"$.scenarios.{scenario.scenario_id}.parameters",
                    "pairwise scenarios must bind exactly one value for every factor",
                )
            )
            continue
        invalid_values = sorted(
            factor_id
            for factor_id, value in parameters.items()
            if value not in factor_values.get(factor_id, set())
        )
        if invalid_values:
            issues.append(
                ValidationIssue(
                    "pairwise-row-value",
                    f"$.scenarios.{scenario.scenario_id}.parameters",
                    "pairwise scenario uses values outside the closed factor model",
                )
            )
            continue
        encoded = "|".join(
            f"{factor.factor_id}={parameters[factor.factor_id]}" for factor in factors
        ).encode("utf-8")
        expected_id = "matrix.pairwise." + hashlib.sha256(encoded).hexdigest()[:16]
        if scenario.scenario_id != expected_id:
            issues.append(
                ValidationIssue(
                    "pairwise-row-identity",
                    f"$.scenarios.{scenario.scenario_id}.scenario_id",
                    "pairwise scenario ID does not commit to its exact factor row",
                )
            )

    coverage_keys = {
        (item.left_factor, item.left_value, item.right_factor, item.right_value)
        for item in catalog.pairwise_coverage
    }
    if len(coverage_keys) != len(catalog.pairwise_coverage):
        issues.append(
            ValidationIssue(
                "duplicate-pairwise-coverage",
                "$.pairwise_coverage",
                "each factor-value pair must have exactly one owning scenario",
            )
        )
    if not catalog.pairwise_coverage:
        issues.append(
            ValidationIssue(
                "empty-pairwise-coverage",
                "$.pairwise_coverage",
                "pairwise coverage must contain physical coverage records",
            )
        )
    if catalog.pairwise_coverage != tuple(sorted(set(catalog.pairwise_coverage))):
        issues.append(
            ValidationIssue(
                "coverage-order",
                "$.pairwise_coverage",
                "coverage records must be unique and sorted",
            )
        )
    for item in catalog.pairwise_coverage:
        if item.scenario_id not in known_ids:
            issues.append(
                ValidationIssue(
                    "unknown-coverage-scenario",
                    "$.pairwise_coverage",
                    f"coverage refers to unknown scenario: {item.scenario_id}",
                )
            )
            continue
        scenario = scenarios_by_id[item.scenario_id]
        parameters = {parameter.name: parameter.value for parameter in scenario.parameters}
        if scenario.origin is not ScenarioOrigin.PAIRWISE or (
            parameters.get(item.left_factor) != item.left_value
            or parameters.get(item.right_factor) != item.right_value
        ):
            issues.append(
                ValidationIssue(
                    "pairwise-coverage-owner",
                    "$.pairwise_coverage",
                    "coverage must point to a pairwise scenario carrying the exact factor values",
                )
            )
    coverage_scenario_ids = {item.scenario_id for item in catalog.pairwise_coverage}
    for scenario_id in sorted(pairwise_scenario_ids - coverage_scenario_ids):
        issues.append(
            ValidationIssue(
                "unreferenced-pairwise-scenario",
                "$.pairwise_coverage",
                f"pairwise scenario owns no coverage: {scenario_id}",
            )
        )
    for pair in sorted(expected_pairs - coverage_keys):
        issues.append(
            ValidationIssue(
                "missing-pairwise-coverage",
                "$.pairwise_coverage",
                "uncovered factor pair: " + "/".join(pair),
            )
        )
    for pair in sorted(coverage_keys - expected_pairs):
        issues.append(
            ValidationIssue(
                "unknown-pairwise-coverage",
                "$.pairwise_coverage",
                "coverage is outside the closed factor model: " + "/".join(pair),
            )
        )
    return tuple(sorted(set(issues)))
