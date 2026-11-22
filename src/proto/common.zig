//! Types and helpers that the message unions of each connection type share.
//!
//! Each message union has one tag for each code that it implements, and an `unknown` tag. The
//! name of each tag (except `unknown`) is also the name of a field in its `Code` enum.

const std = @import("std");
const assert = std.debug.assert;

const frame = @import("frame.zig");

/// See "Connection Types" in docs/SLSKPROTOCOL.md. On the wire, the type is a string.
pub const ConnectionType = enum {
    peer,
    file,
    distributed,

    pub fn string(connection_type: ConnectionType) []const u8 {
        return switch (connection_type) {
            .peer => "P",
            .file => "F",
            .distributed => "D",
        };
    }

    pub fn parse(bytes: []const u8) error{InvalidConnectionType}!ConnectionType {
        if (bytes.len != 1) return error.InvalidConnectionType;
        return switch (bytes[0]) {
            'P' => .peer,
            'F' => .file,
            'D' => .distributed,
            else => error.InvalidConnectionType,
        };
    }
};

/// A message with a code that the union does not implement.
pub const Unknown = struct {
    code: u32,
    body: []const u8,
};

/// Returns the wire code of `message`.
pub fn code(comptime Code: type, comptime Message: type, message: Message) u32 {
    return switch (message) {
        .unknown => |unknown| unknown.code,
        inline else => |_, tag| @backingInt(@field(Code, @tagName(tag))),
    };
}

/// Returns true if `Message` has its own tag for `message_code`.
pub fn isKnownCode(comptime Code: type, comptime Message: type, message_code: u32) bool {
    inline for (@typeInfo(Message).@"union".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "unknown")) continue;
        if (message_code == @backingInt(@field(Code, name))) return true;
    }
    return false;
}

pub fn unknownMessage(message_frame: frame.Frame) Unknown {
    return .{ .code = message_frame.code, .body = message_frame.body };
}

const testing = std.testing;

test "invalid connection types" {
    // "X" is not a type, and "PF" is longer than one character.
    for ([_][]const u8{ "X", "PF", "", "p" }) |connection_type| {
        try testing.expectError(error.InvalidConnectionType, ConnectionType.parse(connection_type));
    }
}

test "connection types round trip" {
    inline for (.{ .peer, .file, .distributed }) |connection_type| {
        const parsed = try ConnectionType.parse(ConnectionType.string(connection_type));
        try testing.expectEqual(connection_type, parsed);
    }
}

comptime {
    assert(ConnectionType.string(.peer).len == 1);
}
