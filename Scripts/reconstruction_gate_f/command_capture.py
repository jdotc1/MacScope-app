"""Bounded capture transport, NOT execution or receipt authentication.

Bindings supplied to ``compare_bindings`` must come from independently admitted,
recompiled context. Matching caller assertions to each other grants no authority.
This module neither launches processes nor makes any durability claim.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import re
from dataclasses import dataclass

from .canonical_json import canonical_bytes, canonical_sha256, decode_canonical_bytes, to_primitive
from .command_compiler import CommandRecord
from .runtime_resolution import resolve_command_record
from .command_catalog import CampaignProfile

MAX_ENCODED_BYTES = 12 * 1024 * 1024
MAX_DECODED_BYTES = 8 * 1024 * 1024
MAX_FRAME_BYTES = 64 * 1024
MAX_FRAMES = 4096
MAX_TEXT_BYTES = 4096
INTENT_FIELDS = frozenset("capture_id run_id nonce candidate_identity_sha256 command_plan_sha256 command_record_sha256 command_id scenario_id producer_source_commit producer_source_tree argv working_directory environment environment_policy_id effective_environment prerequisite_receipts started_at_unix_ms".split())
TERMINAL_FIELDS = frozenset("intent_sha256 frames_sha256 ended_at_unix_ms termination_kind exit_code signal stdout_length stdout_sha256 stderr_length stderr_sha256".split())


class CaptureError(ValueError):
    pass


@dataclass(frozen=True)
class CaptureEnvelope:
    """Immutable canonical bytes that have passed structural checks only."""

    payload: bytes

    def __post_init__(self):
        _validate(self.payload)

    def to_mapping(self) -> dict:
        return decode_canonical_bytes(self.payload)


def _closed(value, fields):
    if type(value) is not dict or set(value) != fields:
        raise CaptureError("unexpected or missing object fields")


def _text(value):
    if type(value) is not str or not value or len(value.encode("utf-8")) > MAX_TEXT_BYTES or "\0" in value:
        raise CaptureError("invalid bounded text")


def _integer(value, maximum=2**63 - 1):
    if type(value) is not int or not 0 <= value <= maximum:
        raise CaptureError("invalid bounded integer")


def _hash(value, length=64):
    if type(value) is not str or re.fullmatch("[0-9a-f]{%d}" % length, value) is None:
        raise CaptureError("invalid digest")


def _pairs(value, *, digests=False):
    if type(value) is not list or len(value) > 256:
        raise CaptureError("invalid pairs")
    keys = []
    for pair in value:
        if type(pair) is not list or len(pair) != 2:
            raise CaptureError("invalid pair")
        _text(pair[0])
        if not digests and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", pair[0]) is None:
            raise CaptureError("invalid environment key")
        if digests:
            _hash(pair[1])
        elif type(pair[1]) is not str or len(pair[1].encode("utf-8")) > MAX_TEXT_BYTES or "\0" in pair[1]:
            raise CaptureError("invalid environment value")
        keys.append(pair[0])
    if keys != sorted(set(keys)):
        raise CaptureError("pairs must have sorted unique keys")


def _intent(value):
    _closed(value, INTENT_FIELDS)
    for key in INTENT_FIELDS - {"argv", "environment", "effective_environment", "prerequisite_receipts", "started_at_unix_ms"}:
        _text(value[key])
    for key in ("candidate_identity_sha256", "command_plan_sha256", "command_record_sha256"):
        _hash(value[key])
    for key in ("producer_source_commit", "producer_source_tree"):
        _hash(value[key], 40)
    _integer(value["started_at_unix_ms"])
    if type(value["argv"]) is not list or not 1 <= len(value["argv"]) <= 1024:
        raise CaptureError("invalid argv")
    for arg in value["argv"]:
        # Empty arguments are legitimate argv entries.
        if type(arg) is not str or "\0" in arg or len(arg.encode("utf-8")) > MAX_TEXT_BYTES:
            raise CaptureError("invalid argument")
    for key in ("environment", "effective_environment"):
        _pairs(value[key])
    declared = dict(value["environment"])
    effective = dict(value["effective_environment"])
    allowed = {"HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "LC_ALL", "DEVELOPER_DIR"} | set(declared)
    if not set(effective) <= allowed or any(effective.get(key) != val for key, val in declared.items()):
        raise CaptureError("effective environment violates declared policy")
    _pairs(value["prerequisite_receipts"], digests=True)
    if value["environment_policy_id"] != "gatef-host-environment-v1":
        raise CaptureError("unsupported environment policy")


def _process_observation(value, termination_kind):
    """Validate recorded shape, never authenticate a PID or its lifetime."""
    if type(value) is not dict:
        raise CaptureError("invalid process observation")
    if value.get("state") == "not-launched":
        _closed(value, {"state"})
        if termination_kind != "launch-failed":
            raise CaptureError("missing launched process observation")
        return
    _closed(value, {"state", "pid", "spawn_observed_monotonic_ns", "os_start_time"})
    if value["state"] != "launched" or termination_kind == "launch-failed":
        raise CaptureError("inconsistent process observation")
    for key, maximum in (("pid", 2**31 - 1), ("spawn_observed_monotonic_ns", 2**63 - 1)):
        _integer(value[key], maximum)
        if value[key] == 0:
            raise CaptureError("process observation must be positive")
    start = value["os_start_time"]
    if type(start) is not dict:
        raise CaptureError("invalid OS start-time observation")
    if start.get("state") == "available":
        _closed(start, {"state", "unix_time_ns", "source"})
        _integer(start["unix_time_ns"])
        if start["unix_time_ns"] == 0:
            raise CaptureError("OS start time must be positive")
        _text(start["source"])
    elif start.get("state") == "unavailable":
        _closed(start, {"state", "reason"})
        _text(start["reason"])
    else:
        raise CaptureError("unknown OS start-time observation state")


def _runtime_resolution(value, argv):
    _closed(value, {"schema_version", "bindings", "resolved_command_record_sha256"})
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise CaptureError("unsupported runtime resolution schema")
    _hash(value["resolved_command_record_sha256"])
    bindings = value["bindings"]
    if type(bindings) is not list or len(bindings) > len(argv):
        raise CaptureError("invalid runtime bindings")
    last_index = -1
    for binding in bindings:
        _closed(binding, {"argv_index", "kind", "value"})
        _integer(binding["argv_index"], len(argv) - 1)
        index = binding["argv_index"]
        if index <= last_index or binding["kind"] != "prerequisite-receipt-set-sha256-v1":
            raise CaptureError("runtime binding kind/order mismatch")
        _hash(binding["value"])
        if argv[index] != binding["value"]:
            raise CaptureError("runtime binding differs from captured argv")
        last_index = index
    if "@gatef-runtime:prerequisite-receipt-set-sha256-v1@" in argv:
        raise CaptureError("unresolved runtime argv cannot be captured as execution")


def _validate_transport(frames, process_observation, terminal, *, started_at_unix_ms):
    """Validate bounded observed transport independently of any intent schema."""
    if type(frames) is not list or len(frames) > MAX_FRAMES:
        raise CaptureError("frame count limit/type")
    hashes = {name: hashlib.sha256() for name in ("stdout", "stderr")}
    lengths = dict.fromkeys(hashes, 0)
    streams = {name: bytearray() for name in hashes}
    for index, frame in enumerate(frames):
        _closed(frame, {"sequence", "stream", "data_base64", "raw_length", "raw_sha256"})
        _integer(frame["sequence"])
        if frame["sequence"] != index or frame["stream"] not in hashes:
            raise CaptureError("frame order/stream")
        _integer(frame["raw_length"], MAX_FRAME_BYTES)
        _hash(frame["raw_sha256"])
        encoded = frame["data_base64"]
        if type(encoded) is not str or len(encoded) > 4 * ((MAX_FRAME_BYTES + 2) // 3):
            raise CaptureError("encoded frame limit/type")
        raw = base64.b64decode(encoded, validate=True)
        if base64.b64encode(raw).decode("ascii") != encoded:
            raise CaptureError("noncanonical base64")
        if len(raw) != frame["raw_length"] or hashlib.sha256(raw).hexdigest() != frame["raw_sha256"]:
            raise CaptureError("frame length/digest mismatch")
        lengths[frame["stream"]] += len(raw)
        if sum(lengths.values()) > MAX_DECODED_BYTES:
            raise CaptureError("decoded output limit")
        hashes[frame["stream"]].update(raw)
        streams[frame["stream"]].extend(raw)
    _closed(terminal, TERMINAL_FIELDS - {"intent_sha256"})
    if terminal["frames_sha256"] != canonical_sha256(frames):
        raise CaptureError("terminal commitment mismatch")
    _integer(terminal["ended_at_unix_ms"])
    if terminal["ended_at_unix_ms"] < started_at_unix_ms:
        raise CaptureError("reversed interval")
    kind = terminal["termination_kind"]
    if kind not in ("exited", "signaled", "timed-out", "cancelled", "output-limit", "launch-failed"):
        raise CaptureError("unknown termination")
    _process_observation(process_observation, kind)
    # Stop cause is independent of the status observed while reaping.
    # Failed stops may retain either status, or neither if not observed.
    exit_code, signal = terminal["exit_code"], terminal["signal"]
    if exit_code is not None and signal is not None:
        raise CaptureError("conflicting observed process statuses")
    if (kind == "exited" and (exit_code is None or signal is not None)
            or kind == "signaled" and (signal is None or exit_code is not None)
            or kind == "launch-failed" and (exit_code is not None or signal is not None)):
        raise CaptureError("inconsistent termination")
    for key, limit in (("exit_code", 255), ("signal", 127)):
        if terminal[key] is not None:
            _integer(terminal[key], limit)
            if key == "signal" and terminal[key] == 0:
                raise CaptureError("invalid zero signal")
    for stream in hashes:
        _integer(terminal[stream + "_length"])
        if terminal[stream + "_length"] != lengths[stream] or terminal[stream + "_sha256"] != hashes[stream].hexdigest():
            raise CaptureError("stream commitment mismatch")
    return {name: bytes(data) for name, data in streams.items()}


def _validate(payload):
    if type(payload) is not bytes or len(payload) > MAX_ENCODED_BYTES:
        raise CaptureError("encoded document limit/type")
    try:
        value = decode_canonical_bytes(payload)
        _closed(value, {"schema_version", "intent", "output_frames", "process_observation", "runtime_resolution", "terminal"})
        if type(value["schema_version"]) is not int or value["schema_version"] != 2:
            raise CaptureError("unsupported schema")
        intent, frames, terminal = value["intent"], value["output_frames"], value["terminal"]
        _intent(intent)
        _runtime_resolution(value["runtime_resolution"], intent["argv"])
        _closed(terminal, TERMINAL_FIELDS)
        if terminal["intent_sha256"] != canonical_sha256(intent):
            raise CaptureError("terminal commitment mismatch")
        _validate_transport(frames, value["process_observation"],
            {key: child for key, child in terminal.items() if key != "intent_sha256"},
            started_at_unix_ms=intent["started_at_unix_ms"])
    except (ValueError, TypeError, KeyError, UnicodeError, RecursionError, binascii.Error) as exc:
        raise CaptureError(str(exc)) from exc


def parse_capture(payload: bytes) -> CaptureEnvelope:
    return CaptureEnvelope(payload)


def serialize_capture(value: dict) -> bytes:
    try:
        payload = canonical_bytes(value)
    except (ValueError, TypeError, RecursionError) as exc:
        raise CaptureError(str(exc)) from exc
    return parse_capture(payload).payload


def intent_prefix(intent: dict) -> bytes:
    """Incomplete canonical-byte prefix; caller must persist before dispatch.

    Lexical key order guarantees the complete intent precedes output_frames.
    This prefix alone never passes parse_capture and is not execution proof.
    """
    try:
        _intent(intent)
        return b'{"intent":' + canonical_bytes(intent) + b',"output_frames":['
    except (ValueError, TypeError, KeyError, RecursionError) as exc:
        raise CaptureError(str(exc)) from exc


def compare_bindings(capture: CaptureEnvelope, *, expected_record: CommandRecord,
                     expected_plan_sha256: str, expected_run_id: str,
                     expected_nonce: str, expected_source_commit: str,
                     expected_source_tree: str, expected_capture_id: str,
                     expected_scenario_id: str,
                     expected_effective_environment: tuple[tuple[str, str], ...],
                     expected_prerequisite_receipts: tuple,
                     profile: CampaignProfile = CampaignProfile.EXISTING) -> tuple[str, ...]:
    """Return mismatched fields, NOT an authenticity/receipt admission result.

    Consumers must independently recompile/admit the expected context first.
    A forged self-consistent envelope can pass this comparison with forged inputs.
    """
    from .receipt_validator import QualificationRunAuthority
    try:
        resolved = resolve_command_record(expected_record,
            prerequisite_receipts=expected_prerequisite_receipts,
            qualification_run=QualificationRunAuthority(expected_run_id, expected_nonce), profile=profile)
    except ValueError as exc:
        raise CaptureError("independent expected runtime context is invalid: " + str(exc)) from exc
    document = capture.to_mapping()
    intent = document["intent"]
    expected = dict(candidate_identity_sha256=expected_record.candidate_identity_sha256,
                    command_id=expected_record.command_id,
                    command_record_sha256=resolved.static_record_sha256,
                    argv=list(resolved.record.argv), working_directory=expected_record.working_directory,
                    environment=[list(pair) for pair in expected_record.environment],
                    command_plan_sha256=expected_plan_sha256, run_id=expected_run_id,
                    nonce=expected_nonce, producer_source_commit=expected_source_commit,
                    producer_source_tree=expected_source_tree, capture_id=expected_capture_id,
                    scenario_id=expected_scenario_id,
                    effective_environment=[list(pair) for pair in expected_effective_environment],
                    prerequisite_receipts=[[item.command_id, item.canonical_sha256] for item in expected_prerequisite_receipts])
    mismatches = {key for key, value in expected.items() if intent[key] != value}
    # Empty compiled membership has exactly one command-scoped identity, not
    # an arbitrary fallback scenario. Named memberships remain exact.
    if expected_scenario_id not in (expected_record.scenario_ids or (expected_record.command_id,)):
        mismatches.add("scenario_id")
    if document["runtime_resolution"] != to_primitive(resolved.runtime_resolution):
        mismatches.add("runtime_resolution")
    return tuple(sorted(mismatches))
