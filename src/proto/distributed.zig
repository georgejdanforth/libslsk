//! Distributed messages (see "Distributed Messages" in docs/SLSKPROTOCOL.md).
//!
//! `Message` holds the messages on a `D` connection. These frames have a `u8` code. Each
//! message has the same layout in both directions, so one union encodes and decodes both.
//!
//! The rules of `server.zig` also apply here: an unknown code decodes to `.unknown`, slices
//! point into the frame body, the decoder ignores bytes after the last field, and numbers keep
//! their wire types.
//!
//! A relay must forward the frame of a `Search` without changes, not a new encoding of the
//! decoded message. The frame can have fields after the search term that the decoder ignores.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const frame = @import("frame.zig");
const wire = @import("wire.zig");

const Unknown = common.Unknown;

/// The distributed message codes. Other codes decode to `.unknown`.
pub const Code = enum(u8) {
    ping = 0,
    search = 3,
    branch_level = 4,
    branch_root = 5,
    child_depth = 7,
    embedded_message = 93,
    _,
};

pub const DecodeError = wire.Reader.Error;

/// The messages on a `D` connection. Fields are in wire order.
pub const Message = union(enum) {
    /// Deprecated. Soulseek NS sends it, SoulseekQt does not.
    ping,
    search: Search,
    branch_level: BranchLevel,
    branch_root: BranchRoot,
    /// Obsolete.
    child_depth: ChildDepth,
    /// Deprecated. Older SoulseekQt versions send it.
    embedded_message: EmbeddedMessage,
    unknown: Unknown,

    pub const Search = struct {
        /// Always `search_identifier`. The core rejects other values, the same as Nicotine+.
        identifier: u32,
        /// The user who searches.
        username: []const u8,
        token: u32,
        search_term: []const u8,

        /// The code point of the ASCII character "1".
        pub const search_identifier: u32 = '1';
    };

    pub const BranchLevel = struct {
        /// 0 for a branch root.
        level: i32,
    };

    pub const BranchRoot = struct {
        /// The username of the branch root.
        username: []const u8,
    };

    pub const ChildDepth = struct {
        depth: u32,
    };

    /// A distributed message from the branch root, inside a distributed message.
    pub const EmbeddedMessage = struct {
        /// The code of the embedded message.
        code: Code,
        /// The body of the embedded message.
        body: []const u8,
        /// Older SoulseekQt versions send the code of this message (93) as a `u32`, so the
        /// body starts with the 3 other bytes of that `u32`. Nicotine+ skips these bytes, and
        /// so does `decode`. With this flag, `encode` writes them again.
        legacy_code_u32: bool,

        /// Returns the embedded message as a frame for `Message.decode`.
        pub fn innerFrame(embedded: EmbeddedMessage) frame.Frame {
            return .{ .code = @backingInt(embedded.code), .body = embedded.body };
        }
    };

    pub fn code(message: Message) u32 {
        return common.code(Code, Message, message);
    }

    /// Appends the complete frame, with the length and the code.
    pub fn encode(message: Message, writer: wire.Writer) Allocator.Error!void {
        const header_offset = try frame.begin(writer, .code_u8, message.code());
        switch (message) {
            .ping => {},
            .search => |search| {
                try writer.writeInt(u32, search.identifier);
                try writer.writeString(search.username);
                try writer.writeInt(u32, search.token);
                try writer.writeString(search.search_term);
            },
            .branch_level => |branch_level| try writer.writeInt(i32, branch_level.level),
            .branch_root => |branch_root| try writer.writeString(branch_root.username),
            .child_depth => |child_depth| try writer.writeInt(u32, child_depth.depth),
            .embedded_message => |embedded| {
                if (embedded.legacy_code_u32) {
                    try writer.writeRaw(&legacy_code_padding);
                } else if (embedded.code == .ping) {
                    // The decoder would take these bytes for the legacy padding.
                    assert(!std.mem.startsWith(u8, embedded.body, legacy_code_padding[1..]));
                }
                try writer.writeInt(u8, @backingInt(embedded.code));
                try writer.writeRaw(embedded.body);
            },
            .unknown => |unknown| {
                assert(unknown.code <= std.math.maxInt(u8));
                // A known code would decode to a different tag, so the round trip would fail.
                assert(!common.isKnownCode(Code, Message, unknown.code));
                try writer.writeRaw(unknown.body);
            },
        }
        frame.end(writer, header_offset);
    }

    /// Decodes a frame with a `u8` code. Slices point into the frame body.
    pub fn decode(message_frame: frame.Frame) DecodeError!Message {
        assert(message_frame.code <= std.math.maxInt(u8));
        var reader: wire.Reader = .init(message_frame.body);
        const message_code: Code = @fromBackingInt(@as(u8, @intCast(message_frame.code)));
        switch (message_code) {
            .ping => return .ping,
            .search => return .{ .search = .{
                .identifier = try reader.readInt(u32),
                .username = try reader.readString(),
                .token = try reader.readInt(u32),
                .search_term = try reader.readString(),
            } },
            .branch_level => return .{ .branch_level = .{
                .level = try reader.readInt(i32),
            } },
            .branch_root => return .{ .branch_root = .{
                .username = try reader.readString(),
            } },
            .child_depth => return .{ .child_depth = .{
                .depth = try reader.readInt(u32),
            } },
            .embedded_message => return .{
                .embedded_message = try decodeEmbeddedMessage(message_frame.body),
            },
            _ => return .{ .unknown = common.unknownMessage(message_frame) },
        }
    }

    fn decodeEmbeddedMessage(body: []const u8) DecodeError!EmbeddedMessage {
        // Source: Nicotine+ pynicotine/slskmessages.py, DistribEmbeddedMessage.unpack, commit
        // aea77045f475c168148dfa85ed3b900698e9c397.
        const legacy_code_u32 = std.mem.startsWith(u8, body, &legacy_code_padding);
        const padding_size = if (legacy_code_u32) legacy_code_padding.len else 0;
        var reader: wire.Reader = .init(body[padding_size..]);
        return .{
            .code = @fromBackingInt(try reader.readInt(u8)),
            .body = reader.readRest(),
            .legacy_code_u32 = legacy_code_u32,
        };
    }
};

/// The 3 high bytes of the `u32` code 93, from older SoulseekQt versions.
const legacy_code_padding = [3]u8{ 0x00, 0x00, 0x00 };

comptime {
    // Each code has a tag, and the union has an `unknown` tag.
    for (@typeInfo(Code).@"enum".field_names) |name| assert(@hasField(Message, name));
    assert(@typeInfo(Message).@"union".field_names.len == 7);
    assert(@backingInt(Code.embedded_message) <= std.math.maxInt(u8));
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const intBytes = test_support.intBytes;
const stringBytes = test_support.stringBytes;

const Golden = struct {
    message: Message,
    /// The complete frame.
    bytes: []const u8,
};

fn distributedFrame(comptime code: Code, comptime body: []const u8) []const u8 {
    return test_support.frameBytes(.code_u8, @backingInt(code), body);
}

fn splitFrame(bytes: []const u8) frame.Frame {
    return test_support.splitFrame(.code_u8, bytes);
}

/// Vectors from the data order in the specification. Nicotine+ has no vectors for distributed
/// messages.
const golden = [_]Golden{
    .{
        .message = .ping,
        .bytes = distributedFrame(.ping, ""),
    },
    .{
        .message = .{ .search = .{
            .identifier = Message.Search.search_identifier,
            .username = "bob",
            .token = 0x12345678,
            .search_term = "a b",
        } },
        .bytes = distributedFrame(.search, &([_]u8{ 0x31, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0x03, 0x00, 0x00, 0x00, 'b', 'o', 'b' } ++
            [_]u8{ 0x78, 0x56, 0x34, 0x12 } ++
            [_]u8{ 0x03, 0x00, 0x00, 0x00, 'a', ' ', 'b' })),
    },
    .{
        .message = .{ .branch_level = .{ .level = 3 } },
        .bytes = distributedFrame(.branch_level, &.{ 0x03, 0x00, 0x00, 0x00 }),
    },
    // A negative level, to check the sign.
    .{
        .message = .{ .branch_level = .{ .level = -1 } },
        .bytes = distributedFrame(.branch_level, &.{ 0xff, 0xff, 0xff, 0xff }),
    },
    .{
        .message = .{ .branch_root = .{ .username = "root" } },
        .bytes = distributedFrame(.branch_root, &.{ 0x04, 0x00, 0x00, 0x00, 'r', 'o', 'o', 't' }),
    },
    .{
        .message = .{ .child_depth = .{ .depth = 0x01020304 } },
        .bytes = distributedFrame(.child_depth, &.{ 0x04, 0x03, 0x02, 0x01 }),
    },
    // An embedded BranchLevel. The embedded body has no length and no code.
    .{
        .message = .{ .embedded_message = .{
            .code = .branch_level,
            .body = &.{ 0x02, 0x00, 0x00, 0x00 },
            .legacy_code_u32 = false,
        } },
        .bytes = distributedFrame(.embedded_message, &([_]u8{0x04} ++
            [_]u8{ 0x02, 0x00, 0x00, 0x00 })),
    },
    // An embedded Search from an older SoulseekQt version, with the code 93 as a u32.
    .{
        .message = .{ .embedded_message = .{
            .code = .search,
            .body = embedded_search_body,
            .legacy_code_u32 = true,
        } },
        .bytes = distributedFrame(.embedded_message, &([_]u8{ 0x00, 0x00, 0x00 } ++
            [_]u8{0x03} ++
            embedded_search_body.*)),
    },
};

/// The body of a Search, for the embedded vectors.
const embedded_search_body = &([_]u8{ 0x31, 0x00, 0x00, 0x00 } ++
    [_]u8{ 0x01, 0x00, 0x00, 0x00, 'u' } ++
    [_]u8{ 0x07, 0x00, 0x00, 0x00 } ++
    [_]u8{ 0x01, 0x00, 0x00, 0x00, 'q' });

comptime {
    // Each tag except `unknown` has at least one golden vector.
    for (@typeInfo(Message).@"union".field_names) |name| {
        if (std.mem.eql(u8, name, "unknown")) continue;
        for (golden) |entry| {
            if (std.mem.eql(u8, @tagName(entry.message), name)) break;
        } else @compileError("no golden vector for Message." ++ name);
    }
}

test "golden vectors" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: wire.Writer = .init(testing.allocator, &list);

    for (golden) |entry| {
        list.clearRetainingCapacity();
        try entry.message.encode(writer);
        try testing.expectEqualSlices(u8, entry.bytes, list.items);
        try testing.expectEqualDeep(entry.message, try Message.decode(splitFrame(entry.bytes)));
    }
}

test "embedded messages decode with innerFrame" {
    // Both forms of the embedded Search hold the same Search.
    const expected: Message = .{ .search = .{
        .identifier = Message.Search.search_identifier,
        .username = "u",
        .token = 7,
        .search_term = "q",
    } };
    var embedded_count: u32 = 0;
    for (golden) |entry| {
        const outer = try Message.decode(splitFrame(entry.bytes));
        if (outer != .embedded_message) continue;
        embedded_count += 1;
        const inner = try Message.decode(outer.embedded_message.innerFrame());
        if (outer.embedded_message.code == .search) {
            try testing.expectEqualDeep(expected, inner);
        } else {
            try testing.expectEqualDeep(Message{ .branch_level = .{ .level = 2 } }, inner);
        }
    }
    try testing.expectEqual(2, embedded_count);
}

/// Encodes `message`, decodes the bytes, and checks that the result is the same.
fn expectRoundTrip(message: Message) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try message.encode(.init(testing.allocator, &list));
    try testing.expectEqualDeep(message, try Message.decode(splitFrame(list.items)));
}

test "round trips with other values" {
    // Extreme values, empty strings, raw bytes that are not UTF-8, and unknown codes.
    try expectRoundTrip(.{ .search = .{
        .identifier = 0,
        .username = "",
        .token = std.math.maxInt(u32),
        .search_term = &.{ 0xc3, 0x28 },
    } });
    try expectRoundTrip(.{ .branch_level = .{ .level = std.math.minInt(i32) } });
    try expectRoundTrip(.{ .branch_level = .{ .level = std.math.maxInt(i32) } });
    try expectRoundTrip(.{ .branch_root = .{ .username = "" } });
    try expectRoundTrip(.{ .child_depth = .{ .depth = std.math.maxInt(u32) } });
    try expectRoundTrip(.{ .embedded_message = .{
        .code = @fromBackingInt(0xff),
        .body = "",
        .legacy_code_u32 = false,
    } });
    // An embedded Ping. Its body can start with one zero byte, but not two.
    try expectRoundTrip(.{ .embedded_message = .{
        .code = .ping,
        .body = &.{ 0x00, 0x01 },
        .legacy_code_u32 = false,
    } });
    try expectRoundTrip(.{ .embedded_message = .{
        .code = .ping,
        .body = &.{ 0x00, 0x00 },
        .legacy_code_u32 = true,
    } });
}

test "unknown codes decode to unknown" {
    const body = "any body";
    // Codes that the specification does not list, and the largest code.
    for ([_]u32{ 1, 2, 6, 8, 92, 0xff }) |code| {
        try testing.expect(!common.isKnownCode(Code, Message, code));
        const message_frame: frame.Frame = .{ .code = code, .body = body };
        try testing.expectEqualDeep(
            Message{ .unknown = .{ .code = code, .body = body } },
            try Message.decode(message_frame),
        );
        try expectRoundTrip(.{ .unknown = .{ .code = code, .body = body } });
    }
}

test "bytes after the last field are ignored" {
    // A Search with an extra field, as the specification describes for relays.
    const message_frame: frame.Frame = .{
        .code = @backingInt(Code.search),
        .body = comptime intBytes(u32, '1') ++ stringBytes("u") ++ intBytes(u32, 7) ++
            stringBytes("q") ++ "\xaa\xbb",
    };
    try testing.expectEqualDeep(Message{ .search = .{
        .identifier = Message.Search.search_identifier,
        .username = "u",
        .token = 7,
        .search_term = "q",
    } }, try Message.decode(message_frame));

    // Ping has an empty body.
    try testing.expectEqual(Message.ping, try Message.decode(.{ .code = 0, .body = "\xaa" }));
}

test "truncated bodies" {
    // A prefix must give `EndOfMessage`, or a message that encodes to a prefix of the prefix.
    // The second case happens for an embedded message, where the body is the rest of the
    // frame, and for a Ping.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: wire.Writer = .init(testing.allocator, &list);

    for (golden) |entry| {
        const full = splitFrame(entry.bytes);
        for (0..full.body.len) |prefix_size| {
            const prefix: frame.Frame = .{ .code = full.code, .body = full.body[0..prefix_size] };
            const message = Message.decode(prefix) catch |err| {
                try testing.expectEqual(error.EndOfMessage, err);
                continue;
            };
            try testing.expect(message == .embedded_message);
            list.clearRetainingCapacity();
            try message.encode(writer);
            try testing.expect(std.mem.startsWith(u8, prefix.body, splitFrame(list.items).body));
        }
    }
}

test "fuzz decode" {
    // Random bodies with random codes must give a message or an error. A decoded message must
    // encode to a frame that decodes to the same message.
    try testing.fuzz({}, fuzzDecode, .{ .corpus = fuzz_decode_corpus });
}

/// Encodes a corpus entry for `fuzzDecode`, in the order of its `Smith` calls.
fn fuzzDecodeInput(comptime code: u32, comptime body: []const u8) []const u8 {
    return comptime test_support.fuzzInput(&.{ .{ .int = code }, .{ .slice = body } });
}

const fuzz_decode_corpus: []const []const u8 = corpus: {
    var corpus: []const []const u8 = &.{};
    for (golden) |entry| {
        const message_frame = splitFrame(entry.bytes);
        corpus = corpus ++ [_][]const u8{fuzzDecodeInput(message_frame.code, message_frame.body)};
    }
    // An embedded Ping with two zero bytes: the legacy form with an empty body.
    corpus = corpus ++ [_][]const u8{fuzzDecodeInput(93, &.{ 0x00, 0x00, 0x00, 0x00, 0x00 })};
    break :corpus corpus;
};

fn fuzzDecode(_: void, smith: *testing.Smith) anyerror!void {
    const code = smith.value(u8);
    var body_buffer: [512]u8 = undefined;
    const body = body_buffer[0..smith.slice(&body_buffer)];
    const message_frame: frame.Frame = .{ .code = code, .body = body };

    const message = Message.decode(message_frame) catch |err| switch (err) {
        error.EndOfMessage => return,
    };
    try testing.expectEqual(message_frame.code, message.code());

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try message.encode(.init(testing.allocator, &list));
    const encoded = splitFrame(list.items);
    // The decoder ignores extra bytes, so the encoded body is never longer.
    try testing.expect(encoded.body.len <= message_frame.body.len);
    try testing.expectEqualDeep(message, try Message.decode(encoded));
}
