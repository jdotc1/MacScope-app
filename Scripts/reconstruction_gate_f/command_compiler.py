"""Identity-bound Gate F command-plan compiler.

The compiler resolves only whole-token placeholders into an argv array.  It
never emits shell text, expands a branch name into authority, or invents a
missing repository script.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path

from .canonical_json import canonical_sha256, to_primitive
from .command_catalog import (
    CampaignProfile,
    CommandExecutionMode,
    CommandHost,
    CommandMutationState,
    CommandTemplate,
    ExpectedExit,
    installed_gate_output_slots,
    command_templates,
)
from .scenario_compiler import (
    PAIRWISE_FACTORS,
    REQUIRED_SCENARIO_IDS,
    pairwise_scenarios,
    required_scenario_shape_drift,
)
from .scenario_model import (
    ScenarioCatalog,
    ScenarioOrigin,
    scenario_catalog_sha256,
    validate_scenario_catalog,
)
from .schema import (
    SHA256_RE,
    STABLE_ID_RE,
    CandidateIdentity,
    EvidenceLayer,
    ValidationIssue,
    candidate_identity_sha256,
    candidate_to_mapping,
    validate_candidate_identity,
)

COMMAND_PLAN_SCHEMA_VERSION = 3
COMMAND_SCHEMA_VERSION = 3
RUNTIME_ARGUMENT_KIND = "prerequisite-receipt-set-sha256-v1"
RUNTIME_ARGUMENT_MARKER = "@gatef-runtime:prerequisite-receipt-set-sha256-v1@"
RUNTIME_INPUT_NAMES = frozenset({
    "hosted_governance_predecessor_observations_sha256",
    "deterministic_evidence_predecessor_observations_sha256",
    "signed_xpc_supervision_predecessor_observations_sha256",
    "signed_reconstruction_predecessor_observations_sha256",
    "signed_xpc_content_predecessor_observations_sha256",
    "signed_xpc_error_cancellation_predecessor_observations_sha256",
    "install_release_predecessor_observations_sha256",
    "installed_task10_predecessor_observations_sha256",
    "installed_accessibility_predecessor_observations_sha256",
    "bootstrap_fullsuite_predecessor_observations_sha256",
    "bootstrap_products_predecessor_observations_sha256",
})
PLACEHOLDER_RE = re.compile(r"^@([a-z][a-z0-9_]*)@$", re.ASCII)
PLACEHOLDER_ANY_RE = re.compile(r"@([a-z][a-z0-9_]*)@", re.ASCII)
FORBIDDEN_ENTRYPOINT = "sync_roadmap_status.py"
EXTERNAL_PREREQUISITE_IDS = frozenset({"candidate-identity-accepted"})


class CommandCompilationError(ValueError):
    pass


@dataclass(frozen=True)
class RuntimeArgumentSlot:
    argv_index: int
    kind: str


@dataclass(frozen=True)
class CommandRecord:
    schema_version: int
    command_id: str
    candidate_identity_sha256: str
    scenario_ids: tuple[str, ...]
    command_groups: tuple[str, ...]
    argv: tuple[str, ...]
    working_directory: str
    environment: tuple[tuple[str, str], ...]
    host: CommandHost
    evidence_layer: EvidenceLayer
    prerequisite_ids: tuple[str, ...]
    expected_exits: tuple[ExpectedExit, ...]
    timeout_seconds: int
    generated_artifacts: tuple[str, ...]
    generated_logs: tuple[str, ...]
    receipt_fields: tuple[str, ...]
    mutation_state: CommandMutationState
    cleanup_rollback: tuple[str, ...]
    stop_on_failure: bool
    execution_mode: CommandExecutionMode
    unavailability_reason: str | None
    runtime_argument_slots: tuple[RuntimeArgumentSlot, ...]


@dataclass(frozen=True, order=True)
class ScenarioCommandBinding:
    scenario_id: str
    command_ids: tuple[str, ...]


@dataclass(frozen=True)
class CommandPlan:
    schema_version: int
    candidate_identity_sha256: str
    scenario_catalog_sha256: str
    command_inputs: tuple[tuple[str, str], ...]
    commands: tuple[CommandRecord, ...]
    scenario_bindings: tuple[ScenarioCommandBinding, ...]
    executor_required_layers: tuple[EvidenceLayer, ...]


def command_plan_sha256(plan: CommandPlan) -> str:
    return canonical_sha256(to_primitive(plan))


def _candidate_inputs(candidate: CandidateIdentity) -> dict[str, str]:
    return {
        "candidate_commit": candidate.source.commit,
        "candidate_tree": candidate.source.tree,
        "candidate_identity_sha256": candidate_identity_sha256(candidate),
        "application_bundle_sha256": candidate.application.bundle_sha256,
        "application_executable_sha256": candidate.application.executable_sha256,
        "selector_catalog_sha256": candidate.selector_catalog_sha256,
    }


def _placeholder_names(template: CommandTemplate) -> set[str]:
    for value in ((template.working_directory,) + tuple(value for _, value in template.environment)
                  + template.generated_artifacts + template.generated_logs):
        if RUNTIME_ARGUMENT_MARKER in value or any(match.group(1) in RUNTIME_INPUT_NAMES
                for match in PLACEHOLDER_ANY_RE.finditer(value)):
            raise CommandCompilationError("runtime placeholders are allowed only in standalone argv slots")
    for value in template.argv:
        names = {match.group(1) for match in PLACEHOLDER_ANY_RE.finditer(value)} & RUNTIME_INPUT_NAMES
        if RUNTIME_ARGUMENT_MARKER in value or (names and value not in {f"@{name}@" for name in names}):
            raise CommandCompilationError("runtime placeholders must occupy exact standalone argv slots")
    values = (
        template.argv
        + (template.working_directory,)
        + tuple(value for _, value in template.environment)
        + template.generated_artifacts
        + template.generated_logs
    )
    return {
        match.group(1)
        for value in values
        for match in PLACEHOLDER_ANY_RE.finditer(value)
    }


def required_command_input_names(
    templates: Iterable[CommandTemplate] | None = None,
    *, profile: CampaignProfile = CampaignProfile.EXISTING,
) -> tuple[str, ...]:
    selected = tuple(command_templates(profile=profile) if templates is None else templates)
    names: set[str] = set()
    for template in selected:
        names.update(_placeholder_names(template))
    names.difference_update(
        {
            "candidate_commit",
            "candidate_tree",
            "candidate_identity_sha256",
            "application_bundle_sha256",
            "application_executable_sha256",
            "selector_catalog_sha256",
        }
    )
    return tuple(sorted(names - RUNTIME_INPUT_NAMES))


def runtime_slots_for_template(template: CommandTemplate) -> tuple[RuntimeArgumentSlot, ...]:
    _placeholder_names(template)
    return tuple(RuntimeArgumentSlot(index, RUNTIME_ARGUMENT_KIND)
                 for index, value in enumerate(template.argv)
                 if value in {f"@{name}@" for name in RUNTIME_INPUT_NAMES})


def validate_runtime_slots(record: CommandRecord) -> None:
    if type(record.runtime_argument_slots) is not tuple:
        raise CommandCompilationError("runtime slots must be a tuple")
    indices = []
    for slot in record.runtime_argument_slots:
        if (type(slot) is not RuntimeArgumentSlot or type(slot.argv_index) is not int
                or not 0 <= slot.argv_index < len(record.argv) or slot.kind != RUNTIME_ARGUMENT_KIND):
            raise CommandCompilationError("invalid runtime argument slot")
        indices.append(slot.argv_index)
    if indices != sorted(set(indices)):
        raise CommandCompilationError("runtime argument slots must be unique and ordered")
    markers = [index for index, value in enumerate(record.argv) if value == RUNTIME_ARGUMENT_MARKER]
    if indices != markers or any("@gatef-runtime:" in value and value != RUNTIME_ARGUMENT_MARKER for value in record.argv):
        raise CommandCompilationError("runtime argument slots do not match static argv markers")


def _resolve(
    value: str,
    inputs: Mapping[str, str],
    *,
    allow_embedded: bool = False,
) -> str:
    match = PLACEHOLDER_RE.fullmatch(value)
    if match is None:
        matches = tuple(PLACEHOLDER_ANY_RE.finditer(value))
        if matches and allow_embedded:
            resolved = value
            for embedded in matches:
                key = embedded.group(1)
                try:
                    replacement = inputs[key]
                except KeyError as error:
                    raise CommandCompilationError(f"missing command input: {key}") from error
                resolved = resolved.replace(embedded.group(0), replacement)
            return resolved
        if "@" in value:
            raise CommandCompilationError(
                f"placeholders must occupy one complete argv/value token: {value!r}"
            )
        return value
    key = match.group(1)
    try:
        return inputs[key]
    except KeyError as error:
        raise CommandCompilationError(f"missing command input: {key}") from error


def _resolve_argv(template: CommandTemplate, inputs: Mapping[str, str]) -> tuple[str, ...]:
    """Permit embedded substitution only in the eight governed aggregate slots."""
    slots = installed_gate_output_slots() if '--acceptance-gate-output' in template.argv else ()
    allowed = {gate + "=@" + name + "@": (gate, name) for gate, name in slots}
    observed = []
    result = []
    for index, value in enumerate(template.argv):
        if index and template.argv[index - 1] == "--acceptance-gate-output":
            if template.command_id != "installed.emit-report" or value not in allowed:
                raise CommandCompilationError("unknown or malformed installed acceptance gate output slot")
            gate, name = allowed[value]
            observed.append(gate)
            result.append(gate + "=" + inputs[name])
        else:
            result.append(RUNTIME_ARGUMENT_MARKER if value in {f"@{name}@" for name in RUNTIME_INPUT_NAMES}
                          else _resolve(value, inputs))
    if observed and tuple(observed) != tuple(gate for gate, _ in slots):
        raise CommandCompilationError("installed acceptance gate output slots must be complete, unique and ordered")
    return tuple(result)


def _validate_input_mapping(
    values: Mapping[str, str],
    templates: tuple[CommandTemplate, ...],
    candidate: CandidateIdentity,
    *, profile: CampaignProfile = CampaignProfile.EXISTING,
) -> dict[str, str]:
    candidate_values = _candidate_inputs(candidate)
    if set(values) & RUNTIME_INPUT_NAMES:
        raise CommandCompilationError("runtime predecessor hashes cannot be supplied as command inputs")
    collisions = sorted(set(values) & set(candidate_values))
    if collisions:
        raise CommandCompilationError(
            "candidate-derived command inputs cannot be overridden: " + ", ".join(collisions)
        )
    required = set(required_command_input_names(templates))
    missing = sorted(required - set(values))
    unknown = sorted(set(values) - required)
    if missing:
        raise CommandCompilationError("missing command inputs: " + ", ".join(missing))
    if unknown:
        raise CommandCompilationError("unknown command inputs: " + ", ".join(unknown))
    normalized = dict(candidate_values)
    nonpath_inputs = {
        "generated_at_unix_ms",
        "integration_ref",
        "native_wrapper_revision",
        "qualification_run_id",
        "qualification_run_nonce",
        "sdk_name",
    }
    sha256_inputs = {
        name
        for name in required
        if name.endswith("_predecessor_observations_sha256")
    } | {"qualification_run_nonce"}
    nonpath_inputs.update(sha256_inputs)
    for name, value in values.items():
        if not isinstance(value, str) or not value:
            raise CommandCompilationError(f"command input {name} must be nonempty text")
        try:
            size = len(value.encode("utf-8"))
        except UnicodeEncodeError as error:
            raise CommandCompilationError(f"command input {name} is not UTF-8") from error
        if size > 4_096 or "\x00" in value or "\n" in value or "\r" in value:
            raise CommandCompilationError(f"command input {name} is unbounded or unsafe")
        if name not in nonpath_inputs and not Path(value).is_absolute():
            raise CommandCompilationError(f"command input {name} must be an absolute path")
        normalized[name] = value
    if re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", normalized["native_wrapper_revision"]) is None:
        raise CommandCompilationError("native_wrapper_revision must be lowercase 40- or 64-hex")
    if (
        "qualification_run_id" in normalized
        and STABLE_ID_RE.fullmatch(normalized["qualification_run_id"]) is None
    ):
        raise CommandCompilationError(
            "qualification_run_id must be a canonical lowercase stable ID"
        )
    for name in sorted(sha256_inputs):
        if name in normalized and SHA256_RE.fullmatch(normalized[name]) is None:
            raise CommandCompilationError(f"{name} must be a lowercase SHA-256")
    if not normalized["generated_at_unix_ms"].isdigit():
        raise CommandCompilationError("generated_at_unix_ms must be a nonnegative integer")
    if not normalized["integration_ref"].startswith("refs/"):
        raise CommandCompilationError("integration_ref must be a fully qualified ref")
    if profile is CampaignProfile.BOOTSTRAP_VERIFIER:
        shell_report = Path(normalized['installed_shell_smoke_report'])
        shell_paths = {
            'installed_full_surface_report': shell_report,
            'installed_legacy_grid_report': shell_report.with_name(shell_report.stem + '.legacy-grid' + shell_report.suffix),
        }
        for name, path in shell_paths.items():
            if normalized[name] != str(path):
                raise CommandCompilationError(f'{name} must equal the bootstrap shell producer path: {path}')
        native_work = Path(normalized["output_root"]) / "native-work"
        expected = {
            "native_build_root": native_work / "normal",
            "native_sanitizer_build_root": native_work / "sanitizers",
            "native_normal_report_dir": native_work / "normal/qualification",
            "native_asan_report_dir": native_work / "sanitizers/address/qualification",
            "native_ubsan_report_dir": native_work / "sanitizers/undefined/qualification",
            "native_golden_work_root": native_work / "golden",
            "native_source_root": Path(normalized["repository_root"]) / "Tools/NativeDecompilerBridge",
        }
        for name, path in expected.items():
            if normalized[name] != str(path):
                raise CommandCompilationError(f"{name} must equal the fixed bootstrap native path: {path}")
    return normalized


def _repository_script_tokens(argv: tuple[str, ...]) -> tuple[str, ...]:
    result = []
    for index, token in enumerate(argv):
        relative = token[2:] if token.startswith("./Scripts/") else token
        if relative.startswith("Scripts/"):
            result.append(relative)
        elif index > 0 and argv[index - 1] == "-m" and token.startswith("Scripts."):
            # Frozen source-owned modules only; no imports or package discovery.
            result.append(token.replace(".", "/") + ".py")
    return tuple(result)


def _matches_template_value(
    template_value: str,
    resolved_value: str,
    trusted_values: Mapping[str, str],
) -> bool:
    match = PLACEHOLDER_RE.fullmatch(template_value)
    if match is not None:
        trusted = trusted_values.get(match.group(1))
        if trusted is not None:
            return resolved_value == trusted
        return bool(resolved_value) and PLACEHOLDER_ANY_RE.search(resolved_value) is None
    pieces: list[str] = []
    cursor = 0
    for embedded in PLACEHOLDER_ANY_RE.finditer(template_value):
        pieces.append(re.escape(template_value[cursor : embedded.start()]))
        trusted = trusted_values.get(embedded.group(1))
        pieces.append(re.escape(trusted) if trusted is not None else ".+")
        cursor = embedded.end()
    if pieces:
        pieces.append(re.escape(template_value[cursor:]))
        return re.fullmatch("".join(pieces), resolved_value) is not None
    return template_value == resolved_value


def _validate_frozen_template(
    template: CommandTemplate,
    record: CommandRecord,
    trusted_values: Mapping[str, str],
) -> list[ValidationIssue]:
    path = f"$.commands.{record.command_id}"
    issues: list[ValidationIssue] = []

    def drift(field: str) -> None:
        issues.append(
            ValidationIssue(
                "command-template-drift",
                f"{path}.{field}",
                f"{field} differs from the frozen command template",
            )
        )

    literal_fields = (
        "command_groups",
        "host",
        "evidence_layer",
        "prerequisite_ids",
        "expected_exits",
        "timeout_seconds",
        "receipt_fields",
        "mutation_state",
        "cleanup_rollback",
        "stop_on_failure",
        "execution_mode",
        "unavailability_reason",
    )
    for field in literal_fields:
        if getattr(record, field) != getattr(template, field):
            drift(field)

    if not _matches_template_value(
        template.working_directory,
        record.working_directory,
        trusted_values,
    ):
        drift("working_directory")
    for field in ("argv",):
        expected = getattr(template, field)
        observed = getattr(record, field)
        if len(expected) != len(observed) or any(
            not (resolved_value == RUNTIME_ARGUMENT_MARKER
                 if template_value in {f"@{name}@" for name in RUNTIME_INPUT_NAMES}
                 else _matches_template_value(template_value, resolved_value, trusted_values))
            for template_value, resolved_value in zip(expected, observed)
        ):
            drift(field)
    try:
        validate_runtime_slots(record)
        if record.runtime_argument_slots != runtime_slots_for_template(template):
            drift("runtime_argument_slots")
    except CommandCompilationError:
        drift("runtime_argument_slots")
    for field in ("generated_artifacts", "generated_logs"):
        observed = getattr(record, field)
        try:
            expected = tuple(sorted(_resolve(value, trusted_values, allow_embedded=True)
                                    for value in getattr(template, field)))
        except CommandCompilationError:
            drift(field)
            continue
        if observed != expected or len(observed) != len(set(observed)):
            drift(field)
    if len(template.environment) != len(record.environment) or any(
        template_name != record_name
        or not _matches_template_value(template_value, record_value, trusted_values)
        for (template_name, template_value), (record_name, record_value) in zip(
            template.environment,
            record.environment,
        )
    ):
        drift("environment")
    return issues


def _validate_live_entrypoints(
    template: CommandTemplate,
    record: CommandRecord,
    repository_root: Path,
) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    if record.argv:
        executable = record.argv[0]
        if executable != "/usr/bin/python3" and not executable.startswith("./Scripts/"):
            issues.append(
                ValidationIssue(
                    "unknown-executable",
                    f"$.commands.{record.command_id}.argv",
                    f"executable is outside the closed command catalog: {executable}",
                )
            )
    for token in record.argv:
        if FORBIDDEN_ENTRYPOINT in token:
            issues.append(
                ValidationIssue(
                    "stale-entrypoint",
                    f"$.commands.{record.command_id}.argv",
                    f"forbidden stale entrypoint: {FORBIDDEN_ENTRYPOINT}",
                )
            )
        if token in {"&&", "||", "|", ";"}:
            issues.append(
                ValidationIssue(
                    "shell-interpolation",
                    f"$.commands.{record.command_id}.argv",
                    "argv must not contain shell control operators",
                )
            )
    for relative in _repository_script_tokens(record.argv):
        path = repository_root / relative
        if not path.is_file() or path.is_symlink():
            issues.append(
                ValidationIssue(
                    "invented-entrypoint",
                    f"$.commands.{record.command_id}.argv",
                    f"repository entrypoint does not exist: {relative}",
                )
            )

    if "--only-testing" in record.argv:
        index = record.argv.index("--only-testing")
        if index + 1 >= len(record.argv):
            issues.append(
                ValidationIssue(
                    "selector-missing",
                    f"$.commands.{record.command_id}.argv",
                    "--only-testing requires an exact selector",
                )
            )
        else:
            selector = record.argv[index + 1]
            parts = selector.split("/")
            if len(parts) < 2 or parts[0] != "CoreTests":
                issues.append(
                    ValidationIssue(
                        "selector-shape",
                        f"$.commands.{record.command_id}.argv",
                        f"unsupported selector shape: {selector}",
                    )
                )
            else:
                suite_path = repository_root / "MacScope" / "Tests" / "CoreTests" / f"{parts[1]}.swift"
                if not suite_path.is_file():
                    issues.append(
                        ValidationIssue(
                            "invented-selector",
                            f"$.commands.{record.command_id}.argv",
                            f"selector suite does not exist: {selector}",
                        )
                    )

    if template.execution_mode is CommandExecutionMode.EXECUTOR_REQUIRED:
        if record.argv:
            issues.append(
                ValidationIssue(
                    "executor-required-argv",
                    f"$.commands.{record.command_id}.argv",
                    "an unavailable operation must not masquerade as an executable command",
                )
            )
        if not record.unavailability_reason:
            issues.append(
                ValidationIssue(
                    "executor-required-reason",
                    f"$.commands.{record.command_id}.unavailability_reason",
                    "executor-required commands need a bounded reason",
                )
            )
    elif not record.argv:
        issues.append(
            ValidationIssue(
                "missing-argv",
                f"$.commands.{record.command_id}.argv",
                "runnable and vector-only commands require exact argv",
            )
        )
    elif record.unavailability_reason is not None:
        issues.append(
            ValidationIssue(
                "unexpected-unavailability",
                f"$.commands.{record.command_id}.unavailability_reason",
                "only executor-required commands carry an unavailable reason",
            )
        )
    return issues


def validate_command_plan(
    plan: CommandPlan,
    *,
    candidate: CandidateIdentity,
    scenario_catalog: ScenarioCatalog,
    repository_root: Path,
    templates: Mapping[str, CommandTemplate],
    profile: CampaignProfile = CampaignProfile.EXISTING,
) -> tuple[ValidationIssue, ...]:
    issues: list[ValidationIssue] = []
    candidate_issues = validate_candidate_identity(candidate_to_mapping(candidate))
    issues.extend(candidate_issues)
    issues.extend(validate_scenario_catalog(scenario_catalog))
    frozen_templates = {item.command_id: item for item in command_templates(profile=profile)}
    if dict(templates) != frozen_templates:
        issues.append(
            ValidationIssue(
                "template-catalog-mismatch",
                "$.commands",
                "validation must use the frozen live command catalog",
            )
        )
    templates = frozen_templates
    candidate_digest = candidate_identity_sha256(candidate)
    if plan.command_inputs != tuple(sorted(plan.command_inputs)):
        issues.append(
            ValidationIssue(
                "command-input-order",
                "$.command_inputs",
                "command inputs must be stable-name sorted",
            )
        )
    command_input_names = tuple(name for name, _ in plan.command_inputs)
    if len(command_input_names) != len(set(command_input_names)):
        issues.append(
            ValidationIssue(
                "duplicate-command-input",
                "$.command_inputs",
                "command input names must be unique",
            )
        )
    try:
        trusted_template_values = _validate_input_mapping(
            dict(plan.command_inputs),
            tuple(frozen_templates.values()),
            candidate,
            profile=profile,
        )
    except (CommandCompilationError, TypeError, ValueError) as error:
        issues.append(
            ValidationIssue(
                "command-input-binding",
                "$.command_inputs",
                f"command plan carries invalid resolved inputs: {error}",
            )
        )
        trusted_template_values = _candidate_inputs(candidate) | {
            "repository_root": str(repository_root),
        }
    else:
        try:
            bound_repository_root = Path(
                trusted_template_values["repository_root"]
            ).resolve(strict=True)
        except (KeyError, OSError, RuntimeError) as error:
            issues.append(
                ValidationIssue(
                    "command-input-binding",
                    "$.command_inputs.repository_root",
                    f"bound repository root is unavailable: {error}",
                )
            )
        else:
            if bound_repository_root != repository_root.resolve(strict=True):
                issues.append(
                    ValidationIssue(
                        "command-input-binding",
                        "$.command_inputs.repository_root",
                        "bound repository root differs from the audited repository root",
                    )
                )
    if plan.schema_version != COMMAND_PLAN_SCHEMA_VERSION:
        issues.append(ValidationIssue("schema-version", "$.schema_version", "unsupported command-plan schema"))
    if plan.candidate_identity_sha256 != candidate_digest or SHA256_RE.fullmatch(plan.candidate_identity_sha256) is None:
        issues.append(
            ValidationIssue(
                "candidate-mismatch",
                "$.candidate_identity_sha256",
                "command plan must bind the exact candidate input",
            )
        )
    if scenario_catalog.candidate_identity_sha256 != candidate_digest:
        issues.append(
            ValidationIssue(
                "scenario-candidate-mismatch",
                "$.scenario_catalog.candidate_identity_sha256",
                "scenario catalog must bind the exact validated candidate",
            )
        )
    expected_scenario_digest = scenario_catalog_sha256(scenario_catalog)
    if plan.scenario_catalog_sha256 != expected_scenario_digest:
        issues.append(
            ValidationIssue(
                "scenario-catalog-mismatch",
                "$.scenario_catalog_sha256",
                "command plan must bind the exact scenario catalog",
            )
        )
    if scenario_catalog.required_scenario_ids != REQUIRED_SCENARIO_IDS:
        issues.append(
            ValidationIssue(
                "required-scenario-catalog",
                "$.scenario_catalog.required_scenario_ids",
                "the command plan requires the exact commissioned scenario catalog",
            )
        )
    if scenario_catalog.pairwise_factors != PAIRWISE_FACTORS:
        issues.append(
            ValidationIssue(
                "pairwise-factor-catalog",
                "$.scenario_catalog.pairwise_factors",
                "the command plan requires the exact commissioned factor model",
            )
        )
    _, expected_pairwise_scenarios, expected_pairwise_coverage = pairwise_scenarios()
    observed_pairwise_scenarios = tuple(
        item
        for item in scenario_catalog.scenarios
        if item.origin is ScenarioOrigin.PAIRWISE
    )
    if observed_pairwise_scenarios != expected_pairwise_scenarios:
        issues.append(
            ValidationIssue(
                "pairwise-scenario-catalog",
                "$.scenario_catalog.scenarios",
                "pairwise scenarios differ from the deterministic commissioned closure",
            )
        )
    if scenario_catalog.pairwise_coverage != expected_pairwise_coverage:
        issues.append(
            ValidationIssue(
                "pairwise-coverage-catalog",
                "$.scenario_catalog.pairwise_coverage",
                "pairwise coverage differs from the deterministic commissioned closure",
            )
        )
    for scenario_id in required_scenario_shape_drift(scenario_catalog.scenarios):
        issues.append(
            ValidationIssue(
                "required-scenario-shape",
                "$.scenario_catalog.scenarios",
                f"required scenario differs from its frozen shape: {scenario_id}",
            )
        )

    command_ids = tuple(item.command_id for item in plan.commands)
    if command_ids != tuple(sorted(command_ids)):
        issues.append(ValidationIssue("command-order", "$.commands", "commands must be stable-ID sorted"))
    if len(command_ids) != len(set(command_ids)):
        issues.append(ValidationIssue("duplicate-command", "$.commands", "command IDs must be unique"))
    missing_commands = sorted(set(templates) - set(command_ids))
    for command_id in missing_commands:
        issues.append(ValidationIssue("missing-command", "$.commands", command_id))

    scenarios_by_id = {item.scenario_id: item for item in scenario_catalog.scenarios}
    scenario_ids = set(scenarios_by_id)
    known_commands = set(command_ids)
    commands_by_id = {item.command_id: item for item in plan.commands}
    for index, record in enumerate(plan.commands):
        path = f"$.commands[{index}]"
        if record.schema_version != COMMAND_SCHEMA_VERSION:
            issues.append(ValidationIssue("schema-version", path, "unsupported command schema"))
        if STABLE_ID_RE.fullmatch(record.command_id) is None:
            issues.append(ValidationIssue("stable-id", f"{path}.command_id", "invalid command ID"))
        if record.candidate_identity_sha256 != candidate_digest:
            issues.append(ValidationIssue("candidate-mismatch", path, "command has another candidate"))
        if record.scenario_ids != tuple(sorted(set(record.scenario_ids))):
            issues.append(ValidationIssue("scenario-order", f"{path}.scenario_ids", "scenario IDs must be unique and sorted"))
        unknown_scenarios = sorted(set(record.scenario_ids) - scenario_ids)
        for scenario_id in unknown_scenarios:
            issues.append(ValidationIssue("unknown-scenario", path, f"unknown scenario: {scenario_id}"))
        if record.timeout_seconds < 1:
            issues.append(ValidationIssue("timeout", f"{path}.timeout_seconds", "must be positive"))
        if record.prerequisite_ids != tuple(sorted(set(record.prerequisite_ids))):
            issues.append(
                ValidationIssue(
                    "prerequisite-order",
                    f"{path}.prerequisite_ids",
                    "command prerequisites must be unique and sorted",
                )
            )
        for prerequisite_id in record.prerequisite_ids:
            if prerequisite_id not in known_commands | EXTERNAL_PREREQUISITE_IDS:
                issues.append(
                    ValidationIssue(
                        "unknown-prerequisite",
                        f"{path}.prerequisite_ids",
                        prerequisite_id,
                    )
                )
        if record.command_id in record.prerequisite_ids:
            issues.append(
                ValidationIssue(
                    "command-cycle",
                    f"{path}.prerequisite_ids",
                    "command cannot depend on itself",
                )
            )
        if record.expected_exits != tuple(sorted(set(record.expected_exits))):
            issues.append(
                ValidationIssue(
                    "expected-exit-order",
                    f"{path}.expected_exits",
                    "expected exit classes must be unique and sorted",
                )
            )
        template = templates.get(record.command_id)
        if template is None:
            issues.append(ValidationIssue("unknown-command", path, "command is not in the frozen catalog"))
        else:
            issues.extend(
                _validate_frozen_template(
                    template,
                    record,
                    trusted_template_values,
                )
            )
            expected_scenarios = tuple(
                sorted(
                    scenario.scenario_id
                    for scenario in scenario_catalog.scenarios
                    if set(scenario.command_groups) & set(record.command_groups)
                )
            )
            if record.scenario_ids != expected_scenarios:
                issues.append(
                    ValidationIssue(
                        "command-scenario-binding",
                        f"{path}.scenario_ids",
                        "command scenario IDs do not match its closed command groups",
                    )
                )
            issues.extend(_validate_live_entrypoints(template, record, repository_root))
        if Path(record.working_directory) != repository_root:
            issues.append(
                ValidationIssue(
                    "working-directory",
                    f"{path}.working_directory",
                    "commands must execute from the audited repository root",
                )
            )
        unresolved_values = record.argv + tuple(value for _, value in record.environment)
        if any(PLACEHOLDER_ANY_RE.search(value) for value in unresolved_values):
            issues.append(
                ValidationIssue(
                    "unresolved-placeholder",
                    path,
                    "executable argv and environment must be fully resolved",
                )
            )

    graph = {
        record.command_id: tuple(
            prerequisite_id
            for prerequisite_id in record.prerequisite_ids
            if prerequisite_id in known_commands
        )
        for record in plan.commands
    }
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(command_id: str) -> None:
        if command_id in visited:
            return
        if command_id in visiting:
            issues.append(
                ValidationIssue(
                    "command-cycle",
                    "$.commands",
                    f"command prerequisite cycle reaches {command_id}",
                )
            )
            return
        visiting.add(command_id)
        for prerequisite_id in graph.get(command_id, ()):
            visit(prerequisite_id)
        visiting.remove(command_id)
        visited.add(command_id)

    for command_id in sorted(graph):
        visit(command_id)

    expected_bindings = tuple(sorted(plan.scenario_bindings))
    if plan.scenario_bindings != expected_bindings:
        issues.append(ValidationIssue("binding-order", "$.scenario_bindings", "bindings must be sorted"))
    binding_scenario_ids = tuple(item.scenario_id for item in plan.scenario_bindings)
    if len(binding_scenario_ids) != len(set(binding_scenario_ids)):
        issues.append(
            ValidationIssue(
                "duplicate-scenario-binding",
                "$.scenario_bindings",
                "each scenario must have exactly one command binding",
            )
        )
    bound_scenarios: set[str] = set()
    for binding in plan.scenario_bindings:
        bound_scenarios.add(binding.scenario_id)
        if binding.scenario_id not in scenario_ids:
            issues.append(ValidationIssue("unknown-scenario", "$.scenario_bindings", binding.scenario_id))
        if not binding.command_ids:
            issues.append(ValidationIssue("unbound-scenario", "$.scenario_bindings", binding.scenario_id))
        if binding.command_ids != tuple(sorted(set(binding.command_ids))):
            issues.append(ValidationIssue("binding-command-order", "$.scenario_bindings", binding.scenario_id))
        for command_id in set(binding.command_ids) - known_commands:
            issues.append(ValidationIssue("unknown-command", "$.scenario_bindings", command_id))
        scenario = scenarios_by_id.get(binding.scenario_id)
        if scenario is not None:
            expected_commands = tuple(
                sorted(
                    command.command_id
                    for command in plan.commands
                    if set(command.command_groups) & set(scenario.command_groups)
                )
            )
            if binding.command_ids != expected_commands:
                issues.append(
                    ValidationIssue(
                        "scenario-command-binding",
                        "$.scenario_bindings",
                        f"binding is not exact for scenario: {binding.scenario_id}",
                    )
                )
            covered_layers = {
                commands_by_id[command_id].evidence_layer
                for command_id in binding.command_ids
                if command_id in commands_by_id
            }
            missing_layers = sorted(
                set(scenario.evidence_layers) - covered_layers,
                key=lambda item: item.value,
            )
            for layer in missing_layers:
                issues.append(
                    ValidationIssue(
                        "uncovered-evidence-layer",
                        "$.scenario_bindings",
                        f"{binding.scenario_id} lacks command coverage for {layer.value}",
                    )
                )
    for scenario_id in sorted(scenario_ids - bound_scenarios):
        issues.append(ValidationIssue("unbound-scenario", "$.scenario_bindings", scenario_id))

    expected_executor_layers = tuple(
        sorted(
            {
                item.evidence_layer
                for item in plan.commands
                if item.execution_mode is CommandExecutionMode.EXECUTOR_REQUIRED
            },
            key=lambda item: item.value,
        )
    )
    if plan.executor_required_layers != expected_executor_layers:
        issues.append(
            ValidationIssue(
                "executor-layer-summary",
                "$.executor_required_layers",
                "executor-required layer summary is not exact",
            )
        )
    return tuple(sorted(set(issues)))


def compile_command_plan(
    candidate: CandidateIdentity,
    scenario_catalog: ScenarioCatalog,
    *,
    repository_root: Path,
    inputs: Mapping[str, str],
    templates: Iterable[CommandTemplate] | None = None,
    profile: CampaignProfile = CampaignProfile.EXISTING,
) -> CommandPlan:
    repository_root = repository_root.resolve(strict=True)
    candidate_issues = validate_candidate_identity(candidate_to_mapping(candidate))
    if candidate_issues:
        raise CommandCompilationError(
            "invalid candidate input: "
            + "; ".join(f"{item.code}: {item.message}" for item in candidate_issues)
        )
    selected_templates = tuple(command_templates(profile=profile) if templates is None else templates)
    selected_templates = tuple(sorted(selected_templates, key=lambda item: item.command_id))
    if len({item.command_id for item in selected_templates}) != len(selected_templates):
        raise CommandCompilationError("command template IDs must be unique")
    template_map = {item.command_id: item for item in selected_templates}
    resolved_inputs = _validate_input_mapping(inputs, selected_templates, candidate, profile=profile)
    try:
        input_repository_root = Path(resolved_inputs["repository_root"]).resolve(strict=True)
    except OSError as error:
        raise CommandCompilationError(f"repository_root command input is unavailable: {error}") from error
    if input_repository_root != repository_root:
        raise CommandCompilationError(
            "repository_root command input must equal the audited repository root"
        )

    if scenario_catalog.candidate_identity_sha256 != candidate_identity_sha256(candidate):
        raise CommandCompilationError("scenario catalog and command plan candidate differ")
    scenario_issues = validate_scenario_catalog(scenario_catalog)
    if scenario_issues:
        raise CommandCompilationError(
            "invalid scenario catalog: "
            + "; ".join(f"{item.code}: {item.message}" for item in scenario_issues)
        )
    if scenario_catalog.required_scenario_ids != REQUIRED_SCENARIO_IDS:
        raise CommandCompilationError(
            "required-scenario-catalog: scenario catalog does not carry the exact commissioned IDs"
        )
    if scenario_catalog.pairwise_factors != PAIRWISE_FACTORS:
        raise CommandCompilationError(
            "pairwise-factor-catalog: scenario catalog does not carry the exact factor model"
        )
    _, expected_pairwise_scenarios, expected_pairwise_coverage = pairwise_scenarios()
    observed_pairwise_scenarios = tuple(
        item
        for item in scenario_catalog.scenarios
        if item.origin is ScenarioOrigin.PAIRWISE
    )
    if (
        observed_pairwise_scenarios != expected_pairwise_scenarios
        or scenario_catalog.pairwise_coverage != expected_pairwise_coverage
    ):
        raise CommandCompilationError(
            "pairwise-coverage-catalog: scenario catalog does not carry the exact deterministic closure"
        )
    shape_drift = required_scenario_shape_drift(scenario_catalog.scenarios)
    if shape_drift:
        raise CommandCompilationError(
            "required-scenario-shape: required scenarios differ from the frozen catalog: "
            + ", ".join(shape_drift)
        )

    group_to_scenarios: dict[str, set[str]] = {}
    for scenario in scenario_catalog.scenarios:
        for group in scenario.command_groups:
            group_to_scenarios.setdefault(group, set()).add(scenario.scenario_id)

    records: list[CommandRecord] = []
    for template in selected_templates:
        scenario_ids = tuple(
            sorted(
                set().union(
                    *(group_to_scenarios.get(group, set()) for group in template.command_groups)
                )
            )
        )
        record = CommandRecord(
            schema_version=COMMAND_SCHEMA_VERSION,
            command_id=template.command_id,
            candidate_identity_sha256=candidate_identity_sha256(candidate),
            scenario_ids=scenario_ids,
            command_groups=template.command_groups,
            argv=_resolve_argv(template, resolved_inputs),
            working_directory=_resolve(template.working_directory, resolved_inputs),
            environment=tuple(
                sorted((name, _resolve(value, resolved_inputs)) for name, value in template.environment)
            ),
            host=template.host,
            evidence_layer=template.evidence_layer,
            prerequisite_ids=template.prerequisite_ids,
            expected_exits=template.expected_exits,
            timeout_seconds=template.timeout_seconds,
            generated_artifacts=tuple(sorted(
                _resolve(value, resolved_inputs, allow_embedded=True)
                for value in template.generated_artifacts
            )),
            generated_logs=tuple(sorted(
                _resolve(value, resolved_inputs, allow_embedded=True)
                for value in template.generated_logs
            )),
            receipt_fields=template.receipt_fields,
            mutation_state=template.mutation_state,
            cleanup_rollback=template.cleanup_rollback,
            stop_on_failure=template.stop_on_failure,
            execution_mode=template.execution_mode,
            unavailability_reason=template.unavailability_reason,
            runtime_argument_slots=runtime_slots_for_template(template),
        )
        records.append(record)

    command_ids_by_group: dict[str, set[str]] = {}
    for record in records:
        for group in record.command_groups:
            command_ids_by_group.setdefault(group, set()).add(record.command_id)
    bindings = tuple(
        sorted(
            ScenarioCommandBinding(
                scenario.scenario_id,
                tuple(
                    sorted(
                        set().union(
                            *(command_ids_by_group.get(group, set()) for group in scenario.command_groups)
                        )
                    )
                ),
            )
            for scenario in scenario_catalog.scenarios
        )
    )
    plan = CommandPlan(
        schema_version=COMMAND_PLAN_SCHEMA_VERSION,
        candidate_identity_sha256=candidate_identity_sha256(candidate),
        scenario_catalog_sha256=scenario_catalog_sha256(scenario_catalog),
        command_inputs=tuple(sorted(inputs.items())),
        commands=tuple(sorted(records, key=lambda item: item.command_id)),
        scenario_bindings=bindings,
        executor_required_layers=tuple(
            sorted(
                {
                    item.evidence_layer
                    for item in records
                    if item.execution_mode is CommandExecutionMode.EXECUTOR_REQUIRED
                },
                key=lambda item: item.value,
            )
        ),
    )
    issues = validate_command_plan(
        plan,
        candidate=candidate,
        scenario_catalog=scenario_catalog,
        repository_root=repository_root,
        templates=template_map,
        profile=profile,
    )
    if issues:
        raise CommandCompilationError("; ".join(f"{item.code}: {item.message}" for item in issues))
    return plan
