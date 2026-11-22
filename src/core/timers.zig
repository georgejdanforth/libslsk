//! The timers of the core. The core has no clock, so each timer is an absolute deadline in the
//! host's time (`now_ms`). The host asks for the next deadline and calls `timerFired` at or
//! after it.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Conn = @import("connections.zig").Conn;

pub const Kind = enum(u8) {
    /// The host did not open a connection in time. The key is the connection.
    connect,
};

/// Identifies one timer. A second `set` with the same id moves the deadline of the timer.
pub const Id = struct {
    kind: Kind,
    key: u32,

    pub fn connect(conn: Conn) Id {
        return .{ .kind = .connect, .key = @backingInt(conn) };
    }
};

pub const Timer = struct {
    id: Id,
    deadline_ms: u64,
    /// The order of `set` calls. Timers with the same deadline fire in this order, so the
    /// result does not depend on the slot layout.
    sequence: u64,
};

/// A fixed number of timer slots, allocated at init. The core has few timers, so a linear
/// scan is fast enough and keeps the order easy to check.
pub const Timers = struct {
    timers: []Timer,
    count: u32,
    sequence_next: u64,

    pub fn init(gpa: Allocator, timer_count_max: u32) Allocator.Error!Timers {
        assert(timer_count_max > 0);
        const timers = try gpa.alloc(Timer, timer_count_max);
        return .{ .timers = timers, .count = 0, .sequence_next = 0 };
    }

    pub fn deinit(timers: *Timers, gpa: Allocator) void {
        gpa.free(timers.timers);
        timers.* = undefined;
    }

    /// Sets the deadline of the timer `id`. If the timer exists, this replaces its deadline.
    pub fn set(timers: *Timers, id: Id, deadline_ms: u64) void {
        const sequence = timers.sequence_next;
        timers.sequence_next += 1;

        if (timers.find(id)) |index| {
            timers.timers[index].deadline_ms = deadline_ms;
            timers.timers[index].sequence = sequence;
        } else {
            // The core sizes the table for all timers that it can have at the same time.
            assert(timers.count < timers.timers.len);
            timers.timers[timers.count] = .{
                .id = id,
                .deadline_ms = deadline_ms,
                .sequence = sequence,
            };
            timers.count += 1;
        }
    }

    /// Removes the timer `id`. Does nothing if it does not exist.
    pub fn cancel(timers: *Timers, id: Id) void {
        if (timers.find(id)) |index| timers.remove(index);
    }

    pub fn isSet(timers: *const Timers, id: Id) bool {
        return timers.find(id) != null;
    }

    /// Returns the earliest deadline, or null if no timer is set.
    pub fn nextDeadline(timers: *const Timers) ?u64 {
        if (timers.earliest()) |index| {
            return timers.timers[index].deadline_ms;
        } else {
            return null;
        }
    }

    /// Removes and returns the earliest timer with a deadline at or before `now_ms`.
    pub fn popExpired(timers: *Timers, now_ms: u64) ?Timer {
        const index = timers.earliest() orelse return null;
        const timer = timers.timers[index];
        if (timer.deadline_ms <= now_ms) {
            timers.remove(index);
            return timer;
        } else {
            return null;
        }
    }

    fn find(timers: *const Timers, id: Id) ?u32 {
        for (timers.timers[0..timers.count], 0..) |timer, index| {
            if (timer.id.kind == id.kind and timer.id.key == id.key) return @intCast(index);
        }
        return null;
    }

    fn earliest(timers: *const Timers) ?u32 {
        if (timers.count == 0) return null;

        var best: u32 = 0;
        for (timers.timers[1..timers.count], 1..) |timer, index| {
            const best_timer = timers.timers[best];
            if (timer.deadline_ms < best_timer.deadline_ms) {
                best = @intCast(index);
            } else if (timer.deadline_ms == best_timer.deadline_ms) {
                assert(timer.sequence != best_timer.sequence);
                if (timer.sequence < best_timer.sequence) best = @intCast(index);
            }
        }
        return best;
    }

    fn remove(timers: *Timers, index: u32) void {
        assert(index < timers.count);
        // The order of the slots does not matter, so move the last timer into the gap.
        timers.count -= 1;
        timers.timers[index] = timers.timers[timers.count];
    }
};

const testing = std.testing;

fn testId(key: u32) Id {
    return .{ .kind = .connect, .key = key };
}

test "Timers: the next deadline is the earliest one" {
    var timers: Timers = try .init(testing.allocator, 4);
    defer timers.deinit(testing.allocator);

    try testing.expectEqual(null, timers.nextDeadline());
    timers.set(testId(1), 300);
    timers.set(testId(2), 100);
    timers.set(testId(3), 200);
    try testing.expectEqual(100, timers.nextDeadline().?);

    timers.cancel(testId(2));
    try testing.expectEqual(200, timers.nextDeadline().?);
    timers.cancel(testId(2));
    try testing.expectEqual(2, timers.count);
}

test "Timers: set with an existing id moves the deadline" {
    var timers: Timers = try .init(testing.allocator, 2);
    defer timers.deinit(testing.allocator);

    timers.set(testId(1), 100);
    timers.set(testId(1), 500);
    try testing.expectEqual(1, timers.count);
    try testing.expectEqual(500, timers.nextDeadline().?);
}

test "Timers: expired timers come out in deadline order, then in set order" {
    var timers: Timers = try .init(testing.allocator, 8);
    defer timers.deinit(testing.allocator);

    timers.set(testId(1), 200);
    timers.set(testId(2), 100);
    timers.set(testId(3), 200);
    timers.set(testId(4), 100);
    timers.set(testId(5), 900);
    // Moving a timer gives it a new place in the set order.
    timers.set(testId(2), 100);

    try testing.expectEqual(null, timers.popExpired(99));
    const expected_keys = [_]u32{ 4, 2, 1, 3 };
    for (expected_keys) |key| {
        const timer = timers.popExpired(200).?;
        try testing.expectEqual(key, timer.id.key);
    }
    try testing.expectEqual(null, timers.popExpired(200));
    try testing.expectEqual(900, timers.nextDeadline().?);
    try testing.expect(timers.isSet(testId(5)));
    try testing.expect(!timers.isSet(testId(1)));
}
