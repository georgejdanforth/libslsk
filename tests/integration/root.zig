//! Integration tests against a Soulfind server.
//!
//! Start the server with `scripts/soulfind.sh up`, then run
//! `SLSK_SOULFIND=127.0.0.1:2242 zig build itest`.
//! If `SLSK_SOULFIND` is not set, each test skips.

const std = @import("std");

const soulfind = @import("soulfind.zig");

test {
    _ = soulfind;
}

test "connect to Soulfind and close the connection" {
    // The goal is to check the harness: the server address comes from the environment, and the
    // server accepts a TCP connection.
    const io = std.testing.io;
    const address = try soulfind.address(std.testing.allocator);

    const stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    stream.close(io);
}
