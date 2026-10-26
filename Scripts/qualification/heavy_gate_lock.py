#!/usr/bin/env python3
"""Machine-wide exclusive lock for heavy native qualification phases.

The qualifier opens the lock file on a descriptor it keeps for the whole heavy
phase (``exec 7>>LOCK``) and asks this helper to take ``flock(LOCK_EX)`` on
that inherited descriptor. BSD ``flock`` locks belong to the open file
description, so the lock outlives this helper while the qualifier keeps the
descriptor and the kernel releases it when the last descriptor closes,
including after ``kill -9``. A crash can therefore never leave a stale lock;
the adjacent ``.json`` file is visibility metadata only and never grants or
denies the lock.

Heavy phases (qualification, CI, sanitizers, acceptance) take the lock
exclusively. The developer loop may instead pass ``--shared`` with
``--slot-fds``: it then holds ``flock(LOCK_SH)`` on the lock plus
``flock(LOCK_EX)`` on one of the inherited slot descriptors, so at most that
many dev-loop builds run together and never beside a heavy phase. A heavy phase
that is waiting publishes ``<lock>.waiting``; shared acquirers do not start
while that names a live process, so dev loops cannot starve CI.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import errno
import fcntl
import json
import os
from pathlib import Path
import stat
import sys
import time


TIMEOUT_STATUS = 4
LOG_INTERVAL_SECONDS = 60.0
POLL_INTERVAL_SECONDS = 1.0


class GateLockError(RuntimeError):
    """The lock descriptor or its metadata is unsafe."""


def metadata_path(lock: Path) -> Path:
    return lock.with_name(lock.name + ".json")


def waiting_path(lock: Path) -> Path:
    return lock.with_name(lock.name + ".waiting")


def slot_path(lock: Path, index: int) -> Path:
    return lock.with_name(f"{lock.name}.slot-{index}")


def process_alive(pid: object) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def heavy_waiter(lock: Path) -> int | None:
    try:
        value = json.loads(waiting_path(lock).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    pid = value.get("pid") if isinstance(value, dict) else None
    if process_alive(pid):
        return pid
    # A waiter killed before it acquired leaves its marker behind; drop it so a later
    # unrelated process reusing that pid can never block dev loops.
    if isinstance(pid, int):
        clear_waiting(lock, pid)
    return None


def waiter_summary(lock: Path) -> str:
    try:
        value = json.loads(waiting_path(lock).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return "an unidentified exclusive phase"
    if not isinstance(value, dict):
        return "an unidentified exclusive phase"
    return f"pid={value.get('pid')}, mode={value.get('mode')}"


def clear_waiting(lock: Path, pid: int) -> None:
    try:
        value = json.loads(waiting_path(lock).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return
    if isinstance(value, dict) and value.get("pid") == pid:
        try:
            waiting_path(lock).unlink()
        except FileNotFoundError:
            pass


def holder_summary(lock: Path) -> str:
    try:
        value = json.loads(metadata_path(lock).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return "an unidentified holder"
    if not isinstance(value, dict):
        return "an unidentified holder"
    fields = ("pid", "mode", "integration_ref", "work_root", "started_at")
    return ", ".join(f"{name}={value.get(name)}" for name in fields)


def validate_descriptor(descriptor: int, lock: Path) -> None:
    opened = os.fstat(descriptor)
    named = lock.lstat()
    if (
        not stat.S_ISREG(opened.st_mode)
        or stat.S_ISLNK(named.st_mode)
        or (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino)
    ):
        raise GateLockError("heavy-gate lock descriptor does not name the lock file")


def write_metadata(lock: Path, value: dict[str, object], target: Path | None = None) -> None:
    target = target or metadata_path(lock)
    temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    temporary.chmod(0o644)
    os.replace(temporary, target)


def holder_record(arguments: argparse.Namespace, waited: float) -> dict[str, object]:
    return {
        "integration_ref": arguments.integration_ref,
        "mode": arguments.mode,
        "pid": arguments.pid,
        "run_root": arguments.run_root,
        "started_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "waited_seconds": round(waited, 3),
        "work_root": arguments.work_root,
    }


def try_flock(descriptor: int, operation: int) -> bool:
    try:
        fcntl.flock(descriptor, operation | fcntl.LOCK_NB)
        return True
    except OSError as error:
        if error.errno not in {errno.EWOULDBLOCK, errno.EAGAIN}:
            raise
        return False


def acquire_shared(arguments: argparse.Namespace) -> int:
    lock = arguments.lock
    validate_descriptor(arguments.fd, lock)
    slots = arguments.slot_fds
    for index, descriptor in enumerate(slots):
        validate_descriptor(descriptor, slot_path(lock, index))
    started = time.monotonic()
    next_log = started
    while True:
        waiter = None if arguments.ignore_exclusive_waiter else heavy_waiter(lock)
        if waiter is None:
            for index, descriptor in enumerate(slots):
                if not try_flock(descriptor, fcntl.LOCK_EX):
                    continue
                if try_flock(arguments.fd, fcntl.LOCK_SH):
                    waited = time.monotonic() - started
                    write_metadata(lock, holder_record(arguments, waited), slot_path(lock, index).with_name(slot_path(lock, index).name + ".json"))
                    print(
                        f"==> acquired shared heavy-gate slot {index} of {len(slots)} after {waited:.1f}s",
                        file=sys.stderr,
                    )
                    return 0
                fcntl.flock(descriptor, fcntl.LOCK_UN)
                break
        now = time.monotonic()
        if arguments.timeout and now - started >= arguments.timeout:
            print(
                f"ERROR: timed out after {arguments.timeout}s waiting for a shared heavy-gate slot ({lock})",
                file=sys.stderr,
            )
            return TIMEOUT_STATUS
        if now >= next_log:
            if waiter is not None:
                message = (f"==> backing off: an exclusive heavy phase is queued ({waiter_summary(lock)}); "
                           "dev loops wait until it has run (MACSCOPE_DEV_IGNORE_EXCLUSIVE_WAITER=1 overrides)")
            else:
                message = f"==> waiting for a shared heavy-gate slot; exclusive holder: {holder_summary(lock)}"
            print(f"{message} ({lock})", file=sys.stderr, flush=True)
            next_log = now + LOG_INTERVAL_SECONDS
        time.sleep(POLL_INTERVAL_SECONDS)


def acquire_command(arguments: argparse.Namespace) -> int:
    if arguments.shared:
        return acquire_shared(arguments)
    lock = arguments.lock
    validate_descriptor(arguments.fd, lock)
    started = time.monotonic()
    next_log = started
    announced = False
    while True:
        if try_flock(arguments.fd, fcntl.LOCK_EX):
            break
        if not announced:
            write_metadata(lock, {"pid": arguments.pid, "mode": arguments.mode}, waiting_path(lock))
            announced = True
        now = time.monotonic()
        if arguments.timeout and now - started >= arguments.timeout:
            print(
                f"ERROR: timed out after {arguments.timeout}s waiting for heavy-gate lock "
                f"held by {holder_summary(lock)} ({lock})",
                file=sys.stderr,
            )
            clear_waiting(lock, arguments.pid)
            return TIMEOUT_STATUS
        if now >= next_log:
            print(
                f"==> waiting for heavy-gate lock held by {holder_summary(lock)} ({lock})",
                file=sys.stderr,
                flush=True,
            )
            next_log = now + LOG_INTERVAL_SECONDS
        time.sleep(POLL_INTERVAL_SECONDS)
    # The lock is now held through the qualifier's descriptor; recheck that the
    # path still names the locked file before publishing who holds it.
    validate_descriptor(arguments.fd, lock)
    if announced:
        clear_waiting(lock, arguments.pid)
    waited = time.monotonic() - started
    write_metadata(lock, holder_record(arguments, waited))
    print(f"==> acquired heavy-gate lock {lock} after {waited:.1f}s", file=sys.stderr)
    return 0


def release_command(arguments: argparse.Namespace) -> int:
    lock = arguments.lock
    targets = [metadata_path(lock)]
    targets += sorted(lock.parent.glob(lock.name + ".slot-*.json"))
    for target in targets:
        try:
            value = json.loads(target.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(value, dict) and value.get("pid") == arguments.pid:
            try:
                target.unlink()
            except FileNotFoundError:
                pass
    clear_waiting(lock, arguments.pid)
    return 0


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser()
    commands = value.add_subparsers(dest="command", required=True)
    acquire = commands.add_parser("acquire")
    acquire.add_argument("--fd", type=int, required=True)
    acquire.add_argument("--lock", type=Path, required=True)
    acquire.add_argument("--timeout", type=int, default=0)
    acquire.add_argument("--pid", type=int, required=True)
    acquire.add_argument("--work-root", required=True)
    acquire.add_argument("--integration-ref", required=True)
    acquire.add_argument("--mode", required=True)
    acquire.add_argument("--run-root", required=True)
    acquire.add_argument("--shared", action="store_true")
    # Escape hatch for shared acquirers: do not yield to a queued exclusive waiter.
    acquire.add_argument("--ignore-exclusive-waiter", action="store_true")
    acquire.add_argument(
        "--slot-fds",
        type=lambda text: [int(item) for item in text.split(",") if item],
        default=[],
    )
    acquire.set_defaults(action=acquire_command)
    release = commands.add_parser("release")
    release.add_argument("--lock", type=Path, required=True)
    release.add_argument("--pid", type=int, required=True)
    release.set_defaults(action=release_command)
    return value


def main() -> int:
    arguments = parser().parse_args()
    if getattr(arguments, "timeout", 0) < 0:
        print("ERROR: heavy-gate lock timeout must be nonnegative", file=sys.stderr)
        return 2
    if getattr(arguments, "shared", False) and not arguments.slot_fds:
        print("ERROR: --shared requires --slot-fds", file=sys.stderr)
        return 2
    try:
        return arguments.action(arguments)
    except (GateLockError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
