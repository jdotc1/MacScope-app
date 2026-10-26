from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
TOOL_ROOT = ROOT / "Tools" / "DecompilerCoreProof"
FIXTURE_PATH = TOOL_ROOT / "fixtures" / "conditional-call.request.json"
EXPECTED_PATH = TOOL_ROOT / "fixtures" / "conditional-call.expected-semantics.json"
sys.path.insert(0, str(TOOL_ROOT))

from macscope_decompiler_proof.canonical import canonical_json_bytes, canonical_sha256
from macscope_decompiler_proof.contract import RESULT_SCHEMA_VERSION
from macscope_decompiler_proof.engine import analyze_request
from macscope_decompiler_proof.errors import (
    BudgetExceededError,
    CancelledError,
    LiftError,
    RequestValidationError,
)
from macscope_decompiler_proof.request import parse_request_bytes
from macscope_decompiler_proof.result_validation import (
    ResultValidationError,
    validate_result,
)


def fixture_value() -> dict[str, object]:
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


def request_from(value: dict[str, object]):
    return parse_request_bytes(json.dumps(value, separators=(",", ":")).encode("utf-8"))


class DCP03RequestTests(unittest.TestCase):
    def test_valid_fixture_is_canonicalized_and_fully_mapped(self) -> None:
        request = parse_request_bytes(FIXTURE_PATH.read_bytes())
        self.assertEqual(request.function_size, 28)
        self.assertEqual(len(request.read(request.function_entry, request.function_end, require_executable=True)), 28)
        self.assertEqual(request.symbol_at(0x10000101C).name, "_helper")
        self.assertEqual(request.canonical_input["memoryRegions"][0]["startAddress"], "0x100001000")
        self.assertEqual(len(request.request_sha256), 64)

    def test_duplicate_json_key_is_rejected(self) -> None:
        with self.assertRaisesRegex(RequestValidationError, "duplicate JSON key"):
            parse_request_bytes(b'{"schemaVersion":1,"schemaVersion":1}')

    def test_unknown_top_level_key_is_rejected(self) -> None:
        value = fixture_value()
        value["unexpected"] = True
        with self.assertRaisesRegex(RequestValidationError, "unknown keys"):
            request_from(value)

    def test_control_and_surrogate_text_are_rejected(self) -> None:
        for invalid in ("bad\tname", "bad\ud800name"):
            with self.subTest(invalid=repr(invalid)):
                value = fixture_value()
                value["function"]["name"] = invalid
                with self.assertRaisesRegex(RequestValidationError, "control or surrogate"):
                    request_from(value)

    def test_schema_version_rejects_boolean_and_float_aliases(self) -> None:
        for invalid in (True, 1.0):
            with self.subTest(invalid=invalid):
                value = fixture_value()
                value["schemaVersion"] = invalid
                with self.assertRaisesRegex(RequestValidationError, "unsupported schemaVersion"):
                    request_from(value)

    def test_noncanonical_address_is_rejected(self) -> None:
        value = fixture_value()
        value["function"]["entryAddress"] = "0x0100001000"
        with self.assertRaisesRegex(RequestValidationError, "canonical lowercase hexadecimal"):
            request_from(value)

    def test_overlapping_memory_regions_are_rejected(self) -> None:
        value = fixture_value()
        value["memoryRegions"].append(
            {
                "name": "overlap",
                "startAddress": "0x100001004",
                "permissions": "r-x",
                "bytesHex": "1f2003d5",
            }
        )
        with self.assertRaisesRegex(RequestValidationError, "overlap"):
            request_from(value)

    def test_memory_region_end_cannot_overflow_uint64(self) -> None:
        value = fixture_value()
        value["memoryRegions"] = [
            {
                "name": "overflow",
                "startAddress": "0xffffffffffffffff",
                "permissions": "r-x",
                "bytesHex": "00",
            }
        ]
        with self.assertRaisesRegex(RequestValidationError, "overflows unsigned 64-bit"):
            request_from(value)

    def test_unmapped_function_range_is_rejected(self) -> None:
        value = fixture_value()
        value["function"]["endAddressExclusive"] = "0x100001028"
        with self.assertRaisesRegex(RequestValidationError, "not fully mapped"):
            request_from(value)

    def test_non_executable_function_range_is_rejected(self) -> None:
        value = fixture_value()
        value["memoryRegions"][0]["permissions"] = "rw-"
        with self.assertRaisesRegex(RequestValidationError, "non-executable"):
            request_from(value)

    def test_symbol_from_different_image_is_rejected(self) -> None:
        value = fixture_value()
        value["symbols"][0]["imageId"] = "other-image"
        with self.assertRaisesRegex(RequestValidationError, "different image"):
            request_from(value)

    def test_unsupported_mapped_relocation_fails_before_dependency_load(self) -> None:
        value = fixture_value()
        value["relocations"] = [
            {
                "address": "0x100001008",
                "kind": "ARM64_RELOC_UNSUPPORTED",
                "targetAddress": "0x10000101c",
                "symbol": "_helper",
                "addend": 0,
            }
        ]
        with self.assertRaisesRegex(LiftError, "unsupported mapped relocation kind"):
            analyze_request(request_from(value))

    def test_preexisting_cancellation_file_fails_before_dependency_load(self) -> None:
        request = parse_request_bytes(FIXTURE_PATH.read_bytes())
        with tempfile.TemporaryDirectory() as directory:
            sentinel = pathlib.Path(directory) / "cancel"
            sentinel.write_text("cancel", encoding="utf-8")
            with self.assertRaises(CancelledError):
                analyze_request(request, cancellation_path=sentinel)

    def test_wall_budget_guard_is_fail_closed(self) -> None:
        request = parse_request_bytes(FIXTURE_PATH.read_bytes())
        moments = iter((0.0, 100.0))
        with self.assertRaisesRegex(BudgetExceededError, "wall time"):
            analyze_request(request, clock=lambda: next(moments))

    def test_request_and_result_schemas_are_valid_json(self) -> None:
        for filename in ("request.schema.json", "result.schema.json"):
            value = json.loads((TOOL_ROOT / "schemas" / filename).read_text(encoding="utf-8"))
            self.assertEqual(value["$schema"], "https://json-schema.org/draft/2020-12/schema")
            self.assertFalse(value["additionalProperties"])

    def test_every_result_object_schema_is_closed(self) -> None:
        schema = json.loads((TOOL_ROOT / "schemas" / "result.schema.json").read_text(encoding="utf-8"))

        def visit(value: object, path: str) -> None:
            if isinstance(value, dict):
                if value.get("type") == "object":
                    self.assertIs(
                        value.get("additionalProperties"),
                        False,
                        f"open object schema at {path}",
                    )
                for key, child in value.items():
                    visit(child, f"{path}/{key}")
            elif isinstance(value, list):
                for index, child in enumerate(value):
                    visit(child, f"{path}/{index}")

        visit(schema, "$")

    @unittest.skipUnless(importlib.util.find_spec("jsonschema") is not None, "jsonschema is unavailable")
    def test_result_schema_is_valid_draft_2020_12(self) -> None:
        import jsonschema

        schema = json.loads((TOOL_ROOT / "schemas" / "result.schema.json").read_text(encoding="utf-8"))
        jsonschema.Draft202012Validator.check_schema(schema)

    def test_supervisor_resolves_relative_cancellation_path_before_launch(self) -> None:
        supervisor = ROOT / "Scripts" / "decompiler-proof" / "run_dcp03_proof.py"
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "cancel").write_text("cancel", encoding="utf-8")
            output = root / "result.json"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(supervisor),
                    "--python",
                    sys.executable,
                    "--input",
                    str(FIXTURE_PATH),
                    "--output",
                    str(output),
                    "--cancel-file",
                    "cancel",
                ],
                check=False,
                capture_output=True,
                cwd=root,
            )
            self.assertEqual(completed.returncode, 6, completed.stderr.decode("utf-8", errors="replace"))
            self.assertFalse(output.exists())
            error = json.loads(completed.stderr)
            self.assertEqual(error["error"]["code"], "analysis.cancelled")

    def test_supervisor_rejects_child_result_bound_to_another_request(self) -> None:
        supervisor = ROOT / "Scripts" / "decompiler-proof" / "run_dcp03_proof.py"
        request = parse_request_bytes(FIXTURE_PATH.read_bytes())
        forged: dict[str, object] = {
            "schemaVersion": RESULT_SCHEMA_VERSION,
            "status": "ok",
            "requestId": request.request_id,
            "requestSha256": "0" * 64,
        }
        forged["contentHash"] = canonical_sha256(forged)
        payload = canonical_json_bytes(forged)
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fake_python = root / "fake-python"
            fake_python.write_text(
                "#!/bin/sh\n"
                "cat <<'MACSCOPE_RESULT_EOF'\n"
                + payload.decode("utf-8")
                + "MACSCOPE_RESULT_EOF\n",
                encoding="utf-8",
            )
            fake_python.chmod(0o755)
            output = root / "result.json"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(supervisor),
                    "--python",
                    str(fake_python),
                    "--input",
                    str(FIXTURE_PATH),
                    "--output",
                    str(output),
                ],
                check=False,
                capture_output=True,
                cwd=ROOT,
            )
            self.assertEqual(completed.returncode, 70)
            self.assertFalse(output.exists())
            error = json.loads(completed.stderr)
            self.assertEqual(error["error"]["code"], "child.invalid_output")
            self.assertIn("requestSha256", error["error"]["message"])


class DCP03SupervisorBoundaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.supervisor = ROOT / "Scripts" / "decompiler-proof" / "run_dcp03_proof.py"

    def _fake_python(self, root: pathlib.Path, body: str) -> pathlib.Path:
        path = root / "fake-python"
        path.write_text(f"#!/bin/sh\n{body}", encoding="utf-8")
        path.chmod(0o755)
        return path

    def test_supervisor_does_not_forward_untrusted_child_stderr(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            output = root / "result.json"
            secret = "/private/secret/native-trace"
            fake_python = self._fake_python(
                root,
                f"printf '%s\n' '{secret}' >&2\nexit 4\n",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(self.supervisor),
                    "--python",
                    str(fake_python),
                    "--input",
                    str(FIXTURE_PATH),
                    "--output",
                    str(output),
                ],
                check=False,
                capture_output=True,
                cwd=ROOT,
            )
            self.assertEqual(completed.returncode, 70)
            self.assertFalse(output.exists())
            self.assertNotIn(secret.encode("utf-8"), completed.stderr)
            error = json.loads(completed.stderr)
            self.assertEqual(error["error"]["code"], "child.failed")

    def test_supervisor_rejects_success_result_not_bound_to_request(self) -> None:
        request = parse_request_bytes(FIXTURE_PATH.read_bytes())
        forged: dict[str, object] = {
            "schemaVersion": RESULT_SCHEMA_VERSION,
            "status": "ok",
            "requestId": "wrong-request",
            "requestSha256": request.request_sha256,
        }
        forged["contentHash"] = canonical_sha256(forged)
        forged_payload = canonical_json_bytes(forged)
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            output = root / "result.json"
            fake_python = self._fake_python(
                root,
                "cat <<'MACSCOPE_RESULT_EOF'\n"
                + forged_payload.decode("utf-8")
                + "MACSCOPE_RESULT_EOF\n",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(self.supervisor),
                    "--python",
                    str(fake_python),
                    "--input",
                    str(FIXTURE_PATH),
                    "--output",
                    str(output),
                ],
                check=False,
                capture_output=True,
                cwd=ROOT,
            )
            self.assertEqual(completed.returncode, 70)
            self.assertFalse(output.exists())
            error = json.loads(completed.stderr)
            self.assertEqual(error["error"]["code"], "child.invalid_output")

    def test_supervisor_late_cancellation_does_not_publish_output(self) -> None:
        request = parse_request_bytes(FIXTURE_PATH.read_bytes())
        forged: dict[str, object] = {
            "schemaVersion": RESULT_SCHEMA_VERSION,
            "status": "ok",
            "requestId": request.request_id,
            "requestSha256": request.request_sha256,
            "engine": {
                "languageId": request.language_id,
                "compilerSpecId": request.compiler_spec_id,
            },
            "image": {
                "imageId": request.image_id,
                "uuid": request.image_uuid,
                "preferredLoadAddress": "0x100001000",
            },
            "function": {
                "functionId": request.function_id,
                "name": request.function_name,
                "entryAddress": "0x100001000",
                "endAddressExclusive": "0x10000101c",
            },
        }
        forged["contentHash"] = canonical_sha256(forged)
        forged_payload = canonical_json_bytes(forged)
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            output = root / "result.json"
            cancellation = root / "cancel"
            fake_python = self._fake_python(
                root,
                "cat >/dev/null\n"
                f": > {shlex.quote(str(cancellation))}\n"
                "cat <<'MACSCOPE_RESULT_EOF'\n"
                + forged_payload.decode("utf-8")
                + "MACSCOPE_RESULT_EOF\n",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(self.supervisor),
                    "--python",
                    str(fake_python),
                    "--input",
                    str(FIXTURE_PATH),
                    "--output",
                    str(output),
                    "--cancel-file",
                    str(cancellation),
                ],
                check=False,
                capture_output=True,
                cwd=ROOT,
            )
            self.assertEqual(completed.returncode, 6, completed.stderr.decode("utf-8", errors="replace"))
            self.assertTrue(cancellation.exists())
            self.assertFalse(output.exists())
            error = json.loads(completed.stderr)
            self.assertEqual(error["error"]["code"], "analysis.cancelled")

    def test_supervisor_refuses_to_replace_its_input(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            request_path = pathlib.Path(directory) / "request.json"
            original = FIXTURE_PATH.read_bytes()
            request_path.write_bytes(original)
            completed = subprocess.run(
                [
                    sys.executable,
                    str(self.supervisor),
                    "--python",
                    sys.executable,
                    "--input",
                    str(request_path),
                    "--output",
                    str(request_path),
                ],
                check=False,
                capture_output=True,
                cwd=ROOT,
            )
            self.assertEqual(completed.returncode, 2)
            self.assertEqual(request_path.read_bytes(), original)
            error = json.loads(completed.stderr)
            self.assertEqual(error["error"]["code"], "supervisor.invalid_configuration")

    def test_supervisor_configuration_errors_do_not_leak_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            missing = root / "private" / "missing-request.json"
            output = root / "result.json"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(self.supervisor),
                    "--python",
                    sys.executable,
                    "--input",
                    str(missing),
                    "--output",
                    str(output),
                ],
                check=False,
                capture_output=True,
                cwd=ROOT,
            )
            self.assertEqual(completed.returncode, 2)
            self.assertNotIn(str(missing).encode("utf-8"), completed.stderr)
            error = json.loads(completed.stderr)
            self.assertEqual(error["error"]["code"], "supervisor.invalid_input")


@unittest.skipUnless(importlib.util.find_spec("pypcode") is not None, "pypcode proof dependency is not materialized")
class DCP03DataflowIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.request = parse_request_bytes(FIXTURE_PATH.read_bytes())
        self.expected = json.loads(EXPECTED_PATH.read_text(encoding="utf-8"))

    def test_memory_chain_crossing_a_block_boundary_validates(self) -> None:
        """Regression: a store in one block followed by a load in a later block must validate.

        The result verifier used to compare recorded memory-effect inputs against block states
        inside its fixed-point iteration, before predecessor states had propagated, so every
        function whose MemorySSA chain crossed a block boundary was rejected as malformed.
        """
        request = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        # str x1, [x0] ; cbz x2, +8 ; ldr x3, [x0] ; ret
        code = "010000f9420000b4030040f9c0035fd6"
        request["requestId"] = "fixture-memory-chain"
        request["function"] = {"functionId": "fixture-image:memory-chain", "name": "_memory_chain",
                               "entryAddress": "0x100001000", "endAddressExclusive": "0x100001010"}
        request["memoryRegions"][0]["bytesHex"] = code
        request["symbols"] = [{"imageId": "fixture-image", "address": "0x100001000", "name": "_memory_chain", "kind": "function"}]
        request["typeHints"] = []
        result = analyze_request(parse_request_bytes(json.dumps(request).encode("utf-8")))
        self.assertEqual(result["status"], "ok")
        self.assertEqual(len(result["basicBlocks"]), 3)
        kinds = [item["kind"] for item in result["memoryEffects"]]
        self.assertEqual(kinds, ["write", "read"])
        write, read = result["memoryEffects"]
        self.assertEqual(read["inputMemoryVersionId"], write["outputMemoryVersionId"])

    def test_fixture_semantics_and_capability_boundary(self) -> None:
        result = analyze_request(self.request)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["analysisLevel"], self.expected["analysisLevel"])
        self.assertEqual(result["contractCompleteness"], self.expected["contractCompleteness"])
        self.assertEqual(result["function"]["sourceSha256"], self.expected["functionSourceSha256"])
        self.assertEqual(result["function"]["effectiveSha256"], self.expected["functionSourceSha256"])
        self.assertEqual(result["function"]["appliedPatchIds"], [])
        self.assertEqual(result["loadImage"]["patches"], [])
        self.assertEqual(result["loadImage"]["unmappedEvidence"], [])
        self.assertEqual(result["resourceUsage"]["appliedPatchCount"], 0)
        self.assertEqual(
            [item["address"] for item in result["instructions"]],
            self.expected["instructionAddresses"],
        )
        self.assertEqual(
            [item["mnemonic"] for item in result["instructions"]],
            self.expected["instructionMnemonics"],
        )
        self.assertEqual(
            [
                {
                    "id": item["id"],
                    "instructionIndices": item["instructionIndices"],
                    "terminatorKind": item["terminator"]["kind"],
                }
                for item in result["basicBlocks"]
            ],
            self.expected["basicBlocks"],
        )
        self.assertEqual(
            [
                {
                    "kind": item["kind"],
                    "sourceBlockId": item["sourceBlockId"],
                    "targetBlockId": item["targetBlockId"],
                }
                for item in result["edges"]
            ],
            self.expected["edges"],
        )
        call = result["calls"][0]
        self.assertEqual(call["sourceRange"]["startAddress"], self.expected["directCall"]["sourceAddress"])
        self.assertEqual(call["targetAddress"], self.expected["directCall"]["targetAddress"])
        self.assertEqual(call["targetSymbol"]["name"], self.expected["directCall"]["targetSymbol"])
        self.assertEqual(result["schemaVersion"], RESULT_SCHEMA_VERSION)
        for capability in self.expected["availableCapabilities"]:
            self.assertTrue(result["capabilities"][capability])
        for capability in self.expected["unavailableCapabilities"]:
            self.assertFalse(result["capabilities"][capability])
        self.assertEqual(result["analysisSemantics"]["registerAliasModel"], "aarch64-gpr-x-w-zero-extend")
        self.assertEqual(result["analysisSemantics"]["memoryPartitionModel"], "single-unknown")
        self.assertGreater(len(result["ssaValues"]), len(result["values"]))
        self.assertEqual(len(result["ssaBindings"]), len(result["pcodeOps"]))
        self.assertEqual(len(result["heritage"]), sum(len(item["inputs"]) for item in result["pcodeOps"]))
        self.assertEqual(result["phis"], [])
        call_effect = next(item for item in result["memoryEffects"] if item["pcodeOpId"] == call["pcodeOpId"])
        self.assertEqual(call_effect["kind"], "callClobber")
        self.assertIsNotNone(call_effect["outputMemoryVersionId"])
        self.assertEqual(result["memoryPhis"], [])
        register_analysis = result["registerAnalysis"]
        self.assertEqual(register_analysis["model"]["gprAliasCoverage"], "x0-x30-sp-and-32-bit-w-views")
        views = {item["viewName"]: item for item in register_analysis["views"]}
        self.assertEqual(views["x0"]["canonicalRegister"], "x0")
        self.assertEqual(views["w0"]["canonicalRegister"], "x0")
        self.assertEqual(len(register_analysis["callEffects"]), 1)
        call_register_effect = register_analysis["callEffects"][0]
        self.assertEqual(len(call_register_effect["inputs"]), 19)
        self.assertEqual(len(call_register_effect["clobbers"]), 56)
        self.assertEqual(result["resourceUsage"]["callRegisterInputSliceCount"], 19)
        self.assertEqual(result["resourceUsage"]["callRegisterClobberSliceCount"], 56)
        self.assertEqual(
            [item["registerName"] for item in call_register_effect["inputs"]],
            [
                "x0",
                "x1",
                "x2",
                "x3",
                "x4",
                "x5",
                "x6",
                "x7",
                "x8",
                "x30",
                "sp",
                "v0",
                "v1",
                "v2",
                "v3",
                "v4",
                "v5",
                "v6",
                "v7",
            ],
        )
        self.assertEqual(
            next(
                item
                for item in call_register_effect["clobbers"]
                if item["registerName"] == "x30"
            )["reason"],
            "linkRegisterCallerSaved",
        )
        register_versions = {
            item["id"]: item for item in register_analysis["versions"]
        }
        x30_input = next(
            item
            for item in call_register_effect["inputs"]
            if item["registerName"] == "x30"
        )
        x30_input_version = register_versions[x30_input["inputRegisterVersionId"]]
        self.assertEqual(x30_input_version["kind"], "pcodeWrite")
        link_write = next(
            item
            for item in result["pcodeOps"]
            if item["id"] == x30_input_version["definingPcodeOpId"]
        )
        call_operation = next(
            item
            for item in result["pcodeOps"]
            if item["id"] == call_register_effect["pcodeOpId"]
        )
        self.assertEqual(link_write["instructionIndex"], call_operation["instructionIndex"])
        self.assertLess(link_write["sequence"], call_operation["sequence"])
        self.assertEqual(result["recoveredVariables"], [])
        self.assertEqual(result["structuredRegions"], [])
        self.assertEqual(result["pseudocodeTokens"], [])

    def test_branch_relocation_is_applied_before_decode_and_call_recovery(self) -> None:
        value = fixture_value()
        raw = bytearray.fromhex(value["memoryRegions"][0]["bytesHex"])
        raw[8:12] = bytes.fromhex("00000094")
        value["memoryRegions"][0]["bytesHex"] = raw.hex()
        value["relocations"] = [
            {
                "address": "0x100001008",
                "kind": "ARM64_RELOC_BRANCH26",
                "targetAddress": None,
                "symbol": "_helper",
                "addend": 0,
            }
        ]
        request = request_from(value)
        result = analyze_request(request)

        self.assertEqual(result["instructions"][2]["bytesHex"], "05000094")
        self.assertEqual(result["calls"][0]["targetAddress"], "0x10000101c")
        self.assertEqual(result["calls"][0]["targetSymbol"]["name"], "_helper")
        self.assertNotEqual(
            result["function"]["sourceSha256"],
            result["function"]["effectiveSha256"],
        )
        self.assertEqual(result["function"]["appliedPatchIds"], ["patch000000"])
        self.assertEqual(result["resourceUsage"]["appliedPatchCount"], 1)
        self.assertEqual(result["resourceUsage"]["unmappedAddressMetadataCount"], 0)
        patch = result["loadImage"]["patches"][0]
        self.assertEqual(patch["originalBytesHex"], "00000094")
        self.assertEqual(patch["effectiveBytesHex"], "05000094")
        self.assertEqual(patch["encoding"], "aarch64Branch26")

        forged = json.loads(json.dumps(result))
        forged["loadImage"]["patches"][0]["targetAddress"] = "0x100001018"
        forged["contentHash"] = canonical_sha256(
            {key: item for key, item in forged.items() if key != "contentHash"}
        )
        with self.assertRaisesRegex(
            ResultValidationError,
            "effective bytes do not encode the claimed target|"
            "patch target does not match relocation evidence|"
            "deterministic request-derived effective memory|request authority",
        ):
            validate_result(forged, request=request)

    def test_instruction_internal_pcode_branch_does_not_split_machine_cfg(self) -> None:
        value = fixture_value()
        value["function"]["endAddressExclusive"] = "0x100001008"
        value["memoryRegions"] = [
            {
                "name": "__text",
                "startAddress": "0x100001000",
                "permissions": "r-x",
                # csel x0, x1, x2, eq; ret
                "bytesHex": "2000829ac0035fd6",
            }
        ]
        value["symbols"] = []
        result = analyze_request(request_from(value))

        self.assertEqual([item["mnemonic"] for item in result["instructions"]], ["csel", "ret"])
        internal_branches = [
            item
            for item in result["pcodeOps"]
            if item["instructionIndex"] == 0 and item["opcode"] == "CBRANCH"
        ]
        self.assertEqual(len(internal_branches), 1)
        self.assertIsNone(internal_branches[0]["directTargetAddress"])
        self.assertEqual(len(result["basicBlocks"]), 1)
        self.assertEqual(result["basicBlocks"][0]["instructionIndices"], [0, 1])
        self.assertEqual(result["basicBlocks"][0]["terminator"]["kind"], "return")
        self.assertEqual(result["edges"], [])

    def test_native_zero_registers_do_not_become_mutable_register_families(self) -> None:
        value = fixture_value()
        value["function"]["endAddressExclusive"] = "0x10000100c"
        value["memoryRegions"] = [
            {
                "name": "__text",
                "startAddress": "0x100001000",
                "permissions": "r-x",
                # mov x0, xzr; mov xzr, x0; ret
                "bytesHex": "e0031faaff0300aac0035fd6",
            }
        ]
        value["symbols"] = []
        result = analyze_request(request_from(value))

        self.assertEqual(
            [item["mnemonic"] for item in result["instructions"]],
            ["mov", "mov", "ret"],
        )
        view_names = {item["viewName"] for item in result["registerAnalysis"]["views"]}
        canonical_registers = {
            item["canonicalRegister"]
            for item in result["registerAnalysis"]["versions"]
        }
        self.assertNotIn("xzr", view_names)
        self.assertNotIn("wzr", view_names)
        self.assertNotIn("xzr", canonical_registers)
        self.assertNotIn("wzr", canonical_registers)

    def test_two_runs_are_byte_identical(self) -> None:
        first = canonical_json_bytes(analyze_request(self.request))
        second = canonical_json_bytes(analyze_request(self.request))
        self.assertEqual(first, second)

    def test_content_hash_covers_every_other_result_field(self) -> None:
        result = analyze_request(self.request)
        observed = result.pop("contentHash")
        self.assertEqual(observed, canonical_sha256(result))

    def test_engine_resource_paths_are_relative_and_checksummed(self) -> None:
        result = analyze_request(self.request)
        resources = result["engine"]["resources"]
        self.assertGreaterEqual(len(resources), 5)
        for resource in resources:
            self.assertFalse(pathlib.PurePosixPath(resource["name"]).is_absolute())
            self.assertNotIn("..", pathlib.PurePosixPath(resource["name"]).parts)
            self.assertRegex(resource["sha256"], r"^[0-9a-f]{64}$")
            self.assertGreater(resource["byteCount"], 0)

    def test_instruction_budget_is_enforced(self) -> None:
        value = fixture_value()
        value["budgets"]["maxInstructions"] = 2
        with self.assertRaisesRegex(BudgetExceededError, "instruction count"):
            analyze_request(request_from(value))

    def test_pcode_budget_is_enforced(self) -> None:
        value = fixture_value()
        value["budgets"]["maxPcodeOps"] = 4
        with self.assertRaisesRegex(BudgetExceededError, "p-code operation count"):
            analyze_request(request_from(value))

    def test_output_budget_is_enforced(self) -> None:
        value = fixture_value()
        value["budgets"]["maxOutputBytes"] = 1024
        with self.assertRaisesRegex(BudgetExceededError, "output bytes"):
            analyze_request(request_from(value))

    def test_cli_emits_canonical_json_and_refuses_symlink_input(self) -> None:
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(TOOL_ROOT)
        command = [
            sys.executable,
            "-m",
            "macscope_decompiler_proof.cli",
            "--input",
            str(FIXTURE_PATH),
            "--output",
            "-",
        ]
        first = subprocess.run(command, check=True, capture_output=True, env=environment)
        second = subprocess.run(command, check=True, capture_output=True, env=environment)
        self.assertEqual(first.stdout, second.stdout)
        self.assertEqual(first.stdout, canonical_json_bytes(json.loads(first.stdout)))
        with tempfile.TemporaryDirectory() as directory:
            link = pathlib.Path(directory) / "request.json"
            link.symlink_to(FIXTURE_PATH)
            failure = subprocess.run(
                [sys.executable, "-m", "macscope_decompiler_proof.cli", "--input", str(link), "--output", "-"],
                check=False,
                capture_output=True,
                env=environment,
            )
            self.assertEqual(failure.returncode, 2)
            error = json.loads(failure.stderr)
            self.assertEqual(error["error"]["code"], "request.invalid")

    def test_supervisor_emits_canonical_output_atomically(self) -> None:
        supervisor = ROOT / "Scripts" / "decompiler-proof" / "run_dcp03_proof.py"
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "result.json"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(supervisor),
                    "--python",
                    sys.executable,
                    "--input",
                    str(FIXTURE_PATH),
                    "--output",
                    str(output),
                ],
                check=False,
                capture_output=True,
                cwd=ROOT,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8", errors="replace"))
            payload = output.read_bytes()
            self.assertEqual(payload, canonical_json_bytes(json.loads(payload)))
            self.assertEqual(json.loads(payload)["status"], "ok")

    def test_supervisor_cancellation_does_not_publish_output(self) -> None:
        supervisor = ROOT / "Scripts" / "decompiler-proof" / "run_dcp03_proof.py"
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            output = root / "result.json"
            cancellation = root / "cancel"
            cancellation.write_text("cancel", encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(supervisor),
                    "--python",
                    sys.executable,
                    "--input",
                    str(FIXTURE_PATH),
                    "--output",
                    str(output),
                    "--cancel-file",
                    str(cancellation),
                ],
                check=False,
                capture_output=True,
                cwd=ROOT,
            )
            self.assertEqual(completed.returncode, 6)
            self.assertFalse(output.exists())
            error = json.loads(completed.stderr)
            self.assertEqual(error["error"]["code"], "analysis.cancelled")

    def test_supervisor_absolutizes_relative_virtual_environment_python(self) -> None:
        supervisor = ROOT / "Scripts" / "decompiler-proof" / "run_dcp03_proof.py"
        with tempfile.TemporaryDirectory() as directory:
            # Resolve: on macOS the temporary root is /var/... while the child's cwd
            # is /private/var/..., so an unresolved relpath walks the wrong parents.
            root = pathlib.Path(directory).resolve()
            output = root / "result.json"
            relative_python = os.path.relpath(sys.executable, root)
            completed = subprocess.run(
                [
                    sys.executable,
                    str(supervisor),
                    "--python",
                    relative_python,
                    "--input",
                    str(FIXTURE_PATH),
                    "--output",
                    str(output),
                ],
                check=False,
                capture_output=True,
                cwd=root,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8", errors="replace"))
            self.assertEqual(json.loads(output.read_bytes())["status"], "ok")


if __name__ == "__main__":
    unittest.main()
