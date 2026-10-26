from __future__ import annotations

import copy
import pathlib
import random
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOOL_ROOT = ROOT / "Tools" / "DecompilerCoreProof"
sys.path.insert(0, str(TOOL_ROOT))

from macscope_decompiler_proof.register_dataflow import (
    DARWIN_CALL_GPR_CLOBBERS,
    DARWIN_CALL_GPR_INPUTS,
    DARWIN_CALL_SIMD_INPUTS,
    REGISTER_MODEL,
    RegisterDataflowDerivationError,
    derive_register_analysis,
)


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
    size: int,
    register_name: str | None = None,
) -> dict[str, object]:
    return {
        "id": identifier,
        "space": "register" if storage_class == "register" else "const",
        "offset": f"0x{offset:x}",
        "size": size,
        "storageClass": storage_class,
        "registerName": register_name,
        "scopeInstructionAddress": None,
    }


def operation(
    identifier: str,
    index: int,
    opcode: str,
    *,
    inputs: list[str],
    output: str | None,
    direct_target: str | None = None,
) -> dict[str, object]:
    return {
        "id": identifier,
        "instructionIndex": index,
        "sequence": 0,
        "opcode": opcode,
        "output": output,
        "inputs": inputs,
        "directTargetAddress": direct_target,
        "sourceRange": source_range(0x1000 + index * 4),
    }


def block(
    address: int,
    indices: list[int],
    *,
    predecessors: list[str] | None = None,
    successors: list[str] | None = None,
) -> dict[str, object]:
    return {
        "id": f"bb_{address:x}",
        "startAddress": f"0x{address:x}",
        "endAddressExclusive": f"0x{address + 4 * len(indices):x}",
        "instructionIndices": indices,
        "predecessorEdgeIds": predecessors or [],
        "successorEdgeIds": successors or [],
        "terminator": {
            "kind": "functionEnd",
            "pcodeOpId": None,
            "directTargetAddress": None,
        },
    }


def derive(graph: dict[str, object]) -> dict[str, object]:
    return derive_register_analysis(
        values=graph["values"],
        pcode_ops=graph["pcodeOps"],
        basic_blocks=graph["basicBlocks"],
        edges=graph["edges"],
        function_entry=0x1000,
    )


def straight_line_graph(*, call: bool = False, indirect: bool = False) -> dict[str, object]:
    values = [
        value("v000000", storage_class="register", offset=0x4000, size=4, register_name="w0"),
        value("v000001", storage_class="register", offset=0x4000, size=8, register_name="x0"),
        value("v000002", storage_class="constant", offset=1, size=8),
        value("v000003", storage_class="register", offset=0x4008, size=8, register_name="x1"),
        value("v000004", storage_class="register", offset=0x4048, size=8, register_name="x9"),
        value("v000005", storage_class="register", offset=0x4098, size=8, register_name="x19"),
    ]
    operations = [
        operation("op000000", 0, "COPY", inputs=["v000002"], output="v000000"),
    ]
    if call:
        operations.append(
            operation(
                "op000001",
                1,
                "CALLIND" if indirect else "CALL",
                inputs=["v000004"] if indirect else ["v000002"],
                output=None,
                direct_target=None if indirect else "0x2000",
            )
        )
        operations.extend(
            [
                operation("op000002", 2, "INT_ADD", inputs=["v000001", "v000002"], output="v000003"),
                operation("op000003", 3, "INT_ADD", inputs=["v000005", "v000002"], output="v000003"),
            ]
        )
    else:
        operations.append(
            operation("op000001", 1, "INT_ADD", inputs=["v000001", "v000002"], output="v000003")
        )
    return {
        "values": values,
        "pcodeOps": operations,
        "basicBlocks": [block(0x1000, list(range(len(operations))))],
        "edges": [],
    }


def alias_diamond_graph() -> dict[str, object]:
    values = [
        value("v000000", storage_class="register", offset=0x4000, size=4, register_name="w0"),
        value("v000001", storage_class="register", offset=0x4000, size=8, register_name="x0"),
        value("v000002", storage_class="constant", offset=1, size=8),
        value("v000003", storage_class="register", offset=0x4008, size=8, register_name="x1"),
    ]
    operations = [
        operation("op000000", 0, "CBRANCH", inputs=["v000002"], output=None, direct_target="0x100c"),
        operation("op000001", 1, "COPY", inputs=["v000002"], output="v000000"),
        operation("op000002", 2, "BRANCH", inputs=[], output=None, direct_target="0x1010"),
        operation("op000003", 3, "COPY", inputs=["v000002"], output="v000001"),
        operation("op000004", 4, "COPY", inputs=["v000001"], output="v000003"),
    ]
    edges = [
        {"id": "edge000000", "sourceBlockId": "bb_1000", "targetBlockId": "bb_100c", "targetAddress": "0x100c", "kind": "branchTrue", "pcodeOpId": "op000000"},
        {"id": "edge000001", "sourceBlockId": "bb_1000", "targetBlockId": "bb_1004", "targetAddress": "0x1004", "kind": "branchFalse", "pcodeOpId": "op000000"},
        {"id": "edge000002", "sourceBlockId": "bb_1004", "targetBlockId": "bb_1010", "targetAddress": "0x1010", "kind": "branch", "pcodeOpId": "op000002"},
        {"id": "edge000003", "sourceBlockId": "bb_100c", "targetBlockId": "bb_1010", "targetAddress": "0x1010", "kind": "fallthrough", "pcodeOpId": None},
    ]
    blocks = [
        block(0x1000, [0], successors=["edge000000", "edge000001"]),
        block(0x1004, [1, 2], predecessors=["edge000001"], successors=["edge000002"]),
        block(0x100C, [3], predecessors=["edge000000"], successors=["edge000003"]),
        block(0x1010, [4], predecessors=["edge000002", "edge000003"]),
    ]
    return {"values": values, "pcodeOps": operations, "basicBlocks": blocks, "edges": edges}


def loop_graph(*, entry_header: bool) -> dict[str, object]:
    values = [
        value("v000000", storage_class="register", offset=0x4000, size=4, register_name="w0"),
        value("v000001", storage_class="register", offset=0x4000, size=8, register_name="x0"),
        value("v000002", storage_class="constant", offset=1, size=8),
        value("v000003", storage_class="register", offset=0x4008, size=8, register_name="x1"),
    ]
    if entry_header:
        operations = [
            operation("op000000", 0, "CBRANCH", inputs=["v000002"], output=None, direct_target="0x1008"),
            operation("op000001", 1, "COPY", inputs=["v000002"], output="v000000"),
            operation("op000002", 2, "BRANCH", inputs=[], output=None, direct_target="0x1000"),
            operation("op000003", 3, "COPY", inputs=["v000001"], output="v000003"),
        ]
        edges = [
            {"id": "edge000000", "sourceBlockId": "bb_1000", "targetBlockId": "bb_1008", "targetAddress": "0x1008", "kind": "branchTrue", "pcodeOpId": "op000000"},
            {"id": "edge000001", "sourceBlockId": "bb_1000", "targetBlockId": "bb_1004", "targetAddress": "0x1004", "kind": "branchFalse", "pcodeOpId": "op000000"},
            {"id": "edge000002", "sourceBlockId": "bb_1004", "targetBlockId": "bb_1000", "targetAddress": "0x1000", "kind": "branch", "pcodeOpId": "op000002"},
        ]
        blocks = [
            block(0x1000, [0], predecessors=["edge000002"], successors=["edge000000", "edge000001"]),
            block(0x1004, [1, 2], predecessors=["edge000001"], successors=["edge000002"]),
            block(0x1008, [3], predecessors=["edge000000"]),
        ]
    else:
        operations = [
            operation("op000000", 0, "BRANCH", inputs=[], output=None, direct_target="0x1004"),
            operation("op000001", 1, "CBRANCH", inputs=["v000002"], output=None, direct_target="0x100c"),
            operation("op000002", 2, "COPY", inputs=["v000002"], output="v000000"),
            operation("op000003", 3, "BRANCH", inputs=[], output=None, direct_target="0x1004"),
            operation("op000004", 4, "COPY", inputs=["v000001"], output="v000003"),
        ]
        edges = [
            {"id": "edge000000", "sourceBlockId": "bb_1000", "targetBlockId": "bb_1004", "targetAddress": "0x1004", "kind": "branch", "pcodeOpId": "op000000"},
            {"id": "edge000001", "sourceBlockId": "bb_1004", "targetBlockId": "bb_100c", "targetAddress": "0x100c", "kind": "branchTrue", "pcodeOpId": "op000001"},
            {"id": "edge000002", "sourceBlockId": "bb_1004", "targetBlockId": "bb_1008", "targetAddress": "0x1008", "kind": "branchFalse", "pcodeOpId": "op000001"},
            {"id": "edge000003", "sourceBlockId": "bb_1008", "targetBlockId": "bb_1004", "targetAddress": "0x1004", "kind": "branch", "pcodeOpId": "op000003"},
        ]
        blocks = [
            block(0x1000, [0], successors=["edge000000"]),
            block(0x1004, [1], predecessors=["edge000000", "edge000003"], successors=["edge000001", "edge000002"]),
            block(0x1008, [2, 3], predecessors=["edge000002"], successors=["edge000003"]),
            block(0x100C, [4], predecessors=["edge000001"]),
        ]
    return {"values": values, "pcodeOps": operations, "basicBlocks": blocks, "edges": edges}


class AArch64RegisterDataflowTests(unittest.TestCase):
    def test_model_is_explicitly_partial(self) -> None:
        self.assertEqual(REGISTER_MODEL["gprCanonicalWidthBits"], 64)
        self.assertEqual(REGISTER_MODEL["simdSsaCoverage"], "none")
        self.assertEqual(REGISTER_MODEL["conditionFlagSsaCoverage"], "none")
        self.assertEqual(
            REGISTER_MODEL["callExcludedState"],
            "sve-sme-fpsr-fpcr-fpmr-system-registers",
        )

    def test_x_and_w_views_share_one_canonical_family(self) -> None:
        result = derive(straight_line_graph())
        views = {item["viewName"]: item for item in result["views"]}
        self.assertEqual(views["x0"]["canonicalRegister"], "x0")
        self.assertEqual(views["w0"]["canonicalRegister"], "x0")
        self.assertEqual(views["x0"]["writeTransform"], "replace")
        self.assertEqual(views["w0"]["writeTransform"], "zeroExtend")

    def test_w_write_defines_the_x_parent_version(self) -> None:
        result = derive(straight_line_graph())
        write = result["bindings"][0]["write"]
        read = result["bindings"][1]["reads"][0]
        self.assertEqual(write["canonicalRegister"], "x0")
        self.assertEqual(write["writeTransform"], "zeroExtend")
        self.assertEqual(read["canonicalRegister"], "x0")
        self.assertEqual(read["readTransform"], "identity")
        self.assertEqual(read["inputRegisterVersionId"], write["outputRegisterVersionId"])

    def test_call_reads_indirect_target_before_applying_clobbers(self) -> None:
        result = derive(straight_line_graph(call=True, indirect=True))
        call_binding = result["bindings"][1]
        target_read = call_binding["reads"][0]
        self.assertEqual(target_read["canonicalRegister"], "x9")
        x9_clobber = next(
            version_id
            for version_id in call_binding["callClobberRegisterVersionIds"]
            if next(item for item in result["versions"] if item["id"] == version_id)["canonicalRegister"] == "x9"
        )
        self.assertNotEqual(target_read["inputRegisterVersionId"], x9_clobber)

    def test_call_clobber_reaches_later_x0_read_but_preserves_x19(self) -> None:
        result = derive(straight_line_graph(call=True))
        call_binding = result["bindings"][1]
        versions = {item["id"]: item for item in result["versions"]}
        x0_clobber = next(
            version_id
            for version_id in call_binding["callClobberRegisterVersionIds"]
            if versions[version_id]["canonicalRegister"] == "x0"
        )
        self.assertEqual(result["bindings"][2]["reads"][0]["inputRegisterVersionId"], x0_clobber)
        x19_read = result["bindings"][3]["reads"][0]
        self.assertEqual(versions[x19_read["inputRegisterVersionId"]]["kind"], "functionEntry")

    def test_call_clobbers_x30_but_preserves_sp_and_x19(self) -> None:
        graph = straight_line_graph(call=True)
        graph["values"].extend(
            [
                value(
                    "v000006",
                    storage_class="register",
                    offset=0x40F0,
                    size=8,
                    register_name="x30",
                ),
                value(
                    "v000007",
                    storage_class="register",
                    offset=0x8,
                    size=8,
                    register_name="sp",
                ),
            ]
        )
        graph["pcodeOps"][2]["inputs"][0] = "v000006"
        graph["pcodeOps"].append(
            operation(
                "op000004",
                4,
                "INT_ADD",
                inputs=["v000007", "v000002"],
                output="v000003",
            )
        )
        graph["basicBlocks"][0]["instructionIndices"].append(4)
        graph["basicBlocks"][0]["endAddressExclusive"] = "0x1014"

        result = derive(graph)
        versions = {item["id"]: item for item in result["versions"]}
        call_binding = result["bindings"][1]
        clobbers = {
            versions[version_id]["canonicalRegister"]: version_id
            for version_id in call_binding["callClobberRegisterVersionIds"]
        }
        self.assertEqual(
            result["bindings"][2]["reads"][0]["inputRegisterVersionId"],
            clobbers["x30"],
        )
        self.assertEqual(
            versions[result["bindings"][3]["reads"][0]["inputRegisterVersionId"]]["kind"],
            "functionEntry",
        )
        self.assertEqual(
            versions[result["bindings"][4]["reads"][0]["inputRegisterVersionId"]]["kind"],
            "functionEntry",
        )

    def test_darwin_call_effect_contains_exact_modeled_inputs_and_clobbers(self) -> None:
        result = derive(straight_line_graph(call=True))
        effect = result["callEffects"][0]
        versions = {item["id"]: item for item in result["versions"]}
        first_write = result["bindings"][0]["write"]
        self.assertIsNotNone(first_write)
        inputs = effect["inputs"]
        self.assertEqual(len(inputs), 19)
        self.assertEqual(
            [item["registerName"] for item in inputs],
            [*DARWIN_CALL_GPR_INPUTS, *DARWIN_CALL_SIMD_INPUTS],
        )
        self.assertTrue(
            all(
                item["inputRegisterVersionId"] is not None
                for item in inputs[: len(DARWIN_CALL_GPR_INPUTS)]
            )
        )
        self.assertTrue(
            all(
                item["inputRegisterVersionId"] is None
                for item in inputs[len(DARWIN_CALL_GPR_INPUTS) :]
            )
        )
        self.assertEqual(
            next(item for item in inputs if item["registerName"] == "x8")["reason"],
            "possibleIndirectResultLocation",
        )
        self.assertEqual(
            next(item for item in inputs if item["registerName"] == "x30")["reason"],
            "linkRegister",
        )
        self.assertEqual(
            next(item for item in inputs if item["registerName"] == "sp")["reason"],
            "stackPointer",
        )
        x0_input = next(item for item in inputs if item["registerName"] == "x0")
        self.assertEqual(
            x0_input["inputRegisterVersionId"],
            first_write["outputRegisterVersionId"],
        )
        self.assertEqual(
            versions[x0_input["inputRegisterVersionId"]]["kind"],
            "pcodeWrite",
        )
        clobbers = effect["clobbers"]
        self.assertEqual(len(clobbers), 56)
        gprs = [item for item in clobbers if item["registerClass"] == "generalPurpose"]
        self.assertEqual([item["registerName"] for item in gprs], list(DARWIN_CALL_GPR_CLOBBERS))
        self.assertEqual(gprs[-2]["reason"], "platformReserved")
        self.assertEqual(gprs[-1]["reason"], "linkRegisterCallerSaved")
        v8 = next(item for item in clobbers if item["registerName"] == "v8")
        v16 = next(item for item in clobbers if item["registerName"] == "v16")
        self.assertEqual((v8["bitOffset"], v8["bitWidth"]), (64, 64))
        self.assertEqual((v16["bitOffset"], v16["bitWidth"]), (0, 128))
        flags = [item["registerName"] for item in clobbers if item["registerClass"] == "conditionFlag"]
        self.assertEqual(flags, ["N", "Z", "C", "V"])

    def test_alias_writes_merge_through_one_canonical_phi(self) -> None:
        result = derive(alias_diamond_graph())
        self.assertEqual(len(result["phis"]), 1)
        phi = result["phis"][0]
        self.assertEqual(phi["canonicalRegister"], "x0")
        read = result["bindings"][-1]["reads"][0]
        self.assertEqual(read["inputRegisterVersionId"], phi["outputRegisterVersionId"])
        incoming_versions = {item["registerVersionId"] for item in phi["incoming"]}
        self.assertEqual(len(incoming_versions), 2)

    def test_wsp_write_zero_extends_into_sp_parent(self) -> None:
        graph = {
            "values": [
                value("v000000", storage_class="register", offset=0x8, size=4, register_name="wsp"),
                value("v000001", storage_class="register", offset=0x8, size=8, register_name="sp"),
                value("v000002", storage_class="constant", offset=1, size=8),
                value("v000003", storage_class="register", offset=0x4000, size=8, register_name="x0"),
            ],
            "pcodeOps": [
                operation("op000000", 0, "COPY", inputs=["v000002"], output="v000000"),
                operation("op000001", 1, "COPY", inputs=["v000001"], output="v000003"),
            ],
            "basicBlocks": [block(0x1000, [0, 1])],
            "edges": [],
        }
        result = derive(graph)
        write = result["bindings"][0]["write"]
        read = result["bindings"][1]["reads"][0]
        self.assertEqual(write["canonicalRegister"], "sp")
        self.assertEqual(write["writeTransform"], "zeroExtend")
        self.assertEqual(read["inputRegisterVersionId"], write["outputRegisterVersionId"])

    def test_x_write_reaches_w_read_through_low_bits_view(self) -> None:
        graph = straight_line_graph()
        graph["pcodeOps"][0]["output"] = "v000001"
        graph["pcodeOps"][1]["inputs"][0] = "v000000"
        result = derive(graph)
        write = result["bindings"][0]["write"]
        read = result["bindings"][1]["reads"][0]
        self.assertEqual(write["writeTransform"], "replace")
        self.assertEqual(read["readTransform"], "lowBits")
        self.assertEqual(read["inputRegisterVersionId"], write["outputRegisterVersionId"])

    def test_zero_register_views_remain_outside_partial_gpr_ssa(self) -> None:
        graph = {
            "values": [
                value("v000000", storage_class="register", offset=0, size=8, register_name="xzr"),
                value("v000001", storage_class="register", offset=0, size=4, register_name="wzr"),
            ],
            "pcodeOps": [
                operation("op000000", 0, "COPY", inputs=["v000000"], output="v000001"),
            ],
            "basicBlocks": [block(0x1000, [0])],
            "edges": [],
        }
        result = derive(graph)
        self.assertEqual(result["views"], [])
        self.assertEqual(result["versions"], [])
        self.assertEqual(result["bindings"][0]["reads"], [])
        self.assertIsNone(result["bindings"][0]["write"])

    def test_loop_header_phi_uses_entry_and_backedge_versions(self) -> None:
        result = derive(loop_graph(entry_header=False))
        phi = next(
            item
            for item in result["phis"]
            if item["blockId"] == "bb_1004" and item["canonicalRegister"] == "x0"
        )
        self.assertEqual(
            [(item["sourceKind"], item["sourceBlockId"], item["edgeId"]) for item in phi["incoming"]],
            [
                ("block", "bb_1000", "edge000000"),
                ("block", "bb_1008", "edge000003"),
            ],
        )
        versions = {item["id"]: item for item in result["versions"]}
        incoming_kinds = {versions[item["registerVersionId"]]["kind"] for item in phi["incoming"]}
        self.assertEqual(incoming_kinds, {"functionEntry", "pcodeWrite"})

    def test_entry_loop_phi_retains_function_entry_pseudo_predecessor(self) -> None:
        result = derive(loop_graph(entry_header=True))
        phi = next(
            item
            for item in result["phis"]
            if item["blockId"] == "bb_1000" and item["canonicalRegister"] == "x0"
        )
        self.assertEqual(phi["incoming"][0]["sourceKind"], "functionEntry")
        self.assertIsNone(phi["incoming"][0]["sourceBlockId"])
        self.assertIsNone(phi["incoming"][0]["edgeId"])
        self.assertEqual(phi["incoming"][1]["sourceBlockId"], "bb_1004")
        self.assertEqual(phi["incoming"][1]["edgeId"], "edge000002")

    def test_orphan_cfg_edge_fails_closed(self) -> None:
        graph = alias_diamond_graph()
        graph["basicBlocks"][0]["successorEdgeIds"].remove("edge000000")
        with self.assertRaisesRegex(
            RegisterDataflowDerivationError,
            "successor edges are incomplete or inconsistent",
        ):
            derive(graph)

    def test_unknown_cfg_target_fails_closed(self) -> None:
        graph = alias_diamond_graph()
        graph["edges"][0]["targetBlockId"] = "bb_dead"
        with self.assertRaisesRegex(RegisterDataflowDerivationError, "unknown target block"):
            derive(graph)

    def test_duplicate_cfg_adjacency_fails_closed(self) -> None:
        graph = alias_diamond_graph()
        graph["basicBlocks"][0]["successorEdgeIds"].append("edge000000")
        with self.assertRaisesRegex(RegisterDataflowDerivationError, "duplicate edges"):
            derive(graph)

    def test_function_entry_must_identify_exactly_one_block(self) -> None:
        graph = straight_line_graph()
        graph["basicBlocks"][0]["startAddress"] = "0x1004"
        with self.assertRaisesRegex(RegisterDataflowDerivationError, "exactly one basic block"):
            derive(graph)

    def test_malformed_sleigh_offset_fails_closed(self) -> None:
        graph = straight_line_graph()
        graph["values"][0]["offset"] = "0x4008"
        with self.assertRaisesRegex(RegisterDataflowDerivationError, "SLEIGH offset"):
            derive(graph)

    def test_output_is_independent_of_input_collection_order(self) -> None:
        graph = alias_diamond_graph()
        expected = derive(graph)
        shuffled = copy.deepcopy(graph)
        random.Random(23).shuffle(shuffled["values"])
        random.Random(29).shuffle(shuffled["pcodeOps"])
        random.Random(31).shuffle(shuffled["basicBlocks"])
        random.Random(37).shuffle(shuffled["edges"])
        for item in shuffled["basicBlocks"]:
            random.Random(41 + int(item["startAddress"], 16)).shuffle(item["predecessorEdgeIds"])
            random.Random(43 + int(item["startAddress"], 16)).shuffle(item["successorEdgeIds"])
        self.assertEqual(derive(shuffled), expected)


if __name__ == "__main__":
    unittest.main()
