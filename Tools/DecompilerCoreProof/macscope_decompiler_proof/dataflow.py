"""Deterministic MacScope-owned data-flow derivation over raw SLEIGH p-code.

This module deliberately does not claim Ghidra decompiler heritage.  It builds
an exact-storage SSA view and a conservative single-partition MemorySSA view
from the closed DCP-03 raw p-code/CFG DTOs. Register overlap/alias semantics and
ABI call effects are derived by the separate DCP-03B1 register overlay; high-
level variables and types remain outside this module.

The implementation is dependency-free so protocol and invariant tests run on
hosts where the pinned native SLEIGH dependency is not materialized.
"""

from __future__ import annotations

import copy
import re
from collections.abc import Iterable, Mapping, Sequence
from typing import Any

from .canonical import parse_address
from .contract import ANALYSIS_SEMANTICS

_ID_PATTERNS = {
    "value": re.compile(r"^v([0-9]{6})$"),
    "operation": re.compile(r"^op([0-9]{6})$"),
    "edge": re.compile(r"^edge([0-9]{6})$"),
}
_MUTABLE_STORAGE_CLASSES = frozenset({"register", "temporary", "composite", "other"})
_MEMORY_READ_OPS = frozenset({"LOAD"})
_MEMORY_WRITE_OPS = frozenset({"STORE"})
_MEMORY_CALL_OPS = frozenset({"CALL", "CALLIND"})
_MEMORY_UNKNOWN_OPS = frozenset({"CALLOTHER"})
_MEMORY_EFFECT_OPS = _MEMORY_READ_OPS | _MEMORY_WRITE_OPS | _MEMORY_CALL_OPS | _MEMORY_UNKNOWN_OPS


class DataflowDerivationError(ValueError):
    """Raised when raw structured-lift DTOs cannot form a sound data-flow graph."""


def _numeric_identifier(value: object, kind: str) -> int:
    if not isinstance(value, str):
        raise DataflowDerivationError(f"{kind} identifier must be a string")
    match = _ID_PATTERNS[kind].fullmatch(value)
    if match is None:
        raise DataflowDerivationError(f"invalid {kind} identifier")
    return int(match.group(1))


def _unique_index(items: Sequence[Mapping[str, Any]], key: str, label: str) -> dict[str, Mapping[str, Any]]:
    result: dict[str, Mapping[str, Any]] = {}
    for item in items:
        identifier = item.get(key)
        if not isinstance(identifier, str) or not identifier:
            raise DataflowDerivationError(f"{label} is missing {key}")
        if identifier in result:
            raise DataflowDerivationError(f"duplicate {label} identifier")
        result[identifier] = item
    return result


def _validate_graph_links(
    *,
    block_by_id: Mapping[str, Mapping[str, Any]],
    edge_by_id: Mapping[str, Mapping[str, Any]],
    function_entry: int,
) -> None:
    """Reject incomplete or contradictory CFG adjacency before analysis.

    The result verifier also checks these relationships, but ``derive_dataflow``
    is a public proof-layer entry point and must fail closed when called on its
    own.  In particular, an orphan edge must never disappear merely because it
    was omitted from a block's predecessor/successor arrays.
    """

    entry_blocks = [
        block_id
        for block_id, block in block_by_id.items()
        if parse_address(block.get("startAddress"), "block.startAddress") == function_entry
    ]
    if len(entry_blocks) != 1:
        raise DataflowDerivationError("function entry must identify exactly one basic block")

    expected_incoming: dict[str, list[str]] = {block_id: [] for block_id in block_by_id}
    expected_outgoing: dict[str, list[str]] = {block_id: [] for block_id in block_by_id}
    for edge_id, edge in sorted(
        edge_by_id.items(), key=lambda item: _numeric_identifier(item[0], "edge")
    ):
        source = edge.get("sourceBlockId")
        target = edge.get("targetBlockId")
        if source not in block_by_id:
            raise DataflowDerivationError("edge references an unknown source block")
        if target is not None and target not in block_by_id:
            raise DataflowDerivationError("edge references an unknown target block")
        expected_outgoing[source].append(edge_id)
        if target is not None:
            expected_incoming[target].append(edge_id)

    for block_id, block in block_by_id.items():
        predecessors = block.get("predecessorEdgeIds")
        successors = block.get("successorEdgeIds")
        if not isinstance(predecessors, list) or not isinstance(successors, list):
            raise DataflowDerivationError("basic block adjacency must be expressed as arrays")
        if len(predecessors) != len(set(predecessors)) or len(successors) != len(set(successors)):
            raise DataflowDerivationError("basic block adjacency must not contain duplicate edges")
        if sorted(predecessors, key=lambda item: _numeric_identifier(item, "edge")) != expected_incoming[block_id]:
            raise DataflowDerivationError("basic block predecessor edges are incomplete or inconsistent")
        if sorted(successors, key=lambda item: _numeric_identifier(item, "edge")) != expected_outgoing[block_id]:
            raise DataflowDerivationError("basic block successor edges are incomplete or inconsistent")


def _validate_scoped_storage_uses(
    *,
    value_by_id: Mapping[str, Mapping[str, Any]],
    operation_by_id: Mapping[str, Mapping[str, Any]],
) -> None:
    """Ensure instruction-scoped SLEIGH temporaries never escape their scope."""

    for operation in operation_by_id.values():
        source_range = operation.get("sourceRange")
        if not isinstance(source_range, Mapping):
            raise DataflowDerivationError("p-code operation is missing sourceRange")
        try:
            instruction_address = parse_address(
                source_range.get("startAddress"), "pcodeOp.sourceRange.startAddress"
            )
        except ValueError as error:
            raise DataflowDerivationError(str(error)) from error
        referenced = list(operation.get("inputs", []))
        output = operation.get("output")
        if output is not None:
            referenced.append(output)
        for value_id in referenced:
            value = value_by_id[value_id]
            scope = value.get("scopeInstructionAddress")
            if scope is None:
                continue
            try:
                scoped_address = parse_address(scope, "value.scopeInstructionAddress")
            except ValueError as error:
                raise DataflowDerivationError(str(error)) from error
            if scoped_address != instruction_address:
                raise DataflowDerivationError(
                    "instruction-scoped storage is referenced outside its defining instruction"
                )


def _copy_source_range(operation: Mapping[str, Any]) -> dict[str, object]:
    source_range = operation.get("sourceRange")
    if not isinstance(source_range, Mapping):
        raise DataflowDerivationError("p-code operation is missing sourceRange")
    required = {"imageId", "startAddress", "endAddressExclusive"}
    if set(source_range) != required:
        raise DataflowDerivationError("p-code sourceRange has an invalid shape")
    return {key: copy.deepcopy(source_range[key]) for key in ("imageId", "startAddress", "endAddressExclusive")}


def _incoming_paths(
    block: Mapping[str, Any],
    *,
    function_entry: int,
    edge_by_id: Mapping[str, Mapping[str, Any]],
) -> list[dict[str, object]]:
    block_id = block["id"]
    paths: list[dict[str, object]] = []
    if parse_address(block["startAddress"], "block.startAddress") == function_entry:
        paths.append(
            {
                "sourceKind": "functionEntry",
                "sourceBlockId": None,
                "edgeId": None,
            }
        )
    predecessor_ids = block.get("predecessorEdgeIds")
    if not isinstance(predecessor_ids, list):
        raise DataflowDerivationError("basic block predecessorEdgeIds must be an array")
    for edge_id in sorted(predecessor_ids, key=lambda item: _numeric_identifier(item, "edge")):
        edge = edge_by_id.get(edge_id)
        if edge is None or edge.get("targetBlockId") != block_id:
            raise DataflowDerivationError("basic block predecessor edge is inconsistent")
        source_block_id = edge.get("sourceBlockId")
        if not isinstance(source_block_id, str):
            raise DataflowDerivationError("internal predecessor edge has no source block")
        paths.append(
            {
                "sourceKind": "block",
                "sourceBlockId": source_block_id,
                "edgeId": edge_id,
            }
        )
    return paths


def _successors(
    block: Mapping[str, Any], edge_by_id: Mapping[str, Mapping[str, Any]]
) -> tuple[str, ...]:
    successor_ids = block.get("successorEdgeIds")
    if not isinstance(successor_ids, list):
        raise DataflowDerivationError("basic block successorEdgeIds must be an array")
    output: list[str] = []
    for edge_id in sorted(successor_ids, key=lambda item: _numeric_identifier(item, "edge")):
        edge = edge_by_id.get(edge_id)
        if edge is None or edge.get("sourceBlockId") != block.get("id"):
            raise DataflowDerivationError("basic block successor edge is inconsistent")
        target = edge.get("targetBlockId")
        if target is not None:
            if not isinstance(target, str):
                raise DataflowDerivationError("edge targetBlockId must be a string or null")
            output.append(target)
    return tuple(output)


def _fixed_point_liveness(
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
            if new_out != live_out[block_id] or new_in != live_in[block_id]:
                live_out[block_id] = new_out
                live_in[block_id] = new_in
                changed = True
        if not changed:
            return live_in, live_out


def _memory_liveness(
    block_ids: Sequence[str],
    successors: Mapping[str, tuple[str, ...]],
    operations_by_block: Mapping[str, Sequence[Mapping[str, Any]]],
) -> dict[str, bool]:
    live_in = {
        block_id: any(operation.get("opcode") in _MEMORY_EFFECT_OPS for operation in operations_by_block[block_id])
        for block_id in block_ids
    }
    while True:
        changed = False
        for block_id in reversed(block_ids):
            value = live_in[block_id] or any(live_in[successor] for successor in successors[block_id])
            if value != live_in[block_id]:
                live_in[block_id] = value
                changed = True
        if not changed:
            return live_in


def _literal_kind(value: Mapping[str, Any]) -> str:
    storage_class = value.get("storageClass")
    if storage_class == "constant":
        return "constant"
    if storage_class == "memory":
        return "address"
    return "internal"


def derive_dataflow(
    *,
    values: Sequence[Mapping[str, Any]],
    pcode_ops: Sequence[Mapping[str, Any]],
    basic_blocks: Sequence[Mapping[str, Any]],
    edges: Sequence[Mapping[str, Any]],
    function_entry: int,
) -> dict[str, object]:
    """Derive deterministic low-level data flow from raw structured-lift DTOs.

    ``values`` identify exact SLEIGH storage tuples.  Overlapping register
    slices remain independent by design.  ``memorySSA`` uses one conservative
    unknown partition; every call invalidates that partition.
    """

    if not basic_blocks:
        raise DataflowDerivationError("at least one basic block is required")
    value_by_id = _unique_index(values, "id", "value")
    operation_by_id = _unique_index(pcode_ops, "id", "p-code operation")
    block_by_id = _unique_index(basic_blocks, "id", "basic block")
    edge_by_id = _unique_index(edges, "id", "edge")

    _validate_graph_links(
        block_by_id=block_by_id,
        edge_by_id=edge_by_id,
        function_entry=function_entry,
    )

    value_ids = sorted(value_by_id, key=lambda item: _numeric_identifier(item, "value"))
    operation_ids = sorted(operation_by_id, key=lambda item: _numeric_identifier(item, "operation"))
    block_ids = sorted(
        block_by_id,
        key=lambda item: (parse_address(block_by_id[item]["startAddress"], "block.startAddress"), item),
    )

    instruction_to_block: dict[int, str] = {}
    for block_id in block_ids:
        indices = block_by_id[block_id].get("instructionIndices")
        if not isinstance(indices, list) or not indices:
            raise DataflowDerivationError("basic block instructionIndices must be non-empty")
        for index in indices:
            if type(index) is not int or index < 0:
                raise DataflowDerivationError("instruction index must be a non-negative integer")
            if index in instruction_to_block:
                raise DataflowDerivationError("instruction belongs to multiple basic blocks")
            instruction_to_block[index] = block_id

    operations_by_block: dict[str, list[Mapping[str, Any]]] = {block_id: [] for block_id in block_ids}
    for operation_id in operation_ids:
        operation = operation_by_id[operation_id]
        instruction_index = operation.get("instructionIndex")
        if type(instruction_index) is not int or instruction_index not in instruction_to_block:
            raise DataflowDerivationError("p-code operation references an unknown instruction")
        inputs = operation.get("inputs")
        if not isinstance(inputs, list):
            raise DataflowDerivationError("p-code operation inputs must be an array")
        for value_id in inputs:
            if value_id not in value_by_id:
                raise DataflowDerivationError("p-code input references an unknown value")
        output = operation.get("output")
        if output is not None and output not in value_by_id:
            raise DataflowDerivationError("p-code output references an unknown value")
        operations_by_block[instruction_to_block[instruction_index]].append(operation)

    _validate_scoped_storage_uses(
        value_by_id=value_by_id,
        operation_by_id=operation_by_id,
    )

    for block_id in block_ids:
        operations_by_block[block_id].sort(
            key=lambda operation: (
                operation["instructionIndex"],
                operation["sequence"],
                _numeric_identifier(operation["id"], "operation"),
            )
        )

    successors = {block_id: _successors(block_by_id[block_id], edge_by_id) for block_id in block_ids}
    incoming_paths = {
        block_id: _incoming_paths(
            block_by_id[block_id],
            function_entry=function_entry,
            edge_by_id=edge_by_id,
        )
        for block_id in block_ids
    }

    output_storage_ids = {
        operation["output"]
        for operation in operation_by_id.values()
        if operation.get("output") is not None
    }
    mutable_storage_ids = {
        value_id
        for value_id in value_ids
        if value_by_id[value_id].get("storageClass") in _MUTABLE_STORAGE_CLASSES
        or value_id in output_storage_ids
    }
    cross_block_storage_ids = {
        value_id
        for value_id in mutable_storage_ids
        if value_by_id[value_id].get("scopeInstructionAddress") is None
    }
    immutable_value_ids = set(value_ids) - mutable_storage_ids

    uses_before_definition: dict[str, set[str]] = {}
    definitions: dict[str, set[str]] = {}
    for block_id in block_ids:
        seen_definitions: set[str] = set()
        block_uses: set[str] = set()
        block_definitions: set[str] = set()
        for operation in operations_by_block[block_id]:
            for value_id in operation["inputs"]:
                if value_id in mutable_storage_ids and value_id not in seen_definitions:
                    block_uses.add(value_id)
            output = operation.get("output")
            if output in mutable_storage_ids:
                seen_definitions.add(output)
                block_definitions.add(output)
        uses_before_definition[block_id] = block_uses
        definitions[block_id] = block_definitions

    live_in, live_out = _fixed_point_liveness(
        block_ids,
        successors,
        uses_before_definition,
        definitions,
    )

    phi_candidates: list[tuple[str, str]] = []
    for block_id in block_ids:
        if len(incoming_paths[block_id]) < 2:
            continue
        for value_id in value_ids:
            if value_id in live_in[block_id] and value_id in cross_block_storage_ids:
                phi_candidates.append((block_id, value_id))
    phi_candidate_set = set(phi_candidates)

    ssa_keys: list[tuple[str, ...]] = []
    for value_id in value_ids:
        if value_id in mutable_storage_ids:
            ssa_keys.append(("entry", value_id))
        else:
            ssa_keys.append(("literal", value_id))
    for block_id, value_id in phi_candidates:
        ssa_keys.append(("phi", block_id, value_id))
    for operation_id in operation_ids:
        output = operation_by_id[operation_id].get("output")
        if output is not None:
            ssa_keys.append(("operation", operation_id, output))

    ssa_id_for_key = {key: f"ssa{index:06d}" for index, key in enumerate(ssa_keys)}
    phi_id_for_key = {
        key: f"phi{index:06d}" for index, key in enumerate(phi_candidates)
    }

    ssa_values: list[dict[str, object]] = []
    for key in ssa_keys:
        if key[0] == "entry":
            _, value_id = key
            ssa_values.append(
                {
                    "id": ssa_id_for_key[key],
                    "kind": "entry",
                    "storageValueId": value_id,
                    "definingPcodeOpId": None,
                    "definingPhiId": None,
                    "sourceRange": None,
                }
            )
        elif key[0] == "literal":
            _, value_id = key
            ssa_values.append(
                {
                    "id": ssa_id_for_key[key],
                    "kind": _literal_kind(value_by_id[value_id]),
                    "storageValueId": value_id,
                    "definingPcodeOpId": None,
                    "definingPhiId": None,
                    "sourceRange": None,
                }
            )
        elif key[0] == "phi":
            _, block_id, value_id = key
            ssa_values.append(
                {
                    "id": ssa_id_for_key[key],
                    "kind": "phi",
                    "storageValueId": value_id,
                    "definingPcodeOpId": None,
                    "definingPhiId": phi_id_for_key[(block_id, value_id)],
                    "sourceRange": None,
                }
            )
        else:
            _, operation_id, value_id = key
            ssa_values.append(
                {
                    "id": ssa_id_for_key[key],
                    "kind": "operationResult",
                    "storageValueId": value_id,
                    "definingPcodeOpId": operation_id,
                    "definingPhiId": None,
                    "sourceRange": _copy_source_range(operation_by_id[operation_id]),
                }
            )

    def entry_ssa(value_id: str) -> str:
        return ssa_id_for_key[("entry", value_id)]

    def incoming_storage_state(
        block_id: str, previous_out: Mapping[str, Mapping[str, str]]
    ) -> dict[str, str]:
        state: dict[str, str] = {}
        for value_id in live_in[block_id]:
            if (block_id, value_id) in phi_candidate_set:
                state[value_id] = ssa_id_for_key[("phi", block_id, value_id)]
                continue
            candidates: list[str] = []
            for path in incoming_paths[block_id]:
                if path["sourceKind"] == "functionEntry":
                    candidates.append(entry_ssa(value_id))
                else:
                    source_block_id = path["sourceBlockId"]
                    assert isinstance(source_block_id, str)
                    candidates.append(previous_out.get(source_block_id, {}).get(value_id, entry_ssa(value_id)))
            if not candidates:
                candidates.append(entry_ssa(value_id))
            state[value_id] = candidates[0] if all(item == candidates[0] for item in candidates) else entry_ssa(value_id)
        return state

    def transfer_storage(
        block_id: str, previous_out: Mapping[str, Mapping[str, str]]
    ) -> dict[str, str]:
        state = incoming_storage_state(block_id, previous_out)
        for operation in operations_by_block[block_id]:
            output = operation.get("output")
            if output in mutable_storage_ids:
                state[output] = ssa_id_for_key[("operation", operation["id"], output)]
        return {value_id: state.get(value_id, entry_ssa(value_id)) for value_id in live_out[block_id]}

    storage_out: dict[str, dict[str, str]] = {block_id: {} for block_id in block_ids}
    for _ in range(max(4, len(block_ids) * 2 + 4)):
        next_out = {
            block_id: transfer_storage(block_id, storage_out)
            for block_id in block_ids
        }
        if next_out == storage_out:
            storage_out = next_out
            break
        storage_out = next_out
    else:
        raise DataflowDerivationError("exact-storage SSA did not reach a fixed point")

    binding_by_operation: dict[str, dict[str, object]] = {}
    heritage_drafts: list[dict[str, object]] = []
    for block_id in block_ids:
        state = incoming_storage_state(block_id, storage_out)
        for operation in operations_by_block[block_id]:
            input_ssa_ids: list[str] = []
            for operand_index, value_id in enumerate(operation["inputs"]):
                if value_id in immutable_value_ids:
                    ssa_id = ssa_id_for_key[("literal", value_id)]
                else:
                    ssa_id = state.get(value_id, entry_ssa(value_id))
                input_ssa_ids.append(ssa_id)
                heritage_drafts.append(
                    {
                        "pcodeOpId": operation["id"],
                        "operandIndex": operand_index,
                        "storageValueId": value_id,
                        "ssaValueId": ssa_id,
                        "sourceRange": _copy_source_range(operation),
                    }
                )
            output = operation.get("output")
            output_ssa_id = None
            if output is not None:
                output_ssa_id = ssa_id_for_key[("operation", operation["id"], output)]
                if output in mutable_storage_ids:
                    state[output] = output_ssa_id
            binding_by_operation[operation["id"]] = {
                "pcodeOpId": operation["id"],
                "inputSsaValueIds": input_ssa_ids,
                "outputSsaValueId": output_ssa_id,
            }

    ssa_bindings = [
        {"id": f"bind{index:06d}", **binding_by_operation[operation_id]}
        for index, operation_id in enumerate(operation_ids)
    ]
    heritage = [
        {"id": f"use{index:06d}", **item}
        for index, item in enumerate(
            sorted(
                heritage_drafts,
                key=lambda item: (
                    _numeric_identifier(item["pcodeOpId"], "operation"),
                    item["operandIndex"],
                ),
            )
        )
    ]

    phis: list[dict[str, object]] = []
    for block_id, value_id in phi_candidates:
        incoming: list[dict[str, object]] = []
        for path in incoming_paths[block_id]:
            if path["sourceKind"] == "functionEntry":
                ssa_id = entry_ssa(value_id)
            else:
                source_block_id = path["sourceBlockId"]
                assert isinstance(source_block_id, str)
                ssa_id = storage_out[source_block_id].get(value_id, entry_ssa(value_id))
            incoming.append({**path, "ssaValueId": ssa_id})
        phis.append(
            {
                "id": phi_id_for_key[(block_id, value_id)],
                "blockId": block_id,
                "storageValueId": value_id,
                "outputSsaValueId": ssa_id_for_key[("phi", block_id, value_id)],
                "incoming": incoming,
                "isTrivial": bool(incoming) and all(
                    item["ssaValueId"] == incoming[0]["ssaValueId"] for item in incoming
                ),
            }
        )

    memory_live_in = _memory_liveness(block_ids, successors, operations_by_block)
    memory_phi_blocks = [
        block_id
        for block_id in block_ids
        if memory_live_in[block_id] and len(incoming_paths[block_id]) >= 2
    ]
    memory_definition_ops = [
        operation_id
        for operation_id in operation_ids
        if operation_by_id[operation_id].get("opcode")
        in (_MEMORY_WRITE_OPS | _MEMORY_CALL_OPS | _MEMORY_UNKNOWN_OPS)
    ]
    memory_keys: list[tuple[str, ...]] = [("entry", "unknown")]
    memory_keys.extend(("phi", block_id, "unknown") for block_id in memory_phi_blocks)
    memory_keys.extend(("operation", operation_id, "unknown") for operation_id in memory_definition_ops)
    memory_id_for_key = {key: f"mem{index:06d}" for index, key in enumerate(memory_keys)}
    memory_phi_id_for_block = {
        block_id: f"mphi{index:06d}" for index, block_id in enumerate(memory_phi_blocks)
    }

    memory_versions: list[dict[str, object]] = []
    for key in memory_keys:
        if key[0] == "entry":
            memory_versions.append(
                {
                    "id": memory_id_for_key[key],
                    "partition": "unknown",
                    "kind": "functionEntry",
                    "definingPcodeOpId": None,
                    "definingMemoryPhiId": None,
                    "sourceRange": None,
                }
            )
        elif key[0] == "phi":
            _, block_id, _ = key
            memory_versions.append(
                {
                    "id": memory_id_for_key[key],
                    "partition": "unknown",
                    "kind": "phi",
                    "definingPcodeOpId": None,
                    "definingMemoryPhiId": memory_phi_id_for_block[block_id],
                    "sourceRange": None,
                }
            )
        else:
            _, operation_id, _ = key
            memory_versions.append(
                {
                    "id": memory_id_for_key[key],
                    "partition": "unknown",
                    "kind": "operationResult",
                    "definingPcodeOpId": operation_id,
                    "definingMemoryPhiId": None,
                    "sourceRange": _copy_source_range(operation_by_id[operation_id]),
                }
            )

    memory_entry_id = memory_id_for_key[("entry", "unknown")]

    def incoming_memory_state(
        block_id: str, previous_out: Mapping[str, str]
    ) -> str:
        if block_id in memory_phi_id_for_block:
            return memory_id_for_key[("phi", block_id, "unknown")]
        candidates: list[str] = []
        for path in incoming_paths[block_id]:
            if path["sourceKind"] == "functionEntry":
                candidates.append(memory_entry_id)
            else:
                source_block_id = path["sourceBlockId"]
                assert isinstance(source_block_id, str)
                candidates.append(previous_out.get(source_block_id, memory_entry_id))
        if not candidates:
            return memory_entry_id
        return candidates[0] if all(item == candidates[0] for item in candidates) else memory_entry_id

    def transfer_memory(block_id: str, previous_out: Mapping[str, str]) -> str:
        current = incoming_memory_state(block_id, previous_out)
        for operation in operations_by_block[block_id]:
            if operation.get("opcode") in (_MEMORY_WRITE_OPS | _MEMORY_CALL_OPS | _MEMORY_UNKNOWN_OPS):
                current = memory_id_for_key[("operation", operation["id"], "unknown")]
        return current

    memory_out: dict[str, str] = {block_id: memory_entry_id for block_id in block_ids}
    for _ in range(max(4, len(block_ids) * 2 + 4)):
        next_out = {block_id: transfer_memory(block_id, memory_out) for block_id in block_ids}
        if next_out == memory_out:
            memory_out = next_out
            break
        memory_out = next_out
    else:
        raise DataflowDerivationError("single-partition MemorySSA did not reach a fixed point")

    memory_effects: list[dict[str, object]] = []
    for block_id in block_ids:
        current = incoming_memory_state(block_id, memory_out)
        for operation in operations_by_block[block_id]:
            opcode = operation.get("opcode")
            if opcode not in _MEMORY_EFFECT_OPS:
                continue
            if opcode in _MEMORY_READ_OPS:
                kind = "read"
                output_memory_id = None
            elif opcode in _MEMORY_WRITE_OPS:
                kind = "write"
                output_memory_id = memory_id_for_key[("operation", operation["id"], "unknown")]
            elif opcode in _MEMORY_CALL_OPS:
                kind = "callClobber"
                output_memory_id = memory_id_for_key[("operation", operation["id"], "unknown")]
            else:
                kind = "unknownClobber"
                output_memory_id = memory_id_for_key[("operation", operation["id"], "unknown")]
            memory_effects.append(
                {
                    "id": f"me{len(memory_effects):06d}",
                    "pcodeOpId": operation["id"],
                    "kind": kind,
                    "partition": "unknown",
                    "inputMemoryVersionId": current,
                    "outputMemoryVersionId": output_memory_id,
                    "sourceRange": _copy_source_range(operation),
                }
            )
            if output_memory_id is not None:
                current = output_memory_id

    memory_phis: list[dict[str, object]] = []
    for block_id in memory_phi_blocks:
        incoming: list[dict[str, object]] = []
        for path in incoming_paths[block_id]:
            if path["sourceKind"] == "functionEntry":
                memory_version_id = memory_entry_id
            else:
                source_block_id = path["sourceBlockId"]
                assert isinstance(source_block_id, str)
                memory_version_id = memory_out.get(source_block_id, memory_entry_id)
            incoming.append({**path, "memoryVersionId": memory_version_id})
        memory_phis.append(
            {
                "id": memory_phi_id_for_block[block_id],
                "blockId": block_id,
                "partition": "unknown",
                "outputMemoryVersionId": memory_id_for_key[("phi", block_id, "unknown")],
                "incoming": incoming,
                "isTrivial": bool(incoming) and all(
                    item["memoryVersionId"] == incoming[0]["memoryVersionId"]
                    for item in incoming
                ),
            }
        )

    return {
        "analysisSemantics": dict(ANALYSIS_SEMANTICS),
        "ssaValues": ssa_values,
        "ssaBindings": ssa_bindings,
        "phis": phis,
        "heritage": heritage,
        "memoryVersions": memory_versions,
        "memoryPhis": memory_phis,
        "memoryEffects": memory_effects,
    }
