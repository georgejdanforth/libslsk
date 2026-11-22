//! zlib compression for the peer messages that the specification compresses
//! (`SharedFileListResponse`, `FileSearchResponse`, and `FolderContentsResponse`).
//!
//! The compressed data is a zlib stream (RFC 1950): a header, a deflate stream, and an Adler-32
//! checksum of the decompressed data.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

const wire = @import("wire.zig");

pub const DecompressError = Allocator.Error || error{
    /// The data is not a valid zlib stream, the stream ends too early, or the checksum is wrong.
    InvalidCompressedData,
    /// The decompressed data is larger than the limit.
    DecompressedTooLarge,
};

/// Appends `data` to `writer` as a zlib stream. Memory for the compressor comes from
/// `writer.gpa` and is freed before the function returns.
pub fn compress(writer: wire.Writer, data: []const u8) Allocator.Error!void {
    const gpa = writer.gpa;
    // The compressor state is about 225 KiB, which is too large for the stack.
    const compressor = try gpa.create(flate.Compress);
    defer gpa.destroy(compressor);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    // `Compress.init` asserts that the output buffer has more than 8 bytes.
    try writer.list.ensureUnusedCapacity(gpa, 64);
    var output: std.Io.Writer.Allocating = .fromArrayList(gpa, writer.list);
    defer writer.list.* = output.toArrayList();

    // The output is an allocating writer, so each write error is an allocation failure.
    compressor.* = flate.Compress.init(&output.writer, window, .zlib, .default) catch {
        return error.OutOfMemory;
    };
    compressor.writer.writeAll(data) catch return error.OutOfMemory;
    compressor.finish() catch return error.OutOfMemory;
}

/// Decompresses a zlib stream. The result is allocated with `arena` and stays valid until the
/// caller frees the arena. On error, the arena can hold partial results.
///
/// Bytes after the end of the zlib stream are ignored.
pub fn decompress(
    arena: Allocator,
    data: []const u8,
    decompressed_size_max: u32,
) DecompressError![]const u8 {
    var input: std.Io.Reader = .fixed(data);
    // With no buffer, the decompressor uses the output list as its history window.
    var decompressor: flate.Decompress = .init(&input, .zlib, &.{});
    const limit: std.Io.Limit = .limited(decompressed_size_max);
    const decompressed = decompressor.reader.allocRemaining(arena, limit) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StreamTooLong => error.DecompressedTooLarge,
            // `decompressor.err` holds the cause. The caller does not need it.
            error.ReadFailed => error.InvalidCompressedData,
        };
    };
    assert(decompressed.len <= decompressed_size_max);

    // `flate.Decompress` reads the checksum, but it does not check it.
    const checksum = decompressor.container_metadata.zlib.adler;
    if (std.hash.Adler32.hash(decompressed) != checksum) return error.InvalidCompressedData;
    return decompressed;
}

const testing = std.testing;

/// `"hello hello hello world"`, compressed with Python `zlib.compress(data, 4)`. Nicotine+
/// compresses with the same function and level.
const python_hello = "\x78\x5e\xcb\x48\xcd\xc9\xc9\x57\xc8\x40\x22\xcb\xf3\x8b\x72\x52\x00\x68" ++
    "\x7d\x08\xc5";
const hello = "hello hello hello world";

fn expectRoundTrip(data: []const u8) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try compress(.init(testing.allocator, &list), data);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const decompressed = try decompress(arena_state.allocator(), list.items, @intCast(data.len));
    try testing.expectEqualSlices(u8, data, decompressed);
}

test "decompress data from Python zlib" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings(hello, try decompress(arena, python_hello, 1024));
    // A limit of exactly the decompressed size is accepted.
    try testing.expectEqualStrings(hello, try decompress(arena, python_hello, hello.len));
    // Bytes after the stream are ignored.
    try testing.expectEqualStrings(hello, try decompress(arena, python_hello ++ "xyz", 1024));
}

test "round trips" {
    try expectRoundTrip("");
    try expectRoundTrip(hello);

    // More than the 32 KiB history window, so that back references cross window boundaries.
    const large = try testing.allocator.alloc(u8, 200 * 1024);
    defer testing.allocator.free(large);
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    for (large, 0..) |*byte, index| {
        // Runs of repeated bytes and random bytes, so that both matches and literals occur.
        byte.* = if (index % 1000 < 500) @truncate(index / 1000) else prng.random().int(u8);
    }
    try expectRoundTrip(large);
}

test "compress appends to the list" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, "head");
    try compress(.init(testing.allocator, &list), hello);
    try testing.expectEqualStrings("head", list.items[0..4]);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const decompressed = try decompress(arena_state.allocator(), list.items[4..], 64);
    try testing.expectEqualStrings(hello, decompressed);
}

test "bad data gives an error" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Each case must give an error, not a crash and not wrong data.
    const cases = [_][]const u8{
        // No data.
        "",
        // Not a zlib header.
        "garbage data",
        // A zlib header with no deflate stream.
        "\x78\x5e",
        // The stream ends one byte before the end of the checksum.
        python_hello[0 .. python_hello.len - 1],
        // The stream ends in the middle of the deflate data.
        python_hello[0..10],
        // A gzip header.
        "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03",
        // A zlib header with a reserved block type (3) in the first block.
        "\x78\x5e\x07\x00",
    };
    for (cases) |data| {
        try testing.expectError(error.InvalidCompressedData, decompress(arena, data, 1024));
    }

    // A wrong checksum.
    var bad_checksum = python_hello.*;
    bad_checksum[bad_checksum.len - 1] ^= 0x01;
    try testing.expectError(error.InvalidCompressedData, decompress(arena, &bad_checksum, 1024));

    // A change in the deflate data. The decoder must give an error or wrong data that the
    // checksum detects.
    for (2..python_hello.len - 4) |index| {
        var changed = python_hello.*;
        changed[index] ^= 0x10;
        if (decompress(arena, &changed, 1024)) |decompressed| {
            // The change can give the same data, for example in an unused bit.
            try testing.expectEqualStrings(hello, decompressed);
        } else |err| switch (err) {
            error.InvalidCompressedData, error.DecompressedTooLarge => {},
            error.OutOfMemory => return err,
        }
    }
}

test "decompressed size limit" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const too_large = error.DecompressedTooLarge;
    try testing.expectError(too_large, decompress(arena, python_hello, hello.len - 1));
    try testing.expectError(too_large, decompress(arena, python_hello, 0));

    // 1 MiB of zeros compresses to about 1 KiB. The limit stops the decompression early.
    const zeros = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(zeros);
    @memset(zeros, 0);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try compress(.init(testing.allocator, &list), zeros);
    try testing.expect(list.items.len < 4096);
    try testing.expectError(error.DecompressedTooLarge, decompress(arena, list.items, 64 * 1024));
}

test "fuzz decompress" {
    // Random data must give an error or data with a correct checksum, and never more than the
    // limit.
    try testing.fuzz({}, fuzzDecompress, .{ .corpus = &.{
        python_hello,
        python_hello[0..10],
        "\x78\x5e\x07\x00",
    } });
}

fn fuzzDecompress(_: void, smith: *testing.Smith) anyerror!void {
    var data_buffer: [256]u8 = undefined;
    const data = data_buffer[0..smith.slice(&data_buffer)];

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const decompressed_size_max = 4096;
    if (decompress(arena_state.allocator(), data, decompressed_size_max)) |decompressed| {
        try testing.expect(decompressed.len <= decompressed_size_max);
    } else |err| switch (err) {
        error.InvalidCompressedData, error.DecompressedTooLarge => {},
        error.OutOfMemory => return err,
    }
}
