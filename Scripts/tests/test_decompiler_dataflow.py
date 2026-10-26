from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import random
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOOL_ROOT = ROOT / "Tools" / "DecompilerCoreProof"
sys.path.insert(0, str(TOOL_ROOT))

from macscope_decompiler_proof.canonical import bytes_sha256, canonical_sha256
from macscope_decompiler_proof.contract import (
    ANALYSIS_LEVEL,
    ANALYSIS_SEMANTICS,
    CAPABILITY_TRUTH,
    CONTRACT_COMPLETENESS,
    ENGINE_BACKEND_ID,
    ENGINE_COMPONENT_ID,
    ENGINE_GIT_REVISION,
    ENGINE_LANGUAGE_ALLOWLIST,
    ENGINE_MINIMUM_RESOURCE_COUNT,
    ENGINE_VERSION,
    RESULT_SCHEMA_VERSION,
    expected_warnings,
)
from macscope_decompiler_proof.dataflow import DataflowDerivationError, derive_dataflow
from macscope_decompiler_proof.load_image import build_effective_load_image
from macscope_decompiler_proof.register_dataflow import derive_register_analysis
from macscope_decompiler_proof.request import parse_request_bytes
from macscope_decompiler_proof.result_validation import ResultValidationError, validate_result


def source_range(address: int) -> dict[str, object]:
    return {
        "imageId": "fixture-image",
        "startAddress": f"0x{address:x}",
        "endAddressExclusive": f"0x{address + 4:x}",
    }


def value(
    identifier: str,
    *,
    storage_class: str,
    offset: int,
    size: int = 8,
    register_name: str | None = None,
    scope: int | None = None,
) -> dict[str, object]:
    space = {
        "register": "register",
        "constant": "const",
        "memory": "ram",
        "temporary": "unique",
        "internal": "iop",
        "composite": "join",
        "other": "other",
    }[storage_class]
    return {
        "id": identifier,
        "space": space,
        "offset": f"0x{offset:x}",
        "size": size,
        "storageClass": storage_class,
        "registerName": register_name,
        "scopeInstructionAddress": None if scope is None else f"0x{scope:x}",
    }


def operation(
    identifier: str,
    instruction_index: int,
    opcode: str,
    *,
    inputs: list[str],
    output: str | None,
    direct_target: str | None = None,
    sequence: int = 0,
) -> dict[str, object]:
    address = 0x1000 + instruction_index * 4
    return {
        "id": identifier,
        "instructionIndex": instruction_index,
        "sequence": sequence,
        "opcode": opcode,
        "output": output,
        "inputs": inputs,
        "directTargetAddress": direct_target,
        "sourceRange": source_range(address),
    }


def edge(
    identifier: str,
    source: str,
    target: str,
    kind: str,
    *,
    op_id: str | None = None,
) -> dict[str, object]:
    return {
        "id": identifier,
        "sourceBlockId": source,
        "targetBlockId": target,
        "targetAddress": target.replace("bb_", "0x"),
        "kind": kind,
        "pcodeOpId": op_id,
    }


def block(
    address: int,
    instruction_index: int | list[int],
    *,
    predecessors: list[str],
    successors: list[str],
    terminator: str = "fallthrough",
    pcode_op_id: str | None = None,
    direct_target: str | None = None,
) -> dict[str, object]:
    instruction_indices = (
        [instruction_index] if isinstance(instruction_index, int) else instruction_index
    )
    return {
        "id": f"bb_{address:x}",
        "startAddress": f"0x{address:x}",
        "endAddressExclusive": f"0x{address + 4 * len(instruction_indices):x}",
        "instructionIndices": instruction_indices,
        "predecessorEdgeIds": predecessors,
        "successorEdgeIds": successors,
        "terminator": {
            "kind": terminator,
            "pcodeOpId": pcode_op_id,
            "directTargetAddress": direct_target,
        },
    }


def diamond_graph(*, memory: bool = False, call: bool = False) -> dict[str, object]:
    values = [
        value("v000000", storage_class="register", offset=0x4000, register_name="x0"),
        value("v000001", storage_class="constant", offset=1),
        value("v000002", storage_class="constant", offset=2),
        value("v000003", storage_class="register", offset=0x4008, register_name="x1"),
    ]
    operations = [
        operation(
            "op000000",
            0,
            "CBRANCH",
            inputs=["v000001"],
            output=None,
            direct_target="0x100c",
        ),
        operation("op000001", 1, "COPY", inputs=["v000001"], output="v000000"),
        operation("op000002", 2, "BRANCH", inputs=[], output=None, direct_target="0x1010"),
        operation("op000003", 3, "COPY", inputs=["v000002"], output="v000000"),
        operation("op000004", 4, "INT_ADD", inputs=["v000000", "v000001"], output="v000003"),
    ]
    if memory:
        operations[1] = operation(
            "op000001", 1, "STORE", inputs=["v000001", "v000003", "v000000"], output=None
        )
        operations[3] = operation("op000003", 3, "COPY", inputs=["v000002"], output="v000000")
        operations[4] = operation("op000004", 4, "LOAD", inputs=["v000001", "v000003"], output="v000000")
    if call:
        operations[1] = operation("op000001", 1, "CALL", inputs=["v000002"], output=None, direct_target="0x2000")
    edges = [
        edge("edge000000", "bb_1000", "bb_100c", "branchTrue", op_id="op000000"),
        edge("edge000001", "bb_1000", "bb_1004", "branchFalse", op_id="op000000"),
        edge("edge000002", "bb_1004", "bb_1010", "branch", op_id="op000002"),
        edge("edge000003", "bb_100c", "bb_1010", "fallthrough"),
    ]
    blocks = [
        block(
            0x1000,
            0,
            predecessors=[],
            successors=["edge000000", "edge000001"],
            terminator="conditionalBranch",
            pcode_op_id="op000000",
            direct_target="0x100c",
        ),
        block(
            0x1004,
            [1, 2],
            predecessors=["edge000001"],
            successors=["edge000002"],
            terminator="branch",
            pcode_op_id="op000002",
            direct_target="0x1010",
        ),
        block(0x100C, 3, predecessors=["edge000000"], successors=["edge000003"]),
        block(
            0x1010,
            4,
            predecessors=["edge000002", "edge000003"],
            successors=[],
            terminator="functionEnd",
        ),
    ]
    return {"values": values, "pcodeOps": operations, "basicBlocks": blocks, "edges": edges}


def loop_graph() -> dict[str, object]:
    values = [
        value("v000000", storage_class="register", offset=0x4000, register_name="x0"),
        value("v000001", storage_class="constant", offset=1),
    ]
    operations = [
        operation("op000000", 0, "COPY", inputs=["v000001"], output="v000000"),
        operation("op000001", 1, "INT_ADD", inputs=["v000000", "v000001"], output="v000000"),
        operation("op000002", 2, "RETURN", inputs=["v000000"], output=None),
    ]
    edges = [
        edge("edge000000", "bb_1000", "bb_1004", "fallthrough"),
        edge("edge000001", "bb_1004", "bb_1004", "branchTrue", op_id="op000001"),
        edge("edge000002", "bb_1004", "bb_1008", "branchFalse", op_id="op000001"),
    ]
    blocks = [
        block(0x1000, 0, predecessors=[], successors=["edge000000"]),
        block(
            0x1004,
            1,
            predecessors=["edge000000", "edge000001"],
            successors=["edge000001", "edge000002"],
            terminator="conditionalBranch",
            pcode_op_id="op000001",
        ),
        block(0x1008, 2, predecessors=["edge000002"], successors=[], terminator="return", pcode_op_id="op000002"),
    ]
    return {"values": values, "pcodeOps": operations, "basicBlocks": blocks, "edges": edges}


def entry_loop_graph() -> dict[str, object]:
    values = [
        value("v000000", storage_class="register", offset=0x4000, register_name="x0"),
        value("v000001", storage_class="constant", offset=1),
    ]
    operations = [
        operation("op000000", 0, "INT_ADD", inputs=["v000000", "v000001"], output="v000000"),
        operation("op000001", 1, "RETURN", inputs=["v000000"], output=None),
    ]
    edges = [
        edge("edge000000", "bb_1000", "bb_1000", "branchTrue", op_id="op000000"),
        edge("edge000001", "bb_1000", "bb_1004", "branchFalse", op_id="op000000"),
    ]
    blocks = [
        block(
            0x1000,
            0,
            predecessors=["edge000000"],
            successors=["edge000000", "edge000001"],
            terminator="conditionalBranch",
            pcode_op_id="op000000",
        ),
        block(
            0x1004,
            1,
            predecessors=["edge000001"],
            successors=[],
            terminator="return",
            pcode_op_id="op000001",
        ),
    ]
    return {"values": values, "pcodeOps": operations, "basicBlocks": blocks, "edges": edges}


def derive(graph: dict[str, object]) -> dict[str, object]:
    return derive_dataflow(
        values=graph["values"],
        pcode_ops=graph["pcodeOps"],
        basic_blocks=graph["basicBlocks"],
        edges=graph["edges"],
        function_entry=0x1000,
    )


def complete_result(graph: dict[str, object]) -> dict[str, object]:
    dataflow = derive(graph)
    register_analysis = derive_register_analysis(
        values=graph["values"],
        pcode_ops=graph["pcodeOps"],
        basic_blocks=graph["basicBlocks"],
        edges=graph["edges"],
        function_entry=0x1000,
    )
    instructions = []
    operations_by_instruction: dict[int, list[dict[str, object]]] = {}
    for item in graph["pcodeOps"]:
        operations_by_instruction.setdefault(item["instructionIndex"], []).append(item)
    instruction_count = max(operations_by_instruction) + 1
    for index in range(instruction_count):
        address = 0x1000 + index * 4
        operations = sorted(
            operations_by_instruction[index],
            key=lambda item: item["sequence"],
        )
        instructions.append(
            {
                "index": index,
                "address": f"0x{address:x}",
                "size": 4,
                "bytesHex": "1f2003d5",
                "mnemonic": "nop",
                "body": "",
                "pcodeOpIds": [item["id"] for item in operations],
                "sourceRange": source_range(address),
            }
        )
    calls = []
    for op in graph["pcodeOps"]:
        if op["opcode"] in {"CALL", "CALLIND"}:
            calls.append(
                {
                    "id": f"call{len(calls):06d}",
                    "pcodeOpId": op["id"],
                    "kind": "direct" if op["directTargetAddress"] else "indirect",
                    "targetAddress": op["directTargetAddress"],
                    "targetSymbol": None,
                    "sourceRange": copy.deepcopy(op["sourceRange"]),
                }
            )
    source_bytes = bytes.fromhex("1f2003d5") * len(instructions)
    result = {
        "schemaVersion": RESULT_SCHEMA_VERSION,
        "status": "ok",
        "analysisLevel": ANALYSIS_LEVEL,
        "contractCompleteness": CONTRACT_COMPLETENESS,
        "requestId": "synthetic-request",
        "requestSha256": "0" * 64,
        "engine": {
            "backend": ENGINE_BACKEND_ID,
            "componentId": ENGINE_COMPONENT_ID,
            "version": ENGINE_VERSION,
            "gitRevision": ENGINE_GIT_REVISION,
            "languageId": "AARCH64:LE:64:AppleSilicon",
            "compilerSpecId": "default",
            "resources": [
                {"name": f"resource-{index}", "byteCount": 1, "sha256": f"{index + 2:064x}"}
                for index in range(ENGINE_MINIMUM_RESOURCE_COUNT)
            ],
        },
        "capabilities": copy.deepcopy(CAPABILITY_TRUTH),
        "analysisSemantics": dataflow["analysisSemantics"],
        "image": {
            "imageId": "fixture-image",
            "uuid": "00000000-0000-0000-0000-000000000001",
            "preferredLoadAddress": "0x1000",
            "memoryRegions": [
                {
                    "name": "__text",
                    "startAddress": "0x1000",
                    "endAddressExclusive": f"0x{0x1000 + len(instructions) * 4:x}",
                    "permissions": "r-x",
                    "byteCount": len(instructions) * 4,
                    "sha256": "2" * 64,
                }
            ],
        },
        "loadImage": {
            "model": {
                "architecture": "AArch64",
                "byteOrder": "little",
                "pointerWidthBits": 64,
                "relocationModel": "mach-o-arm64-relocation-subset-v1",
                "fixupModel": "dyld-chained-pointer-normalization-v1",
                "patchPolicy": "fail-closed-mapped-preserve-unmapped",
                "authenticatedPointerTreatment": (
                    "materialize-unsigned-target-with-authentication-evidence"
                ),
                "supportedRelocationKinds": [
                    "ARM64_RELOC_UNSIGNED",
                    "ARM64_RELOC_BRANCH26",
                    "ARM64_RELOC_PAGE21",
                    "ARM64_RELOC_GOT_LOAD_PAGE21",
                    "ARM64_RELOC_TLVP_LOAD_PAGE21",
                    "ARM64_RELOC_PAGEOFF12",
                    "ARM64_RELOC_GOT_LOAD_PAGEOFF12",
                    "ARM64_RELOC_TLVP_LOAD_PAGEOFF12",
                ],
                "supportedFixupKinds": [
                    "DYLD_CHAINED_REBASE64",
                    "DYLD_CHAINED_BIND64",
                    "DYLD_CHAINED_AUTH_REBASE64",
                    "DYLD_CHAINED_AUTH_BIND64",
                ],
            },
            "memoryRegions": [
                {
                    "name": "__text",
                    "startAddress": "0x1000",
                    "endAddressExclusive": f"0x{0x1000 + len(instructions) * 4:x}",
                    "permissions": "r-x",
                    "byteCount": len(instructions) * 4,
                    "rawSha256": "2" * 64,
                    "effectiveSha256": "2" * 64,
                    "appliedPatchIds": [],
                }
            ],
            "patches": [],
            "unmappedEvidence": [],
        },
        "function": {
            "functionId": "synthetic-function",
            "name": "_synthetic",
            "entryAddress": "0x1000",
            "endAddressExclusive": f"0x{0x1000 + len(instructions) * 4:x}",
            "byteCount": len(instructions) * 4,
            "sourceSha256": bytes_sha256(source_bytes),
            "effectiveSha256": bytes_sha256(source_bytes),
            "appliedPatchIds": [],
        },
        "instructions": instructions,
        "values": copy.deepcopy(graph["values"]),
        "pcodeOps": copy.deepcopy(graph["pcodeOps"]),
        "basicBlocks": copy.deepcopy(graph["basicBlocks"]),
        "edges": copy.deepcopy(graph["edges"]),
        "calls": calls,
        "evidenceInputs": {"symbols": [], "relocations": [], "fixups": [], "typeHints": []},
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
            unmapped_address_metadata_count=0,
            authenticated_pointer_patch_count=0,
        ),
        "resourceUsage": {
            "mappedByteCount": len(instructions) * 4,
            "effectiveMappedByteCount": len(instructions) * 4,
            "functionByteCount": len(instructions) * 4,
            "effectiveFunctionByteCount": len(instructions) * 4,
            "appliedPatchCount": 0,
            "unmappedAddressMetadataCount": 0,
            "instructionCount": len(instructions),
            "valueCount": len(graph["values"]),
            "pcodeOpCount": len(graph["pcodeOps"]),
            "basicBlockCount": len(graph["basicBlocks"]),
            "edgeCount": len(graph["edges"]),
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
    result["contentHash"] = canonical_sha256(result)
    return result


def synthetic_request_and_result(
    *,
    with_data_fixup: bool = False,
) -> tuple[object, dict[str, object]]:
    result = complete_result(diamond_graph(call=True))
    function_bytes = bytes.fromhex("1f2003d5") * len(result["instructions"])
    raw_request = {
        "schemaVersion": 1,
        "requestId": result["requestId"],
        "engine": {
            "languageId": result["engine"]["languageId"],
            "compilerSpecId": result["engine"]["compilerSpecId"],
        },
        "image": {
            "imageId": result["image"]["imageId"],
            "uuid": result["image"]["uuid"],
            "preferredLoadAddress": result["image"]["preferredLoadAddress"],
        },
        "function": {
            "functionId": result["function"]["functionId"],
            "name": result["function"]["name"],
            "entryAddress": result["function"]["entryAddress"],
            "endAddressExclusive": result["function"]["endAddressExclusive"],
        },
        "memoryRegions": [
            {
                "name": "__text",
                "startAddress": "0x1000",
                "permissions": "r-x",
                "bytesHex": function_bytes.hex(),
            }
        ],
        "symbols": [
            {
                "imageId": "fixture-image",
                "address": "0x2000",
                "name": "_target",
                "kind": "function",
            }
        ],
        "relocations": [],
        "fixups": [],
        "typeHints": [],
        "budgets": {
            "maxCodeBytes": len(function_bytes) + (8 if with_data_fixup else 0),
            "maxInstructions": 64,
            "maxPcodeOps": 256,
            "maxOutputBytes": 1024 * 1024,
            "maxWallTimeMs": 1000,
        },
    }
    if with_data_fixup:
        raw_request["memoryRegions"].append(
            {
                "name": "__data",
                "startAddress": "0x3000",
                "permissions": "rw-",
                "bytesHex": "0000000000000000",
            }
        )
        raw_request["fixups"] = [
            {
                "address": "0x3000",
                "kind": "DYLD_CHAINED_REBASE64",
                "targetAddress": "0x4000",
                "authenticated": False,
                "key": None,
                "diversity": None,
            }
        ]
    request = parse_request_bytes(
        json.dumps(raw_request, sort_keys=True, separators=(",", ":")).encode("utf-8")
    )
    result["requestSha256"] = request.request_sha256
    result["image"]["memoryRegions"] = [region.output() for region in request.memory_regions]
    load_image = build_effective_load_image(request)
    result["loadImage"] = load_image.output
    raw_function = request.read(request.function_entry, request.function_end, require_executable=True)
    effective_function = load_image.read(
        request.function_entry,
        request.function_end,
        require_executable=True,
    )
    result["function"]["sourceSha256"] = bytes_sha256(raw_function)
    result["function"]["effectiveSha256"] = bytes_sha256(effective_function)
    result["function"]["appliedPatchIds"] = load_image.patch_ids_intersecting(
        request.function_entry,
        request.function_end,
    )
    result["evidenceInputs"]["symbols"] = [symbol.output() for symbol in request.symbols]
    result["evidenceInputs"]["relocations"] = [item.output() for item in request.relocations]
    result["evidenceInputs"]["fixups"] = [item.output() for item in request.fixups]
    result["calls"][0]["targetSymbol"] = request.symbols[0].output()
    result["warnings"] = expected_warnings(
        unmapped_address_metadata_count=len(load_image.output["unmappedEvidence"]),
        authenticated_pointer_patch_count=sum(
            1 for item in load_image.output["patches"] if item["authenticated"] is True
        ),
    )
    result["resourceUsage"]["mappedByteCount"] = sum(
        len(region.data) for region in request.memory_regions
    )
    result["resourceUsage"]["effectiveMappedByteCount"] = sum(
        len(region) for region in load_image.effective_regions
    )
    result["resourceUsage"]["appliedPatchCount"] = len(load_image.output["patches"])
    result["resourceUsage"]["unmappedAddressMetadataCount"] = len(
        load_image.output["unmappedEvidence"]
    )
    result["contentHash"] = canonical_sha256(
        {key: value for key, value in result.items() if key != "contentHash"}
    )
    return request, result


def rehash(result: dict[str, object]) -> None:
    result["contentHash"] = canonical_sha256(
        {key: value for key, value in result.items() if key != "contentHash"}
    )


class DataflowDerivationTests(unittest.TestCase):
    def test_diamond_places_exact_storage_phi_for_live_register(self) -> None:
        result = derive(diamond_graph())
        self.assertEqual(len(result["phis"]), 1)
        phi = result["phis"][0]
        self.assertEqual(phi["blockId"], "bb_1010")
        self.assertEqual(phi["storageValueId"], "v000000")
        incoming = [item["ssaValueId"] for item in phi["incoming"]]
        self.assertEqual(len(set(incoming)), 2)
        join_binding = next(
            item for item in result["ssaBindings"] if item["pcodeOpId"] == "op000004"
        )
        self.assertEqual(join_binding["inputSsaValueIds"][0], phi["outputSsaValueId"])

    def test_heritage_covers_every_operand_once(self) -> None:
        graph = diamond_graph()
        result = derive(graph)
        expected = sum(len(item["inputs"]) for item in graph["pcodeOps"])
        self.assertEqual(len(result["heritage"]), expected)
        keys = {(item["pcodeOpId"], item["operandIndex"]) for item in result["heritage"]}
        self.assertEqual(len(keys), expected)

    def test_loop_header_phi_uses_preheader_and_backedge_versions(self) -> None:
        result = derive(loop_graph())
        phi = result["phis"][0]
        self.assertEqual(phi["blockId"], "bb_1004")
        self.assertEqual([item["edgeId"] for item in phi["incoming"]], ["edge000000", "edge000001"])
        self.assertEqual(len({item["ssaValueId"] for item in phi["incoming"]}), 2)

    def test_entry_loop_phi_preserves_function_entry_and_backedge_paths(self) -> None:
        result = derive(entry_loop_graph())
        phi = result["phis"][0]
        self.assertEqual(phi["blockId"], "bb_1000")
        self.assertEqual(
            [item["sourceKind"] for item in phi["incoming"]],
            ["functionEntry", "block"],
        )
        self.assertIsNone(phi["incoming"][0]["edgeId"])
        self.assertEqual(phi["incoming"][1]["edgeId"], "edge000000")
        self.assertEqual(len({item["ssaValueId"] for item in phi["incoming"]}), 2)

    def test_memory_phi_merges_store_and_unchanged_path_before_load(self) -> None:
        result = derive(diamond_graph(memory=True))
        self.assertEqual(len(result["memoryPhis"]), 1)
        phi = result["memoryPhis"][0]
        self.assertEqual(phi["blockId"], "bb_1010")
        incoming = [item["memoryVersionId"] for item in phi["incoming"]]
        self.assertEqual(len(set(incoming)), 2)
        load = next(
            item for item in result["memoryEffects"] if item["pcodeOpId"] == "op000004"
        )
        self.assertEqual(load["kind"], "read")
        self.assertEqual(load["inputMemoryVersionId"], phi["outputMemoryVersionId"])
        self.assertIsNone(load["outputMemoryVersionId"])

    def test_call_conservatively_clobbers_unknown_memory_partition(self) -> None:
        result = derive(diamond_graph(call=True))
        effect = next(item for item in result["memoryEffects"] if item["pcodeOpId"] == "op000001")
        self.assertEqual(effect["kind"], "callClobber")
        self.assertEqual(effect["partition"], "unknown")
        self.assertIsNotNone(effect["outputMemoryVersionId"])

    def test_output_is_independent_of_input_collection_order(self) -> None:
        graph = diamond_graph(memory=True)
        expected = derive(graph)
        shuffled = copy.deepcopy(graph)
        random.Random(7).shuffle(shuffled["values"])
        random.Random(11).shuffle(shuffled["pcodeOps"])
        random.Random(13).shuffle(shuffled["basicBlocks"])
        random.Random(17).shuffle(shuffled["edges"])
        self.assertEqual(derive(shuffled), expected)

    def test_duplicate_raw_identifier_fails_closed(self) -> None:
        graph = diamond_graph()
        graph["values"].append(copy.deepcopy(graph["values"][0]))
        with self.assertRaisesRegex(DataflowDerivationError, "duplicate value identifier"):
            derive(graph)

    def test_orphan_cfg_edge_fails_closed(self) -> None:
        graph = diamond_graph()
        graph["basicBlocks"][0]["successorEdgeIds"].remove("edge000001")
        with self.assertRaisesRegex(DataflowDerivationError, "successor edges"):
            derive(graph)

    def test_instruction_scoped_storage_cannot_escape_its_instruction(self) -> None:
        graph = diamond_graph()
        graph["values"][0]["scopeInstructionAddress"] = "0x1004"
        with self.assertRaisesRegex(DataflowDerivationError, "outside its defining instruction"):
            derive(graph)


class StructuredResultValidationTests(unittest.TestCase):
    def test_contract_constants_match_the_closed_result_schema(self) -> None:
        import json

        schema = json.loads((TOOL_ROOT / "schemas" / "result.schema.json").read_text(encoding="utf-8"))
        self.assertEqual(schema["properties"]["schemaVersion"]["const"], RESULT_SCHEMA_VERSION)
        self.assertEqual(schema["properties"]["analysisLevel"]["const"], ANALYSIS_LEVEL)
        self.assertEqual(
            schema["properties"]["contractCompleteness"]["const"],
            CONTRACT_COMPLETENESS,
        )
        capability_schema = schema["$defs"]["capabilities"]
        self.assertEqual(capability_schema["required"], list(CAPABILITY_TRUTH))
        self.assertEqual(
            {name: definition["const"] for name, definition in capability_schema["properties"].items()},
            CAPABILITY_TRUTH,
        )
        semantics_schema = schema["$defs"]["analysisSemantics"]
        self.assertEqual(semantics_schema["required"], list(ANALYSIS_SEMANTICS))
        self.assertEqual(
            {name: definition["const"] for name, definition in semantics_schema["properties"].items()},
            ANALYSIS_SEMANTICS,
        )
        engine_schema = schema["$defs"]["engine"]
        self.assertEqual(engine_schema["properties"]["backend"]["const"], ENGINE_BACKEND_ID)
        self.assertEqual(
            engine_schema["properties"]["componentId"]["const"],
            ENGINE_COMPONENT_ID,
        )
        self.assertEqual(engine_schema["properties"]["version"]["const"], ENGINE_VERSION)
        self.assertEqual(
            engine_schema["properties"]["gitRevision"]["const"],
            ENGINE_GIT_REVISION,
        )
        self.assertEqual(
            set(engine_schema["properties"]["languageId"]["enum"]),
            set(ENGINE_LANGUAGE_ALLOWLIST),
        )
        self.assertEqual(
            engine_schema["properties"]["resources"]["minItems"],
            ENGINE_MINIMUM_RESOURCE_COUNT,
        )
        self.assertEqual(
            schema["$id"],
            "https://macscope.invalid/schemas/"
            "dcp03-effective-load-image-darwin-register-dataflow-result-v4.json",
        )
        self.assertEqual(
            schema["title"],
            "MacScope DCP-03 effective-load-image Darwin register data-flow result",
        )
        self.assertIn("DCP-03B2", schema["description"])

    def test_complete_synthetic_result_passes_semantic_verification(self) -> None:
        validate_result(complete_result(diamond_graph(memory=True)))

    @unittest.skipUnless(importlib.util.find_spec("jsonschema") is not None, "jsonschema is unavailable")
    def test_complete_synthetic_result_matches_closed_json_schema(self) -> None:
        import json
        import jsonschema

        schema = json.loads((TOOL_ROOT / "schemas" / "result.schema.json").read_text(encoding="utf-8"))
        jsonschema.Draft202012Validator(schema).validate(complete_result(diamond_graph(memory=True)))

    def test_dangling_ssa_binding_is_rejected_even_with_recomputed_hash(self) -> None:
        result = complete_result(diamond_graph())
        result["ssaBindings"][0]["inputSsaValueIds"][0] = "ssa999999"
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "unknown input SSA value"):
            validate_result(result)

    def test_phi_predecessor_identity_is_rejected_even_with_recomputed_hash(self) -> None:
        result = complete_result(diamond_graph())
        result["phis"][0]["incoming"][0]["edgeId"] = "edge000003"
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "predecessor identity"):
            validate_result(result)

    def test_memory_chain_discontinuity_is_rejected(self) -> None:
        result = complete_result(diamond_graph(memory=True))
        load = next(item for item in result["memoryEffects"] if item["kind"] == "read")
        load["inputMemoryVersionId"] = result["memoryVersions"][0]["id"]
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "MemorySSA chain"):
            validate_result(result)

    def test_register_binding_semantics_cannot_be_forged_with_recomputed_hash(self) -> None:
        result = complete_result(diamond_graph())
        read = result["registerAnalysis"]["bindings"][-1]["reads"][0]
        read["inputRegisterVersionId"] = result["registerAnalysis"]["versions"][0]["id"]
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "registerAnalysis"):
            validate_result(result)

    def test_darwin_call_slice_geometry_cannot_be_forged(self) -> None:
        result = complete_result(diamond_graph(call=True))
        v8 = next(
            item
            for item in result["registerAnalysis"]["callEffects"][0]["clobbers"]
            if item["registerName"] == "v8"
        )
        v8["bitOffset"] = 0
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "SIMD call clobber"):
            validate_result(result)

    def test_darwin_call_input_version_cannot_be_forged(self) -> None:
        result = complete_result(diamond_graph(call=True))
        versions = result["registerAnalysis"]["versions"]
        x1_version = next(
            item["id"]
            for item in versions
            if item["canonicalRegister"] == "x1"
            and item["kind"] == "functionEntry"
        )
        x0_input = next(
            item
            for item in result["registerAnalysis"]["callEffects"][0]["inputs"]
            if item["registerName"] == "x0"
        )
        x0_input["inputRegisterVersionId"] = x1_version
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "different canonical register"):
            validate_result(result)

    def test_missing_darwin_call_input_slice_is_rejected(self) -> None:
        result = complete_result(diamond_graph(call=True))
        result["registerAnalysis"]["callEffects"][0]["inputs"].pop()
        result["resourceUsage"]["callRegisterInputSliceCount"] -= 1
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "incomplete conservative input"):
            validate_result(result)

    def test_missing_call_register_effect_is_rejected(self) -> None:
        result = complete_result(diamond_graph(call=True))
        result["registerAnalysis"]["callEffects"] = []
        result["resourceUsage"]["callRegisterEffectCount"] = 0
        result["resourceUsage"]["callRegisterInputSliceCount"] = 0
        result["resourceUsage"]["callRegisterClobberSliceCount"] = 0
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "cover every call"):
            validate_result(result)

    def test_unknown_register_analysis_field_is_rejected(self) -> None:
        result = complete_result(diamond_graph())
        result["registerAnalysis"]["model"]["unexpected"] = True
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "unknown fields"):
            validate_result(result)

    def test_register_resource_counts_are_verified(self) -> None:
        result = complete_result(diamond_graph(call=True))
        result["resourceUsage"]["callRegisterClobberSliceCount"] -= 1
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "resourceUsage"):
            validate_result(result)

    def test_call_input_resource_count_is_verified(self) -> None:
        result = complete_result(diamond_graph(call=True))
        result["resourceUsage"]["callRegisterInputSliceCount"] -= 1
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "resourceUsage"):
            validate_result(result)

    def test_content_hash_mismatch_is_rejected(self) -> None:
        result = complete_result(diamond_graph())
        result["requestId"] = "mutated-request"
        with self.assertRaisesRegex(ResultValidationError, "contentHash"):
            validate_result(result)

    def test_missing_call_record_is_rejected_even_with_recomputed_hash(self) -> None:
        result = complete_result(diamond_graph(call=True))
        result["calls"] = []
        result["resourceUsage"]["callCount"] = 0
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "cover every call"):
            validate_result(result)

    def test_function_source_hash_mismatch_is_rejected(self) -> None:
        result = complete_result(diamond_graph())
        result["function"]["sourceSha256"] = "f" * 64
        rehash(result)
        request, result = synthetic_request_and_result()
        result["function"]["sourceSha256"] = "f" * 64
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "function bytes"):
            validate_result(result, request=request)

    def test_unknown_nested_field_is_rejected_even_with_recomputed_hash(self) -> None:
        result = complete_result(diamond_graph())
        result["instructions"][0]["unexpected"] = True
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "unknown fields"):
            validate_result(result)

    def test_cfg_edge_semantics_cannot_be_forged_with_recomputed_hash(self) -> None:
        result = complete_result(diamond_graph())
        result["edges"][0]["kind"] = "branchFalse"
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "terminator"):
            validate_result(result)

    def test_resource_byte_counts_are_verified(self) -> None:
        result = complete_result(diamond_graph())
        result["resourceUsage"]["mappedByteCount"] += 4
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "mappedByteCount"):
            validate_result(result)

    def test_complete_result_can_be_bound_to_exact_request_authority(self) -> None:
        request, result = synthetic_request_and_result()
        validate_result(result, request=request)

    def test_patched_result_can_be_bound_to_exact_request_authority(self) -> None:
        request, result = synthetic_request_and_result(with_data_fixup=True)
        validate_result(result, request=request)
        self.assertEqual(result["loadImage"]["patches"][0]["targetAddress"], "0x4000")
        data_region = result["loadImage"]["memoryRegions"][1]
        self.assertEqual(data_region["appliedPatchIds"], ["patch000000"])
        self.assertNotEqual(data_region["rawSha256"], data_region["effectiveSha256"])

    def test_frozen_load_image_model_cannot_be_forged_with_recomputed_hash(self) -> None:
        result = complete_result(diamond_graph())
        result["loadImage"]["model"]["patchPolicy"] = "accept-unverified-patches"
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "frozen DCP-03B2 model"):
            validate_result(result)

    def test_unpatched_effective_region_hash_must_equal_raw_hash(self) -> None:
        result = complete_result(diamond_graph())
        result["loadImage"]["memoryRegions"][0]["effectiveSha256"] = "f" * 64
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "unpatched effective memory-region"):
            validate_result(result)

    def test_required_effective_image_warning_cannot_be_suppressed(self) -> None:
        result = complete_result(diamond_graph())
        result["warnings"] = [
            warning
            for warning in result["warnings"]
            if warning["code"] != "capability.relocation_subset_only"
        ]
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "deterministic capability/evidence"):
            validate_result(result)

    def test_patch_must_match_its_fixup_evidence_even_without_request(self) -> None:
        _, result = synthetic_request_and_result(with_data_fixup=True)
        result["loadImage"]["patches"][0]["targetAddress"] = "0x5000"
        result["loadImage"]["patches"][0]["effectiveBytesHex"] = (
            0x5000
        ).to_bytes(8, "little").hex()
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "fixup evidence record"):
            validate_result(result)

    def test_patch_effective_bytes_must_encode_claimed_target_without_request(self) -> None:
        _, result = synthetic_request_and_result(with_data_fixup=True)
        result["loadImage"]["patches"][0]["effectiveBytesHex"] = (
            0x5000
        ).to_bytes(8, "little").hex()
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "encode the claimed target"):
            validate_result(result)

    def test_patch_source_index_must_reference_exact_evidence_record(self) -> None:
        _, result = synthetic_request_and_result(with_data_fixup=True)
        result["loadImage"]["patches"][0]["sourceIndex"] = 1
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "unknown fixup evidence"):
            validate_result(result)

    def test_every_address_metadata_record_must_be_accounted_for(self) -> None:
        _, result = synthetic_request_and_result(with_data_fixup=True)
        result["loadImage"]["patches"] = []
        result["loadImage"]["memoryRegions"][1]["appliedPatchIds"] = []
        result["loadImage"]["memoryRegions"][1]["effectiveSha256"] = (
            result["loadImage"]["memoryRegions"][1]["rawSha256"]
        )
        result["resourceUsage"]["appliedPatchCount"] = 0
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "cover every relocation and fixup"):
            validate_result(result)

    def test_patch_region_ownership_cannot_be_redirected(self) -> None:
        _, result = synthetic_request_and_result(with_data_fixup=True)
        result["loadImage"]["memoryRegions"][0]["appliedPatchIds"] = ["patch000000"]
        result["loadImage"]["memoryRegions"][1]["appliedPatchIds"] = []
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "patch ownership"):
            validate_result(result)

    def test_unknown_patch_field_is_rejected(self) -> None:
        _, result = synthetic_request_and_result(with_data_fixup=True)
        result["loadImage"]["patches"][0]["opaque"] = True
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "unknown fields"):
            validate_result(result)

    def test_request_rederivation_rejects_forged_patch_with_recomputed_hash(self) -> None:
        request, result = synthetic_request_and_result(with_data_fixup=True)
        patch = result["loadImage"]["patches"][0]
        patch["targetAddress"] = "0x5000"
        patch["effectiveBytesHex"] = (0x5000).to_bytes(8, "little").hex()
        result["evidenceInputs"]["fixups"][0]["targetAddress"] = "0x5000"
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "request-derived effective memory"):
            validate_result(result, request=request)

    def test_forged_evidence_is_rejected_against_exact_request_authority(self) -> None:
        request, result = synthetic_request_and_result()
        result["evidenceInputs"]["symbols"][0]["name"] = "_forged"
        result["calls"][0]["targetSymbol"]["name"] = "_forged"
        rehash(result)
        with self.assertRaisesRegex(ResultValidationError, "request symbol evidence|evidenceInputs"):
            validate_result(result, request=request)

    def test_forged_memory_region_is_rejected_against_exact_request_authority(self) -> None:
        request, result = synthetic_request_and_result()
        result["image"]["memoryRegions"][0]["sha256"] = "f" * 64
        rehash(result)
        with self.assertRaisesRegex(
            ResultValidationError,
            "memory region|memoryRegions|request authority",
        ):
            validate_result(result, request=request)


if __name__ == "__main__":
    unittest.main()
