# Ghostty External-I/O Private ABI — Contract v1

Scope: GST-01 Task 2. Private ABI between MacScope's host layer and the
patched Ghostty full surface. Not a public Ghostty API.

- ABI version constant: `GHOSTTY_EXTERNAL_IO_ABI_VERSION = 1`
- Authoritative implementation: `src/termio/External.zig` (patched tree)
- Header: `include/ghostty.h` (typedef block + prototypes)
- Baseline: Ghostty `f64f4aca2c29b554d111b36c3d946a9bddd159ff` (1.3.2-dev)
- Patched head: `a6e4b2901e12865556157b8636bfff370b366b20`
  (repository snapshot tree `de6cd65b35a423d5d6854c6af3a90be20a52d7eb`)

## 1. Exported functions

```c
ghostty_surface_t ghostty_surface_new_external(
    ghostty_app_t app,
    const ghostty_surface_config_s* config,
    const ghostty_external_io_config_s* external);

ghostty_external_io_result_e ghostty_surface_external_feed(
    ghostty_surface_t surface, const uint8_t* bytes, size_t len);

ghostty_external_io_result_e ghostty_surface_external_set_process_state(
    ghostty_surface_t surface, const ghostty_external_process_state_s* state);

bool ghostty_surface_is_external_io(ghostty_surface_t surface);
```

`ghostty_surface_free` gains external-aware behavior: it unregisters the
handle and drains in-flight external calls before any teardown begins.
It is a no-op change for ordinary surfaces.

## 2. Versioning and struct evolution

Every ABI struct is size-prefixed and versioned:

- `struct_size` must be `>= sizeof` the v1 struct. A larger struct from a
  future revision is accepted and only the v1 prefix is read.
- `abi_version` must equal `GHOSTTY_EXTERNAL_IO_ABI_VERSION` (1).
- Fail closed: a null required pointer, undersized struct, unknown
  version, invalid enum value, or impossible pointer/length combination
  causes `ghostty_surface_new_external` to return `NULL` without
  creating anything, and the other calls to return
  `GHOSTTY_EXTERNAL_IO_INVALID` without consuming anything.

Struct layouts (arm64 macOS, verified by an in-tree test against the
compiler-translated header):

- `ghostty_external_io_config_s` (56 bytes): `struct_size` (size_t),
  `abi_version` (uint32 + 4 pad), `userdata`, `write_cb`, `resize_cb`,
  `close_cb`, `health_cb` (pointers).
  Required: `write_cb`, `resize_cb`, `close_cb`. Optional: `health_cb`.
- `ghostty_external_process_state_s` (24 bytes): `struct_size` (size_t),
  `abi_version` (uint32), `state` (int32), `exit_code` (uint32),
  `signal` (uint32).

## 3. Result values

`ghostty_external_io_result_e`:

| Value | Meaning |
|---|---|
| `ACCEPTED` (0) | The entire input was consumed. |
| `BACKPRESSURED` (1) | Nothing consumed; a bounded queue is full. Retry later (see `FEED_READY`). |
| `CLOSED` (2) | Nothing consumed; session is closed (terminal process state reported, or destruction has begun). |
| `INVALID` (3) | Nothing consumed; argument/version/enum/length validation failed, including a feed larger than total queue capacity (which could never succeed). |
| `INTERNAL_ERROR` (4) | Nothing consumed; internal failure (e.g. allocation). |

A feed is all-or-nothing. There is no partial consumption in any code
path.

## 4. Buffer ownership

- `feed` copies any bytes it retains before returning; the caller's
  buffer is never referenced afterwards.
- Every callback buffer (write callback bytes) is valid only for the
  duration of the callback; the host must copy anything it retains.
- Zero-length feed is harmless, consumes nothing, and reports the
  session state (`ACCEPTED` while running, `CLOSED` after closure).
- Pointer/length validation happens before any allocation or queue
  mutation; `bytes == NULL` with `len > 0` is `INVALID`.

## 5. Queues and backpressure (explicit capacities)

Per surface, ABI v1 fixed capacities (`termio.External.Limits`):

| Queue | Capacity | Overflow behavior |
|---|---|---|
| Inbound mailbox (host → terminal) | 1 MiB total bytes AND 1024 chunks | Feed returns `BACKPRESSURED`, consumes nothing. A single feed larger than 1 MiB returns `INVALID`. |
| Pending output (terminal → host retry buffer) | 256 KiB | Output channel permanently fails: one `OUTPUT_OVERFLOW` health event, pending bytes dropped (never silently: the event carries the byte count), subsequent output suppressed with one `OUTPUT_SUPPRESSED` event. |
| Surface registry | 64 simultaneous external surfaces | `ghostty_surface_new_external` fails (NULL). |

Backpressure recovery: after a feed was rejected `BACKPRESSURED`, the
next full drain of the inbound mailbox emits one `FEED_READY` health
event (detail = total capacity); a retry then succeeds and bytes are
processed exactly once, in order.

## 6. Ordering and chunking

- Concurrent `feed` callers are linearized by the mailbox lock; the
  accepted-feed order is a total order, and bytes enter Ghostty's stream
  parser in exactly that order, only ever on the termio io thread.
- Chunk boundaries carry no semantics: any split of the same byte
  stream into accepted feeds yields equivalent terminal state
  (incomplete UTF-8 sequences and escape sequences remain buffered by
  the stream parser and complete when the remaining bytes arrive).
- Terminal-generated output is delivered to the write callback exactly
  once and in order. Byte identity is preserved exactly; the only
  transformation is termio's pre-existing linefeed-mode semantic
  (mode 20: `\r` → `\r\n`), implemented byte-for-byte identically to
  the exec backend.

## 7. Callback threading and reentrancy

- All four callbacks (write, resize, close, health) are invoked on the
  termio io thread, never with any internal lock held.
- During `ghostty_surface_new_external` no callback is invoked.
- `feed` / `set_process_state` / `is_external_io` may be called from
  any host thread, including from inside a callback (they only enqueue
  or read state).
- Callbacks must NOT call `ghostty_surface_free`, and no host thread
  the io thread could be waiting on may block on `ghostty_surface_free`
  (the free path joins the io thread).
- `set_process_state` and `feed` never invoke callbacks synchronously;
  resulting close/health events are delivered by the io thread.

## 8. Write-callback backpressure policy

The write callback returns a result value:

- `ACCEPTED`: bytes were consumed by the host.
- `BACKPRESSURED`: nothing consumed. Ghostty retains the bytes in the
  bounded pending-output buffer (FIFO, behind nothing) and retries on
  every subsequent backend activity tick (next write, next inbound
  drain, focus change). One `OUTPUT_BACKPRESSURED` health event is
  emitted per episode. Ghostty never spins, blocks, or drops silently.
- `CLOSED` (or any out-of-range value, which fails closed): the output
  channel is permanently unavailable; pending bytes are dropped with an
  observable `OUTPUT_SUPPRESSED` health event and subsequent generated
  output is suppressed (single latched event).

## 9. Resize proposals

- The resize callback receives the exact computed grid (columns, rows)
  and pixel (width, height) values; Ghostty never resizes a PTY.
- The proposal precedes the terminal grid applying the new size.
- Consecutive identical proposals are coalesced (documented duplicate
  suppression only; a changed geometry always fires).
- The construction geometry is the baseline: the host created the
  surface at that size, so only post-construction changes are proposed.
- Zero or overflowing dimensions are rejected before any callback.
- After session closure, geometry proposals are suppressed.

## 10. Host lifecycle state

`set_process_state` transitions (validated, host-owned; Ghostty never
fabricates process identity or metadata — `getProcessInfo` reports
null/unavailable in external mode, and `ghostty_surface_process_exited`
remains host-tracked):

- `RUNNING → RUNNING`: idempotent no-op, `ACCEPTED`.
- `RUNNING → EXITED/SIGNALED/CLOSED`: latches. The final screen and
  scrollback are preserved untouched. Feeds return `CLOSED` from that
  point (the host must deliver trailing output before reporting a
  terminal state). Exactly one close callback is delivered from the io
  thread, after previously accepted feeds have parsed:
  `HOST_EXITED` / `HOST_SIGNALED` / `HOST_CLOSED`.
- Terminal → `RUNNING`: `INVALID` (terminal states never regress).
- Terminal → identical terminal state: idempotent `ACCEPTED` (no second
  close callback).
- Terminal → `CLOSED`: `ACCEPTED` no-op escalation (first terminal
  state stays authoritative).
- Terminal → contradictory terminal state (different exit code/signal
  or exited↔signaled): `INVALID`.

Ghostty-originated close requests (e.g. a close keybind) are delivered
through the same close callback with `CLOSE_SURFACE_REQUEST`; the
app-level `close_surface_cb` is not used for external surfaces. The
close callback fires at most once per surface, whichever cause occurs
first.

## 11. Destruction

`ghostty_surface_free(surface)` on an external surface:

1. Unregisters the handle: `feed`/`set_process_state` return `CLOSED`
   and `is_external_io` returns false from this point, and none of them
   ever touch surface memory (they operate on a refcounted shared state
   looked up in a registry).
2. Waits for in-flight external calls to drain (they never block, so
   this wait is bounded by the longest in-flight call).
3. Runs the normal surface teardown, which joins the io thread before
   the termio/backend state is deinitialized.

Guarantees: no callback occurs after `ghostty_surface_free` returns; a
callback in flight during the free never touches freed state; feed /
set_process_state / is_external_io may race the free arbitrarily. The
shared state is freed when its last reference drops.

Do not call `ghostty_surface_free` from a callback. Free all external
surfaces before `ghostty_app_free`.

## 12. Error semantics summary

Every failure is explicit: results for host-initiated calls, health
events for asynchronous conditions (edge-triggered, latched, bounded —
one event per condition episode, never per byte). Nothing is silently
discarded; the only byte drops are the two documented, health-reported
output-channel failure cases (§5, §8), and post-closure generated
output (§10, one `OUTPUT_SUPPRESSED` event), matching the exec
backend's post-exit write suppression but observable.
