//! Test vectors and helpers for the `slsk.proto` tests. Only test code imports this file.

const std = @import("std");
const assert = std.debug.assert;

const frame = @import("frame.zig");

/// The "Sending Login Example" from docs/SLSKPROTOCOL.md, with the frame header.
pub const login_example = [_]u8{
    0x48, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x75, 0x73, 0x65, 0x72, 0x6e, 0x61, 0x6d, 0x65, 0x08, 0x00, 0x00, 0x00,
    0x70, 0x61, 0x73, 0x73, 0x77, 0x6f, 0x72, 0x64, 0xb1, 0x00, 0x00, 0x00,
    0x20, 0x00, 0x00, 0x00, 0x64, 0x35, 0x31, 0x63, 0x39, 0x61, 0x37, 0x65,
    0x39, 0x33, 0x35, 0x33, 0x37, 0x34, 0x36, 0x61, 0x36, 0x30, 0x32, 0x30,
    0x66, 0x39, 0x36, 0x30, 0x32, 0x64, 0x34, 0x35, 0x32, 0x39, 0x32, 0x39,
    0x01, 0x00, 0x00, 0x00,
};

/// The Login example without the length and the code.
pub const login_example_body = login_example[frame.header_size_max..];

comptime {
    assert(login_example.len == frame.length_size + 0x48);
    assert(login_example_body.len == 68);
}

/// Returns the bytes of one frame, for test vectors.
pub fn frameBytes(
    comptime format: frame.Format,
    comptime code: u32,
    comptime body: []const u8,
) []const u8 {
    comptime {
        var header: [frame.header_size_max]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], format.codeSize() + body.len, .little);
        std.mem.writeInt(u32, header[4..8], code, .little);
        return header[0 .. frame.length_size + format.codeSize()] ++ body;
    }
}

/// Splits a complete frame into the code and the body. The frame must have exactly one message.
pub fn splitFrame(format: frame.Format, bytes: []const u8) frame.Frame {
    const header_size = frame.length_size + format.codeSize();
    assert(bytes.len >= header_size);
    const length = std.mem.readInt(u32, bytes[0..frame.length_size], .little);
    assert(length == bytes.len - frame.length_size);
    const code: u32 = switch (format) {
        .code_u32 => std.mem.readInt(u32, bytes[frame.length_size..][0..4], .little),
        .code_u8 => bytes[frame.length_size],
    };
    return .{ .code = code, .body = bytes[header_size..] };
}

/// Returns the little-endian bytes of an integer, for test vectors.
pub fn intBytes(comptime T: type, comptime value: T) []const u8 {
    comptime {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        const result = bytes;
        return &result;
    }
}

/// Returns a string with its `u32` length prefix, for test vectors.
pub fn stringBytes(comptime value: []const u8) []const u8 {
    comptime {
        return intBytes(u32, value.len) ++ value;
    }
}

/// One value in a fuzz input. See `fuzzInput`.
pub const FuzzValue = union(enum) {
    /// For `Smith.eos*`.
    eos: bool,
    /// For `Smith.value` and `Smith.valueRange*` with an integer or an enum of 64 bits or less.
    int: u64,
    /// For `Smith.slice`.
    slice: []const u8,
};

/// Encodes values as a corpus entry for `std.testing.fuzz`. In a normal test run, each corpus
/// entry runs once, so these entries give the fuzz tests real coverage without `--fuzz`.
///
/// The encoding is the fixed-input format of `std.testing.Smith` in Zig 0.17.1. If a Zig
/// update changes that format, the entries are still valid inputs, but they lose their
/// meaning. The test "fuzzInput matches std.testing.Smith" detects that change.
pub fn fuzzInput(comptime values: []const FuzzValue) []const u8 {
    comptime {
        // Each value costs some branches. The largest corpus entries have about 70 values.
        @setEvalBranchQuota(100 * values.len + 1000);
        var input: []const u8 = &.{};
        for (values) |value| {
            switch (value) {
                .eos => |eos| input = input ++ [_]u8{@intFromBool(eos)},
                .int => |int| {
                    var bytes: [8]u8 = undefined;
                    std.mem.writeInt(u64, &bytes, int, .little);
                    input = input ++ bytes;
                },
                .slice => |slice| {
                    var length: [4]u8 = undefined;
                    std.mem.writeInt(u32, &length, slice.len, .little);
                    input = input ++ length ++ slice;
                },
            }
        }
        return input;
    }
}

/// Returns the values of `items` as `FuzzValue.int` values, for `Smith.value` calls on enums.
pub fn fuzzEnums(comptime T: type, comptime items: []const T) []const FuzzValue {
    comptime {
        var values: [items.len]FuzzValue = undefined;
        for (items, &values) |item, *value| value.* = .{ .int = @backingInt(item) };
        const result = values;
        return &result;
    }
}

test "fuzzInput matches std.testing.Smith" {
    const Color = enum(u8) { red = 0, green = 1, blue = 2 };
    const input = comptime fuzzInput(&.{
        .{ .eos = false },
        .{ .int = 0x0102030405060708 },
        .{ .int = 2 },
        .{ .int = 9 },
        .{ .slice = "abc" },
        .{ .eos = true },
    });

    var smith: std.testing.Smith = .{ .in = input };
    try std.testing.expectEqual(false, smith.eosWeightedSimple(1, 1));
    try std.testing.expectEqual(0x0102030405060708, smith.value(u64));
    try std.testing.expectEqual(Color.blue, smith.value(Color));
    try std.testing.expectEqual(9, smith.valueRangeAtMost(u32, 1, 10));
    var buffer: [8]u8 = undefined;
    const length = smith.slice(&buffer);
    try std.testing.expectEqualStrings("abc", buffer[0..length]);
    try std.testing.expectEqual(true, smith.eosWeightedSimple(1, 1));

    // After the end of the input, values are the smallest allowed value.
    try std.testing.expectEqual(1, smith.valueRangeAtMost(u32, 1, 10));
    try std.testing.expectEqual(Color.red, smith.value(Color));
}

test frameBytes {
    const bytes = comptime frameBytes(.code_u8, 5, "ab");
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x00, 0x00, 0x00, 0x05, 'a', 'b' }, bytes);
    const login = comptime frameBytes(.code_u32, 1, login_example_body);
    try std.testing.expectEqualSlices(u8, &login_example, login);
}

test splitFrame {
    const login = splitFrame(.code_u32, &login_example);
    try std.testing.expectEqual(1, login.code);
    try std.testing.expectEqualSlices(u8, login_example_body, login.body);

    const init = splitFrame(.code_u8, comptime frameBytes(.code_u8, 0xab, "xy"));
    try std.testing.expectEqual(0xab, init.code);
    try std.testing.expectEqualStrings("xy", init.body);
}

test "intBytes and stringBytes" {
    const int = comptime intBytes(u32, 0x12345678);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, int);
    const hi = comptime stringBytes("hi");
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x00, 0x00, 0x00, 'h', 'i' }, hi);
}
