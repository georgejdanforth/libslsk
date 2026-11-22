//! A first-in, first-out queue for the actions and events of the core.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// The host pulls items in the order that the core pushed them. The queue grows while the
/// host does not pull, and it starts again at the front of its buffer each time it is empty.
pub fn Queue(comptime T: type) type {
    return struct {
        items: std.ArrayList(T),
        /// The index of the next item that `pop` returns.
        head: usize,

        const Self = @This();

        pub const empty: Self = .{ .items = .empty, .head = 0 };

        pub fn deinit(queue: *Self, gpa: Allocator) void {
            queue.items.deinit(gpa);
            queue.* = undefined;
        }

        pub fn push(queue: *Self, gpa: Allocator, item: T) Allocator.Error!void {
            assert(queue.head <= queue.items.items.len);
            try queue.items.append(gpa, item);
        }

        /// Reserves space for the next `count_unused` calls to `pushAssumeCapacity`.
        pub fn reserve(queue: *Self, gpa: Allocator, count_unused: usize) Allocator.Error!void {
            try queue.items.ensureUnusedCapacity(gpa, count_unused);
        }

        pub fn pushAssumeCapacity(queue: *Self, item: T) void {
            assert(queue.head <= queue.items.items.len);
            queue.items.appendAssumeCapacity(item);
        }

        pub fn pop(queue: *Self) ?T {
            assert(queue.head <= queue.items.items.len);
            if (queue.head < queue.items.items.len) {
                const item = queue.items.items[queue.head];
                queue.head += 1;
                if (queue.head == queue.items.items.len) {
                    queue.items.clearRetainingCapacity();
                    queue.head = 0;
                }
                return item;
            } else {
                assert(queue.head == 0);
                return null;
            }
        }

        pub fn count(queue: *const Self) usize {
            assert(queue.head <= queue.items.items.len);
            return queue.items.items.len - queue.head;
        }
    };
}

const testing = std.testing;

test "Queue: items come out in push order" {
    var queue: Queue(u32) = .empty;
    defer queue.deinit(testing.allocator);

    try testing.expectEqual(null, queue.pop());
    for (0..5) |value| try queue.push(testing.allocator, @intCast(value));
    try testing.expectEqual(5, queue.count());
    for (0..5) |value| try testing.expectEqual(@as(u32, @intCast(value)), queue.pop().?);
    try testing.expectEqual(null, queue.pop());
    try testing.expectEqual(0, queue.count());
}

test "Queue: push between pops keeps the order and reuses the buffer" {
    var queue: Queue(u32) = .empty;
    defer queue.deinit(testing.allocator);

    try queue.push(testing.allocator, 1);
    try queue.push(testing.allocator, 2);
    try testing.expectEqual(1, queue.pop().?);
    try queue.push(testing.allocator, 3);
    try testing.expectEqual(2, queue.pop().?);
    try testing.expectEqual(3, queue.pop().?);
    // The queue is empty, so the next item goes to the front of the buffer.
    try testing.expectEqual(0, queue.head);
    try testing.expectEqual(0, queue.items.items.len);
    try queue.push(testing.allocator, 4);
    try testing.expectEqual(4, queue.pop().?);
}
