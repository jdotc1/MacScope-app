# macscope — Python client for MacScope

A thin, **dependency-free** Python client for the [MacScope](../) binary-analysis workbench. It
spawns a headless `MacScope --mcp <binary>` subprocess and talks to it over MCP
(JSON-RPC 2.0 / stdio), exposing the analysis command surface as a Pythonic API.

Nothing is embedded in the app and there is no native extension to build — MacScope does the
analysis, this just drives it. Pure standard library; works with CPython ≥ 3.9.

## Install

```sh
pip install -e MacScope/python          # or copy the macscope/ package onto your path
```

Point the client at a built MacScope executable (one of):

```sh
export MACSCOPE_BINARY="/path/to/MacScope.app/Contents/MacOS/MacScope"
# …or pass executable="…" to macscope.open(), or put `MacScope` on your PATH.
```

## Usage

```python
import macscope

with macscope.open("/bin/ls") as doc:
    print(doc.info())                       # {'name': 'ls', 'functionCount': 50, ...}

    for f in doc.functions(limit=5):
        print(hex(f.address), f.name)        # addresses come back as ints

    print(doc.read_bytes(0x100000700, 16).hex())   # -> bytes
    print(doc.decompile(function="sub_0x0000000100000700"))

    for s in doc.sections():
        print(s.name, hex(s.address), "zerofill" if s.zeroFill else "")

    doc.rename(0x100000700, "_start")        # undoable edit in the live session
    print(doc.name_at(0x100000700))          # -> "_start"
```

Every result is made Pythonic: `"0x…"` address strings become `int`s and JSON objects
become attribute-accessible records (`f.name` ≡ `f["name"]`).

### Any command, and batches

`doc.command(name, **arguments)` invokes any of MacScope's commands directly (use
`doc.commands()` to list them), and `doc.run_script([...])` runs a batch:

```python
doc.command("set-color", address=0x100000700, color="red")
doc.run_script([
    {"command": "info"},
    {"command": "functions", "arguments": {"limit": 3}},
])
```

## Notes

- Mutations (`rename`, `set_comment`, `set_type`, …) apply to the **live in-memory session**
  and are undoable, but are **not** persisted — the headless server analyzes fresh and exits.
- The client is a single file (`macscope/__init__.py`) with no third-party dependencies.

### Deadlines, failures and concurrency

Every exchange with the server is bounded by a monotonic deadline:

| Deadline | Covers | Default | Override |
| --- | --- | --- | --- |
| `startup_timeout` | spawn, analysis of the binary, MCP handshake | 300 s | `open(..., startup_timeout=)` or `$MACSCOPE_STARTUP_TIMEOUT` |
| `request_timeout` | one call: waiting for the client, writing, reading the response | 120 s | `open(..., request_timeout=)` or `$MACSCOPE_REQUEST_TIMEOUT` |

`None` (or the env value `none`) disables a deadline. Large binaries take longer to analyze
before the handshake completes, so raise `startup_timeout` for them.

If a deadline expires, the server exits, or its stdin pipe breaks, the client is **retired**:
the server process is stopped and reaped, and `MacScopeTimeoutError` or
`MacScopeTransportError` (both subclasses of `MacScopeError`) is raised. The error has these fields:
`phase` (`"startup"` or `"request"`), `method`, `request_id`, `tool`, `stage`
(`"queue"`, `"write"` or `"read"`) and `outcome_unknown`. Nothing is retried. When
`outcome_unknown` is true, the server may have applied the call. Check the result in a new
session before you repeat a mutation. Open a new `Document` to continue.

Each client runs one request at a time. Calls from several threads are serialized, and the
wait counts against each call's own `request_timeout`. `close()` from another thread stops
the server, so the in-flight call fails promptly.

### Response-frame byte limit

Every physical stdout line is limited to **8,388,608 bytes (8 MiB), excluding the terminating
LF**, before accumulation or UTF-8/JSON decoding. This matches
`MCPServer.Configuration.production.maximumOutputBytes`: `encodeBounded` caps the serialized
JSON payload, `MCPRequestSession.restoringID` rechecks the final payload after restoring its
request ID, and `HeadlessProtocolIO.writeLine` adds LF separately. An exactly-at-limit line
plus LF is accepted. Whitespace, malformed/non-JSON noise and notifications count too; UTF-8
is counted in bytes, not characters.

The reader retains at most one capped incomplete line plus a fixed **65,536-byte read
chunk**. Coalesced lines are checked individually, and UTF-8 can span reads. Producing a
completed line and decoding it can temporarily allocate additional bounded copies and
Python objects; this framing bound excludes allocation overhead and is not a total RSS
or total interpreter memory claim.

An oversized line raises `MacScopeTransportError` during `read` and retires/stops/reaps the
owned child through the existing failure path. If the request was sent, `outcome_unknown`
remains true, including for mutations: an unreadable response does not prove the operation
failed. The client never retries, and later calls on that client fail before writing.
The cap cannot be disabled by disabling a deadline. No new client configuration is added:
the supported production server uses 8 MiB, and supplied alternate native test configurations
use smaller 512/8,192-byte payload limits. A custom server that emits larger physical lines
is not supported by this client; the native/wire contract is unchanged.

## Tests

```sh
python Scripts/ci/run_python_client_tests.py  # portable suite: stdlib only, no MacScope build
MACSCOPE_NATIVE_TEST_RECEIPT=<run-root>/candidate-artifacts/NativeLivePreparation.receipt.json \
  python -m pytest MacScope/python/tests      # adds the native suite
```

The portable suite (protocol, explicit-null, coercion, real-subprocess teardown, deadline, and
native-binding tests) runs in the hosted Governance workflow. `tests/test_macscope.py` is the
native-only end-to-end suite and is excluded there by name. It compiles
`tests/fixtures/native_client_fixture.c` with `xcrun clang -arch arm64`, derives expected
names and addresses with `nm`, and drives the headless `MacScope --mcp` server against it.
Its executable comes only from a qualification preparation receipt
(`MACSCOPE_NATIVE_TEST_RECEIPT`) or an explicit `MACSCOPE_NATIVE_TEST_EXECUTABLE` +
`MACSCOPE_NATIVE_TEST_EXECUTABLE_SHA256` pair, and its SHA-256 must match the recorded
digest. Without a binding the suite skips with that reason; an invalid binding fails.

`python -B MacScope/python/tests/test_response_frames.py` runs only the focused DOT-65
response-framing topic with tiny (512-byte) fixture caps and real owned Python child
processes through the production pipe transport. It does not launch native MacScope or run
the existing deadline/teardown suites. The fake child source is embedded in that test file.
