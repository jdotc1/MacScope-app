from __future__ import annotations

import copy
import hashlib
import json
import os
import pathlib
import struct
import sys
import tempfile
import unittest
from dataclasses import replace
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
CORE_ROOT = ROOT / "Tools" / "DecompilerCoreProof"
PILOT_ROOT = ROOT / "Tools" / "NativeDecompilerPilot"
for path in (str(CORE_ROOT), str(PILOT_ROOT), str(ROOT)):
    if path not in sys.path:
        sys.path.insert(0, path)

from macscope_decompiler_proof.canonical import canonical_json_bytes, canonical_sha256
from macscope_native_decompiler_pilot.carrier import (
    HEADER_SIZE,
    LC_SEGMENT_64,
    LC_SYMTAB,
    LC_UUID,
    MH_MAGIC_64,
    build_macho_carrier,
)
from macscope_native_decompiler_pilot.contract import (
    ANALYSIS_LEVEL,
    ANALYSIS_SEMANTICS,
    APPROVED_WHEELS,
    CAPABILITY_TRUTH,
    ENGINE_COMPONENT_ID,
    ENGINE_GIT_REVISION,
    ENGINE_HOST_MODE,
    ENGINE_LANGUAGE_ID,
    ENGINE_SERVICE_NAME,
    ENGINE_SERVICE_VERSION,
    ENGINE_VERSION,
    LINUX_X86_64_WHEEL,
    LINUX_X86_64_WHEEL_SHA256,
    RESULT_SCHEMA_VERSION,
)
from macscope_native_decompiler_pilot.errors import (
    CarrierBuildError,
    MaterializationError,
    NormalizationError,
    ProviderError,
)
from macscope_native_decompiler_pilot.normalize import build_result
from macscope_native_decompiler_pilot.provider import (
    LibGhidraExtensionProvider,
    NativeInstruction,
    _load_manifest,
)
from macscope_native_decompiler_pilot.result_validation import (
    ResultValidationError,
    validate_result,
)
from Scripts.tests.native_decompiler_pilot_fixtures import (
    fixture_instructions,
    fixture_provider_output,
    fixture_request,
    fixture_request_with_branch_relocation,
)


def rehash(value: dict[str, object]) -> dict[str, object]:
    value = copy.deepcopy(value)
    value.pop("contentHash", None)
    value["contentHash"] = canonical_sha256(value)
    return value


class MachOCarrierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.request = fixture_request()
        self.carrier = build_macho_carrier(self.request)

    def _load_command_types(self) -> list[int]:
        _, _, _, _, ncmds, _sizeofcmds, _, _ = struct.unpack_from("<IiiIIIII", self.carrier.data, 0)
        cursor = HEADER_SIZE
        values: list[int] = []
        for _ in range(ncmds):
            command, size = struct.unpack_from("<II", self.carrier.data, cursor)
            values.append(command)
            cursor += size
        return values

    def test_carrier_is_deterministic_and_binds_request_identity(self) -> None:
        second = build_macho_carrier(self.request)
        self.assertEqual(self.carrier.data, second.data)
        self.assertEqual(self.carrier.manifest, second.manifest)
        self.assertEqual(self.carrier.manifest["requestSha256"], self.request.request_sha256)
        self.assertEqual(self.carrier.manifest["imageId"], self.request.image_id)
        self.assertEqual(self.carrier.manifest["imageUUID"], self.request.image_uuid)
        self.assertEqual(self.carrier.manifest["carrierSha256"], hashlib.sha256(self.carrier.data).hexdigest())

    def test_header_and_load_commands_do_not_claim_original_entrypoint(self) -> None:
        magic, cpu, _subtype, filetype, ncmds, sizeofcmds, _flags, _reserved = struct.unpack_from(
            "<IiiIIIII", self.carrier.data, 0
        )
        self.assertEqual(magic, MH_MAGIC_64)
        self.assertEqual(cpu, 0x0100000C)
        self.assertEqual(filetype, 2)
        self.assertEqual(ncmds, len(self.request.memory_regions) + 2)
        self.assertGreater(sizeofcmds, 0)
        command_types = self._load_command_types()
        self.assertEqual(command_types.count(LC_SEGMENT_64), len(self.request.memory_regions))
        self.assertEqual(command_types.count(LC_UUID), 1)
        self.assertEqual(command_types.count(LC_SYMTAB), 1)
        self.assertNotIn(0x80000028, command_types)  # LC_MAIN

    def test_source_mapping_reconstructs_exact_effective_bytes_and_preserves_raw_hashes(self) -> None:
        for index, (mapping, region) in enumerate(
            zip(self.carrier.manifest["sourceMappings"], self.request.memory_regions)
        ):
            start = int(mapping["fileOffset"], 16)
            end = start + mapping["fileSize"]
            effective = self.carrier.load_image.effective_regions[index]
            self.assertEqual(self.carrier.data[start:end], effective)
            self.assertEqual(mapping["rawSha256"], hashlib.sha256(region.data).hexdigest())
            self.assertEqual(mapping["effectiveSha256"], hashlib.sha256(effective).hexdigest())
            self.assertEqual(mapping["appliedPatchIds"], [])
            self.assertEqual(mapping["vmStartAddress"], f"0x{region.start:x}")
            self.assertEqual(mapping["vmEndAddressExclusive"], f"0x{region.end:x}")

    def test_carrier_contains_caller_symbols_and_synthetic_function_symbol_once(self) -> None:
        self.assertEqual(self.carrier.manifest["symbolCount"], len(self.request.symbols))
        self.assertEqual(self.carrier.manifest["functionEntryAddress"], "0x100001000")
        self.assertRegex(self.carrier.manifest["symbolTableSha256"], r"^[0-9a-f]{64}$")

    def test_output_is_exclusive_and_rejects_symlink_parent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            target = root / "carrier.macho"
            self.carrier.write(target)
            self.assertEqual(target.read_bytes(), self.carrier.data)
            with self.assertRaises(CarrierBuildError):
                self.carrier.write(target)
            real = root / "real"
            real.mkdir()
            link = root / "link"
            link.symlink_to(real, target_is_directory=True)
            with self.assertRaises(CarrierBuildError):
                self.carrier.write(link / "carrier.macho")


class NativePilotNormalizationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.request = fixture_request()
        self.carrier = build_macho_carrier(self.request)

    def build(self, output=None):
        return build_result(
            request=self.request,
            carrier=self.carrier,
            output=output or fixture_provider_output(),
        )

    def test_result_is_deterministic_and_capability_truth_is_exact(self) -> None:
        first = self.build()
        second = self.build(fixture_provider_output(reversed_instructions=True))
        self.assertEqual(first, second)
        self.assertEqual(first["schemaVersion"], RESULT_SCHEMA_VERSION)
        self.assertEqual(first["analysisLevel"], ANALYSIS_LEVEL)
        self.assertEqual(first["capabilities"], CAPABILITY_TRUTH)
        self.assertEqual(first["analysisSemantics"], ANALYSIS_SEMANTICS)
        self.assertTrue(first["capabilities"]["nativeGhidraDecompiler"])
        self.assertTrue(first["capabilities"]["structuredInstructions"])
        self.assertFalse(first["capabilities"]["nativeCFGEdges"])
        self.assertFalse(first["capabilities"]["tokenizedPseudocode"])
        self.assertEqual(first["engine"]["openProgram"]["reportedImageBase"], "0x0")
        self.assertEqual(first["engine"]["openProgram"]["imageBaseDisposition"], "unreported")
        self.assertIn("native-open-response-image-base-unreported", first["warnings"])

    def test_contract_fixture_is_byte_identical(self) -> None:
        expected = PILOT_ROOT / "fixtures" / "conditional-call.contract-result.json"
        self.assertEqual(canonical_json_bytes(self.build()), expected.read_bytes())

    def test_instruction_records_are_image_qualified_and_byte_bound(self) -> None:
        result = self.build()
        records = result["backendRecords"]["instructions"]
        self.assertEqual(len(records), 7)
        raw_bytes = self.request.read(
            self.request.function_entry,
            self.request.function_end,
            require_executable=True,
        )
        effective_bytes = self.carrier.load_image.read(
            self.request.function_entry,
            self.request.function_end,
            require_executable=True,
        )
        self.assertEqual("".join(item["rawBytesHex"] for item in records), raw_bytes.hex())
        self.assertEqual(
            "".join(item["effectiveBytesHex"] for item in records),
            effective_bytes.hex(),
        )
        for index, item in enumerate(records):
            self.assertEqual(item["id"], f"nativeinsn{index:06d}")
            self.assertEqual(item["index"], index)
            self.assertEqual(item["length"], 4)
            self.assertEqual(
                item["rawSourceSha256"],
                hashlib.sha256(bytes.fromhex(item["rawBytesHex"])).hexdigest(),
            )
            self.assertEqual(
                item["effectiveSourceSha256"],
                hashlib.sha256(bytes.fromhex(item["effectiveBytesHex"])).hexdigest(),
            )
            self.assertEqual(item["appliedPatchIds"], [])
            source_range = item["imageQualifiedSourceRange"]
            self.assertEqual(source_range["imageId"], self.request.image_id)
            self.assertEqual(source_range["startAddress"], item["address"])
            self.assertEqual(source_range["endAddressExclusive"], item["endAddressExclusive"])
        self.assertEqual(result["resourceUsage"]["nativeInstructionBytes"], self.request.function_size)

    def test_relocated_call_uses_effective_bytes_and_preserves_raw_provenance(self) -> None:
        request = fixture_request_with_branch_relocation()
        carrier = build_macho_carrier(request)
        result = build_result(
            request=request,
            carrier=carrier,
            output=fixture_provider_output(),
        )

        mapping = carrier.manifest["sourceMappings"][0]
        self.assertNotEqual(mapping["rawSha256"], mapping["effectiveSha256"])
        self.assertEqual(mapping["appliedPatchIds"], ["patch000000"])
        self.assertEqual(carrier.manifest["functionAppliedPatchIds"], ["patch000000"])
        self.assertEqual(carrier.manifest["appliedPatchCount"], 1)

        call = result["backendRecords"]["instructions"][2]
        self.assertEqual(call["address"], "0x100001008")
        self.assertEqual(call["rawBytesHex"], "00000094")
        self.assertEqual(call["effectiveBytesHex"], "05000094")
        self.assertEqual(call["appliedPatchIds"], ["patch000000"])
        self.assertEqual(result["function"]["appliedPatchIds"], ["patch000000"])
        self.assertEqual(result["resourceUsage"]["appliedPatchCount"], 1)
        self.assertIn("effective-load-image-patches-applied", result["warnings"])
        self.assertTrue(result["capabilities"]["relocationApplication"])
        self.assertTrue(result["capabilities"]["aarch64MachORelocationApplication"])

        validate_result(result, request=request)

    def test_forged_effective_load_image_and_patch_provenance_fail_closed(self) -> None:
        request = fixture_request_with_branch_relocation()
        result = build_result(
            request=request,
            carrier=build_macho_carrier(request),
            output=fixture_provider_output(),
        )
        mutations = (
            lambda value: value["authority"]["loadImage"]["patches"][0].__setitem__(
                "targetAddress", "0x100001018"
            ),
            lambda value: value["authority"]["carrier"]["sourceMappings"][0].__setitem__(
                "effectiveSha256", "0" * 64
            ),
            lambda value: value["backendRecords"]["instructions"][2].__setitem__(
                "effectiveBytesHex", "00000094"
            ),
            lambda value: value["backendRecords"]["instructions"][2].__setitem__(
                "appliedPatchIds", []
            ),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                forged = copy.deepcopy(result)
                mutate(forged)
                with self.assertRaises(ResultValidationError):
                    validate_result(rehash(forged), request=request)

    def test_pseudocode_is_presentation_only_and_never_reparsed(self) -> None:
        adversarial = "/* fake block, token, variable and type */\nint x = *(Widget *)0x1;\n"
        normal = self.build()
        altered = self.build(fixture_provider_output(pseudocode=adversarial))
        self.assertNotEqual(normal["presentation"]["pseudocode"], altered["presentation"]["pseudocode"])
        self.assertEqual(normal["backendRecords"]["instructions"], altered["backendRecords"]["instructions"])
        self.assertEqual(altered["recoveredVariables"], [])
        self.assertEqual(altered["typeCandidates"], [])
        self.assertFalse(altered["presentation"]["semanticInput"])

    def test_request_evidence_and_unavailable_native_records_are_reported_exactly(self) -> None:
        warnings = self.build()["warnings"]
        self.assertIn("request-type-hints-not-applied", warnings)
        self.assertIn("native-basic-block-enumeration-not-accepted-dcp03b3", warnings)
        self.assertIn("native-cfg-edge-enumeration-not-accepted-dcp03b3", warnings)
        self.assertIn("native-timeout-parameter-not-enforced-by-libghidra-v0.0.2", warnings)
        self.assertNotIn("request-relocations-not-applied", warnings)
        self.assertNotIn("request-fixups-not-applied", warnings)

    def test_duplicate_gap_overlap_wrong_width_and_out_of_range_fail_closed(self) -> None:
        base = fixture_provider_output()
        instructions = list(base.instructions)
        variants = []
        variants.append(replace(base, instructions=tuple(instructions + [instructions[0]])))
        gap = list(instructions)
        gap.pop(2)
        variants.append(replace(base, instructions=tuple(gap)))
        overlap = list(instructions)
        overlap[2] = replace(overlap[2], address=overlap[1].address)
        variants.append(replace(base, instructions=tuple(overlap)))
        wrong_width = list(instructions)
        wrong_width[0] = replace(wrong_width[0], length=8)
        variants.append(replace(base, instructions=tuple(wrong_width)))
        out_of_range = list(instructions)
        out_of_range[-1] = replace(out_of_range[-1], address=self.request.function_end)
        variants.append(replace(base, instructions=tuple(out_of_range)))
        for output in variants:
            with self.subTest(output=output.instructions):
                with self.assertRaises(NormalizationError):
                    self.build(output)

    def test_function_and_decompilation_identity_must_match_request(self) -> None:
        base = fixture_provider_output()
        variants = (
            replace(base, function=replace(base.function, entry_address=base.function.entry_address + 4)),
            replace(base, function=replace(base.function, size=base.function.size + 4)),
            replace(base, function=replace(base.function, end_address=base.function.end_address + 8)),
            replace(base, decompilation=replace(base.decompilation, function_entry=base.decompilation.function_entry + 4)),
            replace(base, decompilation=replace(base.decompilation, completed=False)),
            replace(base, decompilation=replace(base.decompilation, fallback=True)),
            replace(base, decompilation=replace(base.decompilation, pseudocode="")),
        )
        for output in variants:
            with self.subTest(output=output):
                with self.assertRaises(NormalizationError):
                    self.build(output)


class NativePilotVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.request = fixture_request()
        self.result = build_result(
            request=self.request,
            carrier=build_macho_carrier(self.request),
            output=fixture_provider_output(),
        )

    def assertRejected(self, mutate) -> None:
        value = copy.deepcopy(self.result)
        mutate(value)
        with self.assertRaises(ResultValidationError):
            validate_result(rehash(value), request=self.request)

    def test_valid_result_is_independently_rederived(self) -> None:
        validate_result(self.result, request=self.request)

    def test_forged_carrier_function_and_instruction_records_are_rejected(self) -> None:
        mutations = (
            lambda value: value["authority"]["carrier"].__setitem__("carrierByteCount", 1),
            lambda value: value["function"].__setitem__("nativeName", "forged"),
            lambda value: value["backendRecords"]["function"].__setitem__("size", 4),
            lambda value: value["backendRecords"]["instructions"][0].__setitem__("effectiveBytesHex", "00000000"),
            lambda value: value["backendRecords"]["instructions"][0]["imageQualifiedSourceRange"].__setitem__("imageId", "forged-image"),
            lambda value: value["backendRecords"]["instructions"][0].__setitem__("address", "0x0000000100001004"),
            lambda value: value["resourceUsage"].__setitem__("nativeInstructionCount", 6),
            lambda value: value["resourceUsage"].__setitem__("nativeInstructionBytes", 24),
            lambda value: value["authority"]["loadImage"]["memoryRegions"][0].__setitem__("effectiveSha256", "0" * 64),
            lambda value: value["backendRecords"]["instructions"][0].__setitem__("rawSourceSha256", "0" * 64),
            lambda value: value["backendRecords"]["instructions"][0].__setitem__("appliedPatchIds", ["patch000000"]),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.assertRejected(mutate)

    def test_forged_engine_and_capability_records_are_rejected(self) -> None:
        mutations = (
            lambda value: value["engine"].__setitem__("serviceVersion", ENGINE_VERSION),
            lambda value: value["engine"].__setitem__("wheelSha256", "0" * 64),
            lambda value: value["engine"]["reportedCapabilities"][0].__setitem__("status", "partial"),
            lambda value: value["engine"]["openProgram"].__setitem__("reportedImageBase", "0x100002000"),
            lambda value: value["engine"]["openProgram"].__setitem__("imageBaseDisposition", "matches-request"),
            lambda value: value["capabilities"].__setitem__("nativeCFGEdges", True),
            lambda value: value["analysisSemantics"].__setitem__("cfgModel", "invented"),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.assertRejected(mutate)

    def test_semantic_overclaims_and_unknown_fields_are_rejected(self) -> None:
        mutations = (
            lambda value: value["recoveredVariables"].append({"name": "x"}),
            lambda value: value["typeCandidates"].append({"name": "int"}),
            lambda value: value["backendRecords"]["instructions"][0].__setitem__("token", "x"),
            lambda value: value.__setitem__("unknown", True),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.assertRejected(mutate)

    def test_unrehashed_result_is_rejected(self) -> None:
        value = copy.deepcopy(self.result)
        value["presentation"]["pseudocode"] = "forged"
        with self.assertRaises(ResultValidationError):
            validate_result(value, request=self.request)


class MaterializationManifestTests(unittest.TestCase):
    def make(self):
        temporary = tempfile.TemporaryDirectory()
        root = pathlib.Path(temporary.name)
        extension = root / "vendor" / "libghidra" / "_libghidra.so"
        extension.parent.mkdir(parents=True)
        extension.write_bytes(b"native-extension-fixture")
        approved = APPROVED_WHEELS[LINUX_X86_64_WHEEL]
        value = {
            "schemaVersion": 1,
            "componentId": ENGINE_COMPONENT_ID,
            "version": ENGINE_VERSION,
            "gitRevision": ENGINE_GIT_REVISION,
            "wheel": approved.filename,
            "wheelSha256": approved.sha256,
            "wheelPlatform": approved.platform,
            "wheelURL": approved.url,
            "extensionRelativePath": extension.relative_to(root).as_posix(),
            "extensionSha256": hashlib.sha256(extension.read_bytes()).hexdigest(),
        }
        manifest = root / "MATERIALIZATION.json"
        manifest.write_bytes(canonical_json_bytes(value))
        return temporary, root, extension, manifest, value

    def test_exact_manifest_is_accepted(self) -> None:
        temporary, root, _extension, manifest, value = self.make()
        self.addCleanup(temporary.cleanup)
        observed, digest, observed_root = _load_manifest(manifest)
        self.assertEqual(observed, value)
        self.assertEqual(observed_root, root.resolve())
        self.assertEqual(digest, hashlib.sha256(manifest.read_bytes()).hexdigest())

    def test_identity_wheel_and_canonical_encoding_are_fail_closed(self) -> None:
        for key, replacement in (
            ("version", "1.0.0"),
            ("gitRevision", "0" * 40),
            ("wheelSha256", "0" * 64),
            ("wheelPlatform", "other"),
            ("wheelURL", "https://example.invalid/a.whl"),
        ):
            temporary, _root, _extension, manifest, value = self.make()
            self.addCleanup(temporary.cleanup)
            value[key] = replacement
            manifest.write_bytes(canonical_json_bytes(value))
            with self.subTest(key=key), self.assertRaises(MaterializationError):
                _load_manifest(manifest)

        temporary, _root, _extension, manifest, value = self.make()
        self.addCleanup(temporary.cleanup)
        manifest.write_text(json.dumps(value, indent=2), encoding="utf-8")
        with self.assertRaises(MaterializationError):
            _load_manifest(manifest)

    def test_unknown_duplicate_escape_suffix_and_symlink_manifest_are_rejected(self) -> None:
        temporary, root, extension, manifest, value = self.make()
        self.addCleanup(temporary.cleanup)
        value["unknown"] = True
        manifest.write_bytes(canonical_json_bytes(value))
        with self.assertRaises(MaterializationError):
            _load_manifest(manifest)

        manifest.write_bytes(b'{"schemaVersion":1,"schemaVersion":1}\n')
        with self.assertRaises(MaterializationError):
            _load_manifest(manifest)

        for relative in ("../escape.so", "vendor/libghidra/file.txt"):
            value.pop("unknown", None)
            value["extensionRelativePath"] = relative
            manifest.write_bytes(canonical_json_bytes(value))
            with self.subTest(relative=relative), self.assertRaises(MaterializationError):
                _load_manifest(manifest)

        manifest.unlink()
        real = root / "real.json"
        real.write_bytes(canonical_json_bytes(value))
        manifest.symlink_to(real)
        with self.assertRaises(MaterializationError):
            _load_manifest(manifest)


class FakeClient:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple, dict]] = []
        self.status = {
            "ok": True,
            "service_name": ENGINE_SERVICE_NAME,
            "service_version": ENGINE_SERVICE_VERSION,
            "host_mode": ENGINE_HOST_MODE,
            "program_revision": 1,
            "warnings": [],
        }
        self.capabilities = [
            {"id": name, "status": "supported", "note": f"{name} note"}
            for name in ("health", "session", "decompiler", "functions", "listing")
        ]
        self.decompilation = {
            "function_entry_address": 0x100001000,
            "function_name": "",
            "prototype": "",
            "pseudocode": "int _fixture(int value) { return value; }\n",
            "completed": True,
            "is_fallback": False,
            "error_message": "",
            "locals": [],
            "tokens": [],
        }
        self.function = {
            "entry_address": 0x100001000,
            "name": "_fixture",
            "start_address": 0x100001000,
            "end_address": 0x10000101B,
            "size": 0x1C,
            "namespace_name": "",
            "prototype": "int _fixture(int value)",
            "is_thunk": False,
            "parameter_count": 1,
        }
        self.instructions = [
            {
                "address": item.address,
                "mnemonic": item.mnemonic,
                "operand_text": item.operand_text,
                "disassembly": item.disassembly,
                "length": item.length,
            }
            for item in fixture_instructions()
        ]

    def get_status(self):
        return self.status

    def get_capabilities(self):
        return self.capabilities

    def open_program(self, **kwargs):
        self.calls.append(("open_program", (), kwargs))
        return {
            "program_name": "carrier.macho",
            "language_id": ENGINE_LANGUAGE_ID,
            "compiler_spec": "default",
            # The exact v0.0.2 binding leaves this field at zero. The caller
            # still binds every accepted instruction to the carrier bytes.
            "image_base": 0,
        }

    def get_decompilation(self, *args):
        self.calls.append(("get_decompilation", args, {}))
        return self.decompilation

    def get_function(self, *args):
        self.calls.append(("get_function", args, {}))
        return self.function

    def list_instructions(self, *args):
        self.calls.append(("list_instructions", args, {}))
        return self.instructions

    def close_program(self, *args):
        self.calls.append(("close_program", args, {}))


class FakeNativeModule:
    def __init__(self, client: FakeClient) -> None:
        self.client = client
        self.create_calls: list[dict[str, object]] = []

    def create_local_client(self, **kwargs):
        self.create_calls.append(kwargs)
        return self.client


class NativeProviderAdapterTests(MaterializationManifestTests):
    def run_provider(self, client: FakeClient | None = None):
        client = client or FakeClient()
        native = FakeNativeModule(client)
        temporary, root, _extension, manifest, _value = self.make()
        self.addCleanup(temporary.cleanup)
        request = fixture_request()
        carrier = build_macho_carrier(request)
        carrier_path = root / "carrier.macho"
        carrier.write(carrier_path)
        state = root / "state"
        state.mkdir()
        with mock.patch(
            "macscope_native_decompiler_pilot.provider._load_native_extension",
            return_value=native,
        ):
            output = LibGhidraExtensionProvider(manifest).decompile(
                request=request,
                carrier=carrier,
                carrier_path=carrier_path,
                state_directory=state,
                cancellation_path=None,
            )
        return request, output, client, native

    def test_adapter_uses_exact_local_configuration_and_address_driven_apis(self) -> None:
        request, output, client, native = self.run_provider()
        self.assertEqual(output.function.entry_address, request.function_entry)
        self.assertEqual(len(output.instructions), 7)
        self.assertEqual(
            native.create_calls,
            [{
                "ghidra_root": "",
                "state_path": mock.ANY,
                "default_arch": ENGINE_LANGUAGE_ID,
                "pool_size": 1,
            }],
        )
        state_path = pathlib.Path(native.create_calls[0]["state_path"])
        self.assertEqual(state_path.name, "libghidra-state.xml")
        self.assertEqual(state_path.parent.name, "state")
        self.assertFalse(state_path.exists())
        self.assertEqual(output.opened_program.reported_image_base, 0)
        open_call = next(call for call in client.calls if call[0] == "open_program")
        self.assertFalse(open_call[2]["analyze"])
        self.assertTrue(open_call[2]["read_only"])
        self.assertEqual(open_call[2]["base_address"], request.preferred_load_address)
        instruction_call = next(call for call in client.calls if call[0] == "list_instructions")
        self.assertEqual(
            instruction_call[1],
            (request.function_entry, request.function_end - 1, request.budgets.max_instructions, 0),
        )
        self.assertFalse(any(name in {"list_basic_blocks", "list_cfg_edges"} for name, _, _ in client.calls))
        self.assertEqual(client.calls[-1], ("close_program", (2,), {}))

    def test_adapter_rejects_package_service_version_conflation(self) -> None:
        client = FakeClient()
        client.status["service_version"] = ENGINE_VERSION
        with self.assertRaises(ProviderError):
            self.run_provider(client)

    def test_unhealthy_missing_capability_wrong_base_tokens_and_missing_records_fail_closed(self) -> None:
        variants: list[FakeClient] = []
        unhealthy = FakeClient(); unhealthy.status["ok"] = False; variants.append(unhealthy)
        missing = FakeClient(); missing.capabilities = [x for x in missing.capabilities if x["id"] != "listing"]; variants.append(missing)
        wrong_base = FakeClient()
        original_open = wrong_base.open_program
        def open_wrong(**kwargs):
            value = original_open(**kwargs); value["image_base"] = 0x100002000; return value
        wrong_base.open_program = open_wrong  # type: ignore[method-assign]
        variants.append(wrong_base)
        tokens = FakeClient(); tokens.decompilation["tokens"] = [{"text": "x"}]; variants.append(tokens)
        missing_function = FakeClient(); missing_function.function = None; variants.append(missing_function)  # type: ignore[assignment]
        missing_instructions = FakeClient(); missing_instructions.instructions = []; variants.append(missing_instructions)
        for client in variants:
            with self.subTest(client=client), self.assertRaises(ProviderError):
                self.run_provider(client)

    def test_exact_binding_warning_note_and_image_base_shapes_are_enforced_safely(self) -> None:
        client = FakeClient()
        client.status["warnings"] = ["native warning with /private/path redacted by hash"]
        with self.assertRaises(ProviderError):
            self.run_provider(client)

        request, output, _client, _native = self.run_provider(FakeClient())
        self.assertEqual(output.opened_program.reported_image_base, 0)
        result = build_result(request=request, carrier=build_macho_carrier(request), output=output)
        self.assertIn("native-open-response-image-base-unreported", result["warnings"])

    def test_matching_reported_image_base_is_accepted_but_unrelated_nonzero_base_is_rejected(self) -> None:
        matching = FakeClient()
        original = matching.open_program
        def open_matching(**kwargs):
            value = original(**kwargs); value["image_base"] = kwargs["base_address"]; return value
        matching.open_program = open_matching  # type: ignore[method-assign]
        request, output, _client, _native = self.run_provider(matching)
        self.assertEqual(output.opened_program.reported_image_base, request.preferred_load_address)

        unrelated = FakeClient()
        original_unrelated = unrelated.open_program
        def open_unrelated(**kwargs):
            value = original_unrelated(**kwargs); value["image_base"] = 0x100002000; return value
        unrelated.open_program = open_unrelated  # type: ignore[method-assign]
        with self.assertRaises(ProviderError):
            self.run_provider(unrelated)

    def test_malformed_exact_binding_status_and_capability_shapes_fail_closed(self) -> None:
        variants: list[FakeClient] = []
        missing_warnings = FakeClient(); missing_warnings.status.pop("warnings"); variants.append(missing_warnings)
        invalid_warning = FakeClient(); invalid_warning.status["warnings"] = [1]; variants.append(invalid_warning)
        legacy_detail = FakeClient(); legacy_detail.capabilities[0]["detail"] = legacy_detail.capabilities[0].pop("note"); variants.append(legacy_detail)
        unknown_status = FakeClient(); unknown_status.status["unknown"] = True; variants.append(unknown_status)
        unsafe_name = FakeClient()
        original_open = unsafe_name.open_program
        def open_unsafe(**kwargs):
            value = original_open(**kwargs); value["program_name"] = "/tmp/carrier.macho"; return value
        unsafe_name.open_program = open_unsafe  # type: ignore[method-assign]
        variants.append(unsafe_name)
        for client in variants:
            with self.subTest(client=client), self.assertRaises(ProviderError):
                self.run_provider(client)

    def test_unknown_native_fields_and_carrier_drift_are_rejected(self) -> None:
        client = FakeClient()
        client.instructions[0]["unknown"] = True
        with self.assertRaises(ProviderError):
            self.run_provider(client)

        temporary, root, _extension, manifest, _value = self.make()
        self.addCleanup(temporary.cleanup)
        request = fixture_request()
        carrier = build_macho_carrier(request)
        carrier_path = root / "carrier.macho"
        carrier_path.write_bytes(carrier.data + b"x")
        state = root / "state"; state.mkdir()
        native = FakeNativeModule(FakeClient())
        with mock.patch("macscope_native_decompiler_pilot.provider._load_native_extension", return_value=native):
            with self.assertRaises(ProviderError):
                LibGhidraExtensionProvider(manifest).decompile(
                    request=request,
                    carrier=carrier,
                    carrier_path=carrier_path,
                    state_directory=state,
                    cancellation_path=None,
                )


class MaterializerContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.script_path = ROOT / "Scripts" / "dependencies" / "materialize_libghidra_dcp03b3.sh"
        self.script = self.script_path.read_text(encoding="utf-8")

    def test_materializer_pins_exact_release_service_and_approved_wheels(self) -> None:
        self.assertIn('VERSION="0.0.2"', self.script)
        self.assertIn('GIT_REVISION="61b37fa2d99aa5cf0da450b84f2abd797fb6a27c"', self.script)
        self.assertIn('SERVICE_NAME="local-decompiler"', self.script)
        self.assertIn('SERVICE_VERSION="1.0.0"', self.script)
        for wheel in APPROVED_WHEELS.values():
            self.assertIn(wheel.filename, self.script)
            self.assertIn(wheel.sha256, self.script)
        self.assertIn(LINUX_X86_64_WHEEL, self.script)
        self.assertIn(LINUX_X86_64_WHEEL_SHA256, self.script)

    def test_materializer_is_explicit_checksum_first_and_does_not_use_package_installers(self) -> None:
        self.assertIn("/usr/bin/curl", self.script)
        self.assertIn("--proto '=https'", self.script)
        self.assertIn('if [[ "${ACTUAL_SHA256}" != "${WHEEL_SHA256}" ]]', self.script)
        self.assertNotIn("pip install", self.script)
        self.assertNotIn("pip download", self.script)
        self.assertNotIn("python -m build", self.script)
        self.assertNotIn("FetchContent", self.script)

    def test_materializer_uses_bounded_non_following_manual_wheel_extraction(self) -> None:
        for required in (
            "MAX_MEMBERS",
            "MAX_TOTAL_UNCOMPRESSED",
            "MAX_SINGLE_FILE",
            "MAX_COMPRESSION_RATIO",
            "duplicate member path",
            "encrypted members are not allowed",
            "member path escapes extraction root",
            "member is not an ordinary file or directory",
            "O_NOFOLLOW",
            "O_EXCL",
            "os.fsync",
        ):
            self.assertIn(required, self.script)
        self.assertNotIn("archive.extract(", self.script)
        self.assertNotIn("archive.extractall(", self.script)

    def test_materializer_self_test_requires_truthful_address_driven_capabilities(self) -> None:
        self.assertIn('default_arch="AARCH64:LE:64:v8A"', self.script)
        self.assertIn('pool_size=1', self.script)
        self.assertIn('for capability in ("health", "session", "decompiler", "functions", "listing")', self.script)
        self.assertIn('status.get("service_version") != expected_service_version', self.script)
        self.assertIn('status.get("host_mode") != "local"', self.script)



class NativePilotSchemaTests(unittest.TestCase):
    def setUp(self) -> None:
        self.schema_path = PILOT_ROOT / "schemas" / "result.schema.json"
        self.schema = json.loads(self.schema_path.read_text(encoding="utf-8"))
        request = fixture_request()
        self.result = build_result(
            request=request,
            carrier=build_macho_carrier(request),
            output=fixture_provider_output(),
        )

    def test_schema_is_closed_and_identifies_truthful_contract(self) -> None:
        self.assertEqual(self.schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertEqual(
            self.schema["$id"],
            "https://macscope.invalid/schemas/dcp03b3-native-effective-image-decompiler-pilot-result-v2.json",
        )
        self.assertFalse(self.schema["additionalProperties"])
        self.assertEqual(self.schema["properties"]["analysisLevel"]["const"], ANALYSIS_LEVEL)
        caps = self.schema["properties"]["capabilities"]["properties"]
        self.assertTrue(caps["structuredInstructions"]["const"])
        self.assertTrue(caps["effectiveLoadImageCarrier"]["const"])
        self.assertTrue(caps["relocationApplication"]["const"])
        self.assertTrue(caps["dyldChainedPointerNormalization"]["const"])
        self.assertFalse(caps["nativeCFGEdges"]["const"])
        self.assertFalse(caps["tokenizedPseudocode"]["const"])
        try:
            import jsonschema
        except ImportError:
            return
        jsonschema.Draft202012Validator.check_schema(self.schema)

    def test_schema_accepts_fixture_and_rejects_overclaim_when_jsonschema_is_available(self) -> None:
        try:
            import jsonschema
        except ImportError:
            self.skipTest("jsonschema is optional in the repository environment")
        validator = jsonschema.Draft202012Validator(self.schema)
        validator.validate(self.result)
        forged = copy.deepcopy(self.result)
        forged["capabilities"]["nativeCFGEdges"] = True
        with self.assertRaises(jsonschema.ValidationError):
            validator.validate(forged)


if __name__ == "__main__":
    unittest.main()
