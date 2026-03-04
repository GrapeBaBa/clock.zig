const std = @import("std");
const clock = @import("zig_beacon_clock");

fn onSlot(_: ?*anyopaque, slot: clock.Slot) void {
    std.debug.print("slot={d}\n", .{slot});
}

fn onEpoch(_: ?*anyopaque, epoch: clock.Epoch) void {
    std.debug.print("epoch={d}\n", .{epoch});
}

pub fn main() !void {
    var evented: std.Io.Evented = undefined;
    try evented.init(std.heap.page_allocator, .{});
    defer evented.deinit();
    const io = evented.io();

    const now_sec: u64 = @intCast(std.Io.Clock.real.now(io).toSeconds());

    var ec: clock.EventClock = undefined;
    try ec.init(std.heap.page_allocator, .{
        .genesis_time_sec = now_sec,
        .seconds_per_slot = 1,
        .slots_per_epoch = 4,
    }, io);
    defer ec.deinit();

    _ = try ec.onSlot(onSlot, null);
    _ = try ec.onEpoch(onEpoch, null);

    ec.start();

    const start_slot = ec.currentSlotOrGenesis();
    std.debug.print("start_slot={d}, waiting for slot {d}...\n", .{ start_slot, start_slot + 3 });

    var fut = try ec.waitForSlot(start_slot + 3);
    errdefer fut.cancel();
    try fut.await(io);

    std.debug.print("done.\n", .{});
}
