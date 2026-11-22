//! File connection messages (see "File Messages" in docs/SLSKPROTOCOL.md).
//!
//! An `F` connection starts with a `PeerInit` or `PierceFirewall` frame. After that frame, the
//! messages have no length and no code. The uploader sends `TransferInit`, the downloader sends
//! `Offset`, and then the uploader sends the file bytes.
//!
//! Each message has a fixed size, so `decode` takes an array of that size and cannot fail. The
//! caller collects the bytes (for example with `frame.Decoder.takeUnread`) until `size` bytes
//! are available.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const wire = @import("wire.zig");

/// The uploader sends this first.
pub const TransferInit = struct {
    /// The token from the `TransferRequest` peer message.
    token: u32,

    pub const size = @sizeOf(u32);

    pub fn encode(message: TransferInit, writer: wire.Writer) Allocator.Error!void {
        try writer.writeInt(u32, message.token);
    }

    pub fn decode(bytes: *const [size]u8) TransferInit {
        return .{ .token = std.mem.readInt(u32, bytes, .little) };
    }
};

/// The downloader sends this after `TransferInit`.
pub const Offset = struct {
    /// The number of bytes that the downloader already has. Soulseek NS sends
    /// `maxInt(u64)` (-1) if it has more than 2 GB of the file. The core must check the offset
    /// against the file size.
    offset: u64,

    pub const size = @sizeOf(u64);

    pub fn encode(message: Offset, writer: wire.Writer) Allocator.Error!void {
        try writer.writeInt(u64, message.offset);
    }

    pub fn decode(bytes: *const [size]u8) Offset {
        return .{ .offset = std.mem.readInt(u64, bytes, .little) };
    }
};

comptime {
    assert(TransferInit.size == 4);
    assert(Offset.size == 8);
}

const testing = std.testing;
const frame = @import("frame.zig");
const test_support = @import("test_support.zig");
const intBytes = test_support.intBytes;

test "TransferInit golden vectors" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: wire.Writer = .init(testing.allocator, &list);

    const golden = [_]struct { message: TransferInit, bytes: [TransferInit.size]u8 }{
        .{ .message = .{ .token = 0x12345678 }, .bytes = .{ 0x78, 0x56, 0x34, 0x12 } },
        .{ .message = .{ .token = 0 }, .bytes = .{ 0x00, 0x00, 0x00, 0x00 } },
        .{ .message = .{ .token = std.math.maxInt(u32) }, .bytes = .{ 0xff, 0xff, 0xff, 0xff } },
    };
    for (golden) |entry| {
        list.clearRetainingCapacity();
        try entry.message.encode(writer);
        try testing.expectEqualSlices(u8, &entry.bytes, list.items);
        try testing.expectEqual(entry.message, TransferInit.decode(&entry.bytes));
    }
}

test "Offset golden vectors" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: wire.Writer = .init(testing.allocator, &list);

    const golden = [_]struct { message: Offset, bytes: [Offset.size]u8 }{
        // A resume after 5 GB, which needs more than 32 bits.
        .{
            .message = .{ .offset = 5000000000 },
            .bytes = .{ 0x00, 0xf2, 0x05, 0x2a, 0x01, 0x00, 0x00, 0x00 },
        },
        .{ .message = .{ .offset = 0 }, .bytes = @splat(0x00) },
        // The -1 from Soulseek NS.
        .{ .message = .{ .offset = std.math.maxInt(u64) }, .bytes = @splat(0xff) },
    };
    for (golden) |entry| {
        list.clearRetainingCapacity();
        try entry.message.encode(writer);
        try testing.expectEqualSlices(u8, &entry.bytes, list.items);
        try testing.expectEqual(entry.message, Offset.decode(&entry.bytes));
    }
}

test "file messages after a PeerInit frame" {
    // An `F` connection from the uploader: `PeerInit`, then `TransferInit` with no frame. The
    // downloader answers with `Offset`. The bytes arrive in two reads.
    const peer_init = comptime test_support.frameBytes(.code_u8, 1, "x");
    const stream = peer_init ++ comptime intBytes(u32, 7);

    var decoder: frame.Decoder = .init(.{ .frame_size_max = 1024 });
    defer decoder.deinit(testing.allocator);
    try decoder.feed(testing.allocator, stream[0 .. peer_init.len + 1]);
    _ = (try decoder.next(.code_u8)).?;

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(testing.allocator);
    try pending.appendSlice(testing.allocator, decoder.takeUnread());
    try testing.expect(pending.items.len < TransferInit.size);

    try decoder.feed(testing.allocator, stream[peer_init.len + 1 ..]);
    try pending.appendSlice(testing.allocator, decoder.takeUnread());
    try testing.expectEqual(TransferInit.size, pending.items.len);
    const transfer_init = TransferInit.decode(pending.items[0..TransferInit.size]);
    try testing.expectEqual(7, transfer_init.token);
}
