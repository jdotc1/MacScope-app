"""macscope — a Python client for the MacScope binary-analysis app.

This is a thin, dependency-free client: it spawns a headless ``MacScope --mcp <binary>``
subprocess and talks to it over MCP (JSON-RPC 2.0 / stdio), exposing the analysis command
surface as a Pythonic API. Nothing is embedded in the app — MacScope does the analysis; this
just drives it.

    import macscope

    with macscope.open("/bin/ls") as doc:
        print(doc.info()["functionCount"])
        for f in doc.functions(limit=5):
            print(hex(f.address), f.name)
        print(doc.read_bytes(0x100000700, 16).hex())
        doc.rename(0x100000700, "_start")          # undoable, in the live session

The MacScope executable is located via ``$MACSCOPE_BINARY``, then ``PATH``; or pass
``executable=`` explicitly (…/MacScope.app/Contents/MacOS/MacScope).

Deadlines: every exchange with the server is bounded. ``startup_timeout`` covers spawning
the server, its analysis of the binary and the MCP handshake; ``request_timeout`` covers
one request (queueing, writing it and reading its response). Pass them to :func:`open`, or
set ``$MACSCOPE_STARTUP_TIMEOUT`` / ``$MACSCOPE_REQUEST_TIMEOUT`` (seconds). ``None`` as an
argument disables that deadline explicitly. When a deadline expires or the server dies, the
client is retired (the server is stopped and reaped) and a :class:`MacScopeTransportError`
names the phase, method and request id. Requests are never retried automatically; for a
request that may have reached the server, ``outcome_unknown`` is true and the caller must
check the result in a new session before repeating a mutation.
"""
from __future__ import annotations

import errno
import json
import math
import os
import selectors
import shutil
import subprocess
import threading
import time
import weakref
from typing import Any, Optional

__all__ = [
    "open",
    "Document",
    "MacScopeError",
    "MacScopeTransportError",
    "MacScopeTimeoutError",
    "find_executable",
    "JSON_NULL",
    "DEFAULT_STARTUP_TIMEOUT",
    "DEFAULT_REQUEST_TIMEOUT",
]

_PROTOCOL_VERSION = "2024-11-05"

# Per-stage teardown budget: wait this long for exit after stdin EOF, then again after
# SIGTERM, before SIGKILL.
_TERMINATE_TIMEOUT_SECONDS = 5.0

# Startup = spawn + headless analysis of the binary + MCP handshake. The server analyzes the
# whole binary before it answers `initialize`, so this scales with binary size. Measured on
# this Mac (installed MacScope, 2026-10-11): /bin/ls 0.08 s, /usr/bin/ssh (1.7 MB)
# 7.5-10.7 s, /usr/lib/dyld (4.1 MB) 12.1-14.3 s, /bin/zsh (2.0 MB) 14.9-37.3 s; a 95 MB
# binary had not finished after 12.6 min. 300 s is 8x the slowest completed handshake;
# very large binaries need an explicit override.
DEFAULT_STARTUP_TIMEOUT = 300.0
# One request: write + server work + response. Measured requests (info, functions,
# decompile) took at most 0.36 s on the same binaries; the default leaves room for large
# decompiles and slow machines while still turning a wedged server into an error.
DEFAULT_REQUEST_TIMEOUT = 120.0

_STARTUP_TIMEOUT_ENV = "MACSCOPE_STARTUP_TIMEOUT"
_REQUEST_TIMEOUT_ENV = "MACSCOPE_REQUEST_TIMEOUT"

# MCPServer.Configuration.production bounds the serialized payload at 8 MiB, including
# the restored JSON-RPC id. HeadlessProtocolIO.writeLine adds LF separately.
_MAX_RESPONSE_BYTES = 8 * 1024 * 1024
_READ_CHUNK = 65536

# Sentinel: "argument not given", so an explicit None (no deadline) stays distinguishable.
_UNSET: Any = object()


def _close_quietly(stream: Any) -> None:
    """Close a pipe; a flush failure (the reader already exited) must not skip the close."""
    if stream is None:
        return
    try:
        stream.close()
    except Exception:
        pass


def _signal_quietly(send: Any) -> None:
    """Send a termination signal, tolerating a child that exited in the meantime."""
    try:
        send()
    except OSError:
        pass


class _JSONNull:
    """Explicit JSON null; ordinary None still means omit an optional argument."""

    __slots__ = ()

    def __repr__(self) -> str:
        return "JSON_NULL"


JSON_NULL = _JSONNull()


class MacScopeError(RuntimeError):
    """A tool failure or transport error from the MacScope MCP server."""


class MacScopeTransportError(MacScopeError):
    """The exchange with the server failed: it died, closed the connection, or (subclass
    :class:`MacScopeTimeoutError`) missed a deadline.

    Attributes:
        phase: ``"startup"`` (spawn, analysis and MCP handshake) or ``"request"``.
        method: the JSON-RPC method (``"initialize"``, ``"tools/call"``, ...).
        request_id: the JSON-RPC id, or None for a notification.
        tool: the tool name for ``tools/call``, else None.
        stage: where it failed: ``"queue"``, ``"write"`` or ``"read"``.
        outcome_unknown: True when any byte of the request may have reached the server, so
            it may have executed it. The client never retries; check before repeating.
        retired: True when the client was retired (server stopped and reaped).
    """

    def __init__(
        self,
        message: str,
        *,
        phase: str,
        method: str,
        request_id: Optional[int],
        tool: Optional[str] = None,
        stage: str,
        outcome_unknown: bool,
        retired: bool,
    ) -> None:
        super().__init__(message)
        self.phase = phase
        self.method = method
        self.request_id = request_id
        self.tool = tool
        self.stage = stage
        self.outcome_unknown = outcome_unknown
        self.retired = retired


class MacScopeTimeoutError(MacScopeTransportError):
    """A startup or request deadline expired. ``timeout`` is the budget in seconds and
    ``elapsed`` the monotonic time spent before the client gave up."""

    def __init__(self, message: str, *, timeout: float, elapsed: float, **fields: Any) -> None:
        super().__init__(message, **fields)
        self.timeout = timeout
        self.elapsed = elapsed


def _resolve_timeout(value: Any, env_name: str, default: float) -> Optional[float]:
    """Explicit argument, else the environment override, else the measured default. None
    disables the deadline; anything else must be a positive finite number of seconds."""
    if value is _UNSET:
        raw = os.environ.get(env_name)
        if raw is None or raw.strip() == "":
            return default
        if raw.strip().lower() == "none":
            return None
        try:
            value = float(raw)
        except ValueError:
            raise MacScopeError(f"${env_name} must be a number of seconds or 'none', got {raw!r}")
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise MacScopeError(f"timeout must be a number of seconds or None, got {value!r}")
    value = float(value)
    if not math.isfinite(value) or value <= 0:
        raise MacScopeError(f"timeout must be positive and finite, got {value!r}")
    return value


class _Deadline:
    """A monotonic deadline; ``None`` seconds means unbounded."""

    __slots__ = ("seconds", "started", "_end")

    def __init__(self, seconds: Optional[float]) -> None:
        self.seconds = seconds
        self.started = time.monotonic()
        self._end = None if seconds is None else self.started + seconds

    def remaining(self) -> Optional[float]:
        if self._end is None:
            return None
        return max(0.0, self._end - time.monotonic())

    def expired(self) -> bool:
        return self._end is not None and time.monotonic() >= self._end

    def elapsed(self) -> float:
        return time.monotonic() - self.started


class _DeadlineExpired(Exception):
    def __init__(self, stage: str, sent: bool) -> None:
        super().__init__(stage)
        self.stage = stage
        self.sent = sent


class _ConnectionLost(Exception):
    def __init__(self, stage: str, sent: bool, detail: str) -> None:
        super().__init__(detail)
        self.stage = stage
        self.sent = sent
        self.detail = detail


class _PipeTransport:
    """Newline-delimited framing over the child's stdin/stdout with monotonic deadlines.

    Both pipe ends are switched to non-blocking mode and every wait goes through
    ``selectors`` (kqueue on macOS, epoll on Linux) with the time left on the deadline, so a
    server that never reads stdin, never answers, sends half a line, or floods notifications
    cannot block the caller past the deadline. Single-threaded on purpose: no reader thread
    is left blocked in ``read`` after a timeout, and a ``write`` cannot outlive its deadline.

    Each physical response line is capped in bytes, excluding its LF, before accumulation
    or decoding. Retained framing storage is at most one capped line plus one fixed read
    chunk; coalesced frames share that chunk without being counted as a single line.
    """

    def __init__(self, stdin: Any, stdout: Any) -> None:
        self._out_fd = stdin.fileno()
        self._in_fd = stdout.fileno()
        os.set_blocking(self._out_fd, False)
        os.set_blocking(self._in_fd, False)
        self._maximum_response_bytes = _MAX_RESPONSE_BYTES
        self._buffer = bytearray()
        self._chunk = b""
        self._chunk_offset = 0

    def _wait(self, fd: int, event: int, deadline: _Deadline) -> bool:
        """Wait until ``fd`` is ready for ``event``; False when the deadline expires."""
        with selectors.DefaultSelector() as selector:
            selector.register(fd, event)
            while True:
                remaining = deadline.remaining()
                if remaining is not None and remaining <= 0:
                    return False
                if selector.select(remaining):
                    return True

    def write_line(self, data: bytes, deadline: _Deadline) -> None:
        view = memoryview(data + b"\n")
        written = 0
        while written < len(view):
            if deadline.expired() or not self._wait(self._out_fd, selectors.EVENT_WRITE, deadline):
                raise _DeadlineExpired("write", written > 0)
            try:
                written += os.write(self._out_fd, view[written:])
            except BlockingIOError:
                continue
            except (BrokenPipeError, ConnectionResetError) as exc:
                raise _ConnectionLost("write", written > 0, f"stdin closed by server ({exc})")
            except OSError as exc:
                if exc.errno == errno.EAGAIN:
                    continue
                raise _ConnectionLost("write", written > 0, f"write failed ({exc})")

    def read_line(self, deadline: _Deadline) -> Optional[bytes]:
        """The next line without its newline, or None at EOF on a line boundary."""
        while True:
            # Include already-buffered notifications in the deadline, not only pipe waits.
            if deadline.expired():
                raise _DeadlineExpired("read", True)
            if self._chunk_offset < len(self._chunk):
                newline = self._chunk.find(b"\n", self._chunk_offset)
                end = len(self._chunk) if newline < 0 else newline
                count = end - self._chunk_offset
                if count > self._maximum_response_bytes - len(self._buffer):
                    raise _ConnectionLost(
                        "read", True,
                        f"response line exceeds {self._maximum_response_bytes} bytes (excluding LF)",
                    )
                # Check the physical byte count before copying even malformed/noise frames.
                # A memoryview avoids making an additional temporary slice of the chunk.
                self._buffer.extend(memoryview(self._chunk)[self._chunk_offset:end])
                self._chunk_offset = end if newline < 0 else end + 1
                if newline >= 0:
                    line = bytes(self._buffer)
                    self._buffer.clear()
                    return line
            self._chunk = b""
            self._chunk_offset = 0
            if not self._wait(self._in_fd, selectors.EVENT_READ, deadline):
                raise _DeadlineExpired("read", True)
            try:
                self._chunk = os.read(self._in_fd, _READ_CHUNK)
            except BlockingIOError:
                continue
            if not self._chunk:
                if self._buffer:
                    raise _ConnectionLost(
                        "read", True,
                        f"server exited in the middle of a message ({len(self._buffer)} bytes)",
                    )
                return None


def find_executable() -> Optional[str]:
    """Locate the MacScope executable: ``$MACSCOPE_BINARY`` first, then ``PATH``."""
    return os.environ.get("MACSCOPE_BINARY") or shutil.which("MacScope")


class _Record(dict):
    """A dict that also allows attribute access — ``rec.name`` == ``rec["name"]``."""

    def __getattr__(self, key: str) -> Any:
        try:
            return self[key]
        except KeyError as exc:
            raise AttributeError(key) from exc


# Field names whose "0x…" string values are addresses and should become ints. Crucially
# this does NOT include free-text fields like `operands` (a branch target renders as a bare
# "0x…" string) or a `value` string literal, which must stay strings.
_ADDRESS_KEYS = frozenset({"address", "end", "start", "from", "to", "fileOffset"})


def _coerce(value: Any, key: Optional[str] = None) -> Any:
    """Make a decoded result Pythonic: dicts become attribute-accessible records, and a
    hex string ("0x…") becomes an int ONLY when it sits under a known address field."""
    if isinstance(value, str):
        if key in _ADDRESS_KEYS and value.startswith("0x"):
            try:
                return int(value, 16)
            except ValueError:
                return value
        return value
    if isinstance(value, dict):
        return _Record({k: _coerce(v, k) for k, v in value.items()})
    if isinstance(value, list):
        return [_coerce(v, key) for v in value]
    return value


def _as_address(value: Any) -> Optional[int]:
    """Interpret a command result that is a bare ``"0x…"`` address string as an int."""
    if isinstance(value, str) and value.startswith("0x"):
        try:
            return int(value, 16)
        except ValueError:
            return None
    return value if isinstance(value, int) else None


def _addr(value: Any) -> Any:
    """Send an integer address as an unsigned ``"0x…"`` string (the command layer accepts a
    JSON number or a hex/decimal string; a hex string avoids any 64-bit signedness issue)."""
    return hex(value) if isinstance(value, int) else value


class _MCPClient:
    """A minimal MCP (JSON-RPC 2.0) client over a subprocess's newline-delimited stdio.

    Concurrency policy: one request in flight per client. The protocol is strictly
    sequential (an id-less error answers the outstanding request), so concurrent callers
    are serialized by a lock; the wait for the lock counts against the caller's own request
    deadline. A deadline expiry, a dead server or a broken pipe retires the client: the
    server is stopped and reaped with the MS-08 teardown and every later call fails fast.
    Nothing is retried automatically.
    """

    def __init__(
        self,
        executable: str,
        binary: str,
        *,
        startup_timeout: Any = _UNSET,
        request_timeout: Any = _UNSET,
        terminate_timeout: float = _TERMINATE_TIMEOUT_SECONDS,
    ) -> None:
        self._startup_timeout = _resolve_timeout(
            startup_timeout, _STARTUP_TIMEOUT_ENV, DEFAULT_STARTUP_TIMEOUT
        )
        self._request_timeout = _resolve_timeout(
            request_timeout, _REQUEST_TIMEOUT_ENV, DEFAULT_REQUEST_TIMEOUT
        )
        self._next_id = 0
        self._lock = threading.Lock()
        self._retired = False
        startup = _Deadline(self._startup_timeout)
        self._proc = subprocess.Popen(
            [executable, "--mcp", binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            bufsize=0,
        )
        # Reap the child even if the caller never calls close() (REPL / dropped reference /
        # exception before close) or if the handshake below fails — Python's Popen finalizer
        # would otherwise just warn and leave the analysis subprocess running.
        self._finalizer = weakref.finalize(
            self, self._terminate, self._proc, terminate_timeout
        )
        self._terminate_timeout = terminate_timeout
        try:
            self._transport = _PipeTransport(self._proc.stdin, self._proc.stdout)
            self._initialize(startup)
        except BaseException:
            self._retire(graceful=False)  # don't orphan the spawned child on a failed handshake
            raise

    @classmethod
    def _over(cls, transport: Any, request_timeout: Optional[float] = None) -> "_MCPClient":
        """A client over an existing transport (tests); retirement only marks it retired."""
        client = object.__new__(cls)
        client._transport = transport
        client._request_timeout = request_timeout
        client._startup_timeout = request_timeout
        client._next_id = 0
        client._lock = threading.Lock()
        client._retired = False
        client._proc = None
        client._finalizer = None
        client._terminate_timeout = _TERMINATE_TIMEOUT_SECONDS
        return client

    @staticmethod
    def _terminate(
        proc: "subprocess.Popen",
        timeout: float = _TERMINATE_TIMEOUT_SECONDS,
        graceful: bool = True,
    ) -> None:
        """Stop and reap the server, then close every pipe the client holds.

        Closing stdin first lets the server exit on EOF; a server still running after
        ``timeout`` seconds receives SIGTERM, and one that survives that receives SIGKILL
        followed by an unbounded wait (SIGKILL cannot be ignored), so the child is always
        reaped. Pipes are closed in ``finally`` even when the child had already exited.

        ``graceful=False`` (retirement after a deadline or transport failure) skips the EOF
        grace period: the server already failed to keep its contract, so SIGTERM is sent at
        once and the retirement costs at most ``timeout`` before SIGKILL."""
        try:
            _close_quietly(proc.stdin)
            if proc.poll() is None:
                if graceful:
                    try:
                        proc.wait(timeout=timeout)
                        return
                    except subprocess.TimeoutExpired:
                        pass
                _signal_quietly(proc.terminate)
                try:
                    proc.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    _signal_quietly(proc.kill)
                    proc.wait()
        finally:
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                _close_quietly(stream)

    def _retire(self, graceful: bool) -> None:
        self._retired = True
        finalizer = self._finalizer
        if finalizer is None or not finalizer.alive:
            return
        if graceful:
            finalizer()
        else:
            finalizer.detach()
            self._terminate(self._proc, self._terminate_timeout, False)

    def _fail(
        self,
        failure: BaseException,
        *,
        phase: str,
        method: str,
        request_id: Optional[int],
        tool: Optional[str],
        deadline: _Deadline,
    ) -> MacScopeTransportError:
        """Retire the client and describe the failure as a typed, phase-naming error."""
        self._retire(graceful=False)
        what = f"MacScope {phase} {method!r}"
        if tool is not None:
            what += f" (tool {tool!r})"
        if request_id is not None:
            what += f" id {request_id}"
        sent = getattr(failure, "sent", False)
        stage = getattr(failure, "stage", "read")
        if sent:
            consequence = (
                " The outcome is unknown: the server may have received and applied it."
                " It was not retried; check the result in a new session before repeating it."
            )
        else:
            consequence = " Nothing was sent to the server."
        retired = " The client was retired and the server process stopped and reaped."
        fields = dict(
            phase=phase, method=method, request_id=request_id, tool=tool,
            stage=stage, outcome_unknown=sent, retired=True,
        )
        if isinstance(failure, _DeadlineExpired):
            seconds = deadline.seconds
            return MacScopeTimeoutError(
                f"{what} exceeded its {seconds:g} s {phase} deadline while waiting to "
                f"{stage}." + retired + consequence,
                timeout=seconds if seconds is not None else math.inf,
                elapsed=deadline.elapsed(),
                **fields,
            )
        detail = getattr(failure, "detail", str(failure))
        code = self._proc.returncode if self._proc is not None else None
        exit_note = f" (exit status {code})" if code is not None else ""
        return MacScopeTransportError(
            f"{what} failed during {stage}: {detail}{exit_note}." + retired + consequence,
            **fields,
        )

    def _exchange(
        self,
        method: str,
        params: Optional[dict],
        *,
        phase: str,
        deadline: _Deadline,
        expect_response: bool,
    ) -> Any:
        tool = params.get("name") if method == "tools/call" and params else None
        request_id: Optional[int] = None
        message: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if expect_response:
            self._next_id += 1
            request_id = self._next_id
            message = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        if self._retired or (self._proc is not None and self._proc.poll() is not None):
            if not self._retired:
                self._retire(graceful=False)
            raise MacScopeTransportError(
                f"MacScope MCP server is not running (client retired); {method!r} was not sent",
                phase=phase, method=method, request_id=request_id, tool=tool,
                stage="queue", outcome_unknown=False, retired=True,
            )
        try:
            # The server's strict parser rejects NaN/Infinity; fail here instead of sending them.
            encoded = json.dumps(message, allow_nan=False).encode("utf-8")
        except ValueError as exc:
            raise MacScopeError(f"argument is not representable as JSON: {exc}") from exc
        try:
            self._transport.write_line(encoded, deadline)
            if not expect_response:
                return None
            return self._read_response(request_id, deadline)
        except (_DeadlineExpired, _ConnectionLost) as failure:
            raise self._fail(
                failure, phase=phase, method=method, request_id=request_id, tool=tool,
                deadline=deadline,
            ) from None

    def _read_response(self, expected_id: int, deadline: _Deadline) -> Any:
        while True:
            raw = self._transport.read_line(deadline)
            if raw is None:
                raise _ConnectionLost("read", True, "server closed the connection")
            line = raw.strip()
            if not line:
                continue
            try:
                message = json.loads(line.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue  # skip any non-JSON noise on stdout
            if not isinstance(message, dict):
                continue
            if message.get("id") != expected_id:
                # Requests are strictly sequential, so an error the server could not attribute
                # (id null: oversized or unparsable input) answers the outstanding request.
                # Skipping it would wait forever on a server that is waiting for us.
                if "id" in message and message["id"] is None and "error" in message:
                    err = message["error"] or {}
                    raise MacScopeError(f"{err.get('message')} (code {err.get('code')})")
                continue
            if "error" in message:
                err = message["error"] or {}
                raise MacScopeError(f"{err.get('message')} (code {err.get('code')})")
            return message.get("result")

    def _request(self, method: str, params: Optional[dict] = None) -> Any:
        deadline = _Deadline(self._request_timeout)
        tool = params.get("name") if method == "tools/call" and params else None
        remaining = deadline.remaining()
        acquired = self._lock.acquire(timeout=-1 if remaining is None else remaining)
        if not acquired:
            raise MacScopeTimeoutError(
                f"MacScope request {method!r} waited {deadline.seconds:g} s for another "
                "request on this client to finish; nothing was sent and the client stays open.",
                timeout=deadline.seconds, elapsed=deadline.elapsed(),
                phase="request", method=method, request_id=None, tool=tool,
                stage="queue", outcome_unknown=False, retired=False,
            )
        try:
            return self._exchange(
                method, params, phase="request", deadline=deadline, expect_response=True
            )
        finally:
            self._lock.release()

    def _initialize(self, deadline: _Deadline) -> None:
        with self._lock:
            self._exchange(
                "initialize",
                {
                    "protocolVersion": _PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "macscope-python", "version": "0.1.0"},
                },
                phase="startup", deadline=deadline, expect_response=True,
            )
            self._exchange(
                "notifications/initialized", None,
                phase="startup", deadline=deadline, expect_response=False,
            )

    def call(self, name: str, arguments: Optional[dict] = None) -> Any:
        result = self._request("tools/call", {"name": name, "arguments": arguments or {}})
        content = (result or {}).get("content") or []
        text = content[0].get("text", "") if content else ""
        if (result or {}).get("isError"):
            raise MacScopeError(text or f"tool '{name}' failed")
        if text == "":
            return None
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text

    def close(self) -> None:
        # Idempotent: weakref.finalize runs the teardown at most once whether called here,
        # by __exit__, or by GC; later calls are no-ops. A request in flight on another
        # thread is interrupted by stopping the server, which that request then reports.
        self._retired = True
        if self._finalizer is None:
            return
        if not self._lock.acquire(blocking=False):
            # Stop the server so the in-flight request ends (it reports the failure and
            # retires the client); escalate to SIGKILL if SIGTERM is ignored.
            _signal_quietly(self._proc.terminate)
            if not self._lock.acquire(timeout=self._terminate_timeout):
                _signal_quietly(self._proc.kill)
                self._lock.acquire()
        try:
            if self._finalizer.alive:
                self._finalizer()
        finally:
            self._lock.release()


class Document:
    """An open binary. Each method maps to a MacScope scripting command and returns the
    decoded result (addresses as ints, objects as attribute-accessible records)."""

    def __init__(
        self,
        binary: str,
        executable: Optional[str] = None,
        *,
        startup_timeout: Any = _UNSET,
        request_timeout: Any = _UNSET,
    ) -> None:
        exe = executable or find_executable()
        if not exe:
            raise MacScopeError(
                "MacScope executable not found. Set $MACSCOPE_BINARY to the built binary "
                "(…/MacScope.app/Contents/MacOS/MacScope) or pass executable=."
            )
        self.binary = binary
        self._client = _MCPClient(
            exe, binary, startup_timeout=startup_timeout, request_timeout=request_timeout
        )

    # -- lifecycle --
    def __enter__(self) -> "Document":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    def close(self) -> None:
        self._client.close()

    # -- generic access (covers every command, incl. ones without a named method) --
    def command(self, name: str, /, **arguments: Any) -> Any:
        """Invoke any scripting command by name; keyword args become its arguments.

        ``name`` is positional-only so a command that itself takes a ``name`` argument
        (e.g. ``resolve-symbol``) doesn't collide. ``None`` omits a top-level argument;
        ``JSON_NULL`` sends an explicit null. Nested values use normal JSON encoding."""
        encoded = {
            key: None if value is JSON_NULL else value
            for key, value in arguments.items()
            if value is not None
        }
        return _coerce(self._client.call(name, encoded))

    def run_script(self, steps: list, *, preserve_nulls: bool = False) -> list:
        """Run a batch of ``{"command": ..., "arguments": {...}}`` steps, returning each
        result in order.

        By default, top-level ``None`` argument values are omitted, preserving the
        existing Python API. Set ``preserve_nulls=True`` for steps loaded from JSON
        when explicit null values must reach the command. In that mode, omit the
        key to preserve an existing value; null may clear it or be rejected by the
        command. ``JSON_NULL`` explicitly sends null in either mode.
        """
        results = []
        for step in steps:
            arguments = step.get("arguments")
            if arguments is None:
                arguments = {}
            if not isinstance(arguments, dict):
                raise TypeError("script step arguments must be an object or null")
            encoded = {
                key: JSON_NULL if preserve_nulls and value is None else value
                for key, value in arguments.items()
            }
            results.append(self.command(step["command"], **encoded))
        return results

    def commands(self) -> list:
        """Introspect the available commands."""
        return self.command("commands")

    # -- queries --
    def info(self) -> dict:
        return self.command("info")

    def functions(self, limit: Optional[int] = None) -> list:
        return self.command("functions", limit=limit)

    def instructions(self, function: Optional[str] = None, address: Any = None, count: Optional[int] = None) -> list:
        return self.command("instructions", function=function, address=_addr(address), count=count)

    def symbols(self, limit: Optional[int] = None) -> list:
        return self.command("symbols", limit=limit)

    def strings(self, limit: Optional[int] = None) -> list:
        return self.command("strings", limit=limit)

    def imports(self, limit: Optional[int] = None) -> list:
        return self.command("imports", limit=limit)

    def exports(self, limit: Optional[int] = None) -> list:
        return self.command("exports", limit=limit)

    def sections(self, limit: Optional[int] = None) -> list:
        return self.command("sections", limit=limit)

    def xrefs(self, to: Any = None, from_: Any = None) -> list:
        return self.command("xrefs", to=_addr(to), **{"from": _addr(from_)})

    def callers(self, function: Optional[str] = None, address: Any = None) -> list:
        return self.command("callers", function=function, address=_addr(address))

    def callees(self, function: Optional[str] = None, address: Any = None) -> list:
        return self.command("callees", function=function, address=_addr(address))

    def basic_blocks(self, function: Optional[str] = None, address: Any = None) -> list:
        return self.command("basic-blocks", function=function, address=_addr(address))

    def decompile(self, function: Optional[str] = None, address: Any = None, image: Any = None) -> str:
        """Pseudocode for a function (by name or address) as a string. Reads the primary image
        unless ``image`` (a slot index or an image-owner ID) selects another loaded image."""
        result = self.command("decompile", function=function, address=_addr(address), image=image)
        return result["pseudocode"] if result else ""

    def resolve_symbol(self, name: str) -> Optional[int]:
        """The address of a symbol by name, or None if unresolved."""
        return _as_address(self.command("resolve-symbol", name=name))

    def name_at(self, address: Any) -> Optional[str]:
        return self.command("name-at", address=_addr(address))

    def list_types(self) -> list:
        return self.command("list-types")

    def search(self, query: str, mode: Optional[str] = None) -> Any:
        return self.command("search", query=query, mode=mode)

    def read_bytes(self, address: Any, count: int = 16, image: Any = None) -> bytes:
        """Read raw bytes at a virtual address. Returns a ``bytes`` object. Reads the primary
        image unless ``image`` (a slot index or an image-owner ID) selects another loaded image."""
        result = self.command("read-bytes", address=_addr(address), count=count, image=image)
        return bytes.fromhex(result["hex"]) if result and result.get("hex") else b""

    # -- mutations (undoable in the live session; not persisted) --
    def rename(self, address: Any, name: str) -> Any:
        return self.command("rename", address=_addr(address), name=name)

    def set_comment(self, address: Any, comment: str) -> Any:
        return self.command("set-comment", address=_addr(address), comment=comment)

    def set_tag(self, address: Any, tag: str) -> Any:
        return self.command("set-tag", address=_addr(address), tag=tag)

    def set_type(self, address: Any, type: str) -> Any:
        return self.command("set-type", address=_addr(address), type=type)

    def set_color(self, address: Any, color: str) -> Any:
        return self.command("set-color", address=_addr(address), color=color)

    def make_data(self, address: Any, is_data: bool = True) -> Any:
        return self.command("make-data", address=_addr(address), isData=is_data)

    def define_type(self, kind: Optional[str], name: str, fields: Optional[list] = None) -> Any:
        # None omits the argument, which keeps an existing type's kind/fields.
        return self.command("define-type", kind=kind, name=name, fields=fields)

    def goto(self, query: str) -> Any:
        return self.command("goto", query=query)


def open(  # noqa: A001 (deliberate module-level open)
    binary: str,
    executable: Optional[str] = None,
    *,
    startup_timeout: Any = _UNSET,
    request_timeout: Any = _UNSET,
) -> Document:
    """Open a binary for analysis. Returns a :class:`Document` (usable as a context manager).

    ``startup_timeout`` bounds spawn + analysis + handshake (default
    ``$MACSCOPE_STARTUP_TIMEOUT`` or :data:`DEFAULT_STARTUP_TIMEOUT`); ``request_timeout``
    bounds each later call (``$MACSCOPE_REQUEST_TIMEOUT`` or
    :data:`DEFAULT_REQUEST_TIMEOUT`). ``None`` disables a deadline explicitly."""
    return Document(
        binary,
        executable=executable,
        startup_timeout=startup_timeout,
        request_timeout=request_timeout,
    )
