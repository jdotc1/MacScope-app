//! External is a termio backend that is fed already-authorized terminal
//! output bytes by an embedding host and that returns terminal-generated
//! input bytes, grid/pixel resize proposals, and session lifecycle
//! notifications to the host through versioned C ABI callbacks.
//!
//! In this mode Ghostty owns terminal emulation and rendering only. The
//! host owns the process: this backend never launches, owns, resizes,
//! reads from, writes to, signals, or waits for a child process or PTY.
//! In particular there is no use of fork/exec/posix_spawn, no openpty,
//! no ioctl(TIOCSWINSZ), no direct PTY writes, no child signaling and no
//! child waiting anywhere in this file, and no `Exec` state is ever
//! constructed for an external surface.
//!
//! ## Data flow
//!
//!   host --(feed: copied bytes)--> bounded inbound mailbox --(io thread)-->
//!     Termio.processOutput --> terminal state
//!
//!   terminal --(queueWrite on io thread)--> host write callback
//!   surface resize --(io thread)--> host resize callback
//!   host process state / surface close --> host close callback (io thread)
//!
//! ## Threading contract (ABI v1)
//!
//!   - `feed`, `setProcessState`, and `isExternal` may be called from any
//!     host thread. They only touch the shared state object, never the
//!     surface, so they are safe to race with surface destruction.
//!   - Every host callback (write, resize, close, health) is invoked on
//!     Ghostty's termio io thread, never while any internal lock is held.
//!   - Callback buffers are valid only for the duration of the callback;
//!     the receiver must copy anything it retains.
//!   - No callback is invoked after surface destruction has completed:
//!     destruction joins the io thread before the shared state is released.
//!   - Callbacks must not call `ghostty_surface_free` or block on a thread
//!     that does. Calling `feed`/`setProcessState` from within a callback
//!     is allowed (they only enqueue work).
pub const External = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const compat_thread = @import("../lib/compat/thread.zig");

const log = std.log.scoped(.io_external);

/// The refcounted state shared with the C ABI entry points. Owned
/// references: this backend, the surface registry entry, and the io
/// thread data while the thread runs.
shared: *Shared,

/// The last geometry proposed to the host (or the construction geometry
/// before any proposal). Identical consecutive proposals are coalesced;
/// this never suppresses a geometry change. Only touched during init and
/// then from the io thread, so it needs no lock.
last_grid: ?renderer.GridSize = null,
last_screen: ?renderer.ScreenSize = null,

/// The private external-I/O ABI version implemented by this file. This
/// must match `GHOSTTY_EXTERNAL_IO_ABI_VERSION` in include/ghostty.h.
pub const abi_version: u32 = 1;

/// Result codes returned across the C ABI.
/// C type: ghostty_external_io_result_e
pub const Result = enum(c_int) {
    /// The full input was accepted. Feeds are all-or-nothing; there is
    /// no partial consumption.
    accepted = 0,
    /// Nothing was consumed because a bounded queue is full. The call may
    /// be retried after capacity is released (see HealthEvent.feed_ready).
    backpressured = 1,
    /// Nothing was consumed because the session is closed (host reported a
    /// terminal process state, or the surface is being destroyed).
    closed = 2,
    /// Invalid arguments: bad version, undersized struct, null required
    /// pointer, invalid enum value, or an impossible pointer/length
    /// combination. Nothing was consumed.
    invalid = 3,
    /// An internal failure (e.g. allocation failure). Nothing was consumed.
    internal_error = 4,
};

/// Host-reported process lifecycle states.
/// C type: ghostty_external_process_state_e
pub const ProcessStateKind = enum(c_int) {
    running = 0,
    exited = 1,
    signaled = 2,
    closed = 3,
};

/// The reason for a close callback.
/// C type: ghostty_external_close_reason_e
pub const CloseReason = enum(c_int) {
    /// The host reported a normal exit via setProcessState.
    host_exited = 0,
    /// The host reported a signaled/abnormal exit via setProcessState.
    host_signaled = 1,
    /// The host reported the session closed/unavailable via setProcessState.
    host_closed = 2,
    /// Ghostty requests that the host close this surface/session (e.g. a
    /// close keybind or surface close request inside Ghostty).
    surface_request = 3,
};

/// Bounded health/diagnostic events. Each event is edge-triggered and
/// latched so a single condition produces a single callback, never a
/// per-byte or per-call stream.
/// C type: ghostty_external_health_event_e
pub const HealthEvent = enum(c_int) {
    /// The inbound mailbox fully drained after a feed had been rejected
    /// with `backpressured`. A retry is likely to succeed now.
    feed_ready = 0,
    /// The host write callback reported backpressure; the bytes are held
    /// in the bounded pending-output buffer and will be retried.
    output_backpressured = 1,
    /// The pending-output buffer overflowed; the output channel has
    /// failed permanently and subsequent generated output is discarded
    /// (reported once via output_suppressed).
    output_overflow = 2,
    /// Terminal-generated output was discarded because the session is
    /// closed or the output channel failed. Reported once.
    output_suppressed = 3,
};

/// Host write callback: terminal-generated bytes for the host to deliver
/// to its session. The buffer is only valid during the call. The host
/// returns a `Result` value: `accepted`, `backpressured` (nothing
/// consumed, Ghostty retains the bytes in a bounded buffer and retries),
/// or `closed` (output channel permanently unavailable). The return is
/// typed as the raw C integer so an out-of-range value from the host
/// fails closed (treated as `closed`) instead of being undefined.
pub const WriteFn = *const fn (
    ?*anyopaque,
    [*]const u8,
    usize,
) callconv(.c) c_int;

/// Host resize callback: proposed grid size (columns, rows) and pixel
/// size (width, height) whenever the surface computes a new geometry.
/// Ghostty never resizes a PTY itself in external mode.
pub const ResizeFn = *const fn (
    ?*anyopaque,
    u16,
    u16,
    u32,
    u32,
) callconv(.c) void;

/// Host close callback: a session lifecycle notification (host-reported
/// terminal state echoed back after processing) or a Ghostty-originated
/// surface close request. Invoked at most once per surface.
pub const CloseFn = *const fn (
    ?*anyopaque,
    CloseReason,
) callconv(.c) void;

/// Optional host health callback. `detail` is the byte count associated
/// with the event (free capacity for feed_ready, pending/dropped bytes
/// for output events).
pub const HealthFn = *const fn (
    ?*anyopaque,
    HealthEvent,
    u64,
) callconv(.c) void;

/// C ABI: ghostty_external_io_config_s (ABI v1).
///
/// Size-prefixed and versioned. `struct_size` must be at least
/// `@sizeOf(CConfig)`; larger values are allowed for forward
/// compatibility and only the v1 prefix is read.
pub const CConfig = extern struct {
    struct_size: usize,
    abi_version: u32,
    userdata: ?*anyopaque,
    write_cb: ?WriteFn,
    resize_cb: ?ResizeFn,
    close_cb: ?CloseFn,
    health_cb: ?HealthFn,
};

/// C ABI: ghostty_external_process_state_s (ABI v1).
///
/// Size-prefixed and versioned like CConfig. `state` is validated
/// against ProcessStateKind and invalid values fail closed.
pub const CProcessState = extern struct {
    struct_size: usize,
    abi_version: u32,
    state: c_int,
    exit_code: u32,
    signal: u32,
};

/// The validated host callback configuration. Constructing this from the
/// C struct is the fail-closed ABI boundary: unknown versions, undersized
/// structs, and null required callbacks are all rejected here before any
/// surface state exists.
pub const HostConfig = struct {
    userdata: ?*anyopaque = null,
    write_cb: WriteFn,
    resize_cb: ResizeFn,
    close_cb: CloseFn,
    health_cb: ?HealthFn = null,

    pub fn fromC(ptr_: ?*const CConfig) error{Invalid}!HostConfig {
        const ptr = ptr_ orelse return error.Invalid;

        // The struct must cover at least the v1 prefix. A larger struct
        // from a future revision is accepted and only the v1 prefix is
        // read; a smaller struct is rejected.
        if (ptr.struct_size < @sizeOf(CConfig)) return error.Invalid;
        if (ptr.abi_version != abi_version) return error.Invalid;

        return .{
            .userdata = ptr.userdata,
            .write_cb = ptr.write_cb orelse return error.Invalid,
            .resize_cb = ptr.resize_cb orelse return error.Invalid,
            .close_cb = ptr.close_cb orelse return error.Invalid,
            .health_cb = ptr.health_cb,
        };
    }
};

/// The validated host-reported process state.
pub const ProcessState = union(ProcessStateKind) {
    running: void,
    /// Normal exit with the host-supplied exit code.
    exited: u32,
    /// Signaled/abnormal exit with the host-supplied signal number.
    signaled: u32,
    /// The session is closed or unavailable without further detail.
    closed: void,

    pub fn fromC(ptr_: ?*const CProcessState) error{Invalid}!ProcessState {
        const ptr = ptr_ orelse return error.Invalid;
        if (ptr.struct_size < @sizeOf(CProcessState)) return error.Invalid;
        if (ptr.abi_version != abi_version) return error.Invalid;
        const kind = std.enums.fromInt(
            ProcessStateKind,
            ptr.state,
        ) orelse return error.Invalid;
        return switch (kind) {
            .running => .{ .running = {} },
            .exited => .{ .exited = ptr.exit_code },
            .signaled => .{ .signaled = ptr.signal },
            .closed => .{ .closed = {} },
        };
    }
};

/// Explicit, finite queue limits for one external surface. These are the
/// documented ABI v1 capacities; tests may construct smaller limits.
pub const Limits = struct {
    /// Maximum total bytes buffered in the inbound (host -> terminal)
    /// mailbox. A single feed larger than this can never be accepted and
    /// returns `invalid`; a feed that does not fit the current free space
    /// returns `backpressured` and consumes nothing.
    inbound_capacity_bytes: usize = 1024 * 1024,

    /// Maximum number of buffered inbound chunks. Bounds queue metadata
    /// independently of byte capacity.
    inbound_capacity_chunks: usize = 1024,

    /// Maximum bytes of terminal-generated output retained while the host
    /// write callback reports backpressure. Overflow fails the output
    /// channel permanently (health: output_overflow).
    pending_output_capacity_bytes: usize = 256 * 1024,
};

/// The refcounted state shared between the termio backend, the C ABI
/// surface registry, and transient host calls. Host-callable entry points
/// operate only on this object so that they can safely race with surface
/// destruction.
pub const Shared = struct {
    alloc: Allocator,
    limits: Limits,
    callbacks: HostConfig,

    /// Protects every mutable field below. Never held while a host
    /// callback is invoked.
    mutex: std.Io.Mutex = .init,

    /// Signaled when `pins` drops to zero (destruction gate).
    cond: std.Io.Condition = .init,

    /// Ownership references: termio backend, registry entry, io thread
    /// data, and one per transient pinned host call.
    refs: usize = 1,

    /// Transient host calls currently executing against this object.
    pins: usize = 0,

    /// Wakes the termio io thread to drain the inbound mailbox and
    /// deliver pending lifecycle events.
    wakeup: xev.Async,

    /// Bounded inbound mailbox: copied chunks in feed order.
    inbound: std.ArrayListUnmanaged([]u8) = .empty,
    inbound_bytes: usize = 0,

    /// Set when a feed was rejected for capacity; produces one
    /// feed_ready health event after the mailbox next fully drains.
    feed_backpressured: bool = false,

    /// Host-reported process lifecycle state.
    process: ProcessState = .running,

    /// Close notification latched for io-thread delivery, and whether the
    /// (at most one) close callback was already delivered.
    close_pending: ?CloseReason = null,
    close_delivered: bool = false,

    /// Once true, feeds are rejected with `closed`. Set by a terminal
    /// process state or by the start of surface destruction.
    feed_closed: bool = false,

    /// True while the termio io thread is attached (between threadEnter
    /// and threadExit). After detach no further callbacks are made.
    attached: bool = false,
    detached: bool = false,

    pub fn create(
        alloc: Allocator,
        callbacks: HostConfig,
        limits: Limits,
    ) !*Shared {
        const self = try alloc.create(Shared);
        errdefer alloc.destroy(self);

        var wakeup = try xev.Async.init();
        errdefer wakeup.deinit();

        self.* = .{
            .alloc = alloc,
            .limits = limits,
            .callbacks = callbacks,
            .wakeup = wakeup,
        };
        return self;
    }

    pub fn retain(self: *Shared) void {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.refs += 1;
    }

    pub fn release(self: *Shared) void {
        const io = global.io();
        const remaining = remaining: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            assert(self.refs > 0);
            self.refs -= 1;
            break :remaining self.refs;
        };
        if (remaining == 0) self.destroy();
    }

    fn destroy(self: *Shared) void {
        for (self.inbound.items) |chunk| self.alloc.free(chunk);
        self.inbound.deinit(self.alloc);
        self.wakeup.deinit();
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }

    /// Feed host-supplied bytes into the bounded inbound mailbox. The
    /// bytes are copied before this returns; the caller's buffer is never
    /// retained. The feed is all-or-nothing: either the entire buffer is
    /// enqueued (`accepted`) or nothing is consumed.
    pub fn feed(self: *Shared, bytes: []const u8) Result {
        const io = global.io();

        // A feed larger than total capacity can never succeed; reject it
        // as invalid (not backpressured) so the host does not retry
        // forever. This also bounds the arithmetic below.
        if (bytes.len > self.limits.inbound_capacity_bytes) return .invalid;

        var wake = false;
        const result: Result = result: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            if (self.feed_closed) break :result .closed;

            // An accepted zero-length feed is an explicit output-readiness
            // kick. It queues no terminal input, but waking the io thread
            // gives retained output one bounded retry opportunity.
            if (bytes.len == 0) {
                wake = true;
                break :result .accepted;
            }

            // Both operands are <= capacity so this sum cannot overflow.
            if (self.inbound_bytes + bytes.len > self.limits.inbound_capacity_bytes or
                self.inbound.items.len >= self.limits.inbound_capacity_chunks)
            {
                self.feed_backpressured = true;
                break :result .backpressured;
            }

            // Capacity and closure are checked while holding the admission
            // lock before allocating. Besides avoiding needless copies, this
            // bounds concurrent transient allocations to admitted mailbox
            // capacity and preserves the accepted-feed linearization order.
            const copy = self.alloc.dupe(u8, bytes) catch
                break :result .internal_error;
            self.inbound.append(self.alloc, copy) catch {
                self.alloc.free(copy);
                break :result .internal_error;
            };
            self.inbound_bytes += bytes.len;
            wake = true;
            break :result .accepted;
        };

        if (wake) {
            // If notify fails, queued bytes or the readiness kick remain
            // harmless and the next successful activity retries them.
            self.wakeup.notify() catch |err| log.warn(
                "external wakeup failed, queued activity waits for next wakeup err={}",
                .{err},
            );
        }
        return result;
    }

    /// Apply a validated host process state. Transitions are validated:
    /// terminal states latch, never regress to running, and repeated
    /// identical reports are idempotent.
    pub fn setProcessState(self: *Shared, state: ProcessState) Result {
        const io = global.io();
        var wake = false;
        const result: Result = result: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            switch (self.process) {
                .running => switch (state) {
                    // running -> running is an idempotent no-op.
                    .running => break :result .accepted,

                    // First terminal transition: latch the state, close
                    // the feed channel, and queue the close notification
                    // for io-thread delivery. The terminal screen and
                    // scrollback are intentionally left untouched.
                    .exited, .signaled, .closed => {
                        self.process = state;
                        self.feed_closed = true;
                        self.close_pending = switch (state) {
                            .running => unreachable,
                            .exited => .host_exited,
                            .signaled => .host_signaled,
                            .closed => .host_closed,
                        };
                        wake = true;
                        break :result .accepted;
                    },
                },

                .exited, .signaled, .closed => {
                    // Terminal states never regress to running.
                    if (state == .running) break :result .invalid;

                    // Identical repeated reports are idempotent.
                    if (std.meta.eql(self.process, state)) break :result .accepted;

                    // Escalation to closed/unavailable is accepted as a
                    // no-op; the first terminal state stays authoritative.
                    if (state == .closed) break :result .accepted;

                    // Contradictory terminal information fails closed.
                    break :result .invalid;
                },
            }
        };

        if (wake) self.wakeup.notify() catch |err| log.warn(
            "external wakeup failed, close delivery waits for next wakeup err={}",
            .{err},
        );
        return result;
    }

    /// Request that the host close this session (Ghostty-originated).
    /// Delivered at most once, on the io thread, like all callbacks.
    pub fn requestClose(self: *Shared) void {
        const io = global.io();
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.close_delivered or self.close_pending != null) return;
            self.close_pending = .surface_request;
        }
        self.wakeup.notify() catch |err| log.warn(
            "external wakeup failed, close delivery waits for next wakeup err={}",
            .{err},
        );
    }

    /// Deliver a health event outside any lock. No-op without a callback.
    fn healthEvent(self: *Shared, event: HealthEvent, detail: u64) void {
        const cb = self.callbacks.health_cb orelse return;
        cb(self.callbacks.userdata, event, detail);
    }
};

//-------------------------------------------------------------------
// Surface registry
//
// The C ABI entry points look surface handles up here instead of
// dereferencing them, which is what makes feed/setProcessState safe to
// race with ghostty_surface_free: a pinned entry keeps the Shared state
// alive, and beginDestroy waits for pins to drain after unregistering.

/// Maximum simultaneously registered external surfaces. Fixed so the
/// registry itself performs no allocation.
pub const registry_max_surfaces = 64;

const RegistryEntry = struct {
    key: *const anyopaque,
    shared: *Shared,
};

var registry_mutex: std.Io.Mutex = .init;
var registry_entries: [registry_max_surfaces]?RegistryEntry =
    @splat(null);

/// Register a surface handle. Retains `shared` until beginDestroy.
pub fn registryRegister(
    key: *const anyopaque,
    shared: *Shared,
) error{RegistryFull}!void {
    const io = global.io();
    shared.retain();
    errdefer shared.release();

    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);
    for (&registry_entries) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .key = key, .shared = shared };
            return;
        }
    }
    return error.RegistryFull;
}

/// Look up and pin the shared state for a surface handle. The caller
/// must call `unpin` when done. Returns null if the handle is not a
/// (live) external surface.
fn registryPin(key: *const anyopaque) ?*Shared {
    const io = global.io();
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);
    for (registry_entries) |slot| {
        const entry = slot orelse continue;
        if (entry.key == key) {
            entry.shared.mutex.lockUncancelable(io);
            defer entry.shared.mutex.unlock(io);
            entry.shared.refs += 1;
            entry.shared.pins += 1;
            return entry.shared;
        }
    }
    return null;
}

fn unpin(shared: *Shared) void {
    const io = global.io();
    {
        shared.mutex.lockUncancelable(io);
        defer shared.mutex.unlock(io);
        assert(shared.pins > 0);
        shared.pins -= 1;
        if (shared.pins == 0) shared.cond.broadcast(io);
    }
    shared.release();
}

/// True if the surface handle refers to a live external-I/O surface.
pub fn registryContains(key: *const anyopaque) bool {
    const io = global.io();
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);
    for (registry_entries) |slot| {
        const entry = slot orelse continue;
        if (entry.key == key) return true;
    }
    return false;
}

/// Begin surface destruction: unregister the handle so no new host call
/// can pin it, close the feed channel, and wait for in-flight pinned
/// calls to drain. After this returns, feed/setProcessState on the handle
/// return `closed` and never touch surface memory. Safe to call for
/// non-external surfaces (no-op). Callers must not invoke this from a
/// host callback (it would deadlock the io thread join that follows).
pub fn registryBeginDestroy(key: *const anyopaque) void {
    const io = global.io();

    const shared: *Shared = found: {
        registry_mutex.lockUncancelable(io);
        defer registry_mutex.unlock(io);
        for (&registry_entries) |*slot| {
            const entry = slot.* orelse continue;
            if (entry.key == key) {
                slot.* = null;
                break :found entry.shared;
            }
        }
        return;
    };

    {
        shared.mutex.lockUncancelable(io);
        defer shared.mutex.unlock(io);
        shared.feed_closed = true;

        // Pinned calls never block, so this wait is bounded by the
        // longest in-flight feed/setProcessState call.
        while (shared.pins > 0) shared.cond.waitUncancelable(io, &shared.mutex);
    }

    // Release the registry's ownership reference.
    shared.release();
}

//-------------------------------------------------------------------
// C ABI entry points (called from apprt CAPI wrappers)

/// Feed host bytes to the surface identified by `key`. See Shared.feed.
pub fn feedSurface(
    key: ?*const anyopaque,
    bytes: ?[*]const u8,
    len: usize,
) Result {
    const k = key orelse return .invalid;

    // An impossible pointer/length combination is invalid before any
    // queue state is examined.
    const slice: []const u8 = if (len > 0) slice: {
        const ptr = bytes orelse return .invalid;
        break :slice ptr[0..len];
    } else &.{};

    const shared = registryPin(k) orelse return .closed;
    defer unpin(shared);
    return shared.feed(slice);
}

/// Apply a host-reported process state to the surface identified by `key`.
pub fn setProcessStateSurface(
    key: ?*const anyopaque,
    state: ?*const CProcessState,
) Result {
    const k = key orelse return .invalid;
    const validated = ProcessState.fromC(state) catch return .invalid;
    const shared = registryPin(k) orelse return .closed;
    defer unpin(shared);
    return shared.setProcessState(validated);
}

/// True if `key` refers to a live external-I/O surface.
pub fn isExternalSurface(key: ?*const anyopaque) bool {
    const k = key orelse return false;
    return registryContains(k);
}

//-------------------------------------------------------------------
// Termio backend implementation

/// Configuration for constructing the external backend. `host` must
/// already be validated (see HostConfig.fromC for the ABI boundary).
pub const Config = struct {
    host: HostConfig,
    limits: Limits = .{},
};

/// Initialize the external backend state. This never launches anything:
/// it only allocates the shared state and its wakeup handle.
pub fn init(alloc: Allocator, cfg: Config) !External {
    const shared = try Shared.create(alloc, cfg.host, cfg.limits);
    return .{ .shared = shared };
}

pub fn deinit(self: *External) void {
    self.shared.release();
}

/// Called before termio begins. Records the construction geometry as the
/// coalescing baseline: the host created the surface at this size, so
/// only post-construction changes are proposed through the callback.
pub fn initTerminal(self: *External, term: *terminal.Terminal) void {
    self.last_grid = .{ .columns = term.cols, .rows = term.rows };
    self.last_screen = .{ .width = term.width_px, .height = term.height_px };
}

/// The io-thread state for the external backend. All fields except
/// `shared` are owned exclusively by the io thread and need no lock.
pub const ThreadData = struct {
    shared: *Shared,
    io: *termio.Termio,
    wakeup_c: xev.Completion = .{},

    /// Bounded buffer of terminal-generated output retained while the
    /// host write callback reports backpressure. FIFO order is
    /// preserved: new output is appended behind pending output.
    pending: std.ArrayListUnmanaged(u8) = .empty,

    /// True once the output channel permanently failed (host reported
    /// closed/invalid, or the pending buffer overflowed).
    output_failed: bool = false,

    /// Edge-trigger latches so each condition produces one health event.
    notified_backpressure: bool = false,
    notified_suppressed: bool = false,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        self.pending.deinit(alloc);
        self.shared.release();
    }
};

pub fn threadEnter(
    self: *External,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;
    const io_z = global.io();

    // The thread data holds its own reference for the thread lifetime.
    self.shared.retain();
    errdefer self.shared.release();

    {
        self.shared.mutex.lockUncancelable(io_z);
        defer self.shared.mutex.unlock(io_z);
        self.shared.attached = true;
        self.shared.detached = false;
    }

    td.backend = .{ .external = .{ .shared = self.shared, .io = io } };

    // Wake up whenever the host feeds bytes or reports lifecycle state.
    self.shared.wakeup.wait(
        td.loop,
        &td.backend.external.wakeup_c,
        termio.Termio.ThreadData,
        td,
        wakeupCallback,
    );

    // Anything fed between surface construction and thread start must be
    // drained; self-notify so the first loop tick drains it.
    self.shared.wakeup.notify() catch |err| log.warn(
        "external initial wakeup failed, drain waits for next feed err={}",
        .{err},
    );
}

pub fn threadExit(self: *External, td: *termio.Termio.ThreadData) void {
    assert(td.backend == .external);
    const io_z = global.io();
    self.shared.mutex.lockUncancelable(io_z);
    defer self.shared.mutex.unlock(io_z);
    self.shared.attached = false;
    self.shared.detached = true;
}

fn wakeupCallback(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in external wakeup err={}", .{err});
        return .rearm;
    };
    const td = td_ orelse return .rearm;
    drainOnIoThread(td);
    return .rearm;
}

/// Drain the inbound mailbox into the terminal stream and deliver
/// pending lifecycle/health events. Runs only on the termio io thread;
/// tests may call this directly while playing the io-thread role.
pub fn drainOnIoThread(td: *termio.Termio.ThreadData) void {
    assert(td.backend == .external);
    const ext = &td.backend.external;
    const shared = ext.shared;
    const io_z = global.io();

    var chunks: std.ArrayListUnmanaged([]u8) = .empty;
    var deliver_close: ?CloseReason = null;
    var deliver_feed_ready = false;
    {
        shared.mutex.lockUncancelable(io_z);
        defer shared.mutex.unlock(io_z);

        std.mem.swap(
            std.ArrayListUnmanaged([]u8),
            &shared.inbound,
            &chunks,
        );
        shared.inbound_bytes = 0;

        if (shared.feed_backpressured) {
            shared.feed_backpressured = false;
            deliver_feed_ready = true;
        }

        if (shared.close_pending) |reason| {
            shared.close_pending = null;
            if (!shared.close_delivered) {
                shared.close_delivered = true;
                deliver_close = reason;
            }
        }
    }

    // Accepted feeds parse in their linearization (FIFO) order, and only
    // this thread ever passes bytes into the stream parser.
    for (chunks.items) |chunk| {
        ext.io.processOutput(chunk);
        shared.alloc.free(chunk);
    }
    chunks.deinit(shared.alloc);

    // Any activity is a chance to retry pending terminal output.
    flushPending(td);

    // Close/health delivery happens after the preceding accepted feeds
    // were parsed, outside all locks.
    if (deliver_close) |reason| {
        shared.callbacks.close_cb(shared.callbacks.userdata, reason);
    }
    if (deliver_feed_ready) {
        shared.healthEvent(
            .feed_ready,
            @intCast(shared.limits.inbound_capacity_bytes),
        );
    }
}

pub fn focusGained(
    self: *External,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = focused;

    // Focus report bytes (mode 1004) flow through queueWrite from
    // Termio.focusGained; there is no backend-specific focus state.
    // Use the activity tick to retry pending output.
    flushPending(td);
}

/// Propose a new geometry to the host. External mode never resizes a
/// PTY; the exact computed values are delivered to the resize callback.
pub fn resize(
    self: *External,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    // Reject impossible geometry before any callback is invoked.
    if (grid_size.columns == 0 or grid_size.rows == 0 or
        screen_size.width == 0 or screen_size.height == 0)
    {
        log.warn(
            "external resize rejected invalid geometry cols={} rows={} width={} height={}",
            .{ grid_size.columns, grid_size.rows, screen_size.width, screen_size.height },
        );
        return;
    }

    // Coalesce identical consecutive proposals. This only ever removes
    // exact duplicates, never a state transition.
    if (self.last_grid) |lg| if (self.last_screen) |ls| {
        if (lg.columns == grid_size.columns and lg.rows == grid_size.rows and
            ls.width == screen_size.width and ls.height == screen_size.height)
        {
            return;
        }
    };
    self.last_grid = grid_size;
    self.last_screen = screen_size;

    // After the session closed, geometry proposals are suppressed.
    if (closedForOutput(self.shared)) return;

    self.shared.callbacks.resize_cb(
        self.shared.callbacks.userdata,
        grid_size.columns,
        grid_size.rows,
        screen_size.width,
        screen_size.height,
    );
}

/// Deliver terminal-generated bytes to the host write callback. Must be
/// called from the io thread only (same contract as the exec backend).
/// Byte identity is preserved exactly; the only transformation is the
/// pre-existing termio linefeed-mode semantic (\r becomes \r\n), which
/// this implements byte-for-byte like the exec backend.
pub fn queueWrite(
    self: *External,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    assert(td.backend == .external);
    const ext = &td.backend.external;
    if (data.len == 0) return;

    // After the session closed or the output channel failed, generated
    // output is suppressed. This mirrors `.exec` behavior after exit but
    // is observable: the first suppression produces a health event.
    if (ext.output_failed or closedForOutput(ext.shared)) {
        notifySuppressedOnce(ext, data.len);
        return;
    }

    var stack_buf: [512]u8 = undefined;
    var owned: ?[]u8 = null;
    defer if (owned) |v| alloc.free(v);
    const out: []const u8 = if (!linefeed) data else translate: {
        // Worst case every byte is \r and the size doubles.
        const max = std.math.mul(usize, data.len, 2) catch
            return error.Overflow;
        const buf = if (max <= stack_buf.len) stack_buf[0..max] else buf: {
            const b = try alloc.alloc(u8, max);
            owned = b;
            break :buf b;
        };
        var i: usize = 0;
        for (data) |ch| {
            if (ch != '\r') {
                buf[i] = ch;
                i += 1;
                continue;
            }

            // CRLF
            buf[i] = '\r';
            buf[i + 1] = '\n';
            i += 2;
        }
        break :translate buf[0..i];
    };

    deliverOutput(td, out);
}

/// Vestigial Backend interface parity: the external backend never
/// launches a command, so there is nothing to report into the terminal.
pub fn childExitedAbnormally(
    self: *External,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

/// External sessions have no Ghostty-visible process. Process metadata is
/// host-owned; it is never fabricated here, so this always reports the
/// information as unavailable.
pub fn getProcessInfo(
    self: *External,
    comptime info: ProcessInfo,
) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

fn closedForOutput(shared: *Shared) bool {
    const io_z = global.io();
    shared.mutex.lockUncancelable(io_z);
    defer shared.mutex.unlock(io_z);
    return shared.feed_closed;
}

/// Invoke the host write callback with fail-closed result mapping: an
/// out-of-range return value is treated as `closed`.
fn invokeWrite(shared: *Shared, bytes: []const u8) Result {
    const raw = shared.callbacks.write_cb(
        shared.callbacks.userdata,
        bytes.ptr,
        bytes.len,
    );
    return std.enums.fromInt(Result, raw) orelse .closed;
}

fn notifySuppressedOnce(ext: *ThreadData, len: usize) void {
    if (ext.notified_suppressed) return;
    ext.notified_suppressed = true;
    ext.shared.healthEvent(.output_suppressed, @intCast(len));
}

fn notifyBackpressureOnce(ext: *ThreadData) void {
    if (ext.notified_backpressure) return;
    ext.notified_backpressure = true;
    ext.shared.healthEvent(
        .output_backpressured,
        @intCast(ext.pending.items.len),
    );
}

/// Permanently fail the output channel: drop the pending buffer and
/// report the failure through one health event. Never silent.
fn failOutput(
    td: *termio.Termio.ThreadData,
    event: HealthEvent,
    detail: usize,
) void {
    const ext = &td.backend.external;
    if (ext.output_failed) return;
    ext.output_failed = true;
    if (event == .output_suppressed) ext.notified_suppressed = true;
    ext.pending.clearAndFree(td.alloc);
    ext.shared.healthEvent(event, @intCast(detail));
}

/// Append bytes to the bounded pending-output buffer. Overflow
/// permanently fails the output channel (health: output_overflow).
fn appendPending(td: *termio.Termio.ThreadData, bytes: []const u8) void {
    const ext = &td.backend.external;
    if (ext.output_failed) return;
    const cap = ext.shared.limits.pending_output_capacity_bytes;
    if (bytes.len > cap or ext.pending.items.len + bytes.len > cap) {
        failOutput(td, .output_overflow, ext.pending.items.len + bytes.len);
        return;
    }
    ext.pending.appendSlice(td.alloc, bytes) catch {
        failOutput(td, .output_overflow, bytes.len);
    };
}

/// Deliver bytes to the host, preserving FIFO order with any pending
/// bytes. Exactly-once: bytes are either delivered via the callback or
/// retained in the bounded pending buffer, never duplicated.
fn deliverOutput(td: *termio.Termio.ThreadData, bytes: []const u8) void {
    const ext = &td.backend.external;
    if (bytes.len == 0) return;

    if (ext.pending.items.len > 0) {
        appendPending(td, bytes);
        flushPending(td);
        return;
    }

    switch (invokeWrite(ext.shared, bytes)) {
        .accepted => {},
        .backpressured => {
            appendPending(td, bytes);
            if (!ext.output_failed) notifyBackpressureOnce(ext);
        },
        .closed, .invalid, .internal_error => {
            failOutput(td, .output_suppressed, bytes.len);
        },
    }
}

/// Retry delivery of pending output. Called on every backend activity
/// tick (drain, focus, further writes); never spins or blocks.
fn flushPending(td: *termio.Termio.ThreadData) void {
    const ext = &td.backend.external;
    if (ext.output_failed or ext.pending.items.len == 0) return;

    if (closedForOutput(ext.shared)) {
        failOutput(td, .output_suppressed, ext.pending.items.len);
        return;
    }

    switch (invokeWrite(ext.shared, ext.pending.items)) {
        .accepted => {
            ext.pending.clearRetainingCapacity();
            // The backpressure episode is over; a new episode may
            // produce a new health event.
            ext.notified_backpressure = false;
        },
        .backpressured => {},
        .closed, .invalid, .internal_error => {
            failOutput(td, .output_suppressed, ext.pending.items.len);
        },
    }
}

//-------------------------------------------------------------------
// Tests
//
// The deterministic core: everything below runs single-threaded unless a
// test explicitly spawns producers, uses no wall-clock sleeps, and uses
// std.testing.allocator so leaks fail the test.

const testing = std.testing;
const configpkg = @import("../config.zig");
const apprt = @import("../apprt.zig");
const CoreApp = @import("../App.zig");

/// Real-thread test synchronization must fail in bounded time instead of
/// hanging the focused native suite indefinitely.
const test_thread_timeout: std.Io.Timeout = .{ .duration = .{
    .clock = .awake,
    .raw = .fromSeconds(10),
} };

fn waitTestEvent(event: *std.Io.Event) void {
    event.waitTimeout(global.io(), test_thread_timeout) catch |err| {
        std.debug.panic("external test thread wait failed: {}", .{err});
    };
}

/// Ensure the dynamic xev backend is selected (mirrors global.init).
fn testEnsureXev() void {
    if (comptime xev.dynamic) xev.detect() catch {};
}

/// Captures every host callback with scripted write results. Guarded by
/// a mutex so threaded tests can share it; single-threaded tests just
/// take the lock uncontended.
const TestCapture = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    writes: std.ArrayListUnmanaged(u8) = .empty,
    write_calls: usize = 0,

    /// Return backpressured for this many write calls before accepting.
    write_backpressure_remaining: usize = 0,
    /// If set, every write returns this raw result value.
    write_forced_result: ?c_int = null,

    resizes: std.ArrayListUnmanaged([4]u64) = .empty,
    closes: std.ArrayListUnmanaged(CloseReason) = .empty,
    healths: std.ArrayListUnmanaged(HealthRecord) = .empty,

    /// Optional final-frame ordering oracle. When set, closeCb observes
    /// the first terminal cell at callback time on the io thread.
    close_probe_terminal: ?*terminal.Terminal = null,
    close_saw_final_frame: bool = false,

    const HealthRecord = struct {
        event: HealthEvent,
        detail: u64,
    };

    fn init(alloc: Allocator) TestCapture {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *TestCapture) void {
        self.writes.deinit(self.alloc);
        self.resizes.deinit(self.alloc);
        self.closes.deinit(self.alloc);
        self.healths.deinit(self.alloc);
    }

    fn hostConfig(self: *TestCapture) HostConfig {
        return .{
            .userdata = self,
            .write_cb = writeCb,
            .resize_cb = resizeCb,
            .close_cb = closeCb,
            .health_cb = healthCb,
        };
    }

    fn cConfig(self: *TestCapture) CConfig {
        return .{
            .struct_size = @sizeOf(CConfig),
            .abi_version = abi_version,
            .userdata = self,
            .write_cb = writeCb,
            .resize_cb = resizeCb,
            .close_cb = closeCb,
            .health_cb = healthCb,
        };
    }

    fn fromUd(ud: ?*anyopaque) *TestCapture {
        return @ptrCast(@alignCast(ud.?));
    }

    fn writeCb(ud: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) c_int {
        const self = fromUd(ud);
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        defer self.cond.broadcast(io);
        self.write_calls += 1;
        if (self.write_forced_result) |forced| return forced;
        if (self.write_backpressure_remaining > 0) {
            self.write_backpressure_remaining -= 1;
            return @intFromEnum(Result.backpressured);
        }
        self.writes.appendSlice(self.alloc, ptr[0..len]) catch
            return @intFromEnum(Result.internal_error);
        return @intFromEnum(Result.accepted);
    }

    fn resizeCb(ud: ?*anyopaque, cols: u16, rows: u16, w: u32, h: u32) callconv(.c) void {
        const self = fromUd(ud);
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        defer self.cond.broadcast(io);
        self.resizes.append(self.alloc, .{ cols, rows, w, h }) catch {};
    }

    fn closeCb(ud: ?*anyopaque, reason: CloseReason) callconv(.c) void {
        const self = fromUd(ud);
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        defer self.cond.broadcast(io);
        if (self.close_probe_terminal) |term| {
            const cell = term.screens.active.pages.getCell(.{
                .active = .{ .x = 0, .y = 0 },
            });
            self.close_saw_final_frame = cell != null and
                cell.?.cell.codepoint() == 'f';
        }
        self.closes.append(self.alloc, reason) catch {};
    }

    fn healthCb(ud: ?*anyopaque, event: HealthEvent, detail: u64) callconv(.c) void {
        const self = fromUd(ud);
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        defer self.cond.broadcast(io);
        self.healths.append(self.alloc, .{ .event = event, .detail = detail }) catch {};
    }

    fn writesString(self: *TestCapture) []const u8 {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.writes.items;
    }

    /// Block until `pred(self)` is true, with one monotonic deadline for
    /// the entire wait. Event-driven; never a polling sleep.
    fn waitUntil(
        self: *TestCapture,
        ctx: anytype,
        pred: fn (@TypeOf(ctx), *TestCapture) bool,
    ) void {
        const io = global.io();
        const deadline = test_thread_timeout.toDeadline(io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!pred(ctx, self)) {
            compat_thread.waitTimeout(
                &self.cond,
                io,
                &self.mutex,
                deadline,
            ) catch |err| {
                std.debug.panic("external callback wait failed: {}", .{err});
            };
        }
    }
};

/// A headless Termio harness that plays the role of the surface, the
/// renderer, and (in manual mode) the io thread. It constructs the real
/// Termio state field-by-field exactly like Termio.init except for the
/// Kitty image temp-dir limit (which requires initialized global state
/// unavailable under `zig build test`); that limit is irrelevant to the
/// external backend contract under test.
const TestTermio = struct {
    alloc: Allocator,
    capture: *TestCapture,
    config: *configpkg.Config,
    renderer_mutex: *std.Io.Mutex,
    renderer_state: *renderer.State,
    renderer_wakeup: xev.Async,
    renderer_mailbox: *renderer.Thread.Mailbox,
    app_mailbox: *CoreApp.Mailbox.Queue,
    io: *termio.Termio,
    thread: *termio.Thread,
    td: *termio.Termio.ThreadData,
    linefeed_mode: bool = false,

    /// True when the harness plays the io thread itself (tick/drain).
    /// False when a real termio.Thread runs (threadEnter/threadExit and
    /// thread data are owned by that thread).
    manual: bool = true,

    const cell_w = 10;
    const cell_h = 20;

    fn init(
        alloc: Allocator,
        capture: *TestCapture,
        limits: Limits,
        cols: u16,
        rows: u16,
    ) !*TestTermio {
        return initMode(alloc, capture, limits, cols, rows, true);
    }

    fn initMode(
        alloc: Allocator,
        capture: *TestCapture,
        limits: Limits,
        cols: u16,
        rows: u16,
        manual: bool,
    ) !*TestTermio {
        testEnsureXev();
        const self = try alloc.create(TestTermio);
        errdefer alloc.destroy(self);

        const config = try alloc.create(configpkg.Config);
        errdefer alloc.destroy(config);
        config.* = try configpkg.Config.default(alloc);
        errdefer config.deinit();

        const renderer_mutex = try alloc.create(std.Io.Mutex);
        errdefer alloc.destroy(renderer_mutex);
        renderer_mutex.* = .init;

        const renderer_state = try alloc.create(renderer.State);
        errdefer alloc.destroy(renderer_state);

        var renderer_wakeup = try xev.Async.init();
        errdefer renderer_wakeup.deinit();

        const renderer_mailbox = try renderer.Thread.Mailbox.create(alloc);
        errdefer renderer_mailbox.destroy(alloc);

        const app_mailbox = try CoreApp.Mailbox.Queue.create(alloc);
        errdefer app_mailbox.destroy(alloc);

        const io = try alloc.create(termio.Termio);
        errdefer alloc.destroy(io);

        const size: renderer.Size = .{
            .screen = .{
                .width = @as(u32, cols) * cell_w,
                .height = @as(u32, rows) * cell_h,
            },
            .cell = .{ .width = cell_w, .height = cell_h },
            .padding = .{},
        };

        var derived = try termio.Termio.DerivedConfig.init(alloc, config);
        errdefer derived.deinit();

        var term = try terminal.Terminal.init(global.io(), alloc, .{
            .cols = cols,
            .rows = rows,
        });
        errdefer term.deinit(alloc);
        term.width_px = @as(u32, cols) * cell_w;
        term.height_px = @as(u32, rows) * cell_h;

        var backend: termio.Backend = .{ .external = try External.init(alloc, .{
            .host = capture.hostConfig(),
            .limits = limits,
        }) };
        errdefer backend.deinit();
        backend.initTerminal(&term);

        var io_mailbox = try termio.Mailbox.initSPSC(alloc);
        errdefer io_mailbox.deinit(alloc);

        // Surface pointer is never dereferenced by the paths under test;
        // messages carry it opaquely.
        const surface_mailbox: apprt.surface.Mailbox = .{
            .surface = undefined,
            .app = .{ .rt_app = undefined, .mailbox = app_mailbox },
        };

        io.* = .{
            .alloc = alloc,
            .terminal = term,
            .config = derived,
            .renderer_state = renderer_state,
            .renderer_wakeup = renderer_wakeup,
            .renderer_mailbox = renderer_mailbox,
            .surface_mailbox = surface_mailbox,
            .size = size,
            .backend = backend,
            .mailbox = io_mailbox,
            .terminal_stream = .init(.{
                .allocator = alloc,
                .handler = .{
                    .alloc = alloc,
                    .termio_mailbox = &io.mailbox,
                    .surface_mailbox = surface_mailbox,
                    .renderer_state = renderer_state,
                    .renderer_wakeup = renderer_wakeup,
                    .renderer_mailbox = renderer_mailbox,
                    .size = &io.size,
                    .terminal = &io.terminal,
                    .osc_color_report_format = derived.osc_color_report_format,
                    .clipboard_write = derived.clipboard_write,
                    .enquiry_response = derived.enquiry_response,
                },
            }),
            .thread_enter_state = null,
        };

        renderer_state.* = .{
            .mutex = renderer_mutex,
            .terminal = &io.terminal,
        };

        const thread = try alloc.create(termio.Thread);
        errdefer alloc.destroy(thread);
        thread.* = try termio.Thread.init(alloc);
        errdefer thread.deinit();

        const td = try alloc.create(termio.Termio.ThreadData);
        errdefer alloc.destroy(td);
        if (manual) try io.threadEnter(thread, td);

        self.* = .{
            .alloc = alloc,
            .capture = capture,
            .config = config,
            .renderer_mutex = renderer_mutex,
            .renderer_state = renderer_state,
            .renderer_wakeup = renderer_wakeup,
            .renderer_mailbox = renderer_mailbox,
            .app_mailbox = app_mailbox,
            .io = io,
            .thread = thread,
            .td = td,
            .manual = manual,
        };
        return self;
    }

    fn deinit(self: *TestTermio) void {
        const alloc = self.alloc;
        if (self.manual) {
            self.io.threadExit(self.td);
            self.td.deinit();
        }
        alloc.destroy(self.td);
        self.io.deinit();
        alloc.destroy(self.io);
        self.thread.deinit();
        alloc.destroy(self.thread);
        while (self.app_mailbox.pop(global.io())) |_| {}
        self.app_mailbox.destroy(alloc);
        while (self.renderer_mailbox.pop(global.io())) |_| {}
        self.renderer_mailbox.destroy(alloc);
        self.renderer_wakeup.deinit();
        alloc.destroy(self.renderer_state);
        alloc.destroy(self.renderer_mutex);
        self.config.deinit();
        alloc.destroy(self.config);
        alloc.destroy(self);
    }

    fn shared(self: *TestTermio) *Shared {
        return self.io.backend.external.shared;
    }

    /// One io-thread turn: run ready xev completions (drains the
    /// inbound mailbox through the real wakeup callback) without
    /// blocking or sleeping.
    fn tick(self: *TestTermio) !void {
        try self.thread.loop.run(.no_wait);
    }

    /// Feed and then drain, asserting the feed result.
    fn feedAndDrain(self: *TestTermio, bytes: []const u8) !void {
        try testing.expectEqual(Result.accepted, self.shared().feed(bytes));
        try self.tick();
    }

    /// Emulate the write-relevant subset of termio.Thread.drainMailbox:
    /// the harness thread plays the io thread role deterministically.
    fn drainMessages(self: *TestTermio) !void {
        const queue = self.io.mailbox.spsc.queue;
        while (queue.pop(global.io())) |message| {
            switch (message) {
                .linefeed_mode => |v| self.linefeed_mode = v,
                .resize => |v| try self.io.resize(self.td, v),
                .focused => |v| try self.io.focusGained(self.td, v),
                .size_report => |v| try self.io.sizeReport(self.td, v),
                .write_small => |v| try self.io.queueWrite(
                    self.td,
                    v.data[0..v.len],
                    self.linefeed_mode,
                ),
                .write_stable => |v| try self.io.queueWrite(
                    self.td,
                    v,
                    self.linefeed_mode,
                ),
                .write_alloc => |v| {
                    defer v.alloc.free(v.data);
                    try self.io.queueWrite(self.td, v.data, self.linefeed_mode);
                },
                else => message.deinit(),
            }
        }
    }

    fn sendWrite(self: *TestTermio, bytes: []const u8) !void {
        self.io.queueMessage(.{ .write_stable = bytes }, .unlocked);
        try self.drainMessages();
    }

    fn screenString(self: *TestTermio, alloc: Allocator) ![]const u8 {
        const io_z = global.io();
        self.renderer_mutex.lockUncancelable(io_z);
        defer self.renderer_mutex.unlock(io_z);
        return try self.io.terminal.plainString(alloc);
    }

    fn cursorPos(self: *TestTermio) [2]usize {
        const io_z = global.io();
        self.renderer_mutex.lockUncancelable(io_z);
        defer self.renderer_mutex.unlock(io_z);
        return .{
            self.io.terminal.screens.active.cursor.x,
            self.io.terminal.screens.active.cursor.y,
        };
    }

    const SemanticOracle = struct {
        red_palette: ?u8,
        styled_bold: bool,
        styled_underline: bool,
        focus_event: bool,
        bracketed_paste: bool,
    };

    /// Capture non-text terminal semantics that plainString cannot prove:
    /// representative SGR styling and host-relevant terminal modes.
    fn semanticOracle(self: *TestTermio) SemanticOracle {
        const io_z = global.io();
        self.renderer_mutex.lockUncancelable(io_z);
        defer self.renderer_mutex.unlock(io_z);

        const screen = self.io.terminal.screens.active;
        const red = screen.pages.getCell(.{
            .active = .{ .x = 0, .y = 1 },
        }).?;
        const styled = screen.pages.getCell(.{
            .active = .{ .x = 8, .y = 1 },
        }).?;
        const red_style = red.style();
        const styled_style = styled.style();

        return .{
            .red_palette = switch (red_style.fg_color) {
                .palette => |value| value,
                else => null,
            },
            .styled_bold = styled_style.flags.bold,
            .styled_underline = styled_style.flags.underline == .single,
            .focus_event = self.io.terminal.modes.get(.focus_event),
            .bracketed_paste = self.io.terminal.modes.get(.bracketed_paste),
        };
    }
};

//-------------------------------------------------------------------
// ABI validation tests (fail closed)

test "external: HostConfig accepts a valid v1 config" {
    var capture = TestCapture.init(testing.allocator);
    defer capture.deinit();
    var c = capture.cConfig();
    const host = try HostConfig.fromC(&c);
    try testing.expect(host.write_cb == &TestCapture.writeCb);
    try testing.expect(host.health_cb != null);
    try testing.expect(host.userdata == @as(?*anyopaque, &capture));
}

test "external: HostConfig accepts a larger future struct via v1 prefix" {
    var capture = TestCapture.init(testing.allocator);
    defer capture.deinit();
    var c = capture.cConfig();
    c.struct_size = @sizeOf(CConfig) + 64;
    _ = try HostConfig.fromC(&c);
}

test "external: HostConfig fails closed on invalid input" {
    var capture = TestCapture.init(testing.allocator);
    defer capture.deinit();

    // Null pointer
    try testing.expectError(error.Invalid, HostConfig.fromC(null));

    // Undersized struct
    var c = capture.cConfig();
    c.struct_size = @sizeOf(CConfig) - 1;
    try testing.expectError(error.Invalid, HostConfig.fromC(&c));
    c = capture.cConfig();
    c.struct_size = 0;
    try testing.expectError(error.Invalid, HostConfig.fromC(&c));

    // Wrong ABI version
    c = capture.cConfig();
    c.abi_version = 0;
    try testing.expectError(error.Invalid, HostConfig.fromC(&c));
    c = capture.cConfig();
    c.abi_version = 2;
    try testing.expectError(error.Invalid, HostConfig.fromC(&c));

    // Null required callbacks
    c = capture.cConfig();
    c.write_cb = null;
    try testing.expectError(error.Invalid, HostConfig.fromC(&c));
    c = capture.cConfig();
    c.resize_cb = null;
    try testing.expectError(error.Invalid, HostConfig.fromC(&c));
    c = capture.cConfig();
    c.close_cb = null;
    try testing.expectError(error.Invalid, HostConfig.fromC(&c));

    // Optional health callback may be null
    c = capture.cConfig();
    c.health_cb = null;
    _ = try HostConfig.fromC(&c);
}

test "external: CProcessState validates fail closed" {
    const valid: CProcessState = .{
        .struct_size = @sizeOf(CProcessState),
        .abi_version = abi_version,
        .state = @intFromEnum(ProcessStateKind.exited),
        .exit_code = 3,
        .signal = 0,
    };
    {
        const ps = try ProcessState.fromC(&valid);
        try testing.expectEqual(ProcessState{ .exited = 3 }, ps);
    }

    try testing.expectError(error.Invalid, ProcessState.fromC(null));

    var c = valid;
    c.struct_size = @sizeOf(CProcessState) - 1;
    try testing.expectError(error.Invalid, ProcessState.fromC(&c));

    c = valid;
    c.abi_version = 99;
    try testing.expectError(error.Invalid, ProcessState.fromC(&c));

    c = valid;
    c.state = 99;
    try testing.expectError(error.Invalid, ProcessState.fromC(&c));
    c.state = -1;
    try testing.expectError(error.Invalid, ProcessState.fromC(&c));

    // Larger future struct is read via its v1 prefix.
    c = valid;
    c.struct_size = @sizeOf(CProcessState) + 32;
    _ = try ProcessState.fromC(&c);

    // Signaled maps the signal field.
    c = valid;
    c.state = @intFromEnum(ProcessStateKind.signaled);
    c.signal = 9;
    try testing.expectEqual(ProcessState{ .signaled = 9 }, try ProcessState.fromC(&c));
}

test "external: ABI layout matches include/ghostty.h" {
    const ch = @import("ghostty.h");

    try testing.expectEqual(
        @as(usize, @sizeOf(ch.ghostty_external_io_config_s)),
        @sizeOf(CConfig),
    );
    try testing.expectEqual(
        @as(usize, @sizeOf(ch.ghostty_external_process_state_s)),
        @sizeOf(CProcessState),
    );

    inline for (.{
        "struct_size", "abi_version", "userdata",
        "write_cb",    "resize_cb",   "close_cb",
        "health_cb",
    }) |field| {
        try testing.expectEqual(
            @offsetOf(ch.ghostty_external_io_config_s, field),
            @offsetOf(CConfig, field),
        );
    }
    inline for (.{
        "struct_size", "abi_version", "state",
        "exit_code",   "signal",
    }) |field| {
        try testing.expectEqual(
            @offsetOf(ch.ghostty_external_process_state_s, field),
            @offsetOf(CProcessState, field),
        );
    }

    try testing.expectEqual(
        @as(u32, ch.GHOSTTY_EXTERNAL_IO_ABI_VERSION),
        abi_version,
    );

    const pairs = .{
        .{ ch.GHOSTTY_EXTERNAL_IO_ACCEPTED, Result.accepted },
        .{ ch.GHOSTTY_EXTERNAL_IO_BACKPRESSURED, Result.backpressured },
        .{ ch.GHOSTTY_EXTERNAL_IO_CLOSED, Result.closed },
        .{ ch.GHOSTTY_EXTERNAL_IO_INVALID, Result.invalid },
        .{ ch.GHOSTTY_EXTERNAL_IO_INTERNAL_ERROR, Result.internal_error },
        .{ ch.GHOSTTY_EXTERNAL_PROCESS_RUNNING, ProcessStateKind.running },
        .{ ch.GHOSTTY_EXTERNAL_PROCESS_EXITED, ProcessStateKind.exited },
        .{ ch.GHOSTTY_EXTERNAL_PROCESS_SIGNALED, ProcessStateKind.signaled },
        .{ ch.GHOSTTY_EXTERNAL_PROCESS_CLOSED, ProcessStateKind.closed },
        .{ ch.GHOSTTY_EXTERNAL_CLOSE_HOST_EXITED, CloseReason.host_exited },
        .{ ch.GHOSTTY_EXTERNAL_CLOSE_HOST_SIGNALED, CloseReason.host_signaled },
        .{ ch.GHOSTTY_EXTERNAL_CLOSE_HOST_CLOSED, CloseReason.host_closed },
        .{ ch.GHOSTTY_EXTERNAL_CLOSE_SURFACE_REQUEST, CloseReason.surface_request },
        .{ ch.GHOSTTY_EXTERNAL_HEALTH_FEED_READY, HealthEvent.feed_ready },
        .{ ch.GHOSTTY_EXTERNAL_HEALTH_OUTPUT_BACKPRESSURED, HealthEvent.output_backpressured },
        .{ ch.GHOSTTY_EXTERNAL_HEALTH_OUTPUT_OVERFLOW, HealthEvent.output_overflow },
        .{ ch.GHOSTTY_EXTERNAL_HEALTH_OUTPUT_SUPPRESSED, HealthEvent.output_suppressed },
    };
    inline for (pairs) |pair| {
        const c_val: i64 = switch (@typeInfo(@TypeOf(pair[0]))) {
            .@"enum" => @intFromEnum(pair[0]),
            else => @intCast(pair[0]),
        };
        try testing.expectEqual(c_val, @as(i64, @intFromEnum(pair[1])));
    }
}

//-------------------------------------------------------------------
// Shared state unit tests

test "external: feed copies, bounds, and rejects atomically" {
    testEnsureXev();
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();

    const shared = try Shared.create(alloc, capture.hostConfig(), .{
        .inbound_capacity_bytes = 8,
        .inbound_capacity_chunks = 2,
    });
    defer shared.release();

    // Zero-length is harmless and consumes nothing.
    try testing.expectEqual(Result.accepted, shared.feed(""));
    try testing.expectEqual(@as(usize, 0), shared.inbound.items.len);

    // A feed larger than total capacity is invalid, not backpressured.
    try testing.expectEqual(Result.invalid, shared.feed("123456789"));
    try testing.expectEqual(@as(usize, 0), shared.inbound.items.len);

    // Accepted feeds are copied: mutate the source afterwards.
    var src = "abcd".*;
    try testing.expectEqual(Result.accepted, shared.feed(&src));
    src[0] = 'X';
    try testing.expectEqualStrings("abcd", shared.inbound.items[0]);

    // Byte capacity: 5 more would exceed 8; nothing is consumed.
    try testing.expectEqual(Result.backpressured, shared.feed("12345"));
    try testing.expectEqual(@as(usize, 1), shared.inbound.items.len);
    try testing.expectEqual(@as(usize, 4), shared.inbound_bytes);
    try testing.expect(shared.feed_backpressured);

    // A fitting feed is still accepted after a rejection.
    try testing.expectEqual(Result.accepted, shared.feed("efgh"));

    // Chunk capacity: two chunks queued, third rejected atomically.
    try testing.expectEqual(Result.backpressured, shared.feed("x"));
    try testing.expectEqual(@as(usize, 2), shared.inbound.items.len);
    try testing.expectEqual(@as(usize, 8), shared.inbound_bytes);
}

test "external: process state machine validates transitions" {
    testEnsureXev();
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();

    const shared = try Shared.create(alloc, capture.hostConfig(), .{});
    defer shared.release();

    // running -> running is idempotent.
    try testing.expectEqual(Result.accepted, shared.setProcessState(.running));
    try testing.expect(!shared.feed_closed);

    // running -> exited latches, closes feeds, queues one close.
    try testing.expectEqual(Result.accepted, shared.setProcessState(.{ .exited = 0 }));
    try testing.expect(shared.feed_closed);
    try testing.expectEqual(CloseReason.host_exited, shared.close_pending.?);

    // Feed after terminal closure returns closed (also for zero-length).
    try testing.expectEqual(Result.closed, shared.feed("x"));
    try testing.expectEqual(Result.closed, shared.feed(""));

    // Identical repeat is idempotent and does not queue a second close.
    shared.close_pending = null;
    try testing.expectEqual(Result.accepted, shared.setProcessState(.{ .exited = 0 }));
    try testing.expect(shared.close_pending == null);

    // Terminal state never regresses to running.
    try testing.expectEqual(Result.invalid, shared.setProcessState(.running));

    // Contradictory terminal info fails closed.
    try testing.expectEqual(Result.invalid, shared.setProcessState(.{ .exited = 5 }));
    try testing.expectEqual(Result.invalid, shared.setProcessState(.{ .signaled = 9 }));

    // Escalation to closed is an accepted no-op.
    try testing.expectEqual(Result.accepted, shared.setProcessState(.closed));
    try testing.expectEqual(ProcessState{ .exited = 0 }, shared.process);
}

test "external: requestClose latches a single close" {
    testEnsureXev();
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();

    const shared = try Shared.create(alloc, capture.hostConfig(), .{});
    defer shared.release();

    shared.requestClose();
    try testing.expectEqual(CloseReason.surface_request, shared.close_pending.?);
    shared.requestClose();
    try testing.expectEqual(CloseReason.surface_request, shared.close_pending.?);

    // Once delivered, no further close is ever queued.
    shared.close_pending = null;
    shared.close_delivered = true;
    shared.requestClose();
    try testing.expect(shared.close_pending == null);
}

//-------------------------------------------------------------------
// Registry tests

test "external: registry pin, contains, and destroy gate" {
    testEnsureXev();
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();

    const shared = try Shared.create(alloc, capture.hostConfig(), .{});
    defer shared.release();

    var key_storage: u8 = 0;
    const key: *const anyopaque = &key_storage;

    // Unknown handles: closed/invalid/false, never a crash.
    try testing.expectEqual(Result.closed, feedSurface(key, "x", 1));
    try testing.expect(!isExternalSurface(key));
    try testing.expectEqual(Result.invalid, feedSurface(null, null, 0));
    try testing.expect(!isExternalSurface(null));

    try registryRegister(key, shared);
    try testing.expect(isExternalSurface(key));

    // Feed through the registry path, including invalid pointer/length.
    try testing.expectEqual(Result.accepted, feedSurface(key, "ab", 2));
    try testing.expectEqual(Result.invalid, feedSurface(key, null, 2));
    try testing.expectEqual(@as(usize, 1), shared.inbound.items.len);

    // Process state through the registry path.
    const state: CProcessState = .{
        .struct_size = @sizeOf(CProcessState),
        .abi_version = abi_version,
        .state = @intFromEnum(ProcessStateKind.exited),
        .exit_code = 0,
        .signal = 0,
    };
    try testing.expectEqual(Result.accepted, setProcessStateSurface(key, &state));

    // Destroy gate: handle disappears, feeds return closed.
    registryBeginDestroy(key);
    try testing.expect(!isExternalSurface(key));
    try testing.expectEqual(Result.closed, feedSurface(key, "x", 1));
    // Idempotent for already-removed and never-registered keys.
    registryBeginDestroy(key);
}

test "external: registry capacity is bounded and observable" {
    testEnsureXev();
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();

    const shared = try Shared.create(alloc, capture.hostConfig(), .{});
    defer shared.release();

    var keys: [registry_max_surfaces + 1]u8 = undefined;
    var registered: usize = 0;
    defer for (0..registered) |i| registryBeginDestroy(&keys[i]);

    for (0..registry_max_surfaces) |i| {
        try registryRegister(&keys[i], shared);
        registered += 1;
    }
    try testing.expectError(
        error.RegistryFull,
        registryRegister(&keys[registry_max_surfaces], shared),
    );
}

//-------------------------------------------------------------------
// Termio integration tests (harness plays the io thread)

test "external: construction wires the backend without exec" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
    defer h.deinit();

    try testing.expect(h.io.backend == .external);
    try testing.expect(h.td.backend == .external);

    // Neutral process info: nothing is fabricated.
    try testing.expect(h.io.getProcessInfo(.foreground_pid) == null);
    try testing.expect(h.io.getProcessInfo(.tty_name) == null);
}

test "external: feeding hello updates terminal state" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
    defer h.deinit();

    try h.feedAndDrain("hello\r\n");

    const str = try h.screenString(alloc);
    defer alloc.free(str);
    try testing.expect(std.mem.startsWith(u8, str, "hello"));
    try testing.expectEqual([2]usize{ 0, 1 }, h.cursorPos());
}

test "external: chunk boundaries never change terminal semantics" {
    const alloc = testing.allocator;

    // UTF-8 multibyte, SGR escapes, control characters, and mode changes
    // all cross chunk boundaries in every split pattern.
    const stream_bytes =
        "h\xC3\xA9llo \xF0\x9F\x9A\x80\r\n" ++
        "\x1b[31mred\x1b[0m and \x1b[1;4mstyled\x1b[m\r\n" ++
        "tab\there\r\n" ++
        "\x1b[?1004h\x1b[?2004h";

    var expected: ?[]const u8 = null;
    defer if (expected) |v| alloc.free(v);
    var expected_cursor: [2]usize = undefined;
    var expected_semantics: TestTermio.SemanticOracle = undefined;

    // Split sizes: whole, 1, 2, 3, 5, 7 bytes per accepted feed.
    const splits = [_]usize{ stream_bytes.len, 1, 2, 3, 5, 7 };
    for (splits) |split| {
        var capture = TestCapture.init(alloc);
        defer capture.deinit();
        var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
        defer h.deinit();

        var i: usize = 0;
        while (i < stream_bytes.len) : (i += split) {
            const end = @min(stream_bytes.len, i + split);
            try h.feedAndDrain(stream_bytes[i..end]);
        }

        const str = try h.screenString(alloc);
        const semantics = h.semanticOracle();
        if (expected == null) {
            expected = str;
            expected_cursor = h.cursorPos();
            expected_semantics = semantics;
            try testing.expect(std.mem.indexOf(u8, str, "héllo 🚀") != null);
            try testing.expect(std.mem.indexOf(u8, str, "red and styled") != null);
            try testing.expectEqual(@as(?u8, 1), semantics.red_palette);
            try testing.expect(semantics.styled_bold);
            try testing.expect(semantics.styled_underline);
            try testing.expect(semantics.focus_event);
            try testing.expect(semantics.bracketed_paste);
        } else {
            defer alloc.free(str);
            try testing.expectEqualStrings(expected.?, str);
            try testing.expectEqual(expected_cursor, h.cursorPos());
            try testing.expectEqual(expected_semantics, semantics);
        }
    }
}

test "external: incomplete utf8 and escape chunks stay bounded and complete" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
    defer h.deinit();

    // Escape sequence split mid-CSI, drained between the halves.
    try h.feedAndDrain("\x1b[3");
    try h.feedAndDrain("1mred");

    // UTF-8 rocket split mid-encoding, drained between the halves.
    try h.feedAndDrain("\xF0\x9F");
    try h.feedAndDrain("\x9A\x80");

    const str = try h.screenString(alloc);
    defer alloc.free(str);
    try testing.expect(std.mem.indexOf(u8, str, "red🚀") != null);
}

test "external: inbound backpressure is atomic, observable, recoverable" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{
        .inbound_capacity_bytes = 8,
        .inbound_capacity_chunks = 8,
    }, 80, 24);
    defer h.deinit();

    const shared = h.shared();
    try testing.expectEqual(Result.accepted, shared.feed("abcdef"));

    // Does not fit: rejected without consuming anything.
    try testing.expectEqual(Result.backpressured, shared.feed("ghijkl"));
    try testing.expectEqual(@as(usize, 6), shared.inbound_bytes);

    // Larger than total capacity: invalid.
    try testing.expectEqual(Result.invalid, shared.feed("0123456789"));

    // Drain frees capacity and reports feed_ready exactly once.
    try h.tick();
    {
        const io_z = global.io();
        capture.mutex.lockUncancelable(io_z);
        defer capture.mutex.unlock(io_z);
        try testing.expectEqual(@as(usize, 1), capture.healths.items.len);
        try testing.expectEqual(HealthEvent.feed_ready, capture.healths.items[0].event);
    }

    // Retry succeeds; bytes arrive exactly once, in order.
    try h.feedAndDrain("ghijkl");
    const str = try h.screenString(alloc);
    defer alloc.free(str);
    try testing.expect(std.mem.startsWith(u8, str, "abcdefghijkl"));
}

test "external: closed and full feeds allocate nothing" {
    testEnsureXev();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    var capture = TestCapture.init(alloc);
    defer capture.deinit();

    const shared = try Shared.create(alloc, capture.hostConfig(), .{
        .inbound_capacity_bytes = 1,
        .inbound_capacity_chunks = 1,
    });
    defer shared.release();

    // Populate the sole byte/chunk slot, then make the allocator fail its
    // very next allocation. Admission rejections must not reach it.
    try testing.expectEqual(Result.accepted, shared.feed("a"));
    failing.fail_index = failing.alloc_index;

    try testing.expectEqual(Result.backpressured, shared.feed("b"));
    try testing.expect(!failing.has_induced_failure);

    try testing.expectEqual(
        Result.accepted,
        shared.setProcessState(.{ .exited = 0 }),
    );
    try testing.expectEqual(Result.closed, shared.feed("c"));
    try testing.expect(!failing.has_induced_failure);
}

test "external: writes reach the host callback byte-exact" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
    defer h.deinit();

    // Representative terminal-input byte sequences exactly as the
    // surface layer queues them: key encoding, UTF-8 text, bracketed
    // paste, and mouse reports. The external backend must deliver them
    // byte-identically, unre-encoded.
    const sequences = [_][]const u8{
        "\x1b[27u", // CSI-u key encoding
        "h\xC3\xA9llo \xF0\x9F\x9A\x80", // UTF-8 text
        "\x1b[200~pasted data\x1b[201~", // bracketed paste
        "\x1b[<0;10;5M\x1b[<0;10;5m", // SGR mouse press/release
    };
    var expected: std.ArrayListUnmanaged(u8) = .empty;
    defer expected.deinit(alloc);
    for (sequences) |seq| {
        try h.sendWrite(seq);
        try expected.appendSlice(alloc, seq);
    }
    try testing.expectEqualSlices(u8, expected.items, capture.writesString());
}

test "external: linefeed mode translates exactly like exec" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
    defer h.deinit();

    // Mode 20 (LNM) set by the application stream flips linefeed mode
    // through the real message path.
    try h.feedAndDrain("\x1b[20h");
    try h.drainMessages();
    try testing.expect(h.linefeed_mode);

    try h.sendWrite("a\rb\rc");
    try testing.expectEqualStrings("a\r\nb\r\nc", capture.writesString());

    // Mode reset returns to byte-identical passthrough.
    try h.feedAndDrain("\x1b[20l");
    try h.drainMessages();
    try testing.expect(!h.linefeed_mode);
    try h.sendWrite("d\re");
    try testing.expectEqualStrings("a\r\nb\r\ncd\re", capture.writesString());
}

test "external: terminal replies flow to the host write callback" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
    defer h.deinit();

    // DSR cursor position report at origin.
    try h.feedAndDrain("\x1b[6n");
    try h.drainMessages();
    try testing.expectEqualStrings("\x1b[1;1R", capture.writesString());

    // Print two cells, ask again: exact updated report appended.
    try h.feedAndDrain("ab\x1b[6n");
    try h.drainMessages();
    try testing.expectEqualStrings("\x1b[1;1R\x1b[1;3R", capture.writesString());
}

test "external: focus reporting yields exact bytes when enabled" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
    defer h.deinit();

    // Without mode 1004 no bytes are generated.
    try h.io.focusGained(h.td, true);
    try testing.expectEqualStrings("", capture.writesString());

    try h.feedAndDrain("\x1b[?1004h");
    try h.io.focusGained(h.td, true);
    try h.io.focusGained(h.td, false);
    try testing.expectEqualStrings("\x1b[I\x1b[O", capture.writesString());
}

test "external: resize proposals are exact, deduplicated, validated" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
    defer h.deinit();

    const size2: renderer.Size = .{
        .screen = .{ .width = 100 * TestTermio.cell_w, .height = 30 * TestTermio.cell_h },
        .cell = .{ .width = TestTermio.cell_w, .height = TestTermio.cell_h },
        .padding = .{},
    };
    try h.io.resize(h.td, size2);
    {
        const io_z = global.io();
        capture.mutex.lockUncancelable(io_z);
        defer capture.mutex.unlock(io_z);
        try testing.expectEqual(@as(usize, 1), capture.resizes.items.len);
        try testing.expectEqual(
            [4]u64{ 100, 30, 100 * TestTermio.cell_w, 30 * TestTermio.cell_h },
            capture.resizes.items[0],
        );
    }

    // Identical geometry is coalesced: no second callback.
    try h.io.resize(h.td, size2);
    // Invalid zero geometry is rejected before any callback.
    try h.io.backend.resize(
        .{ .columns = 0, .rows = 30 },
        .{ .width = 100, .height = 100 },
    );
    {
        const io_z = global.io();
        capture.mutex.lockUncancelable(io_z);
        defer capture.mutex.unlock(io_z);
        try testing.expectEqual(@as(usize, 1), capture.resizes.items.len);
    }

    // A real geometry change fires with exact values.
    const size3: renderer.Size = .{
        .screen = .{ .width = 90 * TestTermio.cell_w, .height = 30 * TestTermio.cell_h },
        .cell = .{ .width = TestTermio.cell_w, .height = TestTermio.cell_h },
        .padding = .{},
    };
    try h.io.resize(h.td, size3);
    {
        const io_z = global.io();
        capture.mutex.lockUncancelable(io_z);
        defer capture.mutex.unlock(io_z);
        try testing.expectEqual(@as(usize, 2), capture.resizes.items.len);
        try testing.expectEqual(
            [4]u64{ 90, 30, 90 * TestTermio.cell_w, 30 * TestTermio.cell_h },
            capture.resizes.items[1],
        );
    }
}

test "external: host exit preserves screen and reports closure once" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
    defer h.deinit();

    // Queue the final frame and terminal state back-to-back before the io
    // thread gets a turn. The close callback itself probes terminal state,
    // so this asserts parsing precedes closure rather than merely observing
    // both effects after the tick.
    capture.close_probe_terminal = &h.io.terminal;
    const shared = h.shared();
    try testing.expectEqual(
        Result.accepted,
        shared.feed("final screen contents\r\n"),
    );
    try testing.expectEqual(Result.accepted, shared.setProcessState(.{ .exited = 0 }));
    try h.tick();

    // Exactly one close callback with the right reason.
    {
        const io_z = global.io();
        capture.mutex.lockUncancelable(io_z);
        defer capture.mutex.unlock(io_z);
        try testing.expectEqual(@as(usize, 1), capture.closes.items.len);
        try testing.expectEqual(CloseReason.host_exited, capture.closes.items[0]);
        try testing.expect(capture.close_saw_final_frame);
    }

    // The final screen is preserved untouched.
    const str = try h.screenString(alloc);
    defer alloc.free(str);
    try testing.expect(std.mem.startsWith(u8, str, "final screen contents"));

    // Feed after closure returns closed and changes nothing.
    try testing.expectEqual(Result.closed, shared.feed("more"));
    try h.tick();
    const str2 = try h.screenString(alloc);
    defer alloc.free(str2);
    try testing.expectEqualStrings(str, str2);

    // Repeated identical report stays idempotent: still one close.
    try testing.expectEqual(Result.accepted, shared.setProcessState(.{ .exited = 0 }));
    try h.tick();
    {
        const io_z = global.io();
        capture.mutex.lockUncancelable(io_z);
        defer capture.mutex.unlock(io_z);
        try testing.expectEqual(@as(usize, 1), capture.closes.items.len);
    }

    // Generated output after closure is suppressed with one health event.
    try h.sendWrite("late");
    try h.sendWrite("later");
    {
        const io_z = global.io();
        capture.mutex.lockUncancelable(io_z);
        defer capture.mutex.unlock(io_z);
        var suppressed: usize = 0;
        for (capture.healths.items) |rec| {
            if (rec.event == .output_suppressed) suppressed += 1;
        }
        try testing.expectEqual(@as(usize, 1), suppressed);
    }
    try testing.expectEqualStrings("", capture.writesString());
}

test "external: abnormal host exit preserves screen and reports signal" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
    defer h.deinit();

    try h.feedAndDrain("crash output\r\n");
    try testing.expectEqual(
        Result.accepted,
        h.shared().setProcessState(.{ .signaled = 9 }),
    );
    try h.tick();

    {
        const io_z = global.io();
        capture.mutex.lockUncancelable(io_z);
        defer capture.mutex.unlock(io_z);
        try testing.expectEqual(@as(usize, 1), capture.closes.items.len);
        try testing.expectEqual(CloseReason.host_signaled, capture.closes.items[0]);
    }
    try testing.expectEqual(ProcessState{ .signaled = 9 }, h.shared().process);

    const str = try h.screenString(alloc);
    defer alloc.free(str);
    try testing.expect(std.mem.startsWith(u8, str, "crash output"));
}

test "external: surface close request delivers one close callback" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
    defer h.deinit();

    h.shared().requestClose();
    h.shared().requestClose();
    try h.tick();

    const io_z = global.io();
    capture.mutex.lockUncancelable(io_z);
    defer capture.mutex.unlock(io_z);
    try testing.expectEqual(@as(usize, 1), capture.closes.items.len);
    try testing.expectEqual(CloseReason.surface_request, capture.closes.items[0]);
}

test "external: write backpressure retries without loss or duplication" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
    defer h.deinit();

    var key_storage: u8 = 0;
    try registryRegister(&key_storage, h.shared());
    defer registryBeginDestroy(&key_storage);

    // The first write and the implicit retry at the start of the second
    // write both backpressure. The readiness kick below is therefore the
    // first accepting retry.
    capture.write_backpressure_remaining = 2;

    try h.sendWrite("abc");
    try h.sendWrite("def");
    // Both writes are pending; exactly one backpressure health event.
    {
        const io_z = global.io();
        capture.mutex.lockUncancelable(io_z);
        defer capture.mutex.unlock(io_z);
        try testing.expectEqualStrings("", capture.writes.items);
        var bp: usize = 0;
        for (capture.healths.items) |rec| {
            if (rec.event == .output_backpressured) bp += 1;
        }
        try testing.expectEqual(@as(usize, 1), bp);
    }

    // The transport becomes writable without any further terminal input.
    // A zero-length public feed is the readiness kick; it queues no bytes
    // but wakes the io thread to retry retained output exactly once.
    try testing.expectEqual(
        Result.accepted,
        feedSurface(&key_storage, null, 0),
    );
    try testing.expectEqual(@as(usize, 0), h.shared().inbound.items.len);
    try h.tick();
    try testing.expectEqualStrings("abcdef", capture.writesString());

    // Later writes flow directly again.
    try h.sendWrite("ghi");
    try testing.expectEqualStrings("abcdefghi", capture.writesString());
}

test "external: pending output overflow fails the channel observably" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{
        .pending_output_capacity_bytes = 8,
    }, 80, 24);
    defer h.deinit();

    capture.write_forced_result = @intFromEnum(Result.backpressured);

    try h.sendWrite("abcdef");
    try h.sendWrite("ghijkl");

    const io_z = global.io();
    capture.mutex.lockUncancelable(io_z);
    defer capture.mutex.unlock(io_z);
    try testing.expect(h.td.backend.external.output_failed);
    var overflow: usize = 0;
    for (capture.healths.items) |rec| {
        if (rec.event == .output_overflow) overflow += 1;
    }
    try testing.expectEqual(@as(usize, 1), overflow);
    try testing.expectEqualStrings("", capture.writes.items);
}

test "external: host closed write result suppresses output observably" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
    defer h.deinit();

    capture.write_forced_result = @intFromEnum(Result.closed);
    try h.sendWrite("abc");
    try testing.expect(h.td.backend.external.output_failed);

    // An out-of-range host return value also fails closed.
    var capture2 = TestCapture.init(alloc);
    defer capture2.deinit();
    var h2 = try TestTermio.init(alloc, &capture2, .{}, 80, 24);
    defer h2.deinit();
    capture2.write_forced_result = 999;
    try h2.sendWrite("abc");
    try testing.expect(h2.td.backend.external.output_failed);
}

test "external: repeated create/feed/close/destroy cycles stay bounded" {
    const alloc = testing.allocator;

    // testing.allocator fails the test on any leak, so unbounded
    // lifetime growth across cycles is directly detected.
    for (0..12) |i| {
        var capture = TestCapture.init(alloc);
        defer capture.deinit();
        var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
        defer h.deinit();

        var key_storage: u8 = 0;
        try registryRegister(&key_storage, h.shared());
        defer registryBeginDestroy(&key_storage);

        try testing.expectEqual(
            Result.accepted,
            feedSurface(&key_storage, "cycle\r\n", 7),
        );
        try h.tick();

        if (i % 2 == 0) {
            const state: CProcessState = .{
                .struct_size = @sizeOf(CProcessState),
                .abi_version = abi_version,
                .state = @intFromEnum(ProcessStateKind.exited),
                .exit_code = 0,
                .signal = 0,
            };
            try testing.expectEqual(
                Result.accepted,
                setProcessStateSurface(&key_storage, &state),
            );
            try h.tick();
        }
    }
}

test "external: no exec reachable from external construction" {
    // Structural process-authority audit at the type level: the
    // external backend type must not embed or reference the exec
    // backend or any subprocess state.
    comptime {
        for (@typeInfo(External).@"struct".fields) |field| {
            assert(field.type != termio.Exec);
        }
        for (@typeInfo(ThreadData).@"struct".fields) |field| {
            assert(field.type != termio.Exec.ThreadData);
        }
    }

    // Runtime: a full external construction/teardown cycle constructs
    // no Exec and no subprocess (verified structurally above and by the
    // absence of any process/pty syscall path in this file; see the
    // process-authority audit in the integration evidence).
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.init(alloc, &capture, .{}, 80, 24);
    defer h.deinit();
    try testing.expect(h.io.backend != .exec);
}

//-------------------------------------------------------------------
// Hardening: ordering, concurrency, and lifecycle under a real thread

test "external: concurrent feeds have a total linearization order" {
    testEnsureXev();
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();

    const shared = try Shared.create(alloc, capture.hostConfig(), .{
        .inbound_capacity_bytes = 64 * 1024,
        .inbound_capacity_chunks = 4096,
    });
    defer shared.release();

    const producers = 4;
    const per_producer = 100;

    const Producer = struct {
        fn run(sh: *Shared, id: u8, done: *std.Io.Event) void {
            defer done.set(global.io());
            var seq: u16 = 0;
            while (seq < per_producer) : (seq += 1) {
                const payload: [4]u8 = .{
                    id,
                    @intCast(seq >> 8),
                    @intCast(seq & 0xFF),
                    '\n',
                };
                // Capacity is sized so every feed must be accepted.
                std.debug.assert(sh.feed(&payload) == .accepted);
            }
        }
    };

    var done: [producers]std.Io.Event = @splat(.unset);
    var threads: [producers]std.Thread = undefined;
    for (0..producers) |i| {
        threads[i] = try std.Thread.spawn(
            .{},
            Producer.run,
            .{ shared, @as(u8, @intCast(i)), &done[i] },
        );
    }
    for (&done) |*ev| waitTestEvent(ev);
    for (&threads) |*t| t.join();

    // The accepted-feed order is the queue order. Verify the global
    // order is a valid interleaving: every producer's sequence numbers
    // appear strictly in order, and nothing is lost or duplicated.
    {
        const io_z = global.io();
        shared.mutex.lockUncancelable(io_z);
        defer shared.mutex.unlock(io_z);

        try testing.expectEqual(
            @as(usize, producers * per_producer),
            shared.inbound.items.len,
        );
        var next: [producers]u16 = @splat(0);
        for (shared.inbound.items) |chunk| {
            try testing.expectEqual(@as(usize, 4), chunk.len);
            const id = chunk[0];
            const seq = (@as(u16, chunk[1]) << 8) | chunk[2];
            try testing.expectEqual(next[id], seq);
            next[id] += 1;
        }
        for (next) |n| try testing.expectEqual(@as(u16, per_producer), n);
    }
}

test "external: public surface-free gate races with feed safely" {
    testEnsureXev();
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();

    const shared = try Shared.create(alloc, capture.hostConfig(), .{});
    defer shared.release();

    var key_storage: u8 = 0;
    const key: *const anyopaque = &key_storage;
    try registryRegister(key, shared);

    const spammers = 4;
    const attempts = 400;

    const Spammer = struct {
        fn run(
            k: *const anyopaque,
            started: *std.Io.Event,
            finished: *std.Io.Event,
        ) void {
            defer finished.set(global.io());
            started.set(global.io());
            var i: usize = 0;
            while (i < attempts) : (i += 1) {
                // Every result is legal here depending on the race
                // phase; the invariant is no crash, no hang, no
                // partial consumption, and closed-after-destroy.
                switch (feedSurface(k, "x", 1)) {
                    .accepted, .backpressured, .closed => {},
                    .invalid, .internal_error => unreachable,
                }
            }
        }
    };

    var started: [spammers]std.Io.Event = @splat(.unset);
    var finished: [spammers]std.Io.Event = @splat(.unset);
    var threads: [spammers]std.Thread = undefined;
    for (0..spammers) |i| {
        threads[i] = try std.Thread.spawn(
            .{},
            Spammer.run,
            .{ key, &started[i], &finished[i] },
        );
    }
    // ghostty_surface_free calls this exact registry gate before touching
    // Surface state. Begin only after every public feed caller is live so
    // the pin/drain race is genuinely exercised.
    for (&started) |*ev| waitTestEvent(ev);
    registryBeginDestroy(key);

    for (&finished) |*ev| waitTestEvent(ev);
    for (&threads) |*t| t.join();

    try testing.expect(!isExternalSurface(key));
    try testing.expectEqual(Result.closed, feedSurface(key, "x", 1));
    const state: CProcessState = .{
        .struct_size = @sizeOf(CProcessState),
        .abi_version = abi_version,
        .state = @intFromEnum(ProcessStateKind.running),
        .exit_code = 0,
        .signal = 0,
    };
    try testing.expectEqual(Result.closed, setProcessStateSurface(key, &state));
}

test "external: real termio thread drains, replies, closes, and tears down" {
    const alloc = testing.allocator;
    var capture = TestCapture.init(alloc);
    defer capture.deinit();
    var h = try TestTermio.initMode(alloc, &capture, .{}, 80, 24, false);
    defer h.deinit();

    // Run the real io thread. It performs threadEnter/threadExit and
    // owns its thread data exactly like a live surface.
    var thread_done: std.Io.Event = .unset;
    const Runner = struct {
        fn run(
            thread: *termio.Thread,
            io: *termio.Termio,
            done: *std.Io.Event,
        ) void {
            defer done.set(global.io());
            thread.threadMain(io);
        }
    };
    const thr = try std.Thread.spawn(
        .{},
        Runner.run,
        .{ h.thread, h.io, &thread_done },
    );
    var joined = false;
    defer if (!joined) {
        h.thread.stop.notify() catch {};
        waitTestEvent(&thread_done);
        thr.join();
    };

    // Feed output and a DSR query; the reply must arrive through the
    // write callback from the io thread, after the fed bytes parsed.
    try testing.expectEqual(Result.accepted, h.shared().feed("hello\r\n"));
    try testing.expectEqual(Result.accepted, h.shared().feed("\x1b[6n"));

    const Waiter = struct {
        fn hasReply(_: void, c: *TestCapture) bool {
            return std.mem.indexOf(u8, c.writes.items, "\x1b[2;1R") != null;
        }
        fn hasClose(_: void, c: *TestCapture) bool {
            return c.closes.items.len > 0;
        }
    };
    capture.waitUntil({}, Waiter.hasReply);

    {
        const str = try h.screenString(alloc);
        defer alloc.free(str);
        try testing.expect(std.mem.startsWith(u8, str, "hello"));
    }

    // Host reports exit: close callback must be delivered by the io
    // thread while preserving the screen.
    try testing.expectEqual(
        Result.accepted,
        h.shared().setProcessState(.{ .exited = 0 }),
    );
    capture.waitUntil({}, Waiter.hasClose);
    {
        const io_z = global.io();
        capture.mutex.lockUncancelable(io_z);
        defer capture.mutex.unlock(io_z);
        try testing.expectEqual(@as(usize, 1), capture.closes.items.len);
        try testing.expectEqual(CloseReason.host_exited, capture.closes.items[0]);
    }

    // Stop the thread the same way Surface.deinit does, then verify no
    // callback occurs after the join completed.
    try h.thread.stop.notify();
    waitTestEvent(&thread_done);
    thr.join();
    joined = true;

    const stable = counts: {
        const io_z = global.io();
        capture.mutex.lockUncancelable(io_z);
        defer capture.mutex.unlock(io_z);
        break :counts .{
            capture.write_calls,
            capture.resizes.items.len,
            capture.closes.items.len,
            capture.healths.items.len,
        };
    };

    // Post-join feeds are rejected as closed and produce no callbacks.
    try testing.expectEqual(Result.closed, h.shared().feed("late"));
    try testing.expect(h.shared().detached);

    {
        const io_z = global.io();
        capture.mutex.lockUncancelable(io_z);
        defer capture.mutex.unlock(io_z);
        try testing.expectEqual(stable[0], capture.write_calls);
        try testing.expectEqual(stable[1], capture.resizes.items.len);
        try testing.expectEqual(stable[2], capture.closes.items.len);
        try testing.expectEqual(stable[3], capture.healths.items.len);
    }
}
