"""Collector-owned public kqueue process watches; never a system lifecycle journal.

Foreign-only path proofs have no fabricated BSD start identity. The caller must
arm before spawning its observer, drain during its workload, and report actual
observer EOF before finalizing. Queue receipts and every drain are retained.
"""
from __future__ import annotations

import ctypes
import copy
from dataclasses import dataclass
import os
from pathlib import Path
import select
import stat
import time
from typing import Callable, Iterable

KQ_FILTER_PROC = -5
EV_RECEIPT = 0x0040  # Public sys/event.h; absent from Python's select constants.
REGISTRATION_FLAGS = 0x0025 | EV_RECEIPT  # ADD | ENABLE | CLEAR | RECEIPT
SUCCESS_RECEIPT_FLAGS = REGISTRATION_FLAGS | 0x4000  # EV_ERROR with errno zero.
NOTE_EXIT = 0x80000000
NOTE_EXEC = 0x20000000
EVENT_FLAGS_MASK = 0x8075  # The registered EV_RECEIPT bit persists on native events.
EVENT_FFLAGS_MASK = NOTE_EXEC | NOTE_EXIT
PROOF_KIND = "prearmed-kqueue-path-v1"


class ProcessWatchError(RuntimeError):
    """A bounded collector failure; no foreign exclusions may be published."""


@dataclass(frozen=True)
class WatchLimits:
    watches: int = 4096
    drains: int = 4096
    events: int = 65536
    batch: int = 256
    reads_per_drain: int = 256
    diagnostics: int = 4096

    def __post_init__(self):
        maxima = (4096, 4096, 65536, 256, 256, 4096)
        if any(type(value) is not int or not 1 <= value <= maximum
               for value, maximum in zip(vars(self).values(), maxima)):
            raise ValueError("watch limits must be bounded positive integers")


@dataclass(frozen=True)
class WatchDiagnostic:
    code: str
    pid: int | None
    watch_token: int | None


@dataclass(frozen=True)
class WatchResult:
    proofs: tuple[dict, ...]
    drains: tuple[dict, ...]
    diagnostics: tuple[WatchDiagnostic, ...]
    healthy: bool
    observer_spawn_ns: int | None
    observer_eof_ns: int | None
    queue_closed_ns: int | None


def probe_executable_path(pid: int) -> str:
    """Read only proc_pidpath; protected BSD start-info is not consulted."""
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    function = library.proc_pidpath
    function.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
    function.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    length = function(pid, buffer, len(buffer))
    if length <= 0 or length >= len(buffer):
        raise ProcessWatchError("path-probe-unavailable")
    payload = buffer.raw[:length]
    if payload.endswith(b"\0"):
        payload = payload[:-1]
    if b"\0" in payload:
        raise ProcessWatchError("path-probe-invalid")
    return payload.decode("utf-8", errors="strict")


def _physical_identity(path: str) -> tuple[int, int]:
    if not isinstance(path, str) or not path or "\0" in path or len(path.encode("utf-8")) >= 4096:
        raise ProcessWatchError("path-invalid")
    value = Path(path)
    if not value.is_absolute() or str(value) != path or str(value.resolve(strict=True)) != path:
        raise ProcessWatchError("path-alias-or-noncanonical")
    metadata = value.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ProcessWatchError("path-not-regular")
    return metadata.st_dev, metadata.st_ino


class ProcessWatchCollector:
    def __init__(
        self, candidate_paths: Iterable[str], *,
        queue_factory: Callable | None = None,
        event_factory: Callable | None = None,
        path_probe: Callable[[int], str] = probe_executable_path,
        clock: Callable[[], int] = time.monotonic_ns,
        limits: WatchLimits = WatchLimits(),
    ):
        self._clock, self._probe, self._limits = clock, path_probe, limits
        if type(candidate_paths) not in (list, tuple, set, frozenset) or not 1 <= len(candidate_paths) <= 4096:
            raise ProcessWatchError("candidate-paths-unbounded")
        self._candidate_paths = frozenset(candidate_paths)
        if len(self._candidate_paths) != len(candidate_paths):
            raise ProcessWatchError("candidate-paths-duplicate")
        if not self._candidate_paths:
            raise ProcessWatchError("candidate-paths-empty")
        self._candidate_inodes = {_physical_identity(path) for path in self._candidate_paths}
        # Resolve native capabilities only when collecting, so report readers
        # and synthetic tests can import this module on non-kqueue hosts.
        if queue_factory is None:
            queue_factory = getattr(select, "kqueue", None)
        if event_factory is None:
            event_factory = getattr(select, "kevent", None)
        if not callable(queue_factory) or not callable(event_factory):
            raise ProcessWatchError("process-watch-unavailable")
        self._event_factory = event_factory
        self._queue = queue_factory()
        self._records: dict[int, dict] = {}
        self._tokens: dict[int, int] = {}
        self._ineligible: set[int] = set()
        self._drains: list[dict] = []
        self._diagnostics: list[WatchDiagnostic] = []
        self._event_count = 0
        self._last_time = -1
        self._healthy = True
        self._state = "new"
        self._spawn: int | None = None
        self._eof: int | None = None
        self._closed: int | None = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        if self._queue is not None:
            self._healthy = False
            self.close()

    def _now(self) -> int:
        value = self._clock()
        if type(value) is not int or value < 0 or value >= 2**63 or value < self._last_time:
            self._fail("clock-invalid")
        self._last_time = value
        return value

    def _diagnose(self, code: str, pid=None, token=None):
        if len(self._diagnostics) >= self._limits.diagnostics:
            self._fail("diagnostic-bound-exceeded")
        self._diagnostics.append(WatchDiagnostic(code, pid, token))

    def _fail(self, code: str):
        self._healthy = False
        if len(self._diagnostics) < self._limits.diagnostics:
            self._diagnostics.append(WatchDiagnostic(code, None, None))
        self.close()
        raise ProcessWatchError(code)

    def failure_snapshot(self) -> WatchResult:
        """Bounded diagnostic evidence after failure, never an exclusion proof."""
        return WatchResult((), tuple(copy.deepcopy(self._drains)), tuple(self._diagnostics),
                           False, self._spawn, self._eof, self._closed)

    def close(self):
        if self._queue is not None:
            queue, self._queue = self._queue, None
            try:
                queue.close()
            finally:
                value = self._clock()
                self._closed = value if type(value) is int and self._last_time < value < 2**63 else None
                if self._closed is None:
                    self._healthy = False
            if self._state != "finalized":
                self._healthy = False

    def _probe_record(self, pid: int) -> dict:
        begin = self._now()
        path = self._probe(pid)
        identity = _physical_identity(path)
        if path in self._candidate_paths or identity in self._candidate_inodes:
            raise ProcessWatchError("candidate-path-or-alias")
        return {"begin_monotonic_ns": begin, "end_monotonic_ns": self._now(), "executable_path": path}

    def arm(self, pids: Iterable[int]) -> None:
        if self._state != "new":
            self._fail("registration-after-arm")
        self._state = "arming"
        try:
            for pid in pids:
                if type(pid) is not int or pid <= 0 or pid > 2147483647:
                    self._fail("pid-invalid")
                if pid in self._records:
                    self._fail("duplicate-pid-registration")
                if len(self._records) >= self._limits.watches:
                    self._fail("watch-bound-exceeded")
                token = len(self._records) + 1
                record = {"proof_kind": PROOF_KIND, "observation_id": token, "pid": pid, "watch_token": token}
                self._records[pid] = record
                self._tokens[token] = pid
                requested = self._now()
                event = self._event_factory(pid, filter=KQ_FILTER_PROC, flags=REGISTRATION_FLAGS,
                                            fflags=NOTE_EXEC | NOTE_EXIT, udata=token)
                try:
                    receipts = self._queue.control([event], 1, 0)
                except OSError:
                    self._ineligible.add(token)
                    self._diagnose("registration-syscall-failed", pid, token)
                    continue
                completed = self._now()
                if len(receipts) != 1:
                    self._fail("registration-receipt-count")
                receipt = receipts[0]
                if (any(type(value) is not int for value in (receipt.ident, receipt.udata, receipt.filter,
                                                             receipt.flags, receipt.fflags, receipt.data))
                        or receipt.ident != pid or receipt.udata != token or receipt.filter != KQ_FILTER_PROC
                        or receipt.flags != SUCCESS_RECEIPT_FLAGS or receipt.fflags != EVENT_FFLAGS_MASK
                        or type(receipt.data) is not int or receipt.data < 0):
                    self._fail("registration-receipt-invalid")
                if receipt.data != 0:
                    self._ineligible.add(token)
                    self._diagnose("registration-denied", pid, token)
                    continue
                record["registration"] = {
                    "requested_monotonic_ns": requested, "completed_monotonic_ns": completed,
                    "receipt_ident": receipt.ident, "receipt_token": receipt.udata,
                    "receipt_filter": receipt.filter, "receipt_flags": receipt.flags,
                    "receipt_errno": receipt.data,
                }
                try:
                    record["initial_probe"] = self._probe_record(pid)
                except (OSError, ValueError, ProcessWatchError):
                    self._ineligible.add(token)
                    self._diagnose("initial-path-unavailable-or-candidate", pid, token)
            initial = self.drain()
            for record in self._records.values():
                record["initial_drain_id"] = initial["drain_id"]
            self._state = "armed"
        except BaseException:
            self._healthy = False
            self.close()
            raise

    def drain(self) -> dict:
        if self._queue is None or not self._healthy or self._state == "new":
            self._fail("drain-outside-watch-lifetime")
        if len(self._drains) >= self._limits.drains:
            self._fail("drain-bound-exceeded")
        result = {"drain_id": len(self._drains) + 1, "begin_monotonic_ns": self._now(),
                  "end_monotonic_ns": 0, "completed_to_empty": False, "events": []}
        self._drains.append(result)
        try:
            for _ in range(self._limits.reads_per_drain):
                try:
                    events = self._queue.control(None, self._limits.batch, 0)
                except OSError:
                    self._fail("queue-read-failed")
                if len(events) > self._limits.batch:
                    self._fail("event-batch-bound-exceeded")
                if not events:
                    result["completed_to_empty"] = True
                    result["end_monotonic_ns"] = self._now()
                    return result
                for event in events:
                    self._event_count += 1
                    if self._event_count > self._limits.events:
                        self._fail("event-bound-exceeded")
                    token = event.udata
                    if (type(token) is not int or token not in self._tokens or self._tokens[token] != event.ident
                            or any(type(value) is not int for value in (event.ident, event.filter, event.flags, event.fflags, event.data))):
                        self._fail("event-identity-invalid")
                    raw = {"watch_token": token, "pid": event.ident, "filter": event.filter,
                           "flags": event.flags, "fflags": event.fflags, "data": event.data}
                    result["events"].append(raw)
                    if (event.filter != KQ_FILTER_PROC or event.flags < 0 or event.flags & ~EVENT_FLAGS_MASK
                            or event.fflags < 0 or event.fflags & ~EVENT_FFLAGS_MASK or event.data != 0
                            or not (event.fflags or event.flags & 0x8010)):
                        self._fail("event-state-invalid")
                    self._ineligible.add(token)
                    self._diagnose("watch-transition-or-terminal-event", event.ident, token)
            self._fail("drain-did-not-complete")
        except BaseException:
            self._healthy = False
            self.close()
            raise

    def observer_started(self, spawn_ns: int) -> None:
        if (self._state != "armed" or type(spawn_ns) is not int
                or spawn_ns <= self._drains[-1]["end_monotonic_ns"] or spawn_ns > self._now()):
            self._fail("observer-spawn-order-invalid")
        self._spawn, self._state = spawn_ns, "observing"

    def observer_eof(self, eof_ns: int) -> None:
        if (self._state != "observing" or type(eof_ns) is not int
                or eof_ns <= self._spawn or eof_ns < self._drains[-1]["end_monotonic_ns"]
                or eof_ns > self._now()):
            self._fail("observer-eof-order-invalid")
        self._eof, self._state = eof_ns, "eof"

    def finalize(self, used_pids: Iterable[int]) -> WatchResult:
        if self._state != "eof":
            self._fail("finalize-before-explicit-eof")
        try:
            used = set()
            for index, pid in enumerate(used_pids):
                if type(pid) is not int or not 1 <= pid <= 2147483647 or index >= self._limits.watches:
                    self._fail("final-pid-bound-or-type")
                used.add(pid)
            pre = self.drain()
            for pid in sorted(used):
                record = self._records.get(pid)
                if record is None:
                    self._diagnose("pid-not-prearmed", pid)
                    continue
                token = record["watch_token"]
                if token in self._ineligible:
                    continue
                try:
                    final = self._probe_record(pid)
                    if final["executable_path"] != record["initial_probe"]["executable_path"]:
                        raise ProcessWatchError("final-path-changed")
                    record["final_probe"] = final
                    record["pre_final_drain_id"] = pre["drain_id"]
                except (OSError, ValueError, ProcessWatchError):
                    self._ineligible.add(token)
                    self._diagnose("final-path-unavailable-or-changed", pid, token)
            post = self.drain()
            proofs = []
            for pid in sorted(used):
                record = self._records.get(pid)
                if record and record["watch_token"] not in self._ineligible and "final_probe" in record:
                    record["post_final_drain_id"] = post["drain_id"]
                    proofs.append(record.copy())
            self._state = "finalized"
            self.close()
            return WatchResult(tuple(copy.deepcopy(proofs)), tuple(copy.deepcopy(self._drains)), tuple(self._diagnostics),
                               self._healthy, self._spawn, self._eof, self._closed)
        except BaseException:
            self._healthy = False
            self.close()
            raise
