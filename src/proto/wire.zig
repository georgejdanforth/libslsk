//! Wire primitives of the Soulseek protocol (see "Packing" in docs/SLSKPROTOCOL.md).
//!
//! - Integers are little-endian.
//! - A bool is one byte.
//! - Strings and byte arrays have a `u32` length prefix. Strings are not always valid UTF-8,
//!   so both decode to raw byte slices.
//! - An IPv4 address is a `u32` that holds the address as a big-endian number, sent
//!   little-endian. The wire order of the octets is the reverse of the dotted order.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// An IPv4 address. The octets are in dotted order: 127.0.0.1 is `.{ 127, 0, 0, 1 }`.
pub const Ip4 = [4]u8;

/// Reads primitives from one message body. Slices that the reader returns point into the body.
pub const Reader = struct {
    bytes: []const u8,
    offset: usize,

    pub const Error = error{
        /// The body ends before the value that the caller asked for.
        EndOfMessage,
    };

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes, .offset = 0 };
    }

    /// Reads one of the integer types that the specification uses.
    pub fn readInt(reader: *Reader, comptime T: type) Error!T {
        comptime assertWireInt(T);
        const bytes = try reader.take(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }

    /// Reads a bool. Any value that is not zero is true, the same as in Nicotine+.
    pub fn readBool(reader: *Reader) Error!bool {
        return try reader.readInt(u8) != 0;
    }

    /// Reads a length-prefixed string. The result is raw bytes, not always UTF-8.
    pub fn readString(reader: *Reader) Error![]const u8 {
        return reader.readBytes();
    }

    /// Reads a length-prefixed byte array.
    pub fn readBytes(reader: *Reader) Error![]const u8 {
        const length = try reader.readInt(u32);
        return reader.take(length);
    }

    pub fn readIp4(reader: *Reader) Error!Ip4 {
        const address = try reader.readInt(u32);
        var ip: Ip4 = undefined;
        std.mem.writeInt(u32, &ip, address, .big);
        return ip;
    }

    /// Returns the bytes that the reader did not read yet, and consumes them.
    pub fn readRest(reader: *Reader) []const u8 {
        const rest = reader.bytes[reader.offset..];
        reader.offset = reader.bytes.len;
        return rest;
    }

    pub fn remaining(reader: *const Reader) usize {
        assert(reader.offset <= reader.bytes.len);
        return reader.bytes.len - reader.offset;
    }

    fn take(reader: *Reader, size: usize) Error![]const u8 {
        if (size <= reader.remaining()) {
            const bytes = reader.bytes[reader.offset..][0..size];
            reader.offset += size;
            assert(reader.offset <= reader.bytes.len);
            return bytes;
        } else {
            return error.EndOfMessage;
        }
    }
};

/// Appends primitives to a byte list.
pub const Writer = struct {
    gpa: Allocator,
    list: *std.ArrayList(u8),

    pub fn init(gpa: Allocator, list: *std.ArrayList(u8)) Writer {
        return .{ .gpa = gpa, .list = list };
    }

    pub fn writeInt(writer: Writer, comptime T: type, value: T) Allocator.Error!void {
        comptime assertWireInt(T);
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        try writer.list.appendSlice(writer.gpa, &bytes);
    }

    pub fn writeBool(writer: Writer, value: bool) Allocator.Error!void {
        try writer.writeInt(u8, @intFromBool(value));
    }

    pub fn writeString(writer: Writer, string: []const u8) Allocator.Error!void {
        try writer.writeBytes(string);
    }

    pub fn writeBytes(writer: Writer, bytes: []const u8) Allocator.Error!void {
        // A longer value cannot be encoded. The caller must check the length of foreign data.
        assert(bytes.len <= std.math.maxInt(u32));
        try writer.list.ensureUnusedCapacity(writer.gpa, @sizeOf(u32) + bytes.len);
        writer.writeInt(u32, @intCast(bytes.len)) catch unreachable;
        writer.list.appendSliceAssumeCapacity(bytes);
    }

    pub fn writeIp4(writer: Writer, ip: Ip4) Allocator.Error!void {
        try writer.writeInt(u32, std.mem.readInt(u32, &ip, .big));
    }

    /// Appends bytes with no length prefix.
    pub fn writeRaw(writer: Writer, bytes: []const u8) Allocator.Error!void {
        try writer.list.appendSlice(writer.gpa, bytes);
    }
};

fn assertWireInt(comptime T: type) void {
    switch (T) {
        u8, u16, u32, u64, i32 => {},
        else => @compileError("the specification has no integer type " ++ @typeName(T)),
    }
}

const testing = std.testing;
const test_support = @import("test_support.zig");

test "integers are little-endian" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: Writer = .init(testing.allocator, &list);

    try writer.writeInt(u8, 0x12);
    try writer.writeInt(u16, 0x3456);
    try writer.writeInt(u32, 0x789abcde);
    try writer.writeInt(u64, 0x0102030405060708);
    try writer.writeInt(i32, -2);

    const expected = [_]u8{0x12} ++
        [_]u8{ 0x56, 0x34 } ++
        [_]u8{ 0xde, 0xbc, 0x9a, 0x78 } ++
        [_]u8{ 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 } ++
        [_]u8{ 0xfe, 0xff, 0xff, 0xff };
    try testing.expectEqualSlices(u8, &expected, list.items);

    var reader: Reader = .init(list.items);
    try testing.expectEqual(0x12, try reader.readInt(u8));
    try testing.expectEqual(0x3456, try reader.readInt(u16));
    try testing.expectEqual(0x789abcde, try reader.readInt(u32));
    try testing.expectEqual(0x0102030405060708, try reader.readInt(u64));
    try testing.expectEqual(-2, try reader.readInt(i32));
    try testing.expectEqual(0, reader.remaining());
}

test "integer limits round trip" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: Writer = .init(testing.allocator, &list);

    inline for (.{ u8, u16, u32, u64, i32 }) |T| {
        try writer.writeInt(T, std.math.minInt(T));
        try writer.writeInt(T, std.math.maxInt(T));
    }

    var reader: Reader = .init(list.items);
    inline for (.{ u8, u16, u32, u64, i32 }) |T| {
        try testing.expectEqual(std.math.minInt(T), try reader.readInt(T));
        try testing.expectEqual(std.math.maxInt(T), try reader.readInt(T));
    }
    try testing.expectEqual(0, reader.remaining());
}

test "bool" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: Writer = .init(testing.allocator, &list);

    try writer.writeBool(false);
    try writer.writeBool(true);
    try testing.expectEqualSlices(u8, &.{ 0, 1 }, list.items);

    // Other clients can send values that are not 0 or 1. Nicotine+ reads them as true.
    var reader: Reader = .init(&.{ 0, 1, 2, 0xff });
    try testing.expectEqual(false, try reader.readBool());
    try testing.expectEqual(true, try reader.readBool());
    try testing.expectEqual(true, try reader.readBool());
    try testing.expectEqual(true, try reader.readBool());
    try testing.expectError(error.EndOfMessage, reader.readBool());
}

test "strings and byte arrays" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: Writer = .init(testing.allocator, &list);

    try writer.writeString("abc");
    try writer.writeString("");
    try writer.writeBytes(&.{ 0x00, 0xff });
    // Strings are raw bytes. Invalid UTF-8 must round trip unchanged.
    try writer.writeString(&.{ 0xc3, 0x28 });

    const expected = [_]u8{ 0x03, 0x00, 0x00, 0x00, 'a', 'b', 'c' } ++
        [_]u8{ 0x00, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0xff } ++
        [_]u8{ 0x02, 0x00, 0x00, 0x00, 0xc3, 0x28 };
    try testing.expectEqualSlices(u8, &expected, list.items);

    var reader: Reader = .init(list.items);
    try testing.expectEqualStrings("abc", try reader.readString());
    try testing.expectEqualStrings("", try reader.readString());
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xff }, try reader.readBytes());
    try testing.expectEqualSlices(u8, &.{ 0xc3, 0x28 }, try reader.readString());
    try testing.expectEqual(0, reader.remaining());
}

test "IPv4 addresses are in reversed byte order" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: Writer = .init(testing.allocator, &list);

    try writer.writeIp4(.{ 127, 0, 0, 1 });
    try writer.writeIp4(.{ 192, 168, 1, 20 });
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 127, 20, 1, 168, 192 }, list.items);

    var reader: Reader = .init(list.items);
    try testing.expectEqual(Ip4{ 127, 0, 0, 1 }, try reader.readIp4());
    try testing.expectEqual(Ip4{ 192, 168, 1, 20 }, try reader.readIp4());
    try testing.expectEqual(0, reader.remaining());

    // The same bytes, read as a u32, give the address as a big-endian number.
    reader = .init(list.items);
    try testing.expectEqual(0x7f000001, try reader.readInt(u32));
}

test "truncated values give EndOfMessage" {
    // Each case cuts the encoded value by one byte.
    var reader: Reader = .init(&.{ 0x01, 0x02, 0x03 });
    try testing.expectError(error.EndOfMessage, reader.readInt(u32));
    reader = .init(&.{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 });
    try testing.expectError(error.EndOfMessage, reader.readInt(u64));
    reader = .init(&.{ 0x01, 0x00, 0x00 });
    try testing.expectError(error.EndOfMessage, reader.readString());
    reader = .init(&.{ 0x02, 0x00, 0x00, 0x00, 'a' });
    try testing.expectError(error.EndOfMessage, reader.readString());
    reader = .init(&.{ 0x01, 0x00, 0x00 });
    try testing.expectError(error.EndOfMessage, reader.readIp4());
    reader = .init(&.{});
    try testing.expectError(error.EndOfMessage, reader.readBool());

    // A huge length prefix must not read past the body.
    reader = .init(&.{ 0xff, 0xff, 0xff, 0xff, 'a' });
    try testing.expectError(error.EndOfMessage, reader.readBytes());
}

test "readRest consumes the rest of the body" {
    var reader: Reader = .init(&.{ 0x01, 0x02, 0x03 });
    try testing.expectEqual(0x01, try reader.readInt(u8));
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x03 }, reader.readRest());
    try testing.expectEqual(0, reader.remaining());
    try testing.expectEqualSlices(u8, &.{}, reader.readRest());
}

test "Login example from the specification" {
    // The "Sending Login Example" from docs/SLSKPROTOCOL.md, without the frame header.
    const body = test_support.login_example_body;
    const checksum = "d51c9a7e9353746a6020f9602d452929";

    var reader: Reader = .init(body);
    try testing.expectEqualStrings("username", try reader.readString());
    try testing.expectEqualStrings("password", try reader.readString());
    try testing.expectEqual(177, try reader.readInt(u32));
    try testing.expectEqualStrings(checksum, try reader.readString());
    try testing.expectEqual(1, try reader.readInt(u32));
    try testing.expectEqual(0, reader.remaining());

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: Writer = .init(testing.allocator, &list);
    try writer.writeString("username");
    try writer.writeString("password");
    try writer.writeInt(u32, 177);
    try writer.writeString(checksum);
    try writer.writeInt(u32, 1);
    try testing.expectEqualSlices(u8, body, list.items);
}

test "fuzz Reader" {
    // Random bytes, read as a random sequence of primitives, must give values or EndOfMessage.
    // The reader must never read past the body.
    try testing.fuzz({}, fuzzReader, .{ .corpus = fuzz_reader_corpus });
}

const FuzzPrimitive = enum(u8) { u8, u16, u32, u64, i32, bool, string, bytes, ip4, rest };

/// Each entry is a body, then the primitives to read from it. See `fuzzReader`.
const fuzz_reader_corpus: []const []const u8 = &.{
    // The Login example, read field by field.
    test_support.fuzzInput(&[_]test_support.FuzzValue{
        .{ .slice = test_support.login_example_body },
    } ++ test_support.fuzzEnums(FuzzPrimitive, &.{ .string, .string, .u32, .string, .u32 })),
    // Each integer type, an address, a bool, and the rest.
    test_support.fuzzInput(&[_]test_support.FuzzValue{
        .{ .slice = &.{
            0x12, 0x56, 0x34, 0xde, 0xbc, 0x9a, 0x78, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03,
            0x02, 0x01, 0xfe, 0xff, 0xff, 0xff, 0x01, 0x00, 0x00, 0x7f, 0x02, 0xaa,
        } },
    } ++ test_support.fuzzEnums(FuzzPrimitive, &.{
        .u8, .u16, .u32, .u64, .i32, .ip4, .bool, .rest,
    })),
    // A length prefix that is larger than the body.
    test_support.fuzzInput(&[_]test_support.FuzzValue{
        .{ .slice = &.{ 0xff, 0xff, 0xff, 0xff, 'a' } },
    } ++ test_support.fuzzEnums(FuzzPrimitive, &.{ .bytes, .u8, .u64 })),
};

fn fuzzReader(_: void, smith: *testing.Smith) anyerror!void {
    var body_buffer: [256]u8 = undefined;
    const body = body_buffer[0..smith.slice(&body_buffer)];

    var reader: Reader = .init(body);
    for (0..64) |_| {
        const remaining_before = reader.remaining();
        const result = switch (smith.value(FuzzPrimitive)) {
            .u8 => if (reader.readInt(u8)) |_| {} else |err| err,
            .u16 => if (reader.readInt(u16)) |_| {} else |err| err,
            .u32 => if (reader.readInt(u32)) |_| {} else |err| err,
            .u64 => if (reader.readInt(u64)) |_| {} else |err| err,
            .i32 => if (reader.readInt(i32)) |_| {} else |err| err,
            .bool => if (reader.readBool()) |_| {} else |err| err,
            .string => if (reader.readString()) |_| {} else |err| err,
            .bytes => if (reader.readBytes()) |_| {} else |err| err,
            .ip4 => if (reader.readIp4()) |_| {} else |err| err,
            .rest => _ = reader.readRest(),
        };
        try testing.expect(reader.remaining() <= remaining_before);
        result catch |err| switch (err) {
            error.EndOfMessage => {},
        };
    }
}
