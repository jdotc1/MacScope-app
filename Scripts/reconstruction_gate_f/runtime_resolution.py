"""Derive runtime argv from admitted predecessor DTOs, never caller hashes.

The caller must first recompile/admit the static record and physically validate
the predecessor receipts. Structural DTO validation is not execution evidence.
"""
from __future__ import annotations

from dataclasses import dataclass, replace

from .canonical_json import canonical_sha256
from .command_catalog import CampaignProfile
from .command_compiler import (
    COMMAND_SCHEMA_VERSION, EXTERNAL_PREREQUISITE_IDS, RUNTIME_ARGUMENT_KIND,
    CommandCompilationError, CommandRecord, command_templates,
    runtime_slots_for_template, validate_runtime_slots,
)
from .schema import SHA256_RE, STABLE_ID_RE


class RuntimeResolutionError(ValueError):
    pass


@dataclass(frozen=True)
class ResolvedRuntimeArgument:
    argv_index: int
    kind: str
    value: str


@dataclass(frozen=True)
class RuntimeResolution:
    schema_version: int
    bindings: tuple[ResolvedRuntimeArgument, ...]
    resolved_command_record_sha256: str


@dataclass(frozen=True)
class ResolvedCommand:
    record: CommandRecord
    static_record_sha256: str
    runtime_resolution: RuntimeResolution


def resolve_command_record(static_record: CommandRecord, *, prerequisite_receipts: tuple,
                           qualification_run, profile: CampaignProfile = CampaignProfile.EXISTING) -> ResolvedCommand:
    # Deferred import avoids a module cycle when receipt consumers import this
    # resolver. These are the existing authoritative mapping DTOs, not substitutes.
    from .receipt_validator import CommandPrerequisiteExpectation, QualificationRunAuthority

    def require(condition: bool, message: str) -> None:
        if not condition:
            raise RuntimeResolutionError(message)

    def matches(pattern, value) -> bool:
        return type(value) is str and pattern.fullmatch(value) is not None

    require(type(static_record) is CommandRecord and type(static_record.schema_version) is int
            and static_record.schema_version == COMMAND_SCHEMA_VERSION, "static command schema differs")
    require(type(static_record.argv) is tuple and all(type(value) is str for value in static_record.argv),
            "static argv shape differs")
    try:
        validate_runtime_slots(static_record)
        template = next((item for item in command_templates(profile=profile) if item.command_id == static_record.command_id), None)
        require(template is not None and static_record.runtime_argument_slots == runtime_slots_for_template(template),
                "runtime slots differ from frozen command")
    except CommandCompilationError as error:
        raise RuntimeResolutionError(str(error)) from error
    require(type(qualification_run) is QualificationRunAuthority
            and matches(STABLE_ID_RE, qualification_run.run_id)
            and matches(SHA256_RE, qualification_run.nonce), "invalid qualification run")
    require(type(prerequisite_receipts) is tuple, "prerequisite receipts must be an ordered tuple")
    require(type(static_record.prerequisite_ids) is tuple
            and all(matches(STABLE_ID_RE, value) for value in static_record.prerequisite_ids)
            and static_record.prerequisite_ids == tuple(sorted(set(static_record.prerequisite_ids))),
            "invalid static prerequisite closure")
    require(static_record.prerequisite_ids == template.prerequisite_ids,
            "static prerequisite closure differs from frozen command")
    expected_ids = tuple(value for value in static_record.prerequisite_ids if value not in EXTERNAL_PREREQUISITE_IDS)
    require(len(prerequisite_receipts) == len(expected_ids), "prerequisite closure differs")
    ids, receipt_ids, mappings = [], [], []
    for item in prerequisite_receipts:
        require(type(item) is CommandPrerequisiteExpectation, "invalid predecessor DTO")
        require(matches(STABLE_ID_RE, item.command_id) and matches(STABLE_ID_RE, item.receipt_id)
                and matches(SHA256_RE, item.canonical_sha256), "invalid predecessor identity")
        require(item.qualification_run_id == qualification_run.run_id
                and item.qualification_run_nonce == qualification_run.nonce, "foreign predecessor run")
        ids.append(item.command_id)
        receipt_ids.append(item.receipt_id)
        mappings.append({"command_id": item.command_id, "receipt_id": item.receipt_id,
                         "canonical_sha256": item.canonical_sha256,
                         "qualification_run_id": item.qualification_run_id,
                         "qualification_run_nonce": item.qualification_run_nonce})
    require(tuple(ids) == expected_ids and len(receipt_ids) == len(set(receipt_ids)),
            "predecessors are missing, duplicated, substituted or reordered")
    digest = canonical_sha256(mappings)
    argv = list(static_record.argv)
    bindings = []
    for slot in static_record.runtime_argument_slots:
        argv[slot.argv_index] = digest
        bindings.append(ResolvedRuntimeArgument(slot.argv_index, RUNTIME_ARGUMENT_KIND, digest))
    resolved = replace(static_record, argv=tuple(argv))
    return ResolvedCommand(resolved, canonical_sha256(static_record),
                           RuntimeResolution(1, tuple(bindings), canonical_sha256(resolved)))
