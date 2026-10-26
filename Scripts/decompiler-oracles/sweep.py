#!/usr/bin/env python3
"""Corpus decompiler sweep + RegionTree per-veto histogram.

Two passes per binary:
  1. `functions` -> all function addresses.
  2. decompile every address with MACSCOPE_REGIONTREE_DIAGNOSTICS=1; capture stderr.

Produces, per binary and aggregated:
  - fallback distribution (structured / unsupportedRegion / unstructurableCFG / ...)
  - per-function FATAL veto histogram (the actionable metric: one bail cause per fn)
  - per-SITE veto histogram (recursive; how often each veto site was hit total)
Also writes <out>/<base>.json records with pseudocode, diagnostics, parameter facts,
and source-address-bound pair-line facts for differentials.

Usage: sweep.py <MacScope-binary> <out-dir> [binary1 binary2 ...]
"""
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
import tempfile
import unicodedata
from collections import Counter
from contextlib import contextmanager
from pathlib import Path

SELF_TEST_MODE = sys.argv[1:] == ["--self-test"]
if SELF_TEST_MODE:
    MACSCOPE = ""
    OUTDIR = ""
    CORPUS = []
else:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    MACSCOPE = sys.argv[1]
    OUTDIR = sys.argv[2]
    CORPUS = sys.argv[3:] or ["/bin/ls", "/usr/bin/grep", "/usr/bin/ssh", "/bin/zsh"]
    os.makedirs(OUTDIR, exist_ok=True)

PRODUCER_SCHEMA = "macscope-sweep-producer-v3"
RECORD_SCHEMA = "macscope-sweep-record-v6"
PARAMETER_AUDIT_SCHEMA = "parameter-binding-audit-v1"
PAIR_LINE_AUDIT_SCHEMA = "pair-line-instruction-audit-v1"
INSTRUCTION_LINE_AUDIT_SCHEMA = "instruction-line-audit-v1"
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PRODUCER_CODE_PATH = "Scripts/decompiler-oracles/sweep.py"
FROZEN_CATALOG_SOURCE_SHA256 = {
    "MacScope/Services/Decompiler/CallSignatureCatalog.swift": (
        "40581aeec9fec51439fa4380b623f08fe54bb1a1415e7fdb78b19aae72b3f658"
    ),
    "MacScope/Services/Decompiler/CallSignatureCorpus.swift": (
        "eda045883557537e89852ec34e95b63963734b7d3b55cf894e7d09eeaacb5e29"
    ),
}
EXPECTED_FROZEN_SIGNATURE_LAYOUT_SHA256 = (
    "9d142025601313dde0bc1d3372a62d30c51229ae42c8acacd0e7e03e0dc972a7"
)
FROZEN_SEED_SIGNATURES = {
    "malloc": (("size_t",), False),
    "calloc": (("size_t", "size_t"), False),
    "free": (("void *",), False),
    "strlen": (("const char *",), False),
    "strcmp": (("const char *", "const char *"), False),
    "strncmp": (("const char *", "const char *", "size_t"), False),
    "memcpy": (("void *", "const void *", "size_t"), False),
    "memset": (("void *", "int32_t", "size_t"), False),
    "puts": (("const char *",), False),
    "printf": (("const char *",), True),
    "objc_msgSend": (("id", "SEL"), True),
    "swift_retain": (("void *",), False),
    "swift_unknownObjectRetain": (("void *",), False),
    "swift_release": (("void *",), False),
    "swift_unknownObjectRelease": (("void *",), False),
    "memmove": (("void *", "const void *", "size_t"), False),
    "realloc": (("void *", "size_t"), False),
    "strncpy": (("char *", "const char *", "size_t"), False),
    "strcpy": (("char *", "const char *"), False),
    "strcat": (("char *", "const char *"), False),
    "strncat": (("char *", "const char *", "size_t"), False),
    "strchr": (("const char *", "int32_t"), False),
    "strdup": (("const char *",), False),
    "fwrite": (("const void *", "size_t", "size_t", "void *"), False),
    "fputs": (("const char *", "void *"), False),
    "snprintf": (("char *", "size_t", "const char *"), True),
    "asprintf": (("char **", "const char *"), True),
    "NSLog": (("NSString *",), True),
    "objc_retain": (("id",), False),
    "objc_release": (("id",), False),
    "objc_autorelease": (("id",), False),
    "objc_retainAutoreleasedReturnValue": (("id",), False),
    "objc_msgSendSuper": (("struct objc_super *", "SEL"), True),
}
PRODUCER_PATH = os.path.join(OUTDIR, "_producer.json") if OUTDIR else ""
ACTIVE_MACSCOPE = None
ACTIVE_CORPUS_PATHS = {}

CORPUS_BY_BASE = {}
CORPUS_BASE_CASEFOLDS = {}
for corpus_path in CORPUS:
    corpus_base = os.path.basename(corpus_path)
    if not corpus_base or corpus_base in {".", ".."} or corpus_base.startswith("_"):
        raise RuntimeError(f"corpus path has a reserved basename: {corpus_path!r}")
    collision_key = corpus_base.casefold()
    if collision_key in CORPUS_BASE_CASEFOLDS:
        previous_base = CORPUS_BASE_CASEFOLDS[collision_key]
        raise RuntimeError(
            f"duplicate corpus basename {corpus_base!r}: "
            f"{CORPUS_BY_BASE[previous_base]!r} and {corpus_path!r}"
        )
    CORPUS_BY_BASE[corpus_base] = corpus_path
    CORPUS_BASE_CASEFOLDS[collision_key] = corpus_base

DIAG = re.compile(
    r'REGIONTREE_DIAGNOSTICS\tfunction=(?P<fn>.*?)\tfallback=(?P<fb>.*?)\tfatal=(?P<fatal>.*?)\tsites=(?P<sites>.*)')
RETURNING_CALL_MNEMONICS = {"bl", "blr", "blraa", "blrab", "blraaz", "blrabz"}


def _duplicate_safe_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise RuntimeError(f"JSON object duplicates key {key!r}")
        result[key] = value
    return result


def _reject_json_constant(value):
    raise RuntimeError(f"JSON contains non-finite number {value}")


def strict_json_loads(text, context):
    try:
        return json.loads(
            text,
            object_pairs_hook=_duplicate_safe_object,
            parse_constant=_reject_json_constant,
        )
    except RuntimeError:
        raise
    except (TypeError, json.JSONDecodeError) as error:
        raise RuntimeError(f"{context}: response is not strict JSON: {error}") from error


def canonical_address(value, context):
    if not isinstance(value, str) or not value:
        raise RuntimeError(f"{context}: address must be a nonempty string")
    try:
        numeric = int(value, 16)
    except ValueError as error:
        raise RuntimeError(f"{context}: address is not hexadecimal") from error
    if numeric < 0 or numeric > 0xFFFF_FFFF_FFFF_FFFF or value != hex(numeric):
        raise RuntimeError(f"{context}: address is not canonical unslid hexadecimal")
    return value

def run_script(steps, binary, diag=False):
    descriptor, script_path = tempfile.mkstemp(
        prefix="_script-", suffix=".json", dir=OUTDIR, text=True
    )
    try:
        with os.fdopen(descriptor, "w") as script_file:
            json.dump(steps, script_file)
            script_file.flush()
            os.fsync(script_file.fileno())
        env = dict(os.environ)
        if diag:
            env["MACSCOPE_REGIONTREE_DIAGNOSTICS"] = "1"
        executable = ACTIVE_MACSCOPE or MACSCOPE
        execution_binary = ACTIVE_CORPUS_PATHS.get(binary, binary)
        p = subprocess.run([MACSCOPE, "--run-script", script_path, execution_binary],
                           executable=executable,
                           capture_output=True, text=True, env=env, timeout=600)
    finally:
        try:
            os.unlink(script_path)
        except FileNotFoundError:
            pass
    if p.returncode != 0:
        diagnostic = (p.stderr or p.stdout).strip().splitlines()
        first_line = diagnostic[0] if diagnostic else "no diagnostic"
        raise RuntimeError(
            f"MacScope script failed for {binary} (exit {p.returncode}): {first_line}"
        )
    return p.stdout, p.stderr


def parse_script_results(text, context):
    results = strict_json_loads(text, context)
    if not isinstance(results, list):
        raise RuntimeError(f"{context}: script response is not a per-step array")
    return results


def validate_command_capabilities(commands, context):
    if not isinstance(commands, list):
        raise RuntimeError(f"{context}: commands response must be an array")
    matches = {"parameter-binding-audit": [], "call-argument-audit": []}
    for index, command in enumerate(commands):
        command_context = f"{context}[{index}]"
        if not isinstance(command, dict) or set(command) != {
            "name", "summary", "mutates", "arguments"
        }:
            raise RuntimeError(f"{command_context}: command descriptor is not closed")
        if not isinstance(command["name"], str) or not command["name"]:
            raise RuntimeError(f"{command_context}: command name is invalid")
        if not isinstance(command["summary"], str):
            raise RuntimeError(f"{command_context}: command summary is invalid")
        if type(command["mutates"]) is not bool:
            raise RuntimeError(f"{command_context}: command mutates flag is invalid")
        if not isinstance(command["arguments"], list) or not all(
            isinstance(argument, str) and argument for argument in command["arguments"]
        ):
            raise RuntimeError(f"{command_context}: command arguments are invalid")
        if command["name"] in matches:
            matches[command["name"]].append(command)

    result = {}
    for name, key in (
        ("parameter-binding-audit", "parameter_binding_audit_available"),
        ("call-argument-audit", "call_argument_audit_available"),
    ):
        descriptors = matches[name]
        if len(descriptors) > 1:
            raise RuntimeError(f"{context}: duplicate {name} command descriptor")
        if not descriptors:
            result[key] = False
            continue
        descriptor = descriptors[0]
        if descriptor["mutates"] is not False:
            raise RuntimeError(f"{context}: {name} command is not read-only")
        if descriptor["arguments"] != ["function", "address"]:
            raise RuntimeError(f"{context}: {name} command arguments are not canonical")
        result[key] = True
    return result


def validate_functions_response(value, context):
    if not isinstance(value, list) or not value:
        raise RuntimeError(f"{context}: functions response must be a nonempty array")
    validated = []
    prior_start = -1
    prior_end = -1
    for index, raw in enumerate(value):
        row_context = f"{context}[{index}]"
        row = exact_object(
            raw, {"name", "address", "end", "confidence"}, row_context
        )
        name = require_string(row["name"], f"{row_context}.name", allow_empty=True)
        address = canonical_address(row["address"], f"{row_context}.address")
        end = canonical_address(row["end"], f"{row_context}.end")
        start_numeric = int(address, 16)
        end_numeric = int(end, 16)
        if start_numeric <= prior_start:
            raise RuntimeError(f"{context}: function starts are duplicate or unordered")
        if end_numeric < start_numeric:
            raise RuntimeError(f"{row_context}: function end precedes start")
        if prior_end > start_numeric:
            raise RuntimeError(f"{context}: function ranges overlap")
        confidence = row["confidence"]
        if type(confidence) not in {int, float} or not math.isfinite(confidence):
            raise RuntimeError(f"{row_context}: confidence must be a finite number")
        validated.append({
            "name": name,
            "address": address,
            "end": end,
            "confidence": confidence,
        })
        prior_start = start_numeric
        prior_end = end_numeric
    return validated


def instruction_query_count(function):
    start = int(function["address"], 16)
    end = int(function["end"], 16)
    return max(1, ((end - start) // 4) + 1)


def returning_instruction_addresses(value, function, context):
    if not isinstance(value, list):
        raise RuntimeError(f"{context}: instructions response must be an array")
    start = int(function["address"], 16)
    end = int(function["end"], 16)
    prior_address = -1
    returning = []
    for index, raw in enumerate(value):
        row_context = f"{context}[{index}]"
        if not isinstance(raw, dict):
            raise RuntimeError(f"{row_context}: instruction must be an object")
        expected_keys = {"address", "bytes", "mnemonic", "operands"}
        if "comment" in raw:
            expected_keys.add("comment")
        row = exact_object(raw, expected_keys, row_context)
        address = canonical_address(row["address"], f"{row_context}.address")
        numeric = int(address, 16)
        if numeric <= prior_address:
            raise RuntimeError(f"{context}: instruction addresses are duplicate or unordered")
        prior_address = numeric
        require_string(row["bytes"], f"{row_context}.bytes", allow_empty=True)
        mnemonic = require_string(row["mnemonic"], f"{row_context}.mnemonic")
        require_string(row["operands"], f"{row_context}.operands", allow_empty=True)
        if "comment" in row:
            require_string(row["comment"], f"{row_context}.comment", allow_empty=True)
        in_range = start <= numeric < end if end > start else numeric == start
        if in_range and mnemonic.lower() in RETURNING_CALL_MNEMONICS:
            returning.append(address)
    return returning


def probe_capabilities(binary, context="commands"):
    out, _ = run_script([{"command": "commands"}], binary)
    results = parse_script_results(out, context)
    if len(results) != 1 or not isinstance(results[0], list):
        raise RuntimeError(f"{context}: commands response has an unexpected envelope")
    return validate_command_capabilities(results[0], context)


def supports_parameter_binding_audit(binary):
    return probe_capabilities(binary)[
        "parameter_binding_audit_available"
    ]


def validate_parameter_binding_audit(audit, address, context):
    audit = exact_object(
        audit,
        {
            "schema", "validation_scope", "combined_oracle_comparison", "function",
            "address", "declaration_mode", "records", "dangling_body_uses",
        },
        context,
    )
    if audit["schema"] != PARAMETER_AUDIT_SCHEMA:
        raise RuntimeError(f"{context}: parameter audit has an unsupported schema")
    if audit["validation_scope"] != "structural-candidate":
        raise RuntimeError(f"{context}: parameter audit is not candidate-structural")
    if audit["combined_oracle_comparison"] is not False:
        raise RuntimeError(f"{context}: app audit claims an external comparison")
    require_string(audit["function"], f"{context}.function", allow_empty=True)
    if audit["address"] != address:
        raise RuntimeError(
            f"{context}: parameter audit address {audit['address']!r} != {address!r}"
        )
    canonical_address(audit["address"], f"{context}.address")
    require_string(audit["declaration_mode"], f"{context}.declaration_mode")
    if not isinstance(audit["records"], list):
        raise RuntimeError(f"{context}: parameter audit lacks a records array")
    for index, raw_record in enumerate(audit["records"]):
        record_context = f"{context}.records[{index}]"
        record = exact_object(
            raw_record,
            {
                "function", "declaration_mode", "row_ordinal", "binding",
                "source_position", "location", "evidence", "name", "type",
                "body_uses",
            },
            record_context,
        )
        require_string(record["function"], f"{record_context}.function", allow_empty=True)
        require_string(record["declaration_mode"], f"{record_context}.declaration_mode")
        require_integer(record["row_ordinal"], f"{record_context}.row_ordinal", 0)
        if record["binding"] is not None:
            require_string(record["binding"], f"{record_context}.binding")
        if record["source_position"] is not None:
            require_integer(
                record["source_position"], f"{record_context}.source_position", 0
            )
        for key in ("location", "evidence", "name", "type"):
            require_string(
                record[key], f"{record_context}.{key}", allow_empty=key == "name"
            )
        if not isinstance(record["body_uses"], list):
            raise RuntimeError(f"{record_context}.body_uses must be an array")
        for use_index, raw_use in enumerate(record["body_uses"]):
            use_context = f"{record_context}.body_uses[{use_index}]"
            use = exact_object(raw_use, {"address", "occurrence"}, use_context)
            canonical_address(use["address"], f"{use_context}.address")
            require_integer(use["occurrence"], f"{use_context}.occurrence", 0)
    if not isinstance(audit["dangling_body_uses"], list):
        raise RuntimeError(f"{context}: parameter audit lacks dangling-body-use facts")
    for index, raw_dangling in enumerate(audit["dangling_body_uses"]):
        dangling_context = f"{context}.dangling_body_uses[{index}]"
        dangling = exact_object(
            raw_dangling, {"binding", "address", "occurrence"}, dangling_context
        )
        require_string(dangling["binding"], f"{dangling_context}.binding")
        canonical_address(dangling["address"], f"{dangling_context}.address")
        require_integer(
            dangling["occurrence"], f"{dangling_context}.occurrence", 0
        )
    return audit


def exact_object(value, keys, context):
    if not isinstance(value, dict):
        raise RuntimeError(f"{context}: must be an object")
    actual = set(value)
    expected = set(keys)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        raise RuntimeError(
            f"{context}: object is not closed (missing={missing}, unknown={unknown})"
        )
    return value


def require_integer(value, context, minimum=None, maximum=None):
    if type(value) is bool or type(value) is not int:
        raise RuntimeError(f"{context}: must be a JSON integer, never a boolean")
    if minimum is not None and value < minimum:
        raise RuntimeError(f"{context}: is below {minimum}")
    if maximum is not None and value > maximum:
        raise RuntimeError(f"{context}: is above {maximum}")
    return value


def require_string(value, context, allow_empty=False, allow_controls=False):
    if not isinstance(value, str) or (not allow_empty and not value):
        raise RuntimeError(f"{context}: must be a string")
    if not allow_controls and any(
        unicodedata.category(character).startswith("C")
        or character in {"\u2028", "\u2029"}
        for character in value
    ):
        raise RuntimeError(f"{context}: contains a control character")
    return value


def require_digest(value, context):
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise RuntimeError(f"{context}: must be lowercase SHA-256 hex")
    return value


TOOLCHAIN_KEYS = {
    "xcode_version", "xcode_build", "sdk_canonical_name", "sdk_version",
    "clang_version",
}
AUDIT_KEYS = {
    "schema", "validation_scope", "combined_oracle_comparison", "image_slot",
    "binary_sha256", "producer_executable_sha256", "toolchain_identity",
    "function", "calls",
}
CALL_KEYS = {
    "instruction_address", "target", "known_signature_id", "tail_count_evidence",
    "rendered_line_ordinal", "rendered_occurrence_ordinal", "rendered_utf8_sha256",
    "observation", "control_inputs", "arguments",
}
LOCATION_KEYS = {
    "kind", "index", "carrier_width", "scalar_width", "byte_offset", "size",
    "alignment",
}
ARGUMENT_KEYS = {
    "location", "role", "source_position", "tail_ordinal", "value_identity",
    "selector_name", "selector_selref_address", "safe_render_included",
    "safe_render_reason",
}
VALUE_REGISTER_RE = re.compile(
    r"(?:[xw](?:[0-9]|[12][0-9]|30)|[sdqv](?:[0-9]|[12][0-9]|3[01])|"
    r"sp|wsp|xzr|wzr)"
)
CONTROL_REGISTER_RE = re.compile(r"x(?:[0-9]|[12][0-9]|30)|sp")
SELECTOR_IDENTIFIER_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
TRUE_RENDER_REASONS = {"fixed-prefix", "unknown-gpr-prefix", "objc-complete-message"}
FALSE_RENDER_REASONS = {
    "fixed-gap", "unknown-gap", "anonymous-incomplete", "unproven-bank-order",
    "unproven-stack", "selector-ineligible",
}
INTEGER_64_TYPES = {
    "int64_t", "uint64_t", "size_t", "ssize_t", "off_t", "long", "long int",
    "long long", "long long int", "unsigned long", "unsigned long long",
    "unsigned long long int", "clock_t", "pthread_key_t", "pthread_t", "time_t",
    "va_list", "void *", "const void *", "char *", "const char *", "id", "SEL",
}
INTEGER_32_TYPES = {
    "int32_t", "uint32_t", "int", "unsigned int", "BOOL", "clockid_t", "dev_t",
    "gid_t", "pid_t", "sae_associd_t", "sae_connid_t", "socklen_t", "uid_t",
    "wchar_t", "uint16_t", "int16_t", "mode_t", "uint8_t", "int8_t", "char",
}
CORPUS_ENTRY_RE = re.compile(
    r'^\s*s\("(?P<name>[^"]+)",\s*"(?P<return>[^"]+)"(?P<rest>.*)\),\s*$'
)
CORPUS_PARAMETER_RE = re.compile(r'\("(?P<type>[^"]+)",\s*"(?P<name>[^"]+)"\)')


def validate_toolchain_identity(value, context):
    toolchain = exact_object(value, TOOLCHAIN_KEYS, context)
    for key in sorted(TOOLCHAIN_KEYS):
        require_string(toolchain[key], f"{context}.{key}")
    return toolchain


def _run_toolchain_command(command, environment):
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            env=environment,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"toolchain command failed to launch {command!r}: {error}") from error
    if result.returncode != 0:
        diagnostic = (result.stderr or result.stdout).strip().splitlines()
        first = diagnostic[0] if diagnostic else "no diagnostic"
        raise RuntimeError(
            f"toolchain command failed {command!r} (exit {result.returncode}): {first}"
        )
    return result.stdout if result.stdout.strip() else result.stderr


def sample_active_toolchain(run_command=None, environment=None):
    runner = run_command or _run_toolchain_command
    controlled = dict(os.environ if environment is None else environment)
    controlled["LANG"] = "C"
    controlled["LC_ALL"] = "C"
    controlled["LANGUAGE"] = "C"
    inherited_developer_dir = controlled.get("DEVELOPER_DIR")
    if inherited_developer_dir:
        developer_dir = str(Path(inherited_developer_dir).expanduser().resolve())
    else:
        selected_output = runner(["/usr/bin/xcode-select", "-p"], controlled)
        selected_lines = [
            line.strip() for line in selected_output.splitlines() if line.strip()
        ]
        if len(selected_lines) != 1:
            raise RuntimeError("xcode-select returned a noncanonical developer directory")
        developer_dir = str(Path(selected_lines[0]).expanduser().resolve())
    if not os.path.isabs(developer_dir):
        raise RuntimeError("active developer directory is not absolute")
    controlled["DEVELOPER_DIR"] = developer_dir
    xcode_output = runner(["/usr/bin/xcodebuild", "-version"], controlled)
    xcode_lines = [line.strip() for line in xcode_output.splitlines() if line.strip()]
    if (
        len(xcode_lines) != 2
        or not xcode_lines[0].startswith("Xcode ")
        or not xcode_lines[1].startswith("Build version ")
    ):
        raise RuntimeError("active xcodebuild returned a noncanonical version response")
    xcode_version = xcode_lines[0][len("Xcode "):]
    xcode_build = xcode_lines[1][len("Build version "):]
    require_string(xcode_version, "active Xcode version")
    require_string(xcode_build, "active Xcode build")
    sdk_output = runner(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"], controlled
    )
    sdk_lines = [line.strip() for line in sdk_output.splitlines() if line.strip()]
    if len(sdk_lines) != 1:
        raise RuntimeError("active SDK version response is not canonical")
    sdk_version = require_string(sdk_lines[0], "active SDK version")
    clang_output = runner(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--find", "clang"], controlled
    )
    clang_lines = [line.strip() for line in clang_output.splitlines() if line.strip()]
    if len(clang_lines) != 1 or not os.path.isabs(clang_lines[0]):
        raise RuntimeError("active clang path response is not canonical")
    clang_version_output = runner([clang_lines[0], "--version"], controlled)
    clang_version_lines = [
        line.strip() for line in clang_version_output.splitlines() if line.strip()
    ]
    if not clang_version_lines:
        raise RuntimeError("active clang returned no version")
    identity = {
        "xcode_version": xcode_version,
        "xcode_build": xcode_build,
        "sdk_canonical_name": "macosx" + sdk_version,
        "sdk_version": sdk_version,
        "clang_version": clang_version_lines[0],
    }
    return validate_toolchain_identity(identity, "active toolchain")


def validate_value_identity(value, context, depth=0):
    if depth > 32:
        raise RuntimeError(f"{context}: value identity exceeds recursion depth 32")
    if not isinstance(value, dict):
        raise RuntimeError(f"{context}: value identity must be an object")
    kind = value.get("kind")
    if kind == "register":
        record = exact_object(value, {"kind", "name", "version"}, context)
        name = require_string(record["name"], f"{context}.name")
        if VALUE_REGISTER_RE.fullmatch(name) is None:
            raise RuntimeError(f"{context}: invalid value register")
        require_integer(record["version"], f"{context}.version", 0)
    elif kind == "argument":
        record = exact_object(value, {"kind", "binding_kind", "binding_value"}, context)
        binding_kind = record["binding_kind"]
        if binding_kind not in {"gpr", "simd", "entry-stack"}:
            raise RuntimeError(f"{context}: invalid argument binding kind")
        maximum = 7 if binding_kind in {"gpr", "simd"} else None
        require_integer(record["binding_value"], f"{context}.binding_value", 0, maximum)
    elif kind == "immediate":
        record = exact_object(value, {"kind", "value"}, context)
        require_integer(record["value"], f"{context}.value", -(1 << 63), (1 << 63) - 1)
    elif kind == "stack-slot":
        record = exact_object(value, {"kind", "offset"}, context)
        require_integer(record["offset"], f"{context}.offset", -(1 << 63), (1 << 63) - 1)
    elif kind == "symbol":
        record = exact_object(value, {"kind", "name"}, context)
        require_string(record["name"], f"{context}.name")
    elif kind == "temporary":
        record = exact_object(value, {"kind", "index"}, context)
        require_integer(record["index"], f"{context}.index", 0)
    elif kind == "bit-test":
        record = exact_object(value, {"kind", "value", "bit"}, context)
        validate_value_identity(record["value"], f"{context}.value", depth + 1)
        require_integer(record["bit"], f"{context}.bit", 0, 127)
    elif kind == "unary":
        record = exact_object(value, {"kind", "operator", "value"}, context)
        require_string(record["operator"], f"{context}.operator")
        validate_value_identity(record["value"], f"{context}.value", depth + 1)
    elif kind == "binary":
        record = exact_object(value, {"kind", "operator", "left", "right"}, context)
        require_string(record["operator"], f"{context}.operator")
        validate_value_identity(record["left"], f"{context}.left", depth + 1)
        validate_value_identity(record["right"], f"{context}.right", depth + 1)
    elif kind == "unknown":
        record = exact_object(value, {"kind", "text"}, context)
        require_string(record["text"], f"{context}.text", allow_empty=True)
    else:
        raise RuntimeError(f"{context}: unsupported value identity kind {kind!r}")


def validate_location(value, context):
    location = exact_object(value, LOCATION_KEYS, context)
    kind = location["kind"]
    if kind == "gpr":
        index = require_integer(location["index"], f"{context}.index", 0, 7)
        if type(location["carrier_width"]) is bool or location["carrier_width"] not in {32, 64}:
            raise RuntimeError(f"{context}: GPR carrier width must be 32 or 64")
        for key in ("scalar_width", "byte_offset", "size", "alignment"):
            if location[key] is not None:
                raise RuntimeError(f"{context}.{key}: must be null for GPR")
        return {"kind": kind, "index": index, "start": None, "end": None,
                "physical": (0, index), "order": (0, index, 0, 0)}
    if kind == "simd":
        index = require_integer(location["index"], f"{context}.index", 0, 7)
        if type(location["scalar_width"]) is bool or location["scalar_width"] not in {32, 64}:
            raise RuntimeError(f"{context}: SIMD scalar width must be 32 or 64")
        for key in ("carrier_width", "byte_offset", "size", "alignment"):
            if location[key] is not None:
                raise RuntimeError(f"{context}.{key}: must be null for SIMD")
        return {"kind": kind, "index": index, "start": None, "end": None,
                "physical": (1, index), "order": (1, index, 0, 0)}
    if kind == "call-stack":
        offset = require_integer(location["byte_offset"], f"{context}.byte_offset", 0,
                                 (1 << 63) - 1)
        size = require_integer(location["size"], f"{context}.size", 1, (1 << 63) - 1)
        alignment = require_integer(location["alignment"], f"{context}.alignment", 1,
                                    (1 << 63) - 1)
        if alignment & (alignment - 1) or offset % alignment:
            raise RuntimeError(f"{context}: invalid call-stack alignment")
        end = offset + size
        if end > (1 << 63) - 1:
            raise RuntimeError(f"{context}: call-stack range overflows")
        for key in ("index", "carrier_width", "scalar_width"):
            if location[key] is not None:
                raise RuntimeError(f"{context}.{key}: must be null for call-stack")
        return {"kind": kind, "index": None, "start": offset, "end": end,
                "physical": (2, offset), "order": (2, offset, size, alignment)}
    raise RuntimeError(f"{context}: unsupported location kind")


def validate_observation(value, context):
    observation = exact_object(
        value, {"gpr_indices", "scalar_simd_indices", "call_stack_ranges"}, context
    )
    banks = []
    for key in ("gpr_indices", "scalar_simd_indices"):
        raw = observation[key]
        if not isinstance(raw, list):
            raise RuntimeError(f"{context}.{key}: must be an array")
        indices = tuple(
            require_integer(item, f"{context}.{key}[{index}]", 0, 7)
            for index, item in enumerate(raw)
        )
        if indices != tuple(sorted(set(indices))):
            raise RuntimeError(f"{context}.{key}: must be unique ascending")
        banks.append(indices)
    raw_ranges = observation["call_stack_ranges"]
    if not isinstance(raw_ranges, list):
        raise RuntimeError(f"{context}.call_stack_ranges: must be an array")
    ranges = []
    for index, raw_range in enumerate(raw_ranges):
        range_context = f"{context}.call_stack_ranges[{index}]"
        stack_range = exact_object(raw_range, {"start", "end"}, range_context)
        start = require_integer(stack_range["start"], f"{range_context}.start", 0,
                                (1 << 63) - 1)
        end = require_integer(stack_range["end"], f"{range_context}.end", 1,
                              (1 << 63) - 1)
        if start >= end or (ranges and start < ranges[-1][1]):
            raise RuntimeError(f"{range_context}: invalid/overlapping half-open range")
        ranges.append((start, end))
    return {"gpr": banks[0], "simd": banks[1], "stack": tuple(ranges)}


def valid_selector_name(value, context):
    selector = require_string(value, context)
    if '"' in selector or "\\" in selector:
        raise RuntimeError(f"{context}: selector contains quote or backslash")
    if any(
        unicodedata.category(character).startswith("C")
        or character in {"\r", "\n", "\u2028", "\u2029"}
        for character in selector
    ):
        raise RuntimeError(f"{context}: selector contains injection-capable scalar")
    return selector


def statement_parts(line):
    in_string = False
    escaped = False
    depth = 0
    semicolon = None
    for index, character in enumerate(line):
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character in "([":
            depth += 1
        elif character in ")]":
            depth -= 1
            if depth < 0:
                return None
        elif character == ";" and depth == 0:
            semicolon = index
            # ★ Insight: everything after the first complete statement is
            # presentation-only diagnostics. It may repeat the call target and use
            # semicolons or unmatched punctuation without changing call grammar.
            break
    if in_string or depth != 0 or semicolon is None:
        return None
    suffix = line[semicolon + 1:]
    if suffix and not suffix.startswith(" //"):
        return None
    return line[:semicolon].rstrip(), suffix


def split_top_level_arguments(text):
    if not text.strip():
        return ()
    parts = []
    start = 0
    depth = 0
    in_string = False
    escaped = False
    for index, character in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character in "([":
            depth += 1
        elif character in ")]":
            depth -= 1
            if depth < 0:
                return None
        elif character == "," and depth == 0:
            part = text[start:index].strip()
            if not part:
                return None
            parts.append(part)
            start = index + 1
    if in_string or depth != 0:
        return None
    final = text[start:].strip()
    if not final:
        return None
    parts.append(final)
    return tuple(parts)


def valid_call_prefix(prefix):
    if any(character in prefix for character in ";\r\n"):
        return False
    stripped = prefix.strip()
    return not stripped or stripped == "return" or stripped.endswith("=")


def parse_plain_call(line, target):
    statement = statement_parts(line)
    if statement is None:
        return None
    body, suffix = statement
    marker = target + "("
    positions = [match.start() for match in re.finditer(re.escape(marker), body)]
    if len(positions) != 1:
        return None
    start = positions[0]
    prefix = body[:start].rstrip()
    if not valid_call_prefix(prefix):
        return None
    open_index = start + len(target)
    depth = 0
    in_string = False
    escaped = False
    close_index = None
    for index in range(open_index, len(body)):
        character = body[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                close_index = index
                break
    if close_index is None or body[close_index + 1:].strip():
        return None
    arguments = split_top_level_arguments(body[open_index + 1:close_index])
    if arguments is None:
        return None
    return {"prefix": prefix, "arguments": arguments, "suffix": suffix}


def parse_zero_selector_message(line, selector):
    if SELECTOR_IDENTIFIER_RE.fullmatch(selector) is None:
        return None
    statement = statement_parts(line)
    if statement is None:
        return None
    body, suffix = statement
    open_index = body.find("[")
    if open_index < 0 or not body.endswith("]"):
        return None
    prefix = body[:open_index].rstrip()
    if not valid_call_prefix(prefix):
        return None
    bracket_depth = 0
    in_string = False
    escaped = False
    close_index = None
    for index in range(open_index, len(body)):
        character = body[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character == "[":
            bracket_depth += 1
        elif character == "]":
            bracket_depth -= 1
            if bracket_depth < 0:
                return None
            if bracket_depth == 0:
                close_index = index
                break
    if close_index != len(body) - 1:
        return None
    content = body[open_index + 1:-1]
    marker = " " + selector
    if not content.endswith(marker):
        return None
    receiver = content[:-len(marker)].strip()
    if not receiver:
        return None
    return {"prefix": prefix, "receiver": receiver, "suffix": suffix}


def validate_call_argument_call(raw_call, rendered_lines, metadata_lines, context):
    call = exact_object(raw_call, CALL_KEYS, context)
    instruction_address = canonical_address(
        call["instruction_address"], f"{context}.instruction_address"
    )
    target = require_string(call["target"], f"{context}.target")
    if target != target.strip():
        raise RuntimeError(f"{context}: target is not canonical")
    signature = call["known_signature_id"]
    frozen_signature = frozen_signature_for_target(target)
    if frozen_signature is not None and signature is None:
        raise RuntimeError(f"{context}: known direct target requires its exact signature ID")
    if signature is not None:
        signature = require_string(signature, f"{context}.known_signature_id")
        if signature != target:
            raise RuntimeError(f"{context}: known signature must equal target")
        if frozen_signature is None:
            raise RuntimeError(f"{context}: unknown nonnull signature ID")
    ordinal = require_integer(call["rendered_line_ordinal"],
                              f"{context}.rendered_line_ordinal", 1)
    if ordinal > len(rendered_lines):
        raise RuntimeError(f"{context}: rendered line ordinal is out of range")
    line = rendered_lines[ordinal - 1]
    metadata = metadata_lines[ordinal - 1]
    if metadata.get("kind") != "instruction" or metadata.get("address") != instruction_address:
        raise RuntimeError(f"{context}: rendered-line source address is not the call instruction")
    occurrence = require_integer(call["rendered_occurrence_ordinal"],
                                 f"{context}.rendered_occurrence_ordinal", 0)
    if occurrence != sum(1 for prior in rendered_lines[:ordinal - 1] if prior == line):
        raise RuntimeError(f"{context}: rendered occurrence is not source-bound")
    if require_digest(call["rendered_utf8_sha256"],
                      f"{context}.rendered_utf8_sha256") != hashlib.sha256(
        line.encode("utf-8")
    ).hexdigest():
        raise RuntimeError(f"{context}: rendered line digest disagrees")

    observation = validate_observation(call["observation"], f"{context}.observation")
    controls_value = call["control_inputs"]
    if not isinstance(controls_value, list):
        raise RuntimeError(f"{context}: control_inputs must be an array")
    controls = []
    roles = []
    for index, raw_control in enumerate(controls_value):
        control_context = f"{context}.control_inputs[{index}]"
        control = exact_object(raw_control, {"role", "register", "value_identity"},
                               control_context)
        role = control["role"]
        if role not in {"indirect-target", "pointer-authentication-modifier"}:
            raise RuntimeError(f"{control_context}: unsupported control role")
        register = require_string(control["register"], f"{control_context}.register")
        if CONTROL_REGISTER_RE.fullmatch(register) is None:
            raise RuntimeError(f"{control_context}: invalid control register")
        if role == "indirect-target" and register == "sp":
            raise RuntimeError(f"{control_context}: SP cannot be an indirect target")
        validate_value_identity(control["value_identity"], f"{control_context}.value_identity")
        roles.append(role)
        controls.append(control)
    if roles not in ([], ["indirect-target"],
                     ["indirect-target", "pointer-authentication-modifier"]):
        raise RuntimeError(f"{context}: controls are duplicate/missing/noncanonical")
    if controls:
        if target != f"(*{controls[0]['register']})" or signature is not None:
            raise RuntimeError(f"{context}: computed target/control/signature disagreement")
    elif target.startswith("(*"):
        raise RuntimeError(f"{context}: computed target lacks indirect control")
    if len(controls) == 2 and controls[0]["register"] == controls[1]["register"] and (
        controls[0]["value_identity"] != controls[1]["value_identity"]
    ):
        raise RuntimeError(f"{context}: same-register controls require equal values")

    tail_count = None
    if call["tail_count_evidence"] is not None:
        tail = exact_object(call["tail_count_evidence"], {"kind", "expected_tail_count"},
                            f"{context}.tail_count_evidence")
        if tail["kind"] != "objective-c-selector-colon-count":
            raise RuntimeError(f"{context}: unsupported tail evidence")
        tail_count = require_integer(tail["expected_tail_count"],
                                     f"{context}.expected_tail_count", 0)

    raw_arguments = call["arguments"]
    if not isinstance(raw_arguments, list):
        raise RuntimeError(f"{context}: arguments must be an array")
    arguments = []
    locations = []
    physical = set()
    fixed_positions = set()
    selector_rows = []
    roles_seen = set()
    stack_ranges = []
    for index, raw_argument in enumerate(raw_arguments):
        argument_context = f"{context}.arguments[{index}]"
        argument = exact_object(raw_argument, ARGUMENT_KEYS, argument_context)
        location = validate_location(argument["location"], f"{argument_context}.location")
        if location["physical"] in physical:
            raise RuntimeError(f"{context}: duplicate physical argument location")
        physical.add(location["physical"])
        locations.append(location)
        if location["start"] is not None:
            stack_ranges.append((location["start"], location["end"]))
        role = argument["role"]
        if role == "anonymous-variadic":
            raise RuntimeError(f"{argument_context}: anonymous-variadic is invalid in Phase A")
        if role == "fixed":
            source_position = require_integer(argument["source_position"],
                                              f"{argument_context}.source_position", 0)
            if argument["tail_ordinal"] is not None:
                raise RuntimeError(f"{argument_context}: fixed tail_ordinal must be null")
            if source_position in fixed_positions:
                raise RuntimeError(f"{context}: duplicate fixed source position")
            fixed_positions.add(source_position)
        elif role == "unknown":
            if argument["source_position"] is not None or argument["tail_ordinal"] is not None:
                raise RuntimeError(f"{argument_context}: unknown ordinals must be null")
        else:
            raise RuntimeError(f"{argument_context}: unsupported argument role")
        roles_seen.add(role)
        validate_value_identity(argument["value_identity"], f"{argument_context}.value_identity")
        selector_name = argument["selector_name"]
        selector_address = argument["selector_selref_address"]
        if (selector_name is None) != (selector_address is None):
            raise RuntimeError(f"{argument_context}: selector fields must be jointly null")
        if selector_name is not None:
            selector_name = valid_selector_name(selector_name, f"{argument_context}.selector_name")
            canonical_address(selector_address, f"{argument_context}.selector_selref_address")
            selector_rows.append((argument, location, selector_name))
        included = argument["safe_render_included"]
        if type(included) is not bool:
            raise RuntimeError(f"{argument_context}: safe_render_included must be boolean")
        allowed = TRUE_RENDER_REASONS if included else FALSE_RENDER_REASONS
        if argument["safe_render_reason"] not in allowed:
            raise RuntimeError(f"{argument_context}: invalid safe-render bool/reason")
        arguments.append(argument)

    if [location["order"] for location in locations] != sorted(
        location["order"] for location in locations
    ):
        raise RuntimeError(f"{context}: arguments are not in canonical physical order")
    for previous, current in zip(sorted(stack_ranges), sorted(stack_ranges)[1:]):
        if current[0] < previous[1]:
            raise RuntimeError(f"{context}: call-stack arguments overlap")
    if len(roles_seen) > 1:
        raise RuntimeError(f"{context}: known and unknown roles are mixed")
    if signature is None and roles_seen - {"unknown"}:
        raise RuntimeError(f"{context}: unknown signature has fixed arguments")
    if signature is not None and roles_seen - {"fixed"}:
        raise RuntimeError(f"{context}: known signature has unknown arguments")
    if frozen_signature is not None:
        for argument, location in zip(arguments, locations):
            source_position = argument["source_position"]
            if source_position >= len(frozen_signature["locations"]):
                raise RuntimeError(f"{context}: fixed source position is outside signature")
            expected_location = frozen_signature["locations"][source_position]
            if location["kind"] == "gpr":
                actual_location = (
                    "gpr", location["index"], argument["location"]["carrier_width"]
                )
            elif location["kind"] == "simd":
                actual_location = (
                    "simd", location["index"], argument["location"]["scalar_width"]
                )
            else:
                actual_location = None
            if expected_location is None or actual_location != expected_location:
                raise RuntimeError(
                    f"{context}: fixed source position/signature location disagrees"
                )

    selector_name = None
    if (tail_count is None) != (len(selector_rows) == 0):
        raise RuntimeError(f"{context}: selector and tail evidence are not bidirectional")
    if selector_rows:
        if len(selector_rows) != 1:
            raise RuntimeError(f"{context}: exactly one selector row is required")
        selector_argument, selector_location, selector_name = selector_rows[0]
        if (
            selector_location["kind"] != "gpr" or selector_location["index"] != 1
            or selector_argument["location"]["carrier_width"] != 64
            or selector_argument["role"] != "fixed"
            or selector_argument["source_position"] != 1
            or selector_argument["tail_ordinal"] is not None
        ):
            raise RuntimeError(f"{context}: selector is not exact fixed GPR1/source one")
        canonical_target = target[1:] if target.startswith("_") else target
        if canonical_target != "objc_msgSend" or signature != target:
            raise RuntimeError(f"{context}: selector target/signature disagreement")
        if tail_count != selector_name.count(":"):
            raise RuntimeError(f"{context}: selector colon count disagrees")
        if observation != {"gpr": (), "simd": (), "stack": ()}:
            raise RuntimeError(f"{context}: selector evidence requires empty observation")
        fixed_locations = {
            argument["source_position"]: (argument, location)
            for argument, location in zip(arguments, locations)
            if argument["role"] == "fixed"
        }
        if set(fixed_locations) - {0, 1}:
            raise RuntimeError(f"{context}: selector permits only fixed positions zero/one")
        receiver = fixed_locations.get(0)
        if receiver is not None:
            receiver_argument, receiver_location = receiver
            if (
                receiver_location["kind"] != "gpr" or receiver_location["index"] != 0
                or receiver_argument["location"]["carrier_width"] != 64
            ):
                raise RuntimeError(f"{context}: selector receiver must be exact GPR0")
    if signature is not None and observation != {"gpr": (), "simd": (), "stack": ()}:
        raise RuntimeError(f"{context}: known fixed call cannot claim observation coverage")

    control_gprs = {
        int(control["register"][1:]) for control in controls
        if control["register"].startswith("x") and int(control["register"][1:]) < 8
    }
    argument_gprs = {location["index"] for location in locations if location["kind"] == "gpr"}
    if control_gprs & argument_gprs or control_gprs & set(observation["gpr"]):
        raise RuntimeError(f"{context}: control aliases argument/observation")
    for argument, location in zip(arguments, locations):
        if argument["role"] != "unknown":
            continue
        if location["kind"] == "gpr":
            observed = location["index"] in observation["gpr"]
        elif location["kind"] == "simd":
            observed = location["index"] in observation["simd"]
        else:
            observed = any(
                start <= location["start"] and location["end"] <= end
                for start, end in observation["stack"]
            )
        if not observed:
            raise RuntimeError(f"{context}: unknown argument is outside observation coverage")

    fixed_by_position = {
        argument["source_position"]: argument for argument in arguments
        if argument["role"] == "fixed"
    }
    dense_fixed = 0
    while dense_fixed in fixed_by_position:
        dense_fixed += 1
    complete_zero = (
        tail_count == 0 and selector_name is not None
        and set(fixed_by_position) == {0, 1}
        and SELECTOR_IDENTIFIER_RE.fullmatch(selector_name) is not None
    )
    if signature is not None:
        for argument in arguments:
            position = argument["source_position"]
            expected = (
                (True, "objc-complete-message") if complete_zero
                else (True, "fixed-prefix") if position < dense_fixed
                else (False, "fixed-gap")
            )
            if (argument["safe_render_included"], argument["safe_render_reason"]) != expected:
                raise RuntimeError(f"{context}: inconsistent fixed safe-render classification")
    else:
        all_gpr = all(location["kind"] == "gpr" for location in locations)
        can_prefix = all_gpr and not observation["simd"] and not observation["stack"] \
            and 0 in observation["gpr"]
        argument_indices = {location["index"] for location in locations if location["kind"] == "gpr"}
        dense_unknown = 0
        if can_prefix:
            while dense_unknown in observation["gpr"] and dense_unknown in argument_indices:
                dense_unknown += 1
        for argument, location in zip(arguments, locations):
            if can_prefix and location["kind"] == "gpr" and location["index"] < dense_unknown:
                expected = (True, "unknown-gpr-prefix")
            elif location["kind"] == "call-stack" or observation["stack"]:
                expected = (False, "unproven-stack")
            elif location["kind"] == "simd" or observation["simd"]:
                expected = (False, "unproven-bank-order")
            else:
                expected = (False, "unknown-gap")
            if (argument["safe_render_included"], argument["safe_render_reason"]) != expected:
                raise RuntimeError(f"{context}: inconsistent unknown safe-render classification")

    safe_arguments = [argument for argument in arguments if argument["safe_render_included"]]
    if complete_zero:
        if parse_zero_selector_message(line, selector_name) is None or len(safe_arguments) != 2:
            raise RuntimeError(f"{context}: invalid zero-selector complete message")
    else:
        plain = parse_plain_call(line, target)
        if plain is None:
            raise RuntimeError(f"{context}: rendered line is not the exact plain target call")
        if len(plain["arguments"]) != len(safe_arguments):
            raise RuntimeError(f"{context}: rendered argument count disagrees with safe rows")
        if selector_name is not None:
            safe_positions = [argument["source_position"] for argument in safe_arguments]
            if 1 in safe_positions and plain["arguments"][safe_positions.index(1)] != f'"{selector_name}"':
                raise RuntimeError(f"{context}: rendered selector text disagrees")
    return instruction_address


def validate_decompile_response(response, expected_address, expected_name, context):
    if not isinstance(response, dict):
        raise RuntimeError(f"{context}: decompile response is not an object")
    if response.get("address") != expected_address:
        raise RuntimeError(f"{context}: decompile address disagreement")
    if response.get("function") != expected_name:
        raise RuntimeError(f"{context}: decompile function name disagreement")
    pseudocode = response.get("pseudocode")
    lines = response.get("lines")
    if not isinstance(pseudocode, str) or not isinstance(lines, list):
        raise RuntimeError(f"{context}: decompile response lacks line metadata")
    rendered = pseudocode.split("\n")
    if len(lines) != len(rendered):
        raise RuntimeError(f"{context}: decompile line count does not match pseudocode")
    for index, (line, text) in enumerate(zip(lines, rendered), start=1):
        if not isinstance(line, dict):
            raise RuntimeError(f"{context}: decompile line {index} is not an object")
        expected_keys = {"n", "kind", "text"}
        if "address" in line:
            expected_keys.add("address")
        exact_object(line, expected_keys, f"{context}.lines[{index - 1}]")
        if type(line["n"]) is not int or line["n"] != index:
            raise RuntimeError(f"{context}: decompile line ordinals are not contiguous")
        require_string(line["kind"], f"{context}.lines[{index - 1}].kind")
        if line["text"] != text:
            raise RuntimeError(f"{context}: decompile lines do not reconstruct pseudocode")
        if "address" in line:
            canonical_address(line["address"], f"{context}.lines[{index - 1}].address")
    return rendered, lines


def validate_function_identity(value, function, context):
    identity = exact_object(
        value, {"start_address", "display_name"}, context
    )
    start_address = canonical_address(
        identity["start_address"], f"{context}.start_address"
    )
    display_name = require_string(
        identity["display_name"], f"{context}.display_name", allow_empty=True
    )
    if start_address != function["address"]:
        raise RuntimeError(f"{context}: function start address disagrees")
    if display_name != function["name"]:
        raise RuntimeError(f"{context}: function display name disagrees")
    return identity


def build_function_identity(function, context):
    identity = {
        "start_address": function["address"],
        "display_name": function["name"],
    }
    return validate_function_identity(identity, function, context)


def _instruction_line_records(
    decompile_response, expected_address, expected_name, context
):
    _, metadata_lines = validate_decompile_response(
        decompile_response, expected_address, expected_name, context
    )
    records = []
    text_occurrences = Counter()
    for ordinal, line in enumerate(metadata_lines, start=1):
        text = line["text"]
        occurrence = text_occurrences[text]
        text_occurrences[text] += 1
        if line["kind"] != "instruction":
            continue
        instruction_address = None
        if "address" in line:
            instruction_address = canonical_address(
                line["address"], f"{context}.lines[{ordinal - 1}].address"
            )
        records.append({
            "line_ordinal": ordinal,
            "line_text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "text_occurrence": occurrence,
            "instruction_address": instruction_address,
        })
    return records


def validate_instruction_line_audit(
    audit,
    *,
    decompile_response,
    expected_address,
    expected_name,
    context,
):
    value = exact_object(
        audit,
        {
            "schema", "validation_scope", "combined_oracle_comparison",
            "function_address", "records",
        },
        context,
    )
    if value["schema"] != INSTRUCTION_LINE_AUDIT_SCHEMA:
        raise RuntimeError(f"{context}: unsupported instruction-line audit schema")
    if value["validation_scope"] != "structural-candidate":
        raise RuntimeError(f"{context}: instruction-line audit is not candidate-structural")
    if value["combined_oracle_comparison"] is not False:
        raise RuntimeError(f"{context}: instruction-line audit claims an external comparison")
    if canonical_address(
        value["function_address"], f"{context}.function_address"
    ) != expected_address:
        raise RuntimeError(f"{context}: instruction-line function address disagrees")
    if not isinstance(value["records"], list):
        raise RuntimeError(f"{context}: instruction-line records must be an array")
    validated_records = []
    prior_ordinal = 0
    for index, raw_record in enumerate(value["records"]):
        record_context = f"{context}.records[{index}]"
        record = exact_object(
            raw_record,
            {
                "line_ordinal", "line_text_sha256", "text_occurrence",
                "instruction_address",
            },
            record_context,
        )
        ordinal = require_integer(
            record["line_ordinal"], f"{record_context}.line_ordinal", 1
        )
        if ordinal <= prior_ordinal:
            raise RuntimeError(
                f"{context}: instruction-line records are duplicate or unordered"
            )
        prior_ordinal = ordinal
        require_digest(
            record["line_text_sha256"], f"{record_context}.line_text_sha256"
        )
        require_integer(
            record["text_occurrence"], f"{record_context}.text_occurrence", 0
        )
        if record["instruction_address"] is not None:
            canonical_address(
                record["instruction_address"],
                f"{record_context}.instruction_address",
            )
        validated_records.append(record)
    expected_records = _instruction_line_records(
        decompile_response, expected_address, expected_name, context
    )
    if validated_records != expected_records:
        raise RuntimeError(
            f"{context}: instruction-line records do not exactly bind decompile metadata"
        )
    return value


def build_instruction_line_audit(
    decompile_response, *, expected_address, expected_name, context
):
    audit = {
        "schema": INSTRUCTION_LINE_AUDIT_SCHEMA,
        "validation_scope": "structural-candidate",
        "combined_oracle_comparison": False,
        "function_address": expected_address,
        "records": _instruction_line_records(
            decompile_response, expected_address, expected_name, context
        ),
    }
    return validate_instruction_line_audit(
        audit,
        decompile_response=decompile_response,
        expected_address=expected_address,
        expected_name=expected_name,
        context=context,
    )


def validate_call_argument_audit(
    audit,
    *,
    expected_address,
    expected_name,
    decompile_response,
    expected_binary_sha256,
    expected_executable_sha256,
    expected_toolchain_identity,
    returning_call_addresses,
    context,
):
    canonical_address(expected_address, f"{context}.expected_address")
    require_digest(expected_binary_sha256, f"{context}.expected_binary_sha256")
    require_digest(expected_executable_sha256, f"{context}.expected_executable_sha256")
    rendered_lines, metadata_lines = validate_decompile_response(
        decompile_response, expected_address, expected_name, context
    )
    value = exact_object(audit, AUDIT_KEYS, context)
    if value["schema"] != "call-argument-audit-v1":
        raise RuntimeError(f"{context}: unsupported call-audit schema")
    if value["validation_scope"] != "structural-candidate":
        raise RuntimeError(f"{context}: invalid validation scope")
    if value["combined_oracle_comparison"] is not False:
        raise RuntimeError(f"{context}: app audit claims baseline/oracle comparison")
    if require_integer(value["image_slot"], f"{context}.image_slot", 0) != 0:
        raise RuntimeError(f"{context}: standalone image_slot must be zero")
    if require_digest(value["binary_sha256"], f"{context}.binary_sha256") != expected_binary_sha256:
        raise RuntimeError(f"{context}: whole-file binary digest disagreement")
    if require_digest(
        value["producer_executable_sha256"],
        f"{context}.producer_executable_sha256",
    ) != expected_executable_sha256:
        raise RuntimeError(f"{context}: whole-file producer executable digest disagreement")
    toolchain = validate_toolchain_identity(value["toolchain_identity"], f"{context}.toolchain_identity")
    if toolchain != expected_toolchain_identity:
        raise RuntimeError(f"{context}: active toolchain identity disagreement")
    function = exact_object(
        value["function"], {"start_address", "display_name"}, f"{context}.function"
    )
    if function["start_address"] != expected_address:
        raise RuntimeError(f"{context}: audit function address disagreement")
    if function["display_name"] != expected_name:
        raise RuntimeError(f"{context}: audit function name disagreement")
    require_string(function["display_name"], f"{context}.function.display_name", allow_empty=True)
    calls = value["calls"]
    if not isinstance(calls, list):
        raise RuntimeError(f"{context}: calls must be an array")
    validated_addresses = []
    rendered_identities = set()
    for index, call in enumerate(calls):
        if isinstance(call, dict):
            identity = (
                call.get("rendered_line_ordinal"),
                call.get("rendered_occurrence_ordinal"),
            )
            if identity in rendered_identities:
                raise RuntimeError(f"{context}: duplicate rendered call-line identity")
            rendered_identities.add(identity)
        validated_addresses.append(
            validate_call_argument_call(
                call,
                rendered_lines,
                metadata_lines,
                f"{context}.calls[{index}]",
            )
        )
    numeric = [int(address, 16) for address in validated_addresses]
    if numeric != sorted(set(numeric)):
        raise RuntimeError(f"{context}: calls are duplicate or not canonically ordered")
    expected_calls = [
        canonical_address(address, f"{context}.returning_call_addresses")
        for address in returning_call_addresses
    ]
    if validated_addresses != expected_calls:
        raise RuntimeError(f"{context}: returning-call coverage mismatch")
    return value


def build_pair_line_instruction_audit(decompile_response, context):
    """Bind every rendered pair line to its exact lifted instruction address.

    The audit intentionally carries no candidate-derived width, register class, or
    second-slot stride. The differential comparator must obtain those facts by
    independently decoding ``instruction_address`` from the manifested corpus binary.
    """
    if not isinstance(decompile_response, dict):
        raise RuntimeError(f"{context}: decompile response is not an object")
    pseudocode = decompile_response.get("pseudocode")
    lines = decompile_response.get("lines")
    function_address = decompile_response.get("address")
    if not isinstance(pseudocode, str) or not isinstance(lines, list):
        raise RuntimeError(f"{context}: decompile response lacks pseudocode line metadata")
    if not isinstance(function_address, str):
        raise RuntimeError(f"{context}: decompile response lacks a function address")
    try:
        numeric_function_address = int(function_address, 16)
    except ValueError as error:
        raise RuntimeError(f"{context}: function address is invalid") from error
    if (
        function_address != hex(numeric_function_address)
        or numeric_function_address < 0
        or numeric_function_address > 0xFFFF_FFFF_FFFF_FFFF
    ):
        raise RuntimeError(f"{context}: function address is not canonical")
    if any(not isinstance(line, dict) for line in lines):
        raise RuntimeError(f"{context}: decompile line metadata contains a non-object")

    rendered_lines = pseudocode.split("\n")
    metadata_text = [line.get("text") for line in lines]
    if metadata_text != rendered_lines:
        raise RuntimeError(f"{context}: decompile line metadata does not reconstruct pseudocode")

    records = []
    text_occurrences = Counter()
    instruction_addresses = set()
    for ordinal, line in enumerate(lines, start=1):
        if type(line.get("n")) is not int or line.get("n") != ordinal:
            raise RuntimeError(f"{context}: decompile line ordinals are not contiguous")
        text = line.get("text")
        kind = line.get("kind")
        if not isinstance(text, str) or not isinstance(kind, str) or not kind:
            raise RuntimeError(f"{context}: decompile line metadata is incomplete")

        comment = text.partition("//")[2]
        annotations = {annotation.strip() for annotation in comment.split(";")}
        is_save = "saves register pair" in annotations
        is_restore = "restores register pair" in annotations
        if not is_save and not is_restore:
            continue
        if kind != "instruction":
            raise RuntimeError(f"{context}: pair line {ordinal} is not an instruction")
        address = line.get("address")
        if not isinstance(address, str):
            raise RuntimeError(
                f"{context}: pair line {ordinal} lacks an instruction address"
            )
        try:
            numeric_address = int(address, 16)
        except ValueError as error:
            raise RuntimeError(
                f"{context}: pair line {ordinal} has an invalid instruction address"
            ) from error
        if numeric_address < 0 or numeric_address > 0xFFFF_FFFF_FFFF_FFFF:
            raise RuntimeError(
                f"{context}: pair line {ordinal} instruction address is out of range"
            )
        if address != hex(numeric_address):
            raise RuntimeError(
                f"{context}: pair line {ordinal} instruction address is not canonical"
            )
        if address in instruction_addresses:
            raise RuntimeError(
                f"{context}: pair line {ordinal} instruction address is duplicated"
            )
        instruction_addresses.add(address)

        occurrence = text_occurrences[text]
        text_occurrences[text] += 1
        records.append({
            "line_ordinal": ordinal,
            "line_text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "text_occurrence": occurrence,
            "instruction_address": address,
        })

    return {
        "schema": PAIR_LINE_AUDIT_SCHEMA,
        "validation_scope": "structural-candidate",
        "combined_oracle_comparison": False,
        "function_address": function_address,
        "records": records,
    }


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _stat_identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IFMT(metadata.st_mode),
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _digest_descriptor(descriptor, size, context):
    digest = hashlib.sha256()
    offset = 0
    while offset < size:
        chunk = os.pread(descriptor, min(1024 * 1024, size - offset), offset)
        if not chunk:
            raise RuntimeError(f"{context}: descriptor ended before its declared size")
        digest.update(chunk)
        offset += len(chunk)
    if os.pread(descriptor, 1, size):
        raise RuntimeError(f"{context}: descriptor grew while being fingerprinted")
    return digest.hexdigest()


def _open_input_snapshot(path):
    claimed_path = os.fspath(path)
    realpath_before = os.path.realpath(claimed_path)
    path_before = os.lstat(realpath_before)
    if not stat.S_ISREG(path_before.st_mode):
        raise RuntimeError(f"input is not a regular file: {claimed_path}")

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(realpath_before, flags)
    try:
        opened_before = os.fstat(descriptor)
        if _stat_identity(path_before) != _stat_identity(opened_before):
            raise RuntimeError(f"input changed before it was opened: {claimed_path}")
        digest = _digest_descriptor(descriptor, opened_before.st_size, claimed_path)
        opened_after = os.fstat(descriptor)
        path_after = os.lstat(realpath_before)
        realpath_after = os.path.realpath(claimed_path)
        if (
            _stat_identity(opened_before) != _stat_identity(opened_after)
            or _stat_identity(opened_after) != _stat_identity(path_after)
            or realpath_before != realpath_after
        ):
            raise RuntimeError(f"input changed while being fingerprinted: {claimed_path}")
        snapshot = {
            "realpath": realpath_after,
            "sha256": digest,
            "size": opened_after.st_size,
            "device": opened_after.st_dev,
            "inode": opened_after.st_ino,
            "mtime_ns": opened_after.st_mtime_ns,
        }
        return descriptor, snapshot
    except BaseException:
        os.close(descriptor)
        raise


def _copy_descriptor_exact(source_descriptor, source_snapshot, destination, executable):
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    destination_descriptor = os.open(destination, flags, 0o600)
    try:
        offset = 0
        while offset < source_snapshot["size"]:
            chunk = os.pread(
                source_descriptor,
                min(1024 * 1024, source_snapshot["size"] - offset),
                offset,
            )
            if not chunk:
                raise RuntimeError(
                    f"input ended while constructing private replica: {source_snapshot['realpath']}"
                )
            view = memoryview(chunk)
            while view:
                written = os.write(destination_descriptor, view)
                if written <= 0:
                    raise RuntimeError(f"failed to write private input replica: {destination}")
                view = view[written:]
            offset += len(chunk)
        os.fsync(destination_descriptor)
    finally:
        os.close(destination_descriptor)

    os.chmod(destination, 0o500 if executable else 0o400)
    os.chflags(destination, stat.UF_IMMUTABLE)
    descriptor, snapshot = _open_input_snapshot(destination)
    if (
        snapshot["size"] != source_snapshot["size"]
        or snapshot["sha256"] != source_snapshot["sha256"]
    ):
        os.close(descriptor)
        raise RuntimeError(f"private input replica does not match its source: {destination}")
    if not os.lstat(destination).st_flags & stat.UF_IMMUTABLE:
        os.close(descriptor)
        raise RuntimeError(f"private input replica is not immutable: {destination}")
    return descriptor, snapshot


@contextmanager
def pinned_sweep_inputs(macscope, corpora_by_base):
    """Execute only immutable replicas made from descriptor-verified input bytes."""
    global ACTIVE_MACSCOPE, ACTIVE_CORPUS_PATHS

    private_root = Path(tempfile.mkdtemp(prefix="macscope-sweep-inputs-"))
    original_descriptors = []
    private_descriptors = []
    private_paths = []
    original_active_macscope = ACTIVE_MACSCOPE
    original_active_corpora = ACTIVE_CORPUS_PATHS
    initial_producer = None
    initial_corpora = {}
    setup_complete = False
    try:
        producer_descriptor, initial_producer = _open_input_snapshot(macscope)
        original_descriptors.append(producer_descriptor)
        for base, path in corpora_by_base.items():
            descriptor, snapshot = _open_input_snapshot(path)
            original_descriptors.append(descriptor)
            initial_corpora[base] = snapshot

        private_macscope = private_root / "000-macscope"
        private_paths.append(private_macscope)
        descriptor, _ = _copy_descriptor_exact(
            producer_descriptor, initial_producer, private_macscope, executable=True
        )
        private_descriptors.append(descriptor)

        private_corpora = {}
        for index, (base, path) in enumerate(corpora_by_base.items(), start=1):
            destination = private_root / f"{index:03d}-corpus"
            private_paths.append(destination)
            source_descriptor = original_descriptors[index]
            descriptor, _ = _copy_descriptor_exact(
                source_descriptor,
                initial_corpora[base],
                destination,
                executable=False,
            )
            private_descriptors.append(descriptor)
            private_corpora[os.fspath(path)] = str(destination)

        # ★ Insight: a digest describes bytes, not the executable the kernel will
        # launch. Removing directory write access and applying UF_IMMUTABLE makes
        # the verified replica's pathname a stable execution identity for the run.
        os.chmod(private_root, 0o500)
        ACTIVE_MACSCOPE = str(private_macscope)
        ACTIVE_CORPUS_PATHS = private_corpora
        setup_complete = True
        yield initial_producer, initial_corpora
    finally:
        active_exception = sys.exc_info()[0] is not None
        verification_error = None
        if setup_complete:
            try:
                if file_snapshot(macscope) != initial_producer:
                    raise RuntimeError("MacScope executable changed during pinned sweep")
                for base, path in corpora_by_base.items():
                    if file_snapshot(path) != initial_corpora[base]:
                        raise RuntimeError(f"corpus {base} changed during pinned sweep")
                for descriptor, path in zip(private_descriptors, private_paths):
                    opened = os.fstat(descriptor)
                    current = os.lstat(path)
                    if _stat_identity(opened) != _stat_identity(current):
                        raise RuntimeError(f"private input replica changed: {path}")
                    if not current.st_flags & stat.UF_IMMUTABLE:
                        raise RuntimeError(f"private input replica lost immutability: {path}")
            except BaseException as error:
                verification_error = error

        ACTIVE_MACSCOPE = original_active_macscope
        ACTIVE_CORPUS_PATHS = original_active_corpora
        for descriptor in reversed(private_descriptors + original_descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass
        try:
            os.chmod(private_root, 0o700)
        except OSError:
            pass
        for path in reversed(private_paths):
            try:
                os.chflags(path, 0)
            except OSError:
                pass
            try:
                os.chmod(path, 0o600)
            except OSError:
                pass
            try:
                path.unlink()
            except OSError:
                pass
        try:
            private_root.rmdir()
        except OSError:
            pass
        if verification_error is not None and not active_exception:
            raise verification_error


def producer_code_artifacts():
    script_path = Path(__file__).resolve()
    expected_path = REPOSITORY_ROOT / PRODUCER_CODE_PATH
    if script_path != expected_path:
        raise RuntimeError(
            f"producer code is not at the frozen repository path: {script_path}"
        )
    entry = {
        "path": PRODUCER_CODE_PATH,
        "size": script_path.stat().st_size,
        "sha256": sha256_file(script_path),
    }
    entries = [entry]
    canonical = json.dumps(
        entries,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode("utf-8")
    return {
        "entries": entries,
        "canonical_set_sha256": hashlib.sha256(canonical).hexdigest(),
    }


def verify_producer_code_checkpoint(expected, checkpoint, sampler=None):
    """Fail when repository-owned producer code drifts after its first snapshot."""
    # ★ Insight: one injectable guard keeps the production checkpoints and the
    # deterministic drift mutations on exactly the same equality decision.
    actual = (sampler or producer_code_artifacts)()
    if actual != expected:
        raise RuntimeError(
            f"producer code changed {checkpoint}; discard outputs"
        )
    return actual


def assigned_signature_locations(parameter_types):
    next_gpr = 0
    next_simd = 0
    locations = []
    for raw_type in parameter_types:
        parameter_type = raw_type.strip()
        if parameter_type in {"float", "double", "long double"}:
            width = 32 if parameter_type == "float" else 64
            locations.append(("simd", next_simd, width) if next_simd < 8 else None)
            next_simd += 1
            continue
        width = 32 if parameter_type in INTEGER_32_TYPES else 64
        locations.append(("gpr", next_gpr, width) if next_gpr < 8 else None)
        next_gpr += 1
    return tuple(locations)


def load_frozen_signatures():
    for relative_path, expected_digest in FROZEN_CATALOG_SOURCE_SHA256.items():
        path = REPOSITORY_ROOT / relative_path
        if sha256_file(path) != expected_digest:
            raise RuntimeError(
                f"frozen signature source drifted and requires schema review: {relative_path}"
            )
    signature_types = dict(FROZEN_SEED_SIGNATURES)
    corpus_path = REPOSITORY_ROOT / "MacScope/Services/Decompiler/CallSignatureCorpus.swift"
    corpus_entries = 0
    for line_number, line in enumerate(
        corpus_path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if not line.lstrip().startswith('s("'):
            continue
        match = CORPUS_ENTRY_RE.fullmatch(line)
        if match is None:
            raise RuntimeError(f"frozen signature corpus line {line_number} is not parseable")
        name = match.group("name")
        rest = match.group("rest")
        parameters = list(CORPUS_PARAMETER_RE.finditer(rest))
        if rest.count('("') != len(parameters):
            raise RuntimeError(f"frozen signature corpus line {line_number} is ambiguous")
        parameter_types = tuple(parameter.group("type") for parameter in parameters)
        is_variadic = "variadic: true" in rest
        if "variadic:" in rest and not is_variadic:
            raise RuntimeError(f"frozen signature corpus line {line_number} has invalid variadic syntax")
        if name in signature_types:
            raise RuntimeError(f"frozen signature corpus duplicates {name!r}")
        signature_types[name] = (parameter_types, is_variadic)
        corpus_entries += 1
    if corpus_entries != 467 or len(signature_types) != 500:
        raise RuntimeError("frozen signature catalog count drifted")
    signatures = {
        name: {
            "canonical_name": name,
            "locations": assigned_signature_locations(types),
            "is_variadic": is_variadic,
        }
        for name, (types, is_variadic) in signature_types.items()
    }
    canonical = {
        name: {
            "locations": [list(location) if location is not None else None
                          for location in signature["locations"]],
            "variadic": signature["is_variadic"],
        }
        for name, signature in sorted(signatures.items())
    }
    layout_digest = hashlib.sha256(json.dumps(
        canonical, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
    ).encode("utf-8")).hexdigest()
    if layout_digest != EXPECTED_FROZEN_SIGNATURE_LAYOUT_SHA256:
        raise RuntimeError("frozen signature layout digest drifted")
    return signatures


FROZEN_SIGNATURES = load_frozen_signatures()


def frozen_signature_for_target(target):
    canonical = target[1:] if target.startswith("_") else target
    return FROZEN_SIGNATURES.get(canonical)


def file_snapshot(path):
    descriptor, snapshot = _open_input_snapshot(path)
    os.close(descriptor)
    return snapshot


def validate_output_paths(macscope, outdir, corpora_by_base):
    """Reject input/output aliasing and every pre-existing planned artifact."""
    output_root = Path(outdir).resolve()
    inputs = {
        "MacScope executable": Path(macscope).resolve(),
        **{
            f"corpus {base}": Path(path).resolve()
            for base, path in corpora_by_base.items()
        },
    }
    planned = {
        "producer manifest": output_root / "_producer.json",
        "histogram": output_root / "_histogram.json",
        **{
            f"corpus artifact {base}": output_root / f"{base}.json"
            for base in corpora_by_base
        },
    }
    reverse = {}
    for label, destination in planned.items():
        if destination in reverse:
            raise RuntimeError(
                f"planned output {label} aliases {reverse[destination]}: {destination}"
            )
        reverse[destination] = label
        for input_label, input_path in inputs.items():
            same_existing_file = False
            if destination.exists() and input_path.exists():
                try:
                    same_existing_file = os.path.samefile(destination, input_path)
                except OSError as error:
                    raise RuntimeError(
                        f"cannot compare planned output {label} with {input_label}: {error}"
                    ) from error
            if destination == input_path or same_existing_file:
                raise RuntimeError(
                    f"planned output {label} aliases {input_label}: {destination}"
                )
        for previous_path, previous_label in reverse.items():
            if previous_path == destination or not (
                previous_path.exists() and destination.exists()
            ):
                continue
            try:
                if os.path.samefile(previous_path, destination):
                    raise RuntimeError(
                        f"planned output {label} aliases {previous_label}: {destination}"
                    )
            except OSError as error:
                raise RuntimeError(
                    f"cannot compare planned outputs {label} and {previous_label}: {error}"
                ) from error
    for label, destination in planned.items():
        # ★ Insight: a manifested corpus is evidence, not a cache. Even an expected
        # filename from an earlier run must make this fresh production attempt stop.
        if os.path.lexists(destination):
            raise RuntimeError(f"planned output {label} already exists: {destination}")
    return planned


def _write_json_temp(path, value, indent=None):
    destination = Path(path)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}-", suffix=".tmp", dir=destination.parent,
        text=True,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(value, output, indent=indent, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
    except BaseException:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise
    return temporary


def _publish_json_temp(temporary, destination):
    # A same-directory hard link atomically publishes the already-fsynced inode while
    # retaining O_EXCL-like behavior: an intervening artifact is never overwritten.
    try:
        os.link(temporary, destination)
    except FileExistsError as error:
        raise RuntimeError(f"planned output already exists: {destination}") from error
    temporary.unlink()
    try:
        directory_fd = os.open(Path(destination).parent, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def atomic_write_json(path, value, indent=None):
    temporary = _write_json_temp(path, value, indent=indent)
    try:
        _publish_json_temp(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def build_producer_manifest(
    *,
    producer_code,
    executable_snapshot,
    corpus_basenames,
    parameter_audit_available,
    call_audit_capability,
    input_manifests,
):
    if set(producer_code) != {"entries", "canonical_set_sha256"}:
        raise RuntimeError("producer code artifact set is not closed")
    require_digest(
        producer_code["canonical_set_sha256"],
        "producer_code_artifacts.canonical_set_sha256",
    )
    if not isinstance(producer_code["entries"], list) or not producer_code["entries"]:
        raise RuntimeError("producer code artifact entries must be nonempty")
    for index, entry in enumerate(producer_code["entries"]):
        exact_object(entry, {"path", "size", "sha256"}, f"producer code entry {index}")
        require_string(entry["path"], f"producer code entry {index}.path")
        require_integer(entry["size"], f"producer code entry {index}.size", 1)
        require_digest(entry["sha256"], f"producer code entry {index}.sha256")
    code_paths = [entry["path"] for entry in producer_code["entries"]]
    if code_paths != sorted(code_paths, key=lambda path: path.encode("utf-8")):
        raise RuntimeError("producer code artifact entries are not canonically sorted")
    if len({path.casefold() for path in code_paths}) != len(code_paths):
        raise RuntimeError("producer code artifact paths duplicate or case-fold collide")
    canonical_entries = json.dumps(
        producer_code["entries"], sort_keys=True, separators=(",", ":"),
        ensure_ascii=True,
    ).encode("utf-8")
    if hashlib.sha256(canonical_entries).hexdigest() != producer_code[
        "canonical_set_sha256"
    ]:
        raise RuntimeError("producer code artifact canonical-set digest disagrees")
    if set(executable_snapshot) != {"realpath", "size", "sha256"}:
        raise RuntimeError("executable manifest snapshot is not closed")
    executable_path = require_string(
        executable_snapshot["realpath"], "executable snapshot realpath"
    )
    if not os.path.isabs(executable_path):
        raise RuntimeError("executable snapshot realpath is not absolute")
    executable_size = require_integer(
        executable_snapshot["size"], "executable snapshot size", 0
    )
    executable_sha256 = require_digest(
        executable_snapshot["sha256"], "executable snapshot digest"
    )
    if not isinstance(corpus_basenames, list) or not all(
        isinstance(base, str) and base for base in corpus_basenames
    ):
        raise RuntimeError("corpus basenames must be a string array")
    if len(corpus_basenames) != len(set(corpus_basenames)):
        raise RuntimeError("corpus basenames must be unique")
    if set(input_manifests) != set(corpus_basenames):
        raise RuntimeError("corpus manifest set disagrees with the invocation")
    for base in corpus_basenames:
        input_manifest = exact_object(
            input_manifests[base],
            {
                "input_realpath", "input_sha256", "input_size", "record_count",
                "output_sha256",
            },
            f"corpus manifest {base}",
        )
        input_path = require_string(
            input_manifest["input_realpath"], f"corpus manifest {base}.input_realpath"
        )
        if not os.path.isabs(input_path):
            raise RuntimeError(f"corpus manifest {base} input path is not absolute")
        require_digest(
            input_manifest["input_sha256"], f"corpus manifest {base}.input_sha256"
        )
        require_integer(
            input_manifest["input_size"], f"corpus manifest {base}.input_size", 0
        )
        require_integer(
            input_manifest["record_count"], f"corpus manifest {base}.record_count", 0
        )
        require_digest(
            input_manifest["output_sha256"], f"corpus manifest {base}.output_sha256"
        )
    if type(parameter_audit_available) is not bool:
        raise RuntimeError("parameter audit availability must be boolean")
    if call_audit_capability not in {"unavailable", "validated-v1"}:
        raise RuntimeError("call audit capability is not a closed producer-v3 value")
    return {
        "schema": PRODUCER_SCHEMA,
        "record_schema": RECORD_SCHEMA,
        "producer_code_artifacts": producer_code,
        "executable_path": executable_path,
        "executable_size": executable_size,
        "executable_sha256": executable_sha256,
        "invocation": {
            "corpus_basenames": corpus_basenames,
            "regiontree_diagnostics": True,
            "parameter_binding_audit_available": parameter_audit_available,
            "pair_line_instruction_audit_available": True,
            "call_argument_audit_capability": call_audit_capability,
        },
        "runtime": {
            "python_executable": os.path.realpath(sys.executable),
            "python_version": sys.version.split()[0],
        },
        "corpora": input_manifests,
    }


def response_fallback(obj, context):
    structured = obj.get("structured")
    fallback = obj.get("structureFallback")
    if not isinstance(structured, bool):
        raise RuntimeError(f"{context}: decompile response lacks boolean structured state")
    if structured:
        if fallback is not None:
            raise RuntimeError(
                f"{context}: structured response also reports structureFallback={fallback!r}"
            )
        return "structured"
    if not isinstance(fallback, str) or not fallback:
        raise RuntimeError(f"{context}: unstructured response lacks structureFallback")
    return fallback


def run_self_tests():
    global MACSCOPE, OUTDIR

    original_macscope = MACSCOPE
    original_outdir = OUTDIR
    try:
        if PRODUCER_SCHEMA != "macscope-sweep-producer-v3":
            raise AssertionError("producer schema is not v3")
        if RECORD_SCHEMA != "macscope-sweep-record-v6":
            raise AssertionError("record schema is not v6")
        if strict_json_loads('{"value":1}', "self-test") != {"value": 1}:
            raise AssertionError("strict JSON changed a valid object")
        for malformed, expected in (
            ('{"value":1,"value":2}', "duplicates key"),
            ('{"value":NaN}', "non-finite"),
        ):
            try:
                strict_json_loads(malformed, "self-test")
            except RuntimeError as error:
                if expected not in str(error):
                    raise
            else:
                raise AssertionError("strict JSON accepted " + malformed)
        if canonical_address("0x10", "self-test") != "0x10":
            raise AssertionError("canonical address rejected")
        for malformed in ("0x010", "0X10", True, -1):
            try:
                canonical_address(malformed, "self-test")
            except RuntimeError:
                pass
            else:
                raise AssertionError(f"canonical address accepted {malformed!r}")
        code_artifacts = producer_code_artifacts()
        if set(code_artifacts) != {"entries", "canonical_set_sha256"}:
            raise AssertionError("producer-code object is not closed")
        if code_artifacts["entries"] != [{
            "path": "Scripts/decompiler-oracles/sweep.py",
            "size": os.stat(__file__).st_size,
            "sha256": sha256_file(__file__),
        }]:
            raise AssertionError("producer-code entry is not the frozen sweep.py file")
        canonical_entries = json.dumps(
            code_artifacts["entries"], sort_keys=True, separators=(",", ":"),
            ensure_ascii=True,
        ).encode("utf-8")
        if code_artifacts["canonical_set_sha256"] != hashlib.sha256(
            canonical_entries
        ).hexdigest():
            raise AssertionError("producer-code canonical-set digest is wrong")
        drifted_code_artifacts = json.loads(json.dumps(code_artifacts))
        drifted_code_artifacts["entries"][0]["sha256"] = "0" * 64
        for checkpoint in (
            "after corpus artifact fixture",
            "before manifest construction",
            "before manifest publication",
        ):
            try:
                verify_producer_code_checkpoint(
                    code_artifacts,
                    checkpoint,
                    sampler=lambda drift=drifted_code_artifacts: drift,
                )
            except RuntimeError as error:
                if checkpoint not in str(error):
                    raise
            else:
                raise AssertionError(
                    f"producer-code drift at {checkpoint} was accepted"
                )
        if verify_producer_code_checkpoint(
            code_artifacts,
            "self-test stable producer code",
            sampler=lambda: code_artifacts,
        ) != code_artifacts:
            raise AssertionError("stable producer-code checkpoint changed its snapshot")
        base_commands = [
            {
                "name": "decompile", "summary": "decompile", "mutates": False,
                "arguments": ["function", "address"],
            },
            {
                "name": "parameter-binding-audit", "summary": "parameters",
                "mutates": False, "arguments": ["function", "address"],
            },
        ]
        capabilities = validate_command_capabilities(base_commands, "self-test")
        if capabilities != {
            "parameter_binding_audit_available": True,
            "call_argument_audit_available": False,
        }:
            raise AssertionError("baseline capability probe is wrong")
        candidate_commands = base_commands + [{
            "name": "call-argument-audit", "summary": "calls", "mutates": False,
            "arguments": ["function", "address"],
        }]
        if not validate_command_capabilities(
            candidate_commands, "self-test"
        )["call_argument_audit_available"]:
            raise AssertionError("candidate capability was not recognized")
        capability_mutations = [
            candidate_commands + [candidate_commands[-1]],
            base_commands + [{**candidate_commands[-1], "mutates": True}],
            base_commands + [{**candidate_commands[-1], "arguments": ["address"]}],
            base_commands + [{**candidate_commands[-1], "name": "call-argument-audit-v1"}],
        ]
        for mutation in capability_mutations[:3]:
            try:
                validate_command_capabilities(mutation, "self-test")
            except RuntimeError:
                pass
            else:
                raise AssertionError("malformed audit capability was accepted")
        if validate_command_capabilities(
            capability_mutations[3], "self-test"
        )["call_argument_audit_available"]:
            raise AssertionError("schema identifier aliased the command identifier")
        diagnostic_suffix = (
            " // call; signature id _objc_msgSend(id receiver, SEL selector, ...); return"
        )
        diagnostic_plain = (
            '    _objc_msgSend(x0_1, "viewDidLoad");' + diagnostic_suffix
        )
        if parse_plain_call(diagnostic_plain, "_objc_msgSend") is None:
            raise AssertionError("diagnostic-comment semicolons changed the plain call")
        diagnostic_message = "    return [x0_1 viewDidLoad];" + diagnostic_suffix
        if parse_zero_selector_message(diagnostic_message, "viewDidLoad") is None:
            raise AssertionError("the real zero-selector diagnostic line was rejected")
        adjacent_messages = (
            "    return [x0_0 retained] [x0_1 viewDidLoad];" + diagnostic_suffix
        )
        if parse_zero_selector_message(adjacent_messages, "viewDidLoad") is not None:
            raise AssertionError("adjacent outer bracket expressions were accepted")
        nested_receiver = (
            "    return [[x0_0 retainedObject] viewDidLoad];" + diagnostic_suffix
        )
        parsed_nested_receiver = parse_zero_selector_message(
            nested_receiver, "viewDidLoad"
        )
        if (
            parsed_nested_receiver is None
            or parsed_nested_receiver["receiver"] != "[x0_0 retainedObject]"
        ):
            raise AssertionError("a valid nested zero-selector receiver was rejected")
        toolchain = {
            "xcode_version": "27.0",
            "xcode_build": "18A100",
            "sdk_canonical_name": "macosx27.0",
            "sdk_version": "27.0",
            "clang_version": "Apple clang version 21.0.0",
        }
        no_call_text = "void quiet(void) {\n    return;\n}"
        no_call_response = {
            "function": "quiet",
            "address": "0x1000",
            "pseudocode": no_call_text,
            "structured": True,
            "lines": [
                {"n": 1, "kind": "signature", "text": "void quiet(void) {"},
                {"n": 2, "kind": "instruction", "text": "    return;", "address": "0x1000"},
                {"n": 3, "kind": "closingBrace", "text": "}"},
            ],
        }
        quiet_function = {
            "name": "quiet", "address": "0x1000", "end": "0x1004",
            "confidence": 1.0,
        }
        function_identity = build_function_identity(
            quiet_function, "self-test function identity"
        )
        if function_identity != {
            "start_address": "0x1000", "display_name": "quiet"
        }:
            raise AssertionError("function identity changed the validated function")
        validate_function_identity(
            function_identity, quiet_function, "self-test function identity"
        )
        for identity_mutation in (
            {**function_identity, "display_name": "wrong"},
            {**function_identity, "name": "quiet"},
        ):
            try:
                validate_function_identity(
                    identity_mutation, quiet_function,
                    "self-test invalid function identity",
                )
            except RuntimeError:
                pass
            else:
                raise AssertionError("invalid function identity was accepted")

        instruction_line_audit = build_instruction_line_audit(
            no_call_response,
            expected_address="0x1000",
            expected_name="quiet",
            context="self-test instruction-line audit",
        )
        if instruction_line_audit != {
            "schema": INSTRUCTION_LINE_AUDIT_SCHEMA,
            "validation_scope": "structural-candidate",
            "combined_oracle_comparison": False,
            "function_address": "0x1000",
            "records": [{
                "line_ordinal": 2,
                "line_text_sha256": hashlib.sha256(b"    return;").hexdigest(),
                "text_occurrence": 0,
                "instruction_address": "0x1000",
            }],
        }:
            raise AssertionError("instruction-line audit omitted or changed an instruction")
        validate_instruction_line_audit(
            instruction_line_audit,
            decompile_response=no_call_response,
            expected_address="0x1000",
            expected_name="quiet",
            context="self-test instruction-line audit",
        )
        structural_response = {
            "function": "structural",
            "address": "0x2000",
            "pseudocode": "\n".join([
                "void structural(void) {",
                "    if (x0) {",
                "    } else {",
                "    return;",
                "}",
            ]),
            "structured": True,
            "lines": [
                {"n": 1, "kind": "signature", "text": "void structural(void) {"},
                {
                    "n": 2, "kind": "instruction", "text": "    if (x0) {",
                    "address": "0x2000",
                },
                {"n": 3, "kind": "instruction", "text": "    } else {"},
                {
                    "n": 4, "kind": "instruction", "text": "    return;",
                    "address": "0x2004",
                },
                {"n": 5, "kind": "closingBrace", "text": "}"},
            ],
        }
        structural_line_audit = build_instruction_line_audit(
            structural_response,
            expected_address="0x2000",
            expected_name="structural",
            context="self-test addressless structural instruction line",
        )
        if [
            record["instruction_address"]
            for record in structural_line_audit["records"]
        ] != ["0x2000", None, "0x2004"]:
            raise AssertionError(
                "addressless structural instruction line was omitted or fabricated"
            )
        fabricated_null = json.loads(json.dumps(structural_line_audit))
        fabricated_null["records"][0]["instruction_address"] = None
        fabricated_address = json.loads(json.dumps(structural_line_audit))
        fabricated_address["records"][1]["instruction_address"] = "0x2002"
        for topology_mutation in (fabricated_null, fabricated_address):
            try:
                validate_instruction_line_audit(
                    topology_mutation,
                    decompile_response=structural_response,
                    expected_address="0x2000",
                    expected_name="structural",
                    context="self-test invalid instruction address topology",
                )
            except RuntimeError:
                pass
            else:
                raise AssertionError(
                    "instruction-line address/null topology mutation was accepted"
                )
        instruction_line_mutations = []
        for key, value in (
            ("line_ordinal", 1),
            ("line_text_sha256", "0" * 64),
            ("text_occurrence", 1),
            ("instruction_address", "0x1004"),
        ):
            audit_mutation = json.loads(json.dumps(instruction_line_audit))
            audit_mutation["records"][0][key] = value
            instruction_line_mutations.append(audit_mutation)
        missing_instruction = json.loads(json.dumps(instruction_line_audit))
        missing_instruction["records"] = []
        instruction_line_mutations.append(missing_instruction)
        duplicate_instruction = json.loads(json.dumps(instruction_line_audit))
        duplicate_instruction["records"].append(
            json.loads(json.dumps(duplicate_instruction["records"][0]))
        )
        instruction_line_mutations.append(duplicate_instruction)
        adjacent_root_field = json.loads(json.dumps(instruction_line_audit))
        adjacent_root_field["function_identity"] = function_identity
        instruction_line_mutations.append(adjacent_root_field)
        missing_root_field = json.loads(json.dumps(instruction_line_audit))
        del missing_root_field["validation_scope"]
        instruction_line_mutations.append(missing_root_field)
        unknown_record_field = json.loads(json.dumps(instruction_line_audit))
        unknown_record_field["records"][0]["source_address"] = "0x1000"
        instruction_line_mutations.append(unknown_record_field)
        for mutation_index, audit_mutation in enumerate(instruction_line_mutations):
            try:
                validate_instruction_line_audit(
                    audit_mutation,
                    decompile_response=no_call_response,
                    expected_address="0x1000",
                    expected_name="quiet",
                    context="self-test invalid instruction-line audit",
                )
            except RuntimeError:
                pass
            else:
                raise AssertionError(
                    f"invalid instruction-line mutation {mutation_index} was accepted"
                )
        mismatched_metadata = json.loads(json.dumps(no_call_response))
        mismatched_metadata["lines"][1]["text"] = "    changed;"
        try:
            validate_instruction_line_audit(
                instruction_line_audit,
                decompile_response=mismatched_metadata,
                expected_address="0x1000",
                expected_name="quiet",
                context="self-test mismatched reconstructed metadata",
            )
        except RuntimeError as error:
            if "reconstruct" not in str(error):
                raise
        else:
            raise AssertionError("metadata that does not reconstruct pseudocode was accepted")
        no_call_audit = {
            "schema": "call-argument-audit-v1",
            "validation_scope": "structural-candidate",
            "combined_oracle_comparison": False,
            "image_slot": 0,
            "binary_sha256": "1" * 64,
            "producer_executable_sha256": "2" * 64,
            "toolchain_identity": toolchain,
            "function": {"start_address": "0x1000", "display_name": "quiet"},
            "calls": [],
        }
        validate_call_argument_audit(
            no_call_audit,
            expected_address="0x1000",
            expected_name="quiet",
            decompile_response=no_call_response,
            expected_binary_sha256="1" * 64,
            expected_executable_sha256="2" * 64,
            expected_toolchain_identity=toolchain,
            returning_call_addresses=[],
            context="self-test no-call",
        )
        audit_mutations = []
        for key, value in (
            ("image_slot", True),
            ("image_slot", 1),
            ("binary_sha256", "3" * 64),
        ):
            mutation = json.loads(json.dumps(no_call_audit))
            mutation[key] = value
            audit_mutations.append(mutation)
        mutation = json.loads(json.dumps(no_call_audit))
        mutation["baseline_truth"] = True
        audit_mutations.append(mutation)
        mutation = json.loads(json.dumps(no_call_audit))
        mutation["function"]["display_name"] = "wrong"
        audit_mutations.append(mutation)
        for mutation in audit_mutations:
            try:
                validate_call_argument_audit(
                    mutation,
                    expected_address="0x1000",
                    expected_name="quiet",
                    decompile_response=no_call_response,
                    expected_binary_sha256="1" * 64,
                    expected_executable_sha256="2" * 64,
                    expected_toolchain_identity=toolchain,
                    returning_call_addresses=[],
                    context="self-test invalid envelope",
                )
            except RuntimeError:
                pass
            else:
                raise AssertionError("invalid call-audit envelope was accepted")
        try:
            validate_call_argument_audit(
                no_call_audit,
                expected_address="0x1000",
                expected_name="quiet",
                decompile_response=no_call_response,
                expected_binary_sha256="1" * 64,
                expected_executable_sha256="2" * 64,
                expected_toolchain_identity=toolchain,
                returning_call_addresses=["0x1004"],
                context="self-test missing call",
            )
        except RuntimeError as error:
            if "coverage" not in str(error):
                raise
        else:
            raise AssertionError("missing returning call was accepted")

        def value_register(name, version):
            return {"kind": "register", "name": name, "version": version}

        def gpr(index, width=64):
            return {
                "kind": "gpr", "index": index, "carrier_width": width,
                "scalar_width": None, "byte_offset": None, "size": None,
                "alignment": None,
            }

        def argument(index, role, value, source_position, safe, reason, selector=None):
            return {
                "location": gpr(index), "role": role,
                "source_position": source_position, "tail_ordinal": None,
                "value_identity": value,
                "selector_name": selector,
                "selector_selref_address": "0x3000" if selector is not None else None,
                "safe_render_included": safe, "safe_render_reason": reason,
            }

        call_lines = [
            "void calls(void) {",
            "    printf(x0_1);",
            "    (*x8)(x0_2);",
            '    _objc_msgSend(x0_3, "setObject:");',
            "}",
        ]
        call_response = {
            "function": "calls", "address": "0x1000",
            "pseudocode": "\n".join(call_lines), "structured": True,
            "lines": [
                {"n": 1, "kind": "signature", "text": call_lines[0]},
                {"n": 2, "kind": "instruction", "text": call_lines[1], "address": "0x1010"},
                {"n": 3, "kind": "instruction", "text": call_lines[2], "address": "0x1020"},
                {"n": 4, "kind": "instruction", "text": call_lines[3], "address": "0x1030"},
                {"n": 5, "kind": "closingBrace", "text": call_lines[4]},
            ],
        }
        call_instruction_lines = build_instruction_line_audit(
            call_response,
            expected_address="0x1000",
            expected_name="calls",
            context="self-test call instruction lines",
        )
        if [
            record["instruction_address"]
            for record in call_instruction_lines["records"]
        ] != ["0x1010", "0x1020", "0x1030"]:
            raise AssertionError("instruction-line audit did not bind every call line")
        wrong_call_instruction = json.loads(json.dumps(call_instruction_lines))
        wrong_call_instruction["records"][0]["instruction_address"] = "0x1014"
        try:
            validate_instruction_line_audit(
                wrong_call_instruction,
                decompile_response=call_response,
                expected_address="0x1000",
                expected_name="calls",
                context="self-test wrong call instruction address",
            )
        except RuntimeError:
            pass
        else:
            raise AssertionError("wrong call instruction-line address was accepted")

        def call_record(address, target, ordinal, arguments, signature=None, observation=None,
                        controls=None, tail_count=None):
            return {
                "instruction_address": address, "target": target,
                "known_signature_id": signature,
                "tail_count_evidence": None if tail_count is None else {
                    "kind": "objective-c-selector-colon-count",
                    "expected_tail_count": tail_count,
                },
                "rendered_line_ordinal": ordinal,
                "rendered_occurrence_ordinal": 0,
                "rendered_utf8_sha256": hashlib.sha256(
                    call_lines[ordinal - 1].encode("utf-8")
                ).hexdigest(),
                "observation": observation or {
                    "gpr_indices": [], "scalar_simd_indices": [],
                    "call_stack_ranges": [],
                },
                "control_inputs": controls or [], "arguments": arguments,
            }

        calls_audit = json.loads(json.dumps(no_call_audit))
        calls_audit["function"] = {"start_address": "0x1000", "display_name": "calls"}
        calls_audit["calls"] = [
            call_record(
                "0x1010", "printf", 2,
                [argument(0, "fixed", value_register("x0", 1), 0, True, "fixed-prefix")],
                signature="printf",
            ),
            call_record(
                "0x1020", "(*x8)", 3,
                [argument(0, "unknown", value_register("x0", 2), None, True,
                          "unknown-gpr-prefix")],
                observation={
                    "gpr_indices": [0], "scalar_simd_indices": [],
                    "call_stack_ranges": [],
                },
                controls=[{
                    "role": "indirect-target", "register": "x8",
                    "value_identity": value_register("x8", 2),
                }],
            ),
            call_record(
                "0x1030", "_objc_msgSend", 4,
                [
                    argument(0, "fixed", value_register("x0", 3), 0, True, "fixed-prefix"),
                    argument(1, "fixed", value_register("x1", 3), 1, True,
                             "fixed-prefix", selector="setObject:"),
                ],
                signature="_objc_msgSend", tail_count=1,
            ),
        ]
        validate_call_argument_audit(
            calls_audit,
            expected_address="0x1000", expected_name="calls",
            decompile_response=call_response,
            expected_binary_sha256="1" * 64,
            expected_executable_sha256="2" * 64,
            expected_toolchain_identity=toolchain,
            returning_call_addresses=["0x1010", "0x1020", "0x1030"],
            context="self-test calls",
        )
        zero_selector_lines = [
            "void zero_selector(void) {",
            diagnostic_message,
            "}",
        ]
        zero_selector_response = {
            "function": "zero_selector", "address": "0x2000",
            "pseudocode": "\n".join(zero_selector_lines), "structured": True,
            "lines": [
                {"n": 1, "kind": "signature", "text": zero_selector_lines[0]},
                {"n": 2, "kind": "instruction", "text": zero_selector_lines[1],
                 "address": "0x2010"},
                {"n": 3, "kind": "closingBrace", "text": zero_selector_lines[2]},
            ],
        }
        zero_selector_call = call_record(
            "0x2010", "_objc_msgSend", 2,
            [
                argument(0, "fixed", value_register("x0", 1), 0, True,
                         "objc-complete-message"),
                argument(1, "fixed", value_register("x1", 1), 1, True,
                         "objc-complete-message", selector="viewDidLoad"),
            ],
            signature="_objc_msgSend", tail_count=0,
        )
        zero_selector_call["rendered_utf8_sha256"] = hashlib.sha256(
            diagnostic_message.encode("utf-8")
        ).hexdigest()
        zero_selector_audit = json.loads(json.dumps(no_call_audit))
        zero_selector_audit["function"] = {
            "start_address": "0x2000", "display_name": "zero_selector"
        }
        zero_selector_audit["calls"] = [zero_selector_call]
        validate_call_argument_audit(
            zero_selector_audit,
            expected_address="0x2000", expected_name="zero_selector",
            decompile_response=zero_selector_response,
            expected_binary_sha256="1" * 64,
            expected_executable_sha256="2" * 64,
            expected_toolchain_identity=toolchain,
            returning_call_addresses=["0x2010"],
            context="self-test real zero-selector diagnostic",
        )
        adjacent_response = json.loads(json.dumps(zero_selector_response))
        adjacent_response["pseudocode"] = "\n".join(
            [zero_selector_lines[0], adjacent_messages, zero_selector_lines[2]]
        )
        adjacent_response["lines"][1]["text"] = adjacent_messages
        adjacent_audit = json.loads(json.dumps(zero_selector_audit))
        adjacent_audit["calls"][0]["rendered_utf8_sha256"] = hashlib.sha256(
            adjacent_messages.encode("utf-8")
        ).hexdigest()
        try:
            validate_call_argument_audit(
                adjacent_audit,
                expected_address="0x2000", expected_name="zero_selector",
                decompile_response=adjacent_response,
                expected_binary_sha256="1" * 64,
                expected_executable_sha256="2" * 64,
                expected_toolchain_identity=toolchain,
                returning_call_addresses=["0x2010"],
                context="self-test adjacent zero-selector messages",
            )
        except RuntimeError as error:
            if "zero-selector" not in str(error):
                raise
        else:
            raise AssertionError("adjacent zero-selector messages passed full validation")
        nested = value_register("x0", 0)
        for _ in range(32):
            nested = {"kind": "unary", "operator": "-", "value": nested}
        validate_value_identity(nested, "self-test depth32")
        too_deep = {"kind": "unary", "operator": "-", "value": nested}
        try:
            validate_value_identity(too_deep, "self-test depth33")
        except RuntimeError as error:
            if "recursion" not in str(error):
                raise
        else:
            raise AssertionError("value identity depth 33 was accepted")

        nested_mutations = []
        mutation = json.loads(json.dumps(calls_audit))
        mutation["calls"][0]["arguments"][0]["location"]["index"] = True
        nested_mutations.append(mutation)
        mutation = json.loads(json.dumps(calls_audit))
        mutation["calls"][2]["arguments"][1]["role"] = "anonymous-variadic"
        mutation["calls"][2]["arguments"][1]["source_position"] = None
        mutation["calls"][2]["arguments"][1]["tail_ordinal"] = 0
        nested_mutations.append(mutation)
        mutation = json.loads(json.dumps(calls_audit))
        mutation["calls"][2]["observation"]["gpr_indices"] = [0]
        nested_mutations.append(mutation)
        mutation = json.loads(json.dumps(calls_audit))
        mutation["calls"][2]["arguments"][0]["safe_render_reason"] = "objc-complete-message"
        nested_mutations.append(mutation)
        mutation = json.loads(json.dumps(calls_audit))
        mutation["calls"][1]["control_inputs"].append({
            "role": "pointer-authentication-modifier", "register": "x8",
            "value_identity": value_register("x8", 99),
        })
        nested_mutations.append(mutation)
        mutation = json.loads(json.dumps(calls_audit))
        mutation["calls"][0]["unexpected"] = None
        nested_mutations.append(mutation)
        mutation = json.loads(json.dumps(calls_audit))
        mutation["calls"][0]["arguments"][0]["location"]["index"] = 1
        nested_mutations.append(mutation)
        mutation = json.loads(json.dumps(calls_audit))
        mutation["calls"][0]["target"] = "invented_signature"
        mutation["calls"][0]["known_signature_id"] = "invented_signature"
        nested_mutations.append(mutation)
        mutation = json.loads(json.dumps(calls_audit))
        mutation["calls"][2]["arguments"][0]["location"]["index"] = 2
        nested_mutations.append(mutation)
        for mutation_index, mutation in enumerate(nested_mutations):
            try:
                validate_call_argument_audit(
                    mutation,
                    expected_address="0x1000", expected_name="calls",
                    decompile_response=call_response,
                    expected_binary_sha256="1" * 64,
                    expected_executable_sha256="2" * 64,
                    expected_toolchain_identity=toolchain,
                    returning_call_addresses=["0x1010", "0x1020", "0x1030"],
                    context="self-test invalid nested audit",
                )
            except RuntimeError:
                pass
            else:
                raise AssertionError(
                    f"invalid nested call audit mutation {mutation_index} was accepted"
                )
        if len(FROZEN_SIGNATURES) != 500:
            raise AssertionError("frozen signature catalog is not the exact 500-entry map")
        printf_signature = frozen_signature_for_target("_printf")
        if printf_signature is None or printf_signature["locations"] != (("gpr", 0, 64),):
            raise AssertionError("printf frozen signature layout is wrong")
        try:
            require_string("bad\u200dtext", "self-test Unicode category-C")
        except RuntimeError:
            pass
        else:
            raise AssertionError("Unicode category-C string was accepted")
        sampled_commands = []

        def fake_tool(command, environment):
            sampled_commands.append((list(command), dict(environment)))
            if command == ["/usr/bin/xcodebuild", "-version"]:
                return "Xcode 27.0\nBuild version 18A100\n"
            if command == ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]:
                return "27.0\n"
            if command == ["/usr/bin/xcrun", "--sdk", "macosx", "--find", "clang"]:
                return "/Xcode/usr/bin/clang\n"
            if command == ["/Xcode/usr/bin/clang", "--version"]:
                return "\nApple clang version 21.0.0\nTarget: arm64-apple-macos\n"
            raise AssertionError(f"unexpected tool command {command!r}")

        sampled_toolchain = sample_active_toolchain(
            run_command=fake_tool,
            environment={
                "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/../Contents/Developer"
            },
        )
        if sampled_toolchain != toolchain:
            raise AssertionError(f"toolchain normalization drifted: {sampled_toolchain!r}")
        if not sampled_commands or any(
            environment.get("LANG") != "C"
            or environment.get("LC_ALL") != "C"
            or environment.get("LANGUAGE") != "C"
            for _, environment in sampled_commands
        ):
            raise AssertionError("toolchain sampling did not force the C locale")
        if any(
            environment.get("DEVELOPER_DIR")
            != "/Applications/Xcode.app/Contents/Developer"
            for _, environment in sampled_commands
        ):
            raise AssertionError("toolchain sampling did not canonicalize DEVELOPER_DIR")
        function_rows = [
            {"name": "calls", "address": "0x1000", "end": "0x1040", "confidence": 1.0},
            {"name": "quiet", "address": "0x1040", "end": "0x1044", "confidence": 0.9},
        ]
        validated_functions = validate_functions_response(function_rows, "self-test functions")
        if [row["address"] for row in validated_functions] != ["0x1000", "0x1040"]:
            raise AssertionError("function validation changed canonical order")
        instruction_rows = [
            {"address": "0x1000", "bytes": "00 00 00 00", "mnemonic": "mov", "operands": "x0, x0"},
            {"address": "0x1010", "bytes": "00 00 00 94", "mnemonic": "bl", "operands": "_printf"},
            {"address": "0x1020", "bytes": "00 01 3f d6", "mnemonic": "BLR", "operands": "x8"},
            {"address": "0x1030", "bytes": "00 00 00 94", "mnemonic": "blraa", "operands": "x8, x9"},
            {"address": "0x1040", "bytes": "c0 03 5f d6", "mnemonic": "ret", "operands": ""},
        ]
        returning = returning_instruction_addresses(
            instruction_rows, validated_functions[0], "self-test instructions"
        )
        if returning != ["0x1010", "0x1020", "0x1030"]:
            raise AssertionError(f"returning instruction enumeration failed: {returning!r}")
        malformed_functions = json.loads(json.dumps(function_rows))
        malformed_functions[1]["address"] = "0x1000"
        try:
            validate_functions_response(malformed_functions, "self-test duplicate function")
        except RuntimeError:
            pass
        else:
            raise AssertionError("duplicate function start was accepted")
        with tempfile.TemporaryDirectory(prefix="macscope-sweep-publication-test-") as raw:
            publication_root = Path(raw)
            publication_output = publication_root / "output"
            publication_output.mkdir()
            publication_executable = publication_root / "MacScope"
            publication_executable.write_bytes(b"executable")
            publication_corpus = publication_root / "fixture"
            publication_corpus.write_bytes(b"corpus")
            validate_output_paths(
                publication_executable,
                publication_output,
                {"fixture": publication_corpus},
            )
            for stale_name in ("_producer.json", "_histogram.json", "fixture.json"):
                stale_path = publication_output / stale_name
                stale_payload = ("stale:" + stale_name).encode("utf-8")
                stale_path.write_bytes(stale_payload)
                try:
                    validate_output_paths(
                        publication_executable,
                        publication_output,
                        {"fixture": publication_corpus},
                    )
                except RuntimeError as error:
                    if "already exists" not in str(error):
                        raise
                else:
                    raise AssertionError(
                        f"existing planned output {stale_name} was accepted"
                    )
                if stale_path.read_bytes() != stale_payload:
                    raise AssertionError(
                        f"existing planned output {stale_name} was modified"
                    )
                stale_path.unlink()
            broken_manifest = publication_output / "_producer.json"
            broken_target = publication_root / "missing-manifest-target"
            broken_manifest.symlink_to(broken_target)
            try:
                validate_output_paths(
                    publication_executable,
                    publication_output,
                    {"fixture": publication_corpus},
                )
            except RuntimeError as error:
                if "already exists" not in str(error):
                    raise
            else:
                raise AssertionError("a broken-symlink planned output was accepted")
            if not broken_manifest.is_symlink() or os.readlink(
                broken_manifest
            ) != str(broken_target):
                raise AssertionError("a broken-symlink planned output was modified")
            broken_manifest.unlink()
            alias_executable = publication_output / "fixture.json"
            alias_executable.write_bytes(b"alias")
            try:
                validate_output_paths(
                    alias_executable,
                    publication_output,
                    {"fixture": publication_corpus},
                )
            except RuntimeError as error:
                if "aliases" not in str(error):
                    raise
            else:
                raise AssertionError("output/executable alias was accepted")
            alias_executable.unlink()
            histogram_alias = publication_output / "_histogram.json"
            os.link(publication_corpus, histogram_alias)
            try:
                validate_output_paths(
                    publication_executable,
                    publication_output,
                    {"fixture": publication_corpus},
                )
            except RuntimeError as error:
                if "aliases" not in str(error):
                    raise
            else:
                raise AssertionError("hard-linked output/input alias was accepted")
            histogram_alias.unlink()
            atomic_path = publication_output / "atomic.json"
            atomic_write_json(atomic_path, {"schema": "atomic-test"}, indent=2)
            if strict_json_loads(atomic_path.read_text(encoding="utf-8"), "atomic") != {
                "schema": "atomic-test"
            }:
                raise AssertionError("atomic JSON publication changed its payload")
            atomic_payload = atomic_path.read_bytes()
            try:
                atomic_write_json(
                    atomic_path, {"schema": "must-not-overwrite"}, indent=2
                )
            except RuntimeError as error:
                if "already exists" not in str(error):
                    raise
            else:
                raise AssertionError("atomic publication overwrote an existing artifact")
            if atomic_path.read_bytes() != atomic_payload:
                raise AssertionError("failed atomic publication changed existing bytes")
            manifest = build_producer_manifest(
                producer_code=code_artifacts,
                executable_snapshot={
                    "realpath": str(publication_executable.resolve()),
                    "size": publication_executable.stat().st_size,
                    "sha256": sha256_file(publication_executable),
                },
                corpus_basenames=["fixture"],
                parameter_audit_available=True,
                call_audit_capability="validated-v1",
                input_manifests={"fixture": {
                    "input_realpath": str(publication_corpus.resolve()),
                    "input_sha256": sha256_file(publication_corpus),
                    "input_size": publication_corpus.stat().st_size,
                    "record_count": 1,
                    "output_sha256": "4" * 64,
                }},
            )
            if set(manifest) != {
                "schema", "record_schema", "producer_code_artifacts",
                "executable_path", "executable_size", "executable_sha256",
                "invocation", "runtime", "corpora",
            }:
                raise AssertionError("producer-v3 manifest top level is not closed")
            if "sweep_script_sha256" in manifest or "sweep_script_realpath" in manifest:
                raise AssertionError("producer-v3 retained legacy script provenance")
        wrong_line_response = json.loads(json.dumps(call_response))
        wrong_line_response["lines"][1]["address"] = "0x1014"
        try:
            validate_call_argument_audit(
                calls_audit,
                expected_address="0x1000", expected_name="calls",
                decompile_response=wrong_line_response,
                expected_binary_sha256="1" * 64,
                expected_executable_sha256="2" * 64,
                expected_toolchain_identity=toolchain,
                returning_call_addresses=["0x1010", "0x1020", "0x1030"],
                context="self-test wrong line source",
            )
        except RuntimeError as error:
            if "source" not in str(error):
                raise
        else:
            raise AssertionError("wrong rendered-line source address was accepted")
        pair_text = "    local_10, local_18 = x0_0, x1_0; // saves register pair"
        response = {
            "function": "fixture",
            "address": "0x1000",
            "pseudocode": "\n".join([
                "int64_t fixture(void) {",
                pair_text,
                "    return 0;",
                pair_text,
                "}",
            ]),
            "lines": [
                {"n": 1, "kind": "signature", "text": "int64_t fixture(void) {"},
                {"n": 2, "kind": "instruction", "text": pair_text, "address": "0x1000"},
                {"n": 3, "kind": "instruction", "text": "    return 0;", "address": "0x1004"},
                {"n": 4, "kind": "instruction", "text": pair_text, "address": "0x1008"},
                {"n": 5, "kind": "closingBrace", "text": "}"},
            ],
        }
        all_instruction_lines = build_instruction_line_audit(
            response,
            expected_address="0x1000",
            expected_name="fixture",
            context="self-test all pair and ordinary instruction lines",
        )
        if [
            record["instruction_address"]
            for record in all_instruction_lines["records"]
        ] != ["0x1000", "0x1004", "0x1008"]:
            raise AssertionError(
                "instruction-line audit did not retain pair and ordinary lines"
            )
        if [
            record["text_occurrence"]
            for record in all_instruction_lines["records"]
        ] != [0, 0, 1]:
            raise AssertionError(
                "instruction-line audit did not disambiguate duplicate pair text"
            )
        audit = build_pair_line_instruction_audit(response, "[self-test] 0x1000")
        if audit.get("schema") != PAIR_LINE_AUDIT_SCHEMA:
            raise AssertionError("pair-line audit schema is missing")
        if audit.get("validation_scope") != "structural-candidate":
            raise AssertionError("pair-line audit scope is not candidate-structural")
        if audit.get("combined_oracle_comparison") is not False:
            raise AssertionError("pair-line audit claims an external comparison")
        if audit.get("function_address") != "0x1000":
            raise AssertionError("pair-line audit does not bind the function address")
        if [row.get("line_ordinal") for row in audit.get("records", [])] != [2, 4]:
            raise AssertionError("pair-line audit did not bind exact line ordinals")
        if [row.get("text_occurrence") for row in audit.get("records", [])] != [0, 1]:
            raise AssertionError("duplicate pair text occurrences are not disambiguated")
        if [row.get("instruction_address") for row in audit.get("records", [])] != [
            "0x1000", "0x1008"
        ]:
            raise AssertionError("pair-line audit did not preserve source addresses")
        if any(row.get("line_text_sha256") != hashlib.sha256(pair_text.encode()).hexdigest()
               for row in audit.get("records", [])):
            raise AssertionError("pair-line audit text digest is incorrect")

        prefixed_save_text = (
            "    local_20, local_28 = x2_0, x3_0; "
            "// spill pair; saves register pair"
        )
        prefixed_restore_text = (
            "    x2_1, x3_1 = local_20, local_28; "
            "// reload pair; restores register pair; recovered stack[0x20], stack[0x28]"
        )
        near_miss_text = "    helper(); // saves register pairwise"
        prefixed_response = {
            "address": "0x1010",
            "pseudocode": "\n".join([
                prefixed_save_text,
                prefixed_restore_text,
                near_miss_text,
            ]),
            "lines": [
                {"n": 1, "kind": "instruction", "text": prefixed_save_text,
                 "address": "0x1010"},
                {"n": 2, "kind": "instruction", "text": prefixed_restore_text,
                 "address": "0x1014"},
                {"n": 3, "kind": "instruction", "text": near_miss_text,
                 "address": "0x1018"},
            ],
        }
        prefixed_audit = build_pair_line_instruction_audit(
            prefixed_response, "[self-test] prefixed pair annotation"
        )
        if [row.get("line_ordinal") for row in prefixed_audit.get("records", [])] != [1, 2]:
            raise AssertionError("prefixed pair annotations were not audited exactly")

        missing_address = json.loads(json.dumps(response))
        del missing_address["lines"][1]["address"]
        try:
            build_pair_line_instruction_audit(missing_address, "[self-test] missing address")
        except RuntimeError as error:
            if "lacks an instruction address" not in str(error):
                raise
        else:
            raise AssertionError("pair line without an instruction address was accepted")

        mismatched_text = json.loads(json.dumps(response))
        mismatched_text["lines"][1]["text"] = "    unrelated();"
        try:
            build_pair_line_instruction_audit(mismatched_text, "[self-test] mismatched text")
        except RuntimeError as error:
            if "does not reconstruct pseudocode" not in str(error):
                raise
        else:
            raise AssertionError("line metadata that disagrees with pseudocode was accepted")

        non_instruction_pair = json.loads(json.dumps(response))
        non_instruction_pair["lines"][1]["kind"] = "comment"
        try:
            build_pair_line_instruction_audit(
                non_instruction_pair, "[self-test] non-instruction pair"
            )
        except RuntimeError as error:
            if "not an instruction" not in str(error):
                raise
        else:
            raise AssertionError("pair marker on a non-instruction line was accepted")

        duplicate_pair_address = json.loads(json.dumps(response))
        duplicate_pair_address["lines"][3]["address"] = "0x1000"
        try:
            build_pair_line_instruction_audit(
                duplicate_pair_address, "[self-test] duplicate pair address"
            )
        except RuntimeError as error:
            if "duplicated" not in str(error):
                raise
        else:
            raise AssertionError("duplicate pair instruction address was accepted")

        with tempfile.TemporaryDirectory(prefix="macscope-sweep-self-test-") as raw_directory:
            directory = Path(raw_directory)
            fake = directory / "echo-script-path.py"
            fake.write_text(
                "#!/usr/bin/python3\n"
                "import sys\n"
                "print(sys.argv[2])\n",
                encoding="utf-8",
            )
            fake.chmod(0o755)
            MACSCOPE = str(fake)
            OUTDIR = str(directory)
            first_stdout, _ = run_script([{"command": "functions"}], "/tmp/input")
            second_stdout, _ = run_script([{"command": "commands"}], "/tmp/input")
            first_path = first_stdout.strip()
            second_path = second_stdout.strip()
            if first_path == second_path:
                raise AssertionError("sweep script paths are reused between invocations")
            if Path(first_path).exists() or Path(second_path).exists():
                raise AssertionError("temporary sweep script was not removed after invocation")

            legitimate = directory / "legitimate-macscope.py"
            alternate = directory / "alternate-macscope.py"
            saved_legitimate = directory / "saved-legitimate-macscope.py"
            pinned_input = directory / "pinned-input.bin"
            saved_input = directory / "saved-pinned-input.bin"
            legitimate.write_text(
                "#!/usr/bin/python3\n"
                "import pathlib, sys\n"
                "print('legitimate-executable:' + pathlib.Path(sys.argv[3]).read_text())\n",
                encoding="utf-8",
            )
            alternate.write_text(
                "#!/usr/bin/python3\nprint('alternate-executable')\n",
                encoding="utf-8",
            )
            legitimate.chmod(0o755)
            alternate.chmod(0o755)
            pinned_input.write_bytes(b"pinned corpus bytes")
            with pinned_sweep_inputs(
                str(legitimate), {"pinned-input.bin": str(pinned_input)}
            ):
                os.replace(legitimate, saved_legitimate)
                os.replace(alternate, legitimate)
                os.replace(pinned_input, saved_input)
                pinned_input.write_bytes(b"alternate corpus bytes")
                try:
                    pinned_stdout, _ = run_script(
                        [{"command": "commands"}], str(pinned_input)
                    )
                finally:
                    pinned_input.unlink()
                    os.replace(saved_input, pinned_input)
                    os.replace(saved_legitimate, legitimate)
                if pinned_stdout.strip() != "legitimate-executable:pinned corpus bytes":
                    raise AssertionError(
                        "transient input pathname replacement redirected sweep evidence"
                    )

            mismatched_response = json.loads(json.dumps(no_call_response))
            mismatched_response["address"] = "0x2000"
            try:
                validate_decompile_response(
                    mismatched_response, "0x1000", "quiet",
                    "self-test mismatched decompile",
                )
            except RuntimeError as error:
                if "address disagreement" not in str(error):
                    raise
            else:
                raise AssertionError("mismatched decompile response address was accepted")
    finally:
        MACSCOPE = original_macscope
        OUTDIR = original_outdir


if SELF_TEST_MODE:
    run_self_tests()
    print("self-test: PASS (closed schemas, mutations, provenance, publication)")
    raise SystemExit(0)


def verify_inputs_unchanged(initial_producer, initial_corpora, phase):
    try:
        if file_snapshot(MACSCOPE) != initial_producer:
            raise RuntimeError(f"MacScope executable changed {phase}")
        for base, path in CORPUS_BY_BASE.items():
            if file_snapshot(path) != initial_corpora[base]:
                raise RuntimeError(f"corpus {base} changed {phase}")
    except OSError as error:
        raise RuntimeError(f"cannot re-fingerprint sweep input {phase}: {error}") from error


def verify_artifacts_unchanged(input_manifests, phase):
    for base, manifest in input_manifests.items():
        artifact_path = Path(OUTDIR) / f"{base}.json"
        if sha256_file(artifact_path) != manifest["output_sha256"]:
            raise RuntimeError(f"output artifact {artifact_path} changed {phase}")


def dump_histogram(title, counts, top=25):
    total = sum(counts.values())
    print(f"\n== {title} (total {total}) ==")
    for key, count in counts.most_common(top):
        percentage = 100.0 * count / total if total else 0
        print(f"  {count:6d}  {percentage:5.1f}%  {key}")


def _run_sweep_pinned(initial_producer, initial_corpora):
    expected_public_artifacts = {f"{base}.json" for base in CORPUS_BY_BASE}
    stale_public_artifacts = {
        name for name in os.listdir(OUTDIR)
        if name.endswith(".json") and not name.startswith("_")
        and name not in expected_public_artifacts
    }
    if stale_public_artifacts:
        raise RuntimeError(
            "output directory contains stale corpus JSON artifacts: "
            + ", ".join(sorted(stale_public_artifacts))
        )

    initial_producer_code = producer_code_artifacts()
    initial_toolchain = sample_active_toolchain()

    initial_capabilities = None
    parameter_binding_audit_available = None
    call_argument_audit_available = None
    aggregate_fallback, aggregate_fatal, aggregate_site = Counter(), Counter(), Counter()
    per_binary = {}
    input_manifests = {}

    for base, binary in CORPUS_BY_BASE.items():
        capabilities = probe_capabilities(binary, f"[{base}] commands")
        if initial_capabilities is None:
            initial_capabilities = capabilities
            parameter_binding_audit_available = capabilities[
                "parameter_binding_audit_available"
            ]
            call_argument_audit_available = capabilities[
                "call_argument_audit_available"
            ]
            if not parameter_binding_audit_available:
                raise RuntimeError(
                    "record-v6 requires the parameter-binding-audit capability"
                )
        elif capabilities != initial_capabilities:
            raise RuntimeError(f"[{base}] scripting audit capability drifted")

        function_stdout, _ = run_script([{"command": "functions"}], binary)
        function_results = parse_script_results(
            function_stdout, f"[{base}] functions"
        )
        if len(function_results) != 1:
            raise RuntimeError(f"[{base}] functions response has an unexpected envelope")
        functions = validate_functions_response(
            function_results[0], f"[{base}] functions[0]"
        )
        addresses = [function["address"] for function in functions]

        decompile_steps = [
            {"command": "decompile", "arguments": {"address": address}}
            for address in addresses
        ]
        decompile_stdout, decompile_stderr = run_script(
            decompile_steps, binary, diag=True
        )
        decompile_results = parse_script_results(
            decompile_stdout, f"[{base}] decompile"
        )
        if len(decompile_results) != len(functions):
            raise RuntimeError(
                f"[{base}] decompile result count {len(decompile_results)} does not "
                f"match function count {len(functions)}"
            )
        for function, response in zip(functions, decompile_results):
            validate_decompile_response(
                response,
                function["address"],
                function["name"],
                f"[{base}] {function['address']} decompile",
            )

        instruction_steps = [
            {
                "command": "instructions",
                "arguments": {
                    "address": function["address"],
                    "count": instruction_query_count(function),
                },
            }
            for function in functions
        ]
        instruction_stdout, _ = run_script(instruction_steps, binary)
        instruction_results = parse_script_results(
            instruction_stdout, f"[{base}] instructions"
        )
        if len(instruction_results) != len(functions):
            raise RuntimeError(
                f"[{base}] instruction result count {len(instruction_results)} does "
                f"not match function count {len(functions)}"
            )
        returning_calls = [
            returning_instruction_addresses(
                result, function, f"[{base}] {function['address']} instructions"
            )
            for function, result in zip(functions, instruction_results)
        ]

        if parameter_binding_audit_available:
            parameter_stdout, _ = run_script([
                {
                    "command": "parameter-binding-audit",
                    "arguments": {"address": address},
                }
                for address in addresses
            ], binary)
            parameter_audits = parse_script_results(
                parameter_stdout, f"[{base}] parameter binding audit"
            )
            if len(parameter_audits) != len(functions):
                raise RuntimeError(
                    f"[{base}] parameter audit count {len(parameter_audits)} does not "
                    f"match function count {len(functions)}"
                )
            parameter_audits = [
                validate_parameter_binding_audit(
                    audit, address, f"[{base}] {address} parameter audit"
                )
                for address, audit in zip(addresses, parameter_audits)
            ]
        else:
            parameter_audits = [None] * len(functions)

        if call_argument_audit_available:
            call_stdout, _ = run_script([
                {
                    "command": "call-argument-audit",
                    "arguments": {"address": address},
                }
                for address in addresses
            ], binary)
            call_audits = parse_script_results(
                call_stdout, f"[{base}] call argument audit"
            )
            if len(call_audits) != len(functions):
                raise RuntimeError(
                    f"[{base}] call audit count {len(call_audits)} does not match "
                    f"function count {len(functions)}"
                )
            call_audits = [
                validate_call_argument_audit(
                    audit,
                    expected_address=function["address"],
                    expected_name=function["name"],
                    decompile_response=decompile_response,
                    expected_binary_sha256=initial_corpora[base]["sha256"],
                    expected_executable_sha256=initial_producer["sha256"],
                    expected_toolchain_identity=initial_toolchain,
                    returning_call_addresses=call_addresses,
                    context=f"[{base}] {function['address']} call audit",
                )
                for function, decompile_response, audit, call_addresses in zip(
                    functions, decompile_results, call_audits, returning_calls
                )
            ]
        else:
            call_audits = [None] * len(functions)

        fallback_counts, fatal_counts, site_counts = Counter(), Counter(), Counter()
        diagnostic_by_name = {}
        diagnostic_by_address = {}
        address_pattern = re.compile(r"sub_0x0*([0-9a-fA-F]+)")
        for line in decompile_stderr.splitlines():
            match = DIAG.match(line)
            if not match:
                continue
            fallback = match.group("fb")
            fatal = match.group("fatal")
            sites = match.group("sites")
            diagnostic_by_name[match.group("fn")] = (fallback, fatal)
            address_match = address_pattern.search(match.group("fn"))
            if address_match:
                diagnostic_by_address[
                    hex(int(address_match.group(1), 16))
                ] = (fallback, fatal)
            for token in sites.split(","):
                token = token.strip()
                if not token or ":" not in token:
                    continue
                site, count = token.rsplit(":", 1)
                try:
                    site_counts[site.strip()] += int(count)
                except ValueError:
                    pass

        records = []
        for function, response, parameter_audit, call_audit in zip(
            functions, decompile_results, parameter_audits, call_audits
        ):
            address = function["address"]
            name = function["name"]
            pseudocode = response["pseudocode"]
            pair_line_audit = build_pair_line_instruction_audit(
                response, f"[{base}] {address}"
            )
            function_identity = build_function_identity(
                function, f"[{base}] {address} function identity"
            )
            instruction_line_audit = build_instruction_line_audit(
                response,
                expected_address=address,
                expected_name=name,
                context=f"[{base}] {address} instruction-line audit",
            )
            response_fallback_value = response_fallback(
                response, f"[{base}] {address}"
            )
            diagnostic = diagnostic_by_name.get(name)
            if diagnostic is None:
                diagnostic = diagnostic_by_address.get(address)
            if diagnostic is None:
                diagnostic_fallback, fatal = None, "notEmitted"
            else:
                diagnostic_fallback, fatal = diagnostic
            if (
                diagnostic_fallback is not None
                and diagnostic_fallback != response_fallback_value
            ):
                raise RuntimeError(
                    f"[{base}] {address}: stderr fallback {diagnostic_fallback!r} "
                    f"disagrees with decompile response {response_fallback_value!r}"
                )
            fallback_counts[response_fallback_value] += 1
            fatal_counts[fatal] += 1
            record = {
                "address": address,
                "pseudocode": pseudocode,
                "fallback": response_fallback_value,
                "fatal": fatal,
                "gotos": pseudocode.count(" goto "),
                "unknowns": pseudocode.count('__unknown("'),
                "parameter_binding_audit": parameter_audit,
                "pair_line_instruction_audit": pair_line_audit,
                "call_argument_audit": call_audit,
                "function_identity": function_identity,
                "instruction_line_audit": instruction_line_audit,
            }
            if set(record) != {
                "address", "pseudocode", "fallback", "fatal", "gotos", "unknowns",
                "parameter_binding_audit", "pair_line_instruction_audit",
                "call_argument_audit", "function_identity", "instruction_line_audit",
            }:
                raise RuntimeError(f"[{base}] {address}: record-v6 is not closed")
            records.append(record)

        if len(records) != len(functions) or any(
            not record["fallback"] for record in records
        ):
            raise RuntimeError(f"[{base}] failed to map every function to record-v6")
        per_binary[base] = {
            "fallback": fallback_counts,
            "fatal": fatal_counts,
            "site": site_counts,
            "nfuncs": len(functions),
            "ndiag": len(records),
        }
        aggregate_fallback += fallback_counts
        aggregate_fatal += fatal_counts
        aggregate_site += site_counts

        artifact_path = Path(OUTDIR) / f"{base}.json"
        atomic_write_json(artifact_path, records)
        input_snapshot = initial_corpora[base]
        input_manifests[base] = {
            "input_realpath": input_snapshot["realpath"],
            "input_sha256": input_snapshot["sha256"],
            "input_size": input_snapshot["size"],
            "record_count": len(records),
            "output_sha256": sha256_file(artifact_path),
        }
        verify_producer_code_checkpoint(
            initial_producer_code, f"after corpus artifact {base}"
        )
        verify_inputs_unchanged(
            initial_producer, initial_corpora, f"after corpus artifact {base}"
        )
        print(
            f"[{base}] fns={len(functions)} diag={sum(fallback_counts.values())} "
            f"structured={fallback_counts.get('structured', 0)} "
            f"unsupportedRegion={fallback_counts.get('unsupportedRegion', 0)} "
            f"unstructurableCFG={fallback_counts.get('unstructurableCFG', 0)}"
        )

    print("\n########## AGGREGATE ##########")
    dump_histogram("FALLBACK distribution", aggregate_fallback)
    dump_histogram(
        "FATAL veto per-function (actionable: 1 bail cause / fn)", aggregate_fatal
    )
    dump_histogram(
        "SITE veto counts (recursive; total site hits)", aggregate_site, top=30
    )

    histogram = {
        "aggregate": {
            "fallback": dict(aggregate_fallback),
            "fatal": dict(aggregate_fatal),
            "site": dict(aggregate_site),
        },
        "per_binary": {
            base: {
                "fallback": dict(result["fallback"]),
                "fatal": dict(result["fatal"]),
                "site": dict(result["site"]),
                "nfuncs": result["nfuncs"],
            }
            for base, result in per_binary.items()
        },
    }
    atomic_write_json(Path(OUTDIR) / "_histogram.json", histogram, indent=2)

    verify_inputs_unchanged(initial_producer, initial_corpora, "during the sweep")
    verify_artifacts_unchanged(input_manifests, "before manifest publication")
    discovered_artifacts = {
        os.path.splitext(name)[0]
        for name in os.listdir(OUTDIR)
        if name.endswith(".json") and not name.startswith("_")
    }
    if discovered_artifacts != set(input_manifests):
        raise RuntimeError(
            "output directory contains stale or missing corpus JSON artifacts"
        )

    final_producer_code = verify_producer_code_checkpoint(
        initial_producer_code, "before manifest construction"
    )
    call_audit_capability = (
        "validated-v1" if call_argument_audit_available else "unavailable"
    )
    manifest = build_producer_manifest(
        producer_code=final_producer_code,
        executable_snapshot={
            "realpath": initial_producer["realpath"],
            "size": initial_producer["size"],
            "sha256": initial_producer["sha256"],
        },
        corpus_basenames=list(CORPUS_BY_BASE),
        parameter_audit_available=parameter_binding_audit_available,
        call_audit_capability=call_audit_capability,
        input_manifests=input_manifests,
    )
    producer_temporary = _write_json_temp(PRODUCER_PATH, manifest, indent=2)
    try:
        # Final resampling is deliberately after the durable manifest temporary has
        # been rendered and immediately before its one atomic publication step.
        prepublication_code = verify_producer_code_checkpoint(
            initial_producer_code, "before manifest publication"
        )
        if manifest["producer_code_artifacts"] != prepublication_code:
            raise RuntimeError("manifest does not contain final verified producer code")
        verify_inputs_unchanged(
            initial_producer, initial_corpora, "before manifest publication"
        )
        verify_artifacts_unchanged(
            input_manifests, "before manifest publication"
        )
        if sample_active_toolchain() != initial_toolchain:
            raise RuntimeError("active toolchain changed before manifest publication")
        _publish_json_temp(producer_temporary, PRODUCER_PATH)
    finally:
        try:
            producer_temporary.unlink()
        except FileNotFoundError:
            pass

    print(f"\nWrote {OUTDIR}/_histogram.json + _producer.json + per-binary .json")


def run_sweep():
    validate_output_paths(MACSCOPE, OUTDIR, CORPUS_BY_BASE)
    try:
        with pinned_sweep_inputs(MACSCOPE, CORPUS_BY_BASE) as snapshots:
            _run_sweep_pinned(*snapshots)
    except OSError as error:
        raise RuntimeError(f"cannot bind sweep input: {error}") from error


run_sweep()
