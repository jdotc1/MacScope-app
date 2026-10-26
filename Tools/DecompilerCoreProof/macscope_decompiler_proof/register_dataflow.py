"""AArch64 GPR alias SSA and Darwin call-effect derivation for DCP-03.

The raw SLEIGH DTO intentionally preserves exact storage tuples.  This module
adds a separate, dependency-free semantic overlay for the AArch64 general-
purpose register bank:

* ``xN`` and ``wN`` are views of one canonical 64-bit ``xN`` family.
* ``sp`` and ``wsp`` are views of one canonical 64-bit ``sp`` family.
* a 32-bit view write zero-extends into the 64-bit parent.
* CALL/CALLIND conservatively read the base unknown-prototype call state and
  introduce post-call definitions for x0-x18 and x30.
* base Darwin AAPCS64 volatile GPR, SIMD-slice, and NZCV effects are enumerated
  without claiming SIMD, condition-flag, SVE, SME, or system-register SSA.

This is MacScope-owned analysis over raw p-code.  It does not claim Ghidra
Decompiler heritage or complete AArch64 register SSA.
"""

from __future__ import annotations

import copy
import re
from collections.abc import Mapping, Sequence
from typing import Any

from .canonical import parse_address
from .dataflow import DataflowDerivationError

_VALUE_ID = re.compile(r"^v([0-9]{6})$")
_OPERATION_ID = re.compile(r"^op([0-9]{6})$")
_EDGE_ID = re.compile(r"^edge([0-9]{6})$")
_GPR_VIEW = re.compile(r"^([xw])([0-9]|[12][0-9]|30)$")
_CALL_OPS = frozenset({"CALL", "CALLIND"})

GPR_CANONICAL_ORDER: tuple[str, ...] = tuple(f"x{index}" for index in range(31)) + ("sp",)
_GPR_ORDER = {name: index for index, name in enumerate(GPR_CANONICAL_ORDER)}

# Unknown-prototype calls conservatively consume the base PCS argument/result
# registers plus the link register and stack pointer that establish the call
# frame.  SIMD inputs are represented as slices without claiming SIMD SSA.
DARWIN_CALL_GPR_INPUTS: tuple[str, ...] = (
    *(f"x{index}" for index in range(9)),
    "x30",
    "sp",
)
DARWIN_CALL_SIMD_INPUTS: tuple[str, ...] = tuple(f"v{index}" for index in range(8))

# AAPCS64 preserves x19-x29 and SP.  x30/LR is not callee-saved, while Apple
# reserves x18 rather than exposing it as an application register.  Both x18
# and x30 therefore receive conservative post-call unknown versions.
DARWIN_CALL_GPR_CLOBBERS: tuple[str, ...] = (
    *(f"x{index}" for index in range(19)),
    "x30",
)

REGISTER_MODEL: dict[str, object] = {
    "architecture": "AArch64",
    "platform": "Apple",
    "callingConvention": "darwin-arm64-aapcs64",
    "abiSpecification": "aapcs64-2025q4",
    "gprCanonicalWidthBits": 64,
    "gprAliasCoverage": "x0-x30-sp-and-32-bit-w-views",
    "simdSsaCoverage": "none",
    "conditionFlagSsaCoverage": "none",
    "callInputCoverage": "conservative-x0-x8-x30-sp-v0-v7",
    "callEffectCoverage": "base-gpr-simd-nzcv",
    "callExcludedState": "sve-sme-fpsr-fpcr-fpmr-system-registers",
}


class RegisterDataflowDerivationError(DataflowDerivationError):
    """A raw graph cannot form the closed DCP-03B1 register analysis."""


def _number(identifier: object, pattern: re.Pattern[str], label: str) -> int:
    if not isinstance(identifier, str):
        raise RegisterDataflowDerivationError(f"{label} identifier must be a string")
    match = pattern.fullmatch(identifier)
    if match is None:
        raise RegisterDataflowDerivationError(f"invalid {label} identifier")
    return int(match.group(1))


def _index(items: Sequence[Mapping[str, Any]], label: str) -> dict[str, Mapping[str, Any]]:
    output: dict[str, Mapping[str, Any]] = {}
    for item in items:
        identifier = item.get("id")
        if not isinstance(identifier, str) or not identifier:
            raise RegisterDataflowDerivationError(f"{label} is missing id")
        if identifier in output:
            raise RegisterDataflowDerivationError(f"duplicate {label} identifier")
        output[identifier] = item
    return output


def _validate_graph_links(
    *,
    block_by_id: Mapping[str, Mapping[str, Any]],
    edge_by_id: Mapping[str, Mapping[str, Any]],
    function_entry: int,
) -> None:
    """Reject incomplete, contradictory, or orphaned CFG relationships.

    The result supervisor validates the complete structured result before calling
    this module, but ``derive_register_analysis`` is also a public proof-layer
    entry point. It therefore must fail closed when used independently rather
    than silently dropping edges omitted from a block's adjacency arrays.
    """

    if type(function_entry) is not int or function_entry < 0:
        raise RegisterDataflowDerivationError(
            "function entry must be a non-negative integer address"
        )

    entry_blocks: list[str] = []
    for block_id, block in block_by_id.items():
        try:
            start = parse_address(block.get("startAddress"), "block.startAddress")
        except ValueError as error:
            raise RegisterDataflowDerivationError(str(error)) from error
        if start == function_entry:
            entry_blocks.append(block_id)
    if len(entry_blocks) != 1:
        raise RegisterDataflowDerivationError(
            "function entry must identify exactly one basic block"
        )

    expected_incoming: dict[str, list[str]] = {block_id: [] for block_id in block_by_id}
    expected_outgoing: dict[str, list[str]] = {block_id: [] for block_id in block_by_id}
    for edge_id, edge in sorted(
        edge_by_id.items(), key=lambda item: _number(item[0], _EDGE_ID, "edge")
    ):
        source = edge.get("sourceBlockId")
        target = edge.get("targetBlockId")
        if not isinstance(source, str) or source not in block_by_id:
            raise RegisterDataflowDerivationError(
                "edge references an unknown source block"
            )
        if target is not None and (not isinstance(target, str) or target not in block_by_id):
            raise RegisterDataflowDerivationError(
                "edge references an unknown target block"
            )
        expected_outgoing[source].append(edge_id)
        if target is not None:
            expected_incoming[target].append(edge_id)

    for block_id, block in block_by_id.items():
        predecessors = block.get("predecessorEdgeIds")
        successors = block.get("successorEdgeIds")
        if not isinstance(predecessors, list) or not isinstance(successors, list):
            raise RegisterDataflowDerivationError(
                "basic block adjacency must be expressed as arrays"
            )
        if any(not isinstance(item, str) for item in predecessors + successors):
            raise RegisterDataflowDerivationError(
                "basic block adjacency identifiers must be strings"
            )
        if len(predecessors) != len(set(predecessors)) or len(successors) != len(
            set(successors)
        ):
            raise RegisterDataflowDerivationError(
                "basic block adjacency must not contain duplicate edges"
            )
        actual_incoming = sorted(
            predecessors, key=lambda item: _number(item, _EDGE_ID, "edge")
        )
        actual_outgoing = sorted(
            successors, key=lambda item: _number(item, _EDGE_ID, "edge")
        )
        if actual_incoming != expected_incoming[block_id]:
            raise RegisterDataflowDerivationError(
                "basic block predecessor edges are incomplete or inconsistent"
            )
        if actual_outgoing != expected_outgoing[block_id]:
            raise RegisterDataflowDerivationError(
                "basic block successor edges are incomplete or inconsistent"
            )


def _source_range(operation: Mapping[str, Any]) -> dict[str, object]:
    value = operation.get("sourceRange")
    if not isinstance(value, Mapping) or set(value) != {
        "imageId",
        "startAddress",
        "endAddressExclusive",
    }:
        raise RegisterDataflowDerivationError("p-code operation is missing a closed sourceRange")
    return {
        "imageId": copy.deepcopy(value["imageId"]),
        "startAddress": copy.deepcopy(value["startAddress"]),
        "endAddressExclusive": copy.deepcopy(value["endAddressExclusive"]),
    }


def _view_for_value(value: Mapping[str, Any]) -> dict[str, object] | None:
    name = value.get("registerName")
    if not isinstance(name, str):
        return None
    lowered = name.lower()
    if lowered in {"sp", "wsp"}:
        if name != lowered:
            raise RegisterDataflowDerivationError("recognized AArch64 GPR view names must be canonical lowercase")
        canonical = "sp"
        bit_width = 64 if name == "sp" else 32
        expected_offset = 0x8
    else:
        match = _GPR_VIEW.fullmatch(lowered)
        if match is None:
            return None
        if name != lowered:
            raise RegisterDataflowDerivationError("recognized AArch64 GPR view names must be canonical lowercase")
        prefix, raw_index = match.groups()
        index = int(raw_index)
        canonical = f"x{index}"
        bit_width = 64 if prefix == "x" else 32
        expected_offset = 0x4000 + index * 8

    if value.get("storageClass") != "register" or value.get("space") != "register":
        raise RegisterDataflowDerivationError("recognized AArch64 GPR view has non-register storage metadata")
    if value.get("size") != bit_width // 8:
        raise RegisterDataflowDerivationError("recognized AArch64 GPR view has an invalid width")
    try:
        offset = parse_address(value.get("offset"), "value.offset")
    except ValueError as error:
        raise RegisterDataflowDerivationError(str(error)) from error
    if offset != expected_offset:
        raise RegisterDataflowDerivationError("recognized AArch64 GPR view has an invalid SLEIGH offset")
    if value.get("scopeInstructionAddress") is not None:
        raise RegisterDataflowDerivationError("architectural GPR views must not be instruction-scoped")

    return {
        "storageValueId": value["id"],
        "viewName": name,
        "canonicalRegister": canonical,
        "canonicalBitWidth": 64,
        "bitOffset": 0,
        "bitWidth": bit_width,
        "readTransform": "identity" if bit_width == 64 else "lowBits",
        "writeTransform": "replace" if bit_width == 64 else "zeroExtend",
    }


def _incoming_paths(
    block: Mapping[str, Any],
    *,
    function_entry: int,
    edge_by_id: Mapping[str, Mapping[str, Any]],
) -> list[dict[str, object]]:
    block_id = block.get("id")
    if not isinstance(block_id, str):
        raise RegisterDataflowDerivationError("basic block is missing id")
    paths: list[dict[str, object]] = []
    try:
        is_entry = parse_address(block.get("startAddress"), "block.startAddress") == function_entry
    except ValueError as error:
        raise RegisterDataflowDerivationError(str(error)) from error
    if is_entry:
        paths.append({"sourceKind": "functionEntry", "sourceBlockId": None, "edgeId": None})
    predecessors = block.get("predecessorEdgeIds")
    if not isinstance(predecessors, list):
        raise RegisterDataflowDerivationError("basic block predecessorEdgeIds must be an array")
    for edge_id in sorted(predecessors, key=lambda item: _number(item, _EDGE_ID, "edge")):
        edge = edge_by_id.get(edge_id)
        if edge is None or edge.get("targetBlockId") != block_id:
            raise RegisterDataflowDerivationError("basic block predecessor edge is inconsistent")
        source = edge.get("sourceBlockId")
        if not isinstance(source, str):
            raise RegisterDataflowDerivationError("internal predecessor edge has no source block")
        paths.append({"sourceKind": "block", "sourceBlockId": source, "edgeId": edge_id})
    return paths


def _successors(
    block: Mapping[str, Any], edge_by_id: Mapping[str, Mapping[str, Any]]
) -> tuple[str, ...]:
    block_id = block.get("id")
    edge_ids = block.get("successorEdgeIds")
    if not isinstance(edge_ids, list):
        raise RegisterDataflowDerivationError("basic block successorEdgeIds must be an array")
    output: list[str] = []
    for edge_id in sorted(edge_ids, key=lambda item: _number(item, _EDGE_ID, "edge")):
        edge = edge_by_id.get(edge_id)
        if edge is None or edge.get("sourceBlockId") != block_id:
            raise RegisterDataflowDerivationError("basic block successor edge is inconsistent")
        target = edge.get("targetBlockId")
        if target is not None:
            if not isinstance(target, str):
                raise RegisterDataflowDerivationError("edge targetBlockId must be a string or null")
            output.append(target)
    return tuple(output)


def _liveness(
    block_ids: Sequence[str],
    successors: Mapping[str, tuple[str, ...]],
    uses_before_definition: Mapping[str, set[str]],
    definitions: Mapping[str, set[str]],
) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    live_in = {block_id: set(uses_before_definition[block_id]) for block_id in block_ids}
    live_out = {block_id: set() for block_id in block_ids}
    while True:
        changed = False
        for block_id in reversed(block_ids):
            new_out: set[str] = set()
            for successor in successors[block_id]:
                new_out.update(live_in[successor])
            new_in = uses_before_definition[block_id] | (new_out - definitions[block_id])
            if new_in != live_in[block_id] or new_out != live_out[block_id]:
                live_in[block_id] = new_in
                live_out[block_id] = new_out
                changed = True
        if not changed:
            return live_in, live_out


def _call_input_slices(
    *,
    input_version_by_register: Mapping[str, str],
) -> list[dict[str, object]]:
    slices: list[dict[str, object]] = []
    for register in DARWIN_CALL_GPR_INPUTS:
        if register.startswith("x") and register not in {"x8", "x30"}:
            reason = "possibleParameter"
        elif register == "x8":
            reason = "possibleIndirectResultLocation"
        elif register == "x30":
            reason = "linkRegister"
        else:
            reason = "stackPointer"
        slices.append(
            {
                "registerName": register,
                "registerClass": "generalPurpose",
                "bitOffset": 0,
                "bitWidth": 64,
                "reason": reason,
                "access": "conservativeMayRead",
                "inputRegisterVersionId": input_version_by_register[register],
            }
        )
    for register in DARWIN_CALL_SIMD_INPUTS:
        slices.append(
            {
                "registerName": register,
                "registerClass": "simdFloatingPoint",
                "bitOffset": 0,
                "bitWidth": 128,
                "reason": "possibleParameter",
                "access": "conservativeMayRead",
                "inputRegisterVersionId": None,
            }
        )
    return slices


def _call_clobber_slices(
    *,
    operation_id: str,
    version_id_for_key: Mapping[tuple[str, ...], str],
) -> list[dict[str, object]]:
    slices: list[dict[str, object]] = []
    for register in DARWIN_CALL_GPR_CLOBBERS:
        if register == "x18":
            reason = "platformReserved"
        elif register == "x30":
            reason = "linkRegisterCallerSaved"
        else:
            reason = "callerSaved"
        slices.append(
            {
                "registerName": register,
                "registerClass": "generalPurpose",
                "bitOffset": 0,
                "bitWidth": 64,
                "reason": reason,
                "outputRegisterVersionId": version_id_for_key[("callClobber", operation_id, register)],
            }
        )
    for index in range(32):
        if index <= 7 or index >= 16:
            bit_offset = 0
            bit_width = 128
            reason = "callerSaved"
        else:
            bit_offset = 64
            bit_width = 64
            reason = "upperHalfCallerSaved"
        slices.append(
            {
                "registerName": f"v{index}",
                "registerClass": "simdFloatingPoint",
                "bitOffset": bit_offset,
                "bitWidth": bit_width,
                "reason": reason,
                "outputRegisterVersionId": None,
            }
        )
    for flag in ("N", "Z", "C", "V"):
        slices.append(
            {
                "registerName": flag,
                "registerClass": "conditionFlag",
                "bitOffset": 0,
                "bitWidth": 1,
                "reason": "undefinedAcrossCall",
                "outputRegisterVersionId": None,
            }
        )
    return slices


def derive_register_analysis(
    *,
    values: Sequence[Mapping[str, Any]],
    pcode_ops: Sequence[Mapping[str, Any]],
    basic_blocks: Sequence[Mapping[str, Any]],
    edges: Sequence[Mapping[str, Any]],
    function_entry: int,
) -> dict[str, object]:
    """Derive deterministic partial register SSA and ABI call effects."""

    if not basic_blocks:
        raise RegisterDataflowDerivationError("at least one basic block is required")
    value_by_id = _index(values, "value")
    operation_by_id = _index(pcode_ops, "p-code operation")
    block_by_id = _index(basic_blocks, "basic block")
    edge_by_id = _index(edges, "edge")
    _validate_graph_links(
        block_by_id=block_by_id,
        edge_by_id=edge_by_id,
        function_entry=function_entry,
    )

    value_ids = sorted(value_by_id, key=lambda item: _number(item, _VALUE_ID, "value"))
    operation_ids = sorted(
        operation_by_id, key=lambda item: _number(item, _OPERATION_ID, "operation")
    )
    block_ids = sorted(
        block_by_id,
        key=lambda item: (
            parse_address(block_by_id[item].get("startAddress"), "block.startAddress"),
            item,
        ),
    )

    view_drafts: list[dict[str, object]] = []
    seen_view_names: set[str] = set()
    for value_id in value_ids:
        draft = _view_for_value(value_by_id[value_id])
        if draft is None:
            continue
        view_name = str(draft["viewName"])
        if view_name in seen_view_names:
            raise RegisterDataflowDerivationError("AArch64 GPR views must be unique")
        seen_view_names.add(view_name)
        view_drafts.append(draft)
    view_drafts.sort(
        key=lambda item: (
            _GPR_ORDER[str(item["canonicalRegister"])],
            -int(item["bitWidth"]),
            str(item["viewName"]),
            _number(item["storageValueId"], _VALUE_ID, "value"),
        )
    )
    views: list[dict[str, object]] = [
        {"id": f"rview{index:06d}", **draft} for index, draft in enumerate(view_drafts)
    ]
    view_by_storage = {str(item["storageValueId"]): item for item in views}

    instruction_to_block: dict[int, str] = {}
    incoming_paths: dict[str, list[dict[str, object]]] = {}
    successors: dict[str, tuple[str, ...]] = {}
    for block_id in block_ids:
        block = block_by_id[block_id]
        indices = block.get("instructionIndices")
        if not isinstance(indices, list) or not indices:
            raise RegisterDataflowDerivationError("basic block instructionIndices must be non-empty")
        for index in indices:
            if type(index) is not int or index < 0 or index in instruction_to_block:
                raise RegisterDataflowDerivationError("instruction ownership is invalid")
            instruction_to_block[index] = block_id
        incoming_paths[block_id] = _incoming_paths(
            block, function_entry=function_entry, edge_by_id=edge_by_id
        )
        successors[block_id] = _successors(block, edge_by_id)

    operations_by_block: dict[str, list[Mapping[str, Any]]] = {block_id: [] for block_id in block_ids}
    for operation_id in operation_ids:
        operation = operation_by_id[operation_id]
        instruction_index = operation.get("instructionIndex")
        if type(instruction_index) is not int or instruction_index not in instruction_to_block:
            raise RegisterDataflowDerivationError("p-code operation references an unknown instruction")
        inputs = operation.get("inputs")
        if not isinstance(inputs, list):
            raise RegisterDataflowDerivationError("p-code operation inputs must be an array")
        if any(value_id not in value_by_id for value_id in inputs):
            raise RegisterDataflowDerivationError("p-code input references an unknown value")
        output = operation.get("output")
        if output is not None and output not in value_by_id:
            raise RegisterDataflowDerivationError("p-code output references an unknown value")
        operations_by_block[instruction_to_block[instruction_index]].append(operation)
    for block_id in block_ids:
        operations_by_block[block_id].sort(
            key=lambda operation: (
                operation["instructionIndex"],
                operation["sequence"],
                _number(operation["id"], _OPERATION_ID, "operation"),
            )
        )

    uses_before_definition: dict[str, set[str]] = {block_id: set() for block_id in block_ids}
    definitions: dict[str, set[str]] = {block_id: set() for block_id in block_ids}
    canonicals: set[str] = {str(item["canonicalRegister"]) for item in views}
    for block_id in block_ids:
        defined: set[str] = set()
        for operation in operations_by_block[block_id]:
            inputs = operation.get("inputs")
            if not isinstance(inputs, list):
                raise RegisterDataflowDerivationError(
                    "p-code operation inputs must remain an array during liveness analysis"
                )
            for value_id in inputs:
                view = view_by_storage.get(value_id)
                if view is None:
                    continue
                canonical = str(view["canonicalRegister"])
                if canonical not in defined:
                    uses_before_definition[block_id].add(canonical)
            if operation.get("opcode") in _CALL_OPS:
                for canonical in DARWIN_CALL_GPR_INPUTS:
                    if canonical not in defined:
                        uses_before_definition[block_id].add(canonical)
                    canonicals.add(canonical)
            output = operation.get("output")
            view = view_by_storage.get(output) if isinstance(output, str) else None
            if view is not None:
                canonical = str(view["canonicalRegister"])
                definitions[block_id].add(canonical)
                defined.add(canonical)
            if operation.get("opcode") in _CALL_OPS:
                for canonical in DARWIN_CALL_GPR_CLOBBERS:
                    definitions[block_id].add(canonical)
                    defined.add(canonical)
                    canonicals.add(canonical)

    canonical_registers = sorted(canonicals, key=lambda item: _GPR_ORDER[item])
    live_in, live_out = _liveness(
        block_ids, successors, uses_before_definition, definitions
    )
    phi_candidates = [
        (block_id, canonical)
        for block_id in block_ids
        for canonical in canonical_registers
        if canonical in live_in[block_id] and len(incoming_paths[block_id]) >= 2
    ]
    phi_candidate_set = set(phi_candidates)
    phi_id_for_key = {
        key: f"rphi{index:06d}" for index, key in enumerate(phi_candidates)
    }

    version_keys: list[tuple[str, ...]] = [
        ("entry", canonical) for canonical in canonical_registers
    ]
    version_keys.extend(("phi", block_id, canonical) for block_id, canonical in phi_candidates)
    for operation_id in operation_ids:
        operation = operation_by_id[operation_id]
        output = operation.get("output")
        view = view_by_storage.get(output) if isinstance(output, str) else None
        if view is not None:
            version_keys.append(
                ("pcodeWrite", operation_id, str(view["canonicalRegister"]))
            )
        if operation.get("opcode") in _CALL_OPS:
            version_keys.extend(
                ("callClobber", operation_id, canonical)
                for canonical in DARWIN_CALL_GPR_CLOBBERS
            )
    version_id_for_key = {
        key: f"reg{index:06d}" for index, key in enumerate(version_keys)
    }

    view_id_by_storage = {
        str(item["storageValueId"]): str(item["id"]) for item in views
    }
    versions: list[dict[str, object]] = []
    for key in version_keys:
        kind = key[0]
        if kind == "entry":
            _, canonical = key
            versions.append(
                {
                    "id": version_id_for_key[key],
                    "canonicalRegister": canonical,
                    "bitWidth": 64,
                    "kind": "functionEntry",
                    "definingPcodeOpId": None,
                    "definingRegisterPhiId": None,
                    "writeViewId": None,
                    "writeTransform": None,
                    "sourceRange": None,
                }
            )
        elif kind == "phi":
            _, block_id, canonical = key
            versions.append(
                {
                    "id": version_id_for_key[key],
                    "canonicalRegister": canonical,
                    "bitWidth": 64,
                    "kind": "phi",
                    "definingPcodeOpId": None,
                    "definingRegisterPhiId": phi_id_for_key[(block_id, canonical)],
                    "writeViewId": None,
                    "writeTransform": None,
                    "sourceRange": None,
                }
            )
        elif kind == "pcodeWrite":
            _, operation_id, canonical = key
            output = operation_by_id[operation_id].get("output")
            if not isinstance(output, str):
                raise RegisterDataflowDerivationError(
                    "p-code write definition is missing its storage output"
                )
            view = view_by_storage[output]
            versions.append(
                {
                    "id": version_id_for_key[key],
                    "canonicalRegister": canonical,
                    "bitWidth": 64,
                    "kind": "pcodeWrite",
                    "definingPcodeOpId": operation_id,
                    "definingRegisterPhiId": None,
                    "writeViewId": view_id_by_storage[output],
                    "writeTransform": view["writeTransform"],
                    "sourceRange": _source_range(operation_by_id[operation_id]),
                }
            )
        else:
            _, operation_id, canonical = key
            versions.append(
                {
                    "id": version_id_for_key[key],
                    "canonicalRegister": canonical,
                    "bitWidth": 64,
                    "kind": "callClobber",
                    "definingPcodeOpId": operation_id,
                    "definingRegisterPhiId": None,
                    "writeViewId": None,
                    "writeTransform": "unknown",
                    "sourceRange": _source_range(operation_by_id[operation_id]),
                }
            )

    def entry_version(canonical: str) -> str:
        return version_id_for_key[("entry", canonical)]

    def incoming_state(
        block_id: str, previous_out: Mapping[str, Mapping[str, str]]
    ) -> dict[str, str]:
        state: dict[str, str] = {}
        for canonical in live_in[block_id]:
            if (block_id, canonical) in phi_candidate_set:
                state[canonical] = version_id_for_key[("phi", block_id, canonical)]
                continue
            candidates: list[str] = []
            for path in incoming_paths[block_id]:
                if path["sourceKind"] == "functionEntry":
                    candidates.append(entry_version(canonical))
                else:
                    source = path["sourceBlockId"]
                    if not isinstance(source, str):
                        raise RegisterDataflowDerivationError(
                            "CFG predecessor path is missing its source block"
                        )
                    candidates.append(
                        previous_out.get(source, {}).get(canonical, entry_version(canonical))
                    )
            if not candidates:
                candidates.append(entry_version(canonical))
            state[canonical] = (
                candidates[0]
                if all(candidate == candidates[0] for candidate in candidates)
                else entry_version(canonical)
            )
        return state

    def transfer(
        block_id: str, previous_out: Mapping[str, Mapping[str, str]]
    ) -> dict[str, str]:
        state = incoming_state(block_id, previous_out)
        for operation in operations_by_block[block_id]:
            operation_id = str(operation["id"])
            output = operation.get("output")
            view = view_by_storage.get(output) if isinstance(output, str) else None
            if view is not None:
                canonical = str(view["canonicalRegister"])
                state[canonical] = version_id_for_key[("pcodeWrite", operation_id, canonical)]
            if operation.get("opcode") in _CALL_OPS:
                for canonical in DARWIN_CALL_GPR_CLOBBERS:
                    state[canonical] = version_id_for_key[("callClobber", operation_id, canonical)]
        return {
            canonical: state.get(canonical, entry_version(canonical))
            for canonical in live_out[block_id]
        }

    register_out: dict[str, dict[str, str]] = {block_id: {} for block_id in block_ids}
    for _ in range(max(4, len(block_ids) * 2 + 4)):
        next_out = {
            block_id: transfer(block_id, register_out) for block_id in block_ids
        }
        if next_out == register_out:
            register_out = next_out
            break
        register_out = next_out
    else:
        raise RegisterDataflowDerivationError("AArch64 GPR SSA did not reach a fixed point")

    bindings: list[dict[str, object]] = []
    call_input_versions: dict[str, dict[str, str]] = {}
    for block_id in block_ids:
        state = incoming_state(block_id, register_out)
        for operation in operations_by_block[block_id]:
            operation_id = str(operation["id"])
            reads: list[dict[str, object]] = []
            inputs = operation.get("inputs")
            if not isinstance(inputs, list):
                raise RegisterDataflowDerivationError(
                    "p-code operation inputs must remain an array during SSA binding"
                )
            for operand_index, value_id in enumerate(inputs):
                view = view_by_storage.get(value_id)
                if view is None:
                    continue
                canonical = str(view["canonicalRegister"])
                reads.append(
                    {
                        "operandIndex": operand_index,
                        "storageValueId": value_id,
                        "registerViewId": view["id"],
                        "canonicalRegister": canonical,
                        "inputRegisterVersionId": state.get(
                            canonical, entry_version(canonical)
                        ),
                        "readTransform": view["readTransform"],
                    }
                )
            if operation.get("opcode") in _CALL_OPS:
                call_input_versions[operation_id] = {
                    canonical: state.get(canonical, entry_version(canonical))
                    for canonical in DARWIN_CALL_GPR_INPUTS
                }
            output = operation.get("output")
            view = view_by_storage.get(output) if isinstance(output, str) else None
            write: dict[str, object] | None = None
            if view is not None:
                canonical = str(view["canonicalRegister"])
                output_version = version_id_for_key[
                    ("pcodeWrite", operation_id, canonical)
                ]
                write = {
                    "storageValueId": output,
                    "registerViewId": view["id"],
                    "canonicalRegister": canonical,
                    "outputRegisterVersionId": output_version,
                    "writeTransform": view["writeTransform"],
                }
                state[canonical] = output_version
            call_clobber_ids: list[str] = []
            if operation.get("opcode") in _CALL_OPS:
                for canonical in DARWIN_CALL_GPR_CLOBBERS:
                    version_id = version_id_for_key[
                        ("callClobber", operation_id, canonical)
                    ]
                    call_clobber_ids.append(version_id)
                    state[canonical] = version_id
            bindings.append(
                {
                    "id": f"rbind{len(bindings):06d}",
                    "pcodeOpId": operation_id,
                    "reads": reads,
                    "write": write,
                    "callClobberRegisterVersionIds": call_clobber_ids,
                }
            )

    phis: list[dict[str, object]] = []
    for block_id, canonical in phi_candidates:
        incoming: list[dict[str, object]] = []
        for path in incoming_paths[block_id]:
            if path["sourceKind"] == "functionEntry":
                version_id = entry_version(canonical)
            else:
                source = path["sourceBlockId"]
                if not isinstance(source, str):
                    raise RegisterDataflowDerivationError(
                        "register phi input is missing its source block"
                    )
                version_id = register_out[source].get(
                    canonical, entry_version(canonical)
                )
            incoming.append({**path, "registerVersionId": version_id})
        phis.append(
            {
                "id": phi_id_for_key[(block_id, canonical)],
                "blockId": block_id,
                "canonicalRegister": canonical,
                "outputRegisterVersionId": version_id_for_key[
                    ("phi", block_id, canonical)
                ],
                "incoming": incoming,
                "isTrivial": bool(incoming)
                and all(
                    item["registerVersionId"] == incoming[0]["registerVersionId"]
                    for item in incoming
                ),
            }
        )

    call_effects: list[dict[str, object]] = []
    for operation_id in operation_ids:
        operation = operation_by_id[operation_id]
        if operation.get("opcode") not in _CALL_OPS:
            continue
        call_effects.append(
            {
                "id": f"ce{len(call_effects):06d}",
                "pcodeOpId": operation_id,
                "callKind": "direct"
                if operation.get("directTargetAddress") is not None
                else "indirect",
                "callingConvention": "darwin-arm64-aapcs64",
                "coverage": "base-gpr-simd-nzcv",
                "inputs": _call_input_slices(
                    input_version_by_register=call_input_versions[operation_id],
                ),
                "clobbers": _call_clobber_slices(
                    operation_id=operation_id,
                    version_id_for_key=version_id_for_key,
                ),
                "sourceRange": _source_range(operation),
            }
        )

    return {
        "model": copy.deepcopy(REGISTER_MODEL),
        "views": views,
        "versions": versions,
        "bindings": bindings,
        "phis": phis,
        "callEffects": call_effects,
    }
