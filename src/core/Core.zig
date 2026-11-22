//! The sans-IO protocol state machine.
//!
//! The core does no I/O and reads no clock. The host gives it connection events, bytes, and
//! the current time (`now_ms`). The core answers with actions for the host (`nextAction`),
//! events for the application (`nextEvent`), and one timer deadline (`nextDeadline`).
//!
//! Host loop:
//!
//! 1. Call an input function: `connOpened`, `connFailed`, `connData`, `connClosed`, or
//!    `timerFired`. Each one takes the current time.
//! 2. Pull and do all actions with `nextAction`, and pull all events with `nextEvent`.
//! 3. Wait for I/O, or until `nextDeadline`. At or after the deadline, call `timerFired`.
//!
//! Connection rules:
//!
//! - The core assigns each handle in an `open_conn` action.
//! - The host answers each `open_conn` with `connOpened` or `connFailed`.
//! - After `connOpened`, the host calls `connClosed` when the connection closes.
//! - After a `close` action, the host closes the connection and calls `connClosed`.
//! - The handle is invalid after `connFailed` or `connClosed`.
//!
//! Slices in an action stay valid until the next input call.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const proto = @import("../proto/root.zig");
const frame = proto.frame;
const wire = proto.wire;

const connections_module = @import("connections.zig");
const Conn = connections_module.Conn;
const Queue = @import("queue.zig").Queue;
const timers_module = @import("timers.zig");
const Timers = timers_module.Timers;
const TimerId = timers_module.Id;

gpa: Allocator,
options: Options,
/// The time of the last input. The host clock must not go backwards.
now_ms: u64,
connections: connections_module.Table,
timers: Timers,
actions: Queue(QueuedAction),
/// The bytes that queued actions refer to. The core clears it at the start of an input call
/// when the host pulled all actions.
outbox: std.ArrayList(u8),

const Core = @This();

pub const Options = struct {
    /// The time at init, in the same clock as the `now_ms` of each input.
    now_ms: u64,
    /// The largest number of connections at the same time.
    connection_count_max: u32,
    /// The time from `open_conn` to `connOpened`. After it, the core closes the connection.
    connect_timeout_ms: u32,
    /// The largest frame that the core accepts. A larger frame closes the connection.
    frame_size_max: u32,
};

/// Something that the host must do.
pub const Action = union(enum) {
    /// Open a TCP connection, then call `connOpened` or `connFailed`.
    open_conn: OpenConn,
    /// Write all bytes to the connection, in order.
    send: Send,
    /// Close the connection, then call `connClosed`.
    close: Close,

    pub const OpenConn = struct { conn: Conn, address: Address };
    pub const Send = struct { conn: Conn, bytes: []const u8 };
    pub const Close = struct { conn: Conn };
};

pub const Address = union(enum) {
    /// A host name or an address string. The host resolves it.
    host: Host,
    ip4: Ip4,

    pub const Host = struct { name: []const u8, port: u16 };
    pub const Ip4 = struct { ip: wire.Ip4, port: u16 };
};

/// Something that happened, for the application. D2.2 adds the first events, and with them
/// the event queue. A queue cannot hold a union with no fields.
pub const Event = union(enum) {};

pub const InputError = error{
    /// The handle is not in use: the core did not assign it, or the host already ended it.
    ConnectionUnknown,
    /// The call does not match the connection state. For example, `connData` before
    /// `connOpened`.
    ConnectionState,
    /// The time is earlier than the time of an earlier call.
    TimeBackwards,
} || Allocator.Error;

/// The action queue stores offsets into `outbox`, because `outbox` can move when it grows.
const QueuedAction = union(enum) {
    open_conn: struct { conn: Conn, address: QueuedAddress },
    send: struct { conn: Conn, bytes: Span },
    close: Action.Close,
};

const QueuedAddress = union(enum) {
    host: struct { name: Span, port: u16 },
    ip4: Address.Ip4,
};

const Span = struct {
    offset: u32,
    size: u32,
};

pub fn init(gpa: Allocator, options: Options) Allocator.Error!Core {
    assert(options.connection_count_max > 0);
    assert(options.connection_count_max <= connections_module.connection_count_limit);
    assert(options.connect_timeout_ms > 0);
    assert(options.frame_size_max >= frame.Format.code_u32.codeSize());

    var table: connections_module.Table = try .init(gpa, options.connection_count_max);
    errdefer table.deinit(gpa);
    // Each connection has at most one connect timer.
    const timers: Timers = try .init(gpa, options.connection_count_max);
    errdefer comptime unreachable;

    return .{
        .gpa = gpa,
        .options = options,
        .now_ms = options.now_ms,
        .connections = table,
        .timers = timers,
        .actions = .empty,
        .outbox = .empty,
    };
}

pub fn deinit(core: *Core) void {
    core.connections.deinit(core.gpa);
    core.timers.deinit(core.gpa);
    core.actions.deinit(core.gpa);
    core.outbox.deinit(core.gpa);
    core.* = undefined;
}

/// The connection `conn` is open.
pub fn connOpened(core: *Core, conn: Conn, now_ms: u64) InputError!void {
    try core.beginInput(now_ms);
    const connection = core.connections.get(conn) orelse return error.ConnectionUnknown;
    switch (connection.state) {
        .connecting => {
            core.timers.cancel(.connect(conn));
            connection.state = .open;
        },
        // The core already queued a `close` action, so the open does not matter.
        .closing => {},
        .open => return error.ConnectionState,
    }
}

/// The host could not open the connection `conn`. The handle becomes invalid.
pub fn connFailed(core: *Core, conn: Conn, now_ms: u64) InputError!void {
    try core.beginInput(now_ms);
    const connection = core.connections.get(conn) orelse return error.ConnectionUnknown;
    switch (connection.state) {
        .connecting, .closing => core.release(conn),
        .open => return error.ConnectionState,
    }
}

/// Bytes arrived on the connection `conn`. The core copies them.
pub fn connData(core: *Core, conn: Conn, bytes: []const u8, now_ms: u64) InputError!void {
    try core.beginInput(now_ms);
    const connection = core.connections.get(conn) orelse return error.ConnectionUnknown;
    switch (connection.state) {
        .open => {
            try connection.decoder.feed(core.gpa, bytes);
            try core.receiveFrames(conn);
        },
        // The core is closing the connection, so it drops bytes that were in flight.
        .closing => {},
        .connecting => return error.ConnectionState,
    }
}

/// The connection `conn` closed. The handle becomes invalid.
pub fn connClosed(core: *Core, conn: Conn, now_ms: u64) InputError!void {
    try core.beginInput(now_ms);
    const connection = core.connections.get(conn) orelse return error.ConnectionUnknown;
    switch (connection.state) {
        .open, .closing => core.release(conn),
        .connecting => return error.ConnectionState,
    }
}

/// Runs all timers with a deadline at or before `now_ms`. A call before the next deadline
/// does nothing.
pub fn timerFired(core: *Core, now_ms: u64) InputError!void {
    try core.beginInput(now_ms);
    // Timer handlers set new deadlines only after `now_ms`, so each timer fires at most once.
    const timer_count_max = core.timers.count;
    var timer_count: u32 = 0;
    while (core.timers.popExpired(now_ms)) |timer| {
        timer_count += 1;
        assert(timer_count <= timer_count_max);
        try core.timerRun(timer.id);
    }
}

/// Returns the time at which the host must call `timerFired`, or null if no timer is set.
pub fn nextDeadline(core: *const Core) ?u64 {
    return core.timers.nextDeadline();
}

/// Returns the next action, or null if there is none.
pub fn nextAction(core: *Core) ?Action {
    const queued = core.actions.pop() orelse return null;
    return switch (queued) {
        .open_conn => |open_conn| .{ .open_conn = .{
            .conn = open_conn.conn,
            .address = switch (open_conn.address) {
                .host => |host| .{ .host = .{
                    .name = core.outboxSlice(host.name),
                    .port = host.port,
                } },
                .ip4 => |ip4| .{ .ip4 = ip4 },
            },
        } },
        .send => |send_action| .{ .send = .{
            .conn = send_action.conn,
            .bytes = core.outboxSlice(send_action.bytes),
        } },
        .close => |close_action| .{ .close = close_action },
    };
}

/// Returns the next application event, or null if there is none.
pub fn nextEvent(core: *Core) ?Event {
    _ = core;
    return null;
}

/// Assigns a handle and queues an `open_conn` action. The connection expects frames in
/// `format`.
pub fn openConnection(
    core: *Core,
    address: Address,
    format: frame.Format,
) (error{ConnectionLimit} || Allocator.Error)!Conn {
    const outbox_size = core.outbox.items.len;
    errdefer core.outbox.shrinkRetainingCapacity(outbox_size);

    const queued_address: QueuedAddress = switch (address) {
        .host => |host| .{ .host = .{
            .name = try core.outboxAppend(host.name),
            .port = host.port,
        } },
        .ip4 => |ip4| .{ .ip4 = ip4 },
    };
    try core.actions.reserve(core.gpa, 1);

    const conn = core.connections.acquire(.{
        .state = .connecting,
        .format = format,
        .decoder = .init(.{ .frame_size_max = core.options.frame_size_max }),
    }) orelse return error.ConnectionLimit;
    errdefer comptime unreachable;

    core.actions.pushAssumeCapacity(.{ .open_conn = .{
        .conn = conn,
        .address = queued_address,
    } });
    core.timers.set(.connect(conn), core.now_ms + core.options.connect_timeout_ms);
    return conn;
}

/// Encodes `message` and queues a `send` action. `message` is a proto message with an
/// `encode(writer)` method.
pub fn send(core: *Core, conn: Conn, message: anytype) Allocator.Error!void {
    const connection = core.connections.get(conn).?;
    assert(connection.state == .open);

    const outbox_size = core.outbox.items.len;
    errdefer core.outbox.shrinkRetainingCapacity(outbox_size);

    try message.encode(wire.Writer.init(core.gpa, &core.outbox));
    const bytes = spanFrom(outbox_size, core.outbox.items.len);
    try core.actions.push(core.gpa, .{ .send = .{ .conn = conn, .bytes = bytes } });
}

/// Queues a `close` action. The handle stays valid until the host calls `connClosed` or
/// `connFailed`.
pub fn close(core: *Core, conn: Conn) Allocator.Error!void {
    const connection = core.connections.get(conn).?;
    assert(connection.state != .closing);

    try core.actions.push(core.gpa, .{ .close = .{ .conn = conn } });
    core.timers.cancel(.connect(conn));
    connection.state = .closing;
}

fn beginInput(core: *Core, now_ms: u64) InputError!void {
    if (now_ms < core.now_ms) return error.TimeBackwards;
    core.now_ms = now_ms;
    // The host pulled all actions, so no action refers to the outbox now.
    if (core.actions.count() == 0) core.outbox.clearRetainingCapacity();
}

fn release(core: *Core, conn: Conn) void {
    core.timers.cancel(.connect(conn));
    core.connections.release(core.gpa, conn);
    assert(core.connections.get(conn) == null);
    assert(!core.timers.isSet(.connect(conn)));
}

fn receiveFrames(core: *Core, conn: Conn) Allocator.Error!void {
    // Each frame takes at least the length field, so this bounds the loop.
    const frame_count_max = core.connections.get(conn).?.decoder.buffer.items.len /
        frame.length_size;
    var frame_count: u32 = 0;
    while (true) {
        const connection = core.connections.get(conn).?;
        // A frame handler can close the connection. Then the rest of the bytes do not matter.
        if (connection.state != .open) return;

        const message_frame = connection.decoder.next(connection.format) catch |err| {
            switch (err) {
                error.FrameTooLarge, error.FrameTooShort => {},
            }
            return core.close(conn);
        } orelse return;
        frame_count += 1;
        assert(frame_count <= frame_count_max);
        core.frameReceive(conn, message_frame);
    }
}

/// D2.2 adds message handling. Until then, the core ignores all frames.
fn frameReceive(core: *Core, conn: Conn, message_frame: frame.Frame) void {
    assert(core.connections.get(conn).?.state == .open);
    assert(message_frame.body.len < core.options.frame_size_max);
}

fn timerRun(core: *Core, id: TimerId) Allocator.Error!void {
    switch (id.kind) {
        .connect => {
            const conn: Conn = @fromBackingInt(id.key);
            // `connOpened`, `close`, and `release` cancel this timer.
            assert(core.connections.get(conn).?.state == .connecting);
            try core.close(conn);
        },
    }
}

fn outboxAppend(core: *Core, bytes: []const u8) Allocator.Error!Span {
    const offset = core.outbox.items.len;
    try core.outbox.appendSlice(core.gpa, bytes);
    return spanFrom(offset, core.outbox.items.len);
}

fn outboxSlice(core: *const Core, span: Span) []const u8 {
    assert(span.offset + span.size <= core.outbox.items.len);
    return core.outbox.items[span.offset..][0..span.size];
}

fn spanFrom(start: usize, end: usize) Span {
    assert(start <= end);
    assert(end <= std.math.maxInt(u32));
    return .{ .offset = @intCast(start), .size = @intCast(end - start) };
}

const testing = std.testing;
const TestHost = @import("TestHost.zig");

const server_address: Address = .{ .host = .{ .name = "server.example", .port = 2242 } };
const peer_address: Address = .{ .ip4 = .{ .ip = .{ 10, 0, 0, 7 }, .port = 2234 } };

test "open_conn assigns a new handle to each connection, up to the limit" {
    var options = TestHost.options_default;
    options.connection_count_max = 2;
    var host: TestHost = undefined;
    try host.init(testing.allocator, options);
    defer host.deinit();

    const a = try host.core.openConnection(server_address, .code_u32);
    const b = try host.core.openConnection(peer_address, .code_u32);
    try testing.expect(a != b);
    try testing.expectError(
        error.ConnectionLimit,
        host.core.openConnection(peer_address, .code_u8),
    );
    try host.drain();
    try host.expectActions(&.{
        .{ .open_conn = .{ .conn = a, .address = server_address } },
        .{ .open_conn = .{ .conn = b, .address = peer_address } },
    });

    // A failed connection frees its slot. The next handle is new, and the old one is unknown.
    try host.failed(a);
    const c = try host.core.openConnection(peer_address, .code_u32);
    try testing.expect(c != a);
    try testing.expect(c != b);
    try testing.expectError(error.ConnectionUnknown, host.core.connOpened(a, host.now_ms));
    const zero: Conn = @fromBackingInt(0);
    try testing.expectError(error.ConnectionUnknown, host.core.connOpened(zero, host.now_ms));
}

test "actions come out in the order that the core queued them" {
    var host: TestHost = undefined;
    try host.init(testing.allocator, TestHost.options_default);
    defer host.deinit();

    const a = try host.core.openConnection(server_address, .code_u32);
    const b = try host.core.openConnection(peer_address, .code_u32);
    try host.opened(b);
    try host.opened(a);
    const ping: proto.server.ToServer = .server_ping;
    const set_wait_port: proto.server.ToServer = .{
        .set_wait_port = .{ .port = 2234, .obfuscated = null },
    };
    try host.core.send(b, ping);
    try host.core.close(b);
    try host.core.send(a, set_wait_port);
    try host.drain();

    var ping_bytes: std.ArrayList(u8) = .empty;
    defer ping_bytes.deinit(testing.allocator);
    try ping.encode(.init(testing.allocator, &ping_bytes));
    var set_wait_port_bytes: std.ArrayList(u8) = .empty;
    defer set_wait_port_bytes.deinit(testing.allocator);
    try set_wait_port.encode(.init(testing.allocator, &set_wait_port_bytes));

    try host.expectActions(&.{
        .{ .open_conn = .{ .conn = a, .address = server_address } },
        .{ .open_conn = .{ .conn = b, .address = peer_address } },
        .{ .send = .{ .conn = b, .bytes = ping_bytes.items } },
        .{ .close = .{ .conn = b } },
        .{ .send = .{ .conn = a, .bytes = set_wait_port_bytes.items } },
    });
    try testing.expectEqual(null, host.core.nextAction());
}

test "the outbox is cleared only after the host pulls all actions" {
    var host: TestHost = undefined;
    try host.init(testing.allocator, TestHost.options_default);
    defer host.deinit();

    const conn = try host.core.openConnection(peer_address, .code_u32);
    try host.opened(conn);
    const ping: proto.server.ToServer = .server_ping;
    try host.core.send(conn, ping);
    try host.core.send(conn, ping);
    try testing.expect(host.core.outbox.items.len > 0);

    // One action is still in the queue, so an input must keep the bytes.
    const first = host.core.nextAction().?;
    try host.core.connData(conn, &.{}, host.now_ms);
    const second = host.core.nextAction().?;
    try testing.expectEqualSlices(u8, first.send.bytes, second.send.bytes);
    try testing.expectEqual(2 * first.send.bytes.len, host.core.outbox.items.len);

    try host.core.connData(conn, &.{}, host.now_ms);
    try testing.expectEqual(0, host.core.outbox.items.len);
}

test "a connection that does not open in time is closed" {
    var host: TestHost = undefined;
    try host.init(testing.allocator, TestHost.options_default);
    defer host.deinit();

    try testing.expectEqual(null, host.core.nextDeadline());
    const conn = try host.core.openConnection(peer_address, .code_u32);
    try host.drain();
    host.actions.clearRetainingCapacity();
    const deadline_ms = host.now_ms + TestHost.options_default.connect_timeout_ms;
    try testing.expectEqual(deadline_ms, host.core.nextDeadline().?);

    // A call before the deadline does nothing.
    host.advance(TestHost.options_default.connect_timeout_ms - 1);
    try host.core.timerFired(host.now_ms);
    try host.drain();
    try host.expectActions(&.{});

    try host.fireTimers();
    try testing.expectEqual(deadline_ms, host.now_ms);
    try host.expectActions(&.{.{ .close = .{ .conn = conn } }});
    try testing.expectEqual(null, host.core.nextDeadline());

    // The connect finished while the close was in flight. The core ignores it.
    try host.opened(conn);
    try host.data(conn, "late bytes");
    try host.closed(conn);
    try host.expectActions(&.{});
    try testing.expectEqual(0, host.core.connections.count());
}

test "the next deadline follows the earliest connect timer" {
    var host: TestHost = undefined;
    try host.init(testing.allocator, TestHost.options_default);
    defer host.deinit();
    const timeout_ms = TestHost.options_default.connect_timeout_ms;
    const start_ms = host.now_ms;

    const a = try host.core.openConnection(peer_address, .code_u32);
    host.advance(100);
    host.core.now_ms = host.now_ms;
    const b = try host.core.openConnection(peer_address, .code_u32);
    host.advance(100);
    host.core.now_ms = host.now_ms;
    const c = try host.core.openConnection(peer_address, .code_u32);
    try host.drain();
    host.actions.clearRetainingCapacity();
    try testing.expectEqual(start_ms + timeout_ms, host.core.nextDeadline().?);

    // An open connection has no connect timer.
    try host.opened(a);
    try testing.expectEqual(start_ms + 100 + timeout_ms, host.core.nextDeadline().?);

    // A failed connection has no connect timer.
    try host.failed(b);
    try testing.expectEqual(start_ms + 200 + timeout_ms, host.core.nextDeadline().?);

    try host.fireTimers();
    try host.expectActions(&.{.{ .close = .{ .conn = c } }});
    try testing.expectEqual(null, host.core.nextDeadline());
}

test "timers with the same deadline fire in the order the core set them" {
    var host: TestHost = undefined;
    try host.init(testing.allocator, TestHost.options_default);
    defer host.deinit();

    const a = try host.core.openConnection(peer_address, .code_u32);
    const b = try host.core.openConnection(peer_address, .code_u32);
    const c = try host.core.openConnection(peer_address, .code_u32);
    try host.drain();
    host.actions.clearRetainingCapacity();

    try host.fireTimers();
    try host.expectActions(&.{
        .{ .close = .{ .conn = a } },
        .{ .close = .{ .conn = b } },
        .{ .close = .{ .conn = c } },
    });
}

test "inputs that do not match the connection state are errors" {
    var host: TestHost = undefined;
    try host.init(testing.allocator, TestHost.options_default);
    defer host.deinit();
    const now_ms = host.now_ms;

    const conn = try host.core.openConnection(peer_address, .code_u32);
    try testing.expectError(error.ConnectionState, host.core.connData(conn, "x", now_ms));
    try testing.expectError(error.ConnectionState, host.core.connClosed(conn, now_ms));

    try host.core.connOpened(conn, now_ms);
    try testing.expectError(error.ConnectionState, host.core.connOpened(conn, now_ms));
    try testing.expectError(error.ConnectionState, host.core.connFailed(conn, now_ms));

    try testing.expectError(error.TimeBackwards, host.core.connData(conn, "x", now_ms - 1));
    try testing.expectError(error.TimeBackwards, host.core.timerFired(now_ms - 1));

    try host.core.connClosed(conn, now_ms);
    try testing.expectError(error.ConnectionUnknown, host.core.connClosed(conn, now_ms));
    try testing.expectError(error.ConnectionUnknown, host.core.connData(conn, "x", now_ms));
}

test "a connect that fails after a close is accepted" {
    var host: TestHost = undefined;
    try host.init(testing.allocator, TestHost.options_default);
    defer host.deinit();

    const conn = try host.core.openConnection(peer_address, .code_u32);
    try host.core.close(conn);
    try host.failed(conn);
    try host.expectActions(&.{
        .{ .open_conn = .{ .conn = conn, .address = peer_address } },
        .{ .close = .{ .conn = conn } },
    });
    try testing.expectEqual(0, host.core.connections.count());
}

test "frames split across reads do not close the connection" {
    var host: TestHost = undefined;
    try host.init(testing.allocator, TestHost.options_default);
    defer host.deinit();

    const conn = try host.core.openConnection(server_address, .code_u32);
    try host.opened(conn);
    host.actions.clearRetainingCapacity();

    // Two complete `ServerPing` frames, split at each byte.
    const ping = [_]u8{ 4, 0, 0, 0, 32, 0, 0, 0 };
    const frames = ping ++ ping;
    for (0..frames.len) |index| try host.data(conn, frames[index..][0..1]);
    try host.expectActions(&.{});
    try testing.expectEqual(.open, host.core.connections.get(conn).?.state);
}

test "a frame larger than frame_size_max closes the connection" {
    var host: TestHost = undefined;
    try host.init(testing.allocator, TestHost.options_default);
    defer host.deinit();

    const conn = try host.core.openConnection(server_address, .code_u32);
    try host.opened(conn);
    host.actions.clearRetainingCapacity();

    var header: [8]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], TestHost.options_default.frame_size_max + 1, .little);
    std.mem.writeInt(u32, header[4..8], 1, .little);
    try host.data(conn, &header);
    try host.expectActions(&.{.{ .close = .{ .conn = conn } }});

    // The core drops bytes that arrive before the host closes the connection.
    try host.data(conn, &header);
    try host.closed(conn);
    try host.expectActions(&.{});
}
