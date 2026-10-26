#!/usr/bin/env python3
"""WS-14 Darwin arm64 parameter-binding oracle.

The reduced proof uses the active Xcode clang, a C caller, and an assembly
entry-state capture harness. It executes sentinels, reads source-formal order
from dwarfdump, and anchors register/stack observations to otool.

``parameter-binding-audit-v1`` is structural candidate output and contains no
baseline claims. Combined comparison mode is deliberately disabled until an
independently provenance-bound comparison producer exists.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import io
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


FIXTURE_DIR = Path(__file__).resolve().parent / "fixtures/parameter-identity"
class OracleError(Exception):
    """Invalid oracle input, unavailable tool, or failed external proof."""


def _require_string(value: object, context: str) -> str:
    if not isinstance(value, str) or not value:
        raise OracleError(f"{context} must be a nonempty string")
    return value


def _binding_for_location(location: str, context: str) -> str | None:
    register = re.fullmatch(r"([wxsd])([0-7])", location)
    if register:
        bank = "gpr" if register.group(1) in {"w", "x"} else "simd"
        return f"{bank}:{register.group(2)}"
    stack = re.fullmatch(r"entry_sp\+([0-9]+)\[([1-9][0-9]*)/([1-9][0-9]*)\]", location)
    if stack:
        offset, size, alignment = map(int, stack.groups())
        if alignment & (alignment - 1) or offset % alignment:
            raise OracleError(f"{context}: misaligned entry-stack location {location!r}")
        if size <= 0:
            raise OracleError(f"{context}: invalid entry-stack size")
        return f"entry-stack:{offset}"
    if location.startswith("unbound:"):
        return None
    raise OracleError(f"{context}: invalid location {location!r}")


def validate_candidate_audit(payload: object, source: str) -> int:
    """Validate structural facts emitted by the app candidate.

    This layer does not claim external name/type truth or body preservation. It
    rejects any embedded comparison fields so the candidate cannot echo a
    baseline and certify itself.
    """

    if not isinstance(payload, dict):
        raise OracleError(f"{source}: audit root must be an object")
    if payload.get("schema") != "parameter-binding-audit-v1":
        raise OracleError(f"{source}: unsupported audit schema {payload.get('schema')!r}")
    if payload.get("validation_scope") != "structural-candidate":
        raise OracleError(f"{source}: validation_scope must be 'structural-candidate'")
    if payload.get("combined_oracle_comparison") is not False:
        raise OracleError(f"{source}: candidate must not claim combined oracle comparison")
    root_function = _require_string(payload.get("function"), f"{source}.function")
    address = payload.get("address")
    if not isinstance(address, str) or not re.fullmatch(r"0x[0-9a-f]+", address):
        raise OracleError(f"{source}.address must be a lowercase 0x-prefixed address")
    root_mode = payload.get("declaration_mode")
    if root_mode not in {"ordinary", "abi-only"}:
        raise OracleError(f"{source}: invalid declaration mode {root_mode!r}")
    forbidden_comparison_fields = {
        "baseline_body_sha256",
        "candidate_body_sha256",
        "baseline_operands",
        "candidate_operands",
        "oracle_name",
        "oracle_type",
        "oracle_binding",
        "oracle_location",
        "oracle_source_position",
    }
    embedded = sorted(forbidden_comparison_fields & set(payload))
    if embedded:
        raise OracleError(
            f"{source}: structural candidate embeds comparison field(s) {', '.join(embedded)}"
        )
    dangling = payload.get("dangling_body_uses")
    if not isinstance(dangling, list):
        raise OracleError(f"{source}.dangling_body_uses must be an array")
    if dangling:
        raise OracleError(f"{source}: dangling body use reported by candidate")
    records = payload.get("records")
    if not isinstance(records, list):
        raise OracleError(f"{source}: records must be an array")
    if not records and root_mode != "abi-only":
        raise OracleError(f"{source}: empty parameter table cannot claim an ordinary declaration")

    normalized: list[dict[str, Any]] = []
    seen_bindings: set[str] = set()
    seen_body_use_sites: set[tuple[int, int]] = set()
    required = {
        "function",
        "declaration_mode",
        "row_ordinal",
        "binding",
        "source_position",
        "location",
        "evidence",
        "name",
        "type",
        "body_uses",
    }

    for index, raw in enumerate(records):
        context = f"{source}.records[{index}]"
        if not isinstance(raw, dict):
            raise OracleError(f"{context}: record must be an object")
        missing = sorted(required - set(raw))
        if missing:
            raise OracleError(f"{context}: missing field(s) {', '.join(missing)}")
        embedded = sorted(forbidden_comparison_fields & set(raw))
        if embedded:
            raise OracleError(
                f"{context}: structural candidate embeds comparison field(s) "
                f"{', '.join(embedded)}"
            )

        function = _require_string(raw["function"], f"{context}.function")
        if function != root_function:
            raise OracleError(f"{context}: function differs from audit root")
        mode = raw["declaration_mode"]
        if mode != root_mode:
            raise OracleError(f"{context}: declaration mode differs from audit root")
        row_ordinal = raw["row_ordinal"]
        if row_ordinal != index:
            raise OracleError(f"{context}: row_ordinal must match deterministic array order")
        source_position = raw["source_position"]
        if source_position is not None and (
            isinstance(source_position, bool)
            or not isinstance(source_position, int)
            or source_position < 0
        ):
            raise OracleError(f"{context}: source_position must be null or nonnegative")
        binding = raw["binding"]
        if binding is not None and (
            not isinstance(binding, str)
            or not re.fullmatch(r"(?:gpr|simd):[0-7]|entry-stack:[0-9]+", binding)
        ):
            raise OracleError(f"{context}: invalid binding {binding!r}")
        if binding is not None and binding in seen_bindings:
            raise OracleError(f"{source}: duplicate binding in {root_function}")
        if binding is not None:
            seen_bindings.add(binding)
        location = _require_string(raw["location"], f"{context}.location")
        projected = _binding_for_location(location, context)
        unproven_entry_stack = binding is None and location.startswith("entry_sp+")
        if projected != binding and not unproven_entry_stack:
            raise OracleError(
                f"{context}: binding/location mismatch ({binding!r} versus {location!r})"
            )

        evidence = raw["evidence"]
        if evidence not in {
            "heuristic_entry_read",
            "known_call_type_constraint",
            "authoritative_debug",
            "authoritative_user",
            "unresolved_legacy",
            "legacy_transient",
        }:
            raise OracleError(f"{context}: invalid evidence {evidence!r}")
        for text_name in ("name", "type"):
            _require_string(raw[text_name], f"{context}.{text_name}")
        body_uses = raw["body_uses"]
        if not isinstance(body_uses, list):
            raise OracleError(f"{context}: body_uses must be an array of MacIR node sites")
        if binding is None and body_uses:
            raise OracleError(f"{context}: unbound row cannot own body uses")
        previous_site: tuple[int, int] | None = None
        for use_index, use in enumerate(body_uses):
            use_context = f"{context}.body_uses[{use_index}]"
            if not isinstance(use, dict):
                raise OracleError(f"{use_context}: body use must be an object")
            use_address = use.get("address")
            occurrence = use.get("occurrence")
            if not isinstance(use_address, str) or not re.fullmatch(
                r"0x[0-9a-f]+", use_address
            ):
                raise OracleError(f"{use_context}.address must be a lowercase hex address")
            if isinstance(occurrence, bool) or not isinstance(occurrence, int) or occurrence < 0:
                raise OracleError(f"{use_context}.occurrence must be nonnegative")
            site = (int(use_address, 16), occurrence)
            if previous_site is not None and site <= previous_site:
                raise OracleError(f"{context}: body uses must be deterministically ordered")
            if site in seen_body_use_sites:
                raise OracleError(f"{source}: duplicate MacIR body-use site {use_address}:{occurrence}")
            previous_site = site
            seen_body_use_sites.add(site)

        record = dict(raw)
        normalized.append(record)

    positions = [record["source_position"] for record in normalized]
    bindings = [record["binding"] for record in normalized if record["binding"]]
    if root_mode == "ordinary":
        if any(position is None for position in positions) or positions != list(
            range(len(positions))
        ):
            raise OracleError(f"{source}: ordinary source positions are incomplete")
        heuristic = bool(normalized) and all(
            record["evidence"] == "heuristic_entry_read" for record in normalized
        )
        if heuristic:
            dense_gpr = bindings == [f"gpr:{index}" for index in range(len(bindings))]
            dense_simd = bindings == [f"simd:{index}" for index in range(len(bindings))]
            if not (dense_gpr or dense_simd):
                raise OracleError(f"{source}: compressed sparse input in {root_function}")
    elif any(position is not None for position in positions):
        raise OracleError(f"{source}: ABI-only rows cannot claim source positions")

    return len(normalized)


def parse_dwarfdump_parameter_names(text: str) -> dict[str, list[str]]:
    """Extract named formal order from Apple dwarfdump's indented DIE listing."""

    functions: dict[str, list[str]] = {}
    current_function: str | None = None
    awaiting_subprogram_name = False
    awaiting_parameter_name = False
    for line in text.splitlines():
        tag = re.search(r"DW_TAG_([A-Za-z_]+)", line)
        if tag:
            tag_name = tag.group(1)
            if tag_name == "subprogram":
                current_function = None
                awaiting_subprogram_name = True
                awaiting_parameter_name = False
            elif tag_name == "formal_parameter" and current_function is not None:
                awaiting_subprogram_name = False
                awaiting_parameter_name = True
            else:
                awaiting_parameter_name = False
        name = re.search(r'DW_AT_name\s*\("([^"]+)"\)', line)
        if not name:
            continue
        if awaiting_subprogram_name:
            current_function = name.group(1)
            functions.setdefault(current_function, [])
            awaiting_subprogram_name = False
        elif awaiting_parameter_name and current_function is not None:
            functions[current_function].append(name.group(1))
            awaiting_parameter_name = False
    return functions


def parse_otool_functions(text: str) -> dict[str, list[tuple[str, str]]]:
    """Parse function labels and instructions from ``otool -tvV`` output."""

    functions: dict[str, list[tuple[str, str]]] = {}
    current: str | None = None
    for line in text.splitlines():
        label = re.fullmatch(r"_?([A-Za-z$][A-Za-z0-9_$]*)\s*:", line.strip())
        if label:
            current = label.group(1)
            functions.setdefault(current, [])
            continue
        if current is None:
            continue
        instruction = re.match(
            r"^\s*[0-9a-fA-F]+\s+([A-Za-z][A-Za-z0-9.]*)\s*(.*?)\s*$", line
        )
        if instruction:
            functions[current].append((instruction.group(1), instruction.group(2)))
    return functions


def _run_checked(command: list[str], *, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            text=True,
            capture_output=True,
            check=False,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise OracleError(f"cannot run {' '.join(command)}: {error}") from error
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise OracleError(
            f"command failed ({result.returncode}): {' '.join(command)}"
            + (f"\n{detail}" if detail else "")
        )
    return result


def _xcrun_find(tool: str) -> str:
    result = _run_checked(["/usr/bin/xcrun", "--find", tool])
    path = result.stdout.strip()
    if not path or not os.access(path, os.X_OK):
        raise OracleError(f"active Xcode tool is unavailable: {tool}")
    return path


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _normalized_instruction_set(
    functions: dict[str, list[tuple[str, str]]], function: str
) -> set[tuple[str, str]]:
    instructions = functions.get(function)
    if not instructions:
        raise OracleError(f"otool: missing fixture function {function}")
    return {
        (mnemonic.lower(), re.sub(r"\s+", "", operands.lower()))
        for mnemonic, operands in instructions
    }


def _require_instruction(
    functions: dict[str, list[tuple[str, str]]],
    function: str,
    mnemonic: str,
    operand_fragment: str,
) -> None:
    instructions = _normalized_instruction_set(functions, function)
    fragment = re.sub(r"\s+", "", operand_fragment.lower())
    if not any(
        actual_mnemonic == mnemonic and fragment in operands
        for actual_mnemonic, operands in instructions
    ):
        raise OracleError(
            f"otool: {function} lacks {mnemonic} operand anchor {operand_fragment!r}"
        )


def _verify_otool(text: str) -> None:
    functions = parse_otool_functions(text)
    for register in ("w0", "d0", "s1", "x1"):
        _require_instruction(functions, "capture_mixed", "str", f"{register},")
    for register in ("d0", "x0"):
        _require_instruction(functions, "capture_bank_collision", "str", f"{register},")
    _require_instruction(functions, "capture_ninth_integer", "ldr", "x10,[sp]")
    _require_instruction(functions, "capture_ninth_integer", "str", "x8,")
    _require_instruction(functions, "capture_packed_chars", "ldrb", "w10,[sp]")
    _require_instruction(functions, "capture_packed_chars", "ldrb", "w10,[sp,#0x1]")
    _require_instruction(functions, "capture_shared_nsaa", "ldrb", "w10,[sp]")
    _require_instruction(functions, "capture_shared_nsaa", "str", "d0,")
    _require_instruction(functions, "capture_shared_nsaa", "ldr", "d9,[sp,#0x8]")
    _require_instruction(functions, "capture_shared_nsaa", "ldrb", "w10,[sp,#0x10]")
    _require_instruction(functions, "capture_independent_bank_spill", "ldr", "d9,[sp]")
    _require_instruction(functions, "capture_independent_bank_spill", "str", "w0,")
    _require_instruction(
        functions, "capture_independent_bank_spill", "ldr", "d9,[sp,#0x8]"
    )
    _require_instruction(functions, "capture_independent_bank_spill", "str", "x1,")
    for register in ("w0", "x0", "s0", "d0"):
        _require_instruction(functions, "capture_scalar_returns", "str", f"{register},")
    _require_instruction(functions, "capture_large_return", "str", "x8,")
    _require_instruction(functions, "capture_large_return", "str", "x0,")
    _require_instruction(functions, "capture_large_return", "str", "x0,[x8]")


EXPECTED_DWARF_PARAMETERS = {
    "mixed_scalars": ["integer_value", "double_value", "float_value", "pointer_value"],
    "bank_collision": ["floating_value", "pointer_value"],
    "ninth_integer": [f"i{index}" for index in range(9)],
    "packed_chars": [f"c{index}" for index in range(10)],
    "shared_nsaa": [f"c{index}" for index in range(9)]
    + [f"d{index}" for index in range(9)]
    + ["tail"],
    "independent_bank_spill": [f"d{index}" for index in range(9)]
    + ["integer_value", "d9", "pointer_value"],
    "invoke_large_return": ["marker"],
}


def _verify_dwarfdump(text: str) -> None:
    functions = parse_dwarfdump_parameter_names(text)
    for function, expected_names in EXPECTED_DWARF_PARAMETERS.items():
        actual = functions.get(function)
        if actual != expected_names:
            raise OracleError(
                f"dwarfdump: {function} formal order {actual!r} != {expected_names!r}"
            )


def _stack(offset: int, size: int, alignment: int) -> str:
    return f"entry_sp+{offset}[{size}/{alignment}]"


ORACLE_CASES = [
    {
        "name": "mixed_scalars",
        "parameter_types": ["int", "double", "float", "void *"],
        "locations": ["w0", "d0", "s1", "x1"],
    },
    {
        "name": "bank_collision",
        "parameter_types": ["double", "char *"],
        "locations": ["d0", "x0"],
    },
    {
        "name": "ninth_integer",
        "parameter_types": ["int64_t"] * 9,
        "locations": [f"x{index}" for index in range(8)] + [_stack(0, 8, 8)],
    },
    {
        "name": "packed_chars",
        "parameter_types": ["char"] * 10,
        "locations": [f"w{index}" for index in range(8)]
        + [_stack(0, 1, 1), _stack(1, 1, 1)],
    },
    {
        "name": "shared_nsaa",
        "parameter_types": ["char"] * 9 + ["double"] * 9 + ["char"],
        "locations": [f"w{index}" for index in range(8)]
        + [_stack(0, 1, 1)]
        + [f"d{index}" for index in range(8)]
        + [_stack(8, 8, 8), _stack(16, 1, 1)],
    },
    {
        "name": "independent_bank_spill",
        "parameter_types": ["double"] * 9 + ["int", "double", "void *"],
        "locations": [f"d{index}" for index in range(8)]
        + [_stack(0, 8, 8), "w0", _stack(8, 8, 8), "x1"],
    },
]


def run_external_oracle() -> dict[str, object]:
    source = FIXTURE_DIR / "parameter_identity.c"
    assembly = FIXTURE_DIR / "entry_capture.s"
    for fixture in (source, assembly):
        if not fixture.is_file():
            raise OracleError(f"missing fixture source: {fixture}")

    clang = _xcrun_find("clang")
    dsymutil = _xcrun_find("dsymutil")
    dwarfdump = _xcrun_find("dwarfdump")
    otool = _xcrun_find("otool")
    compiler_version = _run_checked([clang, "--version"]).stdout.splitlines()[0]
    developer_dir = _run_checked(["/usr/bin/xcode-select", "-p"]).stdout.strip()
    sdk_path = _run_checked(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"]
    ).stdout.strip()
    if not developer_dir.startswith("/Applications/Xcode"):
        raise OracleError(f"active developer directory is not Xcode: {developer_dir}")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise OracleError(
            f"fixture execution requires arm64 macOS, got "
            f"{platform.system()} {platform.machine()}"
        )
    if not Path(sdk_path).is_dir():
        raise OracleError(f"active macOS SDK is unavailable: {sdk_path}")

    target = "arm64-apple-macos26.4"
    with tempfile.TemporaryDirectory(prefix="macscope-parameter-binding-") as temporary:
        build = Path(temporary)
        c_object = build / "parameter_identity.o"
        assembly_object = build / "entry_capture.o"
        executable = build / "parameter_binding_fixture"
        dsym = build / "parameter_binding_fixture.dSYM"

        _run_checked(
            [
                clang,
                "-target",
                target,
                "-isysroot",
                sdk_path,
                "-std=c17",
                "-g",
                "-O0",
                "-fno-omit-frame-pointer",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-c",
                str(source),
                "-o",
                str(c_object),
            ]
        )
        _run_checked(
            [
                clang,
                "-target",
                target,
                "-isysroot",
                sdk_path,
                "-g",
                "-c",
                str(assembly),
                "-o",
                str(assembly_object),
            ]
        )
        _run_checked(
            [
                clang,
                "-target",
                target,
                "-isysroot",
                sdk_path,
                str(c_object),
                str(assembly_object),
                "-o",
                str(executable),
            ]
        )
        _run_checked([dsymutil, str(executable), "-o", str(dsym)])

        runtime = _run_checked([str(executable)])
        if runtime.stdout.strip() != "parameter-binding-sentinels-ok":
            raise OracleError(
                "runtime sentinel harness returned without its exact success marker"
            )

        dwarf_text = _run_checked([dwarfdump, "--debug-info", str(dsym)]).stdout
        _verify_dwarfdump(dwarf_text)
        otool_text = _run_checked([otool, "-tvV", str(executable)]).stdout
        _verify_otool(otool_text)

        executable_sha256 = _sha256(executable)

    return {
        "schema": "parameter-binding-oracle-v1",
        "toolchain": {
            "developer_dir": developer_dir,
            "clang": clang,
            "clang_version": compiler_version,
            "sdk": sdk_path,
            "target": target,
        },
        "fixtures": {
            source.name: _sha256(source),
            assembly.name: _sha256(assembly),
            "executable_sha256": executable_sha256,
        },
        "proofs": {
            "runtime_sentinels": True,
            "dwarf_source_order": True,
            "otool_entry_capture": True,
        },
        "cases": ORACLE_CASES,
        "returns": {
            "int32": "w0",
            "int64": "x0",
            "float": "s0",
            "double": "d0",
        },
        "x8_negative_control": {
            "source_formal_count": 1,
            "source_formal_location": "x0",
            "hidden_result_channel": "x8",
        },
    }


def _valid_audit() -> dict[str, object]:
    return {
        "schema": "parameter-binding-audit-v1",
        "validation_scope": "structural-candidate",
        "combined_oracle_comparison": False,
        "function": "mixed_scalars",
        "address": "0x1000",
        "declaration_mode": "ordinary",
        "dangling_body_uses": [],
        "records": [
            {
                "function": "mixed_scalars",
                "declaration_mode": "ordinary",
                "row_ordinal": 0,
                "binding": "gpr:0",
                "source_position": 0,
                "location": "w0",
                "evidence": "authoritative_debug",
                "name": "integer_value",
                "type": "int",
                "body_uses": [{"address": "0x1000", "occurrence": 0}],
            },
            {
                "function": "mixed_scalars",
                "declaration_mode": "ordinary",
                "row_ordinal": 1,
                "binding": "simd:0",
                "source_position": 1,
                "location": "d0",
                "evidence": "authoritative_debug",
                "name": "double_value",
                "type": "double",
                "body_uses": [{"address": "0x1004", "occurrence": 0}],
            },
        ],
    }


class CandidateAuditValidationTests(unittest.TestCase):
    def assert_rejected(self, payload: dict[str, object], phrase: str) -> None:
        with self.assertRaisesRegex(OracleError, phrase):
            validate_candidate_audit(payload, "self-test")

    def test_valid_candidate_audit(self) -> None:
        self.assertEqual(validate_candidate_audit(_valid_audit(), "self-test"), 2)

    def test_ungrounded_combined_comparison_cli_is_disabled(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "--compare-audit",
                "/tmp/nonexistent-candidate-audit.json",
                "--comparison",
                "/tmp/nonexistent-comparison.json",
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("combined comparison mode is disabled", result.stderr)

    def test_empty_candidate_is_abi_only_without_fabricated_void(self) -> None:
        payload = _valid_audit()
        payload["declaration_mode"] = "abi-only"
        payload["records"] = []
        self.assertEqual(validate_candidate_audit(payload, "self-test"), 0)

    def test_duplicate_binding(self) -> None:
        payload = _valid_audit()
        payload["records"][1]["binding"] = "gpr:0"
        payload["records"][1]["location"] = "x0"
        self.assert_rejected(payload, "duplicate binding")

    def test_dangling_body_use(self) -> None:
        payload = _valid_audit()
        payload["dangling_body_uses"] = [
            {"binding": "gpr:7", "address": "0x1008", "occurrence": 0}
        ]
        self.assert_rejected(payload, "dangling body use")

    def test_compressed_sparse_input(self) -> None:
        payload = _valid_audit()
        payload["records"] = [copy.deepcopy(payload["records"][0])]
        row = payload["records"][0]
        row["binding"] = "gpr:1"
        row["location"] = "x1"
        row["evidence"] = "heuristic_entry_read"
        self.assert_rejected(payload, "compressed sparse input")

    def test_structural_candidate_cannot_embed_comparison_fields(self) -> None:
        payload = _valid_audit()
        payload["records"][0]["baseline_body_sha256"] = "a" * 64
        self.assert_rejected(payload, "embeds comparison field")

    def test_authoritative_source_order_must_match_external_fixture(self) -> None:
        payload = _valid_audit()
        payload["records"][0]["source_position"] = 1
        payload["records"][1]["source_position"] = 0
        self.assert_rejected(payload, "ordinary source positions")

class ExternalTextParsingTests(unittest.TestCase):
    def test_dwarfdump_parameter_counts(self) -> None:
        text = """
0x0001: DW_TAG_subprogram
          DW_AT_name ("mixed_scalars")
0x0002:   DW_TAG_formal_parameter
            DW_AT_name ("integer_value")
0x0003:   DW_TAG_formal_parameter
            DW_AT_name ("double_value")
0x0004: DW_TAG_subprogram
          DW_AT_name ("invoke_large_return")
0x0005:   DW_TAG_formal_parameter
            DW_AT_name ("marker")
"""
        self.assertEqual(
            parse_dwarfdump_parameter_names(text),
            {
                "mixed_scalars": ["integer_value", "double_value"],
                "invoke_large_return": ["marker"],
            },
        )

    def test_otool_function_instruction_operands(self) -> None:
        text = """
_capture_mixed:
0000000100001000\tstr\tw0, [x9]
0000000100001004\tstr\td0, [x9]
_capture_large_return:
0000000100001008\tstr\tx8, [x9]
000000010000100c\tstr\tx0, [x9]
"""
        functions = parse_otool_functions(text)
        self.assertEqual(
            functions["capture_mixed"],
            [("str", "w0, [x9]"), ("str", "d0, [x9]")],
        )
        self.assertEqual(functions["capture_large_return"][0], ("str", "x8, [x9]"))


def run_self_tests() -> int:
    stream = io.StringIO()
    suite = unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__))
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    print(stream.getvalue(), end="")
    if result.wasSuccessful():
        print(
            "false-pass gates exercised: duplicate binding; dangling body use; "
            "compressed sparse input; embedded comparison fields; source order; "
            "combined comparison disabled"
        )
    return 0 if result.wasSuccessful() else 1


def _load_json(path: Path, label: str) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise OracleError(f"cannot read {label} {path}: {error}") from error


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compile and verify the reduced WS-14 Darwin arm64 ABI fixture."
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--json", action="store_true")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--validate-audit", type=Path)
    mode.add_argument(
        "--compare-audit",
        type=Path,
        help="disabled until a provenance-bound external comparison producer exists",
    )
    parser.add_argument(
        "--comparison",
        type=Path,
        help="disabled legacy comparison input",
    )
    args = parser.parse_args()
    if args.self_test:
        return run_self_tests()
    try:
        if args.validate_audit is not None:
            if args.comparison is not None:
                raise OracleError(
                    "combined comparison mode is disabled; use structural --validate-audit "
                    "and the separate active-compiler oracle"
                )
            payload = _load_json(args.validate_audit, "candidate audit")
            count = validate_candidate_audit(payload, str(args.validate_audit))
            result: dict[str, object] = {
                "schema": "parameter-binding-audit-validation-v1",
                "validation_scope": "structural-candidate",
                "combined_oracle_comparison": False,
                "valid": True,
                "record_count": count,
            }
        elif args.compare_audit is not None or args.comparison is not None:
            raise OracleError(
                "combined comparison mode is disabled; use structural --validate-audit "
                "and the separate active-compiler oracle"
            )
        else:
            result = run_external_oracle()
    except OracleError as error:
        print(f"parameter-binding oracle: {error}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    elif args.validate_audit is not None:
        print(
            f"{result['validation_scope']} audit valid: "
            f"{result['record_count']} record(s)"
        )
    else:
        print("parameter-binding oracle passed")
        print(f"  compiler: {result['toolchain']['clang_version']}")
        print(f"  cases:    {len(result['cases'])}")
        print("  proofs:   runtime sentinels + dwarfdump + otool")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
