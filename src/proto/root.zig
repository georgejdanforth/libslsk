//! `slsk.proto`: wire codecs. Pure encode and decode, with no state and no I/O.

pub const wire = @import("wire.zig");
pub const frame = @import("frame.zig");

test {
    _ = wire;
    _ = frame;
}
