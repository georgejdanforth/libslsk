//! `slsk.proto`: wire codecs. Pure encode and decode, with no state and no I/O.

pub const wire = @import("wire.zig");
pub const frame = @import("frame.zig");
pub const common = @import("common.zig");
pub const zlib = @import("zlib.zig");
pub const server = @import("server.zig");
pub const peer = @import("peer.zig");
pub const file = @import("file.zig");
pub const distributed = @import("distributed.zig");

pub const ConnectionType = common.ConnectionType;

test {
    _ = wire;
    _ = frame;
    _ = common;
    _ = zlib;
    _ = server;
    _ = peer;
    _ = file;
    _ = distributed;
}
