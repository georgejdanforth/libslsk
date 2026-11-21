//! C ABI exports. `include/slsk.h` declares these functions.

const std = @import("std");

const slsk = @import("slsk");

/// Returns the library version as a static NUL-terminated string, for example "0.1.0".
export fn slsk_version() [*:0]const u8 {
    return slsk.version_string.ptr;
}

test slsk_version {
    try std.testing.expectEqualStrings(slsk.version_string, std.mem.span(slsk_version()));
}
