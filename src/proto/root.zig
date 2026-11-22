//! `slsk.proto`: wire codecs. Pure encode and decode, with no state and no I/O.

pub const wire = @import("wire.zig");
pub const frame = @import("frame.zig");
pub const server = @import("server.zig");

test {
    _ = wire;
    _ = frame;
    _ = server;
}
