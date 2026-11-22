//! A scripted host for core unit tests. It owns a fake clock, feeds inputs to the core, and
//! records each action. It uses no sockets and no real clock, so tests are deterministic.
//!
//! Each input method drains the core after the call. Then `expectActions` compares the
//! recorded actions and clears them.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Core = @import("Core.zig");
const Conn = @import("connections.zig").Conn;

core: Core,
/// The fake clock. Only `advance` and `fireTimers` move it.
now_ms: u64,
/// Copies of the recorded actions. Slices from the core become invalid after the next input,
/// so the host copies them into `arena`.
actions: std.ArrayList(Core.Action),
arena: std.heap.ArenaAllocator,

const TestHost = @This();

/// Options for a test core. Tests change the fields that they check.
pub const options_default: Core.Options = .{
    .now_ms = 1_000,
    .connection_count_max = 4,
    .connect_timeout_ms = 5_000,
    .frame_size_max = 1024,
};

/// Inits `host` in place. The core keeps no pointer to the host, but the arena must not move
/// while the recorded actions refer to it.
pub fn init(host: *TestHost, gpa: Allocator, options: Core.Options) Allocator.Error!void {
    host.* = .{
        .core = try .init(gpa, options),
        .now_ms = options.now_ms,
        .actions = .empty,
        .arena = .init(gpa),
    };
}

pub fn deinit(host: *TestHost) void {
    const gpa = host.core.gpa;
    host.core.deinit();
    host.actions.deinit(gpa);
    host.arena.deinit();
    host.* = undefined;
}

pub fn advance(host: *TestHost, duration_ms: u64) void {
    host.now_ms += duration_ms;
}

pub fn opened(host: *TestHost, conn: Conn) !void {
    try host.core.connOpened(conn, host.now_ms);
    try host.drain();
}

pub fn failed(host: *TestHost, conn: Conn) !void {
    try host.core.connFailed(conn, host.now_ms);
    try host.drain();
}

pub fn data(host: *TestHost, conn: Conn, bytes: []const u8) !void {
    try host.core.connData(conn, bytes, host.now_ms);
    try host.drain();
}

pub fn closed(host: *TestHost, conn: Conn) !void {
    try host.core.connClosed(conn, host.now_ms);
    try host.drain();
}

/// Moves the clock to the next deadline and fires the timers.
pub fn fireTimers(host: *TestHost) !void {
    const deadline_ms = host.core.nextDeadline().?;
    assert(deadline_ms >= host.now_ms);
    host.now_ms = deadline_ms;
    try host.core.timerFired(host.now_ms);
    try host.drain();
}

/// Pulls all actions from the core and records copies. It also pulls all events.
pub fn drain(host: *TestHost) Allocator.Error!void {
    const gpa = host.core.gpa;
    const arena = host.arena.allocator();
    while (host.core.nextAction()) |action| {
        const copy: Core.Action = switch (action) {
            .open_conn => |open_conn| .{ .open_conn = .{
                .conn = open_conn.conn,
                .address = switch (open_conn.address) {
                    .host => |address| .{ .host = .{
                        .name = try arena.dupe(u8, address.name),
                        .port = address.port,
                    } },
                    .ip4 => |address| .{ .ip4 = address },
                },
            } },
            .send => |send| .{ .send = .{
                .conn = send.conn,
                .bytes = try arena.dupe(u8, send.bytes),
            } },
            .close => |close| .{ .close = close },
        };
        try host.actions.append(gpa, copy);
    }
    while (host.core.nextEvent()) |event| switch (event) {};
}

/// Checks the recorded actions, in order, and clears them.
pub fn expectActions(host: *TestHost, expected: []const Core.Action) !void {
    try std.testing.expectEqualDeep(expected, host.actions.items);
    host.actions.clearRetainingCapacity();
}
