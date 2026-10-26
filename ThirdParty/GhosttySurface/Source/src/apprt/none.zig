const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");
const apprt = @import("../apprt.zig");
pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    /// No-op wakeup. Core paths that notify the app loop (for example
    /// apprt surface mailbox pushes) become semantically analyzed under
    /// the `none` runtime as soon as unit tests exercise them; there is
    /// no app loop here, so waking it is a no-op.
    pub fn wakeup(self: *const App) void {
        _ = self;
    }

    /// Always return false as there is no apprt to communicate with.
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        return false;
    }
};
pub const Surface = struct {};
