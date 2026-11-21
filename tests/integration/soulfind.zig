//! Helpers to find the Soulfind server for integration tests.

const std = @import("std");
const IpAddress = std.Io.net.IpAddress;

/// The environment variable with the server address, for example "127.0.0.1:2242".
pub const env_name = "SLSK_SOULFIND";

/// Returns the server address from `SLSK_SOULFIND`.
/// If the variable is not set, returns `error.SkipZigTest`, so that the test skips.
pub fn address(gpa: std.mem.Allocator) !IpAddress {
    const text = std.testing.environ.getAlloc(gpa, env_name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("{s} is not set: skipping integration test.\n", .{env_name});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer gpa.free(text);

    return parse(text) catch |err| {
        std.debug.print("{s}='{s}' is not a valid host:port address.\n", .{ env_name, text });
        return err;
    };
}

/// Parses "host:port", where host is an IP address literal. The port must not be zero.
pub fn parse(text: []const u8) !IpAddress {
    const result = try IpAddress.parseLiteral(text);
    if (result.getPort() == 0) return error.InvalidPort;
    return result;
}

test parse {
    const result = try parse("127.0.0.1:2242");
    try std.testing.expectEqual(@as(u16, 2242), result.getPort());

    try std.testing.expectEqual(@as(u16, 2242), (try parse("[::1]:2242")).getPort());

    try std.testing.expectError(error.InvalidPort, parse("127.0.0.1"));
    try std.testing.expectError(error.InvalidPort, parse("127.0.0.1:0"));
    try std.testing.expectError(error.InvalidPort, parse("127.0.0.1:99999"));
    try std.testing.expectError(error.InvalidAddress, parse("localhost:2242"));
    try std.testing.expectError(error.InvalidAddress, parse(""));
}
