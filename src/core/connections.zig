//! Connection handles and the table that maps them to connection state.
//!
//! A handle holds a slot index and a generation. When a slot is used again, its generation
//! changes, so an old handle does not find the new connection.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const proto = @import("../proto/root.zig");
const frame = proto.frame;

/// A connection handle. The core assigns it in an `open_conn` action. The value 0 is never a
/// valid handle, so a C host can use 0 for "no connection".
pub const Conn = enum(u32) {
    _,

    pub fn fromHandle(value: Handle) Conn {
        assert(value.generation != 0);
        return @fromBackingInt(@as(u32, @bitCast(value)));
    }

    pub fn handle(conn: Conn) Handle {
        return @bitCast(@backingInt(conn));
    }
};

pub const Handle = packed struct(u32) {
    index: u16,
    generation: u16,
};

/// The largest number of connections that one table can hold.
pub const connection_count_limit = std.math.maxInt(u16) + 1;

pub const State = enum {
    /// The core asked the host to open the connection. The host did not answer yet.
    connecting,
    /// The connection is open and can carry bytes.
    open,
    /// The core asked the host to close the connection. The host did not confirm yet.
    closing,
};

pub const Connection = struct {
    state: State,
    /// The frame format of the next message on this connection.
    format: frame.Format,
    decoder: frame.Decoder,
};

/// A fixed number of slots, allocated at init.
pub const Table = struct {
    slots: []Slot,
    /// A stack of free slot indexes. The next free index is `free[free_count - 1]`.
    free: []u16,
    free_count: u32,

    const Slot = struct {
        /// The generation of the next handle for this slot. It is never 0.
        generation: u16,
        connection: ?Connection,
    };

    pub fn init(gpa: Allocator, connection_count_max: u32) Allocator.Error!Table {
        assert(connection_count_max > 0);
        assert(connection_count_max <= connection_count_limit);

        const slots = try gpa.alloc(Slot, connection_count_max);
        errdefer gpa.free(slots);
        const free = try gpa.alloc(u16, connection_count_max);
        errdefer comptime unreachable;

        @memset(slots, .{ .generation = 1, .connection = null });
        // Push the indexes in reverse order, so that the first handle uses slot 0.
        for (free, 0..) |*index, position| {
            index.* = @intCast(connection_count_max - 1 - position);
        }
        return .{ .slots = slots, .free = free, .free_count = connection_count_max };
    }

    pub fn deinit(table: *Table, gpa: Allocator) void {
        for (table.slots) |*slot| {
            if (slot.connection) |*connection| connection.decoder.deinit(gpa);
        }
        gpa.free(table.slots);
        gpa.free(table.free);
        table.* = undefined;
    }

    /// Takes a free slot for `connection` and returns its handle. Returns null if all slots
    /// are in use.
    pub fn acquire(table: *Table, connection: Connection) ?Conn {
        assert(table.free_count <= table.slots.len);
        if (table.free_count == 0) return null;

        table.free_count -= 1;
        const index = table.free[table.free_count];
        const slot = &table.slots[index];
        assert(slot.connection == null);
        assert(slot.generation != 0);

        slot.connection = connection;
        return .fromHandle(.{ .index = index, .generation = slot.generation });
    }

    /// Frees the slot of `conn` and deinits its decoder. The handle becomes invalid.
    pub fn release(table: *Table, gpa: Allocator, conn: Conn) void {
        const connection = table.get(conn).?;
        connection.decoder.deinit(gpa);

        const index = conn.handle().index;
        const slot = &table.slots[index];
        slot.connection = null;
        // Skip 0 when the generation wraps, because 0 is not a valid handle.
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;

        assert(table.free_count < table.slots.len);
        table.free[table.free_count] = index;
        table.free_count += 1;
    }

    /// Returns the connection of `conn`, or null if the handle is not in use.
    pub fn get(table: *Table, conn: Conn) ?*Connection {
        const handle = conn.handle();
        if (handle.index >= table.slots.len) return null;

        const slot = &table.slots[handle.index];
        if (slot.generation != handle.generation) return null;
        if (slot.connection) |*connection| {
            return connection;
        } else {
            return null;
        }
    }

    pub fn count(table: *const Table) u32 {
        assert(table.free_count <= table.slots.len);
        return @intCast(table.slots.len - table.free_count);
    }
};

const testing = std.testing;

fn testConnection() Connection {
    return .{
        .state = .connecting,
        .format = .code_u32,
        .decoder = .init(.{ .frame_size_max = 1024 }),
    };
}

test "Table: handles are unique, nonzero, and limited" {
    var table: Table = try .init(testing.allocator, 3);
    defer table.deinit(testing.allocator);

    const a = table.acquire(testConnection()).?;
    const b = table.acquire(testConnection()).?;
    const c = table.acquire(testConnection()).?;
    try testing.expectEqual(null, table.acquire(testConnection()));
    try testing.expectEqual(3, table.count());

    try testing.expect(a != b);
    try testing.expect(b != c);
    try testing.expect(a != c);
    for ([_]Conn{ a, b, c }, 0..) |conn, index| {
        try testing.expect(@backingInt(conn) != 0);
        try testing.expectEqual(index, conn.handle().index);
        try testing.expect(table.get(conn) != null);
    }
}

test "Table: a released handle does not find the next connection in its slot" {
    var table: Table = try .init(testing.allocator, 1);
    defer table.deinit(testing.allocator);

    const first = table.acquire(testConnection()).?;
    table.release(testing.allocator, first);
    try testing.expectEqual(null, table.get(first));
    try testing.expectEqual(0, table.count());

    const second = table.acquire(testConnection()).?;
    try testing.expectEqual(first.handle().index, second.handle().index);
    try testing.expect(first != second);
    try testing.expectEqual(null, table.get(first));
    try testing.expect(table.get(second) != null);
}

test "Table: the generation skips 0 when it wraps" {
    var table: Table = try .init(testing.allocator, 1);
    defer table.deinit(testing.allocator);

    table.slots[0].generation = std.math.maxInt(u16);
    const conn = table.acquire(testConnection()).?;
    try testing.expectEqual(std.math.maxInt(u16), conn.handle().generation);
    table.release(testing.allocator, conn);
    try testing.expectEqual(1, table.slots[0].generation);
}

test "Table: a handle with an index outside the table is not found" {
    var table: Table = try .init(testing.allocator, 1);
    defer table.deinit(testing.allocator);

    try testing.expectEqual(null, table.get(.fromHandle(.{ .index = 7, .generation = 1 })));
}
