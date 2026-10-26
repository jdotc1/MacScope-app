"""Native SLEIGH data-flow proof backed by pinned pypcode 4.0.0.

The backend preserves DCP-03A raw instruction/p-code/CFG recovery, DCP-03B0
exact-storage SSA/MemorySSA/heritage, and DCP-03B1 AArch64 GPR alias SSA plus
Darwin base call effects. DCP-03B2 adds an authority-preserving effective-memory
view that applies a closed AArch64 Mach-O relocation and dyld chained-pointer
subset before decoding. It still does not claim Ghidra decompiler heritage,
complete register SSA, recovered variables/types, high-level structuring, or
source pseudocode.
"""

from __future__ import annotations

import hashlib
import stat
import time
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .canonical import bytes_sha256, canonical_json_bytes, canonical_sha256, format_address
from .contract import (
    ANALYSIS_LEVEL,
    CAPABILITY_TRUTH,
    CONTRACT_COMPLETENESS,
    ENGINE_BACKEND_ID,
    ENGINE_COMPONENT_ID,
    ENGINE_GIT_REVISION,
    ENGINE_VERSION,
    RESULT_SCHEMA_VERSION,
    expected_warnings,
)
from .dataflow import derive_dataflow
from .load_image import EffectiveLoadImageError, build_effective_load_image
from .register_dataflow import derive_register_analysis
from .errors import (
    BudgetExceededError,
    CancelledError,
    DecodeError,
    DependencyMismatchError,
    DependencyUnavailableError,
    LiftError,
)
from .request import AnalysisRequest
from .result_validation import ResultValidationError, validate_result

PYP_CODE_VERSION = ENGINE_VERSION
PYP_CODE_GIT_REVISION = ENGINE_GIT_REVISION
COMPONENT_ID = ENGINE_COMPONENT_ID
BACKEND_ID = ENGINE_BACKEND_ID
CONTROL_OPS = {"BRANCH", "CBRANCH", "BRANCHIND", "RETURN"}
CALL_OPS = {"CALL", "CALLIND"}


@dataclass(frozen=True)
class _DecodedInstruction:
    index: int
    address: int
    size: int
    data: bytes
    mnemonic: str
    body: str

    @property
    def end(self) -> int:
        return self.address + self.size


@dataclass(frozen=True)
class _RawValue:
    space: str
    offset: int
    size: int
    register_name: str | None
    scope_instruction_address: int | None

    @property
    def key(self) -> tuple[object, ...]:
        return (
            self.space,
            self.offset,
            self.size,
            self.register_name,
            self.scope_instruction_address,
        )


@dataclass(frozen=True)
class _RawOperation:
    identifier: str
    instruction_index: int
    sequence: int
    instruction_address: int
    opcode: str
    output_key: tuple[object, ...] | None
    input_keys: tuple[tuple[object, ...], ...]
    direct_target: int | None


class _Guard:
    def __init__(
        self,
        request: AnalysisRequest,
        *,
        cancellation_path: Path | None,
        clock: Callable[[], float],
    ) -> None:
        self._deadline = clock() + request.budgets.max_wall_time_ms / 1000.0
        self._clock = clock
        self._cancellation_path = cancellation_path

    def check(self) -> None:
        if self._cancellation_path is not None:
            try:
                self._cancellation_path.lstat()
            except FileNotFoundError:
                pass
            except OSError as error:
                raise CancelledError() from error
            else:
                raise CancelledError()
        if self._clock() > self._deadline:
            raise BudgetExceededError("wall time")


def _regular_file_sha256(path: Path, package_root: Path) -> dict[str, object]:
    try:
        resolved = path.resolve(strict=True)
        resolved.relative_to(package_root)
        metadata = resolved.lstat()
    except (OSError, ValueError) as error:
        raise DependencyMismatchError("pypcode resource path escaped its package root") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise DependencyMismatchError("pypcode resource is not a regular file")
    digest = hashlib.sha256()
    with resolved.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return {
        "name": resolved.relative_to(package_root).as_posix(),
        "byteCount": metadata.st_size,
        "sha256": digest.hexdigest(),
    }


def _load_pypcode(language_id: str, compiler_spec_id: str) -> tuple[Any, dict[str, object]]:
    try:
        import pypcode  # type: ignore[import-not-found]
        import pypcode.pypcode_native as pypcode_native  # type: ignore[import-not-found]
    except (ImportError, OSError) as error:
        raise DependencyUnavailableError(
            "pypcode 4.0.0 is not materialized; run the explicit DCP-03 dependency materializer"
        ) from error

    if getattr(pypcode, "__version__", None) != PYP_CODE_VERSION:
        raise DependencyMismatchError(
            f"expected pypcode {PYP_CODE_VERSION}; found {getattr(pypcode, '__version__', 'unknown')}"
        )
    language = pypcode.ArchLanguage.from_id(language_id)
    if language is None:
        raise DependencyMismatchError(f"materialized pypcode lacks language {language_id}")
    if not any(identifier == compiler_spec_id for identifier, _ in language.cspecs):
        raise DependencyMismatchError(
            f"language {language_id} lacks compiler spec {compiler_spec_id}"
        )

    matching_arch = None
    for arch in pypcode.Arch.enumerate():
        if any(candidate.id == language_id for candidate in arch.languages):
            matching_arch = arch
            break
    if matching_arch is None:
        raise DependencyMismatchError("could not locate the selected SLEIGH language definition")

    compiler_path = None
    for compiler in language.ldef.findall("compiler"):
        if compiler.attrib.get("id") == compiler_spec_id:
            compiler_path = Path(language.archdir) / compiler.attrib["spec"]
            break
    if compiler_path is None:
        raise DependencyMismatchError("could not locate the selected compiler specification")

    package_root = Path(pypcode.__file__).resolve(strict=True).parent
    resources = [
        _regular_file_sha256(Path(matching_arch.ldefpath), package_root),
        _regular_file_sha256(Path(language.pspec_path), package_root),
        _regular_file_sha256(Path(language.slafile_path), package_root),
        _regular_file_sha256(compiler_path, package_root),
        _regular_file_sha256(Path(pypcode_native.__file__), package_root),
    ]
    resources.sort(key=lambda item: str(item["name"]))
    engine = {
        "backend": BACKEND_ID,
        "componentId": COMPONENT_ID,
        "version": PYP_CODE_VERSION,
        "gitRevision": PYP_CODE_GIT_REVISION,
        "languageId": language_id,
        "compilerSpecId": compiler_spec_id,
        "resources": resources,
    }
    try:
        context = pypcode.Context(language)
    except Exception as error:  # native binding errors use several exception classes
        raise DependencyMismatchError("failed to initialize the selected SLEIGH context") from error
    return context, engine


def _source_range(request: AnalysisRequest, address: int, size: int) -> dict[str, object]:
    return {
        "imageId": request.image_id,
        "startAddress": format_address(address),
        "endAddressExclusive": format_address(address + size),
    }


def _decoded_instructions(
    context: Any,
    request: AnalysisRequest,
    function_bytes: bytes,
    guard: _Guard,
) -> tuple[_DecodedInstruction, ...]:
    guard.check()
    try:
        disassembly = context.disassemble(
            function_bytes,
            base_address=request.function_entry,
            max_bytes=len(function_bytes),
            max_instructions=request.budgets.max_instructions + 1,
        )
    except Exception as error:
        raise DecodeError("SLEIGH rejected the function byte range") from error
    guard.check()

    instructions: list[_DecodedInstruction] = []
    cursor = request.function_entry
    for index, item in enumerate(disassembly.instructions):
        if index >= request.budgets.max_instructions:
            raise BudgetExceededError("instruction count")
        address = int(item.addr.offset)
        size = int(item.length)
        if address != cursor or size <= 0 or address + size > request.function_end:
            raise DecodeError("SLEIGH produced a gap, overlap, or out-of-range instruction")
        offset = address - request.function_entry
        instructions.append(
            _DecodedInstruction(
                index=index,
                address=address,
                size=size,
                data=function_bytes[offset : offset + size],
                mnemonic=str(item.mnem),
                body=str(item.body),
            )
        )
        cursor += size
    if not instructions or cursor != request.function_end:
        raise DecodeError("SLEIGH did not decode the complete declared function range")
    return tuple(instructions)


def _varnode(varnode: Any, instruction_address: int) -> _RawValue:
    space = str(varnode.space.name)
    try:
        register_name = str(varnode.getRegisterName()) or None
    except Exception:
        register_name = None
    return _RawValue(
        space=space,
        offset=int(varnode.offset),
        size=int(varnode.size),
        register_name=register_name,
        scope_instruction_address=instruction_address if space in {"unique", "iop"} else None,
    )


def _direct_target(opcode: str, inputs: tuple[_RawValue, ...]) -> int | None:
    if opcode not in CONTROL_OPS | CALL_OPS or not inputs:
        return None
    first = inputs[0]
    return first.offset if first.space == "ram" else None


def _is_machine_terminator(operation: _RawOperation) -> bool:
    """Distinguish instruction control flow from SLEIGH's internal p-code labels.

    Raw p-code may use BRANCH/CBRANCH with a ``const`` destination to express
    intra-instruction semantics (for example atomic compare-and-swap). Those
    operations are not machine CFG edges. Direct machine branches use the RAM
    address space; indirect branches and returns are always instruction flow.
    """

    if operation.opcode in {"BRANCH", "CBRANCH"}:
        return operation.direct_target is not None
    return operation.opcode in {"BRANCHIND", "RETURN"}


def _lift_operations(
    context: Any,
    request: AnalysisRequest,
    instructions: tuple[_DecodedInstruction, ...],
    guard: _Guard,
) -> tuple[tuple[_RawOperation, ...], OrderedDict[tuple[object, ...], _RawValue]]:
    operations: list[_RawOperation] = []
    values: OrderedDict[tuple[object, ...], _RawValue] = OrderedDict()
    for instruction in instructions:
        guard.check()
        try:
            translation = context.translate(
                instruction.data,
                base_address=instruction.address,
                max_bytes=instruction.size,
                max_instructions=1,
            )
        except Exception as error:
            raise LiftError(f"SLEIGH could not lift instruction at {format_address(instruction.address)}") from error
        guard.check()
        if not translation.ops:
            raise LiftError(f"SLEIGH emitted no p-code at {format_address(instruction.address)}")
        for sequence, operation in enumerate(translation.ops):
            if len(operations) >= request.budgets.max_pcode_ops:
                raise BudgetExceededError("p-code operation count")
            output = None if operation.output is None else _varnode(operation.output, instruction.address)
            inputs = tuple(_varnode(item, instruction.address) for item in operation.inputs)
            if output is not None:
                values.setdefault(output.key, output)
            for value in inputs:
                values.setdefault(value.key, value)
            opcode = str(operation.opcode.name)
            operations.append(
                _RawOperation(
                    identifier=f"op{len(operations):06d}",
                    instruction_index=instruction.index,
                    sequence=sequence,
                    instruction_address=instruction.address,
                    opcode=opcode,
                    output_key=None if output is None else output.key,
                    input_keys=tuple(value.key for value in inputs),
                    direct_target=_direct_target(opcode, inputs),
                )
            )
    return tuple(operations), values


def _storage_class(space: str) -> str:
    return {
        "register": "register",
        "const": "constant",
        "ram": "memory",
        "unique": "temporary",
        "iop": "internal",
        "join": "composite",
    }.get(space, "other")


def _value_output(
    values: OrderedDict[tuple[object, ...], _RawValue]
) -> tuple[list[dict[str, object]], dict[tuple[object, ...], str]]:
    identifiers: dict[tuple[object, ...], str] = {}
    output: list[dict[str, object]] = []
    for index, value in enumerate(values.values()):
        identifier = f"v{index:06d}"
        identifiers[value.key] = identifier
        output.append(
            {
                "id": identifier,
                "space": value.space,
                "offset": format_address(value.offset),
                "size": value.size,
                "storageClass": _storage_class(value.space),
                "registerName": value.register_name,
                "scopeInstructionAddress": (
                    None
                    if value.scope_instruction_address is None
                    else format_address(value.scope_instruction_address)
                ),
            }
        )
    return output, identifiers


def _operations_output(
    request: AnalysisRequest,
    instructions: tuple[_DecodedInstruction, ...],
    operations: tuple[_RawOperation, ...],
    value_ids: dict[tuple[object, ...], str],
) -> tuple[list[dict[str, object]], dict[int, list[str]], dict[int, _RawOperation]]:
    output: list[dict[str, object]] = []
    by_instruction: dict[int, list[str]] = {item.index: [] for item in instructions}
    terminators: dict[int, _RawOperation] = {}
    instruction_by_index = {item.index: item for item in instructions}
    for operation in operations:
        instruction = instruction_by_index[operation.instruction_index]
        by_instruction[operation.instruction_index].append(operation.identifier)
        if _is_machine_terminator(operation):
            terminators[operation.instruction_index] = operation
        output.append(
            {
                "id": operation.identifier,
                "instructionIndex": operation.instruction_index,
                "sequence": operation.sequence,
                "opcode": operation.opcode,
                "output": None if operation.output_key is None else value_ids[operation.output_key],
                "inputs": [value_ids[key] for key in operation.input_keys],
                "directTargetAddress": (
                    None if operation.direct_target is None else format_address(operation.direct_target)
                ),
                "sourceRange": _source_range(request, instruction.address, instruction.size),
            }
        )
    return output, by_instruction, terminators


def _build_cfg(
    request: AnalysisRequest,
    instructions: tuple[_DecodedInstruction, ...],
    terminators: dict[int, _RawOperation],
) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    address_to_instruction = {item.address: item for item in instructions}
    leaders = {request.function_entry}
    for instruction in instructions:
        terminator = terminators.get(instruction.index)
        if terminator is None:
            continue
        if terminator.direct_target is not None and request.function_entry <= terminator.direct_target < request.function_end:
            if terminator.direct_target not in address_to_instruction:
                raise LiftError("direct branch targets the middle of an instruction")
            leaders.add(terminator.direct_target)
        if instruction.end < request.function_end:
            leaders.add(instruction.end)

    sorted_leaders = sorted(leaders)
    block_for_address: dict[int, str] = {}
    block_drafts: list[dict[str, Any]] = []
    for position, leader in enumerate(sorted_leaders):
        end = sorted_leaders[position + 1] if position + 1 < len(sorted_leaders) else request.function_end
        block_instructions = [item for item in instructions if leader <= item.address < end]
        if not block_instructions or block_instructions[0].address != leader:
            raise LiftError("CFG leader is not an instruction boundary")
        identifier = f"bb_{leader:x}"
        for item in block_instructions:
            block_for_address[item.address] = identifier
        terminal_operation = terminators.get(block_instructions[-1].index)
        block_drafts.append(
            {
                "id": identifier,
                "start": leader,
                "end": block_instructions[-1].end,
                "instructions": block_instructions,
                "terminal": terminal_operation,
            }
        )

    edge_drafts: list[dict[str, Any]] = []

    def add_edge(source: str, kind: str, target_address: int | None, op_id: str | None) -> None:
        target_block = block_for_address.get(target_address) if target_address is not None else None
        edge_drafts.append(
            {
                "sourceBlockId": source,
                "targetBlockId": target_block,
                "targetAddress": None if target_address is None else format_address(target_address),
                "kind": kind,
                "pcodeOpId": op_id,
            }
        )

    for draft in block_drafts:
        last = draft["instructions"][-1]
        terminal = draft["terminal"]
        if terminal is None:
            if last.end < request.function_end:
                add_edge(draft["id"], "fallthrough", last.end, None)
            continue
        if terminal.opcode == "CBRANCH":
            add_edge(draft["id"], "branchTrue", terminal.direct_target, terminal.identifier)
            if last.end < request.function_end:
                add_edge(draft["id"], "branchFalse", last.end, terminal.identifier)
        elif terminal.opcode == "BRANCH":
            add_edge(draft["id"], "branch", terminal.direct_target, terminal.identifier)
        elif terminal.opcode == "BRANCHIND":
            add_edge(draft["id"], "indirect", None, terminal.identifier)
        elif terminal.opcode == "RETURN":
            pass

    kind_order = {"branchTrue": 0, "branchFalse": 1, "branch": 2, "fallthrough": 3, "indirect": 4}
    edge_drafts.sort(
        key=lambda item: (
            next(d["start"] for d in block_drafts if d["id"] == item["sourceBlockId"]),
            kind_order[item["kind"]],
            item["targetAddress"] or "",
        )
    )
    edges: list[dict[str, object]] = []
    incoming: dict[str, list[str]] = {draft["id"]: [] for draft in block_drafts}
    outgoing: dict[str, list[str]] = {draft["id"]: [] for draft in block_drafts}
    for index, draft in enumerate(edge_drafts):
        identifier = f"edge{index:06d}"
        edge = {"id": identifier, **draft}
        edges.append(edge)
        outgoing[draft["sourceBlockId"]].append(identifier)
        if draft["targetBlockId"] is not None:
            incoming[draft["targetBlockId"]].append(identifier)

    blocks: list[dict[str, object]] = []
    for draft in block_drafts:
        terminal = draft["terminal"]
        if terminal is None:
            terminator = {
                "kind": "fallthrough" if draft["end"] < request.function_end else "functionEnd",
                "pcodeOpId": None,
                "directTargetAddress": None,
            }
        else:
            kind = {
                "CBRANCH": "conditionalBranch",
                "BRANCH": "branch",
                "BRANCHIND": "indirectBranch",
                "RETURN": "return",
            }[terminal.opcode]
            terminator = {
                "kind": kind,
                "pcodeOpId": terminal.identifier,
                "directTargetAddress": (
                    None if terminal.direct_target is None else format_address(terminal.direct_target)
                ),
            }
        blocks.append(
            {
                "id": draft["id"],
                "startAddress": format_address(draft["start"]),
                "endAddressExclusive": format_address(draft["end"]),
                "instructionIndices": [item.index for item in draft["instructions"]],
                "predecessorEdgeIds": incoming[draft["id"]],
                "successorEdgeIds": outgoing[draft["id"]],
                "terminator": terminator,
            }
        )
    return blocks, edges


def _calls_output(
    request: AnalysisRequest,
    instructions: tuple[_DecodedInstruction, ...],
    operations: tuple[_RawOperation, ...],
) -> list[dict[str, object]]:
    instruction_by_index = {item.index: item for item in instructions}
    output: list[dict[str, object]] = []
    for operation in operations:
        if operation.opcode not in CALL_OPS:
            continue
        instruction = instruction_by_index[operation.instruction_index]
        symbol = None if operation.direct_target is None else request.symbol_at(operation.direct_target)
        output.append(
            {
                "id": f"call{len(output):06d}",
                "pcodeOpId": operation.identifier,
                "kind": "direct" if operation.direct_target is not None else "indirect",
                "targetAddress": (
                    None if operation.direct_target is None else format_address(operation.direct_target)
                ),
                "targetSymbol": None if symbol is None else symbol.output(),
                "sourceRange": _source_range(request, instruction.address, instruction.size),
            }
        )
    return output



def analyze_request(
    request: AnalysisRequest,
    *,
    cancellation_path: Path | None = None,
    clock: Callable[[], float] = time.monotonic,
) -> dict[str, object]:
    """Analyze one validated static AArch64 function and return canonical DTOs."""

    try:
        load_image = build_effective_load_image(request)
    except EffectiveLoadImageError as error:
        raise LiftError(str(error)) from error

    guard = _Guard(request, cancellation_path=cancellation_path, clock=clock)
    guard.check()
    raw_function_bytes = request.read(
        request.function_entry,
        request.function_end,
        require_executable=True,
    )
    function_bytes = load_image.read(
        request.function_entry,
        request.function_end,
        require_executable=True,
    )
    context, engine = _load_pypcode(request.language_id, request.compiler_spec_id)
    guard.check()
    instructions = _decoded_instructions(context, request, function_bytes, guard)
    operations, raw_values = _lift_operations(context, request, instructions, guard)
    values, value_ids = _value_output(raw_values)
    pcode_ops, operations_by_instruction, terminators = _operations_output(
        request, instructions, operations, value_ids
    )
    blocks, edges = _build_cfg(request, instructions, terminators)
    calls = _calls_output(request, instructions, operations)
    dataflow = derive_dataflow(
        values=values,
        pcode_ops=pcode_ops,
        basic_blocks=blocks,
        edges=edges,
        function_entry=request.function_entry,
    )
    register_analysis = derive_register_analysis(
        values=values,
        pcode_ops=pcode_ops,
        basic_blocks=blocks,
        edges=edges,
        function_entry=request.function_entry,
    )

    instruction_output = [
        {
            "index": item.index,
            "address": format_address(item.address),
            "size": item.size,
            "bytesHex": item.data.hex(),
            "mnemonic": item.mnemonic,
            "body": item.body,
            "pcodeOpIds": operations_by_instruction[item.index],
            "sourceRange": _source_range(request, item.address, item.size),
        }
        for item in instructions
    ]

    capabilities = dict(CAPABILITY_TRUTH)

    result: dict[str, object] = {
        "schemaVersion": RESULT_SCHEMA_VERSION,
        "status": "ok",
        "analysisLevel": ANALYSIS_LEVEL,
        "contractCompleteness": CONTRACT_COMPLETENESS,
        "requestId": request.request_id,
        "requestSha256": request.request_sha256,
        "engine": engine,
        "capabilities": capabilities,
        "analysisSemantics": dataflow["analysisSemantics"],
        "image": {
            "imageId": request.image_id,
            "uuid": request.image_uuid,
            "preferredLoadAddress": format_address(request.preferred_load_address),
            "memoryRegions": [region.output() for region in request.memory_regions],
        },
        "loadImage": load_image.output,
        "function": {
            "functionId": request.function_id,
            "name": request.function_name,
            "entryAddress": format_address(request.function_entry),
            "endAddressExclusive": format_address(request.function_end),
            "byteCount": len(raw_function_bytes),
            "sourceSha256": bytes_sha256(raw_function_bytes),
            "effectiveSha256": bytes_sha256(function_bytes),
            "appliedPatchIds": load_image.patch_ids_intersecting(
                request.function_entry,
                request.function_end,
            ),
        },
        "instructions": instruction_output,
        "values": values,
        "pcodeOps": pcode_ops,
        "basicBlocks": blocks,
        "edges": edges,
        "calls": calls,
        "evidenceInputs": {
            "symbols": [item.output() for item in request.symbols],
            "relocations": [item.output() for item in request.relocations],
            "fixups": [item.output() for item in request.fixups],
            "typeHints": [item.output() for item in request.type_hints],
        },
        "ssaValues": dataflow["ssaValues"],
        "ssaBindings": dataflow["ssaBindings"],
        "phis": dataflow["phis"],
        "heritage": dataflow["heritage"],
        "memoryVersions": dataflow["memoryVersions"],
        "memoryPhis": dataflow["memoryPhis"],
        "memoryEffects": dataflow["memoryEffects"],
        "registerAnalysis": register_analysis,
        "recoveredVariables": [],
        "recoveredTypes": [],
        "structuredRegions": [],
        "pseudocodeTokens": [],
        "warnings": expected_warnings(
            unmapped_address_metadata_count=len(load_image.output["unmappedEvidence"]),
            authenticated_pointer_patch_count=sum(
                1
                for patch in load_image.output["patches"]
                if patch["authenticated"] is True
            ),
        ),
        "resourceUsage": {
            "mappedByteCount": sum(len(region.data) for region in request.memory_regions),
            "effectiveMappedByteCount": sum(len(region) for region in load_image.effective_regions),
            "functionByteCount": len(raw_function_bytes),
            "effectiveFunctionByteCount": len(function_bytes),
            "appliedPatchCount": len(load_image.output["patches"]),
            "unmappedAddressMetadataCount": len(load_image.output["unmappedEvidence"]),
            "instructionCount": len(instructions),
            "valueCount": len(values),
            "pcodeOpCount": len(pcode_ops),
            "basicBlockCount": len(blocks),
            "edgeCount": len(edges),
            "callCount": len(calls),
            "ssaValueCount": len(dataflow["ssaValues"]),
            "ssaBindingCount": len(dataflow["ssaBindings"]),
            "phiCount": len(dataflow["phis"]),
            "heritageUseCount": len(dataflow["heritage"]),
            "memoryVersionCount": len(dataflow["memoryVersions"]),
            "memoryPhiCount": len(dataflow["memoryPhis"]),
            "memoryEffectCount": len(dataflow["memoryEffects"]),
            "registerViewCount": len(register_analysis["views"]),
            "registerVersionCount": len(register_analysis["versions"]),
            "registerBindingCount": len(register_analysis["bindings"]),
            "registerPhiCount": len(register_analysis["phis"]),
            "callRegisterEffectCount": len(register_analysis["callEffects"]),
            "callRegisterInputSliceCount": sum(
                len(item["inputs"]) for item in register_analysis["callEffects"]
            ),
            "callRegisterClobberSliceCount": sum(
                len(item["clobbers"]) for item in register_analysis["callEffects"]
            ),
        },
    }
    guard.check()
    result["contentHash"] = canonical_sha256(result)
    try:
        validate_result(result, request=request)
    except ResultValidationError as error:
        raise LiftError("internal structured result failed semantic validation") from error
    payload = canonical_json_bytes(result)
    if len(payload) > request.budgets.max_output_bytes:
        raise BudgetExceededError("output bytes")
    return result
