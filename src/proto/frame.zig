//! Message frames and an incremental frame decoder.
//!
//! Each framed message starts with a `u32` length. The length counts the code and the body,
//! but not the length field itself. The code width depends on the connection type and on
//! the connection state (see `Format`).
//!
//! The file connection (`F`) messages have no frame. After the `PeerInit` frame of an `F`
//! connection, the caller takes the rest of the bytes with `Decoder.takeUnread`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const wire = @import("wire.zig");

pub const length_size = @sizeOf(u32);

pub const Format = enum {
    /// A `u32` code. Server messages and peer messages.
    code_u32,
    /// A `u8` code. Peer init messages and distributed messages.
    code_u8,

    pub fn codeSize(format: Format) u32 {
        return switch (format) {
            .code_u32 => @sizeOf(u32),
            .code_u8 => @sizeOf(u8),
        };
    }
};

pub const header_size_max = length_size + Format.code_u32.codeSize();

comptime {
    assert(Format.code_u8.codeSize() < Format.code_u32.codeSize());
    assert(header_size_max == 8);
}

pub const Frame = struct {
    code: u32,
    /// The message contents after the code.
    body: []const u8,
};

/// Appends a frame header with a placeholder length. Write the body, then call `end` with
/// the returned offset.
pub fn begin(writer: wire.Writer, format: Format, code: u32) Allocator.Error!usize {
    const header_offset = writer.list.items.len;
    try writer.writeInt(u32, 0);
    switch (format) {
        .code_u32 => try writer.writeInt(u32, code),
        .code_u8 => try writer.writeInt(u8, @intCast(code)),
    }
    return header_offset;
}

/// Sets the length field of the frame that starts at `header_offset`.
pub fn end(writer: wire.Writer, header_offset: usize) void {
    const items = writer.list.items;
    assert(header_offset + length_size <= items.len);
    // The length field still holds the placeholder from `begin`.
    assert(std.mem.readInt(u32, items[header_offset..][0..length_size], .little) == 0);

    const length = items.len - header_offset - length_size;
    assert(length >= Format.code_u8.codeSize());
    assert(length <= std.math.maxInt(u32));
    std.mem.writeInt(u32, items[header_offset..][0..length_size], @intCast(length), .little);
}

/// Splits a byte stream into frames. It accepts partial reads.
///
/// Usage: call `feed` with the bytes from each read, then call `next` until it returns null.
/// `feed` asserts that no complete frame is waiting, so the buffer holds at most one
/// incomplete frame and the bytes of one read.
pub const Decoder = struct {
    buffer: std.ArrayList(u8),
    /// The start of the bytes that `next` did not return yet.
    offset: usize,
    /// The largest length field that the decoder accepts.
    frame_size_max: u32,

    pub const Options = struct {
        /// The largest length field to accept. The length counts the code and the body.
        frame_size_max: u32,
    };

    pub const Error = error{
        /// The length field is larger than `frame_size_max`.
        FrameTooLarge,
        /// The length field is smaller than the code size.
        FrameTooShort,
    };

    pub fn init(options: Options) Decoder {
        assert(options.frame_size_max >= Format.code_u32.codeSize());
        return .{ .buffer = .empty, .offset = 0, .frame_size_max = options.frame_size_max };
    }

    pub fn deinit(decoder: *Decoder, gpa: Allocator) void {
        decoder.buffer.deinit(gpa);
        decoder.* = undefined;
    }

    /// Adds bytes from the connection. Frames from earlier `next` calls become invalid.
    pub fn feed(decoder: *Decoder, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
        assert(decoder.offset <= decoder.buffer.items.len);
        // The caller must drain the decoder first, and must close the connection after an
        // error. Both keep the buffer small.
        if (peekFrameSize(decoder.unread(), .code_u8, decoder.frame_size_max)) |frame_size| {
            assert(frame_size == null);
        } else |_| unreachable;

        const unread_size = decoder.buffer.items.len - decoder.offset;
        std.mem.copyForwards(u8, decoder.buffer.items[0..unread_size], decoder.unread());
        decoder.buffer.shrinkRetainingCapacity(unread_size);
        decoder.offset = 0;

        try decoder.buffer.appendSlice(gpa, bytes);
    }

    /// Returns the next complete frame, or null if more bytes are necessary. The frame stays
    /// valid until the next `feed` or `deinit`. After an error, the stream is broken and the
    /// caller must close the connection.
    pub fn next(decoder: *Decoder, format: Format) Error!?Frame {
        const bytes = decoder.unread();
        const frame_size = try peekFrameSize(bytes, format, decoder.frame_size_max) orelse {
            return null;
        };
        assert(frame_size <= bytes.len);
        assert(frame_size >= length_size + format.codeSize());

        var reader: wire.Reader = .init(bytes[length_size..frame_size]);
        const code: u32 = switch (format) {
            .code_u32 => reader.readInt(u32) catch unreachable,
            .code_u8 => reader.readInt(u8) catch unreachable,
        };
        decoder.offset += frame_size;
        assert(decoder.offset <= decoder.buffer.items.len);
        return .{ .code = code, .body = reader.readRest() };
    }

    /// Returns the bytes after the last frame and consumes them. Use this when the stream
    /// stops using frames, for example after the `PeerInit` frame of an `F` connection.
    /// The bytes stay valid until the next `feed` or `deinit`.
    pub fn takeUnread(decoder: *Decoder) []const u8 {
        const bytes = decoder.unread();
        decoder.offset = decoder.buffer.items.len;
        return bytes;
    }

    fn unread(decoder: *const Decoder) []const u8 {
        return decoder.buffer.items[decoder.offset..];
    }
};

/// Returns the size of the frame at the start of `bytes`, with the length field. Returns null
/// if `bytes` does not hold the complete frame.
fn peekFrameSize(bytes: []const u8, format: Format, frame_size_max: u32) Decoder.Error!?usize {
    if (bytes.len < length_size) return null;

    const length = std.mem.readInt(u32, bytes[0..length_size], .little);
    // Check the length as soon as it arrives. Then the decoder never buffers an oversize frame.
    if (length > frame_size_max) return error.FrameTooLarge;
    if (length < format.codeSize()) return error.FrameTooShort;

    const frame_size = @as(usize, length_size) + length;
    if (frame_size <= bytes.len) {
        return frame_size;
    } else {
        return null;
    }
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const FuzzValue = test_support.FuzzValue;

fn encodeFrame(list: *std.ArrayList(u8), format: Format, code: u32, body: []const u8) !void {
    const writer: wire.Writer = .init(testing.allocator, list);
    const header_offset = try begin(writer, format, code);
    try writer.writeRaw(body);
    end(writer, header_offset);
}

test "encode frames" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);

    try encodeFrame(&list, .code_u32, 0x01020304, &.{ 0xaa, 0xbb });
    try encodeFrame(&list, .code_u8, 0x05, &.{0xcc});
    try encodeFrame(&list, .code_u8, 0x06, &.{});

    const expected = [_]u8{ 0x06, 0x00, 0x00, 0x00, 0x04, 0x03, 0x02, 0x01, 0xaa, 0xbb } ++
        [_]u8{ 0x02, 0x00, 0x00, 0x00, 0x05, 0xcc } ++
        [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x06 };
    try testing.expectEqualSlices(u8, &expected, list.items);
}

const login_example = test_support.login_example;

test "decode the Login example" {
    var decoder: Decoder = .init(.{ .frame_size_max = 1024 });
    defer decoder.deinit(testing.allocator);

    try decoder.feed(testing.allocator, &login_example);
    const frame = (try decoder.next(.code_u32)).?;
    try testing.expectEqual(1, frame.code);
    try testing.expectEqualSlices(u8, test_support.login_example_body, frame.body);
    try testing.expectEqual(null, try decoder.next(.code_u32));

    var reader: wire.Reader = .init(frame.body);
    try testing.expectEqualStrings("username", try reader.readString());
}

const Expected = struct { format: Format, code: u32, body: []const u8 };

/// A stream with both formats, as on a `P` connection: a `PeerInit`-like frame with a `u8`
/// code, then peer frames with `u32` codes. It also has an empty body.
const mixed_frames = [_]Expected{
    .{ .format = .code_u8, .code = 1, .body = "init" },
    .{ .format = .code_u32, .code = 1, .body = test_support.login_example_body },
    .{ .format = .code_u32, .code = 0xdeadbeef, .body = "" },
    .{ .format = .code_u32, .code = 9, .body = "x" },
};

/// The bytes of `mixed_frames`.
const mixed_stream = stream: {
    var stream: []const u8 = &.{};
    for (mixed_frames) |expected| {
        stream = stream ++ test_support.frameBytes(expected.format, expected.code, expected.body);
    }
    break :stream stream;
};

fn encodeFrames(list: *std.ArrayList(u8), frames: []const Expected) !void {
    for (frames) |expected| try encodeFrame(list, expected.format, expected.code, expected.body);
}

/// Feeds `chunks` in order, drains after each one, and checks the frames against `frames`.
fn expectFrames(chunks: []const []const u8, frames: []const Expected) !void {
    var decoder: Decoder = .init(.{ .frame_size_max = 1024 });
    defer decoder.deinit(testing.allocator);

    var frame_index: usize = 0;
    for (chunks) |chunk| {
        try decoder.feed(testing.allocator, chunk);
        while (frame_index < frames.len) {
            const expected = frames[frame_index];
            const frame = try decoder.next(expected.format) orelse break;
            try testing.expectEqual(expected.code, frame.code);
            try testing.expectEqualSlices(u8, expected.body, frame.body);
            frame_index += 1;
        }
    }
    try testing.expectEqual(frames.len, frame_index);
    try testing.expectEqual(0, decoder.takeUnread().len);
}

test "decode with a split at every byte position" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try encodeFrames(&list, &mixed_frames);
    const stream = list.items;

    for (0..stream.len + 1) |split| {
        try expectFrames(&.{ stream[0..split], stream[split..] }, &mixed_frames);
    }
    for (0..stream.len + 1) |split_a| {
        for (split_a..stream.len + 1) |split_b| {
            const chunks = [_][]const u8{
                stream[0..split_a],
                stream[split_a..split_b],
                stream[split_b..],
            };
            try expectFrames(&chunks, &mixed_frames);
        }
    }
}

test "decode one byte at a time" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try encodeFrames(&list, &mixed_frames);

    var chunks: std.ArrayList([]const u8) = .empty;
    defer chunks.deinit(testing.allocator);
    for (0..list.items.len) |index| {
        try chunks.append(testing.allocator, list.items[index..][0..1]);
    }
    try expectFrames(chunks.items, &mixed_frames);
}

test "frames stay valid until the next feed" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try encodeFrame(&list, .code_u32, 1, "first");
    try encodeFrame(&list, .code_u32, 2, "second");

    var decoder: Decoder = .init(.{ .frame_size_max = 1024 });
    defer decoder.deinit(testing.allocator);
    try decoder.feed(testing.allocator, list.items);

    const first = (try decoder.next(.code_u32)).?;
    const second = (try decoder.next(.code_u32)).?;
    try testing.expectEqualStrings("first", first.body);
    try testing.expectEqualStrings("second", second.body);
}

test "frame size limit" {
    var decoder: Decoder = .init(.{ .frame_size_max = 8 });
    defer decoder.deinit(testing.allocator);

    // A length of exactly frame_size_max is accepted.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try encodeFrame(&list, .code_u32, 7, "abcd");
    try decoder.feed(testing.allocator, list.items);
    const frame = (try decoder.next(.code_u32)).?;
    try testing.expectEqualStrings("abcd", frame.body);

    // One more byte is an error as soon as the length field arrives, before the body.
    try decoder.feed(testing.allocator, &.{ 0x09, 0x00, 0x00, 0x00 });
    try testing.expectError(error.FrameTooLarge, decoder.next(.code_u32));
    // The decoder stays broken.
    try testing.expectError(error.FrameTooLarge, decoder.next(.code_u32));
}

test "huge length field" {
    var decoder: Decoder = .init(.{ .frame_size_max = 1024 });
    defer decoder.deinit(testing.allocator);
    try decoder.feed(testing.allocator, &.{ 0xff, 0xff, 0xff, 0xff });
    try testing.expectError(error.FrameTooLarge, decoder.next(.code_u8));
}

test "frame shorter than its code" {
    var decoder: Decoder = .init(.{ .frame_size_max = 1024 });
    defer decoder.deinit(testing.allocator);

    // A length of 3 cannot hold a u32 code, but it can hold a u8 code.
    try decoder.feed(testing.allocator, &.{ 0x03, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03 });
    try testing.expectError(error.FrameTooShort, decoder.next(.code_u32));
    const frame = (try decoder.next(.code_u8)).?;
    try testing.expectEqual(1, frame.code);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x03 }, frame.body);

    // A length of 0 cannot hold any code.
    try decoder.feed(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00 });
    try testing.expectError(error.FrameTooShort, decoder.next(.code_u8));
}

test "takeUnread returns the bytes after the last frame" {
    // An `F` connection: a PeerInit frame, then a raw token with no frame.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try encodeFrame(&list, .code_u8, 1, "init");
    try list.appendSlice(testing.allocator, &.{ 0x01, 0x02, 0x03, 0x04 });

    var decoder: Decoder = .init(.{ .frame_size_max = 1024 });
    defer decoder.deinit(testing.allocator);
    try decoder.feed(testing.allocator, list.items);

    const frame = (try decoder.next(.code_u8)).?;
    try testing.expectEqualStrings("init", frame.body);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03, 0x04 }, decoder.takeUnread());
    try testing.expectEqual(0, decoder.takeUnread().len);
}

test "feed with no bytes" {
    var decoder: Decoder = .init(.{ .frame_size_max = 1024 });
    defer decoder.deinit(testing.allocator);
    try decoder.feed(testing.allocator, &.{});
    try testing.expectEqual(null, try decoder.next(.code_u32));
}

test "fuzz Decoder with random bytes" {
    // Random bytes, fed in random chunks and read in random formats, must not crash the
    // decoder. The results must match a decoder that gets all the bytes in one feed. Each
    // error must agree with the length field at the error position.
    try testing.fuzz({}, fuzzDecoderRandom, .{ .corpus = fuzz_random_corpus });
}

const fuzz_random_formats_count = 64;

const FuzzRandomOptions = struct {
    frame_size_max: u32,
    stream: []const u8,
    formats: []const Format,
    /// After the end of this list, the chunk size is 1.
    chunk_sizes: []const u32,
};

/// Encodes a corpus entry for `fuzzDecoderRandom`, in the order of its `Smith` calls.
fn fuzzRandomInput(comptime options: FuzzRandomOptions) []const u8 {
    comptime {
        assert(options.formats.len <= fuzz_random_formats_count);
        const padding_count = fuzz_random_formats_count - options.formats.len;
        const padding: [padding_count]Format = @splat(.code_u32);
        var values: []const FuzzValue = &.{
            .{ .int = options.frame_size_max },
            .{ .slice = options.stream },
        };
        values = values ++ test_support.fuzzEnums(Format, options.formats ++ &padding);
        for (options.chunk_sizes) |chunk_size| {
            values = values ++ [_]FuzzValue{.{ .int = chunk_size }};
        }
        return test_support.fuzzInput(values);
    }
}

const fuzz_random_corpus: []const []const u8 = &.{
    // Valid frames in both formats, in three chunks and then one byte at a time.
    fuzzRandomInput(.{
        .frame_size_max = 128,
        .stream = mixed_stream,
        .formats = &.{ .code_u8, .code_u32, .code_u32, .code_u32 },
        .chunk_sizes = &.{ 3, 50, 30 },
    }),
    // A frame of exactly frame_size_max, then a frame that is one byte too large.
    fuzzRandomInput(.{
        .frame_size_max = 8,
        .stream = test_support.frameBytes(.code_u32, 7, "abcd") ++ &[_]u8{ 9, 0, 0, 0, 'x' },
        .formats = &.{},
        .chunk_sizes = &.{},
    }),
    // A length of 3 is too short for a u32 code.
    fuzzRandomInput(.{
        .frame_size_max = 64,
        .stream = &.{ 3, 0, 0, 0, 1, 2, 3 },
        .formats = &.{.code_u32},
        .chunk_sizes = &.{7},
    }),
    // A length of 3 is valid for a u8 code. A length of 0 is too short for both formats.
    fuzzRandomInput(.{
        .frame_size_max = 64,
        .stream = &.{ 3, 0, 0, 0, 1, 2, 3, 0, 0, 0, 0 },
        .formats = &.{ .code_u8, .code_u8 },
        .chunk_sizes = &.{ 2, 9 },
    }),
    // The stream ends in the middle of a frame.
    fuzzRandomInput(.{
        .frame_size_max = 128,
        .stream = login_example[0..40],
        .formats = &.{},
        .chunk_sizes = &.{40},
    }),
};

fn fuzzDecoderRandom(_: void, smith: *testing.Smith) anyerror!void {
    const frame_size_max = smith.valueRangeAtMost(u32, 4, 128);
    var stream_buffer: [512]u8 = undefined;
    const stream = stream_buffer[0..smith.slice(&stream_buffer)];
    var formats: [fuzz_random_formats_count]Format = undefined;
    for (&formats) |*format| format.* = smith.value(Format);

    var reference: Decoder = .init(.{ .frame_size_max = frame_size_max });
    defer reference.deinit(testing.allocator);
    try reference.feed(testing.allocator, stream);

    var decoder: Decoder = .init(.{ .frame_size_max = frame_size_max });
    defer decoder.deinit(testing.allocator);

    var stream_offset: usize = 0;
    var frame_count: usize = 0;
    while (stream_offset < stream.len) {
        const chunk_size = smith.valueRangeAtMost(u32, 1, @intCast(stream.len - stream_offset));
        try decoder.feed(testing.allocator, stream[stream_offset..][0..chunk_size]);
        stream_offset += chunk_size;

        while (frame_count < formats.len) {
            const format = formats[frame_count];
            const position = reference.offset;
            const expected = reference.next(format);
            const actual = decoder.next(format);
            const actual_frame = actual catch |actual_err| {
                try testing.expectError(actual_err, expected);
                const length = std.mem.readInt(u32, stream[position..][0..length_size], .little);
                switch (actual_err) {
                    error.FrameTooLarge => try testing.expect(length > frame_size_max),
                    error.FrameTooShort => try testing.expect(length < format.codeSize()),
                }
                return;
            };
            if (actual_frame) |frame| {
                const expected_frame = (try expected).?;
                try testing.expectEqual(expected_frame.code, frame.code);
                try testing.expectEqualSlices(u8, expected_frame.body, frame.body);
                frame_count += 1;
            } else {
                // The chunked decoder lacks bytes. If the reference has all of them, it can
                // have a frame or an error. Either way, the next feed starts at this position.
                if (stream_offset == stream.len) try testing.expect((try expected) == null);
                reference.offset = position;
                break;
            }
        }
        if (frame_count == formats.len) return;
    }
}

test "fuzz Decoder round trip" {
    // Frames that the encoder writes, fed in random chunks, must decode to the same frames.
    try testing.fuzz({}, fuzzDecoderRoundTrip, .{ .corpus = fuzz_round_trip_corpus });
}

const fuzz_round_trip_frame_count_max = 16;
const fuzz_round_trip_body_size_max = 80;

comptime {
    for (mixed_frames) |expected| assert(expected.body.len <= fuzz_round_trip_body_size_max);
}

/// Encodes a corpus entry for `fuzzDecoderRoundTrip`, in the order of its `Smith` calls.
/// After the end of `chunk_sizes`, the chunk size is 1.
fn fuzzRoundTripInput(
    comptime frames: []const Expected,
    comptime chunk_sizes: []const u32,
) []const u8 {
    comptime {
        assert(frames.len <= fuzz_round_trip_frame_count_max);
        var values: []const FuzzValue = &.{};
        for (frames) |expected| {
            values = values ++ [_]FuzzValue{
                .{ .eos = false },
                .{ .int = @backingInt(expected.format) },
                .{ .int = expected.code },
                .{ .slice = expected.body },
            };
        }
        values = values ++ [_]FuzzValue{.{ .eos = true }};
        for (chunk_sizes) |chunk_size| values = values ++ [_]FuzzValue{.{ .int = chunk_size }};
        return test_support.fuzzInput(values);
    }
}

const fuzz_round_trip_corpus: []const []const u8 = &.{
    fuzzRoundTripInput(&mixed_frames, &.{}),
    fuzzRoundTripInput(&mixed_frames, &.{ 5, 7, 60 }),
    // The largest codes, and the largest body.
    fuzzRoundTripInput(&.{
        .{ .format = .code_u8, .code = 0xff, .body = "" },
        .{
            .format = .code_u32,
            .code = 0xffffffff,
            .body = &@as([fuzz_round_trip_body_size_max]u8, @splat(0xab)),
        },
    }, &.{ 4, 1, 100 }),
};

fn fuzzDecoderRoundTrip(_: void, smith: *testing.Smith) anyerror!void {
    const frame_count_max = fuzz_round_trip_frame_count_max;
    var frames: [frame_count_max]Expected = undefined;
    var bodies: [frame_count_max][fuzz_round_trip_body_size_max]u8 = undefined;

    var frame_count: usize = 0;
    while (frame_count < frame_count_max and !smith.eosWeightedSimple(7, 1)) {
        const format = smith.value(Format);
        const code: u32 = switch (format) {
            .code_u32 => smith.value(u32),
            .code_u8 => smith.value(u8),
        };
        const body_size = smith.slice(&bodies[frame_count]);
        frames[frame_count] = .{
            .format = format,
            .code = code,
            .body = bodies[frame_count][0..body_size],
        };
        frame_count += 1;
    }

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try encodeFrames(&list, frames[0..frame_count]);

    var chunks: std.ArrayList([]const u8) = .empty;
    defer chunks.deinit(testing.allocator);
    var stream_offset: usize = 0;
    while (stream_offset < list.items.len) {
        const chunk_size_max: u32 = @intCast(list.items.len - stream_offset);
        const chunk_size = smith.valueRangeAtMost(u32, 1, chunk_size_max);
        try chunks.append(testing.allocator, list.items[stream_offset..][0..chunk_size]);
        stream_offset += chunk_size;
    }
    try expectFrames(chunks.items, frames[0..frame_count]);
}
