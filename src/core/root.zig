//! `slsk.core`: the sans-IO protocol state machine. No `std.Io`, no clock, and no sockets.

pub const Core = @import("Core.zig");
pub const Conn = @import("connections.zig").Conn;
pub const TestHost = @import("TestHost.zig");

pub const Action = Core.Action;
pub const Address = Core.Address;
pub const Event = Core.Event;
pub const Options = Core.Options;
pub const InputError = Core.InputError;

test {
    _ = Core;
    _ = TestHost;
    _ = @import("connections.zig");
    _ = @import("queue.zig");
    _ = @import("timers.zig");
}
