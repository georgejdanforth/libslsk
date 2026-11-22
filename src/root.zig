//! libslsk: a Soulseek client protocol library.

const std = @import("std");
const assert = std.debug.assert;

const build_options = @import("build_options");

/// Wire codecs: pure encode and decode, with no state.
pub const proto = @import("proto/root.zig");

/// The sans-IO protocol state machine.
pub const core = @import("core/root.zig");

/// The library version, from `build.zig.zon`.
pub const version: std.SemanticVersion = std.SemanticVersion.parse(version_string) catch unreachable;

/// The library version as a string, for example "0.1.0".
pub const version_string: [:0]const u8 = build_options.version;

comptime {
    assert(version_string.len > 0);
}

test "version matches version_string" {
    // The build script and the module parse the same string, so a mismatch is a build bug.
    var buffer: [64]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buffer, "{f}", .{version});
    try std.testing.expectEqualStrings(version_string, formatted);
}

test {
    _ = proto;
    _ = core;
}
