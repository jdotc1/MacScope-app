from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
CORE_TOOL_ROOT = ROOT / "Tools" / "DecompilerCoreProof"
PILOT_TOOL_ROOT = ROOT / "Tools" / "NativeDecompilerPilot"
FIXTURE_PATH = CORE_TOOL_ROOT / "fixtures" / "conditional-call.request.json"


def fixture_request():
    from macscope_decompiler_proof.request import parse_request_bytes

    return parse_request_bytes(FIXTURE_PATH.read_bytes())



def fixture_instructions(*, reversed_order: bool = False):
    from macscope_native_decompiler_pilot.provider import NativeInstruction

    entry = 0x100001000
    values = (
        NativeInstruction(entry + 0x00, "cmp", "w0, #0", "cmp w0, #0", 4),
        NativeInstruction(entry + 0x04, "b.eq", "0x100001014", "b.eq 0x100001014", 4),
        NativeInstruction(entry + 0x08, "bl", "0x10000101c", "bl 0x10000101c", 4),
        NativeInstruction(entry + 0x0C, "add", "w0, w0, #1", "add w0, w0, #1", 4),
        NativeInstruction(entry + 0x10, "ret", "", "ret", 4),
        NativeInstruction(entry + 0x14, "mov", "w0, #0x2a", "mov w0, #0x2a", 4),
        NativeInstruction(entry + 0x18, "ret", "", "ret", 4),
    )
    return tuple(reversed(values)) if reversed_order else values


def fixture_provider_output(
    *,
    pseudocode: str | None = None,
    reversed_instructions: bool = False,
):
    from macscope_native_decompiler_pilot.contract import (
        ENGINE_HOST_MODE,
        ENGINE_SERVICE_NAME,
        ENGINE_SERVICE_VERSION,
        LINUX_X86_64_WHEEL,
        LINUX_X86_64_WHEEL_SHA256,
    )
    from macscope_native_decompiler_pilot.provider import (
        NativeCapability,
        NativeDecompilation,
        NativeEngineStatus,
        NativeFunction,
        NativeOpenProgram,
        NativeProviderOutput,
    )

    entry = 0x100001000
    text = pseudocode or (
        "int _fixture(int value) {\n"
        "  if (value == 0) return 42;\n"
        "  int result = _helper();\n"
        "  return result + 1;\n"
        "}\n"
    )
    return NativeProviderOutput(
        engine=NativeEngineStatus(
            service_name=ENGINE_SERVICE_NAME,
            service_version=ENGINE_SERVICE_VERSION,
            host_mode=ENGINE_HOST_MODE,
            program_revision=1,
            capabilities=(
                *(
                    NativeCapability(name, status)
                    for name, status in (
                        ("decompiler", "supported"),
                        ("functions", "supported"),
                        ("health", "supported"),
                        ("listing", "supported"),
                        ("memory", "supported"),
                        ("session", "supported"),
                        ("signatures", "supported"),
                        ("symbols", "supported"),
                        ("types", "supported"),
                        ("xrefs", "partial"),
                    )
                ),
            ),
            wheel_filename=LINUX_X86_64_WHEEL,
            wheel_sha256=LINUX_X86_64_WHEEL_SHA256,
            wheel_platform="manylinux_2_28_x86_64",
            extension_sha256="a" * 64,
            materialization_sha256="b" * 64,
        ),
        opened_program=NativeOpenProgram(
            program_name="carrier.macho",
            language_id="AARCH64:LE:64:v8A",
            compiler_spec="default",
            reported_image_base=0,
        ),
        decompilation=NativeDecompilation(
            function_entry=entry,
            pseudocode=text,
            completed=True,
            fallback=False,
        ),
        function=NativeFunction(
            entry_address=entry,
            name="_fixture",
            start_address=entry,
            end_address=entry + 0x1B,
            size=0x1C,
            namespace_name="",
            prototype="int _fixture(int value)",
            is_thunk=False,
            parameter_count=1,
        ),
        instructions=fixture_instructions(reversed_order=reversed_instructions),
    )


def fixture_request_with_branch_relocation():
    """Return the conditional-call fixture with a raw BL+0 relocation site.

    DCP-03B2 must materialize the effective call target before libghidra sees
    the bytes. The native records remain the same as ``fixture_provider_output``.
    """
    import json

    value = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
    value["requestId"] = "fixture-relocated-call"
    raw = bytearray.fromhex(value["memoryRegions"][0]["bytesHex"])
    raw[8:12] = bytes.fromhex("00000094")
    value["memoryRegions"][0]["bytesHex"] = raw.hex()
    value["relocations"] = [
        {
            "address": "0x100001008",
            "kind": "ARM64_RELOC_BRANCH26",
            "targetAddress": "0x10000101c",
            "symbol": "_helper",
            "addend": 0,
        }
    ]
    from macscope_decompiler_proof.canonical import canonical_json_bytes
    from macscope_decompiler_proof.request import parse_request_bytes

    return parse_request_bytes(canonical_json_bytes(value))
