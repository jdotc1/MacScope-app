"""Pure, fail-closed replay of prearmed foreign-process observation records.

This validates recorded proof, not kernel attestation. The governed collector
must establish physical canonical paths (including candidate alias exclusion),
retain the queue, and bind these bytes to the complete raw observation.
"""

from __future__ import annotations

import json
import posixpath
from typing import FrozenSet, Iterable


PROOF_KIND = "prearmed-kqueue-path-v1"
KQ_FILTER_PROC = -5
EV_RECEIPT = 0x0040
RECEIPT_FLAGS = 0x4065  # ADD | ENABLE | CLEAR | RECEIPT | ERROR
NOTE_EXIT = 0x80000000
NOTE_EXEC = 0x20000000
# EV_RECEIPT remains on runtime events on macOS 27.2; unlike EV_ERROR it is
# not itself a registration response. Preserve the observed raw flag.
EVENT_FLAGS_MASK = 0x8075  # ADD | ENABLE | ONESHOT | CLEAR | RECEIPT | EOF
EVENT_FFLAGS_MASK = NOTE_EXEC | NOTE_EXIT
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_PROOFS = 4096
MAX_WATCHES = MAX_PROOFS
MAX_DRAINS = 4096
MAX_EVENTS = 65536
MAX_PATH_BYTES = 4096
MAX_INTEGER = (1 << 63) - 1


class NetworkAttributionError(ValueError):
    """The retained evidence cannot authorize foreign-row exclusion."""


def _reject(message: str) -> None:
    raise NetworkAttributionError(message)


def _integer(value: object, label: str, *, minimum: int = 0) -> int:
    if type(value) is not int or not minimum <= value <= MAX_INTEGER:
        _reject(f"{label} must be a bounded integer")
    return value


def _object(value: object, keys: Iterable[str], label: str) -> dict:
    if type(value) is not dict or set(value) != set(keys):
        _reject(f"{label} has an invalid closed schema")
    return value


def _path(value: object) -> str:
    if type(value) is not str:
        _reject("executable path must be a canonical absolute string")
    try:
        size = len(value.encode("utf-8", errors="strict"))
    except UnicodeError as error:
        raise NetworkAttributionError("invalid executable path encoding") from error
    if (not 1 < size < MAX_PATH_BYTES or not value.startswith("/")
            or value.startswith("//") or posixpath.normpath(value) != value
            or any(ord(character) < 32 or ord(character) == 127 for character in value)):
        _reject("executable path must be canonical and bounded")
    return value


def decode_ledger_json(raw: bytes) -> dict:
    """Decode exactly {proofs, drains}; reject duplicates, nonfinite and deep JSON.

    Schema/temporal validation still requires validate_foreign_proofs with the
    independently governed observer boundaries and candidate path inventory.
    """
    if type(raw) is not bytes or not 0 < len(raw) <= MAX_JSON_BYTES:
        _reject("ledger JSON bytes absent or oversized")

    def pairs(items: list) -> dict:
        result = {}
        for key, value in items:
            if key in result:
                _reject("duplicate ledger JSON key")
            result[key] = value
        return result

    def constant(value: str) -> None:
        _reject("nonfinite ledger JSON number")

    try:
        result = json.loads(raw.decode("utf-8", errors="strict"),
                            object_pairs_hook=pairs, parse_constant=constant)
    except (UnicodeError, ValueError, RecursionError) as error:
        raise NetworkAttributionError("invalid ledger JSON") from error
    return _object(result, ("proofs", "drains"), "ledger")


def _probe(value: object, label: str) -> tuple:
    record = _object(value, ("begin_monotonic_ns", "end_monotonic_ns", "executable_path"), label)
    begin = _integer(record["begin_monotonic_ns"], label)
    end = _integer(record["end_monotonic_ns"], label)
    if begin > end:
        _reject(f"{label} is reversed")
    return begin, end, _path(record["executable_path"])


def validate_foreign_proofs(
    proofs: object,
    drains: object,
    *,
    observer_spawn_ns: int,
    observer_eof_ns: int,
    queue_closed_ns: int,
    candidate_paths: Iterable[str],
) -> FrozenSet[int]:
    """Return eligible PIDs, or reject the entire evidence on any invalid record.

    No start time is accepted or synthesized. Canonical here means lexical;
    physical alias exclusion is a mandatory collector precondition. A returned
    PID can exclude a raw row only in the caller's matching observer session.
    """
    spawn = _integer(observer_spawn_ns, "observer spawn")
    eof = _integer(observer_eof_ns, "observer EOF")
    closed = _integer(queue_closed_ns, "queue closure")
    if not spawn < eof < closed:
        _reject("observer/queue boundaries are not ordered")
    if type(candidate_paths) not in (list, tuple, set, frozenset):
        _reject("candidate paths must be a bounded inventory")
    if not 1 <= len(candidate_paths) <= MAX_PROOFS:
        _reject("candidate path inventory absent or oversized")
    candidates = {_path(path) for path in candidate_paths}
    if len(candidates) != len(candidate_paths):
        _reject("duplicate candidate path")
    if type(proofs) is not list or len(proofs) > MAX_PROOFS:
        _reject("proof inventory must be a bounded list")
    if type(drains) is not list or not 1 <= len(drains) <= MAX_DRAINS:
        _reject("drain inventory absent or oversized")

    drain_index = {}
    event_tokens, event_pids = set(), set()
    event_token_pids, event_pid_tokens = {}, {}
    last_id, last_end, event_count = 0, 0, 0
    for item in drains:
        record = _object(item, ("drain_id", "begin_monotonic_ns", "end_monotonic_ns",
                                "completed_to_empty", "events"), "drain")
        ident = _integer(record["drain_id"], "drain ID", minimum=1)
        begin = _integer(record["begin_monotonic_ns"], "drain begin")
        end = _integer(record["end_monotonic_ns"], "drain end")
        if ident <= last_id or not last_end <= begin <= end < closed:
            _reject("drains are duplicate, overlapping or unordered")
        if record["completed_to_empty"] is not True:
            _reject("drain did not complete to empty")
        events = record["events"]
        if type(events) is not list:
            _reject("events must be a bounded list")
        event_count += len(events)
        if event_count > MAX_EVENTS:
            _reject("event bound exceeded")
        for event in events:
            event = _object(event, ("watch_token", "pid", "filter", "flags", "fflags", "data"), "event")
            _integer(event["watch_token"], "event token", minimum=1)
            _integer(event["pid"], "event PID", minimum=1)
            for field in ("flags", "fflags"):
                _integer(event[field], f"event {field}")
            _integer(event["data"], "event data", minimum=-(1 << 63))
            if type(event["filter"]) is not int or event["filter"] != KQ_FILTER_PROC:
                _reject("unexpected event filter")
            # Known transitions for unrelated watches remain in the ledger.
            # Unknown event forms cannot silently disappear from attribution.
            if (event["flags"] & ~EVENT_FLAGS_MASK or event["fflags"] & ~EVENT_FFLAGS_MASK
                    or not (event["fflags"] or event["flags"] & 0x8010)
                    or event["data"] != 0):
                _reject("unexpected process event")
            token, pid = event["watch_token"], event["pid"]
            if (event_token_pids.get(token, pid) != pid
                    or event_pid_tokens.get(pid, token) != token):
                _reject("event token/PID association changed")
            event_token_pids[token] = pid
            event_pid_tokens[pid] = token
            event_tokens.add(event["watch_token"])
            event_pids.add(event["pid"])
        drain_index[ident] = (begin, end)
        last_id, last_end = ident, end

    pids, tokens, observations = set(), set(), set()
    for item in proofs:
        record = _object(item, ("proof_kind", "observation_id", "pid", "watch_token",
                                "registration", "initial_probe", "final_probe",
                                "initial_drain_id", "pre_final_drain_id", "post_final_drain_id"), "proof")
        if record["proof_kind"] != PROOF_KIND:
            _reject("unsupported foreign proof kind")
        pid = _integer(record["pid"], "PID", minimum=1)
        token = _integer(record["watch_token"], "watch token", minimum=1)
        observation = _integer(record["observation_id"], "observation ID", minimum=1)
        if pid in pids or token in tokens or observation in observations:
            _reject("reused PID, watch token or observation ID")
        if token in event_tokens or pid in event_pids:
            _reject("proof has a process transition, terminal state or error")
        registration = _object(record["registration"], ("requested_monotonic_ns", "completed_monotonic_ns",
            "receipt_ident", "receipt_token", "receipt_filter", "receipt_flags", "receipt_errno"), "registration")
        requested = _integer(registration["requested_monotonic_ns"], "registration request")
        completed = _integer(registration["completed_monotonic_ns"], "registration completion")
        for field, expected in (("receipt_ident", pid), ("receipt_token", token),
                                ("receipt_filter", KQ_FILTER_PROC), ("receipt_flags", RECEIPT_FLAGS),
                                ("receipt_errno", 0)):
            if type(registration[field]) is not int or registration[field] != expected:
                _reject(f"invalid {field}")
        initial = _probe(record["initial_probe"], "initial probe")
        final = _probe(record["final_probe"], "final probe")
        if initial[2] != final[2] or initial[2] in candidates:
            _reject("changed or candidate executable path")
        selected = []
        for field in ("initial_drain_id", "pre_final_drain_id", "post_final_drain_id"):
            ident = _integer(record[field], field, minimum=1)
            if ident not in drain_index:
                _reject("missing referenced drain")
            selected.append(drain_index[ident])
        before, prefinal, after = selected
        if not (requested <= completed <= initial[0] <= initial[1] <= before[0]
                <= before[1] < spawn < eof <= prefinal[0] <= prefinal[1]
                <= final[0] <= final[1] <= after[0] <= after[1] < closed):
            _reject("proof/observer temporal ordering mismatch")
        if len({record["initial_drain_id"], record["pre_final_drain_id"], record["post_final_drain_id"]}) != 3:
            _reject("proof requires distinct drain boundaries")
        pids.add(pid)
        tokens.add(token)
        observations.add(observation)
    return frozenset(pids)
