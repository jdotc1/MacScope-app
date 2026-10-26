#!/usr/bin/env python3
"""WS-13 caller-clobber and WS-14 parameter-identity corpus oracle.

Compare two enriched ``sweep.py`` output directories and enforce the invariants
that a call-boundary-only change can prove on real binaries:

  G0  Inputs use the enriched sweep schema, map every function diagnostic, and
      come from distinct producer executables.
  G1  Functions containing no returning call have byte-identical pseudocode.
  G2  Every changed function is anchored to a real ``bl*`` call in otool output.
  G3  Recovered ``argN`` names are monotonic subsets; the candidate adds none.
  G4  Candidate text introduces no unavailable marker for state preserved by the
      frozen Apple boundary (x19...x29/fp, sp, or scalar d/s8...d/s15).

The positive proof that volatile state is invalidated belongs in focused unit
tests. This oracle independently checks corpus scope and preservation; it does
not claim that external pseudocode is a trusted semantic oracle.

When both manifests use the enriched WS-14 record schema and the candidate
advertises ``parameter-binding-audit``, every changed function must normalize
exactly to the baseline through validated ABI-only names, conservative
definite-unknown-write tombstones, and removal of trailing unbound raw call
inputs. No broad changed-call exemption is used in that mode.

Usage:
  call_clobber_oracle.py BASELINE_DIR CANDIDATE_DIR
  call_clobber_oracle.py BASELINE_DIR CANDIDATE_DIR \
      --binary objc_corpus=/path/to/objc_corpus
  call_clobber_oracle.py --self-test

Known sweep names (ls, grep, ssh, zsh, swift_corpus, objc_corpus) resolve to the
repository/system binaries automatically. Use repeatable ``--binary NAME=PATH``
for any additional sweep basename or to override a known path.

Exit status: 0 = pass, 1 = invalid input/tool failure, 2 = gate violation.
"""

from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

from parameter_binding_oracle import (
    OracleError as ParameterAuditError,
    validate_candidate_audit,
)


REPO_ROOT = Path(__file__).resolve().parents[2]
KNOWN_BINARIES = {
    "ls": Path("/bin/ls"),
    "grep": Path("/usr/bin/grep"),
    "ssh": Path("/usr/bin/ssh"),
    "zsh": Path("/bin/zsh"),
    "swift_corpus": REPO_ROOT
    / "MacScope/Tests/CoreTests/GoldenFixtures/swift_corpus/swift_corpus",
    "objc_corpus": REPO_ROOT
    / "MacScope/Tests/CoreTests/GoldenFixtures/objc_corpus/objc_corpus",
}
RETURNING_CALL_MNEMONICS = {
    "bl",
    "blr",
    "blraa",
    "blrab",
    "blraaz",
    "blrabz",
}
REQUIRED_RECORD_FIELDS = (
    "address", "pseudocode", "fallback", "fatal", "gotos", "unknowns",
    "pair_line_instruction_audit",
)
PRODUCER_METADATA_NAME = "_producer.json"
PRODUCER_SCHEMA = "macscope-sweep-producer-v2"
PARAMETER_RECORD_SCHEMA = "macscope-sweep-record-v4"
PAIR_LINE_AUDIT_SCHEMA = "pair-line-instruction-audit-v1"
ARG_NAME = re.compile(r"\barg[0-9]+\b")
PRESERVED_UNAVAILABLE = re.compile(
    r"\bunavailable_(?:"
    r"[xw](?:19|2[0-9])"
    r"|fp|sp"
    r"|[ds](?:8|9|1[0-5])"
    r")\b",
    re.IGNORECASE,
)


class OracleError(Exception):
    """An invalid input or failed local oracle tool invocation."""


@dataclass(frozen=True)
class SweepRecord:
    address_text: str
    pseudocode: str
    fallback: str
    fatal: str
    gotos: int
    unknowns: int
    parameter_binding_audit: dict[str, object] | None = None
    pair_line_instruction_audit: dict[str, object] | None = None


@dataclass(frozen=True)
class ProducerMetadata:
    executable_sha256: str
    executable_size: int
    corpora: dict[str, "CorpusManifest"]
    record_schema: str | None = None
    sweep_script_sha256: str | None = None
    invocation: dict[str, object] | None = None


@dataclass(frozen=True)
class CorpusManifest:
    input_realpath: str
    input_sha256: str
    input_size: int
    record_count: int
    output_sha256: str


@dataclass
class CorpusResult:
    name: str
    functions: int
    call_sites: int
    call_functions: int
    changed_functions: int = 0
    no_call_checked: int = 0
    no_call_identical: int = 0
    changed_anchored: int = 0
    parameter_identity_changes: int = 0
    arg_sets_checked: int = 0
    marker_functions_checked: int = 0
    violations: list[tuple[str, str, str]] = field(default_factory=list)


def parse_hex_address(value: object, context: str) -> int:
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]+", value):
        raise OracleError(f"{context}: address must be a 0x-prefixed hex string, got {value!r}")
    return int(value, 16)


def validate_pair_line_instruction_audit(
    audit: object,
    pseudocode: str,
    function_address: str,
    context: str,
) -> dict[str, object]:
    if not isinstance(audit, dict):
        raise OracleError(f"{context}: pair-line audit must be an object")
    expected_envelope = {
        "schema",
        "validation_scope",
        "combined_oracle_comparison",
        "function_address",
        "records",
    }
    if set(audit) != expected_envelope:
        raise OracleError(f"{context}: pair-line audit envelope is not canonical")
    if audit.get("schema") != PAIR_LINE_AUDIT_SCHEMA:
        raise OracleError(f"{context}: unsupported pair-line audit schema")
    if audit.get("validation_scope") != "structural-candidate":
        raise OracleError(f"{context}: pair-line audit is not candidate-structural")
    if audit.get("combined_oracle_comparison") is not False:
        raise OracleError(f"{context}: pair-line audit claims an external comparison")
    audit_function_address = audit.get("function_address")
    if audit_function_address != function_address:
        raise OracleError(f"{context}: pair-line audit function address does not match record")
    if not isinstance(audit_function_address, str) or not re.fullmatch(
        r"0x[0-9a-f]+", audit_function_address
    ):
        raise OracleError(f"{context}: pair-line audit function address is not canonical")
    numeric_function_address = int(audit_function_address, 16)
    if (
        audit_function_address != hex(numeric_function_address)
        or numeric_function_address > 0xFFFF_FFFF_FFFF_FFFF
    ):
        raise OracleError(f"{context}: pair-line audit function address is not canonical")
    records = audit.get("records")
    if not isinstance(records, list):
        raise OracleError(f"{context}: pair-line audit records must be an array")

    expected: list[tuple[int, str, int]] = []
    occurrences: Counter[str] = Counter()
    for ordinal, text in enumerate(pseudocode.splitlines(), start=1):
        comment = text.partition("//")[2]
        annotations = {annotation.strip() for annotation in comment.split(";")}
        if not ({"saves register pair", "restores register pair"} & annotations):
            continue
        occurrence = occurrences[text]
        occurrences[text] += 1
        expected.append((
            ordinal,
            hashlib.sha256(text.encode("utf-8")).hexdigest(),
            occurrence,
        ))
    if len(records) != len(expected):
        raise OracleError(f"{context}: pair-line audit coverage is incomplete")

    expected_record_fields = {
        "line_ordinal",
        "line_text_sha256",
        "text_occurrence",
        "instruction_address",
    }
    instruction_addresses: set[str] = set()
    for index, (raw, expected_values) in enumerate(zip(records, expected)):
        record_context = f"{context}.records[{index}]"
        if not isinstance(raw, dict) or set(raw) != expected_record_fields:
            raise OracleError(f"{record_context}: pair-line record is not canonical")
        ordinal, digest, occurrence = expected_values
        if type(raw.get("line_ordinal")) is not int or raw.get("line_ordinal") != ordinal:
            raise OracleError(f"{record_context}: line ordinal does not match pseudocode")
        if raw.get("line_text_sha256") != digest:
            raise OracleError(f"{record_context}: line digest does not match pseudocode")
        if type(raw.get("text_occurrence")) is not int or raw.get("text_occurrence") != occurrence:
            raise OracleError(f"{record_context}: text occurrence is not canonical")
        instruction_address = raw.get("instruction_address")
        if not isinstance(instruction_address, str) or not re.fullmatch(
            r"0x[0-9a-f]+", instruction_address
        ):
            raise OracleError(f"{record_context}: instruction address is not canonical hex")
        numeric_address = int(instruction_address, 16)
        if instruction_address != hex(numeric_address) or numeric_address > 0xFFFF_FFFF_FFFF_FFFF:
            raise OracleError(f"{record_context}: instruction address is not canonical")
        if instruction_address in instruction_addresses:
            raise OracleError(f"{record_context}: instruction address is duplicated")
        instruction_addresses.add(instruction_address)
    return audit


def load_sweep(path: Path, expected_sha256: str | None = None) -> dict[int, SweepRecord]:
    try:
        artifact_bytes = path.read_bytes()
        if expected_sha256 is not None:
            actual_digest = hashlib.sha256(artifact_bytes).hexdigest()
            if actual_digest != expected_sha256:
                raise OracleError(
                    f"{path}: output digest does not match producer manifest; "
                    "artifact is stale or modified"
                )
        payload = json.loads(artifact_bytes)
    except FileNotFoundError as error:
        raise OracleError(f"missing sweep JSON: {path}") from error
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise OracleError(f"cannot read sweep JSON {path}: {error}") from error

    return validate_sweep_payload(payload, str(path))


def validate_sweep_payload(payload: object, source: str) -> dict[int, SweepRecord]:
    """Validate an enriched sweep payload and key it by numeric function address."""

    if not isinstance(payload, list) or not payload:
        raise OracleError(f"{source}: expected a nonempty per-function JSON list")

    records: dict[int, SweepRecord] = {}
    for index, raw in enumerate(payload):
        context = f"{source}[{index}]"
        if not isinstance(raw, dict):
            raise OracleError(f"{context}: function record must be an object")
        missing = [field_name for field_name in REQUIRED_RECORD_FIELDS if field_name not in raw]
        if missing:
            raise OracleError(
                f"{context}: missing enriched field(s) {', '.join(missing)}; re-run sweep.py"
            )
        address = parse_hex_address(raw["address"], context)
        if address in records:
            raise OracleError(f"{context}: duplicate function address {raw['address']}")
        if not isinstance(raw["pseudocode"], str):
            raise OracleError(f"{context}: pseudocode must be a string")
        if not isinstance(raw["fallback"], str):
            raise OracleError(f"{context}: fallback must be a string")
        if not raw["fallback"]:
            raise OracleError(
                f"{context}: fallback is empty; diagnostics were not mapped for this function"
            )
        if not isinstance(raw["fatal"], str) or not raw["fatal"]:
            raise OracleError(f"{context}: fatal must be a nonempty string")
        for count_name in ("gotos", "unknowns"):
            count = raw[count_name]
            if isinstance(count, bool) or not isinstance(count, int) or count < 0:
                raise OracleError(f"{context}: {count_name} must be a nonnegative integer")
        parameter_audit = raw.get("parameter_binding_audit")
        if parameter_audit is not None:
            try:
                validate_candidate_audit(parameter_audit, f"{context}.parameter_binding_audit")
            except ParameterAuditError as error:
                raise OracleError(str(error)) from error
        pair_line_audit = raw.get("pair_line_instruction_audit")
        validate_pair_line_instruction_audit(
            pair_line_audit,
            raw["pseudocode"],
            raw["address"],
            f"{context}.pair_line_instruction_audit",
        )
        records[address] = SweepRecord(
            address_text=raw["address"],
            pseudocode=raw["pseudocode"],
            fallback=raw["fallback"],
            fatal=raw["fatal"],
            gotos=raw["gotos"],
            unknowns=raw["unknowns"],
            parameter_binding_audit=parameter_audit,
            pair_line_instruction_audit=pair_line_audit,
        )

    return records


def validate_producer_payload(payload: object, source: str) -> ProducerMetadata:
    if not isinstance(payload, dict):
        raise OracleError(f"{source}: producer metadata must be an object")
    if payload.get("schema") != PRODUCER_SCHEMA:
        raise OracleError(
            f"{source}: unsupported producer schema {payload.get('schema')!r}; re-run sweep.py"
        )
    digest = payload.get("executable_sha256")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise OracleError(f"{source}: executable_sha256 must be 64 lowercase hex digits")
    size = payload.get("executable_size")
    if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
        raise OracleError(f"{source}: executable_size must be a positive integer")
    raw_corpora = payload.get("corpora")
    if not isinstance(raw_corpora, dict) or not raw_corpora:
        raise OracleError(f"{source}: corpora must be a nonempty object")
    corpora: dict[str, CorpusManifest] = {}
    for name, raw_manifest in raw_corpora.items():
        context = f"{source}.corpora[{name!r}]"
        if (
            not isinstance(name, str)
            or not name
            or Path(name).name != name
            or name in {".", ".."}
            or name.startswith("_")
        ):
            raise OracleError(f"{context}: corpus name must be a plain sweep basename")
        if not isinstance(raw_manifest, dict):
            raise OracleError(f"{context}: corpus manifest must be an object")
        input_realpath = raw_manifest.get("input_realpath")
        if not isinstance(input_realpath, str) or not Path(input_realpath).is_absolute():
            raise OracleError(f"{context}: input_realpath must be an absolute path")
        input_sha256 = raw_manifest.get("input_sha256")
        if not isinstance(input_sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", input_sha256
        ):
            raise OracleError(f"{context}: input_sha256 must be 64 lowercase hex digits")
        input_size = raw_manifest.get("input_size")
        if isinstance(input_size, bool) or not isinstance(input_size, int) or input_size <= 0:
            raise OracleError(f"{context}: input_size must be a positive integer")
        record_count = raw_manifest.get("record_count")
        if (
            isinstance(record_count, bool)
            or not isinstance(record_count, int)
            or record_count <= 0
        ):
            raise OracleError(f"{context}: record_count must be a positive integer")
        output_sha256 = raw_manifest.get("output_sha256")
        if not isinstance(output_sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", output_sha256
        ):
            raise OracleError(f"{context}: output_sha256 must be 64 lowercase hex digits")
        corpora[name] = CorpusManifest(
            input_realpath=input_realpath,
            input_sha256=input_sha256,
            input_size=input_size,
            record_count=record_count,
            output_sha256=output_sha256,
        )
    record_schema = payload.get("record_schema")
    sweep_script_sha256 = payload.get("sweep_script_sha256")
    invocation = payload.get("invocation")
    provenance_fields = (record_schema, sweep_script_sha256, invocation)
    if any(field is not None for field in provenance_fields):
        if record_schema != PARAMETER_RECORD_SCHEMA:
            raise OracleError(f"{source}: unsupported record_schema {record_schema!r}")
        if not isinstance(sweep_script_sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", sweep_script_sha256
        ):
            raise OracleError(f"{source}: sweep_script_sha256 must be 64 lowercase hex digits")
        if not isinstance(invocation, dict):
            raise OracleError(f"{source}: invocation must be an object")
        if invocation.get("regiontree_diagnostics") is not True:
            raise OracleError(f"{source}: RegionTree diagnostics provenance is missing")
        if not isinstance(invocation.get("parameter_binding_audit_available"), bool):
            raise OracleError(f"{source}: parameter audit availability must be boolean")
        if invocation.get("pair_line_instruction_audit_available") is not True:
            raise OracleError(f"{source}: pair-line instruction audit provenance is missing")
        corpus_basenames = invocation.get("corpus_basenames")
        if (
            not isinstance(corpus_basenames, list)
            or not all(isinstance(name, str) and name for name in corpus_basenames)
            or len(set(corpus_basenames)) != len(corpus_basenames)
            or set(corpus_basenames) != set(corpora)
        ):
            raise OracleError(f"{source}: invocation corpus set differs from manifest")
    return ProducerMetadata(
        executable_sha256=digest,
        executable_size=size,
        corpora=corpora,
        record_schema=record_schema,
        sweep_script_sha256=sweep_script_sha256,
        invocation=invocation,
    )


def load_producer(directory: Path) -> ProducerMetadata:
    path = directory / PRODUCER_METADATA_NAME
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise OracleError(f"missing producer metadata: {path}; re-run sweep.py") from error
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise OracleError(f"cannot read producer metadata {path}: {error}") from error
    return validate_producer_payload(payload, str(path))


def require_distinct_sweeps(
    baseline_dir: Path,
    candidate_dir: Path,
    baseline_producer: ProducerMetadata,
    candidate_producer: ProducerMetadata,
) -> None:
    if baseline_dir == candidate_dir:
        raise OracleError("baseline and candidate resolve to the same sweep directory")
    if baseline_producer.executable_sha256 == candidate_producer.executable_sha256:
        raise OracleError(
            "baseline and candidate were produced by the same MacScope executable "
            f"(sha256 {baseline_producer.executable_sha256}); rebuild and re-run both sweeps"
        )


def discovered_sweep_names(directory: Path) -> set[str]:
    if not directory.is_dir():
        raise OracleError(f"sweep directory is missing: {directory}")
    return {
        path.stem
        for path in directory.glob("*.json")
        if path.is_file() and not path.name.startswith("_")
    }


def load_manifest_artifacts(
    directory: Path, producer: ProducerMetadata
) -> dict[str, dict[int, SweepRecord]]:
    discovered = discovered_sweep_names(directory)
    manifested = set(producer.corpora)
    if discovered != manifested:
        missing = sorted(manifested - discovered)
        extra = sorted(discovered - manifested)
        details = []
        if missing:
            details.append(f"missing artifact(s): {', '.join(missing)}")
        if extra:
            details.append(f"unmanifested artifact(s): {', '.join(extra)}")
        raise OracleError(f"{directory}: manifest/artifact mismatch; " + "; ".join(details))

    loaded: dict[str, dict[int, SweepRecord]] = {}
    for name in sorted(manifested):
        artifact = directory / f"{name}.json"
        manifest = producer.corpora[name]
        records = load_sweep(artifact, expected_sha256=manifest.output_sha256)
        if len(records) != manifest.record_count:
            raise OracleError(
                f"{artifact}: record count {len(records)} does not match producer manifest "
                f"count {manifest.record_count}"
            )
        loaded[name] = records
    return loaded


def require_same_input_corpora(
    baseline_producer: ProducerMetadata, candidate_producer: ProducerMetadata
) -> None:
    baseline_names = set(baseline_producer.corpora)
    candidate_names = set(candidate_producer.corpora)
    if baseline_names != candidate_names:
        raise OracleError("baseline and candidate producer manifests name different corpora")
    for name in sorted(baseline_names):
        before = baseline_producer.corpora[name]
        after = candidate_producer.corpora[name]
        before_identity = (before.input_realpath, before.input_sha256, before.input_size)
        after_identity = (after.input_realpath, after.input_sha256, after.input_size)
        if before_identity != after_identity:
            raise OracleError(
                f"corpus {name}: baseline and candidate input identities differ"
            )


def require_compatible_provenance(
    baseline_producer: ProducerMetadata, candidate_producer: ProducerMetadata
) -> None:
    before = (
        baseline_producer.record_schema,
        baseline_producer.sweep_script_sha256,
    )
    after = (
        candidate_producer.record_schema,
        candidate_producer.sweep_script_sha256,
    )
    if before == (None, None) and after == (None, None):
        raise OracleError(
            "baseline and candidate manifests lack enriched sweep script/record provenance; "
            "re-run both sweeps with the current sweep.py"
        )
    if before != after or None in before:
        raise OracleError(
            "baseline and candidate were not produced by the identical enriched "
            "sweep script/record schema"
        )
    assert baseline_producer.invocation is not None
    assert candidate_producer.invocation is not None
    before_corpora = baseline_producer.invocation.get("corpus_basenames")
    after_corpora = candidate_producer.invocation.get("corpus_basenames")
    if before_corpora != after_corpora:
        raise OracleError("baseline and candidate sweep invocation corpora differ")
    if candidate_producer.invocation.get("parameter_binding_audit_available") is not True:
        raise OracleError("candidate sweep did not expose parameter-binding-audit")


def require_current_corpus(binary: Path, manifest: CorpusManifest, name: str) -> None:
    try:
        realpath_before = str(binary.expanduser().resolve(strict=True))
        stat_before = binary.stat()
        corpus_bytes = binary.read_bytes()
        realpath_after = str(binary.expanduser().resolve(strict=True))
        stat_after = binary.stat()
    except OSError as error:
        raise OracleError(f"corpus {name}: cannot inspect {binary}: {error}") from error
    before = (
        realpath_before,
        stat_before.st_size,
        stat_before.st_dev,
        stat_before.st_ino,
        stat_before.st_mtime_ns,
    )
    after = (
        realpath_after,
        stat_after.st_size,
        stat_after.st_dev,
        stat_after.st_ino,
        stat_after.st_mtime_ns,
    )
    if before != after:
        raise OracleError(f"corpus {name}: binary changed while being verified")
    digest = hashlib.sha256(corpus_bytes).hexdigest()
    actual = (realpath_after, digest, stat_after.st_size)
    expected = (manifest.input_realpath, manifest.input_sha256, manifest.input_size)
    if actual != expected:
        raise OracleError(
            f"corpus {name}: current binary does not match the swept input manifest"
        )


def parse_call_addresses(disassembly: str) -> list[int]:
    """Return sorted, unique addresses of the six frozen returning-call forms."""
    addresses: set[int] = set()
    for line in disassembly.splitlines():
        fields = line.split("\t")
        if len(fields) < 2:
            continue
        address_text = fields[0].strip()
        mnemonic = fields[1].strip().lower()
        if mnemonic not in RETURNING_CALL_MNEMONICS:
            continue
        if re.fullmatch(r"[0-9a-fA-F]+", address_text):
            addresses.add(int(address_text, 16))
    return sorted(addresses)


def otool_commands(binary: Path) -> list[list[str]]:
    """Prefer the same arm64e slice MacScope selects, then allow a thin-binary fallback."""
    binary_text = str(binary)
    return [
        ["/usr/bin/otool", "-tvV", "-arch", "arm64e", binary_text],
        ["/usr/bin/otool", "-tvV", binary_text],
    ]


def run_otool(binary: Path) -> str:
    if not binary.is_file():
        raise OracleError(f"corpus binary is missing: {binary}")
    failures: list[str] = []
    for command in otool_commands(binary):
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=120, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            failures.append(str(error))
            continue
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout
        diagnostic = (result.stderr or result.stdout).strip().splitlines()
        first_line = diagnostic[0] if diagnostic else "empty disassembly"
        failures.append(f"exit {result.returncode}: {first_line}")
    raise OracleError(f"otool failed for {binary}: {'; '.join(failures)}")


def containing_call_functions(function_starts: Iterable[int], call_addresses: Iterable[int]) -> set[int]:
    """Map each call to the greatest discovered function start not after it."""
    starts = sorted(set(function_starts))
    call_functions: set[int] = set()
    for address in call_addresses:
        index = bisect.bisect_right(starts, address) - 1
        if index >= 0:
            call_functions.add(starts[index])
    return call_functions


def arg_names(pseudocode: str) -> set[str]:
    return set(ARG_NAME.findall(pseudocode))


def preserved_unavailable_markers(pseudocode: str) -> Counter[str]:
    return Counter(match.group(0).lower() for match in PRESERVED_UNAVAILABLE.finditer(pseudocode))


def _parameter_name_normalization(
    before_lines: list[str],
    after_lines: list[str],
    audit: dict[str, object],
) -> tuple[list[str], bool] | None:
    """Normalize an exact audited ABI-only header back to its WS-13 spelling."""

    if audit.get("declaration_mode") != "abi-only":
        return list(after_lines), False
    records = audit.get("records")
    if not isinstance(records, list) or not records:
        return list(after_lines), False
    header_pattern = re.compile(r"^(.*\()(.*)(\) \{)$")
    before_header = header_pattern.fullmatch(before_lines[0])
    after_header = header_pattern.fullmatch(after_lines[0])
    if before_header is None or after_header is None:
        return None
    if (before_header.group(1), before_header.group(3)) != (
        after_header.group(1), after_header.group(3)
    ):
        return None

    baseline_parameters = before_header.group(2)
    candidate_parameters = after_header.group(2)
    if not candidate_parameters.startswith("/* ABI inputs: ") or not candidate_parameters.endswith(" */"):
        return None
    baseline_rows: list[tuple[str, str]] = []
    for declaration in baseline_parameters.split(", "):
        match = re.fullmatch(r"(.+?) (arg[0-9]+)", declaration)
        if match is None:
            return None
        baseline_rows.append((match.group(1), match.group(2)))
    if len(baseline_rows) != len(records):
        return None

    expected_candidate_rows: list[str] = []
    name_pairs: list[tuple[str, str]] = []
    for record, (baseline_type, baseline_name) in zip(records, baseline_rows):
        if not isinstance(record, dict):
            return None
        if record.get("declaration_mode") != "abi-only" or record.get("source_position") is not None:
            return None
        location = record.get("location")
        type_name = record.get("type")
        candidate_name = record.get("name")
        if not all(isinstance(value, str) and value for value in (location, type_name, candidate_name)):
            return None
        if type_name != baseline_type:
            return None
        expected_candidate_rows.append(f"{location}:{type_name} {candidate_name}")
        name_pairs.append((candidate_name, baseline_name))
    if candidate_parameters != "/* ABI inputs: " + ", ".join(expected_candidate_rows) + " */":
        return None

    normalized_lines = list(after_lines)
    normalized_lines[0] = (
        after_header.group(1) + baseline_parameters + after_header.group(3)
    )
    for index, line in enumerate(normalized_lines):
        for candidate_name, baseline_name in sorted(
            name_pairs, key=lambda pair: -len(pair[0])
        ):
            line = re.sub(
                rf"(?<![A-Za-z0-9_]){re.escape(candidate_name)}(?![A-Za-z0-9_])",
                baseline_name,
                line,
            )
        normalized_lines[index] = line
    return normalized_lines, True


def _has_prior_unknown_write(lines: list[str], line_index: int, scalar_view: str) -> bool:
    index_match = re.fullmatch(r"[ds]([0-9]+)", scalar_view)
    if index_match is None:
        return False
    register_index = index_match.group(1)
    unknown_destination = re.compile(
        rf'__unknown\("[^"]+", "(?:[ds]{register_index}(?:,|")|v{register_index}(?:\.|,|"))'
    )
    concrete_definition = re.compile(
        rf"(?:^|\s)(?:[ds]{register_index}|v{register_index})_[0-9]+\s*="
    )
    for line in reversed(lines[:line_index]):
        if unknown_destination.search(line):
            return True
        if concrete_definition.search(line):
            return False
    return False


def _conservative_unavailability_line(
    before_line: str,
    after_line: str,
    all_after_lines: list[str],
    line_index: int,
) -> bool:
    scalar_views = set(re.findall(r"\bunavailable_([ds][0-9]+)\b", after_line))
    if not scalar_views:
        return False
    normalized_before = before_line
    for scalar_view in scalar_views:
        normalized_before = re.sub(
            rf"\b{re.escape(scalar_view)}_[0-9]+\b",
            f"unavailable_{scalar_view}",
            normalized_before,
        )
        if not _has_prior_unknown_write(all_after_lines, line_index, scalar_view):
            return False
    return normalized_before == after_line


def _removed_unproven_trailing_call_inputs(
    before_line: str,
    after_line: str,
    audit: dict[str, object],
) -> bool:
    if not before_line.endswith("); // call") or not after_line.endswith("); // call"):
        return False
    records = audit.get("records")
    if not isinstance(records, list):
        return False
    declared_gprs = {
        record.get("binding")
        for record in records
        if isinstance(record, dict) and isinstance(record.get("binding"), str)
    }
    normalized = before_line
    removed = False
    while True:
        match = re.search(r", ([xw])([0-9]+)_0(?=\); // call$)", normalized)
        if match is None:
            break
        binding = f"gpr:{match.group(2)}"
        if binding in declared_gprs:
            return False
        normalized = normalized[:match.start()] + normalized[match.end():]
        removed = True
    return removed and normalized == after_line


def ws14_contract_only_change(before: SweepRecord, after: SweepRecord) -> bool:
    """Accept only audited ABI naming and conservative definite-write tombstones."""

    audit = after.parameter_binding_audit
    if audit is None:
        return False
    before_lines = before.pseudocode.splitlines()
    after_lines = after.pseudocode.splitlines()
    if not before_lines or len(before_lines) != len(after_lines):
        return False
    normalized_result = _parameter_name_normalization(before_lines, after_lines, audit)
    if normalized_result is None:
        return False
    normalized_lines, parameter_changed = normalized_result
    changed_line_count = 0
    for index, (before_line, after_line) in enumerate(
        zip(before_lines, normalized_lines)
    ):
        if before_line == after_line:
            continue
        changed_line_count += 1
        if not (
            _conservative_unavailability_line(
                before_line, after_line, normalized_lines, index
            )
            or _removed_unproven_trailing_call_inputs(
                before_line, after_line, audit
            )
        ):
            return False
    return parameter_changed or changed_line_count > 0


def evaluate_corpus(
    name: str,
    baseline: dict[int, SweepRecord],
    candidate: dict[int, SweepRecord],
    call_addresses: Iterable[int],
    enforce_ws14_contract: bool = False,
) -> CorpusResult:
    call_address_list = sorted(set(call_addresses))
    call_functions = containing_call_functions(baseline, call_address_list)
    result = CorpusResult(
        name=name,
        functions=len(baseline),
        call_sites=len(call_address_list),
        call_functions=len(call_functions),
    )

    missing = sorted(set(baseline) - set(candidate))
    extra = sorted(set(candidate) - set(baseline))
    for address in missing:
        result.violations.append(("G0", hex(address), "function missing in candidate sweep"))
    for address in extra:
        result.violations.append(("G0", hex(address), "new function in candidate sweep"))

    for address in sorted(set(baseline) & set(candidate)):
        before = baseline[address]
        after = candidate[address]
        if (
            before.fallback,
            before.fatal,
            before.gotos,
            before.unknowns,
        ) != (
            after.fallback,
            after.fatal,
            after.gotos,
            after.unknowns,
        ):
            result.violations.append(
                (
                    "G0",
                    before.address_text,
                    "fallback/fatal/goto/unknown metadata changed",
                )
            )
        changed = before.pseudocode != after.pseudocode
        ws14_only = changed and ws14_contract_only_change(before, after)
        if changed:
            result.changed_functions += 1
        if ws14_only:
            result.parameter_identity_changes += 1
        elif changed and enforce_ws14_contract:
            result.violations.append(
                (
                    "G5",
                    before.address_text,
                    "change is outside audited ABI naming and conservative tombstone deltas",
                )
            )

        if address not in call_functions:
            result.no_call_checked += 1
            if not changed or ws14_only:
                result.no_call_identical += 1
            else:
                result.violations.append(
                    (
                        "G1/G2",
                        before.address_text,
                        "no-call function changed; change is not anchored to a returning call",
                    )
                )
        elif changed:
            result.changed_anchored += 1

        result.arg_sets_checked += 1
        added_args = sorted(arg_names(after.pseudocode) - arg_names(before.pseudocode))
        if added_args:
            result.violations.append(
                (
                    "G3",
                    before.address_text,
                    f"candidate added recovered argument name(s): {', '.join(added_args)}",
                )
            )

        result.marker_functions_checked += 1
        markers = (
            preserved_unavailable_markers(after.pseudocode)
            - preserved_unavailable_markers(before.pseudocode)
        )
        if markers and not ws14_only:
            marker_summary = ", ".join(
                marker if count == 1 else f"{marker} x{count}"
                for marker, count in sorted(markers.items())
            )
            result.violations.append(
                (
                    "G4",
                    before.address_text,
                    f"preserved state became unavailable: {marker_summary}",
                )
            )
    return result


def synthetic_record(
    address: int,
    pseudocode: str,
    parameter_binding_audit: dict[str, object] | None = None,
    pair_line_instruction_audit: dict[str, object] | None = None,
) -> SweepRecord:
    return SweepRecord(
        hex(address), pseudocode, "structured", "none", 0, 0,
        parameter_binding_audit, pair_line_instruction_audit,
    )


def require_self_test(condition: bool, message: object) -> None:
    if not condition:
        raise AssertionError(message)


def run_self_tests() -> None:
    base = {
        0x1000: synthetic_record(0x1000, "uint64_t no_call(uint64_t arg0) { return arg0; }"),
        0x2000: synthetic_record(0x2000, "uint64_t calls(uint64_t arg0) { return arg0; }"),
    }

    identity = evaluate_corpus("fixture", base, dict(base), [0x2004])
    require_self_test(not identity.violations, identity.violations)
    require_self_test(
        identity.no_call_checked == identity.no_call_identical == 1,
        "identity did not check exactly one no-call function",
    )

    changed_call = dict(base)
    changed_call[0x2000] = synthetic_record(0x2000, "uint64_t calls(void) { return 0; }")
    anchored = evaluate_corpus("fixture", base, changed_call, [0x2004])
    require_self_test(not anchored.violations, anchored.violations)
    require_self_test(anchored.changed_anchored == 1, "call-site change was not anchored")

    changed_no_call = dict(base)
    changed_no_call[0x1000] = synthetic_record(0x1000, "uint64_t no_call(void) { return 0; }")
    unanchored = evaluate_corpus("fixture", base, changed_no_call, [0x2004])
    require_self_test(
        any(code == "G1/G2" for code, _, _ in unanchored.violations),
        "unanchored no-call change escaped G1/G2",
    )

    parameter_audit = {
        "schema": "parameter-binding-audit-v1",
        "validation_scope": "structural-candidate",
        "combined_oracle_comparison": False,
        "function": "no_call",
        "address": "0x1000",
        "declaration_mode": "abi-only",
        "dangling_body_uses": [],
        "records": [
            {
                "function": "no_call",
                "declaration_mode": "abi-only",
                "row_ordinal": 0,
                "binding": "gpr:1",
                "source_position": None,
                "location": "x1",
                "evidence": "heuristic_entry_read",
                "name": "in_x1",
                "type": "uint64_t",
                "body_uses": [{"address": "0x1000", "occurrence": 0}],
            }
        ],
    }
    sparse_before = {
        0x1000: synthetic_record(
            0x1000,
            "uint64_t no_call(uint64_t arg1) {\n    return arg1;\n}",
        )
    }
    sparse_after = {
        0x1000: synthetic_record(
            0x1000,
            "uint64_t no_call(/* ABI inputs: x1:uint64_t in_x1 */) {\n"
            "    return in_x1;\n}",
            parameter_audit,
        )
    }
    sparse_result = evaluate_corpus("fixture", sparse_before, sparse_after, [])
    require_self_test(not sparse_result.violations, sparse_result.violations)
    require_self_test(
        sparse_result.parameter_identity_changes == 1,
        "audited sparse parameter correction was not recognized",
    )
    sparse_body_drift = dict(sparse_after)
    sparse_body_drift[0x1000] = synthetic_record(
        0x1000,
        "uint64_t no_call(/* ABI inputs: x1:uint64_t in_x1 */) {\n"
        "    return in_x1 + 1;\n}",
        parameter_audit,
    )
    sparse_drift_result = evaluate_corpus(
        "fixture", sparse_before, sparse_body_drift, [], enforce_ws14_contract=True
    )
    require_self_test(
        any(code == "G1/G2" for code, _, _ in sparse_drift_result.violations),
        "unrelated body drift hid behind a parameter audit",
    )

    empty_audit = {
        **parameter_audit,
        "declaration_mode": "abi-only",
        "records": [],
    }
    unavailable_before = {
        0x1000: synthetic_record(
            0x1000,
            "void no_call(void) {\n"
            "    __unknown(\"fsub\", \"d8, d0, d8\");\n"
            "    local_0 = d8_0;\n}",
        )
    }
    unavailable_after = {
        0x1000: synthetic_record(
            0x1000,
            "void no_call(void) {\n"
            "    __unknown(\"fsub\", \"d8, d0, d8\");\n"
            "    local_0 = unavailable_d8;\n}",
            empty_audit,
        )
    }
    unavailable_result = evaluate_corpus(
        "fixture", unavailable_before, unavailable_after, [],
        enforce_ws14_contract=True,
    )
    require_self_test(not unavailable_result.violations, unavailable_result.violations)
    resurrected_before = {
        0x1000: synthetic_record(
            0x1000,
            "void no_call(void) {\n"
            "    __unknown(\"fsub\", \"d8, d0, d8\");\n"
            "    d8_1 = 0x1;\n"
            "    local_0 = d8_1;\n}",
        )
    }
    resurrected_after = {
        0x1000: synthetic_record(
            0x1000,
            "void no_call(void) {\n"
            "    __unknown(\"fsub\", \"d8, d0, d8\");\n"
            "    d8_1 = 0x1;\n"
            "    local_0 = unavailable_d8;\n}",
            empty_audit,
        )
    }
    resurrected_result = evaluate_corpus(
        "fixture", resurrected_before, resurrected_after, [],
        enforce_ws14_contract=True,
    )
    require_self_test(
        any(code == "G5" for code, _, _ in resurrected_result.violations),
        "an earlier unknown write authorized unavailability after a concrete redefinition",
    )
    unanchored_unavailable = dict(unavailable_after)
    unanchored_unavailable[0x1000] = synthetic_record(
        0x1000,
        "void no_call(void) {\n"
        "    local_0 = unavailable_d8;\n"
        "    return;\n}",
        empty_audit,
    )
    unanchored_unavailable_result = evaluate_corpus(
        "fixture", unavailable_before, unanchored_unavailable, [],
        enforce_ws14_contract=True,
    )
    require_self_test(
        any(code == "G5" for code, _, _ in unanchored_unavailable_result.violations),
        "unanchored preserved-register tombstone escaped WS-14 normalization",
    )

    call_before = {
        0x1000: synthetic_record(
            0x1000,
            "uint64_t calls(uint64_t arg0) {\n"
            "    x0_1 = callee(arg0, x4_0); // call\n}",
        )
    }
    call_after = {
        0x1000: synthetic_record(
            0x1000,
            "uint64_t calls(/* ABI inputs: x0:uint64_t in_x0 */) {\n"
            "    x0_1 = callee(in_x0); // call\n}",
            {
                **parameter_audit,
                "function": "calls",
                "records": [
                    {
                        **parameter_audit["records"][0],
                        "function": "calls",
                        "binding": "gpr:0",
                        "location": "x0",
                        "name": "in_x0",
                    }
                ],
            },
        )
    }
    call_result = evaluate_corpus(
        "fixture", call_before, call_after, [0x1004],
        enforce_ws14_contract=True,
    )
    require_self_test(not call_result.violations, call_result.violations)
    nontrailing_removal = dict(call_after)
    nontrailing_removal[0x1000] = synthetic_record(
        0x1000,
        "uint64_t calls(/* ABI inputs: x0:uint64_t in_x0 */) {\n"
        "    x0_1 = callee(in_x0, x5_1); // call\n}",
        call_after[0x1000].parameter_binding_audit,
    )
    nontrailing_result = evaluate_corpus(
        "fixture", call_before, nontrailing_removal, [0x1004],
        enforce_ws14_contract=True,
    )
    require_self_test(
        any(code == "G5" for code, _, _ in nontrailing_result.violations),
        "nontrailing call-operand change escaped WS-14 normalization",
    )

    added_arg = dict(base)
    added_arg[0x2000] = synthetic_record(
        0x2000, "uint64_t calls(uint64_t arg0, uint64_t arg1) { return arg1; }"
    )
    arg_result = evaluate_corpus("fixture", base, added_arg, [0x2004])
    require_self_test(
        any(code == "G3" for code, _, _ in arg_result.violations),
        "new recovered argument escaped G3",
    )

    bad_marker = dict(base)
    bad_marker[0x2000] = synthetic_record(0x2000, "return unavailable_x19 + unavailable_d8;")
    marker_result = evaluate_corpus("fixture", base, bad_marker, [0x2004])
    require_self_test(
        any(code == "G4" for code, _, _ in marker_result.violations),
        "preserved unavailable marker escaped G4",
    )

    existing_marker = dict(base)
    existing_marker[0x2000] = synthetic_record(0x2000, "return unavailable_x19;")
    unchanged_marker_result = evaluate_corpus(
        "fixture", existing_marker, existing_marker, [0x2004]
    )
    require_self_test(
        not any(code == "G4" for code, _, _ in unchanged_marker_result.violations),
        "pre-existing preserved unavailable marker was incorrectly treated as new",
    )

    repeated_marker = dict(existing_marker)
    repeated_marker[0x2000] = synthetic_record(
        0x2000, "return unavailable_x19 + unavailable_x19;"
    )
    repeated_marker_result = evaluate_corpus(
        "fixture", existing_marker, repeated_marker, [0x2004]
    )
    require_self_test(
        any(code == "G4" for code, _, _ in repeated_marker_result.violations),
        "increased preserved-marker multiplicity escaped G4",
    )

    volatile_x18 = dict(base)
    volatile_x18[0x2000] = synthetic_record(0x2000, "return unavailable_x18;")
    x18_result = evaluate_corpus("fixture", base, volatile_x18, [0x2004])
    require_self_test(
        not any(code == "G4" for code, _, _ in x18_result.violations),
        "volatile x18 was incorrectly classified as preserved by G4",
    )

    disassembly = "\n".join(
        [
            "0000000000002004\tbl\t_callee",
            "0000000000002008\tblr\tx8",
            "000000000000200c\tblraa\tx8, x17",
            "0000000000002010\tblrab\tx8, x17",
            "0000000000002014\tblraaz\tx8",
            "0000000000002018\tblrabz\tx8",
            "000000000000201c\tb.lo\t0x2024",
        ]
    )
    require_self_test(
        parse_call_addresses(disassembly)
        == [0x2004, 0x2008, 0x200C, 0x2010, 0x2014, 0x2018],
        "returning-call parser did not recognize exactly the six frozen forms",
    )
    require_self_test(
        otool_commands(Path("/tmp/fixture"))
        == [
            ["/usr/bin/otool", "-tvV", "-arch", "arm64e", "/tmp/fixture"],
            ["/usr/bin/otool", "-tvV", "/tmp/fixture"],
        ],
        "otool command order did not prefer arm64e",
    )

    try:
        parse_hex_address("2000", "self-test")
    except OracleError:
        pass
    else:
        raise AssertionError("schema guard accepted an address without 0x prefix")

    valid_payload = [
        {
            "address": "0x3000",
            "pseudocode": "void valid(void) {}",
            "fallback": "structured",
            "fatal": "none",
            "gotos": 0,
            "unknowns": 0,
            "pair_line_instruction_audit": {
                "schema": PAIR_LINE_AUDIT_SCHEMA,
                "validation_scope": "structural-candidate",
                "combined_oracle_comparison": False,
                "function_address": "0x3000",
                "records": [],
            },
        }
    ]
    require_self_test(
        set(validate_sweep_payload(valid_payload, "self-test")) == {0x3000},
        "valid enriched sweep payload was not accepted",
    )
    for invalid_payload in (
        [{key: value for key, value in valid_payload[0].items() if key != "unknowns"}],
        [{key: value for key, value in valid_payload[0].items()
          if key != "pair_line_instruction_audit"}],
        [{**valid_payload[0], "fallback": ""}],
    ):
        try:
            validate_sweep_payload(invalid_payload, "self-test")
        except OracleError:
            pass
        else:
            raise AssertionError("schema/stale-diagnostic guard accepted invalid sweep data")

    pair_text = "    local_0, local_4 = w8_0, w9_0; // saves register pair"
    pair_audit = {
        "schema": PAIR_LINE_AUDIT_SCHEMA,
        "validation_scope": "structural-candidate",
        "combined_oracle_comparison": False,
        "function_address": "0x3000",
        "records": [{
            "line_ordinal": 1,
            "line_text_sha256": hashlib.sha256(pair_text.encode("utf-8")).hexdigest(),
            "text_occurrence": 0,
            "instruction_address": "0x3010",
        }],
    }
    validate_pair_line_instruction_audit(
        pair_audit, pair_text, "0x3000", "self-test.pair-line-audit"
    )
    malformed_pair_audits = []
    for field, value in (
        ("line_ordinal", True),
        ("line_text_sha256", "0" * 64),
        ("text_occurrence", True),
        ("instruction_address", "0x03010"),
    ):
        malformed = json.loads(json.dumps(pair_audit))
        malformed["records"][0][field] = value
        malformed_pair_audits.append(malformed)
    duplicate = json.loads(json.dumps(pair_audit))
    duplicate["records"].append(dict(duplicate["records"][0]))
    malformed_pair_audits.append(duplicate)
    for malformed in malformed_pair_audits:
        try:
            validate_pair_line_instruction_audit(
                malformed, pair_text, "0x3000", "self-test.invalid-pair-line-audit"
            )
        except OracleError:
            pass
        else:
            raise AssertionError("malformed pair-line audit escaped validation")

    corpus_payload = {
        "input_realpath": "/tmp/fixture-input",
        "input_sha256": "c" * 64,
        "input_size": 789,
        "record_count": 1,
        "output_sha256": "d" * 64,
    }
    producer_payload = {
        "schema": PRODUCER_SCHEMA,
        "executable_sha256": "a" * 64,
        "executable_size": 123,
        "corpora": {"fixture": corpus_payload},
    }
    producer_a = validate_producer_payload(producer_payload, "self-test")
    producer_b = validate_producer_payload(
        {
            **producer_payload,
            "executable_sha256": "b" * 64,
            "executable_size": 456,
        },
        "self-test",
    )
    for invalid_producer in (
        {
            **producer_payload,
            "schema": "old-schema",
        },
        {
            **producer_payload,
            "executable_sha256": "not-a-digest",
        },
        {
            **producer_payload,
            "executable_size": 0,
        },
        {
            **producer_payload,
            "corpora": {},
        },
        {
            **producer_payload,
            "corpora": {"../fixture": corpus_payload},
        },
    ):
        try:
            validate_producer_payload(invalid_producer, "self-test")
        except OracleError:
            pass
        else:
            raise AssertionError("producer schema guard accepted invalid metadata")
    try:
        require_compatible_provenance(producer_a, producer_b)
    except OracleError:
        pass
    else:
        raise AssertionError("legacy manifests escaped enriched provenance validation")
    require_distinct_sweeps(Path("/tmp/base"), Path("/tmp/candidate"), producer_a, producer_b)
    for baseline_dir, candidate_dir, candidate_producer in (
        (Path("/tmp/base"), Path("/tmp/base"), producer_b),
        (Path("/tmp/base"), Path("/tmp/candidate"), producer_a),
    ):
        try:
            require_distinct_sweeps(
                baseline_dir, candidate_dir, producer_a, candidate_producer
            )
        except OracleError:
            pass
        else:
            raise AssertionError("same-directory/producer guard accepted stale differential inputs")

    enriched_producer_payload = {
        **producer_payload,
        "record_schema": PARAMETER_RECORD_SCHEMA,
        "sweep_script_sha256": "1" * 64,
        "invocation": {
            "corpus_basenames": ["fixture"],
            "regiontree_diagnostics": True,
            "parameter_binding_audit_available": False,
            "pair_line_instruction_audit_available": True,
        },
    }
    enriched_baseline = validate_producer_payload(
        enriched_producer_payload, "self-test"
    )
    enriched_candidate = validate_producer_payload(
        {
            **enriched_producer_payload,
            "executable_sha256": "b" * 64,
            "invocation": {
                **enriched_producer_payload["invocation"],
                "parameter_binding_audit_available": True,
            },
        },
        "self-test",
    )
    require_compatible_provenance(enriched_baseline, enriched_candidate)
    incompatible_candidate = ProducerMetadata(
        executable_sha256="b" * 64,
        executable_size=456,
        corpora=enriched_candidate.corpora,
        record_schema=PARAMETER_RECORD_SCHEMA,
        sweep_script_sha256="2" * 64,
        invocation=enriched_candidate.invocation,
    )
    try:
        require_compatible_provenance(enriched_baseline, incompatible_candidate)
    except OracleError:
        pass
    else:
        raise AssertionError("mismatched sweep provenance escaped validation")

    artifact_bytes = json.dumps(valid_payload, separators=(",", ":")).encode("utf-8")
    artifact_digest = hashlib.sha256(artifact_bytes).hexdigest()
    artifact_manifest = CorpusManifest(
        input_realpath="/tmp/fixture-input",
        input_sha256="c" * 64,
        input_size=789,
        record_count=1,
        output_sha256=artifact_digest,
    )
    artifact_producer = ProducerMetadata(
        executable_sha256="a" * 64,
        executable_size=123,
        corpora={"fixture": artifact_manifest},
    )
    with tempfile.TemporaryDirectory() as raw_directory:
        directory = Path(raw_directory)
        artifact = directory / "fixture.json"
        artifact.write_bytes(artifact_bytes)
        loaded = load_manifest_artifacts(directory, artifact_producer)
        require_self_test(
            len(loaded["fixture"]) == 1,
            "valid manifested artifact did not load",
        )

        artifact.write_bytes(artifact_bytes + b"\n")
        try:
            load_manifest_artifacts(directory, artifact_producer)
        except OracleError:
            pass
        else:
            raise AssertionError("modified artifact escaped manifest digest validation")

        artifact.write_bytes(artifact_bytes)
        wrong_count_producer = ProducerMetadata(
            executable_sha256="a" * 64,
            executable_size=123,
            corpora={
                "fixture": CorpusManifest(
                    input_realpath=artifact_manifest.input_realpath,
                    input_sha256=artifact_manifest.input_sha256,
                    input_size=artifact_manifest.input_size,
                    record_count=2,
                    output_sha256=artifact_manifest.output_sha256,
                )
            },
        )
        try:
            load_manifest_artifacts(directory, wrong_count_producer)
        except OracleError:
            pass
        else:
            raise AssertionError("stale artifact count escaped manifest validation")

        (directory / "extra.json").write_text("[]", encoding="utf-8")
        try:
            load_manifest_artifacts(directory, artifact_producer)
        except OracleError:
            pass
        else:
            raise AssertionError("unmanifested artifact escaped exact-set validation")

    mismatched_corpus_producer = ProducerMetadata(
        executable_sha256="b" * 64,
        executable_size=456,
        corpora={
            "fixture": CorpusManifest(
                input_realpath="/tmp/different-fixture-input",
                input_sha256="e" * 64,
                input_size=789,
                record_count=1,
                output_sha256="f" * 64,
            )
        },
    )
    try:
        require_same_input_corpora(artifact_producer, mismatched_corpus_producer)
    except OracleError:
        pass
    else:
        raise AssertionError("baseline/candidate corpus mismatch escaped identity validation")

    differently_named_producer = ProducerMetadata(
        executable_sha256="b" * 64,
        executable_size=456,
        corpora={"other": artifact_manifest},
    )
    try:
        require_same_input_corpora(artifact_producer, differently_named_producer)
    except OracleError:
        pass
    else:
        raise AssertionError("baseline/candidate corpus-set mismatch escaped validation")


def binary_override(value: str) -> tuple[str, Path]:
    name, separator, raw_path = value.partition("=")
    if not separator or not name or not raw_path:
        raise argparse.ArgumentTypeError("expected NAME=PATH")
    if Path(name).name != name or name.startswith("_"):
        raise argparse.ArgumentTypeError("NAME must be a plain sweep basename")
    return name, Path(raw_path).expanduser().resolve()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline_dir", nargs="?", type=Path, help="enriched baseline sweep directory")
    parser.add_argument("candidate_dir", nargs="?", type=Path, help="enriched candidate sweep directory")
    parser.add_argument(
        "--binary",
        action="append",
        default=[],
        metavar="NAME=PATH",
        type=binary_override,
        help="override/add the binary for a sweep JSON basename (repeatable)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run deterministic in-memory identity and negative-control tests, then exit",
    )
    return parser


def run_oracle(args: argparse.Namespace) -> int:
    run_self_tests()
    print(
        "self-test: PASS (identity, multiplicity, all gate negative controls, "
        "call parser, schema/producer/artifact guards)"
    )
    if args.self_test:
        return 0
    if args.baseline_dir is None or args.candidate_dir is None:
        raise OracleError("BASELINE_DIR and CANDIDATE_DIR are required unless --self-test is used")

    baseline_dir = args.baseline_dir.resolve()
    candidate_dir = args.candidate_dir.resolve()
    baseline_producer = load_producer(baseline_dir)
    candidate_producer = load_producer(candidate_dir)
    require_distinct_sweeps(
        baseline_dir, candidate_dir, baseline_producer, candidate_producer
    )
    require_same_input_corpora(baseline_producer, candidate_producer)
    require_compatible_provenance(baseline_producer, candidate_producer)
    baseline_sweeps = load_manifest_artifacts(baseline_dir, baseline_producer)
    candidate_sweeps = load_manifest_artifacts(candidate_dir, candidate_producer)
    enforce_ws14_contract = bool(
        candidate_producer.invocation
        and candidate_producer.invocation.get("parameter_binding_audit_available") is True
    )
    sweep_names = sorted(baseline_sweeps)
    binaries = dict(KNOWN_BINARIES)
    for name, path in args.binary:
        binaries[name] = path

    unknown_names = [name for name in sweep_names if name not in binaries]
    if unknown_names:
        hints = " ".join(f"--binary {name}=/path/to/{name}" for name in unknown_names)
        raise OracleError(f"no corpus binary mapping for {', '.join(unknown_names)}; add {hints}")

    results: list[CorpusResult] = []
    for name in sweep_names:
        manifest = baseline_producer.corpora[name]
        require_current_corpus(binaries[name], manifest, name)
        baseline = baseline_sweeps[name]
        candidate = candidate_sweeps[name]
        disassembly = run_otool(binaries[name])
        require_current_corpus(binaries[name], manifest, name)
        call_addresses = parse_call_addresses(disassembly)
        results.append(
            evaluate_corpus(
                name,
                baseline,
                candidate,
                call_addresses,
                enforce_ws14_contract=enforce_ws14_contract,
            )
        )

    for result in results:
        print(
            f"[{result.name}] functions={result.functions} calls={result.call_sites} "
            f"call_functions={result.call_functions} changed={result.changed_functions}"
        )
        print(
            f"  G1 no-call identity: {result.no_call_identical}/{result.no_call_checked}"
        )
        print(
            f"  G2 changed-function call anchoring: "
            f"{result.changed_anchored}/{result.changed_functions}"
        )
        print(
            f"  G2b audited WS-14 contract-only changes: "
            f"{result.parameter_identity_changes}"
        )
        print(f"  G3 arg-name subset checks: {result.arg_sets_checked}")
        print(f"  G4 preserved-marker checks: {result.marker_functions_checked}")

    violations = [
        (result.name, code, address, message)
        for result in results
        for code, address, message in result.violations
    ]
    print(f"violations: {len(violations)}")
    for name, code, address, message in violations:
        print(f"  VIOLATION [{code}] {name} {address}: {message}")
    return 0 if not violations else 2


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return run_oracle(args)
    except OracleError as error:
        print(f"FATAL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
