"""Read-only, current-user admission check before installed-app filesystem changes.

Two fresh target-absence observations bound ordinary census races, not the final
check-to-rename race: this is not a launch lock or cleanup authority. Unknown identity refuses.
No process, including the census helper, is ever signalled by this module.
"""

from __future__ import annotations

import ctypes
import errno
import json
import os
from pathlib import Path
import subprocess
import sys


BUNDLE_IDENTIFIER = "org.macscope.app"
MAX_PIDS = 16_384
MAX_PATH_BYTES = 4_096  # PROC_PIDPATHINFO_MAXSIZE in the installed public SDK.
MAX_APPLICATIONS = 64
MAX_HELPER_BYTES = 512 * 1024
ABSENCE_OBSERVATIONS = 2
HELPER_TIMEOUT_SECONDS = 3
_UNFINISHED_HELPERS: list[subprocess.Popen[bytes]] = []
_APPKIT_SCRIPT = r'''
ObjC.import("AppKit");
const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier("org.macscope.app");
if (apps.count > 64) throw Error("bundle-ID census exceeds bound");
const result = [];
for (let i = 0; i < apps.count; i++) {
    const app = apps.objectAtIndex(i);
    const path = app.executableURL ? ObjC.unwrap(app.executableURL.path) : null;
    if (path !== null && path.length > 4096) throw Error("executable path exceeds bound");
    result.push({pid: Number(app.processIdentifier), path: path});
}
JSON.stringify(result);
'''


class QuiescenceError(RuntimeError):
    """The app's absence could not be established; do not change its bundle."""


def _refuse(detail: str) -> None:
    raise QuiescenceError("app quiescence unproven: " + detail[:8192])


def _valid_path(value: object) -> bool:
    return (
        isinstance(value, str)
        and value.startswith("/")
        and len(value.encode("utf-8")) < MAX_PATH_BYTES
        and not any(ord(character) < 32 or ord(character) == 127 for character in value)
    )


def _decode_applications(payload: bytes) -> tuple[tuple[int, str], ...]:
    if len(payload) > MAX_HELPER_BYTES:
        _refuse("bundle-ID census output exceeds bound")
    try:
        rows = json.loads(payload)
    except (ValueError, UnicodeError) as error:
        _refuse(f"invalid bundle-ID census output: {type(error).__name__}")
    if not isinstance(rows, list) or len(rows) > MAX_APPLICATIONS:
        _refuse("invalid or oversized bundle-ID census")
    result = []
    for row in rows:
        if not isinstance(row, dict) or set(row) != {"pid", "path"}:
            _refuse("unknown bundle-ID census identity")
        pid, path = row["pid"], row["path"]
        if type(pid) is not int or pid <= 0 or not _valid_path(path):
            _refuse(f"bundle-ID PID {pid!r} path={path!r} has unknown identity")
        result.append((pid, path))
    return tuple(result)


def _bundle_applications() -> tuple[tuple[int, str], ...]:
    # A fresh helper avoids AppKit's run-loop-dependent cached application state.
    process = subprocess.Popen(
        ("/usr/bin/osascript", "-l", "JavaScript", "-e", _APPKIT_SCRIPT),
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
    )
    try:
        stdout, stderr = process.communicate(timeout=HELPER_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        # Retain handles; neither kill nor a context manager's unbounded wait is
        # permitted. The refusing caller stops without application mutation.
        _UNFINISHED_HELPERS.append(process)
        _refuse(f"bundle-ID census timed out; helper PID {process.pid} retained without signalling")
    if process.returncode != 0 or stderr or len(stdout) > MAX_HELPER_BYTES:
        _refuse(f"bundle-ID census helper PID {process.pid} failed (status={process.returncode})")
    return _decode_applications(stdout)


def _load_libproc():
    if sys.platform != "darwin":
        _refuse("public macOS process census is unavailable on this host")
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
    library.proc_listpids.restype = ctypes.c_int
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    library.proc_pidinfo.restype = ctypes.c_int
    return library


def _process_paths(*, libproc=None) -> dict[int, str]:
    library = libproc if libproc is not None else _load_libproc()
    pids = (ctypes.c_int * MAX_PIDS)()
    capacity = ctypes.sizeof(pids)
    ctypes.set_errno(0)
    size = library.proc_listpids(4, os.geteuid(), pids, capacity)  # PROC_UID_ONLY
    if size <= 0 or size >= capacity or size % ctypes.sizeof(ctypes.c_int):
        _refuse(f"incomplete same-user PID census (bytes={size}, errno={ctypes.get_errno()})")
    observed = list(pids[:size // ctypes.sizeof(ctypes.c_int)])
    if any(pid <= 0 for pid in observed) or len(set(observed)) != len(observed) or os.getpid() not in observed:
        _refuse("same-user PID census has invalid identities or omits the guard")
    result = {}
    for pid in observed:
        buffer = ctypes.create_string_buffer(MAX_PATH_BYTES)
        ctypes.set_errno(0)
        size = library.proc_pidpath(pid, buffer, len(buffer))
        path_errno = ctypes.get_errno()
        if size <= 0:
            # ESRCH alone is insufficient. A second public liveness probe must
            # also say no such process; no BSD structure is decoded or trusted.
            info = ctypes.create_string_buffer(1024)
            ctypes.set_errno(0)
            count = library.proc_pidinfo(pid, 3, 0, info, len(info))  # PROC_PIDTBSDINFO
            info_errno = ctypes.get_errno()
            if path_errno == errno.ESRCH and count == 0 and info_errno == errno.ESRCH:
                continue
            _refuse(f"PID {pid} path=unknown (path errno={path_errno}, BSD bytes={count}, errno={info_errno})")
        if size >= MAX_PATH_BYTES or buffer.raw[size] != 0 or b"\0" in buffer.raw[:size]:
            _refuse(f"PID {pid} path=unknown (incomplete executable path)")
        try:
            path = buffer.raw[:size].decode("utf-8", errors="strict")
        except UnicodeError:
            _refuse(f"PID {pid} path=unknown (non-UTF-8 executable path)")
        if not _valid_path(path):
            _refuse(f"PID {pid} path={path!r} is not an unambiguous executable path")
        result[pid] = path
    return result


def require_app_quiescent(source_app: Path, installed_app: Path) -> None:
    """Refuse live source/installed executables or any same-bundle-ID application."""
    expected = {
        str((app / "Contents/MacOS/MacScope").resolve())
        for app in (source_app, installed_app)
    }
    for _ in range(ABSENCE_OBSERVATIONS):
        applications = _bundle_applications()
        if applications:
            pid, path = applications[0]
            _refuse(f"live {BUNDLE_IDENTIFIER} PID {pid} path={path}")
        # Each complete scan must establish target absence. Unrelated process
        # churn is not evidence that either target application is running.
        current = _process_paths()
        for pid, path in current.items():
            if str(Path(path).resolve()) in expected:
                _refuse(f"live application PID {pid} path={path}")
