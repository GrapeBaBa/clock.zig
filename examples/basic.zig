const std = @import("std");
const clock = @import("clock");

/// Prints each new slot.
fn onSlot(ctx: *anyopaque, slot: clock.Slot) void {
    _ = ctx;
    std.debug.print("slot={d}\n", .{slot});
}

/// Prints each new epoch.
fn onEpoch(ctx: *anyopaque, epoch: clock.Epoch) void {
    _ = ctx;
    std.debug.print("epoch={d}\n", .{epoch});
}

/// Basic standalone example:
/// - starts a clock
/// - subscribes slot/epoch listeners
/// - waits for a future slot
/// - aborts and exits
pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .environ = .empty });
    defer threaded.deinit();

    var signal = clock.AbortSignal{};
    const genesis_time_ms: u64 = @as(
        u64,
        @intCast(@divTrunc(std.Io.Clock.real.now(std.Options.debug_io).nanoseconds, std.time.ns_per_ms)),
    );

    var c = clock.Clock.init(
        std.heap.smp_allocator,
        threaded.io(),
        .{
            .slot_duration_ms = 200,
            .maximum_gossip_clock_disparity_ms = 100,
            .slots_per_epoch = 4,
        },
        genesis_time_ms,
        &signal,
    );
    defer c.deinit();

    try c.onSlot(.{ .ctx = @ptrCast(&signal), .callback = onSlot });
    try c.onEpoch(.{ .ctx = @ptrCast(&signal), .callback = onEpoch });

    const start_slot = c.currentSlot();
    var fut = c.waitForSlot(start_slot + 6);
    try fut.await(threaded.io());

    signal.abort();
}
